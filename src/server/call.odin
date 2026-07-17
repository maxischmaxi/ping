package main

// Voice-Calls: der Server ist eine kleine SFU (Selective Forwarding Unit).
// Er decodiert kein Audio — er prüft pro UDP-Paket nur das Poly1305-Tag
// (Absender-Authentizität) und leitet die verschlüsselten Bytes unverändert
// an die anderen Call-Teilnehmer weiter. Signalisierung (join/leave/mute)
// läuft über den Noise-TCP-Kanal, der auch call_key/udp_token verteilt.
//
// Calls sind flüchtig (nur RAM): ein Server-Neustart beendet sie.
// Lock-Ordnung: g.mu (Chat) IMMER vor g_calls.mu (Audio-Routing) —
// der UDP-Hot-Path nimmt ausschließlich g_calls.mu.

import "core:bytes"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:thread"

import shared "../shared"

Call_Member :: struct {
	user_id:    u64,
	conn:       ^Client_Conn, // die Verbindung, die den Call hält
	ssrc:       u32,
	token:      [shared.VOICE_TOKEN_LEN]byte,
	muted:      bool,
	addr:       net.Endpoint,
	addr_ok:    bool, // HELLO angekommen → Audio-Ziel bekannt
	last_seq:   u64,  // höchste Audio-seq (grobes Anti-Replay-Fenster)
	last_hello: u64,
	srv_seq:    u64,  // Server-Zähler für WELCOME/PONG an diesen Member
}

Call :: struct {
	id:         u64,
	channel_id: u64,
	key:        [shared.VOICE_KEY_LEN]byte,
	members:    [dynamic]Call_Member,

	// Für die Chat-Systemnachricht des Calls („X hat einen Call gestartet“ →
	// beim Ende um die Dauer ergänzt).
	starter_id: u64,
	started_ms: i64,
	msg_id:     u64,
}

g_calls: struct {
	mu:        sync.Mutex,
	by_id:     map[u64]^Call,
	ssrc_call: map[u32]u64, // ssrc → call_id (UDP-Routing ohne Scan)
	next_id:   u64,
	next_ssrc: u32,
	sock:      net.UDP_Socket,
	port:      int,
}

// ---------- Helfer (nur unter g_calls.mu) ----------

call_by_channel_locked :: proc(channel_id: u64) -> ^Call {
	for _, call in g_calls.by_id {
		if call.channel_id == channel_id {
			return call
		}
	}
	return nil
}

call_member_idx_locked :: proc(call: ^Call, ssrc: u32) -> int {
	for m, i in call.members {
		if m.ssrc == ssrc {
			return i
		}
	}
	return -1
}

call_info_locked :: proc(call: ^Call) -> shared.Call_Info {
	peers := make([]shared.Call_Peer, len(call.members), context.temp_allocator)
	for m, i in call.members {
		peers[i] = {user_id = m.user_id, ssrc = m.ssrc, muted = m.muted}
	}
	return {channel_id = call.channel_id, peers = peers, msg_id = call.msg_id, started_ms = call.started_ms}
}

// ---------- Presence (unter g.mu rufen) ----------

// true, wenn der User gerade in irgendeinem Call steckt (Headphone-Symbol).
call_user_active :: proc(user_id: u64) -> bool {
	sync.lock(&g_calls.mu)
	defer sync.unlock(&g_calls.mu)
	for _, call in g_calls.by_id {
		for m in call.members {
			if m.user_id == user_id {
				return true
			}
		}
	}
	return false
}

// in_call hat sich womöglich geändert → Presence an alle.
call_presence_event :: proc(user_id: u64) {
	if u := find_user_by_id(user_id); u != nil {
		broadcast_authed(shared.Wire{kind = shared.EV_USER, user = wire_user(u)}, nil)
	}
}

call_state_event :: proc(channel_id: u64, info: shared.Call_Info, exclude: ^Client_Conn) {
	if ch := find_channel(channel_id); ch != nil {
		ev := shared.Wire{kind = shared.EV_CALL_STATE, channel_id = channel_id, call = info}
		broadcast_members(ch, ev, exclude)
	}
}

// ---------- TCP-Handler (unter g.mu) ----------

