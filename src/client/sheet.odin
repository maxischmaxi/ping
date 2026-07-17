package main

// Bearbeitungs-History einer Nachricht: Sheet, das von rechts in den
// Bildschirm hereinfährt. Zeigt alle Versionen mit Zeitstempel, die
// aktuelle zuoberst. Esc, ✕ oder Klick daneben schließen.

import "core:fmt"

import rl "vendor:raylib"
import shared "../shared"

SHEET_W :: f32(420)

// Sheet öffnen und Versionen anfordern (aus dem „Mehr"-Menü).
open_message_history :: proc(app: ^App, c: ^Server_Conn, channel_id, msg_id: u64) {
	app.history_msg_id = msg_id
	app.history_loading = true
	clear(&app.history_versions)
	scroll_to(&app.history_scroll, 0)
	open_modal(app, .Msg_History)
	conn_request(c, {kind = shared.K_MESSAGE_HISTORY, channel_id = channel_id, message_id = msg_id},
		{channel_id = channel_id, message_id = msg_id})
}

draw_history_sheet :: proc(app: ^App, c: ^Server_Conn, sw, sh: f32) {
	// open_modal hat die Öffnungs-Animation (Modal_Open, 1) zurückgesetzt —
	// hier treibt sie das Hereinfahren von rechts an.
	t := anim_to(app, anim_id(.Modal_Open, 1), 1, 14, initial = 0)
	rl.DrawRectangleRec({0, -app.bar_h, sw, sh + app.bar_h}, fade(COL_SCRIM, t*0.8))

	w := min(SHEET_W, sw - 80)
	p := rl.Rectangle{sw - w*ease_out_cubic(t), 0, w, sh}
	draw_shadow(p, 2, 0.7*t)
	rl.DrawRectangleRec(p, COL_SURFACE)
	rl.DrawLineEx({p.x, 0}, {p.x, sh}, 1, COL_BORDER)

	// Kopfzeile
	draw_text(app.fonts.bold18, "Bearbeitungsverlauf", {p.x + 24, 20}, 18, 0, fade(COL_TEXT, t))
	rl.DrawLineEx({p.x, HEADER_H + 4}, {p.x + w, HEADER_H + 4}, 1, COL_BORDER_SOFT)

	// ✕ Schließen
	xr := rl.Rectangle{p.x + w - 44, 13, 30, 30}
	close_id := anim_id(.Msg_Action, 0xC105E)
	xfocused := tab_stop(app, close_id, xr, .Modal, radius = 7)
	xhovered := ui_hover(&app.ui, xr, .Modal)
	xt := anim_to(app, close_id, (xhovered || xfocused) ? 1 : 0, 18)
	if xt > 0.01 {
		rrect(xr, 7, fade(COL_OVERLAY, xt*0.08))
	}
	if xfocused {
		draw_focus_ring(xr, 7)
	}
	if xhovered {
		app.ui.cursor = .POINTING_HAND
	}
	draw_cross(xr.x + 15, xr.y + 15, 10, 1.7, mix(COL_TEXT_DIM, COL_TEXT, xt))
	if ui_click(&app.ui, xr, .Modal) || (xfocused && app.ui.tab_activate) {
		close_modal(app)
		return
	}

	list := rl.Rectangle{p.x, HEADER_H + 5, w, sh - HEADER_H - 5}

	if app.history_loading {
		draw_loading_dots(app, list.x + list.width/2, list.y + list.height/2)
	} else {
		draw_history_list(app, p, list)
	}

	// Klick links neben dem Sheet schließt
	if app.ui.clicked && !rl.CheckCollisionPointRec(app.ui.mouse, p) {
		close_modal(app)
	}
}

@(private = "file")
draw_history_list :: proc(app: ^App, p, list: rl.Rectangle) {
	versions := app.history_versions[:]
	pad := f32(24)
	text_w := list.width - 2*pad

	// Höhe messen (neueste Version zuerst)
	entry_h :: proc(app: ^App, text: string, text_w: f32) -> f32 {
		return 30 + rich_text_height(app, text, text_w) + 20
	}
	content_h := f32(12)
	for v in versions {
		content_h += entry_h(app, v.text, text_w)
	}

	hovered := ui_hover(&app.ui, list, .Modal)
	scroll_update(app, &app.history_scroll, hovered, max(0, content_h - list.height), 52)

	scissor_begin(list.x, list.y, list.width, list.height)
	y := list.y + 12 - app.history_scroll.pos

	for j := len(versions) - 1; j >= 0; j -= 1 {
		v := versions[j]
		eh := entry_h(app, v.text, text_w)
		if y + eh > list.y && y < list.y + list.height {
			tag: string
			switch {
			case j == len(versions) - 1:
				tag = "Aktuell"
			case j == 0:
				tag = "Original"
			case:
				tag = fmt.tprintf("Version %d", j + 1)
			}
			ts := fmt.tprintf("%s, %s", format_day_label(app, v.ts_ms), format_time_hm(app, v.ts_ms))
			tw := rl.MeasureTextEx(app.fonts.bold13, tcstr(tag), 13, 0).x
			draw_text(app.fonts.bold13, tcstr(tag), {list.x + pad, y + 4}, 13, 0,
				j == len(versions) - 1 ? COL_ACCENT : COL_TEXT_DIM)
			draw_text(app.fonts.regular13, tcstr(fmt.tprintf("· %s", ts)),
				{list.x + pad + tw + 8, y + 4}, 13, 0, COL_TEXT_FAINT)

			// Copy-Buttons der Code-Blöcke laufen hier auf dem Modal-Layer.
			// Eigener id-Raum pro Version — dieselbe Nachricht ist ja auch
			// im Chat dahinter sichtbar.
			rich_text(app, v.text, list.x + pad, y + 30, text_w, true,
				app.history_msg_id ~ (u64(j + 1) << 44) ~ 0x4157, .Modal)

			if j > 0 {
				rl.DrawLineEx({list.x + pad, y + eh - 8}, {list.x + list.width - pad, y + eh - 8}, 1, COL_BORDER_SOFT)
			}
		}
		y += eh
	}
	scissor_end()

	scrollbar(app, list, content_h, &app.history_scroll, .Modal)
}
