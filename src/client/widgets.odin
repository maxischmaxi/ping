package main

// Immediate-Mode-Widgets: Textfelder (mit Selektion + Maus), Buttons,
// Scrollbars, Tooltips, Avatare.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

import rl "vendor:raylib"

// Eingabe-Layer: Widgets reagieren nur, wenn ihr Layer aktiv ist
// (offenes Modal blockiert die UI darunter).
UI_Layer :: enum {
	Base,
	Modal,
}

// Fokus-Ziele für Textfelder.
Focus :: enum {
	None,
	Welcome_Addr,
	Auth_User,
	Auth_Display,
	Auth_Pass,
	Auth_Invite, // invite code (registering on a closed server)
	Setup_Name,
	Message,
	Edit, // Inline-Editor einer Nachricht
	Modal_Input,
	Switcher,

	// Admin panel fields (adminui.odin)
	Adm_Name,
	Adm_User,
	Adm_Display,
	Adm_Pass,
	Adm_Ban,
	Adm_Reset,
	Adm_OA_Client,
	Adm_OA_Secret,
	Adm_OA_Issuer,
	Adm_OA_Label,
}

// Ein per Tab erreichbares Widget. Die Registrierungs-Reihenfolge
// (= Zeichenreihenfolge) bestimmt die Tab-Reihenfolge.
Tab_Stop :: struct {
	id:     u64,
	layer:  UI_Layer,
	focus:  Focus, // .None bei Buttons/Rows, sonst das Textfeld-Fokusziel
	rect:   rl.Rectangle,
	radius: f32,
}

// Pro Frame gesammelter UI-Zustand.
UI_Ctx :: struct {
	mouse:          rl.Vector2,
	clicked:        bool, // linke Maustaste in diesem Frame gedrückt
	rclicked:       bool, // rechte Maustaste in diesem Frame gedrückt
	mouse_down:     bool,
	released:       bool,
	wheel:          f32,
	layer:          UI_Layer,
	cursor:         rl.MouseCursor,
	focus:          Focus,
	drag_focus:     Focus, // Textfeld, in dem gerade eine Maus-Selektion läuft

	// Mehrfachklick-Erkennung (Browser-Verhalten: 2× Wort, 3× Zeile)
	last_click_t:   f64,
	last_click_pos: rl.Vector2,
	click_streak:   int, // 1 → 2 → 3 → 1 … solange Klicks schnell am Ort bleiben
	double_click:   bool,
	triple_click:   bool,

	// Tooltip-Verwaltung
	hot_id:      u64,
	hot_t:       f32,
	any_hot:     bool,
	tip_text:    string, // temp-alloziert, nur diesen Frame gültig
	tip_anchor:  rl.Rectangle,
	tip_show:    bool,

	// Tab-Navigation (wie im Browser)
	tab_stops:    [dynamic]Tab_Stop, // in diesem Frame registriert
	tab_prev:     [dynamic]Tab_Stop, // Stops des letzten Frames (Navigationsbasis)
	tab_focus:    u64,               // per Tab fokussiertes Widget (0 = keins)
	tab_nav:      bool,              // Tastatur-Navigation aktiv → Fokus-Ring sichtbar
	tab_activate: bool,              // Enter/Leertaste aktiviert das fokussierte Widget

	// Schwebendes Overlay (Call-Popout): fängt die Maus für alle Base-
	// Widgets darunter ab. Das Overlay zeichnet spät im Frame und setzt
	// sein Rect für den NÄCHSTEN Frame (1 Frame Versatz, unmerklich).
	overlay:    rl.Rectangle,
	overlay_on: bool,
	in_overlay: bool, // true, während die Overlay-eigenen Widgets zeichnen

	applied_cursor: rl.MouseCursor, // zuletzt an raylib gemeldeter Cursor
}

