package main

// Server-Rail (links außen) und Sidebar (Channels + DMs + Profil-Footer).

import "core:fmt"

import rl "vendor:raylib"
import shared "../shared"

FOOTER_H :: f32(56)

// --- Server-Rail ---

draw_rail :: proc(app: ^App, sh: f32) {
	rl.DrawRectangleRec({0, 0, RAIL_W, sh}, COL_RAIL_BG)
	rl.DrawLineEx({RAIL_W, 0}, {RAIL_W, sh}, 1, COL_SIDEBAR_LINE)

	y := f32(12)
	for c, i in app.conns {
		r := rl.Rectangle{14, y, 40, 40}
		name := conn_label(c)

		hovered := ui_hover(&app.ui, r, .Base)
		active := i == app.active
		focused := tab_stop(app, anim_id(.Rail_Hover, u64(i)), r, .Base, radius = 14)
		t := anim_to(app, anim_id(.Rail_Hover, u64(i)), (hovered || active || focused) ? 1 : 0)

		// Squircle-Morph: rund im Ruhezustand, eckiger bei Hover/Aktiv
		radius := 20 - t*8
		rrect(r, radius, hash_color(name))
		if focused {
			draw_focus_ring(r, radius)
		}
		ini := initials(name)
		tw := rl.MeasureTextEx(app.fonts.bold15, tcstr(ini), 15, 0)
		draw_text(app.fonts.bold15, tcstr(ini),
			{r.x + (r.width - tw.x)/2, r.y + (r.height - tw.y)/2}, 15, 0, COL_WHITE)

		// Aktiv-Pille am linken Rand (wächst bei Hover, voll bei Aktiv)
		ph := anim_to(app, anim_id(.Rail_Active, u64(i)), active ? 28 : (hovered ? 10 : 0), 16)
		if ph > 1 {
			rrect({0, r.y + (r.height - ph)/2, 4, ph}, 2, COL_PRIMARY)
		}

		// Unread-Punkt oben rechts
		if conn_has_unread(c) {
			rl.DrawCircleV({r.x + r.width - 2, r.y + 2}, 6.5, COL_RAIL_BG)
			rl.DrawCircleV({r.x + r.width - 2, r.y + 2}, 4.5, COL_BADGE)
		}

		// Verbindungsstatus unten rechts
		status := COL_YELLOW
		#partial switch conn_phase(c) {
		case .Ready:
			status = COL_ONLINE
		case .Failed:
			status = COL_RED
		}
		rl.DrawCircleV({r.x + r.width - 2, r.y + r.height - 2}, 6, COL_RAIL_BG)
		rl.DrawCircleV({r.x + r.width - 2, r.y + r.height - 2}, 4, status)

		if hovered {
			app.ui.cursor = .POINTING_HAND
		}
		tip := len(app.conns) > 1 ? fmt.tprintf("%s  ·  Strg+%d", name, i+1) : name
		tooltip(app, anim_id(.Rail_Hover, u64(i) ~ 0xF00), r, tip, .Base)
		if ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate) {
			app.active = i
		}
		y += 52
	}

	// "+"-Button unten
	plus := rl.Rectangle{14, sh - 54, 40, 40}
	hovered := ui_hover(&app.ui, plus, .Base)
	focused := tab_stop(app, anim_id(.Rail_Hover, 0xADD), plus, .Base, radius = 14)
	t := anim_to(app, anim_id(.Rail_Hover, 0xADD), (hovered || focused) ? 1 : 0)
	rrect(plus, 20 - t*8, mix(COL_RAIL_ITEM, COL_PRIMARY, t))
	if focused {
		draw_focus_ring(plus, 20 - t*8)
	}
	draw_plus(plus.x + plus.width/2, plus.y + plus.height/2, 7, 2, mix(COL_SIDEBAR_TEXT, COL_PRIMARY_FG, t))
	if hovered {
		app.ui.cursor = .POINTING_HAND
	}
	tooltip(app, anim_id(.Rail_Hover, 0xADD2), plus, "Server hinzufügen", .Base)
	if ui_click(&app.ui, plus, .Base) || (focused && app.ui.tab_activate) {
		open_modal(app, .Add_Server)
	}
}

// --- Sidebar ---

