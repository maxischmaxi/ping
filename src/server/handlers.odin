package main

// Protokoll-Handler. handle_wire hält für die gesamte Bearbeitung eines
// Requests den globalen Lock; Antworten und Events werden darunter
// verschickt (Secure_Conn.wmu macht Writes an fremde Verbindungen sicher).

import "core:crypto"
import "core:crypto/argon2id"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import "core:sync"

import shared "../shared"

// Argon2id-Parameter laut Vorgabe.
ARGON_PARAMS := argon2id.Parameters{
	memory_size = 64 * 1024, // 64 MiB
	passes      = 3,
	parallelism = 1,
}

hash_password :: proc(password: string, salt: []byte, dst: []byte) -> bool {
	err := argon2id.derive(&ARGON_PARAMS, transmute([]byte)password, salt, dst)
	return err == nil
}

// Neues Session-Token: 32 Zufallsbytes als Hex (langlebig alloziert).
new_token :: proc() -> string {
	raw: [32]byte
	crypto.rand_bytes(raw[:])
	return string(hex.encode(raw[:]))
}

send_err :: proc(c: ^Client_Conn, kind: string, seq: u64, code: string) {
	send_to(c, shared.wire_err(kind, seq, code))
}

// Zentrale Dispatch-Funktion für eine empfangene Wire-Nachricht.
handle_wire :: proc(c: ^Client_Conn, w: shared.Wire) {
	sync.lock(&g.mu)
	defer sync.unlock(&g.mu)

	// Unauthentifiziert sind nur server_info, register, login, resume erlaubt.
	switch w.kind {
	case shared.K_SERVER_INFO:
		handle_server_info(c, w)
	case shared.K_REGISTER:
		handle_register(c, w)
	case shared.K_LOGIN:
		handle_login(c, w)
	case shared.K_RESUME:
		handle_resume(c, w)
	case:
		if !c.authed {
			send_err(c, w.kind, w.seq, "not_authenticated")
			return
		}
		switch w.kind {
		case shared.K_PING:
			send_to(c, shared.wire_ok(w.kind, w.seq)) // Latenz-Echo
		case shared.K_SETUP:
			handle_setup(c, w)
		case shared.K_LIST_USERS:
			handle_list_users(c, w)
		case shared.K_LIST_CHANNELS:
			handle_list_channels(c, w)
		case shared.K_CREATE_CHANNEL:
			handle_create_channel(c, w)
		case shared.K_DELETE_CHANNEL:
			handle_delete_channel(c, w)
		case shared.K_INVITE:
			handle_invite(c, w)
		case shared.K_KICK:
			handle_kick(c, w)
		case shared.K_LEAVE:
			handle_leave(c, w)
		case shared.K_OPEN_DM:
			handle_open_dm(c, w)
		case shared.K_SEND:
			handle_send(c, w)
		case shared.K_HISTORY:
			handle_history(c, w)
		case shared.K_EDIT_START:
			handle_edit_start(c, w)
		case shared.K_EDIT_CANCEL:
			handle_edit_cancel(c, w)
		case shared.K_EDIT_MESSAGE:
			handle_edit_message(c, w)
		case shared.K_MESSAGE_HISTORY:
			handle_message_history(c, w)
		case shared.K_CALL_JOIN:
			handle_call_join(c, w)
		case shared.K_CALL_LEAVE:
			handle_call_leave(c, w)
		case shared.K_CALL_MUTE:
			handle_call_mute(c, w)
		case:
			send_err(c, w.kind, w.seq, "invalid_request")
		}
	}
}

// ---------- Auth ----------

handle_server_info :: proc(c: ^Client_Conn, w: shared.Wire) {
	resp := shared.wire_ok(w.kind, w.seq)
	resp.server_name = g.meta.server_name
	resp.initialized = g.meta.initialized
	resp.setup_needed = !g.meta.initialized
	send_to(c, resp)
}