handle_call_join :: proc(c: ^Client_Conn, w: shared.Wire) {
	ch := find_channel(w.channel_id)
	if ch == nil || !is_member(ch, c.user_id) {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}

	// Ein User ist höchstens in EINEM Call: alte Mitgliedschaften lösen.
	call_leave_everywhere(c.user_id, nil, w.channel_id)

	sync.lock(&g_calls.mu)
	call := call_by_channel_locked(ch.id)
	started := false
	if call == nil {
		call = new(Call)
		g_calls.next_id += 1
		call.id = g_calls.next_id
		call.channel_id = ch.id
		call.starter_id = c.user_id
		call.started_ms = now_ms()
		crypto.rand_bytes(call.key[:])
		g_calls.by_id[call.id] = call
		started = true
	}
	m := Call_Member{
		user_id = c.user_id,
		conn    = c,
	}
	g_calls.next_ssrc += 1
	m.ssrc = g_calls.next_ssrc
	crypto.rand_bytes(m.token[:])
	append(&call.members, m)
	g_calls.ssrc_call[m.ssrc] = call.id

	info := call_info_locked(call)
	call_id := call.id
	started_ms := call.started_ms
	key_hex := string(hex.encode(call.key[:], context.temp_allocator))
	tok_hex := string(hex.encode(m.token[:], context.temp_allocator))
	sync.unlock(&g_calls.mu)

	// Neuer Call → Systemnachricht in den Channel (persistiert; das Ende
	// trägt später call_end_ms nach). Mutationen an Calls laufen alle unter
	// g.mu, daher darf call.msg_id nach dem Relock gesetzt werden.
	if started {
		msg := shared.Chat_Message{
			id            = g.meta.next_message_id,
			channel_id    = ch.id,
			author_id     = c.user_id,
			ts_ms         = started_ms,
			call_start_ms = started_ms,
		}
		g.meta.next_message_id += 1
		if store_message(ch, msg) {
			save_meta()
			sync.lock(&g_calls.mu)
			call.msg_id = msg.id
			sync.unlock(&g_calls.mu)
			info.msg_id = msg.id
			broadcast_members(ch, shared.Wire{kind = shared.EV_MESSAGE, message = msg}, nil)
		} else {
			fmt.printfln("[error] Call-Nachricht %d (Channel %d) konnte nicht gespeichert werden", msg.id, ch.id)
		}
	}

	resp := shared.wire_ok(w.kind, w.seq)
	resp.channel_id = ch.id
	resp.call_id = call_id
	resp.call_key = key_hex
	resp.udp_token = tok_hex
	resp.ssrc = m.ssrc
	resp.udp_port = g_calls.port
	resp.call = info
	send_to(c, resp)

	call_state_event(ch.id, info, c)
	call_presence_event(c.user_id)
}

// Löst Call-Mitgliedschaften des Users (Rejoin, Leave, Disconnect, Wechsel)
// und sendet die nötigen Events. by_conn != nil beschränkt auf
// Mitgliedschaften genau dieser Verbindung (TCP-Disconnect). Der Channel in
// skip_event_channel bekommt gleich ohnehin ein frisches Event (Join-Pfad).
call_leave_everywhere :: proc(user_id: u64, by_conn: ^Client_Conn, skip_event_channel: u64) {
	Left :: struct {
		channel_id: u64,
		info:       shared.Call_Info,
	}
	Ended :: struct {
		channel_id: u64,
		msg_id:     u64,
		starter_id: u64,
		started_ms: i64,
	}
	lefts := make([dynamic]Left, context.temp_allocator)
	ended := make([dynamic]Ended, context.temp_allocator)
	was_in := false

	sync.lock(&g_calls.mu)
	drop := make([dynamic]^Call, context.temp_allocator)
	for _, call in g_calls.by_id {
		removed := false
		for i := 0; i < len(call.members); {
			m := call.members[i]
			if m.user_id == user_id && (by_conn == nil || m.conn == by_conn) {
				delete_key(&g_calls.ssrc_call, m.ssrc)
				ordered_remove(&call.members, i)
				removed = true
				was_in = true
			} else {
				i += 1
			}
		}
		if removed {
			append(&lefts, Left{call.channel_id, call_info_locked(call)})
			if len(call.members) == 0 {
				append(&drop, call)
			}
		}
	}
	for call in drop {
		if call.msg_id != 0 {
			append(&ended, Ended{call.channel_id, call.msg_id, call.starter_id, call.started_ms})
		}
		delete_key(&g_calls.by_id, call.id)
		delete(call.members)
		free(call)
	}
	sync.unlock(&g_calls.mu)

	for l in lefts {
		if l.channel_id != skip_event_channel {
			call_state_event(l.channel_id, l.info, nil)
		}
	}

	// Beendete Calls: Systemnachricht um die Endzeit ergänzen (persistiert)
	// und als Edit-Event an die Mitglieder verteilen (Karte → „Dauer …“).
	for e in ended {
		ch := find_channel(e.channel_id)
		if ch == nil {
			continue
		}
		end := now_ms()
		if !store_call_end(ch, e.msg_id, end) {
			fmt.printfln("[error] Call-Ende %d (Channel %d) konnte nicht gespeichert werden", e.msg_id, ch.id)
			continue
		}
		msg := shared.Chat_Message{
			id            = e.msg_id,
			channel_id    = e.channel_id,
			author_id     = e.starter_id,
			ts_ms         = e.started_ms,
			call_start_ms = e.started_ms,
			call_end_ms   = end,
		}
		broadcast_members(ch, shared.Wire{kind = shared.EV_MESSAGE_EDITED, message = msg}, nil)
	}

	if was_in {
		call_presence_event(user_id)
	}
}

