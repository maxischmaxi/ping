package main

// UI-Orchestrierung: Frame-Aufbau, globale Shortcuts und die Screens
// Welcome / Connecting / Auth / Setup / Failed. Chat, Sidebar, Modals
// liegen in eigenen Dateien.

import "core:fmt"
import "core:math"
import "core:strings"

import rl "vendor:raylib"
import shared "../shared"

RAIL_W :: 68
SIDEBAR_W :: 260
HEADER_H :: 52

// Platz, den der Latenz-Indikator rechts in der Kopfzeile belegt —
// der Chat-Header rückt (zusätzlich zu THEME_RESERVE) darum nach links.
PING_RESERVE :: f32(84)

// Dauerhafter Latenz-Indikator zum aktiven Server (TCP-Ping alle 5 s),
// links neben dem Theme-Umschalter in der Kopfzeile.
@(private = "file")
draw_ping_indicator :: proc(app: ^App, c: ^Server_Conn, sw: f32) {
	label := "…"
	bars := 0
	col := COL_TEXT_FAINT
	if c.rtt_ms > 0 {
		rtt := int(c.rtt_ms)
		label = fmt.tprintf("%d ms", rtt)
		switch {
		case rtt < 80:
			bars = 3
			col = COL_ONLINE
		case rtt < 180:
			bars = 2
			col = COL_YELLOW
		case:
			bars = 1
			col = COL_RED
		}
	}
	tw := rl.MeasureTextEx(app.fonts.regular13, tcstr(label), 13, 0).x
	w := 20 + tw
	r := rl.Rectangle{sw - 20 - THEME_BTN - 14 - w, (HEADER_H - 24)/2, w, 24}
	cy := r.y + 16
	for i in 0 ..< 3 {
		bh := f32(4 + i*3)
		bcol := i < bars ? col : fade(COL_OVERLAY, 0.18)
		rrect({r.x + f32(i)*5, cy + 1 - bh, 3, bh}, 1.5, bcol)
	}
	draw_text(app.fonts.regular13, tcstr(label), {r.x + 20, r.y + (24 - 13)/2 - 1}, 13, 0, COL_TEXT_FAINT)
	tooltip(app, anim_id(.Misc, 0x9143), r, fmt.tprintf("Latenz zu %s (TCP)", conn_label(c)), .Base)
}

ui_draw :: proc(app: ^App) {
	ui_begin_frame(app, app.modal != .None || app.ctx.open || app.msg_menu.open)
	zoom_shortcuts(app)

	// Logische Bildschirmmaße (physisch / UI-Zoom); die Call-Leiste am
	// oberen Rand geht von der nutzbaren Höhe ab (Kamera-Offset, main.odin).
	sw := f32(rl.GetScreenWidth()) / g_scale
	sh := f32(rl.GetScreenHeight()) / g_scale - app.bar_h

	if len(app.conns) == 0 {
		draw_welcome(app, sw, sh)
		draw_theme_switch(app, sw, COL_PANEL_BG)
		draw_call_bar(app, sw)
		draw_toasts(app, sw, sh)
		ui_draw_tooltip(app)
		ui_end_frame(app)
		return
	}

	app.active = clamp(app.active, 0, len(app.conns) - 1)
	c := app_active_conn(app)
	phase := conn_phase(c)

	global_shortcuts(app, c, phase)

	draw_rail(app, sh)
	draw_sidebar(app, c, phase, sh)

	chat := rl.Rectangle{RAIL_W + SIDEBAR_W, 0, sw - RAIL_W - SIDEBAR_W, sh}
	rl.DrawRectangleRec(chat, COL_CHAT_BG)

	switch phase {
	case .Disconnected, .Connecting:
		draw_connecting(app, c, chat)
	case .Auth_Needed:
		draw_auth(app, c, chat)
	case .Setup_Needed:
		draw_setup(app, c, chat)
	case .Failed:
		draw_failed(app, c, chat)
	case .Ready:
		draw_chat(app, c, chat)
	}

	// Theme-Umschalter liegt über der Kopfzeile, aber unter den Modals —
	// ein offenes Modal blockiert den Base-Layer ohnehin.
	// Auth/Setup/Failed legen ein Panel über den Chat → andere Fläche.
	header_bg := COL_CHAT_BG
	#partial switch phase {
	case .Auth_Needed, .Setup_Needed, .Failed:
		header_bg = COL_PANEL_BG
	}
	if phase == .Ready {
		draw_ping_indicator(app, c, sw)
	}
	draw_theme_switch(app, sw, header_bg)

	// Call-Leiste am oberen Rand (liegt bei negativen y über allem)
	draw_call_bar(app, sw)

	// Ausgegliedertes Call-Panel schwebt über allem außer Modals/Menüs
	draw_call_popout(app, sw, sh)

	draw_modals(app, c, sw, sh)
	draw_ctx_menu(app, c, sw, sh)
	draw_msg_menu(app, c, sw, sh)
	draw_toasts(app, sw, sh)
	ui_draw_tooltip(app)
	ui_end_frame(app)
}

