package main

// Profilbild-UI: Bildquelle laden (Dateidialog oder Drag & Drop), Zuschnitt
// im Kreis-Editor (Bild unter fixem Kreis verschieben + zoomen), Bake auf
// AVATAR_BAKE_DIM² und Upload. Der Editor ist ein normales Modal und wird
// aus den Einstellungen ODER dem Registrier-Formular geöffnet.

import "core:encoding/base64"
import "core:fmt"
import "core:os"

import rl "vendor:raylib"
import shared "../shared"

AVATAR_SRC_MAX_BYTES :: 10 * 1024 * 1024 // Quelldatei
AVATAR_SRC_MAX_DIM :: 8192               // Quellmaße (vor dem Dekodieren geprüft)
AVATAR_PREVIEW_MAX :: 2048               // größere Quellen werden vorverkleinert

CROP_VIEW :: f32(320)   // Sichtfenster des Editors
CROP_CIRCLE :: f32(280) // Durchmesser des Kreis-Overlays
CROP_ZOOM_MAX :: f32(6)

// Pro Frame (app_poll): Dateidialog-Ergebnis und Drag & Drop einsammeln.
avatar_tick :: proc(app: ^App) {
	if path, ok := avatar_pick_poll(); ok {
		defer delete(path)
		if path != "" {
			avatar_load_source(app, path)
		}
	}
	if rl.IsFileDropped() {
		files := rl.LoadDroppedFiles()
		defer rl.UnloadDroppedFiles(files)
		if files.count > 0 {
			if receptive, to_auth, ret := avatar_drop_target(app); receptive {
				app.av_to_auth = to_auth
				app.av_return_settings = ret
				avatar_load_source(app, string(files.paths[0]))
			}
		}
	}
}

// Wohin gehört ein gedroppes Bild gerade? (Crop-Editor offen → Quelle
// ersetzen; Einstellungen → Upload-Pfad; Registrier-Formular → Formular.)
@(private = "file")
avatar_drop_target :: proc(app: ^App) -> (receptive, to_auth, ret_settings: bool) {
	if app.modal == .Avatar_Crop {
		return true, app.av_to_auth, app.av_return_settings
	}
	if app.modal == .Settings {
		return true, false, true
	}
	if app.modal == .None {
		if c := app_active_conn(app); c != nil && conn_phase(c) == .Auth_Needed {
			if !c.initialized || c.auth_tab == 1 {
				return true, true, false
			}
		}
	}
	return false, false, false
}

// Dateidialog anstoßen; das Ergebnis routet avatar_tick.
avatar_begin_pick :: proc(app: ^App, to_auth, ret_settings: bool) {
	app.av_to_auth = to_auth
	app.av_return_settings = ret_settings
	avatar_pick_start()
}

// ---------- Quelle laden ----------

// Bildmaße aus den Headern lesen, ohne zu dekodieren (Schutz vor
// Dekompressions-Bomben). kind ist die raylib-Extension.
@(private = "file")
sniff_image :: proc(data: []byte) -> (w, h: int, kind: cstring, ok: bool) {
	be16 :: proc(b: []byte) -> int {return int(b[0]) << 8 | int(b[1])}
	be32 :: proc(b: []byte) -> int {
		return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3])
	}
	if pw, ph, pok := shared.png_dims(data); pok {
		return pw, ph, ".png", true
	}
	if len(data) > 12 && data[0] == 0xFF && data[1] == 0xD8 {
		// JPEG: Marker bis zum SOF-Segment (Cx außer C4/C8/CC) abklappern
		i := 2
		for i + 9 < len(data) {
			if data[i] != 0xFF {
				break
			}
			m := data[i + 1]
			if m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC {
				return be16(data[i+7:]), be16(data[i+5:]), ".jpg", true
			}
			if m == 0xD8 || (m >= 0xD0 && m <= 0xD7) {
				i += 2
				continue
			}
			i += 2 + be16(data[i+2:])
		}
		return
	}
	if len(data) > 26 && data[0] == 'B' && data[1] == 'M' {
		le32 :: proc(b: []byte) -> int {
			return int(b[0]) | int(b[1]) << 8 | int(b[2]) << 16 | int(b[3]) << 24
		}
		bw := le32(data[18:])
		bh := le32(data[22:])
		return abs(bw), abs(bh), ".bmp", true
	}
	if len(data) > 12 && string(data[:4]) == "qoif" {
		return be32(data[4:]), be32(data[8:]), ".qoi", true
	}
	return
}

