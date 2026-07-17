package main

// Profilbilder: Upload (base64-PNG), Abruf und Löschen. Der Server dekodiert
// das PNG nicht — er prüft Magic + IHDR (Maße) + Größenlimit und legt die
// Datei verschlüsselt ab (storage.odin). Jede Änderung bumpt User.avatar_ver
// und geht als EV_USER an alle.

import "core:encoding/base64"
import "core:fmt"

import shared "../shared"

handle_avatar_set :: proc(c: ^Client_Conn, w: shared.Wire) {
	u := find_user_by_id(c.user_id)
	if u == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	// base64 wächst um 4/3 — grob vorprüfen, bevor dekodiert wird.
	if len(w.data) == 0 || len(w.data) > shared.AVATAR_MAX_BYTES * 4 / 3 + 8 {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	png, derr := base64.decode(w.data, base64.DEC_TABLE, nil, context.temp_allocator)
	if derr != nil || len(png) == 0 || len(png) > shared.AVATAR_MAX_BYTES {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	pw, ph, pok := shared.png_dims(png)
	if !pok || pw != ph || pw < shared.AVATAR_MIN_DIM || pw > shared.AVATAR_MAX_DIM {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	if !save_avatar(u.id, png) {
		fmt.printfln("[error] Avatar von User %d konnte nicht gespeichert werden", u.id)
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	u.avatar_max += 1
	u.avatar_ver = u.avatar_max
	save_users()

	resp := shared.wire_ok(w.kind, w.seq)
	resp.user = wire_user(u)
	send_to(c, resp)

	ev := shared.Wire{kind = shared.EV_USER, user = wire_user(u)}
	broadcast_authed(ev, c)
	fmt.printfln("[avatar] User %d: Profilbild gesetzt (v%d, %d Bytes)", u.id, u.avatar_ver, len(png))
}

handle_avatar_delete :: proc(c: ^Client_Conn, w: shared.Wire) {
	u := find_user_by_id(c.user_id)
	if u == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if u.avatar_ver != 0 {
		delete_avatar_file(u.id)
		u.avatar_ver = 0
		save_users()
		ev := shared.Wire{kind = shared.EV_USER, user = wire_user(u)}
		broadcast_authed(ev, c)
		fmt.printfln("[avatar] User %d: Profilbild entfernt", u.id)
	}
	resp := shared.wire_ok(w.kind, w.seq)
	resp.user = wire_user(u)
	send_to(c, resp)
}

handle_avatar_get :: proc(c: ^Client_Conn, w: shared.Wire) {
	u := find_user_by_id(w.user_id)
	if u == nil || u.avatar_ver == 0 {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	png, ok := load_avatar(u.id)
	if !ok {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	resp := shared.wire_ok(w.kind, w.seq)
	resp.user_id = u.id
	resp.user = wire_user(u)
	resp.data = base64.encode(png, base64.ENC_TABLE, context.temp_allocator)
	send_to(c, resp)
}
