package main

// In-Memory-Zustand des Servers. Alles hinter EINEM Mutex (g.mu);
// sämtliche Zugriffe auf g.* passieren nur mit gehaltenem Lock.

import "core:net"
import "core:sync"
import "core:time"

import shared "../shared"

KEY_LEN   :: 32 // Master-/Channel-Keys
SALT_LEN  :: 16 // Argon2id-Salt
HASH_LEN  :: 32 // Argon2id-Hash
NONCE_LEN :: 24 // XChaCha20-Poly1305 Nonce
TAG_LEN   :: 16 // Poly1305-Tag

// Registrierter User inkl. Passwort-Hash.
User :: struct {
	id:           u64,
	username:     string,
	display_name: string,
	is_admin:     bool,
	disabled:     bool, // disabled accounts cannot sign in
	last_ip:      string, // IP of the last successful auth (admin panel)
	last_seen_ms: i64,
	avatar_ver:   u64, // Profilbild-Version (0 = keins), Datei siehe storage
	avatar_max:   u64, // höchste je vergebene Version — Versionen dürfen sich
	                   // nie wiederholen, sonst nagelt ein Client-Cache nach
	                   // Löschen + Neu-Upload das alte Bild fest
	salt:         [SALT_LEN]byte,
	pass_hash:    [HASH_LEN]byte,
}

// Invite code for registering while the server is closed.
Invite :: struct {
	code:       string,
	created_ms: i64,
	expires_ms: i64, // 0 = no expiry
	created_by: u64,
	used_by:    u64, // 0 = unused
	used_ms:    i64,
}

// Channel bzw. DM. `key` ist der entpackte Channel-Key —
// er liegt nur im RAM, auf der Platte ausschließlich gewrappt.
Channel :: struct {
	id:         u64,
	name:       string,
	is_dm:      bool,
	creator_id: u64,
	member_ids: [dynamic]u64,
	key:        [KEY_LEN]byte,
}

Session :: struct {
	token:      string,
	user_id:    u64,
	created_ms: i64,
}

// Persistierte Server-Metadaten (server.json). The admin settings are
// encoded so the zero value matches the previous behavior — old
// server.json files load unchanged (open registration, fail2ban on).
Server_Meta :: struct {
	server_name:     string `json:"server_name"`,
	initialized:     bool   `json:"initialized"`,
	next_user_id:    u64    `json:"next_user_id"`,
	next_channel_id: u64    `json:"next_channel_id"`,
	next_message_id: u64    `json:"next_message_id"`,

	registration_closed: bool `json:"registration_closed,omitempty"`,
	f2b_disabled:        bool `json:"f2b_disabled,omitempty"`,
	f2b_max_fails:       int  `json:"f2b_max_fails,omitempty"`,
	f2b_window_min:      int  `json:"f2b_window_min,omitempty"`,
	f2b_ban_min:         int  `json:"f2b_ban_min,omitempty"`,
}

// Eine Client-Verbindung; lebt in ihrem eigenen Thread.
Client_Conn :: struct {
	sock:          net.TCP_Socket,
	sc:            shared.Secure_Conn,
	authed:        bool,
	user_id:       u64,
	remote:        string, // Gegenstelle, nur fürs Logging
	ip:            string, // IP without the port (bans/fail2ban)
	drop:          bool,   // a handler wants this connection closed
	preauth_seen:  int,    // requests before auth (spam budget)
}

// Requests allowed per connection before auth — anything more is spam.
PREAUTH_BUDGET :: 20

Server_State :: struct {
	mu:         sync.Mutex,
	data_dir:   string,
	master_key: [KEY_LEN]byte,
	meta:       Server_Meta,
	users:      [dynamic]User,
	sessions:   [dynamic]Session,
	channels:   [dynamic]Channel,
	invites:    [dynamic]Invite,
	conns:      [dynamic]^Client_Conn,

	// Offene Bearbeitungs-Freigaben (message_id → user_id). edit_start prüft
	// die 1-Minuten-Frist und legt den Eintrag an; edit_message verlangt ihn.
	// Bewusst nur im RAM: ein Server-Neustart beendet offene Edits.
	open_edits: map[u64]u64,
}

g: Server_State

// ---------- Lookup-Helfer (nur unter g.mu aufrufen) ----------

find_user_by_id :: proc(id: u64) -> ^User {
	for &u in g.users {
		if u.id == id {
			return &u
		}
	}
	return nil
}

