package main

// Chat-Bereich: Header, Nachrichtenliste (mit Layout-Cache, Day-Separatoren,
// „Neu"-Divider, Smooth-Scroll, History-Paging) und Eingabefeld.

import "core:fmt"
import "core:math"
import "core:strings"

import rl "vendor:raylib"
import shared "../shared"

MSG_GUTTER :: f32(76) // Platz links für Avatar / Hover-Zeit
MSG_PAD_RIGHT :: f32(28)

Row_Kind :: enum {
	Message,
	Day_Sep,
	New_Sep,
}

Msg_Row :: struct {
	kind:    Row_Kind,
	msg_idx: int,
	compact: bool,
	h:       f32,
	day_ms:  i64,
}

// --- Layout-Cache ---

// edit_id/edit_h: Nachricht im Inline-Edit (0 = keine) und die Box-Höhe
// ihres Editors — beides Teil des Cache-Schlüssels, damit Tippen im Editor
// die Zeilenhöhe sofort nachzieht.
@(private = "file")
rows_dirty :: proc(cs: ^Channel_State, text_w: f32, edit_id: u64, edit_h: f32) -> bool {
	return cs.rows_n != len(cs.messages) || cs.rows_w != text_w || cs.rows_divider != cs.divider_id ||
		cs.rows_edit != edit_id || cs.rows_edit_h != edit_h
}

@(private = "file")
build_rows :: proc(app: ^App, cs: ^Channel_State, text_w: f32, edit_id: u64, edit_h: f32) {
	old_h := cs.content_h
	clear(&cs.rows)

	prev_day: i64 = -1
	divider_placed := false
	msgs := cs.messages[:]

	for m, i in msgs {
		dk := day_key(app, m.ts_ms)
		sep_added := false
		if dk != prev_day {
			append(&cs.rows, Msg_Row{kind = .Day_Sep, h = 40, day_ms = m.ts_ms})
			prev_day = dk
			sep_added = true
		}
		if !divider_placed && cs.divider_id > 0 && m.id > cs.divider_id {
			append(&cs.rows, Msg_Row{kind = .New_Sep, h = 28})
			divider_placed = true
			sep_added = true
		}

		compact := false
		if !sep_added && i > 0 {
			prev := msgs[i-1]
			// Call-Karten brechen die Kompakt-Kette in beide Richtungen
			compact = prev.author_id == m.author_id && m.ts_ms - prev.ts_ms < 3*60*1000 &&
				prev.call_start_ms == 0 && m.call_start_ms == 0
		}
		h: f32
		if edit_id != 0 && m.id == edit_id {
			// Editor-Box ersetzt den Text (+ etwas Luft unter der Box)
			h = compact ? edit_h + 10 : edit_h + 38
		} else if m.call_start_ms > 0 {
			// Call-Karte: Kopfzeile (Avatar/Name/Zeit) + Karte + Luft
			h = 28 + CALL_CARD_H + 12
		} else {
			th := rich_text_height(app, m.text, text_w, m.edit_count > 0)
			h = compact ? th + 6 : th + 34
		}
		append(&cs.rows, Msg_Row{kind = .Message, msg_idx = i, compact = compact, h = h})
	}

	cs.rows_n = len(msgs)
	cs.rows_w = text_w
	cs.rows_divider = cs.divider_id
	cs.rows_edit = edit_id
	cs.rows_edit_h = edit_h
	total := f32(10)
	for r in cs.rows {
		total += r.h
	}
	cs.content_h = total + 12

	// History-Prepend: Scroll-Position stabil halten
	if cs.adjust_scroll {
		cs.adjust_scroll = false
		if !cs.stick_bottom {
			delta := cs.content_h - old_h
			cs.scroll.pos += delta
			cs.scroll.target += delta
		}
	}
}

// --- Chat-Hauptfläche ---

