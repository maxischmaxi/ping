package audio

// Die komplette Client-Audio-Maschine eines Calls:
//
//   Mikrofon ─(miniaudio-Callback)→ cap_ring ─┐
//                                     Worker-Thread: AEC → RNNoise →
//                                     VAD-Gate → Opus → on_packet(…)
//   Netz ─engine_push_audio→ Jitter-Buffer pro ssrc ─┐
//                                     Worker-Thread: decode/FEC/PLC →
//                                     Mixdown (+Blips) → play_ring
//   play_ring ─(miniaudio-Callback)→ Lautsprecher
//
// Der Echtzeit-Callback macht ausschließlich lock-freie Ring-IO; alles
// Schwere (DSP, Opus, Mixdown) lebt im Worker-Thread. miniaudio läuft
// unabhängig von raylib (raylibs Audio wird nie initialisiert).

import "base:runtime"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"

import ma "vendor:miniaudio"

PLAY_TARGET :: FRAME_20MS * 3 // 60 ms Vorlauf im Playback-Ring
RING_CAP :: 8192

// ssrc des Selbsttest-Loopbacks (Mikrofontest): kollidiert mit keiner
// Server-ssrc (die zählen ab 1 aufwärts) und wird von engine_sync_streams
// verschont, solange der Loopback läuft.
LOOPBACK_SSRC :: u32(0xFFFF_FF10)

Packet_Proc :: proc(user: rawptr, payload: []byte)

// Start-Optionen: Geräte per Name ("" = Systemstandard) + DSP-Schalter.
// Negativ benannt, damit der Nullwert die Production-Defaults trägt
// (alles an, Standardgeräte).
Engine_Options :: struct {
	mic_name:   string,
	out_name:   string,
	no_denoise: bool,
	no_aec:     bool,
	no_gate:    bool,
}

// Ein Remote-Teilnehmer (ssrc): Jitter-Buffer + Decoder + UI-Pegel.
Stream :: struct {
	dec:   Decoder,
	jb:    Jitter,
	level: f32,
}

Engine :: struct {
	dev:        ma.device,
	dev_ok:     bool,
	tx:         Processor,
	cap_ring:   Ring,
	play_ring:  Ring,
	worker:     ^thread.Thread,
	running:    bool, // atomar
	muted:      bool,
	// Mikrofontest: fertige Opus-Pakete werden lokal wieder eingespeist
	// statt gesendet — man hört sich selbst, ins Netz geht GAR NICHTS.
	loopback:   bool,
	loop_seq:   u64, // nur Worker
	on_packet:  Packet_Proc, // läuft im Worker-Thread!
	user:       rawptr,

	streams_mu: sync.Mutex,
	streams:    map[u32]^Stream,

	blips_mu:   sync.Mutex,
	blips:      [dynamic]Blip,

	// UI-Messwerte (Worker schreibt, UI liest — f32-Reads sind hier unkritisch)
	mic_level:  f32,
	mic_vad:    f32,
}

Blip :: struct {
	data: []f32,
	pos:  int,
}

@(private = "file")
engine_data_cb :: proc "c" (dev: ^ma.device, out_, in_: rawptr, frame_count: u32) {
	context = runtime.default_context()
	e := (^Engine)(dev.pUserData)
	n := int(frame_count)
	if in_ != nil {
		ring_write(&e.cap_ring, ([^]f32)(in_)[:n])
	}
	if out_ != nil {
		buf := ([^]f32)(out_)[:n]
		got := ring_read(&e.play_ring, buf)
		for i in got ..< n {
			buf[i] = 0 // Unterlauf → Stille statt Müll
		}
	}
}

// Duplex-Gerät nach Wunschnamen öffnen; unbekannte/verschwundene Geräte
// fallen still auf den Systemstandard zurück.
@(private = "file")
engine_device_init :: proc(e: ^Engine, mic_name, out_name: string) -> bool {
	cfg := ma.device_config_init(.duplex)
	cfg.sampleRate = SAMPLE_RATE
	cfg.periodSizeInFrames = FRAME_10MS
	cfg.capture.format = .f32
	cfg.capture.channels = 1
	cfg.playback.format = .f32
	cfg.playback.channels = 1
	cfg.dataCallback = engine_data_cb
	cfg.pUserData = e

	mic_id, out_id: ma.device_id
	have_mic, have_out := resolve_device_ids(mic_name, out_name, &mic_id, &out_id)
	if have_mic {
		cfg.capture.pDeviceID = &mic_id
	}
	if have_out {
		cfg.playback.pDeviceID = &out_id
	}
	if ma.device_init(nil, &cfg, &e.dev) != .SUCCESS {
		if !have_mic && !have_out {
			return false
		}
		// Wunschgerät nicht mehr initialisierbar → Systemstandard
		cfg.capture.pDeviceID = nil
		cfg.playback.pDeviceID = nil
		if ma.device_init(nil, &cfg, &e.dev) != .SUCCESS {
			return false
		}
	}
	if ma.device_start(&e.dev) != .SUCCESS {
		ma.device_uninit(&e.dev)
		return false
	}
	e.dev_ok = true
	return true
}

