package main

// App-Einstellungen als Dialog: Audio-Geräte (Mikrofon/Lautsprecher),
// Verarbeitungs-Schalter (Rauschunterdrückung, Echo, Sende-Gate) und ein
// Selbsttest. Der Mikrofontest schickt das eigene Signal durch die ECHTE
// Sende-Pipeline (AEC → RNNoise → Gate → Opus → Decode → Jitter-Puffer) und
// spielt es lokal ab — man hört sich exakt so, wie andere einen hören.

import "core:fmt"
import "core:strings"

import rl "vendor:raylib"
import audio "../audio"

open_settings :: proc(app: ^App) {
	if app.modal == .Settings {
		return
	}
	settings_refresh_devices(app)
	scroll_to(&app.set_scroll, 0)
	open_modal(app, .Settings)
}

@(private = "file")
settings_refresh_devices :: proc(app: ^App) {
	settings_free_devices(app)
	out, mic, _ := audio.list_devices()
	app.set_devices_out = out
	app.set_devices_mic = mic
}

@(private = "file")
settings_free_devices :: proc(app: ^App) {
	audio.devices_free(app.set_devices_out, app.set_devices_mic)
	app.set_devices_out = nil
	app.set_devices_mic = nil
}

// --- Test-Mute: solange ein Test im Call läuft, sind wir für die anderen
// stummgeschaltet; der vorherige Zustand kommt danach zurück. Eine
// manuelle Mute-Änderung des Users hebt die Automatik auf (kein Restore).

@(private = "file")
test_mute_begin :: proc(app: ^App) {
	if !app.call.active || app.test_muting {
		return
	}
	app.test_restore_mute = app.call.muted
	app.test_muting = true
	call_set_mute(app, true)
}

// Zurücknehmen, sobald KEIN Test mehr läuft.
@(private = "file")
test_mute_end :: proc(app: ^App) {
	if !app.test_muting || app.mic_test_call || app.spk_test_until != 0 {
		return
	}
	app.test_muting = false
	if app.call.active {
		call_set_mute(app, app.test_restore_mute)
	}
}

// Auch call_join ruft das (Geräte freigeben, bevor der Call sie öffnet).
settings_mic_test_stop :: proc(app: ^App) {
	if !app.mic_test {
		return
	}
	app.mic_test = false
	if app.mic_test_call {
		app.mic_test_call = false
		if app.call.active {
			audio.engine_set_loopback(&app.call.engine, false)
		}
		test_mute_end(app)
		return
	}
	audio.engine_stop(&app.test_engine)
}

@(private = "file")
settings_mic_test_start :: proc(app: ^App) {
	if app.mic_test {
		return
	}
	audio.tone_stop(&app.spk_tone)
	if app.call.active {
		// Im Call: Loopback direkt in der Call-Engine — es wird garantiert
		// NICHTS gesendet, zusätzlich sind wir für die anderen gemutet.
		audio.engine_set_loopback(&app.call.engine, true)
		app.mic_test = true
		app.mic_test_call = true
		test_mute_begin(app)
		return
	}
	if !audio.engine_start(&app.test_engine, nil, nil, audio_opts(&app.cfg)) {
		toast(app, .Error, "Kein Audiogerät verfügbar")
		return
	}
	audio.engine_set_loopback(&app.test_engine, true)
	app.mic_test = true
}

// Der Call ist weg (Auflegen/Teardown/Wechsel) → Test-Zustände lösen.
settings_call_ended :: proc(app: ^App) {
	if app.mic_test_call {
		app.mic_test = false
		app.mic_test_call = false
	}
	app.test_muting = false
	app.spk_test_until = 0
}

// Pro Frame (app_poll): Ausgabetest-Ende erkennen, Ton-Gerät freigeben.
settings_test_tick :: proc(app: ^App) {
	if app.spk_test_until != 0 && mono_ms() >= app.spk_test_until {
		app.spk_test_until = 0
		test_mute_end(app)
	}
	if app.spk_tone.dev_ok && !audio.tone_playing(&app.spk_tone) {
		audio.tone_stop(&app.spk_tone)
	}
}

// Beim Schließen des Dialogs: Tests stoppen, Gerätelisten freigeben.
settings_on_close :: proc(app: ^App) {
	settings_mic_test_stop(app)
	audio.tone_stop(&app.spk_tone)
	settings_free_devices(app)
	app.set_dd = 0
}

// Geänderte Geräte sofort auf laufende Engines anwenden.
@(private = "file")
settings_apply_devices :: proc(app: ^App) {
	if app.call.active {
		if !audio.engine_set_devices(&app.call.engine, app.cfg.audio_mic, app.cfg.audio_out) {
			toast(app, .Error, "Gerätewechsel fehlgeschlagen — Call neu beitreten")
		}
	}
	if app.mic_test && !app.mic_test_call {
		if !audio.engine_set_devices(&app.test_engine, app.cfg.audio_mic, app.cfg.audio_out) {
			settings_mic_test_stop(app)
		}
	}
}