// Abgerundete Sidebar-Zeile mit Hover-Animation. id muss stabil sein.
// view + scroll werden gebraucht, um per Tab fokussierte Zeilen in den
// sichtbaren Bereich zu scrollen.
@(private = "file")
sidebar_row :: proc(app: ^App, view: rl.Rectangle, s: ^Scroll, r: rl.Rectangle, id: u64, active: bool) -> (clicked, rclicked: bool) {
	inset := rl.Rectangle{r.x + 8, r.y, r.width - 16, r.height}
	hovered := ui_hover(&app.ui, inset, .Base)
	focused := tab_stop(app, anim_id(.Sidebar_Row, id), inset, .Base, radius = 6)
	t := anim_to(app, anim_id(.Sidebar_Row, id), (hovered || focused) && !active ? 1 : 0)
	if active {
		rrect(inset, 6, COL_PRIMARY)
	} else if t > 0.01 {
		rrect(inset, 6, fade(COL_SIDEBAR_HOVER, t))
	}
	if focused {
		draw_focus_ring(inset, 6)
		if inset.y < view.y + 4 {
			s.target = max(0, s.target - (view.y + 4 - inset.y))
		} else if inset.y + inset.height > view.y + view.height - 4 {
			s.target += inset.y + inset.height - (view.y + view.height - 4)
		}
	}
	if hovered {
		app.ui.cursor = .POINTING_HAND
	}
	clicked = ui_click(&app.ui, inset, .Base) || (focused && app.ui.tab_activate)
	rclicked = hovered && app.ui.rclicked
	return
}

// Zeichnet den Unread-Badge (rechte Kante bei right_x) und gibt seine
// Breite zurück — daneben platzierte Icons rücken entsprechend nach links.
@(private = "file")
draw_badge :: proc(app: ^App, right_x, cy: f32, count: int, pop_id: u64) -> f32 {
	label := fmt.tprintf("%d", count)
	tw := rl.MeasureTextEx(app.fonts.bold13, tcstr(label), 13, 0)
	w := max(tw.x + 12, 20)
	s := anim_pop_scale(app, pop_id)
	sw := w * s
	sH := 18 * s
	r := rl.Rectangle{right_x - w + (w - sw)/2, cy - sH/2, sw, sH}
	rrect(r, sH/2, COL_BADGE)
	draw_text(app.fonts.bold13, tcstr(label), {right_x - w + (w - tw.x)/2, cy - 6}, 13, 0, COL_WHITE)
	return w
}

