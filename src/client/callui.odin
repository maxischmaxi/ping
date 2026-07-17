package main

// Call-UI: Top-Leiste unter der Titelleiste, Chat-Karte der Call-System-
// nachricht, Header-Button, Channel-Banner, Call-Panel (Sidebar) und das
// ausgliederbare Popout-Panel. Der Call lebt auf App-Ebene — er läuft
// weiter, egal welcher Channel oder Server gerade angezeigt wird.

import "core:fmt"
import "core:math"

import rl "vendor:raylib"
import shared "../shared"

CALL_BAR_H :: f32(46)
CALL_CARD_H :: f32(64)
CALL_PANEL_H :: f32(150)
CALL_POPOUT_W :: f32(320)
CALL_POPOUT_H :: f32(132)

// --- Gemeinsame Helfer ---

// Label auf verfügbare Breite kürzen („…“).
trim_label :: proc(app: ^App, font: rl.Font, size: f32, s: string, max_w: f32) -> string {
	if rl.MeasureTextEx(font, tcstr(s), size, 0).x <= max_w {
		return s
	}
	cut := len(s)
	for cut > 1 {
		cut -= 1
		for cut > 1 && s[cut] & 0xC0 == 0x80 { // nicht mitten im UTF-8-Zeichen
			cut -= 1
		}
		t := fmt.tprintf("%s…", s[:cut])
		if rl.MeasureTextEx(font, tcstr(t), size, 0).x <= max_w {
			return t
		}
	}
	return "…"
}

@(private = "file")
call_channel_title :: proc(app: ^App) -> string {
	cc := app.call.conn
	if cs := conn_find_channel(cc, app.call.channel_id); cs != nil {
		return channel_title(cc, cs)
	}
	return "Voice-Call"
}

// 0..1-Puls für „hier passiert gerade etwas“.
@(private = "file")
call_pulse :: proc() -> f32 {
	return f32(math.sin(rl.GetTime() * 4)) * 0.5 + 0.5
}

// Teilnehmer-Avatar mit Speaking-Ring + Mute-Badge + Tooltip.
@(private = "file")
draw_call_peer :: proc(app: ^App, c: ^Server_Conn, p: shared.Call_Peer, x, y, av: f32, id_salt: u64) {
	u := conn_find_user(c, p.user_id)
	seed := u != nil ? u.username : fmt.tprintf("%d", p.user_id)

	level := call_peer_level(app, p)
	glow := anim_to(app, anim_id(.Call, u64(p.ssrc) ~ id_salt ~ 0x910), level > 0.18 ? 1 : 0, 14, initial = 0)
	if glow > 0.02 {
		rl.DrawRing({x + av/2, y + av/2}, av/2 + 1.5, av/2 + 3.5, 0, 360, 32, fade(COL_ONLINE, glow))
	}
	draw_avatar(app, seed, x, y, av, c = c, uid = p.user_id)
	if p.muted {
		br := av * 0.24
		rl.DrawCircleV({x + av - br + 1, y + av - br + 1}, br + 1.5, COL_SURFACE)
		draw_mic(x + av - br + 1, y + av - br + 1, br + 1.5, 1.3, COL_RED, COL_SURFACE, true)
	}
	tooltip(app, anim_id(.Call, u64(p.ssrc) ~ id_salt ~ 0xA7A), {x, y, av, av}, user_label(c, p.user_id), .Base)
}

// --- Header-Button (Kopfhörer) im Channel-/DM-Header ---

