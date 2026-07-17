package main

// Modals: Overlay mit Fade, Panel mit Scale-In, Klick außerhalb schließt.

import "core:fmt"
import "core:strings"

import rl "vendor:raylib"
import shared "../shared"

open_modal :: proc(app: ^App, kind: Modal_Kind) {
	if app.modal == .Settings && kind != .Settings {
		settings_on_close(app) // Wechsel (z. B. Strg+K): Audio-Tests stoppen
	}
	if app.modal == .Avatar_Crop && kind != .Avatar_Crop {
		avatar_crop_cleanup(app) // Wechsel am Editor vorbei: Quelle freigeben
		app.av_return_settings = false
	}
	app.modal = kind
	app.modal_error = ""
	ti_clear(&app.modal_input)
	scroll_to(&app.modal_scroll, 0)
	app.switcher_sel = 0
	app.anim.vals[anim_id(.Modal_Open, 1)] = 0 // Öffnungs-Animation neu starten
	#partial switch kind {
	case .Members, .Msg_History, .Settings, .Admin:
		app.ui.focus = .None
	case .Quick_Switch:
		app.ui.focus = .Switcher
	case:
		app.ui.focus = .Modal_Input
	}
	// Öffnungs-Klick konsumieren, sonst schließt ihn die
	// Klick-außerhalb-Logik noch im selben Frame wieder.
	app.ui.clicked = false
	// Tab-Navigation startet im Modal frisch (Fokus-Falle wie im Browser)
	app.ui.tab_focus = 0
}

close_modal :: proc(app: ^App) {
	if app.modal == .Settings {
		settings_on_close(app) // Audio-Tests stoppen, Gerätelisten freigeben
	}
	was_crop := app.modal == .Avatar_Crop
	app.modal = .None
	app.ui.focus = .Message
	app.ui.tab_focus = 0
	app.ui.tab_nav = false
	if was_crop {
		avatar_crop_cleanup(app)
		// Der Editor kam aus den Einstellungen → dorthin zurück
		if app.av_return_settings {
			app.av_return_settings = false
			open_settings(app)
		}
	}
}

// Overlay + zentriertes Panel mit Öffnungs-Animation. Gibt Panel-Rect zurück.
// (paketweit: auch settingsui.odin baut darauf auf)
modal_frame :: proc(app: ^App, sw, sh, w, h: f32, title: string, top: f32 = -1) -> rl.Rectangle {
	t := anim_to(app, anim_id(.Modal_Open, 1), 1, 16, initial = 0)
	// Scrim deckt auch die Call-Leiste ab (liegt bei negativem y)
	rl.DrawRectangleRec({0, -app.bar_h, sw, sh + app.bar_h}, fade(COL_SCRIM, t))

	scale := 0.96 + 0.04*t
	pw := w * scale
	ph := h * scale
	px := (sw - pw)/2
	py := top >= 0 ? top + (h - ph)/2 : (sh - ph)/2 - 20*(1 - t)
	p := rl.Rectangle{px, py, pw, ph}

	draw_shadow(p, RADIUS_CARD, t)
	rrect(p, RADIUS_CARD, fade(COL_SURFACE, t))
	rrect_lines(p, RADIUS_CARD, 1, fade(COL_BORDER, t))
	if title != "" {
		draw_text(app.fonts.bold18, tcstr(title), {p.x + 24, p.y + 22}, 18, 0, fade(COL_TEXT, t))
	}

	// Klick außerhalb schließt
	if app.ui.clicked && !rl.CheckCollisionPointRec(app.ui.mouse, p) {
		close_modal(app)
	}
	return p
}

