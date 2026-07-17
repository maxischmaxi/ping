package main

// Netzwerk-Schicht: eine Server_Conn pro Server. Ein Worker-Thread baut die
// Verbindung auf (dial → Handshake → TOFU → server_info → resume) und wird
// danach zum Reader-Thread, der alle Wire-Nachrichten in die inbox legt.
// Der Main-Thread pollt die inbox pro Frame und sendet Requests direkt
// (shared.send_wire ist threadsicher).

import "base:runtime"
import "core:crypto/ecdh"
import "core:encoding/hex"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"

import shared "../shared"

DeviceKey :: ecdh.Private_Key

Conn_Phase :: enum {
	Disconnected,
	Connecting,
	Auth_Needed,
	Setup_Needed,
	Ready,
	Failed,
}

// Zustand eines Channels inkl. UI-Zustand (Scroll, Unread, Layout-Cache).
Channel_State :: struct {
	ch:              shared.Channel,
	messages:        [dynamic]shared.Chat_Message,
	history_loaded:  bool,
	history_loading: bool,
	history_done:    bool, // ältestes Ende erreicht (Server lieferte < limit)
	unread:          int,
	scroll:          Scroll,
	stick_bottom:    bool, // am Ende? → Autoscroll bei neuen Nachrichten

	// Read-Tracking für den „Neu"-Divider
	last_read_id: u64,
	divider_id:   u64, // Divider vor erster Nachricht mit id > divider_id (0 = keiner)

	// Zeilen-Layout-Cache (Rebuild bei Breiten-/Nachrichten-/Divider-Änderung)
	rows:          [dynamic]Msg_Row,
	rows_w:        f32,
	rows_n:        int,
	rows_divider:  u64,
	rows_edit:     u64, // Nachricht im Inline-Edit (Teil des Cache-Schlüssels)
	rows_edit_h:   f32, // Editor-Box-Höhe beim letzten Aufbau
	content_h:     f32,
	adjust_scroll: bool, // nach History-Prepend Scroll-Position erhalten
}

// Laufender Call eines Channels (aus EV_CALL_STATE bzw. list_channels).
Channel_Call :: struct {
	peers:      []shared.Call_Peer,
	msg_id:     u64, // Systemnachricht des Calls (Chat-Karte)
	started_ms: i64, // Unix-ms des Call-Starts (Server-Zeit)
}

// Kontext für ausstehende Requests (seq → was war das?).
Pending :: struct {
	kind:       string,
	channel_id: u64,
	user_id:    u64,
	message_id: u64, // bei edit_*/message_history: betroffene Nachricht
	before_id:  u64, // bei history: Paging-Anker (0 = initiale Ladung)
}

Server_Conn :: struct {
	// --- Identität / Config ---
	addr:         string,
	cfg_index:    int, // Index in app.cfg.servers
	expected_pub: string, // gepinnter Server-Key (hex) beim Verbindungsstart
	token:        string, // Token beim Verbindungsstart (für resume)

	// --- geteilt zwischen Worker- und Main-Thread (mu schützt alles hier) ---
	mu:          sync.Mutex,
	phase:       Conn_Phase,
	err_text:    string, // Fehlertext bei Failed
	inbox:       [dynamic]shared.Wire,
	got_pub:     string, // tatsächlicher Server-Key nach Handshake (hex)
	new_token:   string, // von resume erneuertes Token ("" = unverändert)
	token_bad:   bool, // resume lieferte invalid_token → Token verwerfen
	dirty:       bool, // Config-relevante Änderung durch den Worker
	gen:         int, // Verbindungs-Generation (Schutz bei Reconnect)

	// --- nur Worker bis Phase gesetzt, danach nur Main ---
	conn:         shared.Secure_Conn,
	next_seq:     u64,
	me:           shared.User,
	server_name:  string,
	initialized:  bool,
	setup_needed: bool,

	// --- nur Main-Thread ---
	pending:        map[u64]Pending,
	users:          [dynamic]shared.User,
	channels:       [dynamic]Channel_State,
	active_channel: u64, // Channel-ID, 0 = keiner
	synced:         bool, // list_users/list_channels nach Ready gesendet?
	sidebar_scroll: Scroll,
	calls:          map[u64]Channel_Call, // laufende Calls (channel_id → Stand)

	// Reconnect-Verwaltung (Main-Thread)
	prev_phase:  Conn_Phase,
	retry_count: int,
	retry_at:    f64, // rl.GetTime()-Zeitpunkt des nächsten Auto-Versuchs (0 = keiner)

	// TCP-Latenz (Main-Thread): alle 5 s ein K_PING, geglätteter RTT für
	// den Indikator in der Kopfzeile. Höchstens ein Ping unterwegs.
	rtt_ms:      f32, // 0 = noch kein Messwert
	rtt_pending: bool,
	rtt_sent:    i64, // mono_ms beim Senden
	rtt_last:    i64, // mono_ms des letzten Ping-Versands

	// --- UI-Zustand (nur Main-Thread) ---
	auth_tab:      int, // 0 = Anmelden, 1 = Registrieren
	auth_user:     Text_Input,
	auth_display:  Text_Input,
	auth_pass:     Text_Input,
	auth_error:    string,
	auth_busy:     bool,
	show_pass:     bool,
	setup_input:   Text_Input,
	setup_error:   string,
	msg_input:     Text_Input,
	input_ed:      Editor_State, // Scroll/Caret-Zustand des Eingabefelds

	// Inline-Edit einer Nachricht (0 = keiner aktiv)
	edit_msg_id:  u64,
	edit_channel: u64,
	edit_input:   Text_Input,
	edit_ed:      Editor_State,
	edit_busy:    bool, // Commit unterwegs

	device_key: ^DeviceKey,
}