@(private = "file")
settings_apply_dsp :: proc(app: ^App) {
	if app.call.active {
		audio.engine_set_dsp(&app.call.engine, !app.cfg.denoise_off, !app.cfg.aec_off, !app.cfg.gate_off)
	}
	if app.mic_test && !app.mic_test_call {
		audio.engine_set_dsp(&app.test_engine, !app.cfg.denoise_off, !app.cfg.aec_off, !app.cfg.gate_off)
	}
}

@(private = "file")
device_label :: proc(name: string) -> string {
	return name == "" ? "Systemstandard" : name
}

// Dropdown-Feld (die Liste selbst zeichnet draw_settings_modal am Ende,
// damit sie über den restlichen Widgets liegt).
@(private = "file")
dd_field :: proc(app: ^App, r: rl.Rectangle, label: string, open: bool, which: int) {
	id := anim_id(.Misc, 0xDD00 ~ (u64(which) << 32))
	hovered := ui_hover(&app.ui, r, .Modal)
	focused := tab_stop(app, id, r, .Modal, radius = RADIUS_INPUT)
	t := anim_to(app, id, (open || hovered || focused) ? 1 : 0, 18)
	rrect(r, RADIUS_INPUT, COL_SURFACE)
	rrect_lines(r, RADIUS_INPUT, open ? 1.6 : 1, mix(COL_BORDER, COL_ACCENT, open ? 1 : t*0.35))
	if focused {
		draw_focus_ring(r, RADIUS_INPUT)
	}
	draw_text(app.fonts.regular15, tcstr(trim_label(app, app.fonts.regular15, 15, label, r.width - 44)),
		{r.x + 12, r.y + (r.height - 15)/2 - 1}, 15, 0, COL_TEXT)

	// Chevron (klappt bei offener Liste nach oben)
	cx := r.x + r.width - 20
	cy := r.y + r.height/2
	d: f32 = open ? -3 : 3
	rl.DrawLineEx({cx - 5, cy - d/2 - 1}, {cx, cy + d/2 + 1}, 1.8, COL_TEXT_DIM)
	rl.DrawLineEx({cx, cy + d/2 + 1}, {cx + 5, cy - d/2 - 1}, 1.8, COL_TEXT_DIM)

	if hovered {
		app.ui.cursor = .POINTING_HAND
	}
	if ui_click(&app.ui, r, .Modal) || (focused && app.ui.tab_activate) {
		app.set_dd = open ? 0 : which
		// Der Öffnungs-Klick darf die Liste nicht im selben Frame schließen
		app.ui.clicked = false
	}
}

// Aufgeklappte Geräteliste unterhalb des Ankers. Auswahl wird geklont
// (die Gerätelisten werden beim Schließen freigegeben!).
@(private = "file")
settings_dd_list :: proc(app: ^App, sh: f32, anchor: rl.Rectangle, devices: []audio.Device, sel: ^string) {
	row_h := f32(34)
	fit := max(int((sh - anchor.y - anchor.height - 26) / row_h), 3)
	n := min(len(devices) + 1, fit)
	clipped := len(devices) + 1 > n

	h := f32(n)*row_h + 12 + (clipped ? 20 : 0)
	p := rl.Rectangle{anchor.x, anchor.y + anchor.height + 6, anchor.width, h}
	draw_shadow(p, 10, 0.5)
	rrect(p, 10, COL_SURFACE)
	rrect_lines(p, 10, 1, COL_BORDER)

	iy := p.y + 6
	chosen := -2 // -2 = nichts, -1 = Systemstandard, sonst Geräte-Index
	for i in -1 ..< n - 1 {
		name := i < 0 ? "" : devices[i].name
		label := i < 0 ? "Systemstandard" : devices[i].name
		if i >= 0 && devices[i].is_default {
			label = fmt.tprintf("%s · Standard", label)
		}
		ir := rl.Rectangle{p.x + 6, iy, p.width - 12, row_h}
		if ui_hover(&app.ui, ir, .Modal) {
			rrect(ir, 6, COL_SIDEBAR_HOVER)
			app.ui.cursor = .POINTING_HAND
		}
		draw_text(app.fonts.regular15, tcstr(trim_label(app, app.fonts.regular15, 15, label, ir.width - 40)),
			{ir.x + 10, iy + (row_h - 15)/2 - 1}, 15, 0, COL_TEXT)
		if sel^ == name {
			draw_check(ir.x + ir.width - 18, iy + row_h/2, 11, 1.8, COL_ACCENT)
		}
		if ui_click(&app.ui, ir, .Modal) {
			chosen = i
		}
		iy += row_h
	}
	if clipped {
		draw_text(app.fonts.regular13, tcstr(fmt.tprintf("… %d weitere Geräte", len(devices) + 1 - n)),
			{p.x + 16, iy + 2}, 13, 0, COL_TEXT_FAINT)
	}

	if chosen > -2 {
		name := chosen < 0 ? "" : devices[chosen].name
		if sel^ != name {
			sel^ = strings.clone(name)
			config_save(&app.cfg)
			settings_apply_devices(app)
		}
		app.set_dd = 0
		app.ui.clicked = false
	} else if app.ui.clicked && !rl.CheckCollisionPointRec(app.ui.mouse, p) {
		app.set_dd = 0 // Klick außerhalb schließt nur die Liste
	}
}

