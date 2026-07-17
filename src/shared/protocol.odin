package shared

// Wire-Protokoll: JSON-Nachrichten über einen Noise-verschlüsselten TCP-Kanal.
// Jede Nachricht ist ein `Wire`-Envelope mit `kind` + den für den Kind
// relevanten Feldern. Requests tragen eine `seq`, Responses echoen sie.
// Server-Events haben seq == 0.

import "core:unicode"

PROTOCOL_VERSION :: 1

// Client -> Server Requests
K_SERVER_INFO    :: "server_info"
K_REGISTER       :: "register"
K_LOGIN          :: "login"
K_RESUME         :: "resume" // Session per Token fortsetzen
K_SETUP          :: "setup"  // Ersteinrichtung durch Admin (Servername)
K_LIST_USERS     :: "list_users"
K_LIST_CHANNELS  :: "list_channels"
K_CREATE_CHANNEL :: "create_channel"
K_DELETE_CHANNEL :: "delete_channel" // nur Admin oder Ersteller
K_INVITE         :: "invite"
K_KICK           :: "kick"
K_LEAVE          :: "leave"
K_OPEN_DM        :: "open_dm"
K_SEND           :: "send"
K_HISTORY        :: "history"

// Nachricht bearbeiten. Die 1-Minuten-Frist gilt für den EINSTIEG in den
// Bearbeitungsmodus (edit_start) — danach darf beliebig lange getippt
// werden. edit_start reserviert die Freigabe serverseitig; edit_message
// verbraucht sie, edit_cancel gibt sie wieder her. Jeder Edit startet die
// Frist neu, maximal MAX_MESSAGE_EDITS Edits pro Nachricht.
K_EDIT_START      :: "edit_start"
K_EDIT_CANCEL     :: "edit_cancel"
K_EDIT_MESSAGE    :: "edit_message"
K_MESSAGE_HISTORY :: "message_history" // alle Versionen einer Nachricht

// Voice-Calls. Ein Channel (oder DM) hat höchstens EINEN laufenden Call;
// call_join startet ihn implizit, das letzte call_leave beendet ihn.
// Die Signalisierung läuft über TCP, das Audio über UDP (siehe voice.odin) —
// call_join liefert dafür call_key, udp_token, ssrc und udp_port.
K_CALL_JOIN  :: "call_join"
K_CALL_LEAVE :: "call_leave"
K_CALL_MUTE  :: "call_mute" // muted-Flag setzen (nur Anzeige für andere)

// Leichtgewichtiger Echo-Request: der Server antwortet sofort mit ok —
// der Client misst daraus die TCP-Latenz (Indikator in der Kopfzeile).
K_PING :: "ping"

// Profilbilder. Der Client schneidet das Bild lokal zu (Kreis-Ausschnitt,
// AVATAR_BAKE_DIM²) und lädt es als PNG (base64 in `data`) hoch. Der Server
// prüft nur Magic/IHDR/Limits, dekodiert aber nicht. User.avatar trägt eine
// Versionsnummer (0 = kein Bild) — ändert sie sich, holt der Client das
// Bild per avatar_get neu.
K_AVATAR_SET    :: "avatar_set"    // data = base64(PNG)
K_AVATAR_DELETE :: "avatar_delete"
K_AVATAR_GET    :: "avatar_get"    // user_id → data + user

// Admin panel. All of these require an admin caller; every successful reply
// carries a fresh Admin_State snapshot so the client never has to sync
// increments. Server settings changes go through admin_set as a whole.
K_ADMIN_STATE          :: "admin_state"
K_ADMIN_SET            :: "admin_set"            // settings (whole struct)
K_ADMIN_SET_ROLE       :: "admin_set_role"       // user_id + is_admin
K_ADMIN_SET_DISABLED   :: "admin_set_disabled"   // user_id + disabled
K_ADMIN_CREATE_USER    :: "admin_create_user"    // username/password/display_name
K_ADMIN_RESET_PASSWORD :: "admin_reset_password" // user_id + password
K_ADMIN_CREATE_INVITE  :: "admin_create_invite"  // minutes (0 = no expiry)
K_ADMIN_REVOKE_INVITE  :: "admin_revoke_invite"  // invite_code
K_ADMIN_BAN_IP         :: "admin_ban_ip"         // ip + minutes (0 = permanent)
K_ADMIN_UNBAN_IP       :: "admin_unban_ip"       // ip

