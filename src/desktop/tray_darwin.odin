#+build darwin
package desktop

// macOS backend: NSStatusItem in der Menüleiste (mit Öffnen/Beenden-Menü)
// + NSUserNotificationCenter für Benachrichtigungen. Läuft komplett über
// die ObjC-Runtime; objc_msgSend wird per dlopen aufgelöst und pro
// Signatur getypt aufgerufen (Pflicht auf arm64 — variadische Aufrufe
// hätten dort die falsche ABI). base:runtime deklariert dieselben Symbole
// bereits, deshalb dynlib statt eigener foreign-Deklarationen.
// Muss vom Main-Thread benutzt werden (AppKit-Regel); die Action-Callbacks
// feuern während glfwPollEvents (raylib EndDrawing) — ebenfalls Main-Thread.

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:strings"

@(private = "file") objc_id :: rawptr
@(private = "file") SEL :: rawptr
@(private = "file") Class :: rawptr

@(private = "file") NSSize :: struct {
	w, h: f64,
}

@(private = "file")
O: struct {
	objc_getClass:          proc "c" (name: cstring) -> Class,
	sel_registerName:       proc "c" (name: cstring) -> SEL,
	objc_allocateClassPair: proc "c" (super: Class, name: cstring, extra: uint) -> Class,
	objc_registerClassPair: proc "c" (cls: Class),
	class_addMethod:        proc "c" (cls: Class, sel: SEL, imp: rawptr, types: cstring) -> b8,
	object_getClass:        proc "c" (obj: objc_id) -> Class,
	objc_msgSend:           rawptr, // pro Aufruf passend getypt (s. msg*-Helfer)

	__handle: dynlib.Library,
}

@(private = "file")
msg0 :: proc(obj: objc_id, s: SEL) -> objc_id {
	return (transmute(proc "c" (objc_id, SEL) -> objc_id)O.objc_msgSend)(obj, s)
}

@(private = "file")
msg1 :: proc(obj: objc_id, s: SEL, a: rawptr) -> objc_id {
	return (transmute(proc "c" (objc_id, SEL, rawptr) -> objc_id)O.objc_msgSend)(obj, s, a)
}

@(private = "file")
msg2 :: proc(obj: objc_id, s: SEL, a, b: rawptr) -> objc_id {
	return (transmute(proc "c" (objc_id, SEL, rawptr, rawptr) -> objc_id)O.objc_msgSend)(obj, s, a, b)
}

@(private = "file")
msg3 :: proc(obj: objc_id, s: SEL, a, b, c: rawptr) -> objc_id {
	return (transmute(proc "c" (objc_id, SEL, rawptr, rawptr, rawptr) -> objc_id)O.objc_msgSend)(obj, s, a, b, c)
}

@(private = "file")
msg_f :: proc(obj: objc_id, s: SEL, v: f64) -> objc_id {
	return (transmute(proc "c" (objc_id, SEL, f64) -> objc_id)O.objc_msgSend)(obj, s, v)
}

@(private = "file")
msg_size :: proc(obj: objc_id, s: SEL, size: NSSize) {
	(transmute(proc "c" (objc_id, SEL, NSSize))O.objc_msgSend)(obj, s, size)
}

@(private = "file")
msg_u64 :: proc(obj: objc_id, s: SEL) -> u64 {
	return (transmute(proc "c" (objc_id, SEL) -> u64)O.objc_msgSend)(obj, s)
}

@(private = "file")
msg_1u64 :: proc(obj: objc_id, s: SEL, v: u64) -> objc_id {
	return (transmute(proc "c" (objc_id, SEL, u64) -> objc_id)O.objc_msgSend)(obj, s, v)
}

@(private = "file")
D: struct {
	inited:     bool,
	ev:         Events,
	item:       objc_id, // NSStatusItem (retained)
	button:     objc_id,
	img:        objc_id, // NSImage normal
	img_unread: objc_id,
	target:     objc_id, // FFTrayTarget-Instanz (Menü-Actions + Delegate)
	center:     objc_id, // NSUserNotificationCenter (nil ohne App-Bundle)
	sound:      objc_id, // NSUserNotificationDefaultSoundName
	unread:     bool,
}

@(private = "file")
sel :: proc(name: cstring) -> SEL {
	return O.sel_registerName(name)
}

