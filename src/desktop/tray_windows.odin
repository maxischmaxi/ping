#+build windows
package desktop

// Windows backend: Shell_NotifyIcon (Tray-Icon + Balloon-/Toast-
// Benachrichtigungen) über ein unsichtbares Message-Only-Fenster. Der
// Message-Pump läuft in tray_poll (Main-Thread, pro Frame).

import "base:runtime"
import win32 "core:sys/windows"

@(private = "file") WM_TRAY_CB :: u32(win32.WM_APP + 1)
@(private = "file") NIN_BALLOONUSERCLICK :: win32.LPARAM(0x0405) // WM_USER+5

@(private = "file") NIM_ADD :: u32(0)
@(private = "file") NIM_MODIFY :: u32(1)
@(private = "file") NIM_DELETE :: u32(2)
@(private = "file") NIF_MESSAGE :: u32(0x01)
@(private = "file") NIF_ICON :: u32(0x02)
@(private = "file") NIF_TIP :: u32(0x04)
@(private = "file") NIF_INFO :: u32(0x10)
@(private = "file") NIIF_USER :: u32(0x04)
@(private = "file") NIIF_LARGE_ICON :: u32(0x20)

@(private = "file") CMD_OPEN :: u32(1)
@(private = "file") CMD_QUIT :: u32(2)

@(private = "file")
NOTIFYICONDATAW :: struct {
	cbSize:           u32,
	hWnd:             win32.HWND,
	uID:              u32,
	uFlags:           u32,
	uCallbackMessage: u32,
	hIcon:            win32.HICON,
	szTip:            [128]u16,
	dwState:          u32,
	dwStateMask:      u32,
	szInfo:           [256]u16,
	uVersion:         u32, // union {uTimeout, uVersion}
	szInfoTitle:      [64]u16,
	dwInfoFlags:      u32,
	guidItem:         win32.GUID,
	hBalloonIcon:     win32.HICON,
}

@(private = "file")
ICONINFO :: struct {
	fIcon:    win32.BOOL,
	xHotspot: u32,
	yHotspot: u32,
	hbmMask:  win32.HBITMAP,
	hbmColor: win32.HBITMAP,
}

foreign import shell32 "system:Shell32.lib"

@(default_calling_convention = "system")
foreign shell32 {
	Shell_NotifyIconW :: proc(dwMessage: u32, lpData: ^NOTIFYICONDATAW) -> win32.BOOL ---
}

foreign import gdi32_x "system:Gdi32.lib"

@(default_calling_convention = "system")
foreign gdi32_x {
	@(link_name = "CreateBitmap")
	gdi_CreateBitmap :: proc(w, h: i32, planes, bpp: u32, bits: rawptr) -> win32.HBITMAP ---
	@(link_name = "DeleteObject")
	gdi_DeleteObject :: proc(obj: win32.HGDIOBJ) -> win32.BOOL ---
}

foreign import user32_x "system:User32.lib"

@(default_calling_convention = "system")
foreign user32_x {
	CreateIconIndirect :: proc(info: ^ICONINFO) -> win32.HICON ---
	DestroyIcon        :: proc(icon: win32.HICON) -> win32.BOOL ---
}

@(private = "file")
W: struct {
	ok:          bool,
	hwnd:        win32.HWND,
	icon:        win32.HICON, // 32 px normal
	icon_unread: win32.HICON,
	icon_big:    win32.HICON, // größtes Icon für Balloons
	tip:         [128]u16,
	unread:      bool,
	ev:          Events,
	last_tag:    u64, // Windows zeigt höchstens einen Balloon zugleich
}

@(private = "file")
hicon_from_rgba :: proc(icon: Tray_Icon) -> win32.HICON {
	if icon.w <= 0 || icon.h <= 0 || len(icon.rgba) < icon.w*icon.h*4 {
		return nil
	}
	bgra := make([]u8, icon.w*icon.h*4, context.temp_allocator)
	for i in 0 ..< icon.w*icon.h {
		bgra[i*4+0] = icon.rgba[i*4+2]
		bgra[i*4+1] = icon.rgba[i*4+1]
		bgra[i*4+2] = icon.rgba[i*4+0]
		bgra[i*4+3] = icon.rgba[i*4+3]
	}
	color := gdi_CreateBitmap(i32(icon.w), i32(icon.h), 1, 32, raw_data(bgra))
	if color == nil {
		return nil
	}
	defer gdi_DeleteObject(win32.HGDIOBJ(color))
	// 1-bpp-AND-Maske (Zeilen WORD-aligned), bei 32-bpp-Alpha nur Formsache
	stride := ((icon.w + 15) / 16) * 2
	mask_bits := make([]u8, stride*icon.h, context.temp_allocator)
	mask := gdi_CreateBitmap(i32(icon.w), i32(icon.h), 1, 1, raw_data(mask_bits))
	if mask == nil {
		return nil
	}
	defer gdi_DeleteObject(win32.HGDIOBJ(mask))
	ii := ICONINFO{fIcon = true, hbmMask = mask, hbmColor = color}
	return CreateIconIndirect(&ii)
}

@(private = "file")
utf16_copy :: proc(dst: []u16, s: string) {
	tmp := win32.utf8_to_utf16(s, context.temp_allocator)
	n := min(len(tmp), len(dst) - 1)
	copy(dst[:n], tmp[:n])
	dst[n] = 0
}

@(private = "file")
base_nid :: proc() -> NOTIFYICONDATAW {
	nid: NOTIFYICONDATAW
	nid.cbSize = size_of(NOTIFYICONDATAW)
	nid.hWnd = W.hwnd
	nid.uID = 1
	return nid
}

