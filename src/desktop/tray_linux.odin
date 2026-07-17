#+build linux
package desktop

// Linux backend: StatusNotifierItem (tray) + com.canonical.dbusmenu (menu)
// + org.freedesktop.Notifications, all over the D-Bus session bus using the
// runtime-loaded libdbus (dbus1 package). Works on KDE/XFCE/waybar/… out of
// the box and on GNOME with the AppIndicator extension; without a watcher
// tray_available() stays false and the app falls back to quit-on-close.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/linux"

import dbus "dbus1"

@(private = "file") ITEM_PATH: cstring : "/StatusNotifierItem"
@(private = "file") MENU_PATH: cstring : "/MenuBar"
@(private = "file") SNI_IFACE: cstring : "org.kde.StatusNotifierItem"
@(private = "file") MENU_IFACE: cstring : "com.canonical.dbusmenu"
@(private = "file") PROPS_IFACE :: "org.freedesktop.DBus.Properties"
@(private = "file") WATCHER_NAME :: "org.kde.StatusNotifierWatcher"
@(private = "file") NOTIF_IFACE: cstring : "org.freedesktop.Notifications"

// Menu item ids (fixed, static menu)
@(private = "file") MENU_ROOT :: i32(0)
@(private = "file") MENU_OPEN :: i32(1)
@(private = "file") MENU_SEP :: i32(2)
@(private = "file") MENU_QUIT :: i32(3)

@(private = "file")
Notif_Pending :: struct {
	pc:  ^dbus.Pending_Call,
	tag: u64,
}

@(private = "file")
Argb_Icon :: struct {
	w, h: int,
	argb: []u8, // A,R,G,B byte order (network order, as SNI wants it)
}

@(private = "file")
L: struct {
	ok:              bool,
	conn:            ^dbus.Connection,
	item_name:       cstring, // org.kde.StatusNotifierItem-<pid>-1
	title:           cstring,
	open_label:      cstring, // "<Title> öffnen"
	registered:      bool,
	reg_pc:          ^dbus.Pending_Call,
	icons:           []Argb_Icon,
	icons_unread:    []Argb_Icon,
	notif_icon:      Tray_Icon, // RGBA copy for the image-data hint
	unread:          bool,
	ev:              Events,
	notif_id_by_tag: map[u64]u32,
	notif_tag_by_id: map[u32]u64,
	notif_pend:      [dynamic]Notif_Pending,
}

@(private = "file")
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

@(private = "file")
to_argb :: proc(icon: Tray_Icon) -> Argb_Icon {
	out := make([]u8, icon.w*icon.h*4)
	for i in 0 ..< icon.w*icon.h {
		out[i*4+0] = icon.rgba[i*4+3]
		out[i*4+1] = icon.rgba[i*4+0]
		out[i*4+2] = icon.rgba[i*4+1]
		out[i*4+3] = icon.rgba[i*4+2]
	}
	return {icon.w, icon.h, out}
}

tray_init :: proc(spec: Tray_Spec) -> bool {
	if L.ok {
		return true
	}
	if !dbus.load() {
		return false
	}
	L.conn = dbus.api.dbus_bus_get_private(dbus.BUS_SESSION, nil)
	if L.conn == nil {
		return false
	}
	dbus.api.dbus_connection_set_exit_on_disconnect(L.conn, false)

	title := spec.title != "" ? spec.title : "Flurfunk"
	L.title = strings.clone_to_cstring(title)
	L.open_label = strings.clone_to_cstring(fmt.tprintf("%s öffnen", title))
	pid := linux.getpid()
	L.item_name = strings.clone_to_cstring(fmt.tprintf("org.kde.StatusNotifierItem-%d-1", pid))

	L.icons = make([]Argb_Icon, len(spec.icons))
	for icon, i in spec.icons {
		L.icons[i] = to_argb(icon)
	}
	L.icons_unread = make([]Argb_Icon, len(spec.icons_unread))
	for icon, i in spec.icons_unread {
		L.icons_unread[i] = to_argb(icon)
	}
	// Largest icon <= 64 px for notifications (image-data hint).
	for icon in spec.icons {
		if icon.w <= 64 && icon.w > L.notif_icon.w {
			L.notif_icon = {icon.w, icon.h, make([]u8, len(icon.rgba))}
			copy(L.notif_icon.rgba, icon.rgba)
		}
	}

	// Own the well-known item name (per SNI spec); harmless if it fails —
	// registration falls back to whatever name we present.
	dbus.api.dbus_bus_request_name(L.conn, L.item_name, dbus.NAME_FLAG_DO_NOT_QUEUE, nil)

	dbus.api.dbus_connection_add_filter(L.conn, tray_filter, nil, nil)
	dbus.api.dbus_bus_add_match(L.conn,
		"type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'",
		nil)
	dbus.api.dbus_bus_add_match(L.conn,
		"type='signal',interface='org.freedesktop.Notifications',member='ActionInvoked'", nil)
	dbus.api.dbus_bus_add_match(L.conn,
		"type='signal',interface='org.freedesktop.Notifications',member='NotificationClosed'", nil)

	L.ok = true
	register_watcher()
	dbus.api.dbus_connection_flush(L.conn)
	return true
}

