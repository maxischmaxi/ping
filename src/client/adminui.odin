package main

// Admin panel: one big modal with a tab rail on the left. Data comes as an
// Admin_State snapshot from the server; every admin reply carries a fresh
// one, so this file only renders state and fires requests — no local sync.

import "core:fmt"
import "core:strings"

import rl "vendor:raylib"
import shared "../shared"

ADM_TABS := [5]string{"Allgemein", "Zugang", "Nutzer", "Channels", "Sicherheit"}

// Validity choices for new invites and manual IP bans (minutes, 0 = forever).
ADM_INVITE_OPTS := [3]int{24 * 60, 7 * 24 * 60, 0}
ADM_INVITE_LABELS := [3]string{"24 Stunden", "7 Tage", "Unbefristet"}
ADM_BAN_OPTS := [3]int{30, 24 * 60, 0}
ADM_BAN_LABELS := [3]string{"30 Minuten", "24 Stunden", "Permanent"}

open_admin :: proc(app: ^App, c: ^Server_Conn) {
	if !c.me.is_admin {
		return
	}
	app.adm_tab = 0
	app.adm_reset_user = 0
	app.adm_confirm_del = 0
	ti_set_text(&app.adm_name_input, c.server_name)
	ti_clear(&app.adm_user_input)
	ti_clear(&app.adm_disp_input)
	ti_clear(&app.adm_pass_input)
	ti_clear(&app.adm_ban_input)
	ti_clear(&app.adm_reset_input)
	c.admin_loading = true
	conn_request(c, {kind = shared.K_ADMIN_STATE})
	open_modal(app, .Admin)
}

// Applies a reply to any K_ADMIN_* request (called from app_apply_reply).
admin_apply_reply :: proc(app: ^App, c: ^Server_Conn, w: shared.Wire, p: Pending) {
	c.admin_loading = false
	if !w.ok {
		toast(app, .Error, translate_err(w.err))
		// Demoted mid-flight → the panel has no business staying open.
		if w.err == "not_allowed" && app.modal == .Admin && c == app_active_conn(app) {
			close_modal(app)
		}
		return
	}
	c.admin = w.admin
	c.admin_loaded = true

	switch p.kind {
	case shared.K_ADMIN_CREATE_INVITE:
		if w.invite_code != "" {
			rl.SetClipboardText(tcstr(w.invite_code))
			toast(app, .Success, fmt.tprintf("Einladung %s erstellt — Code kopiert", w.invite_code))
		}
	case shared.K_ADMIN_REVOKE_INVITE:
		toast(app, .Info, "Einladung entfernt")
	case shared.K_ADMIN_CREATE_USER:
		toast(app, .Success, fmt.tprintf("Konto @%s angelegt", w.user.username))
		ti_clear(&app.adm_user_input)
		ti_clear(&app.adm_disp_input)
		ti_clear(&app.adm_pass_input)
	case shared.K_ADMIN_RESET_PASSWORD:
		toast(app, .Success, "Passwort zurückgesetzt — alle Sitzungen beendet")
		app.adm_reset_user = 0
		ti_clear(&app.adm_reset_input)
	case shared.K_ADMIN_BAN_IP:
		toast(app, .Success, "IP-Adresse gesperrt")
		ti_clear(&app.adm_ban_input)
	case shared.K_ADMIN_UNBAN_IP:
		toast(app, .Info, "IP-Adresse entsperrt")
	}
}

// Sends the settings struct (optimistic local update, reply refreshes).
@(private = "file")
adm_send_settings :: proc(c: ^Server_Conn, s: shared.Admin_Settings) {
	c.admin.settings = s
	conn_request(c, {kind = shared.K_ADMIN_SET, settings = s})
}

@(private = "file")
adm_user_info :: proc(c: ^Server_Conn, id: u64) -> shared.Admin_User {
	for a in c.admin.users {
		if a.id == id {
			return a
		}
	}
	return {id = id}
}