// Strg +/-/0: UI-Zoom. Deckt US- und DE-Layout ab (raylib-Keycodes sind
// positionsbasiert: DE „+" liegt auf RIGHT_BRACKET, DE „-" auf SLASH).
@(private = "file")
zoom_shortcuts :: proc(app: ^App) {
	if !ctrl_down() {
		return
	}
	if key_pressed(.EQUAL) || key_pressed(.KP_ADD) || key_pressed(.RIGHT_BRACKET) {
		app_set_scale(app, g_scale + 0.1)
	}
	if key_pressed(.MINUS) || key_pressed(.KP_SUBTRACT) || key_pressed(.SLASH) {
		app_set_scale(app, g_scale - 0.1)
	}
	if rl.IsKeyPressed(.ZERO) || rl.IsKeyPressed(.KP_0) {
		app_set_scale(app, 1)
	}
}

// --- Globale Shortcuts ---

@(private = "file")
global_shortcuts :: proc(app: ^App, c: ^Server_Conn, phase: Conn_Phase) {
	// Strg+K: Quick Switcher
	if ctrl_down() && rl.IsKeyPressed(.K) && phase == .Ready {
		if app.modal == .Quick_Switch {
			close_modal(app)
		} else {
			open_modal(app, .Quick_Switch)
		}
	}

	// Strg+C: markierten Chat-Text kopieren (Eingabefeld-Selektion hat Vorrang)
	if ctrl_down() && rl.IsKeyPressed(.C) && phase == .Ready {
		sel_try_copy(app, c)
	}

	// Strg+1..9: Server wechseln
	num_keys := [9]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE}
	if ctrl_down() {
		for k, i in num_keys {
			if i < len(app.conns) && rl.IsKeyPressed(k) {
				app.active = i
			}
		}
	}

	// Alt+↑/↓: Channel wechseln
	if app.modal == .None && !app.msg_menu.open && phase == .Ready && alt_down() {
		if key_pressed(.UP) {
			sidebar_step_channel(app, c, -1)
		}
		if key_pressed(.DOWN) {
			sidebar_step_channel(app, c, +1)
		}
	}

	// Esc: Dropdown/Kontextmenü/Modal schließen → Inline-Edit abbrechen →
	// Tab-Navigation beenden → ans Chat-Ende springen → Fokus
	if rl.IsKeyPressed(.ESCAPE) {
		if app.theme_menu {
			app.theme_menu = false
		} else if app.ctx.open {
			app.ctx.open = false
		} else if app.msg_menu.open {
			app.msg_menu.open = false
		} else if app.modal == .Settings && app.set_dd != 0 {
			app.set_dd = 0 // offenes Geräte-Dropdown zuerst
		} else if app.modal != .None {
			close_modal(app)
		} else if c.edit_msg_id != 0 {
			cancel_edit(app, c)
		} else if app.ui.tab_nav {
			app.ui.tab_nav = false
			app.ui.tab_focus = 0
			app.ui.focus = .Message
		} else if cs := conn_find_channel(c, c.active_channel); cs != nil && !cs.stick_bottom {
			cs.stick_bottom = true
			cs.scroll.activity = 1
		} else {
			app.ui.focus = .Message
		}
	}
}

// --- Welcome (kein Server konfiguriert) ---