ui_begin_frame :: proc(app: ^App, modal_open: bool) {
	ui := &app.ui
	m := rl.GetMousePosition()
	// Maus in logischen Koordinaten; die Call-Leiste verschiebt die UI um
	// bar_h nach unten → über der Leiste wird y negativ (dort liegt sie).
	ui.mouse = {m.x / g_scale, m.y / g_scale - app.bar_h}
	ui.clicked = rl.IsMouseButtonPressed(.LEFT)
	ui.rclicked = rl.IsMouseButtonPressed(.RIGHT)
	ui.mouse_down = rl.IsMouseButtonDown(.LEFT)
	ui.released = rl.IsMouseButtonReleased(.LEFT)
	ui.wheel = rl.GetMouseWheelMove()
	ui.layer = .Modal if modal_open else .Base
	ui.cursor = .DEFAULT
	ui.any_hot = false
	ui.tip_show = false
	chat_sel_frame() // Text-Runs des letzten Frames verwerfen

	ui.double_click = false
	ui.triple_click = false
	if ui.clicked {
		t := rl.GetTime()
		d := rl.Vector2{ui.mouse.x - ui.last_click_pos.x, ui.mouse.y - ui.last_click_pos.y}
		if t - ui.last_click_t < 0.4 && abs(d.x) < 5 && abs(d.y) < 5 {
			ui.click_streak = ui.click_streak % 3 + 1 // nach 3× beginnt der Zyklus neu
		} else {
			ui.click_streak = 1
		}
		ui.double_click = ui.click_streak == 2
		ui.triple_click = ui.click_streak == 3
		ui.last_click_t = t
		ui.last_click_pos = ui.mouse
	}
	if !ui.mouse_down {
		ui.drag_focus = .None
		// Failsafe: Loslassen beendet den Chat-Text-Drag immer — auch wenn
		// die Liste, die ihn pflegt, gerade nicht mehr gezeichnet wird.
		g_sel.dragging = false
	}

	// --- Tab-Navigation ---
	// Die Stops des letzten Frames sind die Navigationsbasis (die aktuellen
	// sammeln sich erst während des Zeichnens).
	ui.tab_prev, ui.tab_stops = ui.tab_stops, ui.tab_prev
	clear(&ui.tab_stops)

	// Der Quick Switcher hat eine eigene Pfeiltasten-Navigation und
	// erzwingt seinen Fokus — Tab dort nicht umbiegen. Steht der Caret des
	// fokussierten Eingabefelds in einem ```-Code-Block, gehört Tab dem
	// Editor (Einrückung) statt der Fokus-Navigation.
	if key_pressed(.TAB) && app.modal != .Quick_Switch && !editor_wants_tab(app) {
		stops := make([dynamic]Tab_Stop, context.temp_allocator)
		for s in ui.tab_prev {
			if s.layer == ui.layer {
				append(&stops, s)
			}
		}
		if len(stops) > 0 {
			// tab_focus == 0 heißt "kein Fokus" — nie gegen Stop-IDs matchen,
			// sonst kapert ein Widget den Start der Navigation.
			cur := -1
			if ui.tab_focus != 0 {
				for s, i in stops {
					if s.id == ui.tab_focus {
						cur = i
						break
					}
				}
			}
			// Kein Tab-Fokus, aber ein Textfeld aktiv → von dort starten
			if cur < 0 && ui.focus != .None {
				for s, i in stops {
					if s.focus == ui.focus {
						cur = i
						break
					}
				}
			}
			dir := shift_down() ? -1 : 1
			next := cur < 0 ? (dir > 0 ? 0 : len(stops) - 1) : (cur + dir + len(stops)) %% len(stops)
			s := stops[next]
			ui.tab_focus = s.id
			ui.tab_nav = true
			ui.focus = s.focus
			if s.focus != .None {
				caret_reset(app)
			}
		}
	}
	// Mausklick beendet den Tastatur-Modus (Ring verschwindet, wie :focus-visible)
	if ui.clicked {
		ui.tab_focus = 0
		ui.tab_nav = false
	}
	ui.tab_activate = ui.tab_nav && ui.tab_focus != 0 &&
		(rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) || rl.IsKeyPressed(.SPACE))
}

// Widget als Tab-Stop registrieren. Gibt zurück, ob es gerade den
// Tastatur-Fokus hat (→ Fokus-Ring zeichnen, Enter/Leertaste aktiviert).
tab_stop :: proc(app: ^App, id: u64, r: rl.Rectangle, layer: UI_Layer, focus: Focus = .None, radius: f32 = RADIUS_BTN) -> bool {
	ui := &app.ui
	append(&ui.tab_stops, Tab_Stop{id, layer, focus, r, radius})
	return ui.tab_nav && ui.tab_focus == id && ui.layer == layer
}

// Fokus-Ring um ein Widget (3 px Abstand, 2 px stark).
draw_focus_ring :: proc(r: rl.Rectangle, radius: f32) {
	rrect_lines({r.x - 3, r.y - 3, r.width + 6, r.height + 6}, radius + 3, 2, COL_ACCENT)
}

ui_end_frame :: proc(app: ^App) {
	ui := &app.ui
	// Während einer laufenden Text-Selektion (Chat oder Eingabefeld) hält
	// der I-Beam durch — egal, worüber die Maus gerade zieht.
	if g_sel.dragging || ui.drag_focus != .None {
		ui.cursor = .IBEAM
	}
	// Nur bei Änderung setzen: manche Plattformen flackern sonst, weil das
	// Cursor-Bild jeden Frame neu geladen wird.
	if ui.cursor != ui.applied_cursor {
		rl.SetMouseCursor(ui.cursor)
		ui.applied_cursor = ui.cursor
	}
	if !ui.any_hot {
		ui.hot_id = 0
		ui.hot_t = 0
	}
}