conn_create :: proc(addr: string, cfg_index: int, expected_pub: string, token: string, key: ^DeviceKey) -> ^Server_Conn {
	c := new(Server_Conn)
	c.addr = strings.clone(addr)
	c.cfg_index = cfg_index
	c.expected_pub = strings.clone(expected_pub)
	c.token = strings.clone(token)
	c.device_key = key
	c.phase = .Disconnected
	c.next_seq = 1
	return c
}

// Verbindungsaufbau starten (Main-Thread). Setzt den Zustand zurück.
conn_start :: proc(c: ^Server_Conn) {
	sync.lock(&c.mu)
	c.gen += 1
	gen := c.gen
	c.phase = .Connecting
	c.err_text = ""
	clear(&c.inbox)
	c.got_pub = ""
	c.new_token = ""
	c.token_bad = false
	c.dirty = false
	sync.unlock(&c.mu)

	c.next_seq = 1
	clear(&c.pending)
	clear(&c.users)
	clear(&c.channels)
	clear(&c.calls)
	c.active_channel = 0
	c.synced = false
	c.rtt_ms = 0
	c.rtt_pending = false
	c.rtt_last = 0
	c.auth_error = ""
	c.auth_busy = false
	c.setup_error = ""

	// Ein offener Inline-Edit überlebt den Reconnect nicht (Channels sind weg)
	c.edit_msg_id = 0
	c.edit_channel = 0
	c.edit_busy = false
	ti_clear(&c.edit_input)

	thread.run_with_poly_data2(c, gen, conn_worker)
}

@(private = "file")
worker_fail :: proc(c: ^Server_Conn, gen: int, msg: string) {
	sync.lock(&c.mu)
	if c.gen == gen {
		c.err_text = msg
		c.phase = .Failed
	}
	sync.unlock(&c.mu)
}

@(private = "file")
worker_set_phase :: proc(c: ^Server_Conn, gen: int, p: Conn_Phase) -> bool {
	sync.lock(&c.mu)
	defer sync.unlock(&c.mu)
	if c.gen != gen {
		return false
	}
	c.phase = p
	return true
}

// Auf die Antwort mit gegebener seq warten; Events (seq==0), die dazwischen
// eintreffen, landen in der inbox. Alloziert mit context.allocator (heap).
@(private = "file")
worker_wait_reply :: proc(c: ^Server_Conn, gen: int, seq: u64) -> (shared.Wire, bool) {
	for {
		w, ok := shared.recv_wire(&c.conn, context.allocator)
		if !ok {
			return {}, false
		}
		if w.seq == seq {
			return w, true
		}
		if w.seq == 0 {
			sync.lock(&c.mu)
			if c.gen == gen {
				append(&c.inbox, w)
			}
			sync.unlock(&c.mu)
		}
		// Antworten auf fremde seqs vor dem Auth gibt es nicht → ignorieren
	}
}

