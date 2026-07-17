package test_tray

// Headless-Test für die Desktop-Integration (Linux): fährt einen Mock-
// StatusNotifierWatcher und einen Mock-Notification-Daemon auf einem
// isolierten Session-Bus hoch und prüft den kompletten Tray-Stack
// End-to-End (Registrierung, Properties, Activate, Menü, Notifications,
// Klick-Routing, Watcher-Neustart).
//
// Nutzung:  dbus-run-session -- bin/traytest   (mit `timeout` begrenzen)

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

import desk "../../src/desktop"
import dbus "../../src/desktop/dbus1"

step_no := 0

expect :: proc(ok: bool, what: string, args: ..any) {
	if !ok {
		fmt.eprintf("FEHLGESCHLAGEN: %s ", what)
		fmt.eprintln(..args)
		os.exit(1)
	}
	step_no += 1
	fmt.printfln("ok %2d  %s", step_no, what)
}

// --- Mock: StatusNotifierWatcher -------------------------------------------

Watcher :: struct {
	conn:       ^dbus.Connection,
	registered: [dynamic]string,
	new_icons:  int, // empfangene NewIcon-Signale (braucht Match-Rule)
}

watcher_filter :: proc "c" (conn: ^dbus.Connection, msg: ^dbus.Message, ud: rawptr) -> i32 {
	context = runtime.default_context()
	w := (^Watcher)(ud)
	kind := dbus.api.dbus_message_get_type(msg)
	member := msg_member(msg)
	if kind == dbus.TYPE_SIGNAL && member == "NewIcon" {
		w.new_icons += 1
		return dbus.HANDLED
	}
	if kind == dbus.TYPE_METHOD_CALL && member == "RegisterStatusNotifierItem" {
		it: dbus.Iter
		name := ""
		if dbus.api.dbus_message_iter_init(msg, &it) {
			name = strings.clone(dbus.get_string(&it))
		}
		append(&w.registered, name)
		reply := dbus.api.dbus_message_new_method_return(msg)
		dbus.api.dbus_connection_send(conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
		return dbus.HANDLED
	}
	return dbus.NOT_YET_HANDLED
}

make_watcher :: proc(w: ^Watcher, with_sni_match: bool) {
	w.conn = dbus.api.dbus_bus_get_private(dbus.BUS_SESSION, nil)
	expect(w.conn != nil, "Mock-Watcher: Session-Bus-Verbindung")
	dbus.api.dbus_connection_set_exit_on_disconnect(w.conn, false)
	dbus.api.dbus_connection_add_filter(w.conn, watcher_filter, w, nil)
	if with_sni_match {
		dbus.api.dbus_bus_add_match(w.conn,
			"type='signal',interface='org.kde.StatusNotifierItem'", nil)
	}
	r := dbus.api.dbus_bus_request_name(w.conn, "org.kde.StatusNotifierWatcher",
		dbus.NAME_FLAG_DO_NOT_QUEUE, nil)
	expect(r == dbus.REQUEST_NAME_REPLY_PRIMARY_OWNER, "Mock-Watcher: Name übernommen")
	dbus.api.dbus_connection_flush(w.conn)
}

// --- Mock: Notification-Daemon ----------------------------------------------

Notifd :: struct {
	conn:          ^dbus.Connection,
	count:         int,
	next_id:       u32,
	last_id:       u32,
	last_app:      string,
	last_summary:  string,
	last_body:     string,
	last_replaces: u32,
	has_default:   bool,
	has_image:     bool,
}

notifd_filter :: proc "c" (conn: ^dbus.Connection, msg: ^dbus.Message, ud: rawptr) -> i32 {
	context = runtime.default_context()
	nd := (^Notifd)(ud)
	if dbus.api.dbus_message_get_type(msg) != dbus.TYPE_METHOD_CALL ||
	   msg_member(msg) != "Notify" {
		return dbus.NOT_YET_HANDLED
	}

	it: dbus.Iter
	if dbus.api.dbus_message_iter_init(msg, &it) {
		nd.last_app = strings.clone(dbus.get_string(&it))
		dbus.api.dbus_message_iter_next(&it)
		nd.last_replaces = dbus.get_u32(&it)
		dbus.api.dbus_message_iter_next(&it) // app_icon
		dbus.api.dbus_message_iter_next(&it)
		nd.last_summary = strings.clone(dbus.get_string(&it))
		dbus.api.dbus_message_iter_next(&it)
		nd.last_body = strings.clone(dbus.get_string(&it))
		dbus.api.dbus_message_iter_next(&it)
		// actions: as
		nd.has_default = false
		if dbus.api.dbus_message_iter_get_arg_type(&it) == dbus.T_ARRAY {
			sub: dbus.Iter
			dbus.api.dbus_message_iter_recurse(&it, &sub)
			for dbus.api.dbus_message_iter_get_arg_type(&sub) == dbus.T_STRING {
				if dbus.get_string(&sub) == "default" {
					nd.has_default = true
				}
				dbus.api.dbus_message_iter_next(&sub)
			}
		}
		dbus.api.dbus_message_iter_next(&it)
		// hints: a{sv}
		nd.has_image = false
		if dbus.api.dbus_message_iter_get_arg_type(&it) == dbus.T_ARRAY {
			sub: dbus.Iter
			dbus.api.dbus_message_iter_recurse(&it, &sub)
			for dbus.api.dbus_message_iter_get_arg_type(&sub) == dbus.T_DICT_ENTRY {
				e: dbus.Iter
				dbus.api.dbus_message_iter_recurse(&sub, &e)
				if dbus.get_string(&e) == "image-data" {
					nd.has_image = true
				}
				dbus.api.dbus_message_iter_next(&sub)
			}
		}
	}

	nd.last_id = nd.next_id
	nd.next_id += 1
	nd.count += 1
	reply := dbus.api.dbus_message_new_method_return(msg)
	rit: dbus.Iter
	dbus.api.dbus_message_iter_init_append(reply, &rit)
	dbus.append_u32(&rit, nd.last_id)
	dbus.api.dbus_connection_send(conn, reply, nil)
	dbus.api.dbus_message_unref(reply)
	return dbus.HANDLED
}

// --- Pump-/Warte-Helfer ------------------------------------------------------

TW: Watcher  // erster Watcher
TW2: Watcher // Watcher nach „Neustart"
TN: Notifd

G: struct {
	toggle, show, quit: int,
	tags:               [dynamic]u64,
}

msg_member :: proc(msg: ^dbus.Message) -> string {
	m := dbus.api.dbus_message_get_member(msg)
	return m == nil ? "" : string(m)
}

pump_all :: proc() {
	if TW.conn != nil {
		dbus.pump(TW.conn)
	}
	if TW2.conn != nil {
		dbus.pump(TW2.conn)
	}
	if TN.conn != nil {
		dbus.pump(TN.conn)
	}
	ev := desk.tray_poll()
	if ev.toggle {
		G.toggle += 1
	}
	if ev.show {
		G.show += 1
	}
	if ev.quit {
		G.quit += 1
	}
	for t in ev.notif_tags[:ev.notif_n] {
		append(&G.tags, t)
	}
}

// Pumpt bis zu ~3 s; der Aufrufer prüft seine Bedingung selbst in der Schleife.
SPIN_ROUNDS :: 1500

tick :: proc() {
	pump_all()
	time.sleep(2 * time.Millisecond)
}

call_sync :: proc(conn: ^dbus.Connection, msg: ^dbus.Message) -> ^dbus.Message {
	pc: ^dbus.Pending_Call
	dbus.api.dbus_connection_send_with_reply(conn, msg, &pc, 3000)
	dbus.api.dbus_message_unref(msg)
	if pc == nil {
		return nil
	}
	for _ in 0 ..< SPIN_ROUNDS {
		if dbus.api.dbus_pending_call_get_completed(pc) {
			break
		}
		tick()
	}
	if !dbus.api.dbus_pending_call_get_completed(pc) {
		dbus.api.dbus_pending_call_unref(pc)
		return nil
	}
	reply := dbus.api.dbus_pending_call_steal_reply(pc)
	dbus.api.dbus_pending_call_unref(pc)
	return reply
}

msg_sig :: proc(msg: ^dbus.Message) -> string {
	s := dbus.api.dbus_message_get_signature(msg)
	return s == nil ? "" : string(s)
}

// --- Hauptablauf -------------------------------------------------------------

main :: proc() {
	expect(dbus.load(), "libdbus laden")

	make_watcher(&TW, false)
	TN.conn = dbus.api.dbus_bus_get_private(dbus.BUS_SESSION, nil)
	expect(TN.conn != nil, "Mock-Notifd: Session-Bus-Verbindung")
	dbus.api.dbus_connection_set_exit_on_disconnect(TN.conn, false)
	dbus.api.dbus_connection_add_filter(TN.conn, notifd_filter, &TN, nil)
	TN.next_id = 7
	r := dbus.api.dbus_bus_request_name(TN.conn, "org.freedesktop.Notifications",
		dbus.NAME_FLAG_DO_NOT_QUEUE, nil)
	expect(r == dbus.REQUEST_NAME_REPLY_PRIMARY_OWNER, "Mock-Notifd: Name übernommen")

	// --- Tray initialisieren ---
	icons := make([]desk.Tray_Icon, 2)
	icons[0] = mk_icon(4)
	icons[1] = mk_icon(8)
	spec := desk.Tray_Spec {
		title        = "Flurfunk",
		icons        = icons,
		icons_unread = icons,
	}
	expect(desk.tray_init(spec), "tray_init")

	for _ in 0 ..< SPIN_ROUNDS {
		if len(TW.registered) > 0 && desk.tray_available() {
			break
		}
		tick()
	}
	expect(len(TW.registered) == 1, "Watcher erhält genau eine Registrierung")
	expect(desk.tray_available(), "tray_available nach Registrierung")
	want_name := fmt.tprintf("org.kde.StatusNotifierItem-%d-1", linux.getpid())
	expect(TW.registered[0] == want_name, "Registrierter Name", TW.registered[0])

	item := strings.clone_to_cstring(want_name)

	// --- Properties: GetAll ---
	{
		msg := dbus.api.dbus_message_new_method_call(item, "/StatusNotifierItem",
			"org.freedesktop.DBus.Properties", "GetAll")
		it: dbus.Iter
		dbus.api.dbus_message_iter_init_append(msg, &it)
		dbus.append_string(&it, "org.kde.StatusNotifierItem")
		reply := call_sync(TW.conn, msg)
		expect(reply != nil, "GetAll beantwortet")
		expect(dbus.api.dbus_message_get_type(reply) == dbus.TYPE_METHOD_RETURN,
			"GetAll ohne Fehler")
		expect(msg_sig(reply) == "a{sv}", "GetAll-Signatur", msg_sig(reply))

		title_ok, menu_ok, status_ok := false, false, false
		sizes: [dynamic]int
		rit, arr: dbus.Iter
		dbus.api.dbus_message_iter_init(reply, &rit)
		dbus.api.dbus_message_iter_recurse(&rit, &arr)
		for dbus.api.dbus_message_iter_get_arg_type(&arr) == dbus.T_DICT_ENTRY {
			e, v: dbus.Iter
			dbus.api.dbus_message_iter_recurse(&arr, &e)
			key := dbus.get_string(&e)
			dbus.api.dbus_message_iter_next(&e)
			dbus.api.dbus_message_iter_recurse(&e, &v)
			switch key {
			case "Title":
				title_ok = dbus.get_string(&v) == "Flurfunk"
			case "Menu":
				menu_ok = dbus.get_string(&v) == "/MenuBar"
			case "Status":
				status_ok = dbus.get_string(&v) == "Active"
			case "IconPixmap":
				pa: dbus.Iter
				dbus.api.dbus_message_iter_recurse(&v, &pa)
				for dbus.api.dbus_message_iter_get_arg_type(&pa) == dbus.T_STRUCT {
					st: dbus.Iter
					dbus.api.dbus_message_iter_recurse(&pa, &st)
					append(&sizes, int(dbus.get_i32(&st)))
					dbus.api.dbus_message_iter_next(&pa)
				}
			}
			dbus.api.dbus_message_iter_next(&arr)
		}
		expect(title_ok, "Property Title")
		expect(menu_ok, "Property Menu")
		expect(status_ok, "Property Status")
		expect(len(sizes) == 2 && sizes[0] == 4 && sizes[1] == 8,
			"IconPixmap-Größen", sizes)
		dbus.api.dbus_message_unref(reply)
	}

	// --- Activate → Toggle-Event ---
	{
		msg := dbus.api.dbus_message_new_method_call(item, "/StatusNotifierItem",
			"org.kde.StatusNotifierItem", "Activate")
		it: dbus.Iter
		dbus.api.dbus_message_iter_init_append(msg, &it)
		dbus.append_i32(&it, 0)
		dbus.append_i32(&it, 0)
		reply := call_sync(TW.conn, msg)
		expect(reply != nil, "Activate beantwortet")
		dbus.api.dbus_message_unref(reply)
		for _ in 0 ..< SPIN_ROUNDS {
			if G.toggle > 0 {
				break
			}
			tick()
		}
		expect(G.toggle == 1, "Activate löst Toggle-Event aus")
	}

	// --- Menü: GetLayout ---
	{
		msg := dbus.api.dbus_message_new_method_call(item, "/MenuBar",
			"com.canonical.dbusmenu", "GetLayout")
		it, arr: dbus.Iter
		dbus.api.dbus_message_iter_init_append(msg, &it)
		dbus.append_i32(&it, 0)
		dbus.append_i32(&it, -1)
		dbus.api.dbus_message_iter_open_container(&it, dbus.T_ARRAY, "s", &arr)
		dbus.api.dbus_message_iter_close_container(&it, &arr)
		reply := call_sync(TW.conn, msg)
		expect(reply != nil, "GetLayout beantwortet")
		expect(msg_sig(reply) == "u(ia{sv}av)", "GetLayout-Signatur", msg_sig(reply))

		children := 0
		rit, st, props, ch: dbus.Iter
		dbus.api.dbus_message_iter_init(reply, &rit)
		dbus.api.dbus_message_iter_next(&rit) // revision
		dbus.api.dbus_message_iter_recurse(&rit, &st)
		dbus.api.dbus_message_iter_next(&st) // id
		dbus.api.dbus_message_iter_recurse(&st, &props)
		dbus.api.dbus_message_iter_next(&st) // props
		dbus.api.dbus_message_iter_recurse(&st, &ch)
		for dbus.api.dbus_message_iter_get_arg_type(&ch) == dbus.T_VARIANT {
			children += 1
			dbus.api.dbus_message_iter_next(&ch)
		}
		expect(children == 3, "Menü hat 3 Einträge (Öffnen/Trenner/Beenden)", children)
		dbus.api.dbus_message_unref(reply)
	}

	// --- Menü-Events: Öffnen + Beenden ---
	{
		send_menu_event :: proc(item: cstring, id: i32) {
			msg := dbus.api.dbus_message_new_method_call(item, "/MenuBar",
				"com.canonical.dbusmenu", "Event")
			it, v: dbus.Iter
			dbus.api.dbus_message_iter_init_append(msg, &it)
			dbus.append_i32(&it, id)
			dbus.append_string(&it, "clicked")
			dbus.api.dbus_message_iter_open_container(&it, dbus.T_VARIANT, "s", &v)
			dbus.append_string(&v, "")
			dbus.api.dbus_message_iter_close_container(&it, &v)
			dbus.append_u32(&it, 0)
			reply := call_sync(TW.conn, msg)
			if reply != nil {
				dbus.api.dbus_message_unref(reply)
			}
		}
		send_menu_event(item, 1)
		for _ in 0 ..< SPIN_ROUNDS {
			if G.show > 0 {
				break
			}
			tick()
		}
		expect(G.show == 1, "Menü „Öffnen“ löst Show-Event aus")
		send_menu_event(item, 3)
		for _ in 0 ..< SPIN_ROUNDS {
			if G.quit > 0 {
				break
			}
			tick()
		}
		expect(G.quit == 1, "Menü „Beenden“ löst Quit-Event aus")
	}

	// --- Notifications ---
	{
		expect(desk.notify(99, "Titel", "Text der Nachricht", .Message), "notify() sendet")
		for _ in 0 ..< SPIN_ROUNDS {
			if TN.count > 0 {
				break
			}
			tick()
		}
		expect(TN.count == 1, "Notifd erhält Notify")
		expect(TN.last_app == "Flurfunk", "Notify app_name", TN.last_app)
		expect(TN.last_summary == "Titel", "Notify summary", TN.last_summary)
		expect(TN.last_body == "Text der Nachricht", "Notify body", TN.last_body)
		expect(TN.last_replaces == 0, "Erste Notification ersetzt nichts")
		expect(TN.has_default, "Default-Action vorhanden")
		expect(TN.has_image, "image-data-Hint vorhanden")

		// Die id-Zuordnung (Reply) muss verarbeitet sein, bevor der Klick kommt
		for _ in 0 ..< 50 {
			tick()
		}

		// Klick auf die Notification → ActionInvoked
		sig := dbus.api.dbus_message_new_signal("/org/freedesktop/Notifications",
			"org.freedesktop.Notifications", "ActionInvoked")
		it: dbus.Iter
		dbus.api.dbus_message_iter_init_append(sig, &it)
		dbus.append_u32(&it, TN.last_id)
		dbus.append_string(&it, "default")
		dbus.api.dbus_connection_send(TN.conn, sig, nil)
		dbus.api.dbus_message_unref(sig)
		dbus.api.dbus_connection_flush(TN.conn)

		for _ in 0 ..< SPIN_ROUNDS {
			if len(G.tags) > 0 {
				break
			}
			tick()
		}
		expect(len(G.tags) == 1 && G.tags[0] == 99, "Klick liefert Tag 99 zurück", G.tags)
		expect(G.show == 2, "Klick löst Show-Event aus")

		// Gleicher Tag erneut → ersetzt die sichtbare Notification
		expect(desk.notify(99, "Titel 2", "x", .Message), "notify() erneut")
		for _ in 0 ..< SPIN_ROUNDS {
			if TN.count > 1 {
				break
			}
			tick()
		}
		expect(TN.count == 2, "Notifd erhält zweites Notify")
		expect(TN.last_replaces == 7, "Zweites Notify ersetzt die erste (replaces_id)",
			TN.last_replaces)
	}

	// --- Watcher-Neustart → automatische Re-Registrierung ---
	{
		dbus.api.dbus_connection_close(TW.conn)
		dbus.api.dbus_connection_unref(TW.conn)
		TW.conn = nil
		for _ in 0 ..< 100 {
			tick()
		}
		make_watcher(&TW2, true)
		for _ in 0 ..< SPIN_ROUNDS {
			if len(TW2.registered) > 0 && desk.tray_available() {
				break
			}
			tick()
		}
		expect(len(TW2.registered) == 1, "Re-Registrierung nach Watcher-Neustart")
		expect(desk.tray_available(), "tray_available nach Neustart")

		// Unread-Wechsel → NewIcon-Signal
		desk.tray_set_unread(true)
		for _ in 0 ..< SPIN_ROUNDS {
			if TW2.new_icons > 0 {
				break
			}
			tick()
		}
		expect(TW2.new_icons == 1, "tray_set_unread sendet NewIcon")
		desk.tray_set_unread(true) // unverändert → kein weiteres Signal
		for _ in 0 ..< 50 {
			tick()
		}
		expect(TW2.new_icons == 1, "Unveränderter Zustand sendet kein NewIcon")
	}

	desk.tray_shutdown()
	fmt.printfln("\nTRAY-TEST OK — %d Schritte grün", step_no)
}

mk_icon :: proc(w: int) -> desk.Tray_Icon {
	px := make([]u8, w*w*4)
	for i in 0 ..< w*w {
		px[i*4+0] = 238
		px[i*4+1] = 42
		px[i*4+2] = 155
		px[i*4+3] = 255
	}
	return {w, w, px}
}