// Hover nur, wenn der Layer des Widgets gerade aktiv ist — und nur im
// sichtbaren (nicht weggeschnittenen) Bereich, damit geclippte Widgets
// nicht durch ihre Abdeckung hindurch reagieren.
ui_hover :: proc(ui: ^UI_Ctx, r: rl.Rectangle, layer: UI_Layer) -> bool {
	if g_sel.dragging {
		// Text-Drag im Chat: kein Widget reagiert auf die Maus (kein
		// Hover-Cursor, keine Tooltips, kein aufploppendes Panel)
		return false
	}
	if ui.layer != layer {
		return false
	}
	if layer == .Base && ui.overlay_on && !ui.in_overlay &&
	   rl.CheckCollisionPointRec(ui.mouse, ui.overlay) {
		return false // Maus liegt über dem schwebenden Call-Popout
	}
	if g_clip_on && !rl.CheckCollisionPointRec(ui.mouse, g_clip) {
		return false
	}
	return rl.CheckCollisionPointRec(ui.mouse, r)
}

ui_click :: proc(ui: ^UI_Ctx, r: rl.Rectangle, layer: UI_Layer) -> bool {
	return ui.clicked && ui_hover(ui, r, layer)
}

// Tooltip anmelden: erscheint nach kurzer Hover-Zeit, gezeichnet am Frame-Ende.
tooltip :: proc(app: ^App, id: u64, r: rl.Rectangle, text: string, layer: UI_Layer) {
	ui := &app.ui
	if !ui_hover(ui, r, layer) {
		return
	}
	ui.any_hot = true
	if ui.hot_id != id {
		ui.hot_id = id
		ui.hot_t = 0
	}
	ui.hot_t += app.dt
	if ui.hot_t > 0.45 {
		ui.tip_text = fmt.tprintf("%s", text)
		ui.tip_anchor = r
		ui.tip_show = true
	}
}

// Am Ende des Frames aufrufen — zeichnet den ggf. angemeldeten Tooltip.
ui_draw_tooltip :: proc(app: ^App) {
	ui := &app.ui
	if !ui.tip_show {
		return
	}
	font := app.fonts.regular13
	tw := rl.MeasureTextEx(font, tcstr(ui.tip_text), 13, 0)
	pad := f32(8)
	w := tw.x + pad*2
	h := f32(26)
	sw := f32(rl.GetScreenWidth()) / g_scale
	x := ui.tip_anchor.x + ui.tip_anchor.width + 10
	y := ui.tip_anchor.y + (ui.tip_anchor.height - h)/2
	// rechts kein Platz → über dem Anker
	if x + w > sw - 8 {
		x = clamp(ui.tip_anchor.x + (ui.tip_anchor.width - w)/2, 8, sw - w - 8)
		y = ui.tip_anchor.y - h - 8
	}
	alpha := clamp((ui.hot_t - 0.45) * 8, 0, 1)
	r := rl.Rectangle{x, y, w, h}
	rrect(r, 6, fade(COL_TOOLTIP_BG, alpha))
	draw_text(font, tcstr(ui.tip_text), {x + pad, y + (h - 13)/2 - 1}, 13, 0, fade(COL_TOOLTIP_FG, alpha))
}

// Taste gedrückt inkl. Key-Repeat.
key_pressed :: proc(k: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k)
}

ctrl_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

shift_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
}

alt_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
}

tcstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// --- Text-Input ---
// Inhalt als Runen; cursor und sel (Anker) sind Runen-Indizes.
// sel == cursor bedeutet: keine Selektion.

Text_Input :: struct {
	runes:  [dynamic]rune,
	cursor: int,
	sel:    int,
}

ti_text :: proc(ti: ^Text_Input, allocator := context.temp_allocator) -> string {
	s, _ := utf8.runes_to_string(ti.runes[:], allocator)
	return s
}

ti_set_text :: proc(ti: ^Text_Input, s: string) {
	clear(&ti.runes)
	for r in s {
		append(&ti.runes, r)
	}
	ti.cursor = len(ti.runes)
	ti.sel = ti.cursor
}

ti_clear :: proc(ti: ^Text_Input) {
	clear(&ti.runes)
	ti.cursor = 0
	ti.sel = 0
}

ti_has_sel :: proc(ti: ^Text_Input) -> bool {
	return ti.sel != ti.cursor
}

ti_sel_range :: proc(ti: ^Text_Input) -> (lo, hi: int) {
	return min(ti.sel, ti.cursor), max(ti.sel, ti.cursor)
}

ti_selected_text :: proc(ti: ^Text_Input) -> string {
	lo, hi := ti_sel_range(ti)
	s, _ := utf8.runes_to_string(ti.runes[lo:hi], context.temp_allocator)
	return s
}

ti_delete_sel :: proc(ti: ^Text_Input) {
	lo, hi := ti_sel_range(ti)
	if lo == hi {
		return
	}
	remove_range(&ti.runes, lo, hi)
	ti.cursor = lo
	ti.sel = lo
}

ti_insert :: proc(ti: ^Text_Input, r: rune) {
	ti_delete_sel(ti)
	inject_at(&ti.runes, ti.cursor, r)
	ti.cursor += 1
	ti.sel = ti.cursor
}

// Cursor setzen; extend=true behält den Selektionsanker (Shift).
ti_move :: proc(ti: ^Text_Input, pos: int, extend: bool) {
	ti.cursor = clamp(pos, 0, len(ti.runes))
	if !extend {
		ti.sel = ti.cursor
	}
}