// Gemeinsame Erfolgs-Antwort für register/login/resume + Presence-Event.
auth_success :: proc(c: ^Client_Conn, kind: string, seq: u64, u: ^User, token: string) {
	c.authed = true
	c.user_id = u.id

	resp := shared.wire_ok(kind, seq)
	resp.token = token
	resp.user = wire_user(u)
	resp.server_name = g.meta.server_name
	resp.initialized = g.meta.initialized
	resp.setup_needed = u.is_admin && !g.meta.initialized
	send_to(c, resp)

	// Presence: User ist (jetzt) online.
	ev := shared.Wire{kind = shared.EV_USER, user = wire_user(u)}
	broadcast_authed(ev, c)
}

handle_register :: proc(c: ^Client_Conn, w: shared.Wire) {
	username := strings.trim_space(w.username)
	if !shared.valid_username(username) || len(w.password) < shared.MIN_PASSWORD_LEN {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	if find_user_by_name(username) != nil {
		send_err(c, w.kind, w.seq, "username_taken")
		return
	}

	u := User{
		id           = g.meta.next_user_id,
		username     = strings.clone(username),
		display_name = strings.clone(strings.trim_space(w.display_name)),
		is_admin     = len(g.users) == 0, // erster User überhaupt wird Admin
	}
	crypto.rand_bytes(u.salt[:])
	if !hash_password(w.password, u.salt[:], u.pass_hash[:]) {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	g.meta.next_user_id += 1
	append(&g.users, u)

	token := new_token()
	append(&g.sessions, Session{token = token, user_id = u.id, created_ms = now_ms()})

	save_users()
	save_sessions()
	save_meta()

	fmt.printfln("[auth] neuer User %q (id=%d, admin=%v)", u.username, u.id, u.is_admin)
	auth_success(c, w.kind, w.seq, find_user_by_id(u.id), token)
}

handle_login :: proc(c: ^Client_Conn, w: shared.Wire) {
	u := find_user_by_name(strings.trim_space(w.username))
	if u == nil {
		send_err(c, w.kind, w.seq, "invalid_credentials")
		return
	}
	probe: [HASH_LEN]byte
	if !hash_password(w.password, u.salt[:], probe[:]) ||
	   crypto.compare_constant_time(probe[:], u.pass_hash[:]) != 1 {
		send_err(c, w.kind, w.seq, "invalid_credentials")
		return
	}

	token := new_token()
	append(&g.sessions, Session{token = token, user_id = u.id, created_ms = now_ms()})
	save_sessions()

	fmt.printfln("[auth] Login %q (id=%d)", u.username, u.id)
	auth_success(c, w.kind, w.seq, u, token)
}

handle_resume :: proc(c: ^Client_Conn, w: shared.Wire) {
	s := find_session(w.token)
	if s == nil {
		send_err(c, w.kind, w.seq, "invalid_token")
		return
	}
	u := find_user_by_id(s.user_id)
	if u == nil {
		send_err(c, w.kind, w.seq, "invalid_token")
		return
	}
	fmt.printfln("[auth] Resume %q (id=%d)", u.username, u.id)
	auth_success(c, w.kind, w.seq, u, s.token)
}

// ---------- Setup / Listen ----------

handle_setup :: proc(c: ^Client_Conn, w: shared.Wire) {
	u := find_user_by_id(c.user_id)
	if u == nil || !u.is_admin {
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}
	name := strings.trim_space(w.server_name)
	if len(name) < 1 || len(name) > 64 {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	g.meta.server_name = strings.clone(name)
	g.meta.initialized = true
	save_meta()

	resp := shared.wire_ok(w.kind, w.seq)
	resp.server_name = g.meta.server_name
	send_to(c, resp)

	// Alle authentifizierten Verbindungen bekommen den neuen Namen.
	ev := shared.Wire{kind = shared.EV_SERVER, server_name = g.meta.server_name}
	broadcast_authed(ev, nil)

	fmt.printfln("[setup] Servername gesetzt: %q", g.meta.server_name)
}

handle_list_users :: proc(c: ^Client_Conn, w: shared.Wire) {
	users := make([dynamic]shared.User, 0, len(g.users), context.temp_allocator)
	for &u in g.users {
		append(&users, wire_user(&u))
	}
	resp := shared.wire_ok(w.kind, w.seq)
	resp.users = users[:]
	send_to(c, resp)
}

handle_list_channels :: proc(c: ^Client_Conn, w: shared.Wire) {
	channels := make([dynamic]shared.Channel, context.temp_allocator)
	for &ch in g.channels {
		if is_member(&ch, c.user_id) {
			append(&channels, wire_channel(&ch))
		}
	}
	resp := shared.wire_ok(w.kind, w.seq)
	resp.channels = channels[:]
	resp.calls = calls_for_user(c.user_id) // laufende Calls für Banner nach Login
	send_to(c, resp)
}

// ---------- Channels ----------

handle_create_channel :: proc(c: ^Client_Conn, w: shared.Wire) {
	name := strings.trim_space(w.name)
	if !shared.valid_channel_name(name) {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	for &other in g.channels {
		if !other.is_dm && other.name == name {
			send_err(c, w.kind, w.seq, "name_taken")
			return
		}
	}

	ch := Channel{
		id         = g.meta.next_channel_id,
		name       = strings.clone(name),
		creator_id = c.user_id,
	}
	g.meta.next_channel_id += 1
	crypto.rand_bytes(ch.key[:]) // frischer Channel-Key
	append(&ch.member_ids, c.user_id)
	append(&g.channels, ch)

	save_channels()
	save_meta()

	pch := &g.channels[len(g.channels) - 1]
	resp := shared.wire_ok(w.kind, w.seq)
	resp.channel = wire_channel(pch)
	send_to(c, resp)

	fmt.printfln("[channel] %q (id=%d) von User %d erstellt", pch.name, pch.id, c.user_id)
}

handle_delete_channel :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := find_channel(w.channel_id)
	if ch == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if ch.is_dm {
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}
	caller := find_user_by_id(c.user_id)
	if caller == nil || (ch.creator_id != c.user_id && !caller.is_admin) {
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}

	// Erst benachrichtigen (solange ch und die Mitgliederliste gültig sind).
	send_to(c, shared.wire_ok(w.kind, w.seq))
	ev := shared.Wire{kind = shared.EV_CHANNEL_REMOVED, channel_id = ch.id, err = "deleted"}
	broadcast_members(ch, ev, c)

	fmt.printfln("[channel] %q (id=%d) von User %d gelöscht", ch.name, ch.id, c.user_id)

	// Dann Zustand + Persistenz aufräumen (inkl. verschlüsseltem Message-Log).
	delete_message_log(ch.id)
	for &other, idx in g.channels {
		if other.id == ch.id {
			delete(other.name)
			delete(other.member_ids)
			ordered_remove(&g.channels, idx)
			break
		}
	}
	save_channels()
}

handle_invite :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := find_channel(w.channel_id)
	if ch == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if ch.is_dm {
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}
	if !is_member(ch, c.user_id) {
		send_err(c, w.kind, w.seq, "not_a_member")
		return
	}
	if find_user_by_id(w.user_id) == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if is_member(ch, w.user_id) {
		send_err(c, w.kind, w.seq, "already_member")
		return
	}

	append(&ch.member_ids, w.user_id)
	save_channels()

	resp := shared.wire_ok(w.kind, w.seq)
	resp.channel = wire_channel(ch)
	send_to(c, resp)

	// Alle Mitglieder (inkl. Eingeladenem, exkl. aufrufender Verbindung).
	ev := shared.Wire{kind = shared.EV_CHANNEL, channel = wire_channel(ch)}
	broadcast_members(ch, ev, c)
}

handle_kick :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := find_channel(w.channel_id)
	if ch == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if ch.is_dm {
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}
	caller := find_user_by_id(c.user_id)
	if caller == nil || (ch.creator_id != c.user_id && !caller.is_admin) {
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}
	if w.user_id == ch.creator_id {
		// der Ersteller kann nicht gekickt werden
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}
	if !is_member(ch, w.user_id) {
		send_err(c, w.kind, w.seq, "not_a_member")
		return
	}

	remove_member(ch, w.user_id)
	save_channels()

	resp := shared.wire_ok(w.kind, w.seq)
	resp.channel = wire_channel(ch)
	send_to(c, resp)

	// Der Gekickte verliert den Channel, der Rest sieht die neue Mitgliederliste.
	ev_rm := shared.Wire{kind = shared.EV_CHANNEL_REMOVED, channel_id = ch.id}
	broadcast_user(w.user_id, ev_rm, nil)
	ev := shared.Wire{kind = shared.EV_CHANNEL, channel = wire_channel(ch)}
	broadcast_members(ch, ev, c)
}

handle_leave :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := find_channel(w.channel_id)
	if ch == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if ch.is_dm {
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}
	if !is_member(ch, c.user_id) {
		send_err(c, w.kind, w.seq, "not_a_member")
		return
	}

	remove_member(ch, c.user_id)
	save_channels()

	send_to(c, shared.wire_ok(w.kind, w.seq))

	// Verbleibende Mitglieder sehen die neue Mitgliederliste.
	ev := shared.Wire{kind = shared.EV_CHANNEL, channel = wire_channel(ch)}
	broadcast_members(ch, ev, c)
}