// Server -> Client Events (seq == 0)
EV_MESSAGE         :: "ev_message"         // neue Chat-Nachricht
EV_MESSAGE_EDITED  :: "ev_message_edited"  // Nachricht wurde bearbeitet (message = neuer Stand)
EV_CHANNEL         :: "ev_channel"         // Channel neu/aktualisiert (Mitgliedschaft)
EV_CHANNEL_REMOVED :: "ev_channel_removed" // aus Channel entfernt / Channel weg (err = "deleted" bei Löschung)
EV_USER            :: "ev_user"            // User neu/aktualisiert (inkl. online)
EV_SERVER          :: "ev_server"          // Server-Konfiguration geändert (Name)
EV_CALL_STATE      :: "ev_call_state"      // Call-Stand eines Channels (peers leer = beendet)

MAX_MESSAGE_TEXT_LEN :: 8 * 1024
MAX_USERNAME_LEN     :: 32
MAX_CHANNEL_NAME_LEN :: 48
MIN_PASSWORD_LEN     :: 6
HISTORY_MAX_LIMIT    :: 100
EDIT_WINDOW_MS       :: 60 * 1000
MAX_MESSAGE_EDITS    :: 3
INVITE_CODE_LEN      :: 8

// Profilbild-Limits. Der Client backt auf AVATAR_BAKE_DIM² herunter; der
// Server akzeptiert quadratische PNGs im Bereich MIN..MAX (andere Clients).
AVATAR_BAKE_DIM  :: 256
AVATAR_MIN_DIM   :: 64
AVATAR_MAX_DIM   :: 512
AVATAR_MAX_BYTES :: 400 * 1024

User :: struct {
	id:           u64    `json:"id"`,
	username:     string `json:"username"`,
	display_name: string `json:"display_name,omitempty"`,
	is_admin:     bool   `json:"is_admin,omitempty"`,
	disabled:     bool   `json:"disabled,omitempty"`, // account disabled by an admin
	online:       bool   `json:"online,omitempty"`,
	in_call:      bool   `json:"in_call,omitempty"`, // Headphone-Anzeige
	avatar:       u64    `json:"avatar,omitempty"`,  // Profilbild-Version (0 = keins)
}

// Server settings the admin can change (absolute values, sent as a whole).
// The f2b_* fields configure the fail2ban-style brute-force lockout.
Admin_Settings :: struct {
	registration_closed: bool `json:"registration_closed,omitempty"`,
	f2b_disabled:        bool `json:"f2b_disabled,omitempty"`,
	f2b_max_fails:       int  `json:"f2b_max_fails,omitempty"`,
	f2b_window_min:      int  `json:"f2b_window_min,omitempty"`,
	f2b_ban_min:         int  `json:"f2b_ban_min,omitempty"`,
}

Invite_Info :: struct {
	code:       string `json:"code"`,
	created_ms: i64    `json:"created_ms"`,
	expires_ms: i64    `json:"expires_ms,omitempty"`, // 0 = no expiry
	created_by: u64    `json:"created_by"`,
	used_by:    u64    `json:"used_by,omitempty"`, // 0 = unused
	used_ms:    i64    `json:"used_ms,omitempty"`,
}

Ban_Info :: struct {
	ip:         string `json:"ip"`,
	reason:     string `json:"reason,omitempty"`,
	created_ms: i64    `json:"created_ms"`,
	expires_ms: i64    `json:"expires_ms,omitempty"`, // 0 = permanent
	by_user:    u64    `json:"by_user,omitempty"`,    // 0 = fail2ban
}