@(private = "file")
adm_seen_label :: proc(app: ^App, ms: i64) -> string {
	if ms <= 0 {
		return "noch nie angemeldet"
	}
	return fmt.tprintf("zuletzt %s, %s", format_day_label(app, ms), format_time_hm(app, ms))
}

// Small [−] value [+] stepper row; returns the new value or -1.
@(private = "file")
adm_stepper :: proc(app: ^App, x, y, w: f32, label, unit: string, value, minv, maxv, step: int, salt: u64) -> int {
	draw_text(app.fonts.regular15, tcstr(label), {x, y + 5}, 15, 0, COL_TEXT)
	out := -1
	bw := f32(28)
	vx := x + w - bw*2 - 76
	if button(app, {vx, y, bw, 28}, "−", .Modal, id_salt = salt ~ 0x51E1) && value > minv {
		out = max(value - step, minv)
	}
	val := fmt.tprintf("%d %s", value, unit)
	draw_text_centered(app.fonts.bold15, val, vx + bw + 34, y + 6, 15, COL_TEXT)
	if button(app, {x + w - bw, y, bw, 28}, "+", .Modal, id_salt = salt ~ 0x51E2) && value < maxv {
		out = min(value + step, maxv)
	}
	return out
}

// Row of mutually exclusive mini buttons; writes the chosen index to sel.
@(private = "file")
adm_seg :: proc(app: ^App, x, y, w: f32, labels: []string, sel: ^int, salt: u64) {
	bw := (w - f32(len(labels) - 1) * 6) / f32(len(labels))
	for label, i in labels {
		r := rl.Rectangle{x + f32(i) * (bw + 6), y, bw, 30}
		active := sel^ == i
		id := anim_id(.Misc, salt ~ (u64(i + 1) << 32))
		hovered := ui_hover(&app.ui, r, .Modal)
		focused := tab_stop(app, id, r, .Modal, radius = RADIUS_BTN)
		t := anim_to(app, id, (hovered || focused) && !active ? 1 : 0, 18)
		rrect(r, RADIUS_BTN, active ? COL_PRIMARY : mix(COL_SURFACE, COL_SURFACE_HOVER, t))
		if !active {
			rrect_lines(r, RADIUS_BTN, 1, COL_BORDER)
		}
		if focused {
			draw_focus_ring(r, RADIUS_BTN)
		}
		tw := rl.MeasureTextEx(app.fonts.regular13, tcstr(label), 13, 0)
		draw_text(app.fonts.regular13, tcstr(label), {r.x + (bw - tw.x)/2, r.y + (30 - tw.y)/2}, 13, 0,
			active ? COL_PRIMARY_FG : COL_TEXT_DIM)
		if hovered {
			app.ui.cursor = .POINTING_HAND
		}
		if ui_click(&app.ui, r, .Modal) || (focused && app.ui.tab_activate) {
			sel^ = i
		}
	}
}

@(private = "file")
adm_section :: proc(app: ^App, x: f32, y: ^f32, title: string) {
	draw_text(app.fonts.bold13, tcstr(title), {x, y^}, 13, 0, COL_TEXT_FAINT)
	y^ += 24
}

