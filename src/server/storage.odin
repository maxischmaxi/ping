package main

// Persistenz: JSON-Dateien (atomar via Tempdatei + rename) und
// verschlüsselte Message-Logs. Klartext von Nachrichten und Channel-Keys
// landet NIEMALS auf der Platte.

import "core:crypto"
import "core:crypto/aead"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import shared "../shared"

// Sensible Dateien: nur Owner darf lesen/schreiben (0600).
FILE_PERM :: os.Permissions{.Read_User, .Write_User}

// ---------- JSON-Records (Format auf der Platte) ----------

User_Rec :: struct {
	id:           u64    `json:"id"`,
	username:     string `json:"username"`,
	display_name: string `json:"display_name"`,
	is_admin:     bool   `json:"is_admin"`,
	salt:         string `json:"salt"`,      // base64
	pass_hash:    string `json:"pass_hash"`, // base64
}

Session_Rec :: struct {
	token:      string `json:"token"`,
	user_id:    u64    `json:"user_id"`,
	created_ms: i64    `json:"created_ms"`,
}

Channel_Rec :: struct {
	id:          u64    `json:"id"`,
	name:        string `json:"name"`,
	is_dm:       bool   `json:"is_dm"`,
	creator_id:  u64    `json:"creator_id"`,
	member_ids:  []u64  `json:"member_ids"`,
	wrapped_key: string `json:"wrapped_key"`, // base64(nonce||ct||tag)
}

// ---------- Pfade (temp-allokiert) ----------

meta_path :: proc() -> string {
	return fmt.tprintf("%s/server.json", g.data_dir)
}

users_path :: proc() -> string {
	return fmt.tprintf("%s/users.json", g.data_dir)
}

sessions_path :: proc() -> string {
	return fmt.tprintf("%s/sessions.json", g.data_dir)
}

channels_path :: proc() -> string {
	return fmt.tprintf("%s/channels.json", g.data_dir)
}

messages_path :: proc(channel_id: u64) -> string {
	return fmt.tprintf("%s/messages/%d.bin", g.data_dir, channel_id)
}

// Message-Log eines gelöschten Channels entfernen (Fehler egal —
// Channels ohne Nachrichten haben nie eine Datei bekommen).
delete_message_log :: proc(channel_id: u64) {
	_ = os.remove(messages_path(channel_id))
}

// ---------- Atomares JSON-Schreiben ----------

// Erst Tempdatei im selben Verzeichnis schreiben, dann rename → atomar.
save_json_atomic :: proc(path: string, v: any) -> bool {
	data, merr := json.marshal(v, {pretty = true}, context.temp_allocator)
	if merr != nil {
		return false
	}
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, data, FILE_PERM) != nil {
		return false
	}
	if os.rename(tmp, path) != nil {
		return false
	}
	return true
}

// ---------- Channel-Key-Wrapping (XChaCha20-Poly1305 unter Master-Key) ----------

// Format: nonce(24) || ciphertext(32) || tag(16), base64-kodiert.
wrap_key :: proc(key: [KEY_LEN]byte) -> string {
	key := key
	buf: [NONCE_LEN + KEY_LEN + TAG_LEN]byte
	nonce := buf[:NONCE_LEN]
	ct := buf[NONCE_LEN : NONCE_LEN + KEY_LEN]
	tag := buf[NONCE_LEN + KEY_LEN:]
	crypto.rand_bytes(nonce)
	aead.seal_oneshot(.XCHACHA20POLY1305, ct, tag, g.master_key[:], nonce, nil, key[:])
	return base64.encode(buf[:], base64.ENC_TABLE, context.temp_allocator)
}

unwrap_key :: proc(b64: string) -> (key: [KEY_LEN]byte, ok: bool) {
	raw, err := base64.decode(b64, base64.DEC_TABLE, nil, context.temp_allocator)
	if err != nil || len(raw) != NONCE_LEN + KEY_LEN + TAG_LEN {
		return
	}
	nonce := raw[:NONCE_LEN]
	ct := raw[NONCE_LEN : NONCE_LEN + KEY_LEN]
	tag := raw[NONCE_LEN + KEY_LEN:]
	if !aead.open_oneshot(.XCHACHA20POLY1305, key[:], g.master_key[:], nonce, nil, ct, tag) {
		return
	}
	return key, true
}

// ---------- Speichern (nur unter g.mu aufrufen) ----------

save_meta :: proc() {
	if !save_json_atomic(meta_path(), g.meta) {
		fmt.printfln("[error] server.json konnte nicht geschrieben werden")
	}
}