// Worker-Thread: Verbindung aufbauen, dann Reader-Loop.
@(private = "file")
conn_worker :: proc(c: ^Server_Conn, gen: int) {
	defer runtime.default_temp_allocator_destroy(nil)

	// 1. TCP + Noise-Handshake
	sock, derr := net.dial_tcp(c.addr)
	if derr != nil {
		worker_fail(c, gen, "Verbindung fehlgeschlagen")
		return
	}
	if !shared.client_handshake(&c.conn, sock, c.device_key) {
		net.close(sock)
		worker_fail(c, gen, "Handshake fehlgeschlagen")
		return
	}
	free_all(context.temp_allocator)

	// 2. TOFU-Pinning des Server-Keys
	pub_enc, _ := hex.encode(c.conn.peer_static[:], context.allocator)
	pub := string(pub_enc)
	if c.expected_pub != "" && c.expected_pub != pub {
		net.close(sock)
		worker_fail(c, gen, "Server-Schlüssel hat sich geändert!")
		return
	}
	if c.expected_pub == "" {
		sync.lock(&c.mu)
		if c.gen == gen {
			c.got_pub = pub
			c.dirty = true
		}
		sync.unlock(&c.mu)
	}

	// 3. server_info
	seq := u64(1)
	if !shared.send_wire(&c.conn, {kind = shared.K_SERVER_INFO, seq = seq}) {
		net.close(sock)
		worker_fail(c, gen, "Verbindung getrennt")
		return
	}
	info, iok := worker_wait_reply(c, gen, seq)
	if !iok {
		net.close(sock)
		worker_fail(c, gen, "Verbindung getrennt")
		return
	}
	c.server_name = info.server_name
	c.initialized = info.initialized
	c.setup_needed = info.setup_needed

	// 4. Token vorhanden → Session fortsetzen
	next_phase := Conn_Phase.Auth_Needed
	if c.token != "" {
		seq += 1
		if !shared.send_wire(&c.conn, {kind = shared.K_RESUME, seq = seq, token = c.token}) {
			net.close(sock)
			worker_fail(c, gen, "Verbindung getrennt")
			return
		}
		resp, rok := worker_wait_reply(c, gen, seq)
		if !rok {
			net.close(sock)
			worker_fail(c, gen, "Verbindung getrennt")
			return
		}
		if resp.ok {
			c.me = resp.user
			c.server_name = resp.server_name
			c.initialized = resp.initialized
			c.setup_needed = resp.setup_needed
			next_phase = .Setup_Needed if resp.setup_needed else .Ready
			sync.lock(&c.mu)
			if c.gen == gen {
				if resp.token != "" && resp.token != c.token {
					c.new_token = resp.token
				}
				c.dirty = true
			}
			sync.unlock(&c.mu)
		} else {
			// invalid_token (oder anderes) → Token verwerfen, Login-Screen
			sync.lock(&c.mu)
			if c.gen == gen {
				c.token_bad = true
				c.dirty = true
			}
			sync.unlock(&c.mu)
			next_phase = .Auth_Needed
		}
	}

	c.next_seq = seq + 1
	free_all(context.temp_allocator)

	if !worker_set_phase(c, gen, next_phase) {
		net.close(sock)
		return
	}

	// 5. Reader-Loop: alle weiteren Nachrichten in die inbox
	for {
		w, ok := shared.recv_wire(&c.conn, context.allocator)
		free_all(context.temp_allocator)
		if !ok {
			worker_fail(c, gen, "Verbindung getrennt")
			net.close(sock)
			return
		}
		sync.lock(&c.mu)
		stale := c.gen != gen
		if !stale {
			append(&c.inbox, w)
		}
		sync.unlock(&c.mu)
		if stale {
			net.close(sock)
			return
		}
	}
}

// Laufende Worker-/Reader-Threads dieser Verbindung invalidieren
// (z. B. bevor die Verbindung entfernt wird).
conn_invalidate :: proc(c: ^Server_Conn) {
	sync.lock(&c.mu)
	c.gen += 1
	c.phase = .Disconnected
	sync.unlock(&c.mu)
}

// Main-Thread: Phase threadsicher lesen.
conn_phase :: proc(c: ^Server_Conn) -> Conn_Phase {
	sync.lock(&c.mu)
	defer sync.unlock(&c.mu)
	return c.phase
}

// Main-Thread: Request senden und Pending-Eintrag anlegen.
conn_request :: proc(c: ^Server_Conn, w: shared.Wire, p: Pending = {}) -> u64 {
	w := w
	w.seq = c.next_seq
	c.next_seq += 1
	p := p
	p.kind = w.kind
	c.pending[w.seq] = p
	if !shared.send_wire(&c.conn, w) {
		delete_key(&c.pending, w.seq)
		return 0
	}
	return w.seq
}

conn_find_channel :: proc(c: ^Server_Conn, id: u64) -> ^Channel_State {
	for &cs in c.channels {
		if cs.ch.id == id {
			return &cs
		}
	}
	return nil
}

conn_find_user :: proc(c: ^Server_Conn, id: u64) -> ^shared.User {
	for &u in c.users {
		if u.id == id {
			return &u
		}
	}
	return nil
}

// DM-Channel mit einem bestimmten User finden (falls vorhanden).
conn_find_dm :: proc(c: ^Server_Conn, user_id: u64) -> ^Channel_State {
	for &cs in c.channels {
		if !cs.ch.is_dm {
			continue
		}
		for m in cs.ch.member_ids {
			if m == user_id {
				return &cs
			}
		}
	}
	return nil
}

// Anzeigename des DM-Partners (der andere User im DM-Channel).
dm_partner :: proc(c: ^Server_Conn, cs: ^Channel_State) -> ^shared.User {
	for m in cs.ch.member_ids {
		if m != c.me.id {
			return conn_find_user(c, m)
		}
	}
	return nil
}

conn_has_unread :: proc(c: ^Server_Conn) -> bool {
	for &cs in c.channels {
		if cs.unread > 0 {
			return true
		}
	}
	return false
}