handle_open_dm :: proc(c: ^Client_Conn, w: shared.Wire) {
	if w.user_id == c.user_id {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	if find_user_by_id(w.user_id) == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}

	// Existierenden DM mit exakt diesen beiden Mitgliedern wiederverwenden.
	for &other in g.channels {
		if other.is_dm && len(other.member_ids) == 2 &&
		   is_member(&other, c.user_id) && is_member(&other, w.user_id) {
			resp := shared.wire_ok(w.kind, w.seq)
			resp.channel = wire_channel(&other)
			send_to(c, resp)
			return
		}
	}

	ch := Channel{
		id         = g.meta.next_channel_id,
		is_dm      = true, // name bleibt leer
		creator_id = c.user_id,
	}
	g.meta.next_channel_id += 1
	crypto.rand_bytes(ch.key[:])
	append(&ch.member_ids, c.user_id)
	append(&ch.member_ids, w.user_id)
	append(&g.channels, ch)

	save_channels()
	save_meta()

	pch := &g.channels[len(g.channels) - 1]
	resp := shared.wire_ok(w.kind, w.seq)
	resp.channel = wire_channel(pch)
	send_to(c, resp)

	// Der andere User erfährt vom neuen DM.
	ev := shared.Wire{kind = shared.EV_CHANNEL, channel = wire_channel(pch)}
	broadcast_user(w.user_id, ev, c)
}