// Eine Zeile „Titel + Beschreibung + Schalter“. Gibt die Zeilenhöhe zurück.
@(private = "file")
toggle_row :: proc(app: ^App, x, y, w: f32, title, desc: string, value: ^bool, invert: bool, id: u64) -> f32 {
	draw_text(app.fonts.regular15, tcstr(title), {x, y + 2}, 15, 0, COL_TEXT)
	draw_text(app.fonts.regular13, tcstr(trim_label(app, app.fonts.regular13, 13, desc, w - 64)),
		{x, y + 22}, 13, 0, COL_TEXT_FAINT)
	on := invert ? !value^ : value^
	if toggle_switch(app, {x + w - 46, y + 4, 46, 26}, anim_id(.Misc, 0x70661E ~ (id << 32)), on, .Modal) {
		value^ = !value^
		config_save(&app.cfg)
		settings_apply_dsp(app)
	}
	return 46
}

draw_settings_modal :: proc(app: ^App, c: ^Server_Conn, sw, sh: f32) {
	h := min(f32(680), sh - 40)
	p := modal_frame(app, sw, sh, 560, h, "Einstellungen")

	x := p.x + 24
	w := p.width - 48

	// Inhalt scrollt zwischen Titel und Fußzeile (der Dialog ist höher als
	// kleine Fenster). Die Inhaltshöhe stammt aus dem letzten Frame.
	view := rl.Rectangle{p.x, p.y + 48, p.width, p.height - 48 - 62}
	scroll_update(app, &app.set_scroll, ui_hover(&app.ui, view, .Modal),
		max(0, app.set_content_h - view.height), 44)

	// Offenes Dropdown → Klicks auf die darunterliegenden Widgets abschirmen
	// (die Liste zeichnet und klickt am Ende dieses Frames).
	shield := app.set_dd != 0
	saved_click := app.ui.clicked
	if shield {
		app.ui.clicked = false
	}

	scissor_begin(view.x, view.y, view.width, view.height)
	y := view.y + 4 - app.set_scroll.pos
	content_top := y

	y += draw_settings_profile(app, c, x, y, w)
	y += 18

	draw_text(app.fonts.bold13, "AUDIO", {x, y}, 13, 0, COL_TEXT_FAINT)
	y += 22

	draw_text(app.fonts.regular13, "Mikrofon", {x, y}, 13, 0, COL_TEXT_DIM)
	mic_r := rl.Rectangle{x, y + 16, w, 36}
	dd_field(app, mic_r, device_label(app.cfg.audio_mic), app.set_dd == 1, 1)
	y += 60

	draw_text(app.fonts.regular13, "Lautsprecher", {x, y}, 13, 0, COL_TEXT_DIM)
	out_r := rl.Rectangle{x, y + 16, w, 36}
	dd_field(app, out_r, device_label(app.cfg.audio_out), app.set_dd == 2, 2)
	y += 64

	y += toggle_row(app, x, y, w, "Rauschunterdrückung",
		"Filtert Tastatur, Lüfter & Co. aus deinem Mikrofon (RNNoise)",
		&app.cfg.denoise_off, true, 1)
	y += toggle_row(app, x, y, w, "Echo-Unterdrückung",
		"Verhindert, dass dein Lautsprecher-Ton zurück in den Call gelangt",
		&app.cfg.aec_off, true, 2)
	y += toggle_row(app, x, y, w, "Nur bei Sprache senden",
		"Sende-Gate: In Stille wird gar nichts übertragen",
		&app.cfg.gate_off, true, 3)

	y += 8
	draw_text(app.fonts.bold13, "AUDIO-TEST", {x, y}, 13, 0, COL_TEXT_FAINT)
	y += 22

	// --- Mikrofontest (Loopback durch die echte Sende-Pipeline; im Call
	// über die Call-Engine — dabei automatisch stummgeschaltet) ---
	{
		if button(app, {x, y, 168, 36}, app.mic_test ? "Test beenden" : "Mikrofon testen", .Modal,
			style = app.mic_test ? .Danger : .Default, id_salt = 0x77E57) {
			if app.mic_test {
				settings_mic_test_stop(app)
			} else {
				settings_mic_test_start(app)
			}
		}
		// Pegel-Meter + Sprach-Anzeige (Quelle: Call- oder Test-Engine)
		te := app.mic_test_call ? &app.call.engine : &app.test_engine
		mr := rl.Rectangle{x + 184, y + 14, w - 184 - 120, 8}
		rrect(mr, 4, fade(COL_OVERLAY, 0.12))
		if app.mic_test {
			lvl := clamp(te.mic_level * 7, 0, 1)
			sm := anim_to(app, anim_id(.Misc, 0x3E7EB), lvl, 18)
			rrect({mr.x, mr.y, mr.width * sm, 8}, 4, COL_ONLINE)
			speaking := te.mic_vad > 0.5
			st := anim_to(app, anim_id(.Misc, 0x3E7EC), speaking ? 1 : 0, 12)
			rl.DrawCircleV({mr.x + mr.width + 14, y + 18}, 3.5, mix(COL_TEXT_FAINT, COL_ONLINE, st))
			draw_text(app.fonts.regular13, "Sprache", {mr.x + mr.width + 24, y + 12}, 13, 0,
				mix(COL_TEXT_FAINT, COL_TEXT, st))
		}
		y += 44
		hint := "Der Test spielt dein Mikrofon zurück, inkl. Rauschunterdrückung und Opus-Codec."
		if app.mic_test {
			hint = "Sprich etwas — du hörst dich so, wie andere dich hören würden."
			if app.mic_test_call {
				hint = "Du bist stummgeschaltet, solange der Test läuft — die anderen hören nichts."
			}
		} else if app.call.active {
			hint = "Auch im Call möglich: Du wirst dabei automatisch stummgeschaltet."
		}
		draw_text(app.fonts.regular13, tcstr(trim_label(app, app.fonts.regular13, 13, hint, w)),
			{x, y}, 13, 0, COL_TEXT_FAINT)
		y += 28
	}

	// --- Lautsprechertest ---
	playing := audio.tone_playing(&app.spk_tone) || app.spk_test_until != 0
	if button(app, {x, y, 168, 36}, playing ? "Spielt…" : "Testton abspielen", .Modal, id_salt = 0x70E7) && !playing {
		if app.call.active && !app.mic_test_call {
			// In den Call-Mix — dabei stummgeschaltet, damit die anderen
			// den Ton nicht übers Mikrofon hören.
			pcm := audio.tone_pcm()
			app.spk_test_until = mono_ms() + i64(len(pcm)) * 1000 / audio.SAMPLE_RATE + 300
			audio.engine_play_pcm(&app.call.engine, pcm)
			test_mute_begin(app)
		} else if app.mic_test {
			te := app.mic_test_call ? &app.call.engine : &app.test_engine
			audio.engine_play_pcm(te, audio.tone_pcm())
		} else if !audio.tone_start(&app.spk_tone, app.cfg.audio_out) {
			toast(app, .Error, "Kein Wiedergabegerät verfügbar")
		}
	}
	spk_hint := "Spielt einen kurzen Klang über den gewählten Lautsprecher."
	if app.call.active {
		spk_hint = "Spielt einen kurzen Klang — du bist währenddessen stummgeschaltet."
	}
	draw_text(app.fonts.regular13, tcstr(trim_label(app, app.fonts.regular13, 13, spk_hint, w - 184)),
		{x + 184, y + 11}, 13, 0, COL_TEXT_FAINT)
	y += 40

	app.set_content_h = y - content_top
	scissor_end()
	scrollbar(app, view, app.set_content_h, &app.set_scroll, .Modal)

	// Fußzeile: Hairline + Schließen
	rl.DrawLineEx({p.x + 1, p.y + h - 62}, {p.x + p.width - 1, p.y + h - 62}, 1, COL_BORDER_SOFT)
	if button(app, {p.x + p.width - 136, p.y + h - 50, 112, 36}, "Schließen", .Modal, id_salt = 0xC105E) {
		close_modal(app)
	}

	if shield {
		app.ui.clicked = saved_click
	}

	// Offenes Dropdown über allem zeichnen
	if app.set_dd == 1 {
		settings_dd_list(app, sh, mic_r, app.set_devices_mic, &app.cfg.audio_mic)
	} else if app.set_dd == 2 {
		settings_dd_list(app, sh, out_r, app.set_devices_out, &app.cfg.audio_out)
	}
}