save_users :: proc() {
	recs := make([dynamic]User_Rec, 0, len(g.users), context.temp_allocator)
	for &u in g.users {
		append(&recs, User_Rec{
			id           = u.id,
			username     = u.username,
			display_name = u.display_name,
			is_admin     = u.is_admin,
			salt         = base64.encode(u.salt[:], base64.ENC_TABLE, context.temp_allocator),
			pass_hash    = base64.encode(u.pass_hash[:], base64.ENC_TABLE, context.temp_allocator),
		})
	}
	if !save_json_atomic(users_path(), recs[:]) {
		fmt.printfln("[error] users.json konnte nicht geschrieben werden")
	}
}

save_sessions :: proc() {
	recs := make([dynamic]Session_Rec, 0, len(g.sessions), context.temp_allocator)
	for &s in g.sessions {
		append(&recs, Session_Rec{token = s.token, user_id = s.user_id, created_ms = s.created_ms})
	}
	if !save_json_atomic(sessions_path(), recs[:]) {
		fmt.printfln("[error] sessions.json konnte nicht geschrieben werden")
	}
}

save_channels :: proc() {
	recs := make([dynamic]Channel_Rec, 0, len(g.channels), context.temp_allocator)
	for &ch in g.channels {
		append(&recs, Channel_Rec{
			id          = ch.id,
			name        = ch.name,
			is_dm       = ch.is_dm,
			creator_id  = ch.creator_id,
			member_ids  = ch.member_ids[:],
			wrapped_key = wrap_key(ch.key),
		})
	}
	if !save_json_atomic(channels_path(), recs[:]) {
		fmt.printfln("[error] channels.json konnte nicht geschrieben werden")
	}
}

// ---------- Laden beim Start (Main-Thread, vor dem Accept-Loop) ----------