// Quelldatei prüfen, dekodieren und den Crop-Editor öffnen.
avatar_load_source :: proc(app: ^App, path: string) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		toast(app, .Error, "Datei konnte nicht gelesen werden")
		return
	}
	if len(data) > AVATAR_SRC_MAX_BYTES {
		toast(app, .Error, fmt.tprintf("Bild zu groß — maximal %d MB", AVATAR_SRC_MAX_BYTES / (1024*1024)))
		return
	}
	w, h, kind, ok := sniff_image(data)
	if !ok {
		toast(app, .Error, "Format nicht unterstützt (PNG, JPEG, BMP, QOI)")
		return
	}
	if w < shared.AVATAR_MIN_DIM || h < shared.AVATAR_MIN_DIM {
		toast(app, .Error, fmt.tprintf("Bild zu klein — mindestens %d × %d Pixel", shared.AVATAR_MIN_DIM, shared.AVATAR_MIN_DIM))
		return
	}
	if w > AVATAR_SRC_MAX_DIM || h > AVATAR_SRC_MAX_DIM {
		toast(app, .Error, fmt.tprintf("Bild zu groß — maximal %d × %d Pixel", AVATAR_SRC_MAX_DIM, AVATAR_SRC_MAX_DIM))
		return
	}

	img := rl.LoadImageFromMemory(kind, raw_data(data), i32(len(data)))
	if img.data == nil {
		toast(app, .Error, "Bild konnte nicht dekodiert werden")
		return
	}
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)

	// Riesige Quellen vorverkleinern — fürs Bake auf 256² reicht das dicke.
	if img.width > AVATAR_PREVIEW_MAX || img.height > AVATAR_PREVIEW_MAX {
		scale := min(f32(AVATAR_PREVIEW_MAX) / f32(img.width), f32(AVATAR_PREVIEW_MAX) / f32(img.height))
		rl.ImageResize(&img, i32(f32(img.width) * scale), i32(f32(img.height) * scale))
	}

	avatar_crop_cleanup(app)
	app.av_img = img
	app.av_tex = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(app.av_tex, .BILINEAR)
	app.av_loaded = true
	app.av_zoom = 1
	app.av_pan = {0, 0}
	if app.modal != .Avatar_Crop {
		open_modal(app, .Avatar_Crop)
	}
}

// Editor-Ressourcen freigeben (Modal zu / Quelle ersetzt).
avatar_crop_cleanup :: proc(app: ^App) {
	if !app.av_loaded {
		return
	}
	rl.UnloadTexture(app.av_tex)
	rl.UnloadImage(app.av_img)
	app.av_loaded = false
	app.av_dragging = false
	app.av_slider_drag = false
}

// ---------- Crop-Editor (Modal) ----------

// Pan so begrenzen, dass der Kreis immer vollständig im Bild liegt.
@(private = "file")
crop_clamp_pan :: proc(app: ^App) {
	s := crop_scale(app)
	max_x := (f32(app.av_img.width) * s - CROP_CIRCLE) / 2
	max_y := (f32(app.av_img.height) * s - CROP_CIRCLE) / 2
	app.av_pan.x = clamp(app.av_pan.x, -max_x, max_x)
	app.av_pan.y = clamp(app.av_pan.y, -max_y, max_y)
}

@(private = "file")
crop_scale :: proc(app: ^App) -> f32 {
	base := CROP_CIRCLE / f32(min(app.av_img.width, app.av_img.height))
	return base * app.av_zoom
}

// Zoom setzen und den Pan mitskalieren (der Ausschnitt bleibt zentriert).
@(private = "file")
crop_set_zoom :: proc(app: ^App, zoom: f32) {
	old := crop_scale(app)
	app.av_zoom = clamp(zoom, 1, CROP_ZOOM_MAX)
	if old > 0 {
		f := crop_scale(app) / old
		app.av_pan.x *= f
		app.av_pan.y *= f
	}
	crop_clamp_pan(app)
}