draw_chat :: proc(app: ^App, c: ^Server_Conn, chat: rl.Rectangle) {
	cs := conn_find_channel(c, c.active_channel)
	if cs == nil {
		draw_chat_empty_state(app, chat)
		return
	}

	// „Einfach lostippen" → Fokus aufs Eingabefeld (bzw. den offenen Editor).
	// Nicht während Tab-Navigation — die parkt den Fokus bewusst auf Buttons.
	editing_here := c.edit_msg_id != 0 && c.edit_channel == c.active_channel
	if app.ui.focus == .None && app.modal == .None && !app.ui.tab_nav {
		app.ui.focus = editing_here ? .Edit : .Message
	}
	// Der Editor ist nicht sichtbar (anderer Channel/Server) → Fokus lösen
	if app.ui.focus == .Edit && !editing_here {
		app.ui.focus = .Message
	}

	draw_chat_header(app, c, cs, chat)

	// „Call läuft"-Banner (animiert ein/aus; 0 wenn keiner läuft)
	banner_h := draw_call_banner(app, c, cs, chat)

	// Eingabefeld unten (Höhe hängt vom Inhalt ab)
	input_h := draw_message_input(app, c, cs, chat)

	// Nachrichtenliste dazwischen
	list := rl.Rectangle{chat.x, chat.y + HEADER_H + 1 + banner_h, chat.width, chat.height - HEADER_H - 1 - banner_h - input_h}
	draw_message_list(app, c, cs, list)
}

@(private = "file")
draw_chat_empty_state :: proc(app: ^App, chat: rl.Rectangle) {
	cx := chat.x + chat.width/2
	cy := chat.y + chat.height/2
	// COL_BORDER_SOFT statt COL_PANEL_BG: im dunklen Theme ist der Panel-Ton
	// mit der Chatfläche identisch, der Kreis wäre unsichtbar.
	rl.DrawCircleV({cx, cy - 60}, 36, COL_BORDER_SOFT)
	draw_rune_centered(app.fonts.bold24, '#', cx, cy - 60, COL_TEXT_FAINT)
	draw_text_centered(app.fonts.bold18, "Kein Kanal ausgewählt", cx, cy - 4, 18, COL_TEXT)
	draw_text_centered(app.fonts.regular15, "Wähle links einen Kanal oder starte eine Direktnachricht.",
		cx, cy + 24, 15, COL_TEXT_DIM)
	draw_text_centered(app.fonts.regular13, "Tipp: Strg+K öffnet die Schnellsuche", cx, cy + 52, 13, COL_TEXT_FAINT)
}