is_word_rune :: proc(r: rune) -> bool {
	switch r {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		return true
	}
	return r >= 0xC0 // Umlaute & Co. zählen zum Wort
}

// Wortgrenze links von i.
word_left :: proc(runes: []rune, i: int) -> int {
	j := i
	for j > 0 && !is_word_rune(runes[j-1]) {
		j -= 1
	}
	for j > 0 && is_word_rune(runes[j-1]) {
		j -= 1
	}
	return j
}

word_right :: proc(runes: []rune, i: int) -> int {
	j := i
	for j < len(runes) && !is_word_rune(runes[j]) {
		j += 1
	}
	for j < len(runes) && is_word_rune(runes[j]) {
		j += 1
	}
	return j
}

// Logische Zeile (zwischen \n) um Index i selektieren (Dreifachklick).
ti_select_line :: proc(ti: ^Text_Input, i: int) {
	lo := clamp(i, 0, len(ti.runes))
	hi := lo
	for lo > 0 && ti.runes[lo-1] != '\n' {
		lo -= 1
	}
	for hi < len(ti.runes) && ti.runes[hi] != '\n' {
		hi += 1
	}
	ti.sel = lo
	ti.cursor = hi
}

// Wort unter Index selektieren (Doppelklick).
ti_select_word :: proc(ti: ^Text_Input, i: int) {
	i := clamp(i, 0, max(0, len(ti.runes)-1))
	if len(ti.runes) == 0 {
		return
	}
	lo, hi := i, i
	if is_word_rune(ti.runes[i]) {
		for lo > 0 && is_word_rune(ti.runes[lo-1]) {
			lo -= 1
		}
		for hi < len(ti.runes) && is_word_rune(ti.runes[hi]) {
			hi += 1
		}
	} else {
		hi = i + 1
	}
	ti.sel = lo
	ti.cursor = hi
}

// Tastatur-Eingaben verarbeiten. Gibt submitted=true bei Enter zurück
// (bei multiline nur ohne Shift). max_runes begrenzt die Länge (0 = egal).
ti_update :: proc(app: ^App, ti: ^Text_Input, multiline: bool, max_runes := 0) -> (submitted: bool) {
	changed := false

	// Zeichen-Eingabe (Runen-Queue)
	for {
		r := rl.GetCharPressed()
		if r == 0 {
			break
		}
		if r >= 32 && (max_runes == 0 || len(ti.runes) < max_runes || ti_has_sel(ti)) {
			ti_insert(ti, r)
			changed = true
		}
	}

	if ctrl_down() {
		if rl.IsKeyPressed(.A) {
			ti.sel = 0
			ti.cursor = len(ti.runes)
			changed = true
		}
		if rl.IsKeyPressed(.C) && ti_has_sel(ti) {
			rl.SetClipboardText(tcstr(ti_selected_text(ti)))
		}
		if rl.IsKeyPressed(.X) && ti_has_sel(ti) {
			rl.SetClipboardText(tcstr(ti_selected_text(ti)))
			ti_delete_sel(ti)
			changed = true
		}
		if rl.IsKeyPressed(.V) {
			clip := rl.GetClipboardText()
			if clip != nil {
				for r in string(clip) {
					if max_runes != 0 && len(ti.runes) >= max_runes {
						break
					}
					// Tabs überleben das Einfügen (Code-Einrückung!)
					if r >= 32 || ((r == '\n' || r == '\t') && multiline) {
						ti_insert(ti, r)
					}
				}
				changed = true
			}
		}
	}

	if key_pressed(.BACKSPACE) {
		if ti_has_sel(ti) {
			ti_delete_sel(ti)
		} else if ti.cursor > 0 {
			if ctrl_down() {
				lo := word_left(ti.runes[:], ti.cursor)
				remove_range(&ti.runes, lo, ti.cursor)
				ti.cursor = lo
				ti.sel = lo
			} else {
				ordered_remove(&ti.runes, ti.cursor - 1)
				ti.cursor -= 1
				ti.sel = ti.cursor
			}
		}
		changed = true
	}
	if key_pressed(.DELETE) {
		if ti_has_sel(ti) {
			ti_delete_sel(ti)
		} else if ti.cursor < len(ti.runes) {
			if ctrl_down() {
				hi := word_right(ti.runes[:], ti.cursor)
				remove_range(&ti.runes, ti.cursor, hi)
			} else {
				ordered_remove(&ti.runes, ti.cursor)
			}
			ti.sel = ti.cursor
		}
		changed = true
	}

	extend := shift_down()
	if key_pressed(.LEFT) {
		if !extend && ti_has_sel(ti) {
			lo, _ := ti_sel_range(ti)
			ti_move(ti, lo, false)
		} else {
			pos := ctrl_down() ? word_left(ti.runes[:], ti.cursor) : ti.cursor - 1
			ti_move(ti, pos, extend)
		}
		changed = true
	}
	if key_pressed(.RIGHT) {
		if !extend && ti_has_sel(ti) {
			_, hi := ti_sel_range(ti)
			ti_move(ti, hi, false)
		} else {
			pos := ctrl_down() ? word_right(ti.runes[:], ti.cursor) : ti.cursor + 1
			ti_move(ti, pos, extend)
		}
		changed = true
	}
	if rl.IsKeyPressed(.HOME) {
		ti_move(ti, 0, extend)
		changed = true
	}
	if rl.IsKeyPressed(.END) {
		ti_move(ti, len(ti.runes), extend)
		changed = true
	}

	if key_pressed(.ENTER) || key_pressed(.KP_ENTER) {
		if multiline && shift_down() {
			ti_insert(ti, '\n')
			changed = true
		} else {
			submitted = true
		}
	}

	if changed {
		caret_reset(app)
	}
	return
}