draw_avatar_crop_modal :: proc(app: ^App, c: ^Server_Conn, sw, sh: f32) {
	if !app.av_loaded {
		close_modal(app)
		return
	}
	w := f32(460)
	h := f32(536)
	p := modal_frame(app, sw, sh, w, h, "Profilbild zuschneiden")

	view := rl.Rectangle{p.x + (p.width - CROP_VIEW)/2, p.y + 54, CROP_VIEW, CROP_VIEW}
	vcx := view.x + view.width/2
	vcy := view.y + view.height/2

	// --- Interaktion (vor dem Zeichnen, damit der Frame den neuen Stand zeigt) ---
	hovered := ui_hover(&app.ui, view, .Modal)
	if hovered {
		app.ui.cursor = .RESIZE_ALL
		if app.ui.wheel != 0 {
			crop_set_zoom(app, app.av_zoom * (1 + app.ui.wheel * 0.12))
		}
	}
	if ui_click(&app.ui, view, .Modal) {
		app.av_dragging = true
		app.av_last = app.ui.mouse
	}
	if app.av_dragging {
		if !app.ui.mouse_down {
			app.av_dragging = false
		} else {
			app.av_pan.x += app.ui.mouse.x - app.av_last.x
			app.av_pan.y += app.ui.mouse.y - app.av_last.y
			app.av_last = app.ui.mouse
			app.ui.cursor = .RESIZE_ALL
		}
	}
	crop_clamp_pan(app)

	// --- Bild + Kreis-Overlay ---
	s := crop_scale(app)
	dw := f32(app.av_img.width) * s
	dh := f32(app.av_img.height) * s
	dst := rl.Rectangle{vcx + app.av_pan.x - dw/2, vcy + app.av_pan.y - dh/2, dw, dh}

	scissor_begin(view.x, view.y, view.width, view.height)
	rl.DrawRectangleRec(view, COL_PANEL_BG)
	src := rl.Rectangle{0, 0, f32(app.av_tex.width), f32(app.av_tex.height)}
	rl.DrawTexturePro(app.av_tex, src, dst, {0, 0}, 0, rl.WHITE)
	// Scrim außerhalb des Kreises: ein dicker Ring bis über die Ecken hinaus
	rl.DrawRing({vcx, vcy}, CROP_CIRCLE/2, CROP_VIEW, 0, 360, 64, rl.Color{0, 0, 0, 130})
	rl.DrawRing({vcx, vcy}, CROP_CIRCLE/2 - 1, CROP_CIRCLE/2 + 1, 0, 360, 64, fade(COL_WHITE, 0.9))
	scissor_end()
	rrect_lines(view, 4, 1, COL_BORDER)

	// --- Zoom-Slider ---
	track := rl.Rectangle{view.x + 30, view.y + view.height + 18, view.width - 60, 4}
	knob_r := f32(8)
	frac := (app.av_zoom - 1) / (CROP_ZOOM_MAX - 1)
	knob := rl.Vector2{track.x + frac * track.width, track.y + track.height/2}
	hit := rl.Rectangle{track.x - knob_r, track.y - 10, track.width + knob_r*2, 24}
	if ui_click(&app.ui, hit, .Modal) {
		app.av_slider_drag = true
	}
	if app.av_slider_drag {
		if !app.ui.mouse_down {
			app.av_slider_drag = false
		} else {
			f := clamp((app.ui.mouse.x - track.x) / track.width, 0, 1)
			crop_set_zoom(app, 1 + f * (CROP_ZOOM_MAX - 1))
		}
	}
	if ui_hover(&app.ui, hit, .Modal) {
		app.ui.cursor = .POINTING_HAND
	}
	rrect(track, 2, fade(COL_OVERLAY, 0.15))
	rrect({track.x, track.y, frac * track.width, track.height}, 2, COL_ACCENT)
	rl.DrawCircleV(knob, knob_r, COL_SURFACE)
	rl.DrawCircleLinesV(knob, knob_r, COL_BORDER)
	draw_text_centered(app.fonts.regular13, "Ziehen zum Verschieben · Mausrad oder Regler zum Zoomen",
		p.x + p.width/2, track.y + 22, 13, COL_TEXT_FAINT)

	// --- Buttons ---
	by := p.y + h - 56
	if button(app, {p.x + 24, by, 140, 38}, "Anderes Bild…", .Modal, style = .Ghost, id_salt = 0xA7A1) {
		avatar_pick_start()
	}
	if button(app, {p.x + p.width - 262, by, 112, 38}, "Abbrechen", .Modal, id_salt = 0xA7A2) {
		close_modal(app)
	}
	if button(app, {p.x + p.width - 136, by, 112, 38}, "Übernehmen", .Modal, style = .Primary, id_salt = 0xA7A3) {
		avatar_apply_crop(app, c)
	}
}