draw_call_header_button :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, r: rl.Rectangle) {
	here := call_is_here(app, c, cs.ch.id)
	peers := channel_call_peers(c, cs.ch.id)
	live := len(peers) > 0

	hovered := ui_hover(&app.ui, r, .Base)
	focused := tab_stop(app, anim_id(.Call, cs.ch.id ~ 0xCA11), r, .Base, radius = 8)
	t := anim_to(app, anim_id(.Call, cs.ch.id ~ 0xCA11), (hovered || focused) ? 1 : 0)
	rrect(r, 8, fade(COL_OVERLAY, t * 0.07))
	if focused {
		draw_focus_ring(r, 8)
	}
	col := COL_TEXT_DIM
	if here {
		col = COL_ONLINE
	} else if live {
		// laufender Call, dem ich nicht angehöre → Accent mit sanftem Puls
		col = mix(COL_ACCENT, COL_TEXT, 0.25 * call_pulse())
	}
	draw_headphones(r.x + r.width/2, r.y + r.height/2 - 1, 8, 2.4, mix(col, COL_TEXT, t * 0.3))
	if hovered {
		app.ui.cursor = .POINTING_HAND
	}
	tip := "Voice-Call starten"
	if here {
		tip = "Du bist in diesem Call"
	} else if live {
		tip = fmt.tprintf("Call läuft (%d) — beitreten", len(peers))
	}
	tooltip(app, anim_id(.Call, cs.ch.id ~ 0x71F), r, tip, .Base)
	if (ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate)) && !here {
		call_join(app, c, cs.ch.id)
	}
}

// --- Banner unter dem Header: „Call läuft — beitreten“ ---

// Rückgabe: belegte Höhe (animiert ein/aus).
draw_call_banner :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, chat: rl.Rectangle) -> f32 {
	cc := c.calls[cs.ch.id]
	want := len(cc.peers) > 0 && !call_is_here(app, c, cs.ch.id)
	h := anim_to(app, anim_id(.Call, cs.ch.id ~ 0xBA22), want ? 46 : 0, 14, initial = 0)
	if h < 1 {
		return 0
	}
	r := rl.Rectangle{chat.x, chat.y + HEADER_H + 1, chat.width, h}
	scissor_begin(r.x, r.y, r.width, r.height)
	defer scissor_end()
	rl.DrawRectangleRec(r, fade(COL_ACCENT, 0.10))
	rl.DrawLineEx({r.x, r.y + h}, {r.x + r.width, r.y + h}, 1, COL_BORDER_SOFT)

	cy := r.y + h - 23 // Inhalt „fährt“ mit der Unterkante ein
	draw_headphones(r.x + 30, cy - 1, 8, 2.4, mix(COL_ACCENT, COL_TEXT, 0.3 * call_pulse()))

	label := len(cc.peers) == 1 ? "Voice-Call · 1 Teilnehmer" : fmt.tprintf("Voice-Call · %d Teilnehmer", len(cc.peers))
	if cc.started_ms > 0 {
		label = fmt.tprintf("%s · seit %s", label, format_duration((unix_now_ms() - cc.started_ms) / 1000))
	}
	draw_text(app.fonts.bold15, tcstr(label), {r.x + 48, cy - 8}, 15, 0, COL_TEXT)
	lw := rl.MeasureTextEx(app.fonts.bold15, tcstr(label), 15, 0).x

	// Teilnehmer-Avatare, gestapelt
	ax := r.x + 48 + lw + 14
	shown := min(len(cc.peers), 5)
	for i in 0 ..< shown {
		if u := conn_find_user(c, cc.peers[i].user_id); u != nil {
			rl.DrawCircleV({ax + 11, cy}, 13, fade(COL_ACCENT, 0.10))
			draw_avatar(app, u.username, ax, cy - 11, 22, c = c, uid = u.id)
			ax += 16
		}
	}

	// Beitreten-Button rechts
	bw := f32(104)
	br := rl.Rectangle{r.x + r.width - bw - 16, cy - 15, bw, 30}
	if button(app, br, app.call.joining ? "Verbinde…" : "Beitreten", .Base, style = .Primary) {
		call_join(app, c, cs.ch.id)
	}
	return h
}

// --- Chat-Karte der Call-Systemnachricht ---

