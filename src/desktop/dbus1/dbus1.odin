#+build linux
package dbus1

// Minimal libdbus-1 bindings, loaded at runtime via dlopen. No link-time
// dependency: on systems without D-Bus everything degrades gracefully
// (no tray, no notifications). The public struct layouts used here
// (DBusMessageIter) are part of libdbus's frozen ABI.

import "core:dynlib"

Connection :: struct {}
Message :: struct {}
Pending_Call :: struct {}

// Frozen public ABI (dbus-message.h). 72 bytes on 64-bit.
Iter :: struct {
	dummy1, dummy2:                                          rawptr,
	dummy3:                                                  u32,
	dummy4, dummy5, dummy6, dummy7, dummy8, dummy9, dummy10: i32,
	dummy11:                                                 i32,
	pad1:                                                    i32,
	pad2, pad3:                                              rawptr,
}

BUS_SESSION :: i32(0)

// Message types
TYPE_METHOD_CALL :: i32(1)
TYPE_METHOD_RETURN :: i32(2)
TYPE_ERROR :: i32(3)
TYPE_SIGNAL :: i32(4)

// Wire type codes (ASCII of the signature characters)
T_BYTE :: i32('y')
T_BOOLEAN :: i32('b')
T_INT32 :: i32('i')
T_UINT32 :: i32('u')
T_UINT64 :: i32('t')
T_DOUBLE :: i32('d')
T_STRING :: i32('s')
T_OBJECT_PATH :: i32('o')
T_ARRAY :: i32('a')
T_VARIANT :: i32('v')
T_STRUCT :: i32('r')
T_DICT_ENTRY :: i32('e')
T_INVALID :: i32(0)

// dbus_connection_dispatch results
DISPATCH_DATA_REMAINS :: i32(0)

// DBusHandlerResult
HANDLED :: i32(0)
NOT_YET_HANDLED :: i32(1)

// dbus_bus_request_name
NAME_FLAG_DO_NOT_QUEUE :: u32(4)
REQUEST_NAME_REPLY_PRIMARY_OWNER :: i32(1)

Filter_Fn :: proc "c" (conn: ^Connection, msg: ^Message, user_data: rawptr) -> i32

// Symbol table filled by dynlib.initialize_symbols (field name == symbol name).
Api :: struct {
	dbus_bus_get_private:                    proc "c" (kind: i32, err: rawptr) -> ^Connection,
	dbus_bus_get_unique_name:                proc "c" (conn: ^Connection) -> cstring,
	dbus_bus_request_name:                   proc "c" (conn: ^Connection, name: cstring, flags: u32, err: rawptr) -> i32,
	dbus_bus_add_match:                      proc "c" (conn: ^Connection, rule: cstring, err: rawptr),
	dbus_connection_set_exit_on_disconnect:  proc "c" (conn: ^Connection, on: b32),
	dbus_connection_close:                   proc "c" (conn: ^Connection),
	dbus_connection_unref:                   proc "c" (conn: ^Connection),
	dbus_connection_read_write:              proc "c" (conn: ^Connection, timeout_ms: i32) -> b32,
	dbus_connection_dispatch:                proc "c" (conn: ^Connection) -> i32,
	dbus_connection_flush:                   proc "c" (conn: ^Connection),
	dbus_connection_send:                    proc "c" (conn: ^Connection, msg: ^Message, serial: ^u32) -> b32,
	dbus_connection_send_with_reply:         proc "c" (conn: ^Connection, msg: ^Message, pending: ^^Pending_Call, timeout_ms: i32) -> b32,
	dbus_connection_add_filter:              proc "c" (conn: ^Connection, fn: Filter_Fn, user_data: rawptr, free_fn: rawptr) -> b32,
	dbus_message_new_method_call:            proc "c" (dest, path, iface, method: cstring) -> ^Message,
	dbus_message_new_method_return:          proc "c" (call: ^Message) -> ^Message,
	dbus_message_new_error:                  proc "c" (call: ^Message, name, text: cstring) -> ^Message,
	dbus_message_new_signal:                 proc "c" (path, iface, name: cstring) -> ^Message,
	dbus_message_unref:                      proc "c" (msg: ^Message),
	dbus_message_get_type:                   proc "c" (msg: ^Message) -> i32,
	dbus_message_get_path:                   proc "c" (msg: ^Message) -> cstring,
	dbus_message_get_interface:              proc "c" (msg: ^Message) -> cstring,
	dbus_message_get_member:                 proc "c" (msg: ^Message) -> cstring,
	dbus_message_get_sender:                 proc "c" (msg: ^Message) -> cstring,
	dbus_message_get_signature:              proc "c" (msg: ^Message) -> cstring,
	dbus_message_get_serial:                 proc "c" (msg: ^Message) -> u32,
	dbus_message_get_reply_serial:           proc "c" (msg: ^Message) -> u32,
	dbus_message_iter_init:                  proc "c" (msg: ^Message, iter: ^Iter) -> b32,
	dbus_message_iter_init_append:           proc "c" (msg: ^Message, iter: ^Iter),
	dbus_message_iter_append_basic:          proc "c" (iter: ^Iter, kind: i32, value: rawptr) -> b32,
	dbus_message_iter_append_fixed_array:    proc "c" (iter: ^Iter, kind: i32, value: rawptr, n: i32) -> b32,
	dbus_message_iter_open_container:        proc "c" (iter: ^Iter, kind: i32, sig: cstring, sub: ^Iter) -> b32,
	dbus_message_iter_close_container:       proc "c" (iter: ^Iter, sub: ^Iter) -> b32,
	dbus_message_iter_get_arg_type:          proc "c" (iter: ^Iter) -> i32,
	dbus_message_iter_get_basic:             proc "c" (iter: ^Iter, value: rawptr),
	dbus_message_iter_next:                  proc "c" (iter: ^Iter) -> b32,
	dbus_message_iter_recurse:               proc "c" (iter: ^Iter, sub: ^Iter),
	dbus_pending_call_get_completed:         proc "c" (pending: ^Pending_Call) -> b32,
	dbus_pending_call_steal_reply:           proc "c" (pending: ^Pending_Call) -> ^Message,
	dbus_pending_call_cancel:                proc "c" (pending: ^Pending_Call),
	dbus_pending_call_unref:                 proc "c" (pending: ^Pending_Call),

	__handle: dynlib.Library,
}