@(private = "file")
cls :: proc(name: cstring) -> Class {
	return O.objc_getClass(name)
}

@(private = "file")
nsstring :: proc(s: string) -> objc_id {
	c := strings.clone_to_cstring(s, context.temp_allocator)
	return msg1(cls("NSString"), sel("stringWithUTF8String:"), rawptr(c))
}

@(private = "file")
image_from_png :: proc(png: []u8) -> objc_id {
	if len(png) == 0 {
		return nil
	}
	data := msg2(cls("NSData"), sel("dataWithBytes:length:"),
		raw_data(png), rawptr(uintptr(len(png))))
	if data == nil {
		return nil
	}
	img := msg1(msg0(cls("NSImage"), sel("alloc")), sel("initWithData:"), data)
	if img == nil {
		return nil
	}
	msg_size(img, sel("setSize:"), {18, 18}) // Punkte; Retina nutzt die vollen Pixel
	return img
}

// --- Action-/Delegate-Callbacks (laufen im Main-Thread-Eventpump) ---

@(private = "file")
imp_open :: proc "c" (self: objc_id, cmd: SEL, sender: objc_id) {
	D.ev.show = true
}

@(private = "file")
imp_quit :: proc "c" (self: objc_id, cmd: SEL, sender: objc_id) {
	D.ev.quit = true
}

// Klick auf eine zugestellte Benachrichtigung.
@(private = "file")
imp_did_activate :: proc "c" (self: objc_id, cmd: SEL, center: objc_id, notif: objc_id) {
	context = runtime.default_context()
	tag: u64
	if info := msg0(notif, sel("userInfo")); info != nil {
		if num := msg1(info, sel("objectForKey:"), nsstring("tag")); num != nil {
			tag = msg_u64(num, sel("unsignedLongLongValue"))
		}
	}
	if tag != 0 {
		push_notif_event(&D.ev, tag)
	} else {
		D.ev.show = true
	}
}

// Banner auch zeigen, wenn die App vorne ist (wir filtern selbst nach Fokus).
@(private = "file")
imp_should_present :: proc "c" (self: objc_id, cmd: SEL, center: objc_id, notif: objc_id) -> u8 {
	return 1
}

// Dock-Icon-Klick bei verstecktem Fenster → wieder öffnen (Slack-Verhalten).
// Wird der GLFW-App-Delegate-Klasse zur Laufzeit hinzugefügt.
@(private = "file")
imp_reopen :: proc "c" (self: objc_id, cmd: SEL, app: objc_id, has_windows: u8) -> u8 {
	D.ev.show = true
	return 1
}