// Zeichnet die Karte einer Call-Nachricht (m.call_start_ms > 0): läuft der
// Call noch, gibt es Teilnehmerzahl, Dauer und (für Außenstehende) einen
// Beitreten-Button; danach Zeitraum + Gesamtdauer.
draw_call_card :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, m: shared.Chat_Message, x, y, w: f32) {
	cw := clamp(w, 220, 460)
	r := rl.Rectangle{x, y, cw, CALL_CARD_H}

	cc, has := c.calls[m.channel_id]
	live := has && cc.msg_id == m.id && len(cc.peers) > 0
	here := live && call_is_here(app, c, m.channel_id)

	rrect(r, RADIUS_CARD, COL_SURFACE)
	rrect_lines(r, RADIUS_CARD, 1, live ? fade(COL_ONLINE, 0.5) : COL_BORDER)

	// Icon-Kreis links
	icx := r.x + 31
	icy := r.y + CALL_CARD_H/2
	if live {
		rl.DrawCircleV({icx, icy}, 19, fade(COL_ONLINE, 0.13 + 0.06*call_pulse()))
		draw_headphones(icx, icy - 1, 9, 2.6, COL_ONLINE)
	} else {
		rl.DrawCircleV({icx, icy}, 19, fade(COL_OVERLAY, 0.06))
		draw_headphones(icx, icy - 1, 9, 2.6, COL_TEXT_DIM)
	}

	// Rechte Seite: Beitreten-Button bzw. „Verbunden“-Status
	right := r.x + cw - 14
	if live && !here {
		bw := f32(100)
		br := rl.Rectangle{r.x + cw - bw - 14, r.y + (CALL_CARD_H - 32)/2, bw, 32}
		if button(app, br, app.call.joining ? "Verbinde…" : "Beitreten", .Base, style = .Primary, id_salt = m.id ~ 0xCA77) {
			call_join(app, c, m.channel_id)
		}
		right = br.x - 10
	} else if here {
		lbl := "Verbunden"
		lw := rl.MeasureTextEx(app.fonts.bold13, tcstr(lbl), 13, 0).x
		lx := r.x + cw - lw - 16
		rl.DrawCircleV({lx - 10, icy}, 3.5, COL_ONLINE)
		draw_text(app.fonts.bold13, tcstr(lbl), {lx, icy - 6}, 13, 0, COL_ONLINE)
		right = lx - 22
	}

	// Laufender Call: kleine Teilnehmer-Avatare vor dem Button
	if live && cw > 360 {
		shown := min(len(cc.peers), 4)
		aw := f32(20)
		overlap := f32(6)
		stack_w := f32(shown)*aw - f32(max(0, shown-1))*overlap
		ax := right - stack_w
		for i in 0 ..< shown {
			p := cc.peers[i]
			seed := fmt.tprintf("%d", p.user_id)
			if u := conn_find_user(c, p.user_id); u != nil {
				seed = u.username
			}
			rl.DrawCircleV({ax + aw/2, icy}, aw/2 + 2, COL_SURFACE)
			draw_avatar(app, seed, ax, icy - aw/2, aw, c = c, uid = p.user_id)
			ax += aw - overlap
		}
		right -= stack_w + 12
	}

	// Titel + Statuszeile
	tx := r.x + 58
	starter := user_label(c, m.author_id)
	title: string
	sub: string
	if live {
		title = here ? "Voice-Call · du bist dabei" : "Voice-Call läuft"
		n := len(cc.peers)
		peers_lbl := n == 1 ? "1 Teilnehmer" : fmt.tprintf("%d Teilnehmer", n)
		sub = fmt.tprintf("Gestartet von %s · %s · seit %s",
			starter, peers_lbl, format_duration((unix_now_ms() - cc.started_ms) / 1000))
	} else if m.call_end_ms > 0 {
		title = "Voice-Call beendet"
		sub = fmt.tprintf("Gestartet von %s · %s – %s Uhr · Dauer %s",
			starter, format_time_hm(app, m.call_start_ms), format_time_hm(app, m.call_end_ms),
			format_duration((m.call_end_ms - m.call_start_ms) / 1000))
	} else {
		// Server neu gestartet, Ende nie geschrieben → neutraler Abschluss
		title = "Voice-Call beendet"
		sub = fmt.tprintf("Gestartet von %s", starter)
	}
	max_tw := right - tx - 4
	draw_text(app.fonts.bold15, tcstr(trim_label(app, app.fonts.bold15, 15, title, max_tw)),
		{tx, r.y + 13}, 15, 0, COL_TEXT)
	draw_text(app.fonts.regular13, tcstr(trim_label(app, app.fonts.regular13, 13, sub, max_tw)),
		{tx, r.y + 36}, 13, 0, COL_TEXT_DIM)
}

