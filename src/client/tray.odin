package main

// Systemtray + Close-to-Tray. Die Plattform-Backends liegen in src/desktop
// (SNI/D-Bus auf Linux, NSStatusItem auf macOS, Shell_NotifyIcon auf
// Windows); hier passiert nur das Zusammenspiel mit raylib: Icon-Varianten
// bauen, Tray-Events anwenden, Fenster zeigen/verstecken.

import rl "vendor:raylib"

import desk "../desktop"

TARGET_FPS :: 240 // Obergrenze; VSync taktet real
HIDDEN_FPS :: 10  // Netzwerk-/Event-Takt, solange das Fenster versteckt ist

app_tray_init :: proc(app: ^App) {
	png32 := #load("../../assets/icon/png/flurfunk-32.png")
	png64 := #load("../../assets/icon/png/flurfunk-64.png")

	img32 := rl.LoadImageFromMemory(".png", raw_data(png32), i32(len(png32)))
	img64 := rl.LoadImageFromMemory(".png", raw_data(png64), i32(len(png64)))
	if img32.data == nil || img64.data == nil {
		return
	}
	defer rl.UnloadImage(img32)
	defer rl.UnloadImage(img64)
	rl.ImageFormat(&img32, .UNCOMPRESSED_R8G8B8A8)
	rl.ImageFormat(&img64, .UNCOMPRESSED_R8G8B8A8)

	dot32 := rl.ImageCopy(img32)
	dot64 := rl.ImageCopy(img64)
	defer rl.UnloadImage(dot32)
	defer rl.UnloadImage(dot64)
	draw_unread_dot(&dot32)
	draw_unread_dot(&dot64)

	// macOS-Menüleiste bekommt PNG-Bytes (64 px, angezeigt mit 18 pt → Retina)
	png_unread_n: i32
	png_unread := rl.ExportImageToMemory(dot64, ".png", &png_unread_n)
	defer if png_unread != nil {
		rl.MemFree(png_unread)
	}

	// Die Backends kopieren alles, was sie behalten — temp reicht hier.
	spec := desk.Tray_Spec {
		title        = "Flurfunk",
		icons        = tmp_icons(img32, img64),
		icons_unread = tmp_icons(dot32, dot64),
		png          = png64,
		png_unread   = png_unread == nil ? png64 : (cast([^]u8)png_unread)[:png_unread_n],
	}
	desk.tray_init(spec)
}

app_tray_shutdown :: proc() {
	desk.tray_shutdown()
}

app_tray_available :: proc() -> bool {
	return desk.tray_available()
}

@(private = "file")
tmp_icons :: proc(imgs: ..rl.Image) -> []desk.Tray_Icon {
	out := make([]desk.Tray_Icon, len(imgs), context.temp_allocator)
	for img, i in imgs {
		n := int(img.width) * int(img.height) * 4
		out[i] = {int(img.width), int(img.height), (cast([^]u8)img.data)[:n]}
	}
	return out
}

// Roter Unread-Punkt unten rechts (mit hellem Rand zur Icon-Fläche).
@(private = "file")
draw_unread_dot :: proc(img: ^rl.Image) {
	w := int(img.width)
	r := max(w / 5, 4)
	c := i32(w - r - 1)
	rl.ImageDrawCircle(img, c, c, i32(r + 2), {255, 255, 255, 255})
	rl.ImageDrawCircle(img, c, c, i32(r), {240, 68, 56, 255})
}

// Pro Frame: Tray-Events anwenden + Unread-Punkt nachführen.
app_tray_tick :: proc(app: ^App) {
	ev := desk.tray_poll()
	if ev.quit {
		app.want_quit = true
	}
	if ev.toggle {
		// Klick aufs Tray-Icon: verstecken ↔ zeigen (wie Slack)
		if app.hidden {
			app_show_window(app)
		} else if rl.IsWindowFocused() {
			app_hide_window(app)
		} else {
			rl.SetWindowFocused()
		}
	}
	if ev.show {
		app_show_window(app)
	}
	for tag in ev.notif_tags[:ev.notif_n] {
		app_notif_clicked(app, tag)
	}
	desk.tray_set_unread(app_total_unread(app) > 0)
}

app_show_window :: proc(app: ^App) {
	if app.hidden {
		app.hidden = false
		rl.ClearWindowState({.WINDOW_HIDDEN})
		rl.SetTargetFPS(TARGET_FPS)
	}
	rl.SetWindowFocused()
}

app_hide_window :: proc(app: ^App) {
	if app.hidden {
		return
	}
	app.hidden = true
	rl.SetWindowState({.WINDOW_HIDDEN})
	rl.SetTargetFPS(HIDDEN_FPS)
}

// X wurde geklickt: verstecken (Default) oder wirklich beenden (Setting
// bzw. wenn es gar keinen Tray gibt — sonst wäre die App unerreichbar).
app_handle_close :: proc(app: ^App) {
	quit := app.cfg.quit_on_close || !desk.tray_available()
	when ODIN_OS == .Darwin {
		// Cmd+Q soll wie überall auf dem Mac wirklich beenden — GLFW meldet
		// es nur als Fenster-Schließen, daher die Modifier-Abfrage.
		if rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) {
			quit = true
		}
	}
	if quit {
		app.want_quit = true
	} else {
		app_hide_window(app)
	}
}