api: Api
loaded: bool

// Load libdbus once. Safe to call repeatedly.
load :: proc() -> bool {
	if loaded {
		return true
	}
	count, ok := dynlib.initialize_symbols(&api, "libdbus-1.so.3")
	if !ok || count <= 0 {
		count, ok = dynlib.initialize_symbols(&api, "libdbus-1.so")
	}
	if !ok || count <= 0 {
		return false
	}
	// All fields must have resolved — a partial libdbus is unusable.
	if api.dbus_bus_get_private == nil ||
	   api.dbus_connection_send == nil ||
	   api.dbus_message_iter_open_container == nil ||
	   api.dbus_pending_call_steal_reply == nil {
		return false
	}
	loaded = true
	return true
}

// Non-blocking: read/write pending data and dispatch all queued messages
// (runs registered filters). Returns false when the connection died.
pump :: proc(conn: ^Connection) -> bool {
	if conn == nil {
		return false
	}
	alive := api.dbus_connection_read_write(conn, 0)
	for api.dbus_connection_dispatch(conn) == DISPATCH_DATA_REMAINS {
	}
	return bool(alive)
}

// --- append helpers (cstrings must outlive the call only; libdbus copies) ---

append_string :: proc(it: ^Iter, s: cstring) {
	s := s
	api.dbus_message_iter_append_basic(it, T_STRING, &s)
}

append_object_path :: proc(it: ^Iter, s: cstring) {
	s := s
	api.dbus_message_iter_append_basic(it, T_OBJECT_PATH, &s)
}

append_u32 :: proc(it: ^Iter, v: u32) {
	v := v
	api.dbus_message_iter_append_basic(it, T_UINT32, &v)
}

append_i32 :: proc(it: ^Iter, v: i32) {
	v := v
	api.dbus_message_iter_append_basic(it, T_INT32, &v)
}

append_bool :: proc(it: ^Iter, v: bool) {
	b := b32(v)
	api.dbus_message_iter_append_basic(it, T_BOOLEAN, &b)
}

// Variant with a single basic value.
append_variant_string :: proc(it: ^Iter, s: cstring) {
	sub: Iter
	api.dbus_message_iter_open_container(it, T_VARIANT, "s", &sub)
	append_string(&sub, s)
	api.dbus_message_iter_close_container(it, &sub)
}

append_variant_object_path :: proc(it: ^Iter, s: cstring) {
	sub: Iter
	api.dbus_message_iter_open_container(it, T_VARIANT, "o", &sub)
	append_object_path(&sub, s)
	api.dbus_message_iter_close_container(it, &sub)
}

append_variant_bool :: proc(it: ^Iter, v: bool) {
	sub: Iter
	api.dbus_message_iter_open_container(it, T_VARIANT, "b", &sub)
	append_bool(&sub, v)
	api.dbus_message_iter_close_container(it, &sub)
}

append_variant_u32 :: proc(it: ^Iter, v: u32) {
	sub: Iter
	api.dbus_message_iter_open_container(it, T_VARIANT, "u", &sub)
	append_u32(&sub, v)
	api.dbus_message_iter_close_container(it, &sub)
}

append_variant_i32 :: proc(it: ^Iter, v: i32) {
	sub: Iter
	api.dbus_message_iter_open_container(it, T_VARIANT, "i", &sub)
	append_i32(&sub, v)
	api.dbus_message_iter_close_container(it, &sub)
}

// a{sv} entry: key + one basic-typed variant, used all over the place.
append_dict_string :: proc(it: ^Iter, key: cstring, val: cstring) {
	e: Iter
	api.dbus_message_iter_open_container(it, T_DICT_ENTRY, nil, &e)
	append_string(&e, key)
	append_variant_string(&e, val)
	api.dbus_message_iter_close_container(it, &e)
}

// --- read helpers ---

// Borrowed from the message — valid until the message is unref'd.
get_string :: proc(it: ^Iter) -> string {
	if api.dbus_message_iter_get_arg_type(it) != T_STRING &&
	   api.dbus_message_iter_get_arg_type(it) != T_OBJECT_PATH {
		return ""
	}
	s: cstring
	api.dbus_message_iter_get_basic(it, &s)
	return string(s)
}

get_u32 :: proc(it: ^Iter) -> u32 {
	if api.dbus_message_iter_get_arg_type(it) != T_UINT32 {
		return 0
	}
	v: u32
	api.dbus_message_iter_get_basic(it, &v)
	return v
}

get_i32 :: proc(it: ^Iter) -> i32 {
	if api.dbus_message_iter_get_arg_type(it) != T_INT32 {
		return 0
	}
	v: i32
	api.dbus_message_iter_get_basic(it, &v)
	return v
}