// --- Signal-Anzeige (RTT-Balken) ---

@(private = "file")
draw_signal :: proc(app: ^App, x, cy: f32) -> f32 {
	rtt := app.call.link.rtt_ms
	healthy := voice_healthy(&app.call.link)
	bars := 3
	col := COL_ONLINE
	switch {
	case !healthy:
		bars = 0
		col = COL_RED
	case rtt >= 180:
		bars = 1
		col = COL_RED
	case rtt >= 80:
		bars = 2
		col = COL_YELLOW
	}
	for i in 0 ..< 3 {
		bh := f32(4 + i * 3)
		bcol := i < bars ? col : fade(COL_OVERLAY, 0.18)
		rrect({x + f32(i) * 5, cy + 5 - bh, 3, bh}, 1.5, bcol)
	}
	label := healthy ? fmt.tprintf("%d ms", int(rtt)) : "getrennt…"
	draw_text(app.fonts.regular13, tcstr(label), {x + 20, cy - 6}, 13, 0,
		healthy ? COL_TEXT_FAINT : COL_RED)
	return 20 + rl.MeasureTextEx(app.fonts.regular13, tcstr(label), 13, 0).x
}

// --- Icon-Buttons der Call-Flächen ---

@(private = "file")
call_icon_button :: proc(app: ^App, r: rl.Rectangle, id: u64, bg, bg_hot: rl.Color, tip: string) -> (clicked: bool, t: f32) {
	hovered := ui_hover(&app.ui, r, .Base)
	focused := tab_stop(app, id, r, .Base, radius = 8)
	t = anim_to(app, id, (hovered || focused) ? 1 : 0)
	rrect(r, 8, mix(bg, bg_hot, t))
	if focused {
		draw_focus_ring(r, 8)
	}
	if hovered {
		app.ui.cursor = .POINTING_HAND
	}
	tooltip(app, id ~ 0x717, r, tip, .Base)
	clicked = ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate)
	return
}

// Mute-Button + eigener Mini-Pegel. Gibt die belegte Breite zurück.
@(private = "file")
draw_mute_button :: proc(app: ^App, x, y: f32, id_salt: u64) -> f32 {
	mr := rl.Rectangle{x, y, 40, 30}
	m_bg := app.call.muted ? COL_RED : fade(COL_OVERLAY, 0.07)
	m_hot := app.call.muted ? mix(COL_RED, COL_WHITE, 0.15) : fade(COL_OVERLAY, 0.14)
	mclick, _ := call_icon_button(app, mr, anim_id(.Call, 0x3007E ~ id_salt), m_bg, m_hot,
		app.call.muted ? "Mikrofon einschalten" : "Stummschalten")
	draw_mic(mr.x + mr.width/2, mr.y + mr.height/2, 11, 1.8,
		app.call.muted ? COL_WHITE : COL_TEXT, app.call.muted ? COL_RED : COL_RAIL_BG, app.call.muted)
	if mclick {
		app.test_muting = false // manuelle Änderung übersteuert das Test-Mute
		call_set_mute(app, !app.call.muted)
	}
	used := f32(40)
	if !app.call.muted {
		lvl := clamp(app.call.engine.mic_level * 7, 0, 1)
		sm := anim_to(app, anim_id(.Call, 0x3E7E5 ~ id_salt), lvl, 18)
		rrect({x + 46, y + 8, 4, 14}, 2, fade(COL_OVERLAY, 0.15))
		mh := 14 * sm
		rrect({x + 46, y + 8 + 14 - mh, 4, mh}, 2, COL_ONLINE)
		used += 12
	}
	return used
}

// --- Gemeinsamer Panel-Körper: Teilnehmer-Reihe + Steuer-Buttons ---