@(private = "file")
draw_chat_header :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, chat: rl.Rectangle) {
	x := chat.x + 20
	if cs.ch.is_dm {
		// DM: Avatar + Name + Presence
		partner := dm_partner(c, cs)
		seed := partner != nil ? partner.username : "?"
		online := partner != nil && partner.online
		draw_avatar(app, seed, x, chat.y + (HEADER_H - 28)/2, 28, presence = true, online = online,
			c = c, uid = partner != nil ? partner.id : 0)
		title := channel_title(c, cs)
		draw_text(app.fonts.bold18, tcstr(title), {x + 38, chat.y + (HEADER_H - 18)/2}, 18, 0, COL_TEXT)
		if partner != nil && partner.in_call {
			// Gegenüber ist gerade in einem Call
			tw := rl.MeasureTextEx(app.fonts.bold18, tcstr(title), 18, 0).x
			draw_headphones(x + 38 + tw + 16, chat.y + HEADER_H/2 - 1, 7, 2.2, COL_ONLINE)
		}
		cb := rl.Rectangle{chat.x + chat.width - 24 - THEME_RESERVE - PING_RESERVE - 34, chat.y + (HEADER_H - 34)/2, 34, 34}
		draw_call_header_button(app, c, cs, cb)
	} else {
		title := channel_title(c, cs)
		draw_text(app.fonts.bold18, tcstr(title), {x, chat.y + (HEADER_H - 18)/2}, 18, 0, COL_TEXT)

		// Mitglieder-Pill: gestapelte Avatare + Zähler → öffnet Mitglieder-Modal.
		// Der letzte Avatar bekommt KEINEN Overlap-Abzug — der Zähler braucht
		// echten Abstand zur Avatar-Kante.
		n := len(cs.ch.member_ids)
		shown := min(n, 3)
		aw := f32(24)
		overlap := f32(7)
		stack_w := f32(shown)*aw - f32(max(0, shown-1))*overlap
		count_label := fmt.tprintf("%d", n)
		clw := rl.MeasureTextEx(app.fonts.bold13, tcstr(count_label), 13, 0).x
		pad := f32(7)
		gap := f32(9) // Luft zwischen Avatar-Stack und Zähler
		ph := f32(32)
		total_w := pad + stack_w + gap + clw + pad + 3
		// Rechts sitzen Theme-Umschalter + Latenz-Indikator → Platz freihalten
		r := rl.Rectangle{
			chat.x + chat.width - total_w - 24 - THEME_RESERVE - PING_RESERVE,
			chat.y + (HEADER_H - ph)/2, total_w, ph,
		}

		hovered := ui_hover(&app.ui, r, .Base)
		focused := tab_stop(app, anim_id(.Misc, cs.ch.id ~ 0xABCD), r, .Base, radius = ph/2)
		t := anim_to(app, anim_id(.Misc, cs.ch.id ~ 0xABCD), (hovered || focused) ? 1 : 0)
		pill_bg := mix(COL_CHAT_BG, COL_SURFACE_HOVER, 0.35 + t*0.65)
		rrect(r, ph/2, pill_bg)
		rrect_lines(r, ph/2, 1, mix(COL_BORDER_SOFT, COL_BORDER, t))
		if focused {
			draw_focus_ring(r, ph/2)
		}
		if hovered {
			app.ui.cursor = .POINTING_HAND
		}
		cy := r.y + ph/2
		ax := r.x + pad
		for i in 0 ..< shown {
			mid := cs.ch.member_ids[i]
			seed := fmt.tprintf("%d", mid)
			if u := conn_find_user(c, mid); u != nil {
				seed = u.username
			}
			// Ring in Pill-Farbe, damit sich die gestapelten Avatare abheben
			rl.DrawCircleV({ax + aw/2, cy}, aw/2 + 2, pill_bg)
			draw_avatar(app, seed, ax, cy - aw/2, aw, c = c, uid = mid)
			ax += aw - overlap
		}
		draw_text(app.fonts.bold13, tcstr(count_label),
			{r.x + pad + stack_w + gap, cy - 13/2 - 1}, 13, 0, mix(COL_TEXT_DIM, COL_TEXT, t))
		tooltip(app, anim_id(.Misc, cs.ch.id ~ 0xEF01), r, "Mitglieder anzeigen & einladen", .Base)
		if ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate) {
			open_modal(app, .Members)
		}

		// Voice-Call-Button links von der Mitglieder-Pill
		cb := rl.Rectangle{r.x - 44, chat.y + (HEADER_H - 34)/2, 34, 34}
		draw_call_header_button(app, c, cs, cb)
	}
	rl.DrawLineEx({chat.x, chat.y + HEADER_H}, {chat.x + chat.width, chat.y + HEADER_H}, 1, COL_BORDER_SOFT)
}

// --- Nachrichtenliste ---