// Marken-Logo: Sprechblase mit Sunset-Verlauf (Pink → Orange, aus dem
// Logotype) und drei weißen Punkten.
@(private = "file")
draw_logo :: proc(cx, cy, scale: f32, bg: rl.Color) {
	w := 76 * scale
	h := 58 * scale
	r := rl.Rectangle{cx - w/2, cy - h/2, w, h}
	rrect_gradient_h(r, 18*scale, LOGO_PINK, LOGO_ORANGE, bg)
	// Sprechblasen-Zipfel (DrawPoly umgeht Winding-Fallen); sitzt links
	// unten → Farbe nahe am Pink-Ende des Verlaufs.
	rl.DrawPoly({cx - 14*scale, cy + h/2 + 4*scale}, 3, 11*scale, 90, mix(LOGO_PINK, LOGO_ORANGE, 0.3))
	for i in 0 ..< 3 {
		rl.DrawCircleV({cx - 18*scale + f32(i)*18*scale, cy}, 4.4*scale, COL_WHITE)
	}
}

@(private = "file")
draw_welcome :: proc(app: ^App, sw, sh: f32) {
	rl.DrawRectangleRec({0, 0, sw, sh}, COL_PANEL_BG)

	cx := sw / 2
	base_y := sh/2 - 190

	float := f32(math.sin(rl.GetTime() * 1.6)) * 4
	draw_logo(cx, base_y + 30 + float, 1, COL_PANEL_BG)

	draw_text_centered(app.fonts.bold36, "flurfunk", cx, base_y + 84, 36, COL_TEXT)
	draw_text_centered(app.fonts.regular15, "Dein Team. Dein Server. Deine Daten.",
		cx, base_y + 132, 15, COL_TEXT_DIM)

	// Karte
	card := rl.Rectangle{cx - 210, base_y + 172, 420, 158}
	draw_shadow(card, RADIUS_CARD, 0.6)
	rrect(card, RADIUS_CARD, COL_SURFACE)
	rrect_lines(card, RADIUS_CARD, 1, COL_BORDER)

	draw_text(app.fonts.regular13, "Server-Adresse", {card.x + 24, card.y + 18}, 13, 0, COL_TEXT_DIM)

	if app.ui.focus == .None && !app.ui.tab_nav {
		app.ui.focus = .Welcome_Addr
	}

	field := rl.Rectangle{card.x + 24, card.y + 40, card.width - 48, 42}
	submitted := text_field(app, field, &app.welcome_input, .Welcome_Addr, .Base, "z. B. chat.firma.de:7788")
	if button(app, {card.x + 24, card.y + 96, card.width - 48, 42}, "Verbinden", .Base, style = .Primary) || submitted {
		addr := strings.trim_space(ti_text(&app.welcome_input))
		if strings.contains(addr, ":") && len(addr) > 2 {
			app_add_server(app, addr)
			ti_clear(&app.welcome_input)
			app.welcome_error = ""
			app.ui.focus = .None
		} else {
			app.welcome_error = "Bitte Adresse als host:port angeben"
		}
	}
	if app.welcome_error != "" {
		draw_text_centered(app.fonts.regular13, app.welcome_error, cx, card.y + card.height + 14, 13, COL_RED)
	}
}

// --- Connecting ---

draw_spinner :: proc(cx, cy, radius: f32, col: rl.Color) {
	start := f32(math.mod(rl.GetTime()*320, 360))
	rl.DrawRing({cx, cy}, radius - 3, radius, start, start + 270, 40, col)
}

@(private = "file")
draw_connecting :: proc(app: ^App, c: ^Server_Conn, chat: rl.Rectangle) {
	cx := chat.x + chat.width/2
	cy := chat.y + chat.height/2
	draw_spinner(cx, cy - 40, 16, COL_ACCENT)
	draw_text_centered(app.fonts.bold15, fmt.tprintf("Verbinde mit %s…", c.addr), cx, cy, 15, COL_TEXT)
	draw_text_centered(app.fonts.regular13, "Baue verschlüsselte Verbindung auf", cx, cy + 26, 13, COL_TEXT_FAINT)
}

// --- Auth ---

@(private = "file")
card_frame :: proc(app: ^App, chat: rl.Rectangle, w, h: f32) -> rl.Rectangle {
	rl.DrawRectangleRec(chat, COL_PANEL_BG)
	p := rl.Rectangle{chat.x + (chat.width - w)/2, chat.y + (chat.height - h)/2, w, h}
	draw_shadow(p, RADIUS_CARD, 0.7)
	rrect(p, RADIUS_CARD, COL_SURFACE)
	rrect_lines(p, RADIUS_CARD, 1, COL_BORDER)
	return p
}