tray_available :: proc() -> bool {
	return L.ok && L.registered
}

tray_set_unread :: proc(unread: bool) {
	if !L.ok || L.unread == unread {
		return
	}
	L.unread = unread
	sig := dbus.api.dbus_message_new_signal(ITEM_PATH, SNI_IFACE, "NewIcon")
	if sig != nil {
		dbus.api.dbus_connection_send(L.conn, sig, nil)
		dbus.api.dbus_message_unref(sig)
		dbus.api.dbus_connection_flush(L.conn)
	}
}

tray_poll :: proc() -> Events {
	if !L.ok {
		return {}
	}
	if !dbus.pump(L.conn) {
		// Session bus died — no way back, degrade to "no tray".
		L.ok = false
		L.registered = false
		return {}
	}

	// Watcher registration finished?
	if L.reg_pc != nil && dbus.api.dbus_pending_call_get_completed(L.reg_pc) {
		reply := dbus.api.dbus_pending_call_steal_reply(L.reg_pc)
		if reply != nil {
			L.registered = dbus.api.dbus_message_get_type(reply) == dbus.TYPE_METHOD_RETURN
			dbus.api.dbus_message_unref(reply)
		}
		dbus.api.dbus_pending_call_unref(L.reg_pc)
		L.reg_pc = nil
	}

	// Notification ids arrived?
	for i := len(L.notif_pend) - 1; i >= 0; i -= 1 {
		p := L.notif_pend[i]
		if !dbus.api.dbus_pending_call_get_completed(p.pc) {
			continue
		}
		reply := dbus.api.dbus_pending_call_steal_reply(p.pc)
		if reply != nil {
			if dbus.api.dbus_message_get_type(reply) == dbus.TYPE_METHOD_RETURN {
				it: dbus.Iter
				if dbus.api.dbus_message_iter_init(reply, &it) {
					id := dbus.get_u32(&it)
					if id != 0 {
						// Old id of the same tag is replaced server-side.
						if old, has := L.notif_id_by_tag[p.tag]; has {
							delete_key(&L.notif_tag_by_id, old)
						}
						L.notif_id_by_tag[p.tag] = id
						L.notif_tag_by_id[id] = p.tag
					}
				}
			}
			dbus.api.dbus_message_unref(reply)
		}
		dbus.api.dbus_pending_call_unref(p.pc)
		unordered_remove(&L.notif_pend, i)
	}

	ev := L.ev
	L.ev = {}
	return ev
}

tray_shutdown :: proc() {
	if L.conn != nil {
		dbus.api.dbus_connection_flush(L.conn)
		dbus.api.dbus_connection_close(L.conn)
		dbus.api.dbus_connection_unref(L.conn)
		L.conn = nil
	}
	L.ok = false
	L.registered = false
}