@(private = "file")
draw_message_list :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, list: rl.Rectangle) {
	if !cs.history_loaded {
		draw_loading_dots(app, list.x + list.width/2, list.y + list.height/2)
		return
	}

	text_x := list.x + MSG_GUTTER
	text_w := list.width - MSG_GUTTER - MSG_PAD_RIGHT

	edit_id := c.edit_channel == cs.ch.id ? c.edit_msg_id : 0
	edit_h := f32(0)
	if edit_id != 0 {
		edit_h = edit_box_height(app, c, text_w)
	}
	if rows_dirty(cs, text_w, edit_id, edit_h) {
		build_rows(app, cs, text_w, edit_id, edit_h)
	}

	if len(cs.messages) == 0 {
		title := channel_title(c, cs)
		cx := list.x + list.width/2
		cy := list.y + list.height/2
		draw_text_centered(app.fonts.bold24, fmt.tprintf("Das ist der Anfang von %s", title), cx, cy - 30, 24, COL_TEXT)
		sub := cs.ch.is_dm ? "Sag hallo — die Nachricht landet direkt bei ihnen." : "Lade Kolleg:innen ein und schreib die erste Nachricht."
		draw_text_centered(app.fonts.regular15, sub, cx, cy + 8, 15, COL_TEXT_DIM)
		return
	}

	max_scroll := max(0, cs.content_h - list.height)

	// Gelesen-Status pflegen, solange der Channel sichtbar & das Fenster fokussiert ist
	if rl.IsWindowFocused() && len(cs.messages) > 0 {
		cs.last_read_id = max(cs.last_read_id, cs.messages[len(cs.messages)-1].id)
		cs.unread = 0
	}

	// Scroll: Wheel + Smoothing; hochscrollen löst den Boden-Anker
	hovered := ui_hover(&app.ui, list, .Base)
	if hovered && app.ui.wheel > 0 {
		cs.stick_bottom = false
	}
	if cs.stick_bottom {
		if max_scroll - cs.scroll.target > 600 {
			scroll_to(&cs.scroll, max_scroll) // weiter Sprung (Channelwechsel) → sofort
		} else {
			cs.scroll.target = max_scroll
		}
	}
	// Seiten-Tasten
	if app.modal == .None {
		if rl.IsKeyPressed(.PAGE_UP) {
			cs.scroll.target -= list.height * 0.85
			cs.stick_bottom = false
			cs.scroll.activity = 1
		}
		if rl.IsKeyPressed(.PAGE_DOWN) {
			cs.scroll.target += list.height * 0.85
			cs.scroll.activity = 1
		}
	}
	scroll_update(app, &cs.scroll, hovered, max_scroll)
	if cs.scroll.target >= max_scroll - 2 && max_scroll > 0 {
		cs.stick_bottom = true
	}

	// Oben angekommen → ältere Nachrichten nachladen
	if cs.scroll.pos < 240 && !cs.history_done {
		app_request_older(c, cs)
	}

	scissor_begin(list.x, list.y, list.width, list.height)

	y := list.y + 10 - cs.scroll.pos

	// Lade-Hinweis oben beim Paging
	if cs.history_loading && !cs.history_done {
		draw_text_centered(app.fonts.regular13, "Lade ältere Nachrichten…", list.x + list.width/2, y - 4, 13, COL_TEXT_FAINT)
	} else if cs.history_done && cs.scroll.pos < 60 && max_scroll > 0 {
		draw_text_centered(app.fonts.regular13, "— Anfang des Verlaufs —", list.x + list.width/2, y - 4, 13, COL_TEXT_FAINT)
	}

	msgs := cs.messages[:]
	for row, ri in cs.rows {
		if y > list.y + list.height {
			break
		}
		if y + row.h < list.y {
			y += row.h
			continue
		}

		switch row.kind {
		case .Day_Sep:
			label := format_day_label(app, row.day_ms)
			tw := rl.MeasureTextEx(app.fonts.bold13, tcstr(label), 13, 0)
			cy := y + row.h/2 + 4
			pill_w := tw.x + 24
			px := list.x + (list.width - pill_w)/2
			rl.DrawLineEx({list.x + 16, cy}, {px - 8, cy}, 1, COL_BORDER_SOFT)
			rl.DrawLineEx({px + pill_w + 8, cy}, {list.x + list.width - 16, cy}, 1, COL_BORDER_SOFT)
			pill := rl.Rectangle{px, cy - 12, pill_w, 24}
			rrect(pill, 12, COL_CHAT_BG)
			rrect_lines(pill, 12, 1, COL_BORDER_SOFT)
			draw_text(app.fonts.bold13, tcstr(label), {px + 12, cy - 6}, 13, 0, COL_TEXT_DIM)

		case .New_Sep:
			cy := y + row.h/2
			label := "Neu"
			tw := rl.MeasureTextEx(app.fonts.bold13, tcstr(label), 13, 0)
			rl.DrawLineEx({list.x + 16, cy}, {list.x + list.width - tw.x - 40, cy}, 1, fade(COL_BADGE, 0.7))
			draw_text(app.fonts.bold13, tcstr(label), {list.x + list.width - tw.x - 28, cy - 6}, 13, 0, COL_BADGE)

		case .Message:
			m := msgs[row.msg_idx]
			editing := edit_id != 0 && m.id == edit_id
			row_rect := rl.Rectangle{list.x, y, list.width, row.h}

			// Die Panel-Zone der NÄCHSTEN eigenen Nachricht ragt in diese
			// Zeile hinein und gehört ihr — Hover und Klick dort zählen
			// nicht für die aktuelle Zeile.
			steal := false
			if ri + 1 < len(cs.rows) && cs.rows[ri+1].kind == .Message {
				nm := msgs[cs.rows[ri+1].msg_idx]
				if msg_panel_exists(c, nm) {
					steal = ui_hover(&app.ui, msg_panel_rect(list, y + row.h), .Base)
				}
			}

			panel_r := msg_panel_rect(list, y)
			mine_panel := msg_panel_exists(c, m)
			menu_here := app.msg_menu.open && app.msg_menu.msg_id == m.id
			hot := (ui_hover(&app.ui, row_rect, .Base) && !steal) ||
				(mine_panel && ui_hover(&app.ui, panel_r, .Base)) || menu_here
			if hot {
				rl.DrawRectangleRec(row_rect, COL_HOVER_ROW)
			}

			// Klicks im sichtbaren Panel (eigenes oder das der nächsten
			// Zeile) dürfen den Inhalt darunter nicht auslösen — z. B. den
			// Copy-Button eines Code-Blocks.
			shield := steal || (mine_panel && hot && ui_hover(&app.ui, panel_r, .Base))
			saved_click := app.ui.clicked
			if shield {
				app.ui.clicked = false
			}

			author_id := m.author_id
			clickable_author := author_id != c.me.id

			if !row.compact {
				author := user_label(c, author_id)
				seed := author
				if u := conn_find_user(c, author_id); u != nil {
					seed = u.username
				}
				av := rl.Rectangle{list.x + 24, y + 8, 36, 36}
				draw_avatar(app, seed, av.x, av.y, 36, c = c, uid = author_id)

				name_w := rl.MeasureTextEx(app.fonts.bold15, tcstr(author), 15, 0).x
				name_r := rl.Rectangle{text_x, y + 8, name_w, 18}
				draw_text(app.fonts.bold15, tcstr(author), {text_x, y + 8}, 15, 0, COL_TEXT)
				draw_text(app.fonts.regular13, tcstr(format_time_hm(app, m.ts_ms)),
					{text_x + name_w + 8, y + 10}, 13, 0, COL_TEXT_FAINT)

				// Klick auf Avatar/Name → DM öffnen
				if clickable_author {
					if ui_hover(&app.ui, av, .Base) || ui_hover(&app.ui, name_r, .Base) {
						app.ui.cursor = .POINTING_HAND
					}
					if ui_click(&app.ui, av, .Base) || ui_click(&app.ui, name_r, .Base) {
						open_dm_with(app, c, author_id)
					}
				}
				if editing {
					draw_edit_row(app, c, cs, m, text_x, y + 28, text_w)
				} else if m.call_start_ms > 0 {
					draw_call_card(app, c, cs, m, text_x, y + 28, text_w)
				} else {
					rs := Rich_Sel{msg = m.id}
					rich_text(app, m.text, text_x, y + 28, text_w, true, m.id, edited = m.edit_count > 0, sel = &rs)
				}
			} else {
				// Kompaktzeile: Zeit im Gutter nur bei Hover
				if hot {
					ts := format_time_hm(app, m.ts_ms)
					tw := rl.MeasureTextEx(app.fonts.regular13, tcstr(ts), 13, 0).x
					draw_text(app.fonts.regular13, tcstr(ts), {text_x - tw - 10, y + 6}, 13, 0, COL_TEXT_FAINT)
				}
				if editing {
					draw_edit_row(app, c, cs, m, text_x, y + 3, text_w)
				} else {
					rs := Rich_Sel{msg = m.id}
					rich_text(app, m.text, text_x, y + 3, text_w, true, m.id, edited = m.edit_count > 0, sel = &rs)
				}
			}

			if shield {
				app.ui.clicked = saved_click
			}
			if mine_panel && hot {
				sel_block(panel_r) // über dem Panel startet kein Text-Drag
				draw_msg_panel(app, c, cs, m, panel_r)
			} else if mine_panel {
				// Einblendung zurücksetzen — sonst erschiene das Panel beim
				// nächsten Hover schlagartig (der Anim-Wert bliebe auf 1)
				delete_key(&app.anim.vals, anim_id(.Msg_Action, m.id ~ 0x9A7E))
				delete_key(&app.anim.vals, anim_id(.Msg_Action, m.id ~ 0x3D07))
			}
		}
		y += row.h
	}
	scissor_end()

	// Browser-artige Text-Selektion (Drag, Doppelklick, Highlight)
	chat_sel_update(app, c, cs, list)

	scrollbar(app, list, cs.content_h, &cs.scroll, .Base)
	draw_jump_pill(app, cs, list, max_scroll)
}