// Runen-Index zur x-Position (relativ zum Textanfang) in einer Runenfolge.
ti_index_at :: proc(font: rl.Font, size: f32, runes: []rune, rel_x: f32) -> int {
	x := f32(0)
	for r, i in runes {
		s, _ := utf8.runes_to_string([]rune{r}, context.temp_allocator)
		w := rl.MeasureTextEx(font, tcstr(s), size, 0).x
		if rel_x < x + w/2 {
			return i
		}
		x += w
	}
	return len(runes)
}

// --- Einzeiliges Textfeld ---

text_field :: proc(
	app: ^App,
	r: rl.Rectangle,
	ti: ^Text_Input,
	focus_id: Focus,
	layer: UI_Layer,
	placeholder: string,
	password := false,
) -> (submitted: bool) {
	ui := &app.ui
	hovered := ui_hover(ui, r, layer)
	if hovered {
		ui.cursor = .IBEAM
	}
	// Textfelder zeigen ihren Fokus über den Glow — der Stop dient nur der Navigation.
	tab_stop(app, anim_id(.Input_Focus, u64(focus_id)), r, layer, focus_id, RADIUS_INPUT)
	focused := ui.focus == focus_id && ui.layer == layer

	font := app.fonts.regular15
	pad := f32(12)

	// Anzeige-Runen (Passwort → Punkte)
	shown_runes := ti.runes[:]
	if password {
		masked := make([dynamic]rune, 0, len(ti.runes), context.temp_allocator)
		for _ in ti.runes {
			append(&masked, '•')
		}
		shown_runes = masked[:]
	}

	// Scroll-Offset, damit der Cursor sichtbar bleibt
	prefix := runes_str(shown_runes[:clamp(ti.cursor, 0, len(shown_runes))])
	cw := rl.MeasureTextEx(font, tcstr(prefix), 15, 0).x
	offset := f32(0)
	avail := r.width - 2*pad
	if cw > avail {
		offset = cw - avail
	}

	// Maus: Klick setzt Cursor, Drag selektiert, Doppelklick Wort
	if ui.clicked && ui.layer == layer && hovered {
		ui.focus = focus_id
		idx := ti_index_at(font, 15, shown_runes, ui.mouse.x - (r.x + pad - offset))
		if ui.triple_click {
			ti_select_line(ti, idx) // einzeilig = kompletter Inhalt
		} else if ui.double_click {
			ti_select_word(ti, idx)
		} else {
			ti_move(ti, idx, shift_down())
			ui.drag_focus = focus_id
		}
		caret_reset(app)
	}
	if ui.drag_focus == focus_id && ui.mouse_down && !ui.clicked {
		idx := ti_index_at(font, 15, shown_runes, ui.mouse.x - (r.x + pad - offset))
		ti_move(ti, idx, true)
	}

	if focused {
		submitted = ti_update(app, ti, false)
	}

	// Rahmen + Hintergrund + Fokus-Glow
	t := anim_to(app, anim_id(.Input_Focus, u64(focus_id)), focused ? 1 : 0, 18)
	rrect(r, RADIUS_INPUT, COL_SURFACE)
	if t > 0.01 {
		glow := rl.Rectangle{r.x - 3, r.y - 3, r.width + 6, r.height + 6}
		rrect_lines(glow, RADIUS_INPUT + 3, 3, fade(COL_ACCENT_SOFT, t))
	}
	rrect_lines(r, RADIUS_INPUT, focused ? 1.6 : 1, mix(COL_BORDER, COL_ACCENT, t))

	text := ti_text(ti)
	ty := r.y + (r.height - 15) / 2 - 1

	scissor_begin(r.x + 2, r.y, r.width - 4, r.height)
	defer scissor_end()

	if len(text) == 0 && len(placeholder) > 0 {
		draw_text(font, tcstr(placeholder), {r.x + pad, ty}, 15, 0, COL_TEXT_FAINT)
	}

	// Selektion hinterlegen
	if ti_has_sel(ti) && focused {
		lo, hi := ti_sel_range(ti)
		x0 := rl.MeasureTextEx(font, tcstr(runes_str(shown_runes[:lo])), 15, 0).x
		x1 := rl.MeasureTextEx(font, tcstr(runes_str(shown_runes[:hi])), 15, 0).x
		rl.DrawRectangleRec({r.x + pad - offset + x0, r.y + 6, x1 - x0, r.height - 12}, fade(COL_ACCENT, 0.3))
	}

	draw_text(font, tcstr(runes_str(shown_runes)), {r.x + pad - offset, ty}, 15, 0, COL_TEXT)
	if focused && caret_visible(app) {
		cx := r.x + pad - offset + cw
		rl.DrawLineEx({cx, r.y + 8}, {cx, r.y + r.height - 8}, 1.4, COL_TEXT)
	}
	return
}