draw_admin_modal :: proc(app: ^App, c: ^Server_Conn, sw, sh: f32) {
	w := min(f32(800), sw - 60)
	h := min(f32(620), sh - 40)
	p := modal_frame(app, sw, sh, w, h, fmt.tprintf("Verwaltung · %s", conn_label(c)))

	// Left tab rail
	nav_w := f32(168)
	ny := p.y + 56
	for label, i in ADM_TABS {
		r := rl.Rectangle{p.x + 12, ny, nav_w - 20, 34}
		active := app.adm_tab == i
		id := anim_id(.Misc, 0xAD7A0 ~ (u64(i + 1) << 40))
		hovered := ui_hover(&app.ui, r, .Modal)
		focused := tab_stop(app, id, r, .Modal, radius = 7)
		t := anim_to(app, id, (hovered || focused) && !active ? 1 : 0, 18)
		if active {
			rrect(r, 7, COL_PRIMARY)
		} else if t > 0.01 {
			rrect(r, 7, fade(COL_SIDEBAR_HOVER, t))
		}
		if focused {
			draw_focus_ring(r, 7)
		}
		font := active ? app.fonts.bold15 : app.fonts.regular15
		draw_text(font, tcstr(label), {r.x + 12, r.y + (34 - 15)/2 - 1}, 15, 0,
			active ? COL_PRIMARY_FG : COL_TEXT)
		if hovered {
			app.ui.cursor = .POINTING_HAND
		}
		if (ui_click(&app.ui, r, .Modal) || (focused && app.ui.tab_activate)) && !active {
			app.adm_tab = i
			app.adm_reset_user = 0
			app.adm_confirm_del = 0
			scroll_to(&app.modal_scroll, 0)
		}
		ny += 38
	}
	rl.DrawLineEx({p.x + nav_w, p.y + 52}, {p.x + nav_w, p.y + p.height - 12}, 1, COL_BORDER_SOFT)

	content := rl.Rectangle{p.x + nav_w + 20, p.y + 56, p.width - nav_w - 40, p.height - 72}

	if !c.admin_loaded {
		if c.admin_loading {
			draw_spinner(content.x + content.width/2, content.y + content.height/2, 14, COL_ACCENT)
		}
		return
	}

	switch app.adm_tab {
	case 0:
		adm_tab_general(app, c, content)
	case 1:
		adm_tab_access(app, c, content)
	case 2:
		adm_tab_users(app, c, content)
	case 3:
		adm_tab_channels(app, c, content)
	case 4:
		adm_tab_security(app, c, content)
	}
}

// ---------- Tab: Allgemein ----------

@(private = "file")
adm_tab_general :: proc(app: ^App, c: ^Server_Conn, area: rl.Rectangle) {
	x := area.x
	cw := area.width - 8
	y := area.y + 4

	adm_section(app, x, &y, "SERVERNAME")
	submitted := text_field(app, {x, y, cw - 124, 38}, &app.adm_name_input, .Adm_Name, .Modal, "Name des Servers")
	if button(app, {x + cw - 112, y, 112, 38}, "Speichern", .Modal, style = .Primary, id_salt = 0xAD5A7E) || submitted {
		name := strings.trim_space(ti_text(&app.adm_name_input))
		if len(name) >= 1 && len(name) <= 64 {
			conn_request(c, {kind = shared.K_SETUP, server_name = name})
		} else {
			toast(app, .Error, "Name: 1–64 Zeichen")
		}
	}
	y += 56
	draw_text(app.fonts.regular13, "Der Name erscheint bei allen Mitgliedern in der Seitenleiste.",
		{x, y}, 13, 0, COL_TEXT_FAINT)
	y += 36

	adm_section(app, x, &y, "ÜBERBLICK")
	st := &c.admin
	active_users := 0
	admins := 0
	for a in st.users {
		if !a.disabled {
			active_users += 1
		}
	}
	for u in c.users {
		if u.is_admin && !adm_user_info(c, u.id).disabled {
			admins += 1
		}
	}
	open_invites := 0
	for inv in st.invites {
		if inv.used_by == 0 && (inv.expires_ms == 0 || inv.expires_ms > unix_now_ms()) {
			open_invites += 1
		}
	}
	lines := [?]string{
		fmt.tprintf("%d Konten (%d aktiv, %d Admins)", len(st.users), active_users, admins),
		fmt.tprintf("%d Channels, %d Direktnachrichten-Kanäle", len(st.channels), st.dm_count),
		fmt.tprintf("%d offene Einladungen", open_invites),
		fmt.tprintf("%d gesperrte IP-Adressen", len(st.bans)),
		fmt.tprintf("Registrierung: %s", st.settings.registration_closed ? "geschlossen (nur mit Einladung)" : "offen"),
	}
	for line in lines {
		draw_text(app.fonts.regular15, tcstr(line), {x, y}, 15, 0, COL_TEXT)
		y += 26
	}
}