// --- Hover-Panel (Aktionen an eigenen Nachrichten, wie bei Slack) ---

MSG_PANEL_BTN :: f32(30)

// Bekommt diese Nachricht ein Aktions-Panel? Nur eigene, nicht die im
// Inline-Edit — und keine Call-Systemnachrichten (pflegt der Server).
@(private = "file")
msg_panel_exists :: proc(c: ^Server_Conn, m: shared.Chat_Message) -> bool {
	return m.author_id == c.me.id && m.id != c.edit_msg_id && m.call_start_ms == 0
}

// Panel-Rechteck einer Zeile mit Oberkante `y`: oben rechts, ragt halb über
// die Zeilengrenze (deshalb die Besitz-Regeln in draw_message_list).
@(private = "file")
msg_panel_rect :: proc(list: rl.Rectangle, y: f32) -> rl.Rectangle {
	w := MSG_PANEL_BTN + 8 // ein Button; wächst mit künftigen Buttons (Reaktionen …)
	return {list.x + list.width - w - 20, y - 14, w, MSG_PANEL_BTN + 8}
}

@(private = "file")
draw_msg_panel :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, m: shared.Chat_Message, p: rl.Rectangle) {
	// weich einblenden
	pt := anim_to(app, anim_id(.Msg_Action, m.id ~ 0x9A7E), 1, 22, initial = 0)
	draw_shadow(p, 8, 0.35*pt)
	rrect(p, 8, fade(COL_SURFACE, pt))
	rrect_lines(p, 8, 1, fade(COL_BORDER, pt))

	// „Mehr"-Button (drei vertikale Punkte) → Popover-Menü
	btn := rl.Rectangle{p.x + 4, p.y + 4, MSG_PANEL_BTN, MSG_PANEL_BTN}
	id := anim_id(.Msg_Action, m.id ~ 0x3D07)
	hovered := ui_hover(&app.ui, btn, .Base)
	active := app.msg_menu.open && app.msg_menu.msg_id == m.id
	t := anim_to(app, id, (hovered || active) ? 1 : 0, 18)
	if t > 0.01 {
		rrect(btn, 6, fade(COL_OVERLAY, t*0.08))
	}
	if hovered {
		app.ui.cursor = .POINTING_HAND
	}
	draw_dots_v(btn.x + btn.width/2, btn.y + btn.height/2, 4.5, 1.6,
		fade(mix(COL_TEXT_DIM, COL_TEXT, t), pt))
	tooltip(app, id ~ 0x71C, btn, "Weitere Aktionen", .Base)
	if ui_click(&app.ui, btn, .Base) {
		msg_menu_open(app, cs.ch.id, m.id, {btn.x + btn.width/2, p.y + p.height + 2})
	}
}