tray_init :: proc(spec: Tray_Spec) -> bool {
	if D.inited {
		return true
	}
	count, ok := dynlib.initialize_symbols(&O, "/usr/lib/libobjc.A.dylib")
	if !ok || count <= 0 || O.objc_msgSend == nil || O.objc_getClass == nil {
		return false
	}
	// AppKit/Foundation sind über raylib (Cocoa) ohnehin geladen; die
	// Handles brauchen wir nur für die Sound-Konstante.
	fnd, fnd_ok := dynlib.load_library("/System/Library/Frameworks/Foundation.framework/Foundation")
	if fnd_ok {
		if ptr, found := dynlib.symbol_address(fnd, "NSUserNotificationDefaultSoundName"); found {
			D.sound = (^objc_id)(ptr)^
		}
	}

	nsapp := msg0(cls("NSApplication"), sel("sharedApplication"))

	// Target-Klasse registrieren (Menü-Actions + Notification-Delegate)
	tc := O.objc_allocateClassPair(cls("NSObject"), "FFTrayTarget", 0)
	if tc != nil {
		O.class_addMethod(tc, sel("ffOpen:"), rawptr(imp_open), "v@:@")
		O.class_addMethod(tc, sel("ffQuit:"), rawptr(imp_quit), "v@:@")
		O.class_addMethod(tc, sel("userNotificationCenter:didActivateNotification:"),
			rawptr(imp_did_activate), "v@:@@")
		O.class_addMethod(tc, sel("userNotificationCenter:shouldPresentNotification:"),
			rawptr(imp_should_present), "c@:@@")
		O.objc_registerClassPair(tc)
		D.target = msg0(msg0(objc_id(tc), sel("alloc")), sel("init"))
	}
	if D.target == nil {
		return false
	}

	bar := msg0(cls("NSStatusBar"), sel("systemStatusBar"))
	item := msg_f(bar, sel("statusItemWithLength:"), -1) // NSVariableStatusItemLength
	if item == nil {
		return false
	}
	msg0(item, sel("retain"))
	D.item = item

	D.img = image_from_png(spec.png)
	D.img_unread = image_from_png(spec.png_unread)
	if D.img_unread == nil {
		D.img_unread = D.img
	}
	D.button = msg0(item, sel("button"))
	if D.button != nil && D.img != nil {
		msg1(D.button, sel("setImage:"), D.img)
	}

	title := spec.title != "" ? spec.title : "Flurfunk"
	menu := msg0(msg0(cls("NSMenu"), sel("alloc")), sel("init"))
	add_menu_item(menu, fmt.tprintf("%s öffnen", title), "ffOpen:")
	msg1(menu, sel("addItem:"), msg0(cls("NSMenuItem"), sel("separatorItem")))
	add_menu_item(menu, "Beenden", "ffQuit:")
	msg1(item, sel("setMenu:"), menu)

	// Benachrichtigungen gibt es nur mit App-Bundle (Release-Build) —
	// beim nackten Binary bleibt center nil und notify liefert false.
	D.center = msg0(cls("NSUserNotificationCenter"), sel("defaultUserNotificationCenter"))
	if D.center != nil {
		msg1(D.center, sel("setDelegate:"), D.target)
	}

	// Reopen-Handler auf den GLFW-App-Delegate nachrüsten
	if delegate := msg0(nsapp, sel("delegate")); delegate != nil {
		O.class_addMethod(O.object_getClass(delegate),
			sel("applicationShouldHandleReopen:hasVisibleWindows:"),
			rawptr(imp_reopen), "c@:@c")
	}

	D.inited = true
	return true
}

@(private = "file")
add_menu_item :: proc(menu: objc_id, label: string, action: cstring) {
	item := msg3(msg0(cls("NSMenuItem"), sel("alloc")),
		sel("initWithTitle:action:keyEquivalent:"),
		nsstring(label), rawptr(O.sel_registerName(action)), nsstring(""))
	if item == nil {
		return
	}
	msg1(item, sel("setTarget:"), D.target)
	msg1(menu, sel("addItem:"), item)
}

// Menüleisten-Icon ist immer da, sobald init geklappt hat.
tray_available :: proc() -> bool {
	return D.inited
}

tray_set_unread :: proc(unread: bool) {
	if !D.inited || D.unread == unread {
		return
	}
	D.unread = unread
	if D.button != nil {
		img := unread ? D.img_unread : D.img
		if img != nil {
			msg1(D.button, sel("setImage:"), img)
		}
	}
}

tray_poll :: proc() -> Events {
	if !D.inited {
		return {}
	}
	ev := D.ev
	D.ev = {}
	return ev
}

tray_shutdown :: proc() {
	if !D.inited {
		return
	}
	if D.item != nil {
		bar := msg0(cls("NSStatusBar"), sel("systemStatusBar"))
		msg1(bar, sel("removeStatusItem:"), D.item)
	}
	D.inited = false
}

notify :: proc(tag: u64, title, body: string, kind: Notify_Kind) -> bool {
	if !D.inited || D.center == nil {
		return false
	}
	n := msg0(msg0(cls("NSUserNotification"), sel("alloc")), sel("init"))
	if n == nil {
		return false
	}
	msg1(n, sel("setTitle:"), nsstring(title))
	msg1(n, sel("setInformativeText:"), nsstring(body))
	if D.sound != nil {
		msg1(n, sel("setSoundName:"), D.sound)
	}
	num := msg_1u64(cls("NSNumber"), sel("numberWithUnsignedLongLong:"), tag)
	dict := msg2(cls("NSDictionary"), sel("dictionaryWithObject:forKey:"),
		num, nsstring("tag"))
	msg1(n, sel("setUserInfo:"), dict)
	msg1(D.center, sel("deliverNotification:"), n)
	msg0(n, sel("release"))
	return true
}