// Ausschnitt backen (AVATAR_BAKE_DIM²-PNG) und je nach Ziel hochladen oder
// ins Registrier-Formular legen.
@(private = "file")
avatar_apply_crop :: proc(app: ^App, c: ^Server_Conn) {
	s := crop_scale(app)
	iw := f32(app.av_img.width)
	ih := f32(app.av_img.height)
	side := CROP_CIRCLE / s
	cx := iw/2 - app.av_pan.x/s
	cy := ih/2 - app.av_pan.y/s
	rect := rl.Rectangle{
		clamp(cx - side/2, 0, iw - side),
		clamp(cy - side/2, 0, ih - side),
		side, side,
	}

	sub := rl.ImageFromImage(app.av_img, rect)
	rl.ImageResize(&sub, shared.AVATAR_BAKE_DIM, shared.AVATAR_BAKE_DIM)
	size: i32
	raw := rl.ExportImageToMemory(sub, ".png", &size)
	rl.UnloadImage(sub)
	if raw == nil || size <= 0 {
		toast(app, .Error, "Bild konnte nicht kodiert werden")
		return
	}
	png := make([]byte, int(size))
	copy(png, ([^]u8)(raw)[:int(size)])
	rl.MemFree(raw)

	if int(size) > shared.AVATAR_MAX_BYTES {
		// Praktisch nur mit konstruiertem Rauschen erreichbar
		delete(png)
		toast(app, .Error, "Bild lässt sich nicht klein genug komprimieren")
		return
	}

	if app.av_to_auth {
		if c != nil {
			delete(c.auth_avatar_png)
			c.auth_avatar_png = png
			if c.auth_av_ok {
				rl.UnloadTexture(c.auth_av_tex)
				c.auth_av_ok = false
			}
			if tex, ok := avatar_png_texture(png); ok {
				c.auth_av_tex = tex
				c.auth_av_ok = true
			}
		} else {
			delete(png)
		}
	} else if c != nil {
		avatar_upload(app, c, png)
	} else {
		delete(png)
	}
	close_modal(app)
}

// ---------- Bausteine für Einstellungen & Registrierung ----------

// Profil-Bereich im Einstellungs-Dialog. Gibt die belegte Höhe zurück.
draw_settings_profile :: proc(app: ^App, c: ^Server_Conn, x, y, w: f32) -> f32 {
	draw_text(app.fonts.bold13, "PROFIL", {x, y}, 13, 0, COL_TEXT_FAINT)
	if c == nil || conn_phase(c) != .Ready {
		draw_text(app.fonts.regular13, "Nicht verbunden — Profilbild ist pro Server einstellbar.",
			{x, y + 24}, 13, 0, COL_TEXT_FAINT)
		return 56
	}
	label := fmt.tprintf("· %s", conn_label(c))
	draw_text(app.fonts.regular13, tcstr(label), {x + 54, y}, 13, 0, COL_TEXT_FAINT)
	y := y + 24

	draw_avatar(app, c.me.username, x, y, 56, c = c, uid = c.me.id)

	bx := x + 72
	has := c.me.avatar > 0
	busy := app.av_uploading || avatar_pick_active()
	pick_label := has ? "Bild ändern…" : "Bild wählen…"
	if app.av_uploading {
		pick_label = "Wird hochgeladen…"
	} else if avatar_pick_active() {
		pick_label = "Dialog offen…"
	}
	if button(app, {bx, y + 10, 150, 34}, pick_label, .Modal, id_salt = 0xA7B1) && !busy {
		avatar_begin_pick(app, false, true)
	}
	if has {
		if button(app, {bx + 162, y + 10, 110, 34}, "Entfernen", .Modal, style = .Danger, id_salt = 0xA7B2) && !busy {
			conn_request(c, {kind = shared.K_AVATAR_DELETE})
		}
	}
	draw_text(app.fonts.regular13,
		tcstr(trim_label(app, app.fonts.regular13, 13, "Für alle auf diesem Server sichtbar. Auch per Drag & Drop ins Fenster.", w)),
		{x, y + 62}, 13, 0, COL_TEXT_FAINT)
	return 24 + 84
}