@(private = "file")
draw_call_body :: proc(app: ^App, x, y, w: f32, popout: bool) {
	cc := app.call.conn
	peers := channel_call_peers(cc, app.call.channel_id)

	// Teilnehmer-Reihe mit Speaking-Glow
	av := f32(28)
	ax := x
	shown := 0
	max_shown := int((w - 40) / (av + 8))
	for p in peers {
		if shown >= max_shown {
			draw_text(app.fonts.bold13, tcstr(fmt.tprintf("+%d", len(peers) - shown)), {ax + 2, y + 8}, 13, 0, COL_TEXT_DIM)
			break
		}
		draw_call_peer(app, cc, p, ax, y, av, popout ? 0x50 : 0)
		ax += av + 8
		shown += 1
	}

	// Steuer-Buttons
	by := y + av + 10
	bx := x
	salt := u64(popout ? 0x50 : 0)

	bx += draw_mute_button(app, bx, by, salt) + 8

	// Einstellungen (Audio) — direkt aus dem Call heraus erreichbar
	gr := rl.Rectangle{bx, by, 36, 30}
	gclick, _ := call_icon_button(app, gr, anim_id(.Call, 0x6EA2 ~ salt),
		fade(COL_OVERLAY, 0.07), fade(COL_OVERLAY, 0.14), "Audio-Einstellungen")
	draw_gear(gr.x + gr.width/2, gr.y + gr.height/2, 8.5, 1.7, COL_TEXT)
	if gclick {
		open_settings(app)
	}
	bx += 42

	// Popout / Einklappen
	pr := rl.Rectangle{bx, by, 36, 30}
	pclick, _ := call_icon_button(app, pr, anim_id(.Call, 0x707 ~ salt), fade(COL_OVERLAY, 0.07), fade(COL_OVERLAY, 0.14),
		popout ? "Zurück in die Seitenleiste" : "Als schwebendes Fenster ausgliedern")
	draw_popout_icon(pr.x + pr.width/2, pr.y + pr.height/2, 12, 1.8, COL_TEXT)
	if pclick {
		app.call.popout = !popout
		if app.call.popout {
			app.call.popout_pos = {-1, -1} // beim ersten Zeichnen platzieren
		}
	}

	// Auflegen (rechtsbündig, rot)
	hr := rl.Rectangle{x + w - 46, by, 46, 30}
	hclick, _ := call_icon_button(app, hr, anim_id(.Call, 0xDEAD ~ salt), fade(COL_RED, 0.88), COL_RED, "Call verlassen")
	draw_hangup(hr.x + hr.width/2, hr.y + hr.height/2, 10, 3, COL_WHITE)
	if hclick {
		call_hangup(app)
	}
}

// Kopfzeile einer Call-Karte (Puls-Punkt + Titel + Dauer, Signal darunter).
@(private = "file")
draw_call_card_head :: proc(app: ^App, card: rl.Rectangle) {
	rl.DrawCircleV({card.x + 17, card.y + 16}, 4 + call_pulse()*1.4, fade(COL_ONLINE, 0.3))
	rl.DrawCircleV({card.x + 17, card.y + 16}, 3.2, COL_ONLINE)

	title := call_channel_title(app)
	if app.call.conn != app_active_conn(app) {
		title = fmt.tprintf("%s · %s", conn_label(app.call.conn), title)
	}
	dur := call_duration_label(app)
	dw := rl.MeasureTextEx(app.fonts.regular13, tcstr(dur), 13, 0).x
	draw_text(app.fonts.bold13, tcstr(trim_label(app, app.fonts.bold13, 13, title, card.width - 44 - dw - 12)),
		{card.x + 28, card.y + 9}, 13, 0, COL_TEXT)
	draw_text(app.fonts.regular13, tcstr(dur), {card.x + card.width - dw - 12, card.y + 9}, 13, 0, COL_TEXT_FAINT)
	draw_signal(app, card.x + 28, card.y + 33)
}

// --- Panel unten in der Sidebar (Standard-Platz) ---