@(private = "file")
tray_wndproc :: proc "system" (hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	if msg == WM_TRAY_CB {
		context = runtime.default_context()
		switch lparam {
		case win32.LPARAM(win32.WM_LBUTTONUP):
			W.ev.toggle = true
		case win32.LPARAM(win32.WM_RBUTTONUP), win32.LPARAM(win32.WM_CONTEXTMENU):
			show_menu()
		case NIN_BALLOONUSERCLICK:
			push_notif_event(&W.ev, W.last_tag)
		}
		return 0
	}
	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

@(private = "file")
show_menu :: proc() {
	menu := win32.CreatePopupMenu()
	if menu == nil {
		return
	}
	defer win32.DestroyMenu(menu)
	open_w := win32.utf8_to_wstring("Flurfunk öffnen", context.temp_allocator)
	quit_w := win32.utf8_to_wstring("Beenden", context.temp_allocator)
	win32.AppendMenuW(menu, win32.MF_STRING, uintptr(CMD_OPEN), open_w)
	win32.AppendMenuW(menu, win32.MF_SEPARATOR, 0, nil)
	win32.AppendMenuW(menu, win32.MF_STRING, uintptr(CMD_QUIT), quit_w)

	pt: win32.POINT
	win32.GetCursorPos(&pt)
	// Pflicht laut MSDN, sonst schließt das Menü nicht beim Klick daneben
	win32.SetForegroundWindow(W.hwnd)
	cmd := win32.TrackPopupMenu(menu,
		win32.TPM_RIGHTBUTTON | win32.TPM_RETURNCMD | win32.TPM_NONOTIFY,
		pt.x, pt.y, 0, W.hwnd, nil)
	switch u32(cmd) {
	case CMD_OPEN:
		W.ev.show = true
	case CMD_QUIT:
		W.ev.quit = true
	}
	win32.PostMessageW(W.hwnd, win32.WM_NULL, 0, 0)
}

tray_init :: proc(spec: Tray_Spec) -> bool {
	if W.ok {
		return true
	}
	inst := win32.HINSTANCE(win32.GetModuleHandleW(nil))
	class_name := win32.wstring(win32.L("FlurfunkTray"))
	wc: win32.WNDCLASSW
	wc.lpfnWndProc = tray_wndproc
	wc.hInstance = inst
	wc.lpszClassName = class_name
	win32.RegisterClassW(&wc)

	// Message-only-Fenster (Parent HWND_MESSAGE = -3)
	HWND_MESSAGE := win32.HWND(uintptr(max(uintptr) - 2))
	W.hwnd = win32.CreateWindowExW(0, class_name, nil, 0, 0, 0, 0, 0,
		HWND_MESSAGE, nil, inst, nil)
	if W.hwnd == nil {
		return false
	}

	// Icons: 32 px für den Tray, das größte für Balloons
	pick :: proc(icons: []Tray_Icon) -> (small, big: Tray_Icon) {
		for icon in icons {
			if small.w == 0 || abs(icon.w - 32) < abs(small.w - 32) {
				small = icon
			}
			if icon.w > big.w {
				big = icon
			}
		}
		return
	}
	small, big := pick(spec.icons)
	small_u, _ := pick(spec.icons_unread)
	W.icon = hicon_from_rgba(small)
	W.icon_unread = hicon_from_rgba(small_u)
	W.icon_big = hicon_from_rgba(big)
	if W.icon == nil {
		return false
	}
	if W.icon_unread == nil {
		W.icon_unread = W.icon
	}

	title := spec.title != "" ? spec.title : "Flurfunk"
	utf16_copy(W.tip[:], title)

	nid := base_nid()
	nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP
	nid.uCallbackMessage = WM_TRAY_CB
	nid.hIcon = W.icon
	nid.szTip = W.tip
	if Shell_NotifyIconW(NIM_ADD, &nid) == win32.FALSE {
		return false
	}
	W.ok = true
	return true
}

tray_available :: proc() -> bool {
	return W.ok
}

tray_set_unread :: proc(unread: bool) {
	if !W.ok || W.unread == unread {
		return
	}
	W.unread = unread
	nid := base_nid()
	nid.uFlags = NIF_ICON
	nid.hIcon = unread ? W.icon_unread : W.icon
	Shell_NotifyIconW(NIM_MODIFY, &nid)
}

tray_poll :: proc() -> Events {
	if !W.ok {
		return {}
	}
	msg: win32.MSG
	for win32.PeekMessageW(&msg, W.hwnd, 0, 0, win32.PM_REMOVE) {
		win32.TranslateMessage(&msg)
		win32.DispatchMessageW(&msg)
	}
	ev := W.ev
	W.ev = {}
	return ev
}

tray_shutdown :: proc() {
	if !W.ok {
		return
	}
	nid := base_nid()
	Shell_NotifyIconW(NIM_DELETE, &nid)
	win32.DestroyWindow(W.hwnd)
	if W.icon != nil {
		DestroyIcon(W.icon)
	}
	if W.icon_unread != nil && W.icon_unread != W.icon {
		DestroyIcon(W.icon_unread)
	}
	if W.icon_big != nil {
		DestroyIcon(W.icon_big)
	}
	W.ok = false
}

// Balloon-Notification (ab Windows 10 als Toast dargestellt).
notify :: proc(tag: u64, title, body: string, kind: Notify_Kind) -> bool {
	if !W.ok {
		return false
	}
	nid := base_nid()
	nid.uFlags = NIF_INFO
	utf16_copy(nid.szInfoTitle[:], title)
	utf16_copy(nid.szInfo[:], body)
	nid.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON
	nid.hBalloonIcon = W.icon_big
	W.last_tag = tag
	return Shell_NotifyIconW(NIM_MODIFY, &nid) == win32.TRUE
}