// Fire-and-track: the reply carries the server-assigned id, which we need
// for click-routing (ActionInvoked) and coalescing (replaces_id per tag).
notify :: proc(tag: u64, title, body: string, kind: Notify_Kind) -> bool {
	if !L.ok {
		return false
	}
	msg := dbus.api.dbus_message_new_method_call(NOTIF_IFACE,
		"/org/freedesktop/Notifications", NOTIF_IFACE, "Notify")
	if msg == nil {
		return false
	}
	it: dbus.Iter
	dbus.api.dbus_message_iter_init_append(msg, &it)
	dbus.append_string(&it, L.title)
	replaces := L.notif_id_by_tag[tag] or_else 0
	dbus.append_u32(&it, replaces)
	dbus.append_string(&it, "flurfunk") // theme icon fallback; image-data wins
	dbus.append_string(&it, cstr(title))
	dbus.append_string(&it, cstr(body))

	// actions: ["default", "Öffnen"] → click anywhere opens the app
	arr: dbus.Iter
	dbus.api.dbus_message_iter_open_container(&it, dbus.T_ARRAY, "s", &arr)
	dbus.append_string(&arr, "default")
	dbus.append_string(&arr, "Öffnen")
	dbus.api.dbus_message_iter_close_container(&it, &arr)

	// hints
	hints: dbus.Iter
	dbus.api.dbus_message_iter_open_container(&it, dbus.T_ARRAY, "{sv}", &hints)
	dbus.append_dict_string(&hints, "desktop-entry", "flurfunk")
	dbus.append_dict_string(&hints, "category", kind == .Call ? "call.incoming" : "im.received")
	dbus.append_dict_string(&hints, "sound-name",
		kind == .Call ? "phone-incoming-call" : "message-new-instant")
	if L.notif_icon.w > 0 {
		append_image_data(&hints, L.notif_icon)
	}
	dbus.api.dbus_message_iter_close_container(&it, &hints)

	dbus.append_i32(&it, -1) // expire: server default

	pc: ^dbus.Pending_Call
	ok := dbus.api.dbus_connection_send_with_reply(L.conn, msg, &pc, 10000)
	dbus.api.dbus_message_unref(msg)
	if !ok || pc == nil {
		return false
	}
	append(&L.notif_pend, Notif_Pending{pc, tag})
	dbus.api.dbus_connection_flush(L.conn)
	return true
}

// hint "image-data": (iiibiiay) — raw RGBA rows.
@(private = "file")
append_image_data :: proc(hints: ^dbus.Iter, icon: Tray_Icon) {
	e, v, st, arr: dbus.Iter
	dbus.api.dbus_message_iter_open_container(hints, dbus.T_DICT_ENTRY, nil, &e)
	dbus.append_string(&e, "image-data")
	dbus.api.dbus_message_iter_open_container(&e, dbus.T_VARIANT, "(iiibiiay)", &v)
	dbus.api.dbus_message_iter_open_container(&v, dbus.T_STRUCT, nil, &st)
	dbus.append_i32(&st, i32(icon.w))
	dbus.append_i32(&st, i32(icon.h))
	dbus.append_i32(&st, i32(icon.w*4))
	dbus.append_bool(&st, true)
	dbus.append_i32(&st, 8)
	dbus.append_i32(&st, 4)
	dbus.api.dbus_message_iter_open_container(&st, dbus.T_ARRAY, "y", &arr)
	data := raw_data(icon.rgba)
	dbus.api.dbus_message_iter_append_fixed_array(&arr, dbus.T_BYTE, &data, i32(len(icon.rgba)))
	dbus.api.dbus_message_iter_close_container(&st, &arr)
	dbus.api.dbus_message_iter_close_container(&v, &st)
	dbus.api.dbus_message_iter_close_container(&e, &v)
	dbus.api.dbus_message_iter_close_container(hints, &e)
}

// --- registration -----------------------------------------------------------

@(private = "file")
register_watcher :: proc() {
	if L.reg_pc != nil {
		dbus.api.dbus_pending_call_cancel(L.reg_pc)
		dbus.api.dbus_pending_call_unref(L.reg_pc)
		L.reg_pc = nil
	}
	L.registered = false
	msg := dbus.api.dbus_message_new_method_call(WATCHER_NAME, "/StatusNotifierWatcher",
		WATCHER_NAME, "RegisterStatusNotifierItem")
	if msg == nil {
		return
	}
	it: dbus.Iter
	dbus.api.dbus_message_iter_init_append(msg, &it)
	dbus.append_string(&it, L.item_name)
	dbus.api.dbus_connection_send_with_reply(L.conn, msg, &L.reg_pc, 5000)
	dbus.api.dbus_message_unref(msg)
}