engine_start :: proc(e: ^Engine, on_packet: Packet_Proc, user: rawptr, opts: Engine_Options) -> bool {
	e^ = {}
	if !processor_init(&e.tx) {
		return false
	}
	engine_set_dsp(e, !opts.no_denoise, !opts.no_aec, !opts.no_gate)
	ring_init(&e.cap_ring, RING_CAP)
	ring_init(&e.play_ring, RING_CAP)
	e.streams = make(map[u32]^Stream)
	e.on_packet = on_packet
	e.user = user

	if !engine_device_init(e, opts.mic_name, opts.out_name) {
		engine_cleanup(e)
		return false
	}

	sync.atomic_store(&e.running, true)
	e.worker = thread.create(engine_worker)
	e.worker.data = e
	thread.start(e.worker)
	return true
}

// DSP-Schalter zur Laufzeit (Settings-Toggles). Einfache bool-Schreiber —
// der Worker liest sie pro Frame, ein Versatz von einem Frame ist egal.
engine_set_dsp :: proc(e: ^Engine, denoise, aec, gate: bool) {
	e.tx.denoise_on = denoise
	e.tx.aec_on = aec
	e.tx.gate_on = gate
}

// Geräte im laufenden Betrieb wechseln: nur das miniaudio-Device wird
// getauscht, Worker/Streams/Jitter laufen weiter (kurze Stille beim Swap).
engine_set_devices :: proc(e: ^Engine, mic_name, out_name: string) -> bool {
	if !e.dev_ok {
		return false
	}
	ma.device_uninit(&e.dev)
	e.dev_ok = false
	return engine_device_init(e, mic_name, out_name)
}

engine_stop :: proc(e: ^Engine) {
	if e.worker != nil {
		sync.atomic_store(&e.running, false)
		thread.join(e.worker)
		thread.destroy(e.worker)
		e.worker = nil
	}
	if e.dev_ok {
		ma.device_uninit(&e.dev)
		e.dev_ok = false
	}
	engine_cleanup(e)
}

@(private = "file")
engine_cleanup :: proc(e: ^Engine) {
	processor_destroy(&e.tx)
	ring_destroy(&e.cap_ring)
	ring_destroy(&e.play_ring)
	// Unter Lock: der UDP-recv-Thread des Clients könnte parallel noch ein
	// letztes Paket pushen — er sieht danach die nil-Map und tut nichts.
	sync.lock(&e.streams_mu)
	for _, s in e.streams {
		decoder_destroy(&s.dec)
		free(s)
	}
	delete(e.streams)
	e.streams = nil
	sync.unlock(&e.streams_mu)
	for b in e.blips {
		delete(b.data)
	}
	delete(e.blips)
	e.blips = nil
}

// Empfangenes (bereits entschlüsseltes) Opus-Paket einsortieren.
// Threadsicher — wird vom Netzwerk-Thread gerufen.
engine_push_audio :: proc(e: ^Engine, ssrc: u32, seq: u64, payload: []byte) {
	sync.lock(&e.streams_mu)
	defer sync.unlock(&e.streams_mu)
	if e.streams == nil {
		return // Engine ist (gerade) gestoppt
	}
	s, exists := e.streams[ssrc]
	if !exists {
		s = new(Stream)
		if !decoder_init(&s.dec) {
			free(s)
			return
		}
		jitter_init(&s.jb)
		e.streams[ssrc] = s
	}
	jitter_push(&s.jb, seq, payload)
}

// Streams entsorgen, deren ssrc nicht mehr im Call ist.
engine_sync_streams :: proc(e: ^Engine, keep: []u32) {
	sync.lock(&e.streams_mu)
	defer sync.unlock(&e.streams_mu)
	drop := make([dynamic]u32, context.temp_allocator)
	outer: for ssrc, s in e.streams {
		if ssrc == LOOPBACK_SSRC && e.loopback {
			continue // Selbsttest läuft — den eigenen Stream behalten
		}
		for k in keep {
			if k == ssrc {
				continue outer
			}
		}
		decoder_destroy(&s.dec)
		free(s)
		append(&drop, ssrc)
	}
	for ssrc in drop {
		delete_key(&e.streams, ssrc)
	}
}