// Ein DM öffnen bzw. aktivieren.
open_dm_with :: proc(app: ^App, c: ^Server_Conn, user_id: u64) {
	if dm := conn_find_dm(c, user_id); dm != nil {
		app_activate_channel(app, c, dm.ch.id)
		return
	}
	conn_request(c, {kind = shared.K_OPEN_DM, user_id = user_id}, {user_id = user_id})
}

// „↓ Zu neuen Nachrichten"-Pille, wenn nicht am Ende.
@(private = "file")
draw_jump_pill :: proc(app: ^App, cs: ^Channel_State, list: rl.Rectangle, max_scroll: f32) {
	show := !cs.stick_bottom && max_scroll > 0 && max_scroll - cs.scroll.pos > 150
	t := anim_to(app, anim_id(.Jump_Pill, cs.ch.id), show ? 1 : 0, 14, initial = 0)
	if t < 0.02 {
		return
	}
	label := "↓  Zu neuen Nachrichten"
	tw := rl.MeasureTextEx(app.fonts.bold13, tcstr(label), 13, 0)
	w := tw.x + 32
	h := f32(32)
	x := list.x + (list.width - w)/2
	y := list.y + list.height - h - 14 + (1 - t)*24

	r := rl.Rectangle{x, y, w, h}
	focused := tab_stop(app, anim_id(.Jump_Pill, cs.ch.id ~ 0x7AB), r, .Base, radius = 16)
	draw_shadow(r, 16, t*0.6)
	rrect(r, 16, fade(COL_PRIMARY, t))
	if focused {
		draw_focus_ring(r, 16)
	}
	draw_text(app.fonts.bold13, tcstr(label), {x + 16, y + (h-13)/2 - 1}, 13, 0, fade(COL_PRIMARY_FG, t))
	if ui_hover(&app.ui, r, .Base) {
		app.ui.cursor = .POINTING_HAND
	}
	if ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate) {
		cs.stick_bottom = true
		cs.scroll.activity = 1
	}
}