// --- incoming messages ------------------------------------------------------

@(private = "file")
nz :: proc(c: cstring) -> string {
	return c == nil ? "" : string(c)
}

@(private = "file")
tray_filter :: proc "c" (conn: ^dbus.Connection, msg: ^dbus.Message, user_data: rawptr) -> i32 {
	context = runtime.default_context()
	kind := dbus.api.dbus_message_get_type(msg)
	path := nz(dbus.api.dbus_message_get_path(msg))
	iface := nz(dbus.api.dbus_message_get_interface(msg))
	member := nz(dbus.api.dbus_message_get_member(msg))

	if kind == dbus.TYPE_METHOD_CALL {
		switch path {
		case string(ITEM_PATH):
			return handle_item_call(msg, iface, member)
		case string(MENU_PATH):
			return handle_menu_call(msg, iface, member)
		}
		return dbus.NOT_YET_HANDLED
	}

	if kind == dbus.TYPE_SIGNAL {
		switch {
		case iface == "org.freedesktop.DBus" && member == "NameOwnerChanged":
			it: dbus.Iter
			if dbus.api.dbus_message_iter_init(msg, &it) {
				name := dbus.get_string(&it)
				dbus.api.dbus_message_iter_next(&it)
				dbus.api.dbus_message_iter_next(&it)
				new_owner := dbus.get_string(&it)
				if name == WATCHER_NAME && new_owner != "" {
					register_watcher() // watcher (re)started → re-register
				}
			}
			return dbus.HANDLED
		case iface == string(NOTIF_IFACE) && member == "ActionInvoked":
			it: dbus.Iter
			if dbus.api.dbus_message_iter_init(msg, &it) {
				id := dbus.get_u32(&it)
				dbus.api.dbus_message_iter_next(&it)
				action := dbus.get_string(&it)
				if action == "default" {
					if tag, has := L.notif_tag_by_id[id]; has {
						push_notif_event(&L.ev, tag)
					}
				}
			}
			return dbus.HANDLED
		case iface == string(NOTIF_IFACE) && member == "NotificationClosed":
			it: dbus.Iter
			if dbus.api.dbus_message_iter_init(msg, &it) {
				id := dbus.get_u32(&it)
				if tag, has := L.notif_tag_by_id[id]; has {
					delete_key(&L.notif_tag_by_id, id)
					if cur, cur_has := L.notif_id_by_tag[tag]; cur_has && cur == id {
						delete_key(&L.notif_id_by_tag, tag)
					}
				}
			}
			return dbus.HANDLED
		}
	}
	return dbus.NOT_YET_HANDLED
}

@(private = "file")
send_empty_reply :: proc(call: ^dbus.Message) {
	reply := dbus.api.dbus_message_new_method_return(call)
	if reply != nil {
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
	}
}

@(private = "file")
send_error_reply :: proc(call: ^dbus.Message, name, text: cstring) {
	reply := dbus.api.dbus_message_new_error(call, name, text)
	if reply != nil {
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
	}
}

// --- StatusNotifierItem object ----------------------------------------------

@(private = "file")
handle_item_call :: proc(msg: ^dbus.Message, iface, member: string) -> i32 {
	switch iface {
	case PROPS_IFACE:
		return handle_properties(msg, member, append_item_prop, item_prop_names())
	case string(SNI_IFACE):
		switch member {
		case "Activate", "SecondaryActivate":
			L.ev.toggle = true
			send_empty_reply(msg)
		case "ContextMenu", "Scroll", "ProvideXdgActivationToken":
			send_empty_reply(msg)
		case:
			return dbus.NOT_YET_HANDLED
		}
		return dbus.HANDLED
	case "org.freedesktop.DBus.Introspectable":
		if member == "Introspect" {
			reply := dbus.api.dbus_message_new_method_return(msg)
			it: dbus.Iter
			dbus.api.dbus_message_iter_init_append(reply, &it)
			dbus.append_string(&it, ITEM_XML)
			dbus.api.dbus_connection_send(L.conn, reply, nil)
			dbus.api.dbus_message_unref(reply)
			return dbus.HANDLED
		}
	}
	return dbus.NOT_YET_HANDLED
}