// Profilbild-Zeile im Registrier-Formular. Gibt die belegte Höhe zurück.
draw_auth_avatar_row :: proc(app: ^App, c: ^Server_Conn, x, y, w: f32) -> f32 {
	draw_text(app.fonts.regular13, "Profilbild (optional)", {x, y}, 13, 0, COL_TEXT_DIM)
	ry := y + 20
	av := f32(48)

	if c.auth_av_ok {
		src := rl.Rectangle{0, 0, f32(c.auth_av_tex.width), f32(c.auth_av_tex.height)}
		rl.DrawTexturePro(c.auth_av_tex, src, {x, ry, av, av}, {0, 0}, 0, rl.WHITE)
		rl.DrawRing({x + av/2, ry + av/2}, av/2 - 1, av/2, 0, 360, 36, fade(COL_OVERLAY, 0.10))
	} else {
		// leerer Platzhalter: gestrichelter Kreis + Plus
		cx := x + av/2
		cy := ry + av/2
		segs := 12
		for i in 0 ..< segs {
			a0 := f32(i) * 360 / f32(segs)
			rl.DrawRing({cx, cy}, av/2 - 1.2, av/2, a0, a0 + 360/f32(segs)*0.6, 8, COL_BORDER)
		}
		draw_plus(cx, cy, 7, 2, COL_TEXT_FAINT)
	}

	busy := avatar_pick_active()
	bx := x + av + 16
	if button(app, {bx, ry + 7, 110, 34}, c.auth_av_ok ? "Ändern…" : "Wählen…", .Base, id_salt = 0xA7C1) && !busy {
		avatar_begin_pick(app, true, false)
	}
	if c.auth_av_ok {
		if button(app, {bx + 122, ry + 7, 110, 34}, "Entfernen", .Base, style = .Ghost, id_salt = 0xA7C2) {
			delete(c.auth_avatar_png)
			c.auth_avatar_png = nil
			rl.UnloadTexture(c.auth_av_tex)
			c.auth_av_ok = false
		}
	} else {
		draw_text(app.fonts.regular13, "oder Bild ins Fenster ziehen", {bx + 122, ry + 17}, 13, 0, COL_TEXT_FAINT)
	}
	return 20 + av + 12
}

// Upload anstoßen; die Antwort verarbeitet app_apply_reply (K_AVATAR_SET).
avatar_upload :: proc(app: ^App, c: ^Server_Conn, png: []byte) {
	if conn_phase(c) != .Ready {
		delete(png)
		toast(app, .Error, "Nicht verbunden — Profilbild bitte später erneut setzen")
		return
	}
	delete(c.av_upload_png)
	c.av_upload_png = png
	seq := conn_request(c, {kind = shared.K_AVATAR_SET,
		data = base64.encode(png, base64.ENC_TABLE, context.temp_allocator)})
	if seq == 0 {
		// Senden fehlgeschlagen — Reconnect räumt den Rest auf
		delete(c.av_upload_png)
		c.av_upload_png = nil
		toast(app, .Error, "Nicht verbunden — Profilbild bitte später erneut setzen")
		return
	}
	app.av_uploading = true
}

// Registrierung erfolgreich → gemerktes Formular-Bild jetzt hochladen.
avatar_send_pending_auth :: proc(app: ^App, c: ^Server_Conn) {
	if len(c.auth_avatar_png) == 0 {
		return
	}
	png := c.auth_avatar_png
	c.auth_avatar_png = nil
	if c.auth_av_ok {
		rl.UnloadTexture(c.auth_av_tex)
		c.auth_av_ok = false
	}
	avatar_upload(app, c, png)
}