// Admin-only per-user details; joined with the regular user list by id.
Admin_User :: struct {
	id:           u64    `json:"id"`,
	disabled:     bool   `json:"disabled,omitempty"`,
	last_ip:      string `json:"last_ip,omitempty"`,
	last_seen_ms: i64    `json:"last_seen_ms,omitempty"`,
}

// All non-DM channels, including those the admin is not a member of.
Admin_Channel :: struct {
	id:         u64    `json:"id"`,
	name:       string `json:"name"`,
	creator_id: u64    `json:"creator_id,omitempty"`,
	members:    int    `json:"members"`,
}

Admin_State :: struct {
	settings: Admin_Settings  `json:"settings"`,
	users:    []Admin_User    `json:"users,omitempty"`,
	channels: []Admin_Channel `json:"channels,omitempty"`,
	invites:  []Invite_Info   `json:"invites,omitempty"`,
	bans:     []Ban_Info      `json:"bans,omitempty"`,
	dm_count: int             `json:"dm_count,omitempty"`,
}

// Teilnehmer eines laufenden Calls.
Call_Peer :: struct {
	user_id: u64  `json:"user_id"`,
	ssrc:    u32  `json:"ssrc"`,
	muted:   bool `json:"muted,omitempty"`,
}

Call_Info :: struct {
	channel_id: u64         `json:"channel_id"`,
	peers:      []Call_Peer `json:"peers,omitempty"`,
	msg_id:     u64         `json:"msg_id,omitempty"`,     // Systemnachricht des Calls (Chat-Karte)
	started_ms: i64         `json:"started_ms,omitempty"`, // Unix-ms des Call-Starts (Server-Zeit)
}

Channel :: struct {
	id:         u64    `json:"id"`,
	name:       string `json:"name,omitempty"`,
	is_dm:      bool   `json:"is_dm,omitempty"`,
	creator_id: u64    `json:"creator_id,omitempty"`,
	member_ids: []u64  `json:"member_ids,omitempty"`,
}

Chat_Message :: struct {
	id:         u64    `json:"id"`,
	channel_id: u64    `json:"channel_id"`,
	author_id:  u64    `json:"author_id"`,
	ts_ms:      i64    `json:"ts_ms"`, // Unix-Millisekunden
	text:       string `json:"text"`,
	edited_ms:  i64    `json:"edited_ms,omitempty"`,  // letzter Edit (0 = nie bearbeitet)
	edit_count: int    `json:"edit_count,omitempty"`, // wie oft bearbeitet (max. MAX_MESSAGE_EDITS)

	// Voice-Call-Systemnachricht (author = Starter, text bleibt leer).
	// Der Server postet sie beim Call-Start und trägt beim Ende call_end_ms
	// nach — der Client rendert daraus die Call-Karte (live/beendet).
	call_start_ms: i64 `json:"call_start_ms,omitempty"`, // > 0 = Call-Systemnachricht
	call_end_ms:   i64 `json:"call_end_ms,omitempty"`,   // > 0 = Call beendet
}