load_state :: proc() -> bool {
	// server.json
	if os.exists(meta_path()) {
		data, err := os.read_entire_file(meta_path(), context.temp_allocator)
		if err != nil || json.unmarshal(data, &g.meta) != nil {
			fmt.printfln("[error] server.json unlesbar")
			return false
		}
	}
	if g.meta.next_user_id == 0 {g.meta.next_user_id = 1}
	if g.meta.next_channel_id == 0 {g.meta.next_channel_id = 1}
	if g.meta.next_message_id == 0 {g.meta.next_message_id = 1}

	// users.json
	if os.exists(users_path()) {
		data, err := os.read_entire_file(users_path(), context.temp_allocator)
		recs: []User_Rec
		if err != nil || json.unmarshal(data, &recs, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil {
			fmt.printfln("[error] users.json unlesbar")
			return false
		}
		for r in recs {
			u := User{
				id           = r.id,
				username     = strings.clone(r.username),
				display_name = strings.clone(r.display_name),
				is_admin     = r.is_admin,
			}
			salt, serr := base64.decode(r.salt, base64.DEC_TABLE, nil, context.temp_allocator)
			hash, herr := base64.decode(r.pass_hash, base64.DEC_TABLE, nil, context.temp_allocator)
			if serr != nil || herr != nil || len(salt) != SALT_LEN || len(hash) != HASH_LEN {
				fmt.printfln("[error] users.json: kaputter Eintrag für %q", r.username)
				return false
			}
			copy(u.salt[:], salt)
			copy(u.pass_hash[:], hash)
			append(&g.users, u)
		}
	}

	// sessions.json
	if os.exists(sessions_path()) {
		data, err := os.read_entire_file(sessions_path(), context.temp_allocator)
		recs: []Session_Rec
		if err != nil || json.unmarshal(data, &recs, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil {
			fmt.printfln("[error] sessions.json unlesbar")
			return false
		}
		for r in recs {
			append(&g.sessions, Session{
				token      = strings.clone(r.token),
				user_id    = r.user_id,
				created_ms = r.created_ms,
			})
		}
	}

	// channels.json — Channel-Keys mit dem Master-Key entpacken.
	if os.exists(channels_path()) {
		data, err := os.read_entire_file(channels_path(), context.temp_allocator)
		recs: []Channel_Rec
		if err != nil || json.unmarshal(data, &recs, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil {
			fmt.printfln("[error] channels.json unlesbar")
			return false
		}
		for r in recs {
			key, kok := unwrap_key(r.wrapped_key)
			if !kok {
				fmt.printfln("[error] channels.json: Key von Channel %d nicht entschlüsselbar (falscher master.key?)", r.id)
				return false
			}
			ch := Channel{
				id         = r.id,
				name       = strings.clone(r.name),
				is_dm      = r.is_dm,
				creator_id = r.creator_id,
				key        = key,
			}
			for m in r.member_ids {
				append(&ch.member_ids, m)
			}
			append(&g.channels, ch)
		}
	}

	return true
}

// ---------- Verschlüsselte Message-Logs ----------

// AAD: 8 Bytes Channel-ID big-endian.
message_aad :: proc(channel_id: u64) -> [8]byte {
	aad: [8]byte
	for i in 0 ..< 8 {
		aad[i] = byte(channel_id >> uint(56 - 8 * i))
	}
	return aad
}

// Ein entschlüsselter Log-Eintrag: entweder eine Nachricht (edit_of == 0)
// oder ein Edit-Record, der text/ts einer früheren Nachricht überschreibt.
// Alte Logs (nur Nachrichten) parsen unverändert — edit_of fehlt dort und
// bleibt 0.
Log_Entry :: struct {
	id:         u64    `json:"id"`,
	channel_id: u64    `json:"channel_id"`,
	author_id:  u64    `json:"author_id"`,
	ts_ms:      i64    `json:"ts_ms"`,
	text:       string `json:"text"`,
	edit_of:    u64    `json:"edit_of"`,

	// Voice-Call-Systemnachricht bzw. ihr Ende-Record (edit_of gesetzt,
	// call_end_ms > 0 → überschreibt nur call_end_ms, zählt nicht als Edit).
	call_start_ms: i64 `json:"call_start_ms,omitempty"`,
	call_end_ms:   i64 `json:"call_end_ms,omitempty"`,
}

// Edit-Record auf der Platte (append-only, wie Nachrichten verschlüsselt).
@(private = "file")
Edit_Rec :: struct {
	edit_of: u64    `json:"edit_of"`,
	ts_ms:   i64    `json:"ts_ms"`,
	text:    string `json:"text"`,
}

// Record (append-only): u32 big-endian Länge des Rests || nonce(24) || tag(16) || ciphertext.
@(private = "file")
append_log :: proc(ch: ^Channel, pt: []byte) -> bool {
	rest := NONCE_LEN + TAG_LEN + len(pt)
	rec := make([]byte, 4 + rest, context.temp_allocator)
	rec[0] = byte(rest >> 24)
	rec[1] = byte(rest >> 16)
	rec[2] = byte(rest >> 8)
	rec[3] = byte(rest)
	nonce := rec[4 : 4 + NONCE_LEN]
	tag := rec[4 + NONCE_LEN : 4 + NONCE_LEN + TAG_LEN]
	ct := rec[4 + NONCE_LEN + TAG_LEN:]
	crypto.rand_bytes(nonce)
	aad := message_aad(ch.id)
	aead.seal_oneshot(.XCHACHA20POLY1305, ct, tag, ch.key[:], nonce, aad[:], pt)

	f, oerr := os.open(messages_path(ch.id), {.Write, .Create, .Append}, FILE_PERM)
	if oerr != nil {
		return false
	}
	defer os.close(f)
	n, werr := os.write(f, rec)
	return werr == nil && n == len(rec)
}

store_message :: proc(ch: ^Channel, msg: shared.Chat_Message) -> bool {
	pt, merr := json.marshal(msg, {}, context.temp_allocator)
	if merr != nil {
		return false
	}
	return append_log(ch, pt)
}

store_edit :: proc(ch: ^Channel, msg_id: u64, text: string, ts_ms: i64) -> bool {
	pt, merr := json.marshal(Edit_Rec{edit_of = msg_id, ts_ms = ts_ms, text = text}, {}, context.temp_allocator)
	if merr != nil {
		return false
	}
	return append_log(ch, pt)
}

// Ende-Record einer Call-Systemnachricht (append-only wie ein Edit,
// setzt beim Replay aber nur call_end_ms).
@(private = "file")
Call_End_Rec :: struct {
	edit_of:     u64 `json:"edit_of"`,
	ts_ms:       i64 `json:"ts_ms"`,
	call_end_ms: i64 `json:"call_end_ms"`,
}

store_call_end :: proc(ch: ^Channel, msg_id: u64, end_ms: i64) -> bool {
	pt, merr := json.marshal(Call_End_Rec{edit_of = msg_id, ts_ms = end_ms, call_end_ms = end_ms}, {}, context.temp_allocator)
	if merr != nil {
		return false
	}
	return append_log(ch, pt)
}

// Alle Records eines Channel-Logs entschlüsseln (temp-alloziert, in
// Schreibreihenfolge — Edits stehen immer hinter ihrer Nachricht).
@(private = "file")
load_log :: proc(ch: ^Channel) -> []Log_Entry {
	data, rerr := os.read_entire_file(messages_path(ch.id), context.temp_allocator)
	if rerr != nil {
		return nil // Datei existiert noch nicht → leeres Log
	}

	entries := make([dynamic]Log_Entry, context.temp_allocator)
	aad := message_aad(ch.id)
	off := 0
	for off + 4 <= len(data) {
		rest := int(data[off]) << 24 | int(data[off + 1]) << 16 | int(data[off + 2]) << 8 | int(data[off + 3])
		off += 4
		if rest < NONCE_LEN + TAG_LEN || off + rest > len(data) {
			fmt.printfln("[error] Message-Log von Channel %d ist korrupt", ch.id)
			break
		}
		nonce := data[off : off + NONCE_LEN]
		tag := data[off + NONCE_LEN : off + NONCE_LEN + TAG_LEN]
		ct := data[off + NONCE_LEN + TAG_LEN : off + rest]
		off += rest

		pt := make([]byte, len(ct), context.temp_allocator)
		if !aead.open_oneshot(.XCHACHA20POLY1305, pt, ch.key[:], nonce, aad[:], ct, tag) {
			fmt.printfln("[error] Message-Record von Channel %d nicht entschlüsselbar", ch.id)
			break
		}
		e: Log_Entry
		if json.unmarshal(pt, &e, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil {
			break
		}
		append(&entries, e)
	}
	return entries[:]
}

@(private = "file")
entry_message :: proc(e: Log_Entry) -> shared.Chat_Message {
	return {
		id = e.id, channel_id = e.channel_id, author_id = e.author_id,
		ts_ms = e.ts_ms, text = e.text, call_start_ms = e.call_start_ms,
	}
}

// Historie lesen: Log abspielen (Edits überschreiben ihre Nachricht), nach
// before_id filtern, die letzten `limit` in aufsteigender Reihenfolge
// zurückgeben. Ergebnis liegt im temp_allocator.
load_history :: proc(ch: ^Channel, before_id: u64, limit: int) -> []shared.Chat_Message {
	msgs := make([dynamic]shared.Chat_Message, context.temp_allocator)
	index := make(map[u64]int, context.temp_allocator)
	for e in load_log(ch) {
		if e.edit_of != 0 {
			if idx, ok := index[e.edit_of]; ok {
				m := &msgs[idx]
				if e.call_end_ms > 0 {
					m.call_end_ms = e.call_end_ms
				} else {
					m.text = e.text
					m.edited_ms = e.ts_ms
					m.edit_count += 1
				}
			}
			continue
		}
		index[e.id] = len(msgs)
		append(&msgs, entry_message(e))
	}

	// Erst nach dem Replay filtern — Edits liegen im Log auch hinter
	// before_id, gehören aber zu älteren Nachrichten.
	out := msgs[:]
	if before_id != 0 {
		filtered := make([dynamic]shared.Chat_Message, context.temp_allocator)
		for m in out {
			if m.id < before_id {
				append(&filtered, m)
			}
		}
		out = filtered[:]
	}
	if len(out) > limit {
		return out[len(out) - limit:]
	}
	return out
}

// Aktuellen Stand EINER Nachricht laden (inkl. angewandter Edits).
load_message :: proc(ch: ^Channel, msg_id: u64) -> (msg: shared.Chat_Message, ok: bool) {
	for e in load_log(ch) {
		if e.edit_of == 0 && e.id == msg_id {
			msg = entry_message(e)
			ok = true
		} else if e.edit_of == msg_id && ok {
			if e.call_end_ms > 0 {
				msg.call_end_ms = e.call_end_ms
			} else {
				msg.text = e.text
				msg.edited_ms = e.ts_ms
				msg.edit_count += 1
			}
		}
	}
	return
}

// Alle Versionen einer Nachricht, Original zuerst. text/ts_ms je Version,
// edit_count trägt den Versionsindex (0 = Original).
load_message_versions :: proc(ch: ^Channel, msg_id: u64) -> []shared.Chat_Message {
	vers := make([dynamic]shared.Chat_Message, context.temp_allocator)
	for e in load_log(ch) {
		if e.edit_of == 0 && e.id == msg_id {
			append(&vers, entry_message(e))
		} else if e.edit_of == msg_id && len(vers) > 0 {
			if e.call_end_ms > 0 {
				continue // Call-Ende ist keine Textversion
			}
			v := vers[0]
			v.text = e.text
			v.ts_ms = e.ts_ms
			v.edit_count = len(vers)
			append(&vers, v)
		}
	}
	return vers[:]
}