draw_modals :: proc(app: ^App, c: ^Server_Conn, sw, sh: f32) {
	switch app.modal {
	case .None:

	case .Add_Server:
		p := modal_frame(app, sw, sh, 440, 210, "Server hinzufügen")
		draw_text(app.fonts.regular13, "Adresse", {p.x + 24, p.y + 58}, 13, 0, COL_TEXT_DIM)
		submitted := text_field(app, {p.x + 24, p.y + 78, p.width - 48, 40}, &app.modal_input,
			.Modal_Input, .Modal, "z. B. chat.firma.de:7788")
		if app.modal_error != "" {
			draw_text(app.fonts.regular13, tcstr(app.modal_error), {p.x + 24, p.y + 124}, 13, 0, COL_RED)
		}
		if button(app, {p.x + p.width - 262, p.y + p.height - 56, 112, 38}, "Abbrechen", .Modal) {
			close_modal(app)
		}
		if button(app, {p.x + p.width - 136, p.y + p.height - 56, 112, 38}, "Verbinden", .Modal, style = .Primary) || submitted {
			addr := strings.trim_space(ti_text(&app.modal_input))
			if strings.contains(addr, ":") && len(addr) > 2 {
				app_add_server(app, addr)
				close_modal(app)
			} else {
				app.modal_error = "Bitte Adresse als host:port angeben"
			}
		}

	case .Create_Channel:
		p := modal_frame(app, sw, sh, 440, 230, "Kanal erstellen")
		draw_text(app.fonts.regular13, "Name", {p.x + 24, p.y + 58}, 13, 0, COL_TEXT_DIM)
		submitted := text_field(app, {p.x + 24, p.y + 78, p.width - 48, 40}, &app.modal_input,
			.Modal_Input, .Modal, "z. b. marketing")
		draw_text(app.fonts.regular13, "Kleinbuchstaben (ä ö ü ok), Zahlen, - und _", {p.x + 24, p.y + 124}, 13, 0, COL_TEXT_FAINT)
		if app.modal_error != "" {
			draw_text(app.fonts.regular13, tcstr(app.modal_error), {p.x + 24, p.y + 142}, 13, 0, COL_RED)
		}
		if button(app, {p.x + p.width - 262, p.y + p.height - 56, 112, 38}, "Abbrechen", .Modal) {
			close_modal(app)
		}
		if button(app, {p.x + p.width - 136, p.y + p.height - 56, 112, 38}, "Erstellen", .Modal, style = .Primary) || submitted {
			// Großschreibung stillschweigend korrigieren (wie Slack)
			name := strings.to_lower(strings.trim_space(ti_text(&app.modal_input)), context.temp_allocator)
			if shared.valid_channel_name(name) {
				conn_request(c, {kind = shared.K_CREATE_CHANNEL, name = name})
				close_modal(app)
			} else {
				app.modal_error = "Ungültiger Kanalname"
			}
		}

	case .Members:
		draw_members_modal(app, c, sw, sh)

	case .Settings:
		draw_settings_modal(app, c, sw, sh)

	case .Avatar_Crop:
		draw_avatar_crop_modal(app, c, sw, sh)

	case .Admin:
		draw_admin_modal(app, c, sw, sh)

	case .Quick_Switch:
		draw_quick_switcher(app, c, sw, sh)

	case .Msg_History:
		draw_history_sheet(app, c, sw, sh)

	case .Confirm_Delete:
		cs := conn_find_channel(c, app.confirm_channel)
		if cs == nil {
			close_modal(app)
			return
		}
		p := modal_frame(app, sw, sh, 460, 200, "Kanal löschen")
		draw_text(app.fonts.regular15, tcstr(fmt.tprintf("#%s wird für alle Mitglieder entfernt.", cs.ch.name)),
			{p.x + 24, p.y + 62}, 15, 0, COL_TEXT)
		draw_text(app.fonts.regular13, "Alle Nachrichten gehen dauerhaft verloren — das lässt sich nicht rückgängig machen.",
			{p.x + 24, p.y + 88}, 13, 0, COL_TEXT_DIM)
		if button(app, {p.x + p.width - 306, p.y + p.height - 56, 112, 38}, "Abbrechen", .Modal) {
			close_modal(app)
		}
		if button(app, {p.x + p.width - 180, p.y + p.height - 56, 156, 38}, "Endgültig löschen", .Modal, style = .Danger_Solid) {
			conn_request(c, {kind = shared.K_DELETE_CHANNEL, channel_id = cs.ch.id}, {channel_id = cs.ch.id})
			close_modal(app)
		}
	}
}