@(private = "file")
item_prop_names :: proc() -> []string {
	@(static) names := [?]string{
		"Category", "Id", "Title", "Status", "WindowId", "IconName", "IconPixmap",
		"OverlayIconName", "OverlayIconPixmap", "AttentionIconName",
		"AttentionIconPixmap", "AttentionMovieName", "ToolTip", "ItemIsMenu", "Menu",
	}
	return names[:]
}

// Append one property as a variant. Returns false for unknown names.
@(private = "file")
append_item_prop :: proc(it: ^dbus.Iter, name: string) -> bool {
	switch name {
	case "Category":
		dbus.append_variant_string(it, "Communications")
	case "Id":
		dbus.append_variant_string(it, "flurfunk")
	case "Title":
		dbus.append_variant_string(it, L.title)
	case "Status":
		dbus.append_variant_string(it, "Active")
	case "WindowId":
		dbus.append_variant_i32(it, 0)
	case "IconName", "OverlayIconName", "AttentionIconName", "AttentionMovieName":
		dbus.append_variant_string(it, "")
	case "IconPixmap":
		append_variant_pixmaps(it, L.unread ? L.icons_unread : L.icons)
	case "OverlayIconPixmap", "AttentionIconPixmap":
		append_variant_pixmaps(it, nil)
	case "ToolTip":
		append_variant_tooltip(it)
	case "ItemIsMenu":
		dbus.append_variant_bool(it, false)
	case "Menu":
		dbus.append_variant_object_path(it, MENU_PATH)
	case:
		return false
	}
	return true
}

@(private = "file")
append_pixmaps :: proc(it: ^dbus.Iter, icons: []Argb_Icon) {
	arr: dbus.Iter
	dbus.api.dbus_message_iter_open_container(it, dbus.T_ARRAY, "(iiay)", &arr)
	for icon in icons {
		st, bytes: dbus.Iter
		dbus.api.dbus_message_iter_open_container(&arr, dbus.T_STRUCT, nil, &st)
		dbus.append_i32(&st, i32(icon.w))
		dbus.append_i32(&st, i32(icon.h))
		dbus.api.dbus_message_iter_open_container(&st, dbus.T_ARRAY, "y", &bytes)
		data := raw_data(icon.argb)
		dbus.api.dbus_message_iter_append_fixed_array(&bytes, dbus.T_BYTE, &data, i32(len(icon.argb)))
		dbus.api.dbus_message_iter_close_container(&st, &bytes)
		dbus.api.dbus_message_iter_close_container(&arr, &st)
	}
	dbus.api.dbus_message_iter_close_container(it, &arr)
}

@(private = "file")
append_variant_pixmaps :: proc(it: ^dbus.Iter, icons: []Argb_Icon) {
	v: dbus.Iter
	dbus.api.dbus_message_iter_open_container(it, dbus.T_VARIANT, "a(iiay)", &v)
	append_pixmaps(&v, icons)
	dbus.api.dbus_message_iter_close_container(it, &v)
}

@(private = "file")
append_variant_tooltip :: proc(it: ^dbus.Iter) {
	v, st: dbus.Iter
	dbus.api.dbus_message_iter_open_container(it, dbus.T_VARIANT, "(sa(iiay)ss)", &v)
	dbus.api.dbus_message_iter_open_container(&v, dbus.T_STRUCT, nil, &st)
	dbus.append_string(&st, "")
	append_pixmaps(&st, nil)
	dbus.append_string(&st, L.title)
	dbus.append_string(&st, "")
	dbus.api.dbus_message_iter_close_container(&v, &st)
	dbus.api.dbus_message_iter_close_container(it, &v)
}

