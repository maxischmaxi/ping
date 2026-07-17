package audio

// Geräte-Verwaltung (miniaudio): Auflisten der Ein-/Ausgabegeräte fürs
// Settings-Menü, Auflösen gespeicherter Gerätenamen zu Device-IDs beim
// Engine-Start und ein kleiner Playback-Only-Player für den
// Lautsprecher-Testton.
//
// Geräte werden per NAME persistiert (IDs sind backend-spezifisch und
// überleben kein Umstecken) — ist der Name beim Start nicht mehr da,
// fällt alles auf den Systemstandard zurück.

import "base:runtime"
import "core:math"
import "core:strings"

import ma "vendor:miniaudio"

Device :: struct {
	name:       string,
	is_default: bool,
}

// Alle Wiedergabe-/Aufnahmegeräte auflisten. Die Namen sind mit `allocator`
// alloziert — devices_free räumt wieder auf.
list_devices :: proc(allocator := context.allocator) -> (playback: []Device, capture: []Device, ok: bool) {
	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		return
	}
	defer ma.context_uninit(&ctx)

	pinfos, cinfos: [^]ma.device_info
	pn, cn: u32
	if ma.context_get_devices(&ctx, &pinfos, &pn, &cinfos, &cn) != .SUCCESS {
		return
	}

	pb := make([dynamic]Device, 0, int(pn), allocator)
	for i in 0 ..< int(pn) {
		info := &pinfos[i]
		append(&pb, Device{
			name       = strings.clone(string(cstring(raw_data(info.name[:]))), allocator),
			is_default = bool(info.isDefault),
		})
	}
	cp := make([dynamic]Device, 0, int(cn), allocator)
	for i in 0 ..< int(cn) {
		info := &cinfos[i]
		append(&cp, Device{
			name       = strings.clone(string(cstring(raw_data(info.name[:]))), allocator),
			is_default = bool(info.isDefault),
		})
	}
	return pb[:], cp[:], true
}

devices_free :: proc(playback, capture: []Device, allocator := context.allocator) {
	for d in playback {
		delete(d.name, allocator)
	}
	for d in capture {
		delete(d.name, allocator)
	}
	delete(playback, allocator)
	delete(capture, allocator)
}

// Gespeicherte Gerätenamen zu IDs auflösen ("" oder unbekannt → Standard).
// Die IDs sind reine Wertkopien — der Enumerations-Kontext darf danach weg.
resolve_device_ids :: proc(mic_name, out_name: string, mic_id, out_id: ^ma.device_id) -> (have_mic, have_out: bool) {
	if mic_name == "" && out_name == "" {
		return
	}
	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		return
	}
	defer ma.context_uninit(&ctx)

	pinfos, cinfos: [^]ma.device_info
	pn, cn: u32
	if ma.context_get_devices(&ctx, &pinfos, &pn, &cinfos, &cn) != .SUCCESS {
		return
	}
	if mic_name != "" {
		for i in 0 ..< int(cn) {
			if string(cstring(raw_data(cinfos[i].name[:]))) == mic_name {
				mic_id^ = cinfos[i].id
				have_mic = true
				break
			}
		}
	}
	if out_name != "" {
		for i in 0 ..< int(pn) {
			if string(cstring(raw_data(pinfos[i].name[:]))) == out_name {
				out_id^ = pinfos[i].id
				have_out = true
				break
			}
		}
	}
	return
}

// ---------- Lautsprecher-Testton ----------

// Kleiner Playback-Only-Player: spielt einen freundlichen Dreiklang und
// bleibt danach still. Der Main-Thread pollt tone_playing und räumt mit
// tone_stop auf (Stop/Uninit nie aus dem Callback!).
Tone :: struct {
	dev:    ma.device,
	dev_ok: bool,
	data:   []f32,
	pos:    int, // nur der Audio-Callback schreibt; Main liest (Anzeige)
}

@(private = "file")
tone_data_cb :: proc "c" (dev: ^ma.device, out_, in_: rawptr, frame_count: u32) {
	context = runtime.default_context()
	t := (^Tone)(dev.pUserData)
	if out_ == nil {
		return
	}
	buf := ([^]f32)(out_)[:int(frame_count)]
	for &s in buf {
		if t.pos < len(t.data) {
			s = t.data[t.pos]
			t.pos += 1
		} else {
			s = 0
		}
	}
}

// Der Testton als Mono-PCM: C5 → E5 → G5, je ~0,3 s mit weicher Hüllkurve.
// Auch für engine_play_pcm nutzbar (Testton im laufenden Call-Mix).
tone_pcm :: proc(allocator := context.allocator) -> []f32 {
	dur := SAMPLE_RATE * 9 / 10
	seg := dur / 3
	d := make([]f32, dur, allocator)
	freqs := [3]f32{523.25, 659.25, 783.99}
	phase: f32
	for i in 0 ..< dur {
		s := min(i / seg, 2)
		u := f32(i % seg) / f32(seg)
		env := min(u * 18, 1) * math.exp(-u * 3.2)
		phase += 2 * math.PI * freqs[s] / SAMPLE_RATE
		d[i] = math.sin(phase) * env * 0.22
	}
	return d
}

// Testton starten (out_name = "" → Standardgerät). Ein laufender Ton wird
// neu gestartet.
tone_start :: proc(t: ^Tone, out_name: string) -> bool {
	tone_stop(t)
	t.data = tone_pcm()

	cfg := ma.device_config_init(.playback)
	cfg.sampleRate = SAMPLE_RATE
	cfg.periodSizeInFrames = FRAME_10MS
	cfg.playback.format = .f32
	cfg.playback.channels = 1
	cfg.dataCallback = tone_data_cb
	cfg.pUserData = t

	out_id: ma.device_id
	if _, have := resolve_device_ids("", out_name, nil, &out_id); have {
		cfg.playback.pDeviceID = &out_id
	}
	if ma.device_init(nil, &cfg, &t.dev) != .SUCCESS {
		delete(t.data)
		t.data = nil
		return false
	}
	if ma.device_start(&t.dev) != .SUCCESS {
		ma.device_uninit(&t.dev)
		delete(t.data)
		t.data = nil
		return false
	}
	t.dev_ok = true
	return true
}

tone_playing :: proc(t: ^Tone) -> bool {
	return t.dev_ok && t.pos < len(t.data)
}

tone_stop :: proc(t: ^Tone) {
	if t.dev_ok {
		ma.device_uninit(&t.dev)
		t.dev_ok = false
	}
	if t.data != nil {
		delete(t.data)
		t.data = nil
	}
	t.pos = 0
}