// ---------- Tab: Zugang ----------

@(private = "file")
adm_tab_access :: proc(app: ^App, c: ^Server_Conn, area: rl.Rectangle) {
	st := &c.admin
	x := area.x
	cw := area.width - 8

	n_inv := len(st.invites)
	content_h := 422 + f32(max(n_inv, 1)) * 42
	hovered := ui_hover(&app.ui, area, .Modal)
	scroll_update(app, &app.modal_scroll, hovered, max(0, content_h - area.height), 46)
	scissor_begin(area.x, area.y, area.width, area.height)
	defer {
		scissor_end()
		scrollbar(app, area, content_h, &app.modal_scroll, .Modal)
	}
	y := area.y + 4 - app.modal_scroll.pos

	// Registration toggle
	draw_text(app.fonts.regular15, "Offene Registrierung", {x, y + 2}, 15, 0, COL_TEXT)
	desc := "Jeder, der den Server erreicht, kann sich ein Konto erstellen"
	if st.settings.registration_closed {
		desc = "Geschlossen: Beitritt nur mit Einladungscode oder vorab erstelltem Konto"
	}
	draw_text(app.fonts.regular13, tcstr(trim_label(app, app.fonts.regular13, 13, desc, cw - 64)),
		{x, y + 22}, 13, 0, COL_TEXT_FAINT)
	if toggle_switch(app, {x + cw - 46, y + 4, 46, 26}, anim_id(.Misc, 0xAD9E61), !st.settings.registration_closed, .Modal) {
		s := st.settings
		s.registration_closed = !s.registration_closed
		adm_send_settings(c, s)
	}
	y += 56

	// Invites
	adm_section(app, x, &y, "EINLADUNGEN")
	draw_text(app.fonts.regular13, "Gültigkeit", {x, y + 8}, 13, 0, COL_TEXT_DIM)
	adm_seg(app, x + 90, y, cw - 90 - 150, ADM_INVITE_LABELS[:], &app.adm_invite_sel, 0xAD5E9)
	if button(app, {x + cw - 140, y, 140, 30}, "Neue Einladung", .Modal, style = .Primary, id_salt = 0xADC0DE) {
		conn_request(c, {kind = shared.K_ADMIN_CREATE_INVITE, minutes = ADM_INVITE_OPTS[app.adm_invite_sel]})
	}
	y += 44

	if n_inv == 0 {
		draw_text(app.fonts.regular13, "Noch keine Einladungen erstellt.", {x, y + 8}, 13, 0, COL_TEXT_FAINT)
		y += 42
	}
	for i := n_inv - 1; i >= 0; i -= 1 {
		inv := st.invites[i]
		if y + 42 > area.y && y < area.y + area.height {
			draw_text(app.fonts.mono15, tcstr(inv.code), {x, y + 10}, 15, 0, COL_TEXT)
			status: string
			scol := COL_TEXT_FAINT
			now := unix_now_ms()
			switch {
			case inv.used_by != 0:
				status = fmt.tprintf("eingelöst von %s", user_label(c, inv.used_by))
			case inv.expires_ms > 0 && inv.expires_ms <= now:
				status = "abgelaufen"
				scol = COL_RED
			case inv.expires_ms > 0:
				status = fmt.tprintf("gültig bis %s, %s", format_day_label(app, inv.expires_ms), format_time_hm(app, inv.expires_ms))
				scol = COL_ONLINE
			case:
				status = "unbefristet gültig"
				scol = COL_ONLINE
			}
			draw_text(app.fonts.regular13, tcstr(status), {x + 110, y + 11}, 13, 0, scol)
			usable := inv.used_by == 0 && (inv.expires_ms == 0 || inv.expires_ms > now)
			if button(app, {x + cw - 100, y + 3, 100, 30}, "Entfernen", .Modal, style = .Danger, id_salt = 0xAD0F ~ (u64(i + 1) << 24)) {
				conn_request(c, {kind = shared.K_ADMIN_REVOKE_INVITE, invite_code = inv.code})
			}
			if usable {
				if button(app, {x + cw - 100 - 98, y + 3, 92, 30}, "Kopieren", .Modal, id_salt = 0xADCB ~ (u64(i + 1) << 24)) {
					rl.SetClipboardText(tcstr(inv.code))
					toast(app, .Success, "Code kopiert")
				}
			}
		}
		y += 42
	}
	y += 24

	// Pre-created accounts
	adm_section(app, x, &y, "KONTO VORAB ANLEGEN")
	half := (cw - 12) / 2
	draw_text(app.fonts.regular13, "Nutzername", {x, y}, 13, 0, COL_TEXT_DIM)
	draw_text(app.fonts.regular13, "Anzeigename", {x + half + 12, y}, 13, 0, COL_TEXT_DIM)
	y += 18
	text_field(app, {x, y, half, 36}, &app.adm_user_input, .Adm_User, .Modal, "vorname.nachname")
	text_field(app, {x + half + 12, y, half, 36}, &app.adm_disp_input, .Adm_Display, .Modal, "Vorname Nachname")
	y += 46
	draw_text(app.fonts.regular13, "Startpasswort (bitte sicher übermitteln)", {x, y}, 13, 0, COL_TEXT_DIM)
	y += 18
	text_field(app, {x, y, half, 36}, &app.adm_pass_input, .Adm_Pass, .Modal, "mindestens 6 Zeichen")
	if button(app, {x + half + 12, y, 150, 36}, "Konto erstellen", .Modal, style = .Primary, id_salt = 0xADAC0) {
		user := strings.trim_space(ti_text(&app.adm_user_input))
		pass := ti_text(&app.adm_pass_input)
		disp := strings.trim_space(ti_text(&app.adm_disp_input))
		if !shared.valid_username(user) {
			toast(app, .Error, "Nutzername: 2–32 Zeichen, nur a-z 0-9 . _ -")
		} else if len(pass) < shared.MIN_PASSWORD_LEN {
			toast(app, .Error, "Passwort: mindestens 6 Zeichen")
		} else {
			conn_request(c, {kind = shared.K_ADMIN_CREATE_USER, username = user, password = pass, display_name = disp})
		}
	}
	y += 60
}

