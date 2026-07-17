package audio

// Sende-Pipeline: Mikrofon-Frame (10 ms) → AEC → RNNoise → VAD-Gate →
// Opus (20 ms, VBR + FEC + DTX). Empfangs-Seite: Opus-Decode mit
// FEC/PLC-Unterstützung (der Jitter-Buffer entscheidet, was dekodiert wird).
//
// Alles rechnet bei 48 kHz mono. RNNoise arbeitet auf exakt 480 Samples
// (10 ms) in 16-Bit-Skala; Opus bekommt 960 Samples (20 ms) in ±1.

import "core:c"
import "core:math"

SAMPLE_RATE :: 48000
FRAME_10MS :: 480 // DSP-Frame (RNNoise, AEC)
FRAME_20MS :: 960 // Opus-Frame
FRAME_MS :: 20 // Pakettakt
MAX_PAYLOAD :: 400 // Opus @ 32 kbps VBR bleibt weit darunter

BITRATE :: 32000 // Fullband-Sprache, „crispy“ und trotzdem schlank
EXPECTED_LOSS_PERC :: 15 // Opus legt entsprechend FEC-Redundanz an

// VAD-Gate: RNNoise liefert pro 10-ms-Frame eine Sprach-Wahrscheinlichkeit.
// Über der Schwelle bleibt das Gate GATE_HOLD_FRAMES offen (Hangover),
// damit Satzenden und Atempausen nicht abgehackt werden.
GATE_OPEN_PROB :: f32(0.55)
GATE_HOLD_FRAMES :: 40 // 400 ms
GATE_ATTACK :: f32(0.45) // schnell auf
GATE_RELEASE :: f32(0.06) // sanft zu

// AEC-Referenz-FIFO (10-ms-Frames). Der Worker füttert Playback burstweise
// (60 ms Vorlauf am Stück) — deshalb puffern WIR die Referenz und geben
// speex_echo_cancellation pro Capture-Frame den zeitlich passenden
// Playback-Frame. Ziel-Vorlauf ≈ Playback-Ring (60 ms); läuft der Puffer
// weiter voraus (Toggle, Gerätewechsel), fallen die ältesten Frames weg.
REF_FRAMES :: 12 // 120 ms Kapazität
REF_MAX_LEAD :: 8 // > 80 ms Vorlauf → auf Ziel zurückstutzen

Processor :: struct {
	enc:         ^Opus_Encoder,
	dn:          ^Denoise_State,
	aec:         ^Speex_Echo_State,
	// Zustand des Sende-Gates
	vad:         f32, // geglättete Sprach-Wahrscheinlichkeit (UI)
	gate:        f32, // 0..1, multiplikativ
	hold:        int,
	level:       f32, // RMS nach Gate, 0..1 (UI-Pegel)
	// 2×10 ms sammeln → 1 Opus-Frame
	pcm20:       [FRAME_20MS]f32,
	pcm_fill:    int,
	denoise_on:  bool,
	aec_on:      bool,
	gate_on:     bool, // aus → Gate dauerhaft offen (Opus-DTX greift trotzdem)
	// AEC-Referenz: Ring aus 10-ms-Frames (nur der Worker-Thread greift zu)
	ref_buf:     [REF_FRAMES][FRAME_10MS]i16,
	ref_r:       int,
	ref_w:       int,
	// Kratzer: Wiederverwendete Puffer (keine Allocs im Takt)
	scratch_i16: [FRAME_10MS]i16,
	scratch_out: [FRAME_10MS]i16,
	scratch_f32: [FRAME_10MS]f32,
}

processor_init :: proc(p: ^Processor) -> bool {
	err: c.int
	p.enc = opus_encoder_create(SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, &err)
	if p.enc == nil || err != 0 {
		return false
	}
	opus_encoder_ctl(p.enc, OPUS_SET_BITRATE, c.int32_t(BITRATE))
	opus_encoder_ctl(p.enc, OPUS_SET_VBR, c.int32_t(1))
	opus_encoder_ctl(p.enc, OPUS_SET_COMPLEXITY, c.int32_t(10))
	opus_encoder_ctl(p.enc, OPUS_SET_SIGNAL, c.int32_t(OPUS_SIGNAL_VOICE))
	opus_encoder_ctl(p.enc, OPUS_SET_BANDWIDTH, c.int32_t(OPUS_BANDWIDTH_FULLBAND))
	opus_encoder_ctl(p.enc, OPUS_SET_INBAND_FEC, c.int32_t(1))
	opus_encoder_ctl(p.enc, OPUS_SET_PACKET_LOSS_PERC, c.int32_t(EXPECTED_LOSS_PERC))
	opus_encoder_ctl(p.enc, OPUS_SET_DTX, c.int32_t(1))

	p.dn = rnnoise_create(nil)
	assert(int(rnnoise_get_frame_size()) == FRAME_10MS)

	// AEC: 10-ms-Frames, 100 ms Filterlänge (üblicher Sweetspot).
	p.aec = speex_echo_state_init(FRAME_10MS, FRAME_10MS * 10)
	rate := c.int(SAMPLE_RATE)
	speex_echo_ctl(p.aec, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)

	p.denoise_on = true
	p.aec_on = true
	p.gate_on = true
	return true
}

processor_destroy :: proc(p: ^Processor) {
	if p.enc != nil {opus_encoder_destroy(p.enc)}
	if p.dn != nil {rnnoise_destroy(p.dn)}
	if p.aec != nil {speex_echo_state_destroy(p.aec)}
	p^ = {}
}