// Rückgabe: belegte Höhe (0, wenn kein Panel).
draw_call_panel :: proc(app: ^App, sh: f32, footer_h: f32) -> f32 {
	if !app.call.active || app.call.popout {
		return 0
	}
	h := CALL_PANEL_H
	y := sh - footer_h - h
	rl.DrawRectangleRec({RAIL_W, y, SIDEBAR_W, h}, COL_SIDEBAR_BG)
	rl.DrawLineEx({RAIL_W, y}, {RAIL_W + SIDEBAR_W, y}, 1, COL_SIDEBAR_LINE)

	card := rl.Rectangle{RAIL_W + 10, y + 10, SIDEBAR_W - 20, h - 20}
	draw_shadow(card, RADIUS_CARD, 0.3)
	rrect(card, RADIUS_CARD, COL_SURFACE)
	rrect_lines(card, RADIUS_CARD, 1, COL_BORDER)

	draw_call_card_head(app, card)
	draw_call_body(app, card.x + 12, card.y + 48, card.width - 24, popout = false)
	return h
}

// --- Ausgegliedertes Popout-Panel (schwebend, draggable) ---

draw_call_popout :: proc(app: ^App, sw, sh: f32) {
	if !app.call.active || !app.call.popout {
		app.ui.overlay_on = false
		return
	}
	w := CALL_POPOUT_W
	h := CALL_POPOUT_H
	if app.call.popout_pos.x < 0 {
		app.call.popout_pos = {sw - w - 20, HEADER_H + 14}
	}

	// Drag über die Titelzone
	title_r := rl.Rectangle{app.call.popout_pos.x, app.call.popout_pos.y, w - 40, 30}
	app.ui.in_overlay = true
	if app.call.popout_drag {
		if app.ui.mouse_down {
			app.call.popout_pos = {app.ui.mouse.x - app.call.drag_off.x, app.ui.mouse.y - app.call.drag_off.y}
		} else {
			app.call.popout_drag = false
		}
	} else if app.ui.clicked && ui_hover(&app.ui, title_r, .Base) {
		app.call.popout_drag = true
		app.call.drag_off = {app.ui.mouse.x - app.call.popout_pos.x, app.ui.mouse.y - app.call.popout_pos.y}
	}
	app.call.popout_pos.x = clamp(app.call.popout_pos.x, 4, sw - w - 4)
	app.call.popout_pos.y = clamp(app.call.popout_pos.y, 4, sh - h - 4)

	p := rl.Rectangle{app.call.popout_pos.x, app.call.popout_pos.y, w, h}
	draw_shadow(p, RADIUS_CARD, 0.8)
	rrect(p, RADIUS_CARD, COL_SURFACE)
	rrect_lines(p, RADIUS_CARD, 1, COL_BORDER)

	if ui_hover(&app.ui, title_r, .Base) || app.call.popout_drag {
		app.ui.cursor = app.call.popout_drag ? .RESIZE_ALL : .POINTING_HAND
	}
	draw_call_card_head(app, p)
	draw_call_body(app, p.x + 12, p.y + 48, p.width - 24, popout = true)

	app.ui.in_overlay = false
	// Rect fürs Maus-Abfangen im nächsten Frame registrieren
	app.ui.overlay = p
	app.ui.overlay_on = true
}

// --- Top-Leiste unter der Titelleiste ---

// Höhe der Call-Leiste für diesen Frame (animiert). Läuft VOR dem Kamera-
// Setup in main.odin — die gesamte UI rutscht um diese Höhe nach unten,
// die Leiste selbst zeichnet bei negativen y-Koordinaten. Auf ganze
// physische Pixel gerundet, damit der Text darunter scharf bleibt.
call_bar_height :: proc(app: ^App) -> f32 {
	h := anim_to(app, anim_id(.Call, 0xBA40), app.call.active ? CALL_BAR_H : 0, 14, initial = 0)
	if h < 0.5 {
		return 0
	}
	return math.round(h * g_scale) / g_scale
}