// ---------- Tab: Nutzer ----------

@(private = "file")
adm_tab_users :: proc(app: ^App, c: ^Server_Conn, area: rl.Rectangle) {
	x := area.x
	cw := area.width - 8
	row_h := f32(66)

	content_h := f32(len(c.users)) * row_h + 8
	if app.adm_reset_user != 0 {
		content_h += 48
	}
	hovered := ui_hover(&app.ui, area, .Modal)
	scroll_update(app, &app.modal_scroll, hovered, max(0, content_h - area.height), 46)
	scissor_begin(area.x, area.y, area.width, area.height)
	defer {
		scissor_end()
		scrollbar(app, area, content_h, &app.modal_scroll, .Modal)
	}
	y := area.y + 4 - app.modal_scroll.pos

	for u in c.users {
		info := adm_user_info(c, u.id)
		visible := y + row_h > area.y && y < area.y + area.height
		if visible {
			draw_avatar(app, u.username, x, y + 10, 34, presence = true, online = u.online, c = c, uid = u.id)
			label := u.display_name != "" ? u.display_name : u.username
			name_col := info.disabled ? COL_TEXT_FAINT : COL_TEXT
			draw_text(app.fonts.bold15, tcstr(label), {x + 46, y + 10}, 15, 0, name_col)
			nx := x + 46 + rl.MeasureTextEx(app.fonts.bold15, tcstr(label), 15, 0).x + 8
			if u.is_admin {
				draw_text(app.fonts.regular13, "Admin", {nx, y + 12}, 13, 0, COL_ACCENT)
				nx += 46
			}
			if info.disabled {
				draw_text(app.fonts.regular13, "Deaktiviert", {nx, y + 12}, 13, 0, COL_RED)
				nx += 78
			}
			if u.id == c.me.id {
				draw_text(app.fonts.regular13, "du", {nx, y + 12}, 13, 0, COL_TEXT_FAINT)
			}
			sub := fmt.tprintf("@%s · %s", u.username, u.online ? "online" : adm_seen_label(app, info.last_seen_ms))
			if info.last_ip != "" {
				sub = fmt.tprintf("%s · %s", sub, info.last_ip)
			}
			draw_text(app.fonts.regular13, tcstr(trim_label(app, app.fonts.regular13, 13, sub, cw - 46 - 240)),
				{x + 46, y + 32}, 13, 0, COL_TEXT_FAINT)

			// 2×2 action grid on the right (never for yourself)
			if u.id != c.me.id {
				bw := f32(112)
				bx1 := x + cw - bw*2 - 6
				bx2 := x + cw - bw
				salt := u64(u.id + 1) << 16
				if button(app, {bx1, y + 4, bw, 27}, u.is_admin ? "Admin entziehen" : "Zum Admin", .Modal,
					id_salt = salt ~ 0xA1) {
					conn_request(c, {kind = shared.K_ADMIN_SET_ROLE, user_id = u.id, is_admin = !u.is_admin})
				}
				if button(app, {bx2, y + 4, bw, 27}, info.disabled ? "Aktivieren" : "Deaktivieren", .Modal,
					style = info.disabled ? .Default : .Danger, id_salt = salt ~ 0xA2) {
					conn_request(c, {kind = shared.K_ADMIN_SET_DISABLED, user_id = u.id, disabled = !info.disabled})
				}
				if button(app, {bx1, y + 35, bw, 27}, "Passwort…", .Modal, id_salt = salt ~ 0xA3) {
					app.adm_reset_user = app.adm_reset_user == u.id ? 0 : u.id
					ti_clear(&app.adm_reset_input)
					if app.adm_reset_user != 0 {
						app.ui.focus = .Adm_Reset
					}
				}
				if info.last_ip != "" {
					if button(app, {bx2, y + 35, bw, 27}, "IP sperren", .Modal, style = .Danger, id_salt = salt ~ 0xA4) {
						conn_request(c, {kind = shared.K_ADMIN_BAN_IP, ip = info.last_ip, minutes = 0})
					}
				}
			}
		}
		y += row_h

		// Inline password reset row below the affected user
		if app.adm_reset_user == u.id {
			if y + 48 > area.y && y < area.y + area.height {
				draw_text(app.fonts.regular13, "Neues Passwort:", {x + 46, y + 10}, 13, 0, COL_TEXT_DIM)
				fw := cw - 158 - 196
				submitted := text_field(app, {x + 158, y, fw, 34}, &app.adm_reset_input, .Adm_Reset, .Modal, "mindestens 6 Zeichen")
				if button(app, {x + cw - 190, y, 92, 34}, "Setzen", .Modal, style = .Primary, id_salt = 0xADFE ~ (u64(u.id) << 20)) || submitted {
					pass := ti_text(&app.adm_reset_input)
					if len(pass) < shared.MIN_PASSWORD_LEN {
						toast(app, .Error, "Passwort: mindestens 6 Zeichen")
					} else {
						conn_request(c, {kind = shared.K_ADMIN_RESET_PASSWORD, user_id = u.id, password = pass})
					}
				}
				if button(app, {x + cw - 90, y, 90, 34}, "Abbrechen", .Modal, id_salt = 0xADFF ~ (u64(u.id) << 20)) {
					app.adm_reset_user = 0
					ti_clear(&app.adm_reset_input)
				}
			}
			y += 48
		}

		if visible {
			rl.DrawLineEx({x, y - 5}, {x + cw, y - 5}, 1, COL_BORDER_SOFT)
		}
	}
}