// Shared org.freedesktop.DBus.Properties handler for both objects.
@(private = "file")
handle_properties :: proc(msg: ^dbus.Message, member: string,
	append_prop: proc(it: ^dbus.Iter, name: string) -> bool, names: []string) -> i32 {
	switch member {
	case "Get":
		it: dbus.Iter
		prop := ""
		if dbus.api.dbus_message_iter_init(msg, &it) {
			dbus.api.dbus_message_iter_next(&it) // interface name (ignored)
			prop = dbus.get_string(&it)
		}
		reply := dbus.api.dbus_message_new_method_return(msg)
		rit: dbus.Iter
		dbus.api.dbus_message_iter_init_append(reply, &rit)
		if !append_prop(&rit, prop) {
			dbus.api.dbus_message_unref(reply)
			send_error_reply(msg, "org.freedesktop.DBus.Error.UnknownProperty", "unknown property")
			return dbus.HANDLED
		}
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
		return dbus.HANDLED
	case "GetAll":
		reply := dbus.api.dbus_message_new_method_return(msg)
		rit, arr: dbus.Iter
		dbus.api.dbus_message_iter_init_append(reply, &rit)
		dbus.api.dbus_message_iter_open_container(&rit, dbus.T_ARRAY, "{sv}", &arr)
		for name in names {
			e: dbus.Iter
			dbus.api.dbus_message_iter_open_container(&arr, dbus.T_DICT_ENTRY, nil, &e)
			dbus.append_string(&e, cstr(name))
			append_prop(&e, name)
			dbus.api.dbus_message_iter_close_container(&arr, &e)
		}
		dbus.api.dbus_message_iter_close_container(&rit, &arr)
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
		return dbus.HANDLED
	case "Set":
		send_empty_reply(msg)
		return dbus.HANDLED
	}
	return dbus.NOT_YET_HANDLED
}

// --- dbusmenu object --------------------------------------------------------

@(private = "file")
menu_prop_names :: proc() -> []string {
	@(static) names := [?]string{"Version", "Status", "TextDirection", "IconThemePath"}
	return names[:]
}

@(private = "file")
append_menu_prop :: proc(it: ^dbus.Iter, name: string) -> bool {
	switch name {
	case "Version":
		dbus.append_variant_u32(it, 3)
	case "Status":
		dbus.append_variant_string(it, "normal")
	case "TextDirection":
		dbus.append_variant_string(it, "ltr")
	case "IconThemePath":
		v, arr: dbus.Iter
		dbus.api.dbus_message_iter_open_container(it, dbus.T_VARIANT, "as", &v)
		dbus.api.dbus_message_iter_open_container(&v, dbus.T_ARRAY, "s", &arr)
		dbus.api.dbus_message_iter_close_container(&v, &arr)
		dbus.api.dbus_message_iter_close_container(it, &v)
	case:
		return false
	}
	return true
}

// Properties of one menu item into an open a{sv} container.
@(private = "file")
append_menu_item_props :: proc(it: ^dbus.Iter, id: i32) {
	switch id {
	case MENU_ROOT:
		dbus.append_dict_string(it, "children-display", "submenu")
	case MENU_OPEN:
		dbus.append_dict_string(it, "label", L.open_label)
	case MENU_SEP:
		dbus.append_dict_string(it, "type", "separator")
	case MENU_QUIT:
		dbus.append_dict_string(it, "label", "Beenden")
	}
}

// One (ia{sv}av) layout node.
@(private = "file")
append_menu_node :: proc(it: ^dbus.Iter, id: i32, with_children: bool) {
	st, props, children: dbus.Iter
	dbus.api.dbus_message_iter_open_container(it, dbus.T_STRUCT, nil, &st)
	dbus.append_i32(&st, id)
	dbus.api.dbus_message_iter_open_container(&st, dbus.T_ARRAY, "{sv}", &props)
	append_menu_item_props(&props, id)
	dbus.api.dbus_message_iter_close_container(&st, &props)
	dbus.api.dbus_message_iter_open_container(&st, dbus.T_ARRAY, "v", &children)
	if id == MENU_ROOT && with_children {
		for cid in ([3]i32{MENU_OPEN, MENU_SEP, MENU_QUIT}) {
			v: dbus.Iter
			dbus.api.dbus_message_iter_open_container(&children, dbus.T_VARIANT, "(ia{sv}av)", &v)
			append_menu_node(&v, cid, false)
			dbus.api.dbus_message_iter_close_container(&children, &v)
		}
	}
	dbus.api.dbus_message_iter_close_container(&st, &children)
	dbus.api.dbus_message_iter_close_container(it, &st)
}

