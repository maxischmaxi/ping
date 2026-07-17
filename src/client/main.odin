package main

// Einstiegspunkt: Fenster, Main-Loop (Netzwerk pollen → UI zeichnen).

import "core:fmt"
import "core:os"

import rl "vendor:raylib"

import shared "../shared"

main :: proc() {
	for arg in os.args[1:] {
		if arg == "-version" || arg == "--version" {
			fmt.printfln("flurfunk %s", shared.VERSION)
			return
		}
	}

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT})
	rl.InitWindow(1360, 850, "Flurfunk")
	defer rl.CloseWindow()
	rl.SetWindowMinSize(960, 600)

	// Window icon (Linux/Windows; macOS uses the bundle icon instead).
	icon_png := #load("../../assets/icon/png/flurfunk-256.png")
	icon := rl.LoadImageFromMemory(".png", raw_data(icon_png), i32(len(icon_png)))
	if icon.data != nil {
		rl.ImageFormat(&icon, .UNCOMPRESSED_R8G8B8A8)
		rl.SetWindowIcon(icon)
		rl.UnloadImage(icon)
	}
	rl.SetTargetFPS(240) // Obergrenze; VSync taktet real
	rl.SetExitKey(.KEY_NULL)

	app: App
	app_init(&app)
	defer sys_theme_stop()

	title_unread := -1

	for !rl.WindowShouldClose() {
		app.dt = min(rl.GetFrameTime(), 1.0/20.0) // Ruckler nicht überspringen lassen
		app_poll(&app)
		theme_frame(&app) // Farben für diesen Frame festlegen (vor ClearBackground)

		// Fenstertitel mit Unread-Zähler
		unread := app_total_unread(&app)
		if unread != title_unread {
			title_unread = unread
			if unread > 0 {
				rl.SetWindowTitle(fmt.ctprintf("(%d) Flurfunk", unread))
			} else {
				rl.SetWindowTitle("Flurfunk")
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground(COL_CHAT_BG)
		// UI-Zoom: Geometrie über die Kamera skalieren; die Fonts sind in
		// physischer Größe geladen → Text bleibt 1:1 scharf.
		// Der Kamera-Offset schiebt die gesamte UI unter die Call-Leiste —
		// die Leiste selbst zeichnet bei negativen y-Koordinaten.
		app.bar_h = call_bar_height(&app)
		g_off_y = app.bar_h
		rl.BeginMode2D(rl.Camera2D{zoom = g_scale, offset = {0, app.bar_h * g_scale}})
		ui_draw(&app)
		rl.EndMode2D()
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}