// Kleiner Hinweistext unter einem Formularfeld (erklärt Zweck + Sichtbarkeit).
@(private = "file")
field_hint :: proc(app: ^App, x, y, w: f32, text: string) {
	draw_text(app.fonts.regular13, tcstr(trim_label(app, app.fonts.regular13, 13, text, w)),
		{x, y}, 13, 0, COL_TEXT_FAINT)
}

// Feldblock-Höhen: Label + Feld (+ Hinweis) + Luft.
AUTH_FIELD_H :: f32(74)        // ohne Hinweiszeile
AUTH_FIELD_HINT_H :: f32(90)   // mit Hinweiszeile
AUTH_AVATAR_H :: f32(80)

@(private = "file")
draw_auth :: proc(app: ^App, c: ^Server_Conn, chat: rl.Rectangle) {
	fresh := !c.initialized // frischer Server → nur Registrieren, erster User wird Admin
	register := fresh || c.auth_tab == 1
	need_invite := register && !fresh && c.invite_only
	provs := c.providers

	// Höhe aus denselben Blöcken zusammensetzen, die unten gezeichnet werden
	h := f32(28) // oberes Polster
	h += fresh ? 68 : 58
	if register {
		h += AUTH_FIELD_HINT_H * 2 // Nutzername + Anzeigename (mit Hinweis)
		if need_invite {
			h += AUTH_FIELD_HINT_H
		}
		h += AUTH_FIELD_H // Passwort
		h += AUTH_AVATAR_H
	} else {
		h += AUTH_FIELD_H * 2 // Nutzername + Passwort
	}
	h += 52 + 20 + 14 // Button + Fehlerzeile + unteres Polster
	if len(provs) > 0 {
		h += 46 + f32(len(provs)) * 48 // Trenner „oder weiter mit" + Provider-Buttons
	}
	p := card_frame(app, chat, 420, h)

	// Beim Betreten des Formulars das erste Feld fokussieren.
	// Tab/Shift+Tab übernimmt die globale Tab-Navigation (widgets.odin).
	in_form := app.ui.focus == .Auth_User || app.ui.focus == .Auth_Pass ||
		(register && app.ui.focus == .Auth_Display) ||
		(need_invite && app.ui.focus == .Auth_Invite)
	if !in_form && app.modal == .None && !app.ui.tab_nav {
		app.ui.focus = .Auth_User
	}

	y := p.y + 28
	if fresh {
		draw_text_centered(app.fonts.bold24, "Neuen Server einrichten", p.x + p.width/2, y, 24, COL_TEXT)
		y += 34
		draw_text_centered(app.fonts.regular13, "Du bist die erste Person hier und wirst Administrator.",
			p.x + p.width/2, y, 13, COL_TEXT_DIM)
		y += 34
	} else {
		// Segmented Control mit animiertem Slider. Track getönt, Slider
		// zurück auf Kartenniveau — der Kontrast kippt mit dem Theme
		// (hell: Slider heller als der Track, dunkel: dunkler).
		seg := rl.Rectangle{p.x + 24, y, p.width - 48, 40}
		rrect(seg, 9, COL_RAIL_ITEM)
		half := seg.width / 2
		st := anim_to(app, anim_id(.Tab_Slider, u64(c.cfg_index)), f32(c.auth_tab), 16)
		slider := rl.Rectangle{seg.x + 3 + st*(half - 3), seg.y + 3, half - 6, seg.height - 6}
		draw_shadow(slider, 7, 0.25)
		rrect(slider, 7, COL_SURFACE)
		for label, i in ([2]string{"Anmelden", "Registrieren"}) {
			r := rl.Rectangle{seg.x + f32(i)*half, seg.y, half, seg.height}
			selected := c.auth_tab == i
			seg_focused := tab_stop(app, anim_id(.Tab_Slider, u64(c.cfg_index) ~ (u64(i+1) << 32)), r, .Base, radius = 9)
			if seg_focused {
				draw_focus_ring(r, 9)
			}
			if ui_hover(&app.ui, r, .Base) && !selected {
				app.ui.cursor = .POINTING_HAND
			}
			font := selected ? app.fonts.bold15 : app.fonts.regular15
			tw := rl.MeasureTextEx(font, tcstr(label), 15, 0)
			draw_text(font, tcstr(label), {r.x + (half - tw.x)/2, r.y + (seg.height - tw.y)/2}, 15, 0,
				selected ? COL_TEXT : COL_TEXT_DIM)
			if (ui_click(&app.ui, r, .Base) || (seg_focused && app.ui.tab_activate)) && !selected {
				c.auth_tab = i
				c.auth_error = ""
				caret_reset(app)
			}
		}
		y += 58
	}

	field_x := p.x + 24
	field_w := p.width - 48
	submitted := false

	draw_text(app.fonts.regular13, "Nutzername", {field_x, y}, 13, 0, COL_TEXT_DIM)
	y += 20
	submitted |= text_field(app, {field_x, y, field_w, 40}, &c.auth_user, .Auth_User, .Base,
		register ? "z. B. max.mustermann" : "dein.nutzername")
	y += 46
	if register {
		field_hint(app, field_x, y, field_w, "Dein fester Anmeldename — für alle auf dem Server sichtbar.")
		y += AUTH_FIELD_HINT_H - 66
	} else {
		y += AUTH_FIELD_H - 66
	}

	if register {
		draw_text(app.fonts.regular13, "Anzeigename (optional)", {field_x, y}, 13, 0, COL_TEXT_DIM)
		y += 20
		submitted |= text_field(app, {field_x, y, field_w, 40}, &c.auth_display, .Auth_Display, .Base, "z. B. Max Mustermann")
		y += 46
		field_hint(app, field_x, y, field_w, "So heißt du im Chat — für alle sichtbar. Leer = Nutzername.")
		y += AUTH_FIELD_HINT_H - 66
	}

	if need_invite {
		// Registration is invite-only on this server (server_info flag).
		draw_text(app.fonts.regular13, "Einladungscode", {field_x, y}, 13, 0, COL_TEXT_DIM)
		y += 20
		submitted |= text_field(app, {field_x, y, field_w, 40}, &c.auth_invite, .Auth_Invite, .Base, "z. B. K7RTQW2M")
		y += 46
		field_hint(app, field_x, y, field_w, "Bekommst du von der Person, die dich einlädt. Gilt einmal.")
		y += AUTH_FIELD_HINT_H - 66
	}

	draw_text(app.fonts.regular13, "Passwort", {field_x, y}, 13, 0, COL_TEXT_DIM)
	label_y := y
	y += 20
	submitted |= text_field(app, {field_x, y, field_w, 40}, &c.auth_pass, .Auth_Pass, .Base,
		register ? "mindestens 6 Zeichen" : "Dein Passwort", password = !c.show_pass)
	y += AUTH_FIELD_H - 20

	// Show/hide toggle — registered AFTER the field so Tab reaches the
	// password field first and the link second.
	toggle_label := c.show_pass ? "verbergen" : "anzeigen"
	tlw := rl.MeasureTextEx(app.fonts.regular13, tcstr(toggle_label), 13, 0).x
	tr := rl.Rectangle{field_x + field_w - tlw - 4, label_y - 2, tlw + 8, 18}
	toggle_focused := tab_stop(app, anim_id(.Misc, 0x9A55), tr, .Base, radius = 4)
	if toggle_focused {
		draw_focus_ring(tr, 4)
	}
	draw_text(app.fonts.regular13, tcstr(toggle_label), {tr.x + 4, label_y}, 13, 0, COL_ACCENT)
	if ui_hover(&app.ui, tr, .Base) {
		app.ui.cursor = .POINTING_HAND
	}
	if ui_click(&app.ui, tr, .Base) || (toggle_focused && app.ui.tab_activate) {
		c.show_pass = !c.show_pass
	}

	if register {
		// Optionales Profilbild — wird nach erfolgreicher Registrierung hochgeladen
		y += draw_auth_avatar_row(app, c, field_x, y, field_w)
	}

	btn_label := register ? (fresh ? "Server einrichten" : "Konto erstellen") : "Anmelden"
	if c.auth_busy {
		dots := int(rl.GetTime()*3) % 4
		btn_label = fmt.tprintf("Bitte warten%s", strings.repeat(".", dots, context.temp_allocator))
	}
	if button(app, {field_x, y, field_w, 42}, btn_label, .Base, style = .Primary) {
		submitted = true
	}
	y += 52

	if c.auth_error != "" {
		draw_text_centered(app.fonts.regular13, c.auth_error, p.x + p.width/2, y, 13, COL_RED)
	}

	// Auth-Provider-Buttons („Weiter mit Google/…"), sofern der Server
	// welche aktiviert hat. Ein Klick startet den Browser-Flow; ein
	// erneuter Klick auf den laufenden Provider bricht ihn ab.
	if len(provs) > 0 {
		y += 20
		cx := p.x + p.width/2
		lbl := "oder weiter mit"
		tw := rl.MeasureTextEx(app.fonts.regular13, tcstr(lbl), 13, 0).x
		rl.DrawLineEx({field_x, y + 7}, {cx - tw/2 - 10, y + 7}, 1, COL_BORDER_SOFT)
		rl.DrawLineEx({cx + tw/2 + 10, y + 7}, {field_x + field_w, y + 7}, 1, COL_BORDER_SOFT)
		draw_text_centered(app.fonts.regular13, lbl, cx, y, 13, COL_TEXT_FAINT)
		y += 26

		flow := &app.oauth
		for prov, i in provs {
			busy_this := flow.active && flow.conn == c && flow.provider == prov.id
			label := busy_this ? "Warte auf den Browser… (abbrechen)" : fmt.tprintf("Mit %s anmelden", prov.label)
			if button(app, {field_x, y, field_w, 40}, label, .Base, id_salt = 0x0A07 ~ (u64(i + 1) << 32)) && !c.auth_busy {
				if busy_this {
					oauth_flow_stop(app)
					toast(app, .Info, "Anmeldung abgebrochen")
				} else {
					oauth_begin(app, c, prov.id, prov.label)
				}
			}
			y += 48
		}
	}

	if submitted && !c.auth_busy {
		auth_submit(app, c, register)
	}
}