handle_call_leave :: proc(c: ^Client_Conn, w: shared.Wire) {
	call_leave_everywhere(c.user_id, nil, 0)
	send_to(c, shared.wire_ok(w.kind, w.seq))
}

handle_call_mute :: proc(c: ^Client_Conn, w: shared.Wire) {
	sync.lock(&g_calls.mu)
	found := false
	channel_id: u64
	info: shared.Call_Info
	for _, call in g_calls.by_id {
		for &m in call.members {
			if m.user_id == c.user_id {
				m.muted = w.muted
				found = true
			}
		}
		if found {
			channel_id = call.channel_id
			info = call_info_locked(call)
			break
		}
	}
	sync.unlock(&g_calls.mu)

	if !found {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	send_to(c, shared.wire_ok(w.kind, w.seq))
	call_state_event(channel_id, info, c)
}

// Laufende Calls für die list_channels-Antwort (nur Channels des Users).
calls_for_user :: proc(user_id: u64) -> []shared.Call_Info {
	infos := make([dynamic]shared.Call_Info, context.temp_allocator)
	sync.lock(&g_calls.mu)
	for _, call in g_calls.by_id {
		if ch := find_channel(call.channel_id); ch != nil && is_member(ch, user_id) {
			append(&infos, call_info_locked(call))
		}
	}
	sync.unlock(&g_calls.mu)
	return infos[:]
}

// ---------- UDP (SFU-Datenpfad) ----------

call_udp_start :: proc(port: int) -> bool {
	sock, err := net.make_bound_udp_socket(net.IP4_Any, port)
	if err != nil {
		fmt.printfln("[error] UDP-Socket auf Port %d fehlgeschlagen: %v", port, err)
		return false
	}
	g_calls.sock = sock
	g_calls.port = port
	g_calls.by_id = make(map[u64]^Call)
	g_calls.ssrc_call = make(map[u32]u64)
	thread.create_and_start(call_udp_loop, nil, .Normal, true)
	return true
}

call_udp_loop :: proc() {
	buf: [shared.VOICE_MAX_PACKET + 64]byte
	plain: [shared.VOICE_MAX_PACKET]byte
	out: [shared.VOICE_MAX_PACKET]byte

	for {
		n, from, err := net.recv_udp(g_calls.sock, buf[:])
		if err != nil || n <= 0 {
			continue
		}
		pkt := buf[:n]
		vp, ok := shared.voice_parse(pkt)
		if !ok {
			continue
		}

		sync.lock(&g_calls.mu)
		switch vp.ptype {
		case shared.VP_HELLO:
			call := g_calls.by_id[vp.call_id]
			if call == nil {
				break
			}
			idx := call_member_idx_locked(call, vp.ssrc)
			if idx < 0 {
				break
			}
			m := &call.members[idx]
			if m.addr_ok && vp.seq <= m.last_hello {
				break // Replay eines alten HELLO
			}
			pl, opened := shared.voice_open(vp, call.key[:], plain[:])
			if !opened || !bytes.equal(pl, m.token[:]) {
				break
			}
			m.addr = from
			m.addr_ok = true
			m.last_hello = vp.seq
			m.srv_seq += 1
			if wn := shared.voice_pack(out[:], call.key[:], shared.VP_WELCOME, 0, m.ssrc, m.srv_seq, nil); wn > 0 {
				_, _ = net.send_udp(g_calls.sock, out[:wn], from)
			}

		case shared.VP_AUDIO, shared.VP_PING:
			call_id, known := g_calls.ssrc_call[vp.ssrc]
			if !known {
				break
			}
			call := g_calls.by_id[call_id]
			if call == nil {
				break
			}
			idx := call_member_idx_locked(call, vp.ssrc)
			if idx < 0 {
				break
			}
			m := &call.members[idx]
			if !m.addr_ok || from != m.addr {
				break
			}
			if vp.seq + 64 <= m.last_seq {
				break // weit außerhalb des Fensters (Replay/uralt)
			}
			pl, opened := shared.voice_open(vp, call.key[:], plain[:])
			if !opened {
				break
			}
			m.last_seq = max(m.last_seq, vp.seq)

			if vp.ptype == shared.VP_PING {
				m.srv_seq += 1
				if wn := shared.voice_pack(out[:], call.key[:], shared.VP_PONG, 0, m.ssrc, m.srv_seq, pl); wn > 0 {
					_, _ = net.send_udp(g_calls.sock, out[:wn], from)
				}
				break
			}
			// AUDIO: authentifiziert → Original-Bytes an alle anderen.
			for &o in call.members {
				if o.ssrc != vp.ssrc && o.addr_ok {
					_, _ = net.send_udp(g_calls.sock, pkt, o.addr)
				}
			}

		case shared.VP_WELCOME, shared.VP_PONG:
		// Server-eigene Typen von außen → ignorieren.
		}
		sync.unlock(&g_calls.mu)
	}
}