find_user_by_name :: proc(username: string) -> ^User {
	for &u in g.users {
		if u.username == username {
			return &u
		}
	}
	return nil
}

find_channel :: proc(id: u64) -> ^Channel {
	for &ch in g.channels {
		if ch.id == id {
			return &ch
		}
	}
	return nil
}

find_session :: proc(token: string) -> ^Session {
	for &s in g.sessions {
		if s.token == token {
			return &s
		}
	}
	return nil
}

find_invite :: proc(code: string) -> ^Invite {
	for &inv in g.invites {
		if inv.code == code {
			return &inv
		}
	}
	return nil
}

// Drops all sessions of one user (password reset/deactivation).
drop_user_sessions :: proc(user_id: u64) {
	for i := len(g.sessions) - 1; i >= 0; i -= 1 {
		if g.sessions[i].user_id == user_id {
			delete(g.sessions[i].token)
			ordered_remove(&g.sessions, i)
		}
	}
	save_sessions()
}

// Cuts open connections of one user. shutdown (not close!) — close would
// leave the owning thread stuck in its blocking recv; shutdown wakes it
// with EOF and the thread cleans up itself. `except` protects the caller.
close_user_conns :: proc(user_id: u64, except: ^Client_Conn) {
	for conn in g.conns {
		if conn != except && conn.authed && conn.user_id == user_id {
			_ = net.shutdown(conn.sock, .Both)
		}
	}
}

// Cuts open connections from one IP (after an IP ban); see above re shutdown.
close_ip_conns :: proc(ip: string, except: ^Client_Conn) {
	for conn in g.conns {
		if conn != except && conn.ip == ip {
			_ = net.shutdown(conn.sock, .Both)
		}
	}
}

is_member :: proc(ch: ^Channel, user_id: u64) -> bool {
	for id in ch.member_ids {
		if id == user_id {
			return true
		}
	}
	return false
}

remove_member :: proc(ch: ^Channel, user_id: u64) {
	for id, idx in ch.member_ids {
		if id == user_id {
			ordered_remove(&ch.member_ids, idx)
			return
		}
	}
}

// online = mindestens eine authentifizierte Verbindung dieses Users.
user_online :: proc(user_id: u64) -> bool {
	for conn in g.conns {
		if conn.authed && conn.user_id == user_id {
			return true
		}
	}
	return false
}

// ---------- Wire-Konvertierung ----------

wire_user :: proc(u: ^User) -> shared.User {
	return shared.User{
		id           = u.id,
		username     = u.username,
		display_name = u.display_name,
		is_admin     = u.is_admin,
		disabled     = u.disabled,
		online       = user_online(u.id),
		in_call      = call_user_active(u.id),
		avatar       = u.avatar_ver,
	}
}

wire_channel :: proc(ch: ^Channel) -> shared.Channel {
	return shared.Channel{
		id         = ch.id,
		name       = ch.name,
		is_dm      = ch.is_dm,
		creator_id = ch.creator_id,
		member_ids = ch.member_ids[:],
	}
}

// ---------- Senden / Broadcasts (nur unter g.mu aufrufen) ----------

send_to :: proc(c: ^Client_Conn, w: shared.Wire) {
	// Fehler beim Senden werden ignoriert — die Verbindung räumt sich
	// über das recv-Ende ihres eigenen Threads auf.
	_ = shared.send_wire(&c.sc, w)
}

// An alle authentifizierten Verbindungen (optional eine ausnehmen).
broadcast_authed :: proc(w: shared.Wire, exclude: ^Client_Conn) {
	for conn in g.conns {
		if conn == exclude || !conn.authed {
			continue
		}
		send_to(conn, w)
	}
}

// An alle authentifizierten Verbindungen von Channel-Mitgliedern.
broadcast_members :: proc(ch: ^Channel, w: shared.Wire, exclude: ^Client_Conn) {
	for conn in g.conns {
		if conn == exclude || !conn.authed {
			continue
		}
		if !is_member(ch, conn.user_id) {
			continue
		}
		send_to(conn, w)
	}
}

// An alle authentifizierten Verbindungen eines bestimmten Users.
broadcast_user :: proc(user_id: u64, w: shared.Wire, exclude: ^Client_Conn) {
	for conn in g.conns {
		if conn == exclude || !conn.authed || conn.user_id != user_id {
			continue
		}
		send_to(conn, w)
	}
}

// Unix-Millisekunden.
now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}