@(private = "file")
handle_menu_call :: proc(msg: ^dbus.Message, iface, member: string) -> i32 {
	switch iface {
	case PROPS_IFACE:
		return handle_properties(msg, member, append_menu_prop, menu_prop_names())
	case "org.freedesktop.DBus.Introspectable":
		if member == "Introspect" {
			reply := dbus.api.dbus_message_new_method_return(msg)
			it: dbus.Iter
			dbus.api.dbus_message_iter_init_append(reply, &it)
			dbus.append_string(&it, MENU_XML)
			dbus.api.dbus_connection_send(L.conn, reply, nil)
			dbus.api.dbus_message_unref(reply)
			return dbus.HANDLED
		}
		return dbus.NOT_YET_HANDLED
	case string(MENU_IFACE):
		// fällt durch zum switch unten
	case:
		return dbus.NOT_YET_HANDLED
	}

	switch member {
	case "GetLayout":
		parent := i32(0)
		it: dbus.Iter
		if dbus.api.dbus_message_iter_init(msg, &it) {
			parent = dbus.get_i32(&it)
		}
		reply := dbus.api.dbus_message_new_method_return(msg)
		rit: dbus.Iter
		dbus.api.dbus_message_iter_init_append(reply, &rit)
		dbus.append_u32(&rit, 1) // revision (menu is static)
		append_menu_node(&rit, parent, parent == MENU_ROOT)
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
		return dbus.HANDLED

	case "GetGroupProperties":
		// requested ids (empty → all)
		ids := make([dynamic]i32, context.temp_allocator)
		it: dbus.Iter
		if dbus.api.dbus_message_iter_init(msg, &it) &&
		   dbus.api.dbus_message_iter_get_arg_type(&it) == dbus.T_ARRAY {
			sub: dbus.Iter
			dbus.api.dbus_message_iter_recurse(&it, &sub)
			for dbus.api.dbus_message_iter_get_arg_type(&sub) == dbus.T_INT32 {
				append(&ids, dbus.get_i32(&sub))
				dbus.api.dbus_message_iter_next(&sub)
			}
		}
		if len(ids) == 0 {
			append(&ids, MENU_ROOT, MENU_OPEN, MENU_SEP, MENU_QUIT)
		}
		reply := dbus.api.dbus_message_new_method_return(msg)
		rit, arr: dbus.Iter
		dbus.api.dbus_message_iter_init_append(reply, &rit)
		dbus.api.dbus_message_iter_open_container(&rit, dbus.T_ARRAY, "(ia{sv})", &arr)
		for id in ids {
			st, props: dbus.Iter
			dbus.api.dbus_message_iter_open_container(&arr, dbus.T_STRUCT, nil, &st)
			dbus.append_i32(&st, id)
			dbus.api.dbus_message_iter_open_container(&st, dbus.T_ARRAY, "{sv}", &props)
			append_menu_item_props(&props, id)
			dbus.api.dbus_message_iter_close_container(&st, &props)
			dbus.api.dbus_message_iter_close_container(&arr, &st)
		}
		dbus.api.dbus_message_iter_close_container(&rit, &arr)
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
		return dbus.HANDLED

	case "GetProperty":
		reply := dbus.api.dbus_message_new_method_return(msg)
		rit: dbus.Iter
		dbus.api.dbus_message_iter_init_append(reply, &rit)
		dbus.append_variant_string(&rit, "")
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
		return dbus.HANDLED

	case "Event":
		it: dbus.Iter
		if dbus.api.dbus_message_iter_init(msg, &it) {
			id := dbus.get_i32(&it)
			dbus.api.dbus_message_iter_next(&it)
			event := dbus.get_string(&it)
			if event == "clicked" {
				switch id {
				case MENU_OPEN:
					L.ev.show = true
				case MENU_QUIT:
					L.ev.quit = true
				}
			}
		}
		send_empty_reply(msg)
		return dbus.HANDLED

	case "EventGroup":
		// Reply: ai of ids that were NOT found — ours all exist.
		reply := dbus.api.dbus_message_new_method_return(msg)
		rit, arr: dbus.Iter
		dbus.api.dbus_message_iter_init_append(reply, &rit)
		dbus.api.dbus_message_iter_open_container(&rit, dbus.T_ARRAY, "i", &arr)
		dbus.api.dbus_message_iter_close_container(&rit, &arr)
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
		// Events selbst auswerten wie oben
		it: dbus.Iter
		if dbus.api.dbus_message_iter_init(msg, &it) &&
		   dbus.api.dbus_message_iter_get_arg_type(&it) == dbus.T_ARRAY {
			sub: dbus.Iter
			dbus.api.dbus_message_iter_recurse(&it, &sub)
			for dbus.api.dbus_message_iter_get_arg_type(&sub) == dbus.T_STRUCT {
				st: dbus.Iter
				dbus.api.dbus_message_iter_recurse(&sub, &st)
				id := dbus.get_i32(&st)
				dbus.api.dbus_message_iter_next(&st)
				event := dbus.get_string(&st)
				if event == "clicked" {
					switch id {
					case MENU_OPEN:
						L.ev.show = true
					case MENU_QUIT:
						L.ev.quit = true
					}
				}
				dbus.api.dbus_message_iter_next(&sub)
			}
		}
		return dbus.HANDLED

	case "AboutToShow":
		reply := dbus.api.dbus_message_new_method_return(msg)
		rit: dbus.Iter
		dbus.api.dbus_message_iter_init_append(reply, &rit)
		dbus.append_bool(&rit, false)
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
		return dbus.HANDLED

	case "AboutToShowGroup":
		reply := dbus.api.dbus_message_new_method_return(msg)
		rit, a1, a2: dbus.Iter
		dbus.api.dbus_message_iter_init_append(reply, &rit)
		dbus.api.dbus_message_iter_open_container(&rit, dbus.T_ARRAY, "i", &a1)
		dbus.api.dbus_message_iter_close_container(&rit, &a1)
		dbus.api.dbus_message_iter_open_container(&rit, dbus.T_ARRAY, "i", &a2)
		dbus.api.dbus_message_iter_close_container(&rit, &a2)
		dbus.api.dbus_connection_send(L.conn, reply, nil)
		dbus.api.dbus_message_unref(reply)
		return dbus.HANDLED
	}
	return dbus.NOT_YET_HANDLED
}