// --- Buttons ---

Button_Style :: enum {
	Default,
	Primary,
	Danger,       // weiß mit rotem Text/Rahmen
	Danger_Solid, // gefüllt rot (destruktive Bestätigung)
	Ghost,        // nur Text, Hover-Fläche
}

button :: proc(app: ^App, r: rl.Rectangle, label: string, layer: UI_Layer, style := Button_Style.Default, id_salt: u64 = 0) -> bool {
	ui := &app.ui
	hovered := ui_hover(ui, r, layer)
	pressed := hovered && ui.mouse_down
	if hovered {
		ui.cursor = .POINTING_HAND
	}

	// In scrollenden Listen wandert r.y jeden Frame → id_salt hat Vorrang
	raw := id_salt != 0 ? id_salt : u64(i64(r.x)*7919 + i64(r.y)*31) ~ (u64(len(label)) << 40)
	id := anim_id(.Button, raw)
	focused := tab_stop(app, id, r, layer)
	t := anim_to(app, id, (hovered || focused) ? 1 : 0, 18)

	bg, fg, border: rl.Color
	has_border := false
	switch style {
	case .Default:
		bg = mix(COL_SURFACE, COL_SURFACE_HOVER, t)
		fg = COL_TEXT
		border = COL_BORDER
		has_border = true
	case .Primary:
		bg = mix(COL_PRIMARY, COL_PRIMARY_HOVER, t)
		fg = COL_PRIMARY_FG
	case .Danger:
		bg = mix(COL_SURFACE, COL_RED_SOFT, t)
		fg = COL_RED
		border = fade(COL_RED, 0.45)
		has_border = true
	case .Danger_Solid:
		bg = mix(COL_RED, COL_RED_HOVER, t)
		fg = COL_WHITE // Rot bleibt Rot — Weiß trägt in beiden Themes
	case .Ghost:
		bg = fade(COL_OVERLAY, t * 0.06)
		fg = COL_TEXT_DIM
	}
	if pressed {
		bg = mix(bg, COL_PRESS, 0.07)
	}

	rr := r
	if pressed {
		rr.y += 1
	}
	rrect(rr, RADIUS_BTN, bg)
	if has_border {
		rrect_lines(rr, RADIUS_BTN, 1, border)
	}
	if focused {
		draw_focus_ring(rr, RADIUS_BTN)
	}
	font := app.fonts.bold15
	tw := rl.MeasureTextEx(font, tcstr(label), 15, 0)
	draw_text(font, tcstr(label), {rr.x + (rr.width - tw.x)/2, rr.y + (rr.height - tw.y)/2}, 15, 0, fg)
	return ui_click(ui, r, layer) || (focused && ui.tab_activate)
}

// Schalter (an/aus) mit animiertem Knopf. id muss stabil sein.
toggle_switch :: proc(app: ^App, r: rl.Rectangle, id: u64, on: bool, layer: UI_Layer) -> bool {
	ui := &app.ui
	hovered := ui_hover(ui, r, layer)
	focused := tab_stop(app, id, r, layer, radius = r.height/2)
	t := anim_to(app, id, on ? 1 : 0, 18)

	rrect(r, r.height/2, mix(COL_RAIL_ITEM, COL_PRIMARY, t))
	if focused {
		draw_focus_ring(r, r.height/2)
	}
	pad := f32(3)
	kd := r.height - pad*2
	kx := r.x + pad + (r.width - kd - pad*2)*t
	rl.DrawCircleV({kx + kd/2, r.y + r.height/2}, kd/2, mix(COL_SURFACE, COL_PRIMARY_FG, t))
	rl.DrawCircleLinesV({kx + kd/2, r.y + r.height/2}, kd/2, COL_BORDER)
	if hovered {
		ui.cursor = .POINTING_HAND
	}
	return ui_click(ui, r, layer) || (focused && ui.tab_activate)
}

// --- Scrollbar (fade-in bei Aktivität/Hover, draggable) ---