@(private = "file")
auth_submit :: proc(app: ^App, c: ^Server_Conn, register: bool) {
	user := strings.trim_space(ti_text(&c.auth_user))
	pass := ti_text(&c.auth_pass)
	if user == "" || pass == "" {
		c.auth_error = "Bitte Nutzername und Passwort eingeben"
		return
	}
	if register && !shared.valid_username(user) {
		c.auth_error = "Nutzername: 2–32 Zeichen, nur a-z 0-9 . _ -"
		return
	}
	if register && len(pass) < shared.MIN_PASSWORD_LEN {
		c.auth_error = "Passwort: mindestens 6 Zeichen"
		return
	}
	invite := strings.trim_space(ti_text(&c.auth_invite))
	if register && c.initialized && c.invite_only && invite == "" {
		c.auth_error = "Dieser Server braucht einen Einladungscode"
		return
	}
	c.auth_error = ""
	c.auth_busy = true
	if register {
		disp := strings.trim_space(ti_text(&c.auth_display))
		conn_request(c, {kind = shared.K_REGISTER, username = user, password = pass,
			display_name = disp, invite_code = invite})
	} else {
		conn_request(c, {kind = shared.K_LOGIN, username = user, password = pass})
	}
}

// --- Setup ---

@(private = "file")
draw_setup :: proc(app: ^App, c: ^Server_Conn, chat: rl.Rectangle) {
	p := card_frame(app, chat, 420, 268)
	if app.ui.focus != .Setup_Name && app.modal == .None && !app.ui.tab_nav {
		app.ui.focus = .Setup_Name
	}

	y := p.y + 28
	draw_text_centered(app.fonts.bold24, "Fast geschafft!", p.x + p.width/2, y, 24, COL_TEXT)
	y += 34
	draw_text_centered(app.fonts.regular13, "Gib deinem Server einen Namen — dein Team sieht ihn in der Seitenleiste.",
		p.x + p.width/2, y, 13, COL_TEXT_DIM)
	y += 32

	field_x := p.x + 24
	field_w := p.width - 48
	draw_text(app.fonts.regular13, "Name des Servers", {field_x, y}, 13, 0, COL_TEXT_DIM)
	y += 20
	submitted := text_field(app, {field_x, y, field_w, 40}, &c.setup_input, .Setup_Name, .Base, "z. B. Acme GmbH")
	y += 54

	if button(app, {field_x, y, field_w, 42}, "Fertigstellen", .Base, style = .Primary) {
		submitted = true
	}
	y += 50
	if c.setup_error != "" {
		draw_text_centered(app.fonts.regular13, c.setup_error, p.x + p.width/2, y, 13, COL_RED)
	}

	if submitted {
		name := strings.trim_space(ti_text(&c.setup_input))
		if name == "" {
			c.setup_error = "Bitte einen Namen eingeben"
		} else {
			c.setup_error = ""
			conn_request(c, {kind = shared.K_SETUP, server_name = name})
		}
	}
}