// ---------- Tab: Channels ----------

@(private = "file")
adm_tab_channels :: proc(app: ^App, c: ^Server_Conn, area: rl.Rectangle) {
	st := &c.admin
	x := area.x
	cw := area.width - 8
	row_h := f32(48)

	content_h := f32(len(st.channels)) * row_h + 60
	hovered := ui_hover(&app.ui, area, .Modal)
	scroll_update(app, &app.modal_scroll, hovered, max(0, content_h - area.height), 46)
	scissor_begin(area.x, area.y, area.width, area.height)
	defer {
		scissor_end()
		scrollbar(app, area, content_h, &app.modal_scroll, .Modal)
	}
	y := area.y + 4 - app.modal_scroll.pos

	if len(st.channels) == 0 {
		draw_text(app.fonts.regular13, "Es gibt noch keine Channels.", {x, y + 8}, 13, 0, COL_TEXT_FAINT)
		y += 42
	}
	for ch in st.channels {
		if y + row_h > area.y && y < area.y + area.height {
			draw_text(app.fonts.bold15, tcstr(fmt.tprintf("# %s", ch.name)), {x, y + 6}, 15, 0, COL_TEXT)
			sub := fmt.tprintf("%d Mitglieder · erstellt von %s", ch.members, user_label(c, ch.creator_id))
			draw_text(app.fonts.regular13, tcstr(trim_label(app, app.fonts.regular13, 13, sub, cw - 160)),
				{x, y + 26}, 13, 0, COL_TEXT_FAINT)

			confirm := app.adm_confirm_del == ch.id
			label := confirm ? "Endgültig?" : "Löschen"
			if button(app, {x + cw - 108, y + 8, 108, 30}, label, .Modal,
				style = confirm ? .Danger_Solid : .Danger, id_salt = 0xADDE ~ (u64(ch.id + 1) << 20)) {
				if confirm {
					app.adm_confirm_del = 0
					conn_request(c, {kind = shared.K_DELETE_CHANNEL, channel_id = ch.id}, {channel_id = ch.id})
				} else {
					app.adm_confirm_del = ch.id
				}
			}
		}
		y += row_h
	}
	y += 8
	note := fmt.tprintf("Dazu %d private Direktnachrichten-Kanäle (werden hier nicht aufgeführt).", st.dm_count)
	draw_text(app.fonts.regular13, tcstr(trim_label(app, app.fonts.regular13, 13, note, cw)),
		{x, y}, 13, 0, COL_TEXT_FAINT)
}

