package main

// Quick Switcher (Strg+K): fuzzy Springen zu Channels und Direktnachrichten.

import "core:strings"

import rl "vendor:raylib"

Switch_Item :: struct {
	is_dm:      bool,
	channel_id: u64, // 0 bei DM ohne existierenden Channel
	user_id:    u64,
	label:      string,
	sub:        string,
	seed:       string, // Avatar-Seed (Username)
	online:     bool,
	score:      int,
}

// Kleinschreibung nur für ASCII (reicht für Ranking).
@(private = "file")
lower :: proc(s: string) -> string {
	return strings.to_lower(s, context.temp_allocator)
}

// Score: 0 = Prefix, 1 = Wortanfang, 2 = enthalten, -1 = kein Treffer.
@(private = "file")
match_score :: proc(hay, needle: string) -> int {
	if needle == "" {
		return 2
	}
	h := lower(hay)
	n := lower(needle)
	if strings.has_prefix(h, n) {
		return 0
	}
	idx := strings.index(h, n)
	if idx < 0 {
		return -1
	}
	if idx > 0 && (h[idx-1] == ' ' || h[idx-1] == '-' || h[idx-1] == '_' || h[idx-1] == '.') {
		return 1
	}
	return 2
}

@(private = "file")
build_items :: proc(app: ^App, c: ^Server_Conn, query: string) -> []Switch_Item {
	items := make([dynamic]Switch_Item, context.temp_allocator)

	for &cs in c.channels {
		if cs.ch.is_dm {
			continue
		}
		s := match_score(cs.ch.name, query)
		if s < 0 {
			continue
		}
		append(&items, Switch_Item{
			channel_id = cs.ch.id,
			label = cs.ch.name,
			sub = "Kanal",
			score = s,
		})
	}
	for u in c.users {
		if u.id == c.me.id {
			continue
		}
		label := u.display_name != "" ? u.display_name : u.username
		s := match_score(label, query)
		if s < 0 {
			s = match_score(u.username, query)
		}
		if s < 0 {
			continue
		}
		item := Switch_Item{
			is_dm = true,
			user_id = u.id,
			label = label,
			sub = u.online ? "Direktnachricht · online" : "Direktnachricht",
			seed = u.username,
			online = u.online,
			score = s,
		}
		if dm := conn_find_dm(c, u.id); dm != nil {
			item.channel_id = dm.ch.id
		}
		append(&items, item)
	}

	// stabil nach Score sortieren (Insertion Sort, Listen sind klein)
	for i in 1 ..< len(items) {
		j := i
		for j > 0 && items[j-1].score > items[j].score {
			items[j-1], items[j] = items[j], items[j-1]
			j -= 1
		}
	}
	if len(items) > 8 {
		return items[:8]
	}
	return items[:]
}

draw_quick_switcher :: proc(app: ^App, c: ^Server_Conn, sw, sh: f32) {
	t := anim_to(app, anim_id(.Modal_Open, 1), 1, 16, initial = 0)
	rl.DrawRectangleRec({0, -app.bar_h, sw, sh + app.bar_h}, fade(COL_SCRIM, t))

	query := strings.trim_space(ti_text(&app.modal_input))
	items := build_items(app, c, query)
	app.switcher_sel = clamp(app.switcher_sel, 0, max(0, len(items)-1))

	row_h := f32(52)
	w := f32(600)
	h := 84 + f32(len(items))*row_h + (len(items) == 0 ? 44 : 12)
	x := (sw - w)/2
	y := f32(120) - 16*(1 - t)
	p := rl.Rectangle{x, y, w, h}

	draw_shadow(p, RADIUS_CARD, t)
	rrect(p, RADIUS_CARD, fade(COL_SURFACE, t))
	rrect_lines(p, RADIUS_CARD, 1, fade(COL_BORDER, t))

	// Suchfeld
	submitted := text_field(app, {x + 20, y + 20, w - 40, 44}, &app.modal_input, .Switcher, .Modal,
		"Kanal oder Person suchen…")
	app.ui.focus = .Switcher // Fokus bleibt im Switcher

	// Auswahl mit Pfeiltasten
	if key_pressed(.DOWN) {
		app.switcher_sel = min(app.switcher_sel + 1, max(0, len(items)-1))
	}
	if key_pressed(.UP) {
		app.switcher_sel = max(app.switcher_sel - 1, 0)
	}

	ly := y + 78
	if len(items) == 0 {
		draw_text_centered(app.fonts.regular15, "Keine Treffer", x + w/2, ly + 8, 15, COL_TEXT_FAINT)
	}
	chosen := -1
	for it, i in items {
		r := rl.Rectangle{x + 10, ly, w - 20, row_h}
		hovered := ui_hover(&app.ui, r, .Modal)
		if hovered {
			app.ui.cursor = .POINTING_HAND
			// Auswahl nur bei echter Mausbewegung ändern (Pfeiltasten haben Vorrang)
			md := rl.GetMouseDelta()
			if md.x != 0 || md.y != 0 {
				app.switcher_sel = i
			}
		}
		selected := i == app.switcher_sel
		if selected {
			rrect(r, 8, fade(COL_ACCENT, 0.12))
			rrect_lines(r, 8, 1.4, fade(COL_ACCENT, 0.7))
		} else if hovered {
			rrect(r, 8, fade(COL_OVERLAY, 0.05))
		}

		ix := x + 24
		if it.is_dm {
			draw_avatar(app, it.seed, ix, ly + (row_h - 30)/2, 30, presence = true, online = it.online, c = c, uid = it.user_id)
		} else {
			rl.DrawCircleV({ix + 15, ly + row_h/2}, 15, COL_PANEL_BG)
			draw_rune_centered(app.fonts.bold15, '#', ix + 15, ly + row_h/2, COL_TEXT_DIM)
		}
		draw_text(app.fonts.bold15, tcstr(it.label), {ix + 42, ly + 9}, 15, 0, COL_TEXT)
		draw_text(app.fonts.regular13, tcstr(it.sub), {ix + 42, ly + 28}, 13, 0, COL_TEXT_FAINT)

		if ui_click(&app.ui, r, .Modal) {
			chosen = i
		}
		ly += row_h
	}

	if submitted && len(items) > 0 {
		chosen = app.switcher_sel
	}
	if chosen >= 0 {
		it := items[chosen]
		if it.channel_id != 0 {
			app_activate_channel(app, c, it.channel_id)
		} else if it.is_dm {
			open_dm_with(app, c, it.user_id)
		}
		close_modal(app)
	}

	// Klick außerhalb schließt
	if app.ui.clicked && !rl.CheckCollisionPointRec(app.ui.mouse, p) {
		close_modal(app)
	}

	// Fußnote
	draw_text_centered(app.fonts.regular13, "↑↓ wählen · Enter öffnen · Esc schließen",
		x + w/2, y + h + 14, 13, fade(COL_WHITE, 0.75*t))
}
