package main

// Nativer Datei-Dialog fürs Profilbild. raylib hat keinen — wir fragen die
// Bordmittel des Desktops (zenity/kdialog auf Linux, osascript auf macOS)
// in einem Hintergrund-Thread ab; der Main-Thread pollt das Ergebnis.
// Drag & Drop ins Fenster funktioniert unabhängig davon immer.

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

@(private = "file")
g_pick: struct {
	mu:     sync.Mutex,
	active: bool,
	done:   bool,
	path:   string, // heap-alloziert; "" = abgebrochen
}

avatar_pick_active :: proc() -> bool {
	sync.lock(&g_pick.mu)
	defer sync.unlock(&g_pick.mu)
	return g_pick.active
}

// Dialog starten (no-op, wenn schon einer offen ist).
avatar_pick_start :: proc() {
	sync.lock(&g_pick.mu)
	if g_pick.active {
		sync.unlock(&g_pick.mu)
		return
	}
	g_pick.active = true
	g_pick.done = false
	sync.unlock(&g_pick.mu)
	thread.run(pick_thread)
}

// Main-Thread: fertiges Ergebnis abholen. ok=true genau einmal pro Dialog;
// path == "" heißt abgebrochen. Der Aufrufer besitzt den String.
avatar_pick_poll :: proc() -> (path: string, ok: bool) {
	sync.lock(&g_pick.mu)
	defer sync.unlock(&g_pick.mu)
	if !g_pick.done {
		return
	}
	g_pick.done = false
	g_pick.active = false
	return g_pick.path, true
}

@(private = "file")
pick_finish :: proc(path: string) {
	sync.lock(&g_pick.mu)
	g_pick.path = path
	g_pick.done = true
	sync.unlock(&g_pick.mu)
}

@(private = "file")
run_dialog :: proc(cmd: []string) -> (out: string, ok: bool) {
	state, sout, _, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		return "", false
	}
	return strings.trim_space(string(sout)), true
}

@(private = "file")
pick_thread :: proc() {
	defer free_all(context.temp_allocator)

	when ODIN_OS == .Darwin {
		if out, ok := run_dialog({
			"osascript", "-e",
			`POSIX path of (choose file of type {"public.image"} with prompt "Profilbild wählen")`,
		}); ok && out != "" {
			pick_finish(strings.clone(out))
			return
		}
	} else {
		if out, ok := run_dialog({
			"zenity", "--file-selection", "--title=Profilbild wählen",
			"--file-filter=Bilder | *.png *.jpg *.jpeg *.bmp *.qoi",
		}); ok && out != "" {
			pick_finish(strings.clone(out))
			return
		}
		if out, ok := run_dialog({
			"kdialog", "--getopenfilename", ".", "image/png image/jpeg image/bmp",
		}); ok && out != "" {
			pick_finish(strings.clone(out))
			return
		}
	}
	pick_finish("")
}