// --- Failed ---

@(private = "file")
draw_failed :: proc(app: ^App, c: ^Server_Conn, chat: rl.Rectangle) {
	key_mismatch := c.err_text == "Server-Schlüssel hat sich geändert!"
	h := f32(key_mismatch ? 330 : 300)
	p := card_frame(app, chat, 440, h)
	cx := p.x + p.width/2

	y := p.y + 30
	rl.DrawCircleV({cx, y + 22}, 24, fade(COL_RED, 0.12))
	draw_rune_centered(app.fonts.bold24, '!', cx, y + 22, COL_RED)
	y += 62

	draw_text_centered(app.fonts.bold18, c.err_text != "" ? c.err_text : "Verbindung fehlgeschlagen", cx, y, 18, COL_TEXT)
	y += 28
	draw_text_centered(app.fonts.regular13, c.addr, cx, y, 13, COL_TEXT_FAINT)
	y += 26

	if key_mismatch {
		draw_text_centered(app.fonts.regular13, "Der Server weist einen anderen Schlüssel vor als beim ersten Verbinden.",
			cx, y, 13, COL_TEXT_DIM)
		y += 18
		draw_text_centered(app.fonts.regular13, "Wurde er neu aufgesetzt, entferne ihn und füge ihn neu hinzu.",
			cx, y, 13, COL_TEXT_DIM)
		y += 28
	} else if c.retry_at > 0 {
		secs := int(c.retry_at - rl.GetTime()) + 1
		draw_text_centered(app.fonts.regular13, fmt.tprintf("Automatischer Neuversuch in %ds…", max(secs, 1)),
			cx, y, 13, COL_TEXT_DIM)
		y += 28
	} else {
		y += 10
	}

	bw := f32(180)
	if button(app, {cx - bw - 8, y, bw, 42}, "Jetzt neu verbinden", .Base, style = .Primary) {
		c.retry_at = 0
		conn_start(c)
	}
	if button(app, {cx + 8, y, bw, 42}, "Server entfernen", .Base, style = .Danger) {
		app_remove_server(app, app.active)
	}
}