// ---------- Nachrichten ----------

handle_send :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := find_channel(w.channel_id)
	if ch == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if !is_member(ch, c.user_id) {
		send_err(c, w.kind, w.seq, "not_a_member")
		return
	}
	text := strings.trim_space(w.text)
	if len(text) == 0 || len(text) > shared.MAX_MESSAGE_TEXT_LEN {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}

	msg := shared.Chat_Message{
		id         = g.meta.next_message_id,
		channel_id = ch.id,
		author_id  = c.user_id,
		ts_ms      = now_ms(),
		text       = text,
	}
	g.meta.next_message_id += 1

	if !store_message(ch, msg) {
		fmt.printfln("[error] Nachricht %d (Channel %d) konnte nicht gespeichert werden", msg.id, ch.id)
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	save_meta()

	resp := shared.wire_ok(w.kind, w.seq)
	resp.message = msg
	send_to(c, resp)

	// Alle anderen authentifizierten Verbindungen von Mitgliedern
	// (auch weitere Verbindungen desselben Users).
	ev := shared.Wire{kind = shared.EV_MESSAGE, message = msg}
	broadcast_members(ch, ev, c)
}

handle_history :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := find_channel(w.channel_id)
	if ch == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if !is_member(ch, c.user_id) {
		send_err(c, w.kind, w.seq, "not_a_member")
		return
	}

	limit := w.limit
	if limit == 0 {
		limit = 50
	}
	limit = clamp(limit, 1, shared.HISTORY_MAX_LIMIT)

	resp := shared.wire_ok(w.kind, w.seq)
	resp.messages = load_history(ch, w.before_id, limit)
	resp.channel_id = ch.id
	send_to(c, resp)
}