// Mikrofontest an/aus. Beim Ausschalten wird der Loopback-Stream sofort
// entsorgt (Decoder-Zustand, Pegel) — ein durch Race noch nachgeschobenes
// Paket legt höchstens eine stumme Leiche an, die der nächste
// engine_sync_streams wieder abräumt.
engine_set_loopback :: proc(e: ^Engine, on: bool) {
	e.loopback = on
	if on {
		return
	}
	sync.lock(&e.streams_mu)
	defer sync.unlock(&e.streams_mu)
	if e.streams == nil {
		return
	}
	if s, ok := e.streams[LOOPBACK_SSRC]; ok {
		decoder_destroy(&s.dec)
		free(s)
		delete_key(&e.streams, LOOPBACK_SSRC)
	}
}

// Aktueller Ausgabe-Pegel eines Teilnehmers (Speaking-Glow).
engine_stream_level :: proc(e: ^Engine, ssrc: u32) -> f32 {
	sync.lock(&e.streams_mu)
	defer sync.unlock(&e.streams_mu)
	if s, exists := e.streams[ssrc]; exists {
		return s.level
	}
	return 0
}

// Beliebiges Mono-PCM (48 kHz, ±1) in den Ausgabe-Mix legen (Testton).
// Übernimmt die Ownership — der Slice wird nach dem Abspielen freigegeben.
engine_play_pcm :: proc(e: ^Engine, data: []f32) {
	sync.lock(&e.blips_mu)
	append(&e.blips, Blip{data, 0})
	sync.unlock(&e.blips_mu)
}

// Kurzer Zweiklang: up = Beitritt (aufwärts), sonst Abschied (abwärts).
engine_blip :: proc(e: ^Engine, up: bool) {
	dur := SAMPLE_RATE * 18 / 100 // 180 ms
	d := make([]f32, dur)
	f1: f32 = up ? 523.25 : 783.99 // C5 ↔ G5
	f2: f32 = up ? 783.99 : 523.25
	phase: f32
	for i in 0 ..< dur {
		half := dur / 2
		f := i < half ? f1 : f2
		t := f32(i % half) / f32(half)
		env := min(t * 25, 1) * math.exp(-t * 4)
		phase += 2 * math.PI * f / SAMPLE_RATE
		d[i] = math.sin(phase) * env * 0.16
	}
	engine_play_pcm(e, d)
}

@(private = "file")
engine_mix_blips :: proc(e: ^Engine, mix: []f32) {
	sync.lock(&e.blips_mu)
	defer sync.unlock(&e.blips_mu)
	for i := 0; i < len(e.blips); {
		b := &e.blips[i]
		n := min(len(mix), len(b.data) - b.pos)
		for j in 0 ..< n {
			mix[j] += b.data[b.pos + j]
		}
		b.pos += n
		if b.pos >= len(b.data) {
			delete(b.data)
			ordered_remove(&e.blips, i)
		} else {
			i += 1
		}
	}
}

@(private = "file")
engine_worker :: proc(t: ^thread.Thread) {
	e := (^Engine)(t.data)
	cap_frame: [FRAME_10MS]f32
	mix: [FRAME_20MS]f32
	tmp: [FRAME_20MS]f32
	pkt: [MAX_PAYLOAD]byte

	for sync.atomic_load(&e.running) {
		// 1) Mikrofon: 10-ms-Frames durch die Sende-Pipeline schieben.
		for ring_fill(&e.cap_ring) >= FRAME_10MS {
			ring_read(&e.cap_ring, cap_frame[:])
			n := processor_push_capture(&e.tx, cap_frame[:], pkt[:])
			e.mic_level = e.tx.level
			e.mic_vad = e.tx.vad
			if n > 0 {
				if e.loopback {
					// Selbsttest: Paket lokal wieder einspeisen, NICHTS senden
					e.loop_seq += 1
					engine_push_audio(e, LOOPBACK_SSRC, e.loop_seq, pkt[:n])
				} else if !e.muted && e.on_packet != nil {
					e.on_packet(e.user, pkt[:n])
				}
			}
		}

		// 2) Playback-Ring auf Ziel-Vorlauf halten (20-ms-Schritte).
		for ring_fill(&e.play_ring) < PLAY_TARGET {
			mix = {}
			sync.lock(&e.streams_mu)
			for _, s in e.streams {
				res := jitter_pull(&s.jb, &s.dec, tmp[:])
				if res != .Silence {
					sum: f32
					for v, j in tmp {
						mix[j] += v
						sum += v * v
					}
					s.level = math.lerp(s.level, math.sqrt(sum / FRAME_20MS), f32(0.5))
				} else {
					s.level *= 0.75
				}
			}
			sync.unlock(&e.streams_mu)
			engine_mix_blips(e, mix[:])
			for &v in mix {
				v = clamp(v, -1, 1)
			}
			// Gemischtes Signal ist die AEC-Referenz (2 × 10 ms).
			processor_feed_playback(&e.tx, mix[:FRAME_10MS])
			processor_feed_playback(&e.tx, mix[FRAME_10MS:])
			ring_write(&e.play_ring, mix[:])
		}

		time.sleep(3 * time.Millisecond)
	}
}