// Server aus App + Config entfernen (nur für nicht verbundene sinnvoll).
app_remove_server :: proc(app: ^App, idx: int) {
	if idx < 0 || idx >= len(app.conns) {
		return
	}
	c := app.conns[idx]

	// Hängt der aktive Call an diesem Server → lokal beenden
	if app.call.active && app.call.conn == c {
		call_teardown(app)
	}
	// Laufender OAuth-Flow zu diesem Server → abbrechen
	if app.oauth.active && app.oauth.conn == c {
		oauth_flow_stop(app)
	}

	// Reader-Thread (falls noch aktiv) über Generation invalidieren
	conn_invalidate(c)

	// GPU-Ressourcen dieser Verbindung freigeben
	avatar_cache_clear(c)
	if c.auth_av_ok {
		rl.UnloadTexture(c.auth_av_tex)
		c.auth_av_ok = false
	}
	delete(c.auth_avatar_png)
	delete(c.av_upload_png)

	if c.cfg_index >= 0 && c.cfg_index < len(app.cfg.servers) {
		ordered_remove(&app.cfg.servers, c.cfg_index)
		for other in app.conns {
			if other.cfg_index > c.cfg_index {
				other.cfg_index -= 1
			}
		}
		config_save(&app.cfg)
	}
	ordered_remove(&app.conns, idx)
	if app.active >= len(app.conns) {
		app.active = max(0, len(app.conns) - 1)
	}
	toast(app, .Info, fmt.tprintf("%s entfernt", conn_label(c)))
}