// Referenz fürs AEC: jeder Frame, der an den Lautsprecher geht (10 ms, ±1)
// landet im FIFO; processor_push_capture zieht ihn zeitversetzt heraus.
// Voller Puffer verwirft die ältesten Frames — still, ohne Speex-Warnungen.
processor_feed_playback :: proc(p: ^Processor, frame: []f32) {
	assert(len(frame) == FRAME_10MS)
	if p.ref_w - p.ref_r >= REF_FRAMES {
		p.ref_r += 1
	}
	dst := &p.ref_buf[p.ref_w % REF_FRAMES]
	for s, i in frame {
		dst[i] = i16(clamp(s, -1, 1) * 32767)
	}
	p.ref_w += 1
}

// Ein 10-ms-Mikrofon-Frame (±1). Rückgabe: fertiges Opus-Paket (in `out`),
// sobald 20 ms beisammen sind UND das Gate offen ist — sonst n == 0.
// Bei geschlossenem Gate wird GAR NICHTS gesendet (0 Bandbreite in Stille).
processor_push_capture :: proc(p: ^Processor, mic: []f32, out: []byte) -> (n: int) {
	assert(len(mic) == FRAME_10MS && len(out) >= MAX_PAYLOAD)

	// 1) AEC (arbeitet auf int16). Der älteste Referenz-Frame im FIFO ist
	// das, was JETZT ungefähr aus dem Lautsprecher kommt (Playback-Vorlauf).
	// Ohne Referenz (niemand spricht / Playback steht) gibt es kein Echo zu
	// entfernen — Bypass.
	for s, i in mic {
		p.scratch_i16[i] = i16(clamp(s, -1, 1) * 32767)
	}
	if p.aec_on && p.ref_w > p.ref_r {
		for p.ref_w - p.ref_r > REF_MAX_LEAD {
			p.ref_r += 1 // zu weit vorausgelaufen → Ausrichtung zurückholen
		}
		ref := &p.ref_buf[p.ref_r % REF_FRAMES]
		p.ref_r += 1
		speex_echo_cancellation(p.aec, &p.scratch_i16[0], &ref[0], &p.scratch_out[0])
	} else {
		p.scratch_out = p.scratch_i16
	}

	// 2) RNNoise (int16-Werte als f32) + VAD
	for v, i in p.scratch_out {
		p.scratch_f32[i] = f32(v)
	}
	prob: f32 = 1
	if p.denoise_on {
		prob = rnnoise_process_frame(p.dn, &p.scratch_f32[0], &p.scratch_f32[0])
	}
	p.vad = p.vad * 0.8 + prob * 0.2

	// 3) Weiches Gate mit Hangover (abgeschaltet → dauerhaft offen)
	if prob > GATE_OPEN_PROB || !p.gate_on {
		p.hold = GATE_HOLD_FRAMES
	} else if p.hold > 0 {
		p.hold -= 1
	}
	target: f32 = p.hold > 0 ? 1 : 0
	if target > p.gate {
		p.gate += (target - p.gate) * GATE_ATTACK
	} else {
		p.gate += (target - p.gate) * GATE_RELEASE
	}

	sum: f32
	for v, i in p.scratch_f32 {
		s := v * p.gate / 32768
		p.pcm20[p.pcm_fill + i] = s
		sum += s * s
	}
	p.level = math.sqrt(sum / FRAME_10MS)

	p.pcm_fill += FRAME_10MS
	if p.pcm_fill < FRAME_20MS {
		return 0
	}
	p.pcm_fill = 0

	// 4) Zu = still: Paket gar nicht erst encodieren/senden.
	if p.gate < 0.01 && p.hold == 0 {
		return 0
	}
	r := opus_encode_float(p.enc, &p.pcm20[0], FRAME_20MS, raw_data(out), MAX_PAYLOAD)
	if r <= 2 {
		// Fehler oder DTX-Miniframe — nichts senden lohnt mehr.
		return 0
	}
	return int(r)
}

// ---------- Empfangs-Decoder ----------

Decoder :: struct {
	dec: ^Opus_Decoder,
}

decoder_init :: proc(d: ^Decoder) -> bool {
	err: c.int
	d.dec = opus_decoder_create(SAMPLE_RATE, 1, &err)
	return d.dec != nil && err == 0
}

decoder_destroy :: proc(d: ^Decoder) {
	if d.dec != nil {opus_decoder_destroy(d.dec)}
	d^ = {}
}

// Normales Decode eines 20-ms-Pakets.
decode_packet :: proc(d: ^Decoder, payload: []byte, out: []f32) -> bool {
	assert(len(out) >= FRAME_20MS)
	r := opus_decode_float(d.dec, raw_data(payload), c.int32_t(len(payload)), raw_data(out), FRAME_20MS, 0)
	return int(r) == FRAME_20MS
}

// Verlorener Frame, aber der NÄCHSTE liegt vor → dessen in-band-FEC-Daten
// rekonstruieren den fehlenden Frame.
decode_fec :: proc(d: ^Decoder, next_payload: []byte, out: []f32) -> bool {
	r := opus_decode_float(d.dec, raw_data(next_payload), c.int32_t(len(next_payload)), raw_data(out), FRAME_20MS, 1)
	return int(r) == FRAME_20MS
}

// Verlust ohne Ersatz → Packet Loss Concealment (Opus extrapoliert).
decode_plc :: proc(d: ^Decoder, out: []f32) -> bool {
	r := opus_decode_float(d.dec, nil, 0, raw_data(out), FRAME_20MS, 0)
	return int(r) == FRAME_20MS
}