scrollbar :: proc(app: ^App, area: rl.Rectangle, content_h: f32, s: ^Scroll, layer: UI_Layer) {
	if content_h <= area.height {
		return
	}
	ui := &app.ui
	track := rl.Rectangle{area.x + area.width - 10, area.y + 2, 6, area.height - 4}
	ratio := area.height / content_h
	thumb_h := max(28, track.height * ratio)
	max_scroll := content_h - area.height
	ty := track.y + (track.height - thumb_h) * (s.pos / max_scroll)
	thumb := rl.Rectangle{track.x, ty, track.width, thumb_h}

	hovered := ui_hover(ui, area, layer)
	thumb_hover := ui_hover(ui, rl.Rectangle{thumb.x - 4, thumb.y, thumb.width + 8, thumb.height}, layer)

	if ui.clicked && thumb_hover {
		s.dragging = true
		s.drag_off = ui.mouse.y - thumb.y
	} else if ui.clicked && ui_hover(ui, track, layer) {
		// Klick auf Track: dorthin springen
		frac := clamp((ui.mouse.y - track.y - thumb_h/2) / (track.height - thumb_h), 0, 1)
		scroll_to(s, frac * max_scroll)
		s.activity = 1
	}
	if s.dragging {
		if !ui.mouse_down {
			s.dragging = false
		} else {
			frac := clamp((ui.mouse.y - s.drag_off - track.y) / (track.height - thumb_h), 0, 1)
			scroll_to(s, frac * max_scroll)
			s.activity = 1
		}
	}

	show := hovered || s.activity > 0 || s.dragging
	id := anim_id(.Scrollbar, u64(uintptr(rawptr(s))))
	a := anim_to(app, id, show ? 1 : 0, 12)
	if a < 0.02 {
		return
	}
	col := (thumb_hover || s.dragging) ? COL_SCROLL_THUMB_HOT : COL_SCROLL_THUMB
	rrect(thumb, 3, fade(col, a))
}

// --- Kleinkram ---

draw_text_centered :: proc(font: rl.Font, text: string, cx, y: f32, size: f32, color: rl.Color) {
	w := rl.MeasureTextEx(font, tcstr(text), size, 0).x
	draw_text(font, tcstr(text), {cx - w/2, y}, size, 0, color)
}

// Einzelnes Zeichen exakt auf (cx, cy) zentrieren — nutzt die tatsächlichen
// Bitmap-Bounds der Glyphe statt der Zeilenbox (Icons in Kreisen etc.).
// Atlas-Maße sind physische Pixel → für logische Koordinaten durch g_scale.
draw_rune_centered :: proc(font: rl.Font, r: rune, cx, cy: f32, color: rl.Color) {
	idx := rl.GetGlyphIndex(font, r)
	g := font.glyphs[idx]
	rec := font.recs[idx]
	inv := 1 / g_scale
	x := cx - (rec.width/2 + f32(g.offsetX)) * inv
	y := cy - (rec.height/2 + f32(g.offsetY)) * inv
	x = math.round(x * g_scale) / g_scale
	y = math.round(y * g_scale) / g_scale
	rl.DrawTextCodepoint(font, r, {x, y}, f32(font.baseSize) * inv, color)
}

// --- Icon-Wrapper (Lucide) ---
// Alle Symbol-Icons kommen aus dem Lucide-Set (lucide.odin/draw_icon).
// Die Wrapper behalten die alten Signaturen und Größen-Semantiken bei —
// die Skalierungsfaktoren gleichen die Inhalts-Spannweite des jeweiligen
// Lucide-Icons in der 24er-Box aus, damit die optische Größe der alten
// Handzeichnungen erhalten bleibt.

// Plus („plus“). half = halbe Strichlänge.
draw_plus :: proc(cx, cy, half, thick: f32, color: rl.Color) {
	draw_icon(.Plus, cx, cy, half * 3.4, color, thick)
}

// Häkchen („check“). size = Breite des Hakens.
draw_check :: proc(cx, cy, size, thick: f32, color: rl.Color) {
	draw_icon(.Check, cx, cy, size * 1.4, color, thick)
}

// X („x“, Schließen/Abbrechen). size = Diagonale-Spannweite.
draw_cross :: proc(cx, cy, size, thick: f32, color: rl.Color) {
	draw_icon(.X, cx, cy, size * 2, color, thick)
}

// Drei vertikale Punkte („ellipsis-vertical“). gap = Punktabstand.
draw_dots_v :: proc(cx, cy, gap, r: f32, color: rl.Color) {
	size := gap * 24.0 / 7.0
	draw_icon(.Ellipsis_Vertical, cx, cy, size, color, max(2*(r - size/24), 1.2))
}

// Kopfhörer („headphones“). r ≈ halbe Breite.
draw_headphones :: proc(cx, cy, r, thick: f32, color: rl.Color) {
	draw_icon(.Headphones, cx, cy, r * 3.1, color, thick)
}

// Mikrofon („mic“ / „mic-off“). bg wird nicht mehr gebraucht (das
// Off-Icon bringt seinen Streichstrich selbst mit).
draw_mic :: proc(cx, cy, size, thick: f32, color, bg: rl.Color, crossed: bool) {
	_ = bg
	draw_icon(crossed ? Icon.Mic_Off : Icon.Mic, cx, cy, size * 1.2, color, thick)
}

// Auflegen („phone-off“). r ≈ halbe Breite.
draw_hangup :: proc(cx, cy, r, thick: f32, color: rl.Color) {
	draw_icon(.Phone_Off, cx, cy, r * 2.4, color, thick)
}

