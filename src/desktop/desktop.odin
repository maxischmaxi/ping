package desktop

// Cross-platform desktop integration: system tray icon and desktop
// notifications. Platform backends live in tray_<os>.odin and implement:
//
//   tray_init(spec)   -> bool   — create the tray icon (main thread)
//   tray_available()  -> bool   — a tray host exists right now
//   tray_poll()       -> Events — pump backend, drain queued events
//   tray_set_unread(bool)       — swap between normal/unread icon
//   tray_shutdown()
//   notify(tag, title, body, kind) -> bool
//
// The package is deliberately raylib-free so headless tests can drive it.
// All calls must come from one thread (the app's main thread).

Tray_Icon :: struct {
	w, h: int,
	rgba: []u8, // 8-bit RGBA, w*h*4 bytes
}

Tray_Spec :: struct {
	title:        string,      // app name (tooltip / notification source)
	icons:        []Tray_Icon, // normal state, multiple sizes
	icons_unread: []Tray_Icon, // with unread marker, same sizes
	png:          []u8,        // encoded PNG (macOS menu bar)
	png_unread:   []u8,
}

Notify_Kind :: enum {
	Message,
	Call,
}

MAX_NOTIF_EVENTS :: 8

// Drained by tray_poll once per frame.
Events :: struct {
	toggle:     bool, // tray icon activated (click)
	show:       bool, // explicit request to show the window (menu/notification)
	quit:       bool,
	notif_tags: [MAX_NOTIF_EVENTS]u64, // clicked notifications (app-defined tags)
	notif_n:    int,
}

// Shared by the platform backends (single-threaded access).
@(private)
push_notif_event :: proc(ev: ^Events, tag: u64) {
	if ev.notif_n < MAX_NOTIF_EVENTS {
		ev.notif_tags[ev.notif_n] = tag
		ev.notif_n += 1
	}
	ev.show = true
}