@(private = "file")
draw_members_modal :: proc(app: ^App, c: ^Server_Conn, sw, sh: f32) {
	cs := conn_find_channel(c, c.active_channel)
	if cs == nil {
		close_modal(app)
		return
	}
	h := min(f32(580), sh - 120)
	p := modal_frame(app, sw, sh, 460, h, fmt.tprintf("Mitglieder · %s", channel_title(c, cs)))

	can_kick := c.me.is_admin || cs.ch.creator_id == c.me.id

	member_of :: proc(cs: ^Channel_State, id: u64) -> bool {
		for m in cs.ch.member_ids {
			if m == id {
				return true
			}
		}
		return false
	}
	non_members := make([dynamic]shared.User, context.temp_allocator)
	for u in c.users {
		if !member_of(cs, u.id) {
			append(&non_members, u)
		}
	}

	list := rl.Rectangle{p.x, p.y + 56, p.width, p.height - 56 - 64}
	row_h := f32(44)
	content_h := f32(len(cs.ch.member_ids))*row_h + 44 + f32(len(non_members))*row_h + 16
	hovered := ui_hover(&app.ui, list, .Modal)
	scroll_update(app, &app.modal_scroll, hovered, max(0, content_h - list.height), 44)

	scissor_begin(list.x, list.y, list.width, list.height)
	y := list.y - app.modal_scroll.pos

	row_visible :: proc(list: rl.Rectangle, y, row_h: f32) -> bool {
		return y + row_h > list.y && y < list.y + list.height
	}

	for mid in cs.ch.member_ids {
		if !row_visible(list, y, row_h) {
			y += row_h
			continue
		}
		label := user_label(c, mid)
		seed := label
		online := false
		in_call := false
		if u := conn_find_user(c, mid); u != nil {
			seed = u.username
			online = u.online
			in_call = u.in_call
		}
		draw_avatar(app, seed, p.x + 24, y + 7, 30, presence = true, online = online, c = c, uid = mid)
		name_x := p.x + 66
		draw_text(app.fonts.regular15, tcstr(label), {name_x, y + 13}, 15, 0, COL_TEXT)
		nw := rl.MeasureTextEx(app.fonts.regular15, tcstr(label), 15, 0).x
		if in_call {
			draw_headphones(name_x + nw + 14, y + 21, 6, 1.8, COL_ONLINE)
			nw += 22
		}
		if mid == cs.ch.creator_id {
			draw_text(app.fonts.regular13, "Ersteller", {name_x + nw + 8, y + 15}, 13, 0, COL_TEXT_FAINT)
		} else if mid == c.me.id {
			draw_text(app.fonts.regular13, "du", {name_x + nw + 8, y + 15}, 13, 0, COL_TEXT_FAINT)
		}
		if can_kick && mid != cs.ch.creator_id && mid != c.me.id {
			if button(app, {p.x + p.width - 124, y + 7, 100, 30}, "Entfernen", .Modal, style = .Danger, id_salt = mid) {
				conn_request(c, {kind = shared.K_KICK, channel_id = cs.ch.id, user_id = mid}, {channel_id = cs.ch.id, user_id = mid})
			}
		}
		y += row_h
	}

	if len(non_members) > 0 {
		y += 8
		draw_text(app.fonts.bold13, "Einladen", {p.x + 24, y + 8}, 13, 0, COL_TEXT_DIM)
		y += 36
		for u in non_members {
			if !row_visible(list, y, row_h) {
				y += row_h
				continue
			}
			label := u.display_name != "" ? u.display_name : u.username
			draw_avatar(app, u.username, p.x + 24, y + 7, 30, presence = true, online = u.online, c = c, uid = u.id)
			draw_text(app.fonts.regular15, tcstr(label), {p.x + 66, y + 13}, 15, 0, COL_TEXT)
			if button(app, {p.x + p.width - 124, y + 7, 100, 30}, "Einladen", .Modal, id_salt = u.id ~ 0x1E) {
				conn_request(c, {kind = shared.K_INVITE, channel_id = cs.ch.id, user_id = u.id}, {channel_id = cs.ch.id, user_id = u.id})
			}
			y += row_h
		}
	}
	scissor_end()
	scrollbar(app, list, content_h, &app.modal_scroll, .Modal)

	// Fußzeile: Verlassen links, Schließen rechts
	if !cs.ch.is_dm {
		if button(app, {p.x + 24, p.y + p.height - 52, 140, 36}, "Kanal verlassen", .Modal, style = .Danger) {
			conn_request(c, {kind = shared.K_LEAVE, channel_id = cs.ch.id}, {channel_id = cs.ch.id})
			close_modal(app)
		}
	}
	if button(app, {p.x + p.width - 136, p.y + p.height - 52, 112, 36}, "Schließen", .Modal) {
		close_modal(app)
	}
}