draw_sidebar :: proc(app: ^App, c: ^Server_Conn, phase: Conn_Phase, sh: f32) {
	rl.DrawRectangleRec({RAIL_W, 0, SIDEBAR_W, sh}, COL_SIDEBAR_BG)

	// Kopfzeile mit Servername
	name := conn_label(c)
	draw_text(app.fonts.bold18, tcstr(name), {RAIL_W + 16, (HEADER_H - 18) / 2}, 18, 0, COL_TEXT)
	rl.DrawLineEx({RAIL_W, HEADER_H}, {RAIL_W + SIDEBAR_W, HEADER_H}, 1, COL_SIDEBAR_LINE)
	rl.DrawLineEx({RAIL_W + SIDEBAR_W, 0}, {RAIL_W + SIDEBAR_W, sh}, 1, COL_SIDEBAR_LINE)

	if phase != .Ready {
		return
	}

	has_footer := c.me.id != 0
	panel_h := app.call.active && !app.call.popout ? CALL_PANEL_H : 0
	view_h := sh - HEADER_H - (has_footer ? FOOTER_H : 0) - panel_h
	view := rl.Rectangle{RAIL_W, HEADER_H, SIDEBAR_W, view_h}

	// Inhaltshöhe (Zeilen à 30, Sektions-Header à 34)
	n_channels := 0
	for &cs in c.channels {
		if !cs.ch.is_dm {
			n_channels += 1
		}
	}
	n_users := 0
	for u in c.users {
		if u.id != c.me.id {
			n_users += 1
		}
	}
	content_h := f32(12 + 34 + n_channels*30 + 30 + 18 + 34 + n_users*30 + 16)
	max_scroll := max(0, content_h - view.height)
	hovered_view := ui_hover(&app.ui, view, .Base)
	scroll_update(app, &c.sidebar_scroll, hovered_view, max_scroll, 46)

	scissor_begin(view.x, view.y, view.width, view.height)

	x := f32(RAIL_W)
	y := view.y + 12 - c.sidebar_scroll.pos

	// Sektion: Channels
	draw_text(app.fonts.bold13, "Channels", {x + 18, y + 9}, 13, 0, COL_SIDEBAR_DIM)
	y += 34
	for &cs in c.channels {
		if cs.ch.is_dm {
			continue
		}
		row := rl.Rectangle{x, y, SIDEBAR_W, 30}
		is_active := c.active_channel == cs.ch.id
		clicked, rclicked := sidebar_row(app, view, &c.sidebar_scroll, row, cs.ch.id, is_active)
		if clicked {
			app_activate_channel(app, c, cs.ch.id)
		}
		if rclicked {
			ctx_open(app, cs.ch.id)
		}
		col := is_active ? COL_PRIMARY_FG : COL_SIDEBAR_TEXT
		font := app.fonts.regular15
		if cs.unread > 0 && !is_active {
			col = COL_TEXT
			font = app.fonts.bold15
		}
		draw_text(app.fonts.regular15, "#", {x + 20, y + 7}, 15, 0, is_active ? fade(COL_PRIMARY_FG, 0.8) : COL_SIDEBAR_DIM)
		draw_text(font, tcstr(cs.ch.name), {x + 36, y + 7}, 15, 0, col)
		right := x + SIDEBAR_W - 16
		if cs.unread > 0 && !is_active {
			right -= draw_badge(app, right, y + 15, cs.unread, anim_id(.Badge_Pop, cs.ch.id)) + 10
		}
		if cc := c.calls[cs.ch.id]; len(cc.peers) > 0 {
			// Hier läuft gerade ein Voice-Call: Kopfhörer + Teilnehmerzahl
			icol := is_active ? COL_PRIMARY_FG : COL_ONLINE
			cnt := fmt.tprintf("%d", len(cc.peers))
			cw := rl.MeasureTextEx(app.fonts.bold11, tcstr(cnt), 11, 0).x
			draw_text(app.fonts.bold11, tcstr(cnt), {right - cw, y + 9}, 11, 0, icol)
			draw_headphones(right - cw - 11, y + 14, 6, 1.8, icol)
		}
		y += 30
	}

	// Kanal erstellen
	{
		row := rl.Rectangle{x, y, SIDEBAR_W, 30}
		clicked, _ := sidebar_row(app, view, &c.sidebar_scroll, row, 0xC4EA7E, false)
		if clicked {
			open_modal(app, .Create_Channel)
		}
		rl.DrawCircleV({x + 27, y + 15}, 9, fade(COL_OVERLAY, 0.05))
		draw_plus(x + 27, y + 15, 4, 2, COL_SIDEBAR_TEXT)
		draw_text(app.fonts.regular15, "Kanal erstellen", {x + 44, y + 7}, 15, 0, COL_SIDEBAR_DIM)
		y += 30 + 18
	}

	// Sektion: Direktnachrichten
	draw_text(app.fonts.bold13, "Direktnachrichten", {x + 18, y + 9}, 13, 0, COL_SIDEBAR_DIM)
	y += 34
	for u in c.users {
		if u.id == c.me.id {
			continue
		}
		dm := conn_find_dm(c, u.id)
		is_active := dm != nil && c.active_channel == dm.ch.id
		row := rl.Rectangle{x, y, SIDEBAR_W, 30}
		clicked, rclicked := sidebar_row(app, view, &c.sidebar_scroll, row, u.id ~ 0xD3, is_active)
		if clicked {
			open_dm_with(app, c, u.id)
		}
		if rclicked && dm != nil {
			ctx_open(app, dm.ch.id)
		}
		draw_avatar(app, u.username, x + 18, y + 4, 22, presence = true, online = u.online, c = c, uid = u.id)
		label := u.display_name != "" ? u.display_name : u.username
		col := is_active ? COL_PRIMARY_FG : (u.online ? COL_SIDEBAR_TEXT : COL_SIDEBAR_DIM)
		font := app.fonts.regular15
		unread := dm != nil ? dm.unread : 0
		if unread > 0 && !is_active {
			col = COL_TEXT
			font = app.fonts.bold15
		}
		draw_text(font, tcstr(label), {x + 48, y + 7}, 15, 0, col)
		if unread > 0 && !is_active && dm != nil {
			draw_badge(app, x + SIDEBAR_W - 16, y + 15, unread, anim_id(.Badge_Pop, dm.ch.id))
		} else if u.in_call {
			// Kopfhörer: die Person ist gerade in einem Voice-Call
			draw_headphones(x + SIDEBAR_W - 26, y + 14, 6, 1.8, is_active ? COL_PRIMARY_FG : COL_ONLINE)
		}
		y += 30
	}
	scissor_end()

	scrollbar(app, view, content_h, &c.sidebar_scroll, .Base)

	// Aktiver Call: Panel zwischen Liste und Profil-Footer
	draw_call_panel(app, sh, has_footer ? FOOTER_H : 0)

	// Profil-Footer
	if has_footer {
		fy := sh - FOOTER_H
		rl.DrawRectangleRec({RAIL_W, fy, SIDEBAR_W, FOOTER_H}, COL_RAIL_BG)
		rl.DrawLineEx({RAIL_W, fy}, {RAIL_W + SIDEBAR_W, fy}, 1, COL_SIDEBAR_LINE)
		draw_avatar(app, c.me.username, RAIL_W + 14, fy + (FOOTER_H - 32)/2, 32, presence = true, online = true, c = c, uid = c.me.id)
		label := c.me.display_name != "" ? c.me.display_name : c.me.username
		draw_text(app.fonts.bold15, tcstr(label), {RAIL_W + 56, fy + 11}, 15, 0, COL_TEXT)
		sub := c.me.is_admin ? fmt.tprintf("@%s · Admin", c.me.username) : fmt.tprintf("@%s", c.me.username)
		draw_text(app.fonts.regular13, tcstr(sub), {RAIL_W + 56, fy + 30}, 13, 0, COL_SIDEBAR_DIM)

		// Zahnrad → App-Einstellungen
		gr := rl.Rectangle{RAIL_W + SIDEBAR_W - 44, fy + (FOOTER_H - 32)/2, 32, 32}
		hovered := ui_hover(&app.ui, gr, .Base)
		focused := tab_stop(app, anim_id(.Misc, 0x6EA5), gr, .Base, radius = 8)
		t := anim_to(app, anim_id(.Misc, 0x6EA5), (hovered || focused) ? 1 : 0)
		rrect(gr, 8, fade(COL_OVERLAY, t*0.08))
		if focused {
			draw_focus_ring(gr, 8)
		}
		draw_gear(gr.x + gr.width/2, gr.y + gr.height/2, 9, 1.8, mix(COL_SIDEBAR_DIM, COL_TEXT, t))
		if hovered {
			app.ui.cursor = .POINTING_HAND
		}
		tooltip(app, anim_id(.Misc, 0x6EA6), gr, "Einstellungen", .Base)
		if ui_click(&app.ui, gr, .Base) || (focused && app.ui.tab_activate) {
			open_settings(app)
		}

		// Shield → server administration (admins only)
		if c.me.is_admin {
			ar := rl.Rectangle{gr.x - 36, gr.y, 32, 32}
			ahov := ui_hover(&app.ui, ar, .Base)
			afoc := tab_stop(app, anim_id(.Misc, 0xAD01), ar, .Base, radius = 8)
			at := anim_to(app, anim_id(.Misc, 0xAD01), (ahov || afoc) ? 1 : 0)
			rrect(ar, 8, fade(COL_OVERLAY, at*0.08))
			if afoc {
				draw_focus_ring(ar, 8)
			}
			draw_shield(ar.x + ar.width/2, ar.y + ar.height/2, 15, 1.8, mix(COL_SIDEBAR_DIM, COL_TEXT, at))
			if ahov {
				app.ui.cursor = .POINTING_HAND
			}
			tooltip(app, anim_id(.Misc, 0xAD02), ar, "Server verwalten", .Base)
			if ui_click(&app.ui, ar, .Base) || (afoc && app.ui.tab_activate) {
				open_admin(app, c)
			}
		}
	}
}

// Wechsel zum nächsten/vorherigen Channel in Sidebar-Reihenfolge (Alt+↑/↓).
sidebar_step_channel :: proc(app: ^App, c: ^Server_Conn, dir: int) {
	// Reihenfolge: erst Channels, dann DMs in User-Reihenfolge
	order := make([dynamic]u64, context.temp_allocator)
	for &cs in c.channels {
		if !cs.ch.is_dm {
			append(&order, cs.ch.id)
		}
	}
	for u in c.users {
		if u.id == c.me.id {
			continue
		}
		if dm := conn_find_dm(c, u.id); dm != nil {
			append(&order, dm.ch.id)
		}
	}
	if len(order) == 0 {
		return
	}
	cur := -1
	for id, i in order {
		if id == c.active_channel {
			cur = i
			break
		}
	}
	next := cur < 0 ? 0 : (cur + dir + len(order)) %% len(order)
	app_activate_channel(app, c, order[next])
}