// ---------- Tab: Sicherheit ----------

@(private = "file")
adm_tab_security :: proc(app: ^App, c: ^Server_Conn, area: rl.Rectangle) {
	st := &c.admin
	x := area.x
	cw := area.width - 8

	f2b_rows := st.settings.f2b_disabled ? 0 : 3
	content_h := 244 + f32(f2b_rows) * 38 + f32(max(len(st.bans), 1)) * 50
	hovered := ui_hover(&app.ui, area, .Modal)
	scroll_update(app, &app.modal_scroll, hovered, max(0, content_h - area.height), 46)
	scissor_begin(area.x, area.y, area.width, area.height)
	defer {
		scissor_end()
		scrollbar(app, area, content_h, &app.modal_scroll, .Modal)
	}
	y := area.y + 4 - app.modal_scroll.pos

	// fail2ban toggle + steppers
	draw_text(app.fonts.regular15, "Brute-Force-Schutz (Fail2ban)", {x, y + 2}, 15, 0, COL_TEXT)
	draw_text(app.fonts.regular13,
		tcstr(trim_label(app, app.fonts.regular13, 13,
			"Sperrt IP-Adressen automatisch nach zu vielen fehlgeschlagenen Anmeldeversuchen", cw - 64)),
		{x, y + 22}, 13, 0, COL_TEXT_FAINT)
	if toggle_switch(app, {x + cw - 46, y + 4, 46, 26}, anim_id(.Misc, 0xADF2B), !st.settings.f2b_disabled, .Modal) {
		s := st.settings
		s.f2b_disabled = !s.f2b_disabled
		adm_send_settings(c, s)
	}
	y += 54

	if !st.settings.f2b_disabled {
		s := st.settings
		if v := adm_stepper(app, x, y, cw, "Fehlversuche bis zur Sperre", "", s.f2b_max_fails, 2, 50, 1, 0xADF1); v >= 0 {
			s.f2b_max_fails = v
			adm_send_settings(c, s)
		}
		y += 38
		if v := adm_stepper(app, x, y, cw, "Zeitfenster", "min", s.f2b_window_min, 1, 1440, 5, 0xADF2); v >= 0 {
			s.f2b_window_min = v
			adm_send_settings(c, s)
		}
		y += 38
		if v := adm_stepper(app, x, y, cw, "Sperrdauer", "min", s.f2b_ban_min, 5, 10080, 5, 0xADF3); v >= 0 {
			s.f2b_ban_min = v
			adm_send_settings(c, s)
		}
		y += 38
	}
	y += 16

	// Manual IP ban
	adm_section(app, x, &y, "IP-ADRESSE SPERREN")
	text_field(app, {x, y, cw - 260, 36}, &app.adm_ban_input, .Adm_Ban, .Modal, "z. B. 203.0.113.7")
	if button(app, {x + cw - 100, y, 100, 36}, "Sperren", .Modal, style = .Danger_Solid, id_salt = 0xADBA9) {
		ip := strings.trim_space(ti_text(&app.adm_ban_input))
		if ip == "" {
			toast(app, .Error, "Bitte eine IP-Adresse eingeben")
		} else {
			conn_request(c, {kind = shared.K_ADMIN_BAN_IP, ip = ip, minutes = ADM_BAN_OPTS[app.adm_ban_sel]})
		}
	}
	y += 44
	draw_text(app.fonts.regular13, "Dauer", {x, y + 8}, 13, 0, COL_TEXT_DIM)
	adm_seg(app, x + 60, y, cw - 60, ADM_BAN_LABELS[:], &app.adm_ban_sel, 0xADBB1)
	y += 46

	// Active bans
	adm_section(app, x, &y, "AKTIVE SPERREN")
	if len(st.bans) == 0 {
		draw_text(app.fonts.regular13, "Keine IP-Adresse gesperrt.", {x, y + 6}, 13, 0, COL_TEXT_FAINT)
		y += 42
	}
	for b, i in st.bans {
		if y + 50 > area.y && y < area.y + area.height {
			draw_text(app.fonts.mono15, tcstr(b.ip), {x, y + 6}, 15, 0, COL_TEXT)
			source := "automatisch (fail2ban)"
			if b.by_user != 0 {
				source = fmt.tprintf("manuell %s", b.reason)
			}
			until := "permanent"
			if b.expires_ms > 0 {
				until = fmt.tprintf("bis %s, %s", format_day_label(app, b.expires_ms), format_time_hm(app, b.expires_ms))
			}
			draw_text(app.fonts.regular13, tcstr(fmt.tprintf("%s · %s", source, until)),
				{x, y + 27}, 13, 0, COL_TEXT_FAINT)
			if button(app, {x + cw - 110, y + 8, 110, 30}, "Entsperren", .Modal, id_salt = 0xADEB ~ (u64(i + 1) << 20)) {
				conn_request(c, {kind = shared.K_ADMIN_UNBAN_IP, ip = b.ip})
			}
		}
		y += 50
	}
}