draw_call_bar :: proc(app: ^App, sw: f32) {
	h := app.bar_h
	if h <= 0 {
		return
	}
	top := -h
	rl.DrawRectangleRec({0, top, sw, h}, COL_RAIL_BG)
	rl.DrawLineEx({0, top + h}, {sw, top + h}, 1, COL_SIDEBAR_LINE)
	if !app.call.active {
		return // Ausblend-Animation: nur noch die Fläche
	}
	c := app.call.conn
	// Inhalt an der UNTERKANTE verankern: er fährt mit der Leiste von oben
	// ein und ragt während der Animation nie in die UI darunter.
	cy := -CALL_BAR_H/2

	// Links: Kopfhörer + Channel (klickbar → hinspringen) + Dauer + Signal
	draw_headphones(24, cy - 1, 8, 2.4, mix(COL_ONLINE, COL_TEXT, 0.2 * call_pulse()))

	title := call_channel_title(app)
	if c != app_active_conn(app) {
		title = fmt.tprintf("%s · %s", conn_label(c), title)
	}
	title = trim_label(app, app.fonts.bold15, 15, title, sw * 0.24)
	tw := rl.MeasureTextEx(app.fonts.bold15, tcstr(title), 15, 0).x
	title_r := rl.Rectangle{40, cy - 11, tw + 8, 22}
	t_hover := ui_hover(&app.ui, title_r, .Base)
	draw_text(app.fonts.bold15, tcstr(title), {44, cy - 8}, 15, 0, t_hover ? COL_ACCENT : COL_TEXT)
	if t_hover {
		app.ui.cursor = .POINTING_HAND
	}
	tooltip(app, anim_id(.Call, 0xBA41), title_r, "Zum Channel springen", .Base)
	if ui_click(&app.ui, title_r, .Base) {
		for conn, i in app.conns {
			if conn == c {
				app.active = i
				break
			}
		}
		app_activate_channel(app, c, app.call.channel_id)
	}

	x := 44 + tw + 16
	dur := call_duration_label(app)
	draw_text(app.fonts.regular13, tcstr(dur), {x, cy - 6}, 13, 0, COL_TEXT_FAINT)
	x += rl.MeasureTextEx(app.fonts.regular13, tcstr(dur), 13, 0).x + 18
	x += draw_signal(app, x, cy + 1) + 10

	// Rechts: Mute + Pegel, Einstellungen, Auflegen
	by := cy - 15
	hang_w := f32(92)
	hr := rl.Rectangle{sw - 16 - hang_w, by, hang_w, 30}
	hclick, _ := call_icon_button(app, hr, anim_id(.Call, 0xBA42), fade(COL_RED, 0.88), COL_RED, "Call verlassen")
	draw_hangup(hr.x + 18, hr.y + hr.height/2, 9, 2.8, COL_WHITE)
	draw_text(app.fonts.bold13, "Auflegen", {hr.x + 32, hr.y + 8}, 13, 0, COL_WHITE)
	if hclick {
		call_hangup(app)
	}

	gr := rl.Rectangle{hr.x - 44, by, 36, 30}
	gclick, _ := call_icon_button(app, gr, anim_id(.Call, 0xBA43), fade(COL_OVERLAY, 0.07), fade(COL_OVERLAY, 0.14), "Audio-Einstellungen")
	draw_gear(gr.x + gr.width/2, gr.y + gr.height/2, 8.5, 1.7, COL_TEXT)
	if gclick {
		open_settings(app)
	}

	mute_x := gr.x - 8 - 52
	_ = draw_mute_button(app, mute_x, by, 0xBB)

	// Mitte: Teilnehmer-Avatare mit Speaking-Highlight
	peers := channel_call_peers(c, app.call.channel_id)
	av := f32(30)
	ax := x + 14
	limit := mute_x - 16
	shown := 0
	for p in peers {
		if ax + av > limit - 34 {
			draw_text(app.fonts.bold13, tcstr(fmt.tprintf("+%d", len(peers) - shown)), {ax + 2, cy - 6}, 13, 0, COL_TEXT_DIM)
			break
		}
		draw_call_peer(app, c, p, ax, cy - av/2, av, 0xBB)
		ax += av + 8
		shown += 1
	}
}