// Ein flacher Envelope für alle Nachrichten-Kinds. Nicht gesetzte Felder
// werden dank omitempty nicht serialisiert.
Wire :: struct {
	kind: string `json:"kind"`,
	seq:  u64    `json:"seq,omitempty"`,

	ok:  bool   `json:"ok,omitempty"`,
	err: string `json:"err,omitempty"`,

	// Auth / Setup
	username:     string `json:"username,omitempty"`,
	password:     string `json:"password,omitempty"`,
	display_name: string `json:"display_name,omitempty"`,
	token:        string `json:"token,omitempty"`,

	// Server-Info
	server_name:  string `json:"server_name,omitempty"`,
	initialized:  bool   `json:"initialized,omitempty"`,  // Setup abgeschlossen
	setup_needed: bool   `json:"setup_needed,omitempty"`, // dieser Client muss Setup durchführen
	invite_only:  bool   `json:"invite_only,omitempty"`,  // registration requires an invite code

	// Entities
	user:     User         `json:"user,omitempty"`,
	users:    []User       `json:"users,omitempty"`,
	channel:  Channel      `json:"channel,omitempty"`,
	channels: []Channel    `json:"channels,omitempty"`,
	message:  Chat_Message `json:"message,omitempty"`,
	messages: []Chat_Message `json:"messages,omitempty"`,

	// Parameter
	channel_id: u64    `json:"channel_id,omitempty"`,
	user_id:    u64    `json:"user_id,omitempty"`,
	message_id: u64    `json:"message_id,omitempty"`,
	name:       string `json:"name,omitempty"`,
	text:       string `json:"text,omitempty"`,
	before_id:  u64    `json:"before_id,omitempty"`,
	limit:      int    `json:"limit,omitempty"`,
	data:       string `json:"data,omitempty"`, // base64-Binärpayload (Profilbild)

	// Admin / Zugang
	invite_code: string         `json:"invite_code,omitempty"`, // register + invite management
	ip:          string         `json:"ip,omitempty"`,
	minutes:     int            `json:"minutes,omitempty"`, // validity/ban duration (0 = unlimited)
	is_admin:    bool           `json:"is_admin,omitempty"`,
	disabled:    bool           `json:"disabled,omitempty"`,
	settings:    Admin_Settings `json:"settings,omitempty"`,
	admin:       Admin_State    `json:"admin,omitempty"`,

	// Voice-Calls
	call:      Call_Info   `json:"call,omitempty"`,      // EV_CALL_STATE / call_join-Reply
	calls:     []Call_Info `json:"calls,omitempty"`,     // laufende Calls (list_channels-Reply)
	call_id:   u64         `json:"call_id,omitempty"`,   // für das UDP-HELLO
	call_key:  string      `json:"call_key,omitempty"`,  // hex(32 Byte), nur call_join-Reply
	udp_token: string      `json:"udp_token,omitempty"`, // hex(16 Byte), nur call_join-Reply
	udp_port:  int         `json:"udp_port,omitempty"`,
	ssrc:      u32         `json:"ssrc,omitempty"`,
	muted:     bool        `json:"muted,omitempty"`,
}

// Antwort-Helfer
wire_ok :: proc(kind: string, seq: u64) -> Wire {
	return Wire{kind = kind, seq = seq, ok = true}
}

wire_err :: proc(kind: string, seq: u64, msg: string) -> Wire {
	return Wire{kind = kind, seq = seq, err = msg}
}

// PNG-Maße aus dem IHDR-Chunk lesen (liegt laut Spec immer direkt nach der
// 8-Byte-Signatur). ok=false wenn das kein PNG ist. Server (Upload-Limits)
// und Client (Format-Sniffing) prüfen damit, ohne zu dekodieren.
png_dims :: proc(data: []byte) -> (w, h: int, ok: bool) {
	magic := [8]byte{137, 'P', 'N', 'G', 13, 10, 26, 10}
	if len(data) < 24 {
		return
	}
	for b, i in magic {
		if data[i] != b {
			return
		}
	}
	if string(data[12:16]) != "IHDR" {
		return
	}
	be32 :: proc(b: []byte) -> int {
		return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3])
	}
	return be32(data[16:20]), be32(data[20:24]), true
}

valid_username :: proc(s: string) -> bool {
	if len(s) < 2 || len(s) > MAX_USERNAME_LEN {
		return false
	}
	for c in s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_', '-', '.':
		case:
			return false
		}
	}
	return true
}

valid_channel_name :: proc(s: string) -> bool {
	if len(s) < 1 || len(s) > MAX_CHANNEL_NAME_LEN {
		return false
	}
	for c in s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_', '-':
		case:
			// Nicht-ASCII-Buchstaben (ä ö ü ß é …) sind erlaubt, solange
			// sie klein sind — Großbuchstaben bleiben wie im ASCII-Fall draußen.
			if c < 0x80 || !unicode.is_letter(c) || unicode.is_upper(c) {
				return false
			}
		}
	}
	return true
}