// ---------- Nachrichten bearbeiten ----------

// Channel + Mitgliedschaft prüfen (gemeinsamer Vorspann der Edit-Handler).
@(private = "file")
edit_channel_of :: proc(c: ^Client_Conn, w: shared.Wire) -> ^Channel {
	ch := find_channel(w.channel_id)
	if ch == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return nil
	}
	if !is_member(ch, c.user_id) {
		send_err(c, w.kind, w.seq, "not_a_member")
		return nil
	}
	return ch
}

// Bearbeitungsmodus betreten: prüft Autor, Limit und die 1-Minuten-Frist
// (ab Original bzw. letztem Edit) und reserviert die Freigabe. Ab jetzt
// darf beliebig lange getippt werden — die Frist gilt nur für den Einstieg.
handle_edit_start :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := edit_channel_of(c, w)
	if ch == nil {
		return
	}
	msg, ok := load_message(ch, w.message_id)
	if !ok {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if msg.author_id != c.user_id || msg.call_start_ms > 0 {
		// Call-Systemnachrichten pflegt ausschließlich der Server.
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}
	if msg.edit_count >= shared.MAX_MESSAGE_EDITS {
		send_err(c, w.kind, w.seq, "edit_limit")
		return
	}
	base := msg.edited_ms > 0 ? msg.edited_ms : msg.ts_ms
	if now_ms() - base > shared.EDIT_WINDOW_MS {
		send_err(c, w.kind, w.seq, "edit_window")
		return
	}

	g.open_edits[w.message_id] = c.user_id
	send_to(c, shared.wire_ok(w.kind, w.seq))
}

handle_edit_cancel :: proc(c: ^Client_Conn, w: shared.Wire) {
	if g.open_edits[w.message_id] == c.user_id {
		delete_key(&g.open_edits, w.message_id)
	}
	send_to(c, shared.wire_ok(w.kind, w.seq))
}

handle_edit_message :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := edit_channel_of(c, w)
	if ch == nil {
		return
	}
	text := strings.trim_space(w.text)
	if len(text) == 0 || len(text) > shared.MAX_MESSAGE_TEXT_LEN {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	// Commit nur mit offener Freigabe (edit_start) — sie kodiert, dass der
	// Einstieg innerhalb der Frist passiert ist.
	if uid, has := g.open_edits[w.message_id]; !has || uid != c.user_id {
		send_err(c, w.kind, w.seq, "edit_window")
		return
	}
	msg, ok := load_message(ch, w.message_id)
	if !ok {
		delete_key(&g.open_edits, w.message_id)
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if msg.author_id != c.user_id || msg.call_start_ms > 0 {
		send_err(c, w.kind, w.seq, "not_allowed")
		return
	}
	if msg.edit_count >= shared.MAX_MESSAGE_EDITS {
		delete_key(&g.open_edits, w.message_id)
		send_err(c, w.kind, w.seq, "edit_limit")
		return
	}

	now := now_ms()
	if !store_edit(ch, msg.id, text, now) {
		fmt.printfln("[error] Edit von Nachricht %d (Channel %d) konnte nicht gespeichert werden", msg.id, ch.id)
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	delete_key(&g.open_edits, w.message_id)

	msg.text = text
	msg.edited_ms = now
	msg.edit_count += 1

	resp := shared.wire_ok(w.kind, w.seq)
	resp.message = msg
	send_to(c, resp)

	ev := shared.Wire{kind = shared.EV_MESSAGE_EDITED, message = msg}
	broadcast_members(ch, ev, c)

	fmt.printfln("[edit] Nachricht %d (Channel %d) von User %d bearbeitet (%d/%d)",
		msg.id, ch.id, c.user_id, msg.edit_count, shared.MAX_MESSAGE_EDITS)
}

handle_message_history :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := edit_channel_of(c, w)
	if ch == nil {
		return
	}
	vers := load_message_versions(ch, w.message_id)
	if len(vers) == 0 {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	resp := shared.wire_ok(w.kind, w.seq)
	resp.messages = vers
	resp.channel_id = ch.id
	resp.message_id = w.message_id
	send_to(c, resp)
}