// Schild mit Haken („shield-check“, Admin-Panel). size = Höhe.
draw_shield :: proc(cx, cy, size, thick: f32, color: rl.Color) {
	draw_icon(.Shield_Check, cx, cy, size * 1.2, color, thick)
}

// Zahnrad („settings“). r = Außenradius.
draw_gear :: proc(cx, cy, r, thick: f32, color: rl.Color) {
	draw_icon(.Settings, cx, cy, r * 2.5, color, thick)
}

// Ausgliedern („external-link“, Call-Popout).
draw_popout_icon :: proc(cx, cy, size, thick: f32, color: rl.Color) {
	draw_icon(.External_Link, cx, cy, size * 1.33, color, thick)
}

// Kopieren („copy“). bg wird nicht mehr gebraucht (Stroke-Icon).
draw_copy_icon :: proc(cx, cy, size, thick: f32, color, bg: rl.Color) {
	_ = bg
	draw_icon(.Copy, cx, cy, size * 1.05, color, thick)
}

// Sonne („sun“). turn dreht sie (Theme-Übergang).
draw_sun :: proc(cx, cy, r, turn: f32, color: rl.Color) {
	draw_icon(.Sun, cx, cy, r * 3.1, color, max(f32(1.4), r*0.19), turn)
}

// Mond („moon“). turn wie bei der Sonne; bg wird nicht mehr gebraucht.
draw_moon :: proc(cx, cy, r, turn: f32, color, bg: rl.Color) {
	_ = bg
	draw_icon(.Moon, cx, cy, r * 2.7, color, max(f32(1.4), r*0.19), turn)
}

runes_str :: proc(runes: []rune) -> string {
	s, _ := utf8.runes_to_string(runes, context.temp_allocator)
	return s
}

// Akzentfarbe aus einem String-Hash (für Avatare / Server-Icons).
hash_color :: proc(s: string) -> rl.Color {
	palette := [?]rl.Color{
		{88, 101, 242, 255},  // Indigo
		{224, 30, 90, 255},   // Pink
		{35, 165, 90, 255},   // Grün
		{242, 140, 24, 255},  // Orange
		{155, 89, 182, 255},  // Lila
		{0, 150, 170, 255},   // Petrol
		{219, 76, 63, 255},   // Terracotta
		{96, 125, 139, 255},  // Blaugrau
	}
	h: u32 = 2166136261
	for b in transmute([]byte)s {
		h = (h ~ u32(b)) * 16777619
	}
	return palette[h % len(palette)]
}

// Initialen (max. 2 Zeichen) aus einem Namen.
initials :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	count := 0
	prev_space := true
	for r in s {
		if r == ' ' || r == '-' || r == '_' || r == '.' {
			prev_space = true
			continue
		}
		if prev_space && count < 2 {
			strings.write_rune(&sb, to_upper_rune(r))
			count += 1
		}
		prev_space = false
	}
	if count == 0 {
		strings.write_rune(&sb, '?')
	}
	return strings.to_string(sb)
}

to_upper_rune :: proc(r: rune) -> rune {
	if r >= 'a' && r <= 'z' {
		return r - 32
	}
	if r >= 0xE0 && r <= 0xFE && r != 0xF7 {
		return r - 32
	}
	return r
}

// Avatar-Kreis: Profilbild (falls vorhanden und c/uid übergeben), sonst
// Initiale auf Hash-Farbe; optional Presence-Punkt unten rechts.
draw_avatar :: proc(app: ^App, name: string, x, y, size: f32, presence := false, online := false, c: ^Server_Conn = nil, uid: u64 = 0) {
	cx := x + size/2
	cy := y + size/2
	drew_image := false
	if c != nil && uid != 0 {
		if tex, ok := avatar_texture(app, c, uid); ok {
			src := rl.Rectangle{0, 0, f32(tex.width), f32(tex.height)}
			rl.DrawTexturePro(tex, src, {x, y, size, size}, {0, 0}, 0, rl.WHITE)
			// Hairline, damit sich helle Fotos vom Hintergrund abheben
			rl.DrawRing({cx, cy}, size/2 - 1, size/2, 0, 360, 36, fade(COL_OVERLAY, 0.10))
			drew_image = true
		}
	}
	if !drew_image {
		rl.DrawCircleV({cx, cy}, size/2, hash_color(name))
		ini := initials(name)
		font := size >= 30 ? app.fonts.bold15 : app.fonts.bold11
		fsize := size >= 30 ? f32(15) : f32(11)
		tw := rl.MeasureTextEx(font, tcstr(ini), fsize, 0)
		draw_text(font, tcstr(ini), {x + (size - tw.x)/2, y + (size - tw.y)/2}, fsize, 0, COL_WHITE)
	}
	if presence {
		px := x + size - size*0.12
		py := y + size - size*0.12
		rl.DrawCircleV({px, py}, size*0.17 + 2, COL_SIDEBAR_BG)
		if online {
			rl.DrawCircleV({px, py}, size*0.17, COL_ONLINE)
		} else {
			rl.DrawCircleLinesV({px, py}, size*0.15, COL_SIDEBAR_DIM)
		}
	}
}