// Drei hüpfende Lade-Punkte.
draw_loading_dots :: proc(app: ^App, cx, cy: f32) {
	t := f32(rl.GetTime())
	for i in 0 ..< 3 {
		phase := t*3.6 - f32(i)*0.55
		dy := math.sin(phase) * 5
		a := 0.35 + 0.65*clamp(math.sin(phase), 0, 1)
		rl.DrawCircleV({cx - 18 + f32(i)*18, cy + dy}, 4.5, fade(COL_TEXT_FAINT, a))
	}
}

// --- Eingabefeld ---

// Zeichnet das Eingabefeld und gibt die belegte Gesamthöhe (inkl. Ränder) zurück.
@(private = "file")
draw_message_input :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, chat: rl.Rectangle) -> f32 {
	ti := &c.msg_input
	margin := f32(20)
	send_w := f32(40) // Platz für den Senden-Button rechts
	box_w := chat.width - 2*margin

	target_h := editor_box_height(app, ti, box_w - 2*EDITOR_PAD - send_w, 6)
	box_h := anim_to(app, anim_id(.Misc, c.active_channel ~ 0x11), target_h, 20, initial = target_h)
	hint_h := f32(20)
	total := box_h + 14 + hint_h + 10

	box := rl.Rectangle{chat.x + margin, chat.y + chat.height - hint_h - 10 - box_h, box_w, box_h}

	ph: string
	if cs.ch.is_dm {
		ph = fmt.tprintf("Nachricht an %s", channel_title(c, cs))
	} else {
		ph = fmt.tprintf("Nachricht an #%s", cs.ch.name)
	}
	submitted := multiline_editor(app, box, ti, &c.input_ed, .Message, ph, send_w)
	focused := app.ui.focus == .Message && app.ui.layer == .Base
	// Fokus-Blende nur LESEN — der Editor hat sie diesen Frame schon bewegt
	ft := app.anim.vals[anim_id(.Input_Focus, u64(Focus.Message))]

	// Senden-Button
	has_text := len(strings.trim_space(ti_text(ti))) > 0
	btn := rl.Rectangle{box.x + box.width - 38, box.y + box.height - 38, 30, 30}
	btn_focused := tab_stop(app, anim_id(.Misc, 0x5E4D), btn, .Base, radius = 6)
	bt := anim_to(app, anim_id(.Misc, 0x5E4D), has_text ? 1 : 0, 14)
	bcol := mix(COL_SEND_IDLE, COL_ACCENT, bt)
	if ui_hover(&app.ui, btn, .Base) && has_text {
		app.ui.cursor = .POINTING_HAND
		bcol = mix(bcol, COL_PRESS, 0.08)
	}
	rrect(btn, 6, bcol)
	if btn_focused {
		draw_focus_ring(btn, 6)
	}
	// Senden-Icon (Dreieck nach rechts; DrawPoly umgeht Winding-Fallen).
	// +1 px optischer Ausgleich: rechtsweisende Dreiecke wirken sonst linkslastig.
	// Ohne Text gedeckt (auf COL_SEND_IDLE), mit Text weiß auf dem Akzent —
	// sonst sähe der leere Button im dunklen Theme aktiv aus.
	rl.DrawPoly({btn.x + btn.width/2 + 1, btn.y + btn.height/2}, 3, 7, 0,
		mix(COL_TEXT_FAINT, COL_WHITE, bt))
	if (ui_click(&app.ui, btn, .Base) || (btn_focused && app.ui.tab_activate)) && has_text {
		submitted = true
	}

	// Hinweiszeile unter dem Feld
	hint_y := box.y + box.height + 6
	over := len(ti_text(ti)) - shared.MAX_MESSAGE_TEXT_LEN
	if over > -500 {
		// Zeichen-Budget anzeigen, wenn es knapp wird
		lbl := over > 0 ? fmt.tprintf("%d Zeichen zu viel", over) : fmt.tprintf("noch %d Zeichen", -over)
		col := over > 0 ? COL_RED : COL_TEXT_FAINT
		tw := rl.MeasureTextEx(app.fonts.regular13, tcstr(lbl), 13, 0).x
		draw_text(app.fonts.regular13, tcstr(lbl), {box.x + box.width - tw, hint_y}, 13, 0, col)
	} else if focused {
		hint := len(ti.runes) == 0 ? "*fett*  _kursiv_  ~durchgestrichen~  `code`  ```sprache … ```" : "Enter senden  ·  Shift+Enter neue Zeile"
		draw_text(app.fonts.regular13, tcstr(hint), {box.x + 2, hint_y}, 13, 0, fade(COL_TEXT_FAINT, ft*0.9))
	}

	if submitted {
		text := strings.trim_space(ti_text(ti))
		if len(text) > shared.MAX_MESSAGE_TEXT_LEN {
			toast(app, .Error, "Nachricht ist zu lang")
		} else if text != "" {
			conn_request(c, {kind = shared.K_SEND, channel_id = cs.ch.id, text = text}, {channel_id = cs.ch.id})
			ti_clear(ti)
			caret_reset(app)
			cs.stick_bottom = true
		}
	}
	return total
}