// --- introspection ----------------------------------------------------------

@(private = "file")
ITEM_XML: cstring : `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
 <interface name="org.freedesktop.DBus.Properties">
  <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
  <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
 </interface>
 <interface name="org.kde.StatusNotifierItem">
  <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
  <property name="Category" type="s" access="read"/>
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="WindowId" type="i" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="IconPixmap" type="a(iiay)" access="read"/>
  <property name="OverlayIconName" type="s" access="read"/>
  <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
  <property name="AttentionIconName" type="s" access="read"/>
  <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
  <property name="AttentionMovieName" type="s" access="read"/>
  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <signal name="NewIcon"/>
  <signal name="NewTitle"/>
  <signal name="NewToolTip"/>
  <signal name="NewStatus"><arg type="s"/></signal>
 </interface>
</node>`

@(private = "file")
MENU_XML: cstring : `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
 <interface name="org.freedesktop.DBus.Properties">
  <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
  <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
 </interface>
 <interface name="com.canonical.dbusmenu">
  <method name="GetLayout">
   <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
   <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
  </method>
  <method name="GetGroupProperties">
   <arg type="ai" direction="in"/><arg type="as" direction="in"/>
   <arg type="a(ia{sv})" direction="out"/>
  </method>
  <method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
  <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
  <method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
  <property name="Version" type="u" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="TextDirection" type="s" access="read"/>
  <property name="IconThemePath" type="as" access="read"/>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
  <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
 </interface>
</node>`
