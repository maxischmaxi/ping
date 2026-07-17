package smoke

// Headless-Protokoll-Smoke-Test gegen einen laufenden flurfunk-Server.
// Nutzung: smoke <host:port>   (Server muss mit frischem Datenverzeichnis laufen)
// Bei Hängern von außen mit `timeout` begrenzen.

import "core:bytes"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:os"
import "core:crypto/ecdh"
import "core:strings"

import shared "../../src/shared"

Test_Conn :: struct {
	secure:   shared.Secure_Conn,
	priv:     ecdh.Private_Key,
	pending:  [dynamic]shared.Wire,
	next_seq: u64,
	label:    string,
}

fail :: proc(step: string, args: ..any) {
	fmt.eprintf("FEHLGESCHLAGEN: %s ", step)
	fmt.eprintln(..args)
	os.exit(1)
}

step_ok :: proc(step: string) {
	fmt.printfln("ok: %s", step)
}

connect :: proc(addr: string, label: string) -> ^Test_Conn {
	tc := new(Test_Conn)
	tc.label = label
	tc.next_seq = 1
	sock, err := net.dial_tcp(addr)
	if err != nil {
		fail("dial", label, err)
	}
	if !shared.generate_static_key(&tc.priv) {
		fail("keygen", label)
	}
	if !shared.client_handshake(&tc.secure, sock, &tc.priv) {
		fail("handshake", label)
	}
	return tc
}

// Liest Wires, bis die Antwort auf (kind, seq) kommt; Events werden gepuffert.
request :: proc(tc: ^Test_Conn, w: shared.Wire) -> shared.Wire {
	w := w
	w.seq = tc.next_seq
	tc.next_seq += 1
	if !shared.send_wire(&tc.secure, w) {
		fail("send", tc.label, w.kind)
	}
	for {
		r, ok := shared.recv_wire(&tc.secure)
		if !ok {
			fail("recv (Antwort)", tc.label, w.kind)
		}
		if r.seq == w.seq && r.kind == w.kind {
			return r
		}
		append(&tc.pending, r)
	}
}

must :: proc(tc: ^Test_Conn, w: shared.Wire, step: string) -> shared.Wire {
	r := request(tc, w)
	if !r.ok || r.err != "" {
		fail(step, tc.label, "err =", r.err)
	}
	step_ok(step)
	return r
}

must_err :: proc(tc: ^Test_Conn, w: shared.Wire, want_err: string, step: string) {
	r := request(tc, w)
	if r.err != want_err {
		fail(step, tc.label, "erwartet err", want_err, "bekommen:", r.err, r.ok)
	}
	step_ok(step)
}

// UDP-Voice: Socket anlegen, HELLO senden, WELCOME abwarten.
udp_join :: proc(key: []byte, call_id: u64, ssrc: u32, token: []byte, srv: net.Endpoint, step: string) -> net.UDP_Socket {
	sock, serr := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if serr != nil {
		fail(step, "udp-socket:", serr)
	}
	buf: [shared.VOICE_MAX_PACKET]byte
	n := shared.voice_pack(buf[:], key, shared.VP_HELLO, call_id, ssrc, 1, token)
	if n == 0 {
		fail(step, "voice_pack")
	}
	if _, err := net.send_udp(sock, buf[:n], srv); err != nil {
		fail(step, "hello send:", err)
	}
	rbuf: [shared.VOICE_MAX_PACKET]byte
	rn, _, rerr := net.recv_udp(sock, rbuf[:])
	if rerr != nil {
		fail(step, "welcome recv:", rerr)
	}
	vp, ok := shared.voice_parse(rbuf[:rn])
	if !ok || vp.ptype != shared.VP_WELCOME || vp.ssrc != ssrc {
		fail(step, "welcome kaputt")
	}
	plain: [64]byte
	if _, wok := shared.voice_open(vp, key, plain[:]); !wok {
		fail(step, "welcome nicht authentisch")
	}
	step_ok(step)
	return sock
}

// Genau ein Voice-Paket empfangen, parsen und öffnen.
udp_expect :: proc(sock: net.UDP_Socket, key: []byte, step: string) -> (vp: shared.Voice_Packet, payload: []byte) {
	rbuf: [shared.VOICE_MAX_PACKET]byte
	rn, _, rerr := net.recv_udp(sock, rbuf[:])
	if rerr != nil {
		fail(step, "recv:", rerr)
	}
	ok: bool
	vp, ok = shared.voice_parse(rbuf[:rn])
	if !ok {
		fail(step, "parse")
	}
	plain := make([]byte, shared.VOICE_MAX_PACKET)
	payload, ok = shared.voice_open(vp, key, plain)
	if !ok {
		fail(step, "open (tag falsch?)")
	}
	vp.hdr = nil // zeigte in den Stack-Puffer
	vp.sealed = nil
	step_ok(step)
	return
}

// Sucht ein Event in Puffer/Stream.
expect_event :: proc(tc: ^Test_Conn, kind: string, step: string) -> shared.Wire {
	for w, i in tc.pending {
		if w.kind == kind {
			ordered_remove(&tc.pending, i)
			step_ok(step)
			return w
		}
	}
	for {
		r, ok := shared.recv_wire(&tc.secure)
		if !ok {
			fail(step, tc.label, "Verbindung zu beim Warten auf", kind)
		}
		if r.kind == kind {
			step_ok(step)
			return r
		}
		append(&tc.pending, r)
	}
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("Nutzung: smoke <host:port>")
		os.exit(2)
	}
	addr := os.args[1]

	// 1) Frischer Server: Info + Admin-Registrierung + Setup
	a := connect(addr, "A")
	info := request(a, {kind = shared.K_SERVER_INFO})
	if info.initialized || !info.setup_needed {
		fail("server_info frisch", "initialized =", info.initialized, "setup_needed =", info.setup_needed)
	}
	step_ok("server_info: frischer Server")

	reg := must(a, {kind = shared.K_REGISTER, username = "alice", password = "geheim123", display_name = "Alice"}, "admin-registrierung")
	if !reg.user.is_admin || !reg.setup_needed || reg.token == "" {
		fail("admin-flags", "is_admin =", reg.user.is_admin, "setup_needed =", reg.setup_needed)
	}
	alice_id := reg.user.id
	alice_token := reg.token

	must(a, {kind = shared.K_SETUP, server_name = "ACME Corp"}, "setup servername")

	// 2) Zweiter Client: Info + normale Registrierung
	b := connect(addr, "B")
	info2 := request(b, {kind = shared.K_SERVER_INFO})
	if !info2.initialized || info2.server_name != "ACME Corp" {
		fail("server_info nach setup", "name =", info2.server_name)
	}
	step_ok("server_info: initialisiert mit Namen")

	must_err(b, {kind = shared.K_LIST_USERS}, "not_authenticated", "auth-gate")
	must_err(b, {kind = shared.K_REGISTER, username = "alice", password = "xxxxxxxx"}, "username_taken", "doppelter username")

	regb := must(b, {kind = shared.K_REGISTER, username = "bob", password = "huntert2", display_name = "Bob"}, "registrierung bob")
	if regb.user.is_admin || regb.setup_needed {
		fail("bob-flags", "bob darf kein admin sein")
	}
	bob_id := regb.user.id

	// 3) Channel + Invite + Nachrichten
	ch := must(a, {kind = shared.K_CREATE_CHANNEL, name = "general"}, "channel erstellen").channel
	must_err(a, {kind = shared.K_CREATE_CHANNEL, name = "general"}, "name_taken", "channelname doppelt")
	must_err(b, {kind = shared.K_SEND, channel_id = ch.id, text = "hi"}, "not_a_member", "send ohne mitgliedschaft")

	inv := must(a, {kind = shared.K_INVITE, channel_id = ch.id, user_id = bob_id}, "invite bob")
	if len(inv.channel.member_ids) != 2 {
		fail("invite mitglieder", "erwartet 2, bekommen", len(inv.channel.member_ids))
	}
	evch := expect_event(b, shared.EV_CHANNEL, "bob bekommt ev_channel")
	if evch.channel.id != ch.id {
		fail("ev_channel id", "falscher channel")
	}

	sent := must(a, {kind = shared.K_SEND, channel_id = ch.id, text = "hallo *welt* von _alice_"}, "nachricht senden")
	if sent.message.id == 0 || sent.message.ts_ms == 0 {
		fail("message meta", "id/ts fehlen")
	}
	evmsg := expect_event(b, shared.EV_MESSAGE, "bob bekommt ev_message")
	if evmsg.message.text != "hallo *welt* von _alice_" || evmsg.message.author_id != alice_id {
		fail("ev_message inhalt", "text =", evmsg.message.text)
	}

	must(b, {kind = shared.K_SEND, channel_id = ch.id, text = "hi zurück 🎉"}, "antwort von bob")
	evmsg2 := expect_event(a, shared.EV_MESSAGE, "alice bekommt ev_message")
	if evmsg2.message.author_id != bob_id {
		fail("ev_message autor", "erwartet bob")
	}

	hist := must(b, {kind = shared.K_HISTORY, channel_id = ch.id}, "history")
	if len(hist.messages) != 2 || hist.messages[0].author_id != alice_id || hist.messages[1].author_id != bob_id {
		fail("history inhalt", "anzahl =", len(hist.messages))
	}
	if hist.messages[0].id >= hist.messages[1].id {
		fail("history reihenfolge", "nicht aufsteigend")
	}

	// 4) Listen
	lu := must(b, {kind = shared.K_LIST_USERS}, "list_users")
	if len(lu.users) != 2 {
		fail("list_users anzahl", "erwartet 2, bekommen", len(lu.users))
	}
	lc := must(b, {kind = shared.K_LIST_CHANNELS}, "list_channels")
	if len(lc.channels) != 1 {
		fail("list_channels anzahl", "erwartet 1, bekommen", len(lc.channels))
	}

	// 5) DM
	dm := must(b, {kind = shared.K_OPEN_DM, user_id = alice_id}, "dm öffnen").channel
	if !dm.is_dm || len(dm.member_ids) != 2 {
		fail("dm-channel", "is_dm =", dm.is_dm)
	}
	expect_event(a, shared.EV_CHANNEL, "alice bekommt ev_channel (dm)")
	must(b, {kind = shared.K_SEND, channel_id = dm.id, text = "psst, geheim"}, "dm senden")
	evdm := expect_event(a, shared.EV_MESSAGE, "alice bekommt dm")
	if evdm.message.channel_id != dm.id {
		fail("dm event", "falscher channel")
	}
	dm2 := must(a, {kind = shared.K_OPEN_DM, user_id = bob_id}, "dm nochmal öffnen").channel
	if dm2.id != dm.id {
		fail("dm dedupe", "neuer statt existierender DM")
	}

	// 6) Kick + Auth-Fehler
	must_err(b, {kind = shared.K_KICK, channel_id = ch.id, user_id = alice_id}, "not_allowed", "bob darf nicht kicken")
	must(a, {kind = shared.K_KICK, channel_id = ch.id, user_id = bob_id}, "alice kickt bob")
	evrm := expect_event(b, shared.EV_CHANNEL_REMOVED, "bob bekommt ev_channel_removed")
	if evrm.channel_id != ch.id {
		fail("ev_channel_removed id", "falscher channel")
	}
	must_err(b, {kind = shared.K_SEND, channel_id = ch.id, text = "bin ich noch drin?"}, "not_a_member", "send nach kick")

	// 7) Chunking (>32-KiB-Antworten), Pagination, leave, Validierung
	must_err(a, {kind = shared.K_CREATE_CHANNEL, name = "Große Halle"}, "invalid_request", "ungültiger channelname")
	must_err(a, {kind = shared.K_CREATE_CHANNEL, name = "BÜRO"}, "invalid_request", "großbuchstaben-umlaute abgelehnt")
	uml := must(a, {kind = shared.K_CREATE_CHANNEL, name = "büro-küche"}, "channel mit umlauten erstellen").channel
	if uml.name != "büro-küche" {
		fail("umlaut-channel", "name =", uml.name)
	}

	// Tabs und Spaces in Code-Blöcken überleben die Übertragung byte-genau
	tabtext := "```go\nfunc main() {\n\tif x {\n\t\tfmt.Println(\"tabs\")\n\t}\n    spaces()\n}\n```"
	tsend := must(a, {kind = shared.K_SEND, channel_id = uml.id, text = tabtext}, "nachricht mit tabs senden")
	if tsend.message.text != tabtext {
		fail("tab-echo", "text verändert:", tsend.message.text)
	}
	thist := must(a, {kind = shared.K_HISTORY, channel_id = uml.id}, "history mit tabs")
	if len(thist.messages) != 1 || thist.messages[0].text != tabtext {
		fail("tab-roundtrip", "tabs/spaces nicht byte-genau erhalten")
	}
	bulk := must(a, {kind = shared.K_CREATE_CHANNEL, name = "bulk"}, "bulk-channel erstellen").channel

	big := strings.repeat("x", 7000)
	too_big := strings.repeat("x", shared.MAX_MESSAGE_TEXT_LEN + 1)
	must_err(a, {kind = shared.K_SEND, channel_id = bulk.id, text = too_big}, "invalid_request", "nachricht zu lang")

	first_bulk_id: u64
	for i in 0 ..< 12 {
		r := request(a, {kind = shared.K_SEND, channel_id = bulk.id, text = big})
		if !r.ok {
			fail("bulk send", "nachricht", i, "err =", r.err)
		}
		if i == 0 {
			first_bulk_id = r.message.id
		}
	}
	step_ok("12 nachrichten à 7000 zeichen gesendet")

	h5 := must(a, {kind = shared.K_HISTORY, channel_id = bulk.id, limit = 5}, "history limit 5 (chunked, ~35KB)")
	if len(h5.messages) != 5 || len(h5.messages[0].text) != 7000 {
		fail("chunking", "anzahl =", len(h5.messages))
	}
	page2 := must(a, {kind = shared.K_HISTORY, channel_id = bulk.id, before_id = h5.messages[0].id, limit = 5}, "history pagination")
	if len(page2.messages) != 5 {
		fail("pagination anzahl", "erwartet 5, bekommen", len(page2.messages))
	}
	for m in page2.messages {
		if m.id >= h5.messages[0].id {
			fail("pagination filter", "id nicht < before_id")
		}
	}
	_ = first_bulk_id

	must(a, {kind = shared.K_INVITE, channel_id = bulk.id, user_id = bob_id}, "bob in bulk einladen")
	expect_event(b, shared.EV_CHANNEL, "bob bekommt ev_channel (bulk)")
	must(b, {kind = shared.K_LEAVE, channel_id = bulk.id}, "bob verlässt bulk")
	must_err(b, {kind = shared.K_SEND, channel_id = bulk.id, text = "noch da?"}, "not_a_member", "send nach leave")

	// 7b) Kanal löschen (nur Admin oder Ersteller)
	tmp := must(a, {kind = shared.K_CREATE_CHANNEL, name = "temp"}, "temp-channel erstellen").channel
	must(a, {kind = shared.K_INVITE, channel_id = tmp.id, user_id = bob_id}, "bob in temp einladen")
	expect_event(b, shared.EV_CHANNEL, "bob bekommt ev_channel (temp)")
	must_err(b, {kind = shared.K_DELETE_CHANNEL, channel_id = tmp.id}, "not_allowed", "bob darf temp nicht löschen")
	must(a, {kind = shared.K_DELETE_CHANNEL, channel_id = tmp.id}, "alice löscht temp")
	evdel := expect_event(b, shared.EV_CHANNEL_REMOVED, "bob bekommt ev_channel_removed (delete)")
	if evdel.channel_id != tmp.id || evdel.err != "deleted" {
		fail("delete event", "channel =", evdel.channel_id, "reason =", evdel.err)
	}
	must_err(a, {kind = shared.K_SEND, channel_id = tmp.id, text = "noch da?"}, "not_found", "send nach delete")

	// 7c) Nachrichten bearbeiten: Freigabe-Handshake, Limit, Versionen
	edch := must(a, {kind = shared.K_CREATE_CHANNEL, name = "edits"}, "edit-channel erstellen").channel
	must(a, {kind = shared.K_INVITE, channel_id = edch.id, user_id = bob_id}, "bob in edits einladen")
	expect_event(b, shared.EV_CHANNEL, "bob bekommt ev_channel (edits)")
	em := must(a, {kind = shared.K_SEND, channel_id = edch.id, text = "version eins"}, "edit-basis senden").message
	expect_event(b, shared.EV_MESSAGE, "bob bekommt edit-basis")

	must_err(b, {kind = shared.K_EDIT_START, channel_id = edch.id, message_id = em.id},
		"not_allowed", "bob darf alices nachricht nicht bearbeiten")
	must_err(a, {kind = shared.K_EDIT_START, channel_id = edch.id, message_id = 999_999},
		"not_found", "edit_start auf unbekannte nachricht")
	must_err(a, {kind = shared.K_EDIT_MESSAGE, channel_id = edch.id, message_id = em.id, text = "hack"},
		"edit_window", "edit ohne edit_start abgelehnt")

	// Abbrechen räumt die Freigabe wieder weg
	must(a, {kind = shared.K_EDIT_START, channel_id = edch.id, message_id = em.id}, "edit_start")
	must(a, {kind = shared.K_EDIT_CANCEL, channel_id = edch.id, message_id = em.id}, "edit_cancel")
	must_err(a, {kind = shared.K_EDIT_MESSAGE, channel_id = edch.id, message_id = em.id, text = "hack"},
		"edit_window", "edit nach cancel abgelehnt")

	// Drei Edits gehen durch (jeder startet die Frist neu), der vierte nicht
	edit_texts := [3]string{"version zwei", "version drei", "version vier"}
	for txt, i in edit_texts {
		must(a, {kind = shared.K_EDIT_START, channel_id = edch.id, message_id = em.id},
			fmt.tprintf("edit_start %d", i + 1))
		r := must(a, {kind = shared.K_EDIT_MESSAGE, channel_id = edch.id, message_id = em.id, text = txt},
			fmt.tprintf("edit %d", i + 1))
		if r.message.text != txt || r.message.edit_count != i + 1 || r.message.edited_ms == 0 {
			fail("edit-antwort", "text =", r.message.text, "count =", r.message.edit_count)
		}
		ev := expect_event(b, shared.EV_MESSAGE_EDITED, fmt.tprintf("bob bekommt ev_message_edited %d", i + 1))
		if ev.message.id != em.id || ev.message.text != txt || ev.message.edit_count != i + 1 {
			fail("edit-event", "text =", ev.message.text)
		}
	}
	must_err(a, {kind = shared.K_EDIT_START, channel_id = edch.id, message_id = em.id},
		"edit_limit", "vierter edit abgelehnt")
	must_err(a, {kind = shared.K_EDIT_MESSAGE, channel_id = edch.id, message_id = em.id, text = "   "},
		"invalid_request", "leerer edit-text abgelehnt")

	mh := must(b, {kind = shared.K_MESSAGE_HISTORY, channel_id = edch.id, message_id = em.id}, "message_history")
	if len(mh.messages) != 4 || mh.messages[0].text != "version eins" || mh.messages[3].text != "version vier" {
		fail("message_history versionen", "anzahl =", len(mh.messages))
	}
	if mh.messages[0].ts_ms > mh.messages[3].ts_ms {
		fail("message_history reihenfolge", "nicht aufsteigend")
	}
	eh := must(b, {kind = shared.K_HISTORY, channel_id = edch.id}, "channel-history nach edits")
	if len(eh.messages) != 1 || eh.messages[0].text != "version vier" || eh.messages[0].edit_count != 3 {
		fail("history nach edits", "text =", eh.messages[0].text, "count =", eh.messages[0].edit_count)
	}

	// 8) Login/Resume
	c := connect(addr, "C")
	must_err(c, {kind = shared.K_LOGIN, username = "alice", password = "falsch123"}, "invalid_credentials", "login falsches passwort")
	must_err(c, {kind = shared.K_RESUME, token = "deadbeef"}, "invalid_token", "resume kaputter token")
	res := must(c, {kind = shared.K_RESUME, token = alice_token}, "resume mit token")
	if res.user.id != alice_id || res.server_name != "ACME Corp" {
		fail("resume identität", "user =", res.user.username)
	}
	d := connect(addr, "D")
	lg := must(d, {kind = shared.K_LOGIN, username = "bob", password = "huntert2"}, "login bob")
	if lg.user.id != bob_id {
		fail("login identität", "falscher user")
	}
	must(d, {kind = shared.K_PING}, "tcp-ping (latenz-echo)")

	// 9) Voice-Call: Signalisierung, Presence und der UDP-SFU-Datenpfad
	vj := must(a, {kind = shared.K_CALL_JOIN, channel_id = edch.id}, "alice startet call")
	if vj.call_id == 0 || len(vj.call_key) != 64 || len(vj.udp_token) != 32 || vj.ssrc == 0 || vj.udp_port == 0 {
		fail("call_join antwort", "felder fehlen:", vj.call_id, vj.ssrc, vj.udp_port)
	}
	if len(vj.call.peers) != 1 || vj.call.peers[0].user_id != alice_id || vj.call.peers[0].ssrc != vj.ssrc {
		fail("call_join peers", "anzahl =", len(vj.call.peers))
	}
	if vj.call.msg_id == 0 || vj.call.started_ms == 0 {
		fail("call_join systemnachricht", "msg_id =", vj.call.msg_id, "started_ms =", vj.call.started_ms)
	}
	evc := expect_event(b, shared.EV_CALL_STATE, "bob bekommt ev_call_state (start)")
	if evc.channel_id != edch.id || len(evc.call.peers) != 1 {
		fail("ev_call_state start", "peers =", len(evc.call.peers))
	}
	if evc.call.msg_id != vj.call.msg_id {
		fail("ev_call_state msg_id", "erwartet", vj.call.msg_id, "bekommen", evc.call.msg_id)
	}
	// Der Call-Start postet eine Systemnachricht in den Channel
	evstart := expect_event(b, shared.EV_MESSAGE, "bob bekommt call-startnachricht")
	if evstart.message.id != vj.call.msg_id || evstart.message.channel_id != edch.id ||
	   evstart.message.author_id != alice_id || evstart.message.call_start_ms != vj.call.started_ms ||
	   evstart.message.call_end_ms != 0 {
		fail("call-startnachricht", "id =", evstart.message.id, "start =", evstart.message.call_start_ms)
	}
	lu2 := must(b, {kind = shared.K_LIST_USERS}, "list_users während call")
	for u in lu2.users {
		if u.id == alice_id && !u.in_call {
			fail("in_call presence", "alice müsste in_call sein")
		}
		if u.id == bob_id && u.in_call {
			fail("in_call presence", "bob dürfte nicht in_call sein")
		}
	}
	step_ok("in_call-flag stimmt für alice und bob")

	vj2 := must(b, {kind = shared.K_CALL_JOIN, channel_id = edch.id}, "bob tritt call bei")
	if len(vj2.call.peers) != 2 || vj2.call_id != vj.call_id || vj2.ssrc == vj.ssrc {
		fail("zweiter join", "peers =", len(vj2.call.peers))
	}
	evc2 := expect_event(a, shared.EV_CALL_STATE, "alice sieht bob im call")
	if len(evc2.call.peers) != 2 {
		fail("ev_call_state join", "peers =", len(evc2.call.peers))
	}
	lcd := must(d, {kind = shared.K_LIST_CHANNELS}, "list_channels mit laufendem call")
	if len(lcd.calls) != 1 || len(lcd.calls[0].peers) != 2 || lcd.calls[0].channel_id != edch.id {
		fail("calls in list_channels", "anzahl =", len(lcd.calls))
	}

	// Beide Teilnehmer bekommen denselben Call-Key
	akey, akok := hex.decode(transmute([]byte)vj.call_key, context.temp_allocator)
	atok, atok_ok := hex.decode(transmute([]byte)vj.udp_token, context.temp_allocator)
	bkey, _ := hex.decode(transmute([]byte)vj2.call_key, context.temp_allocator)
	btok, _ := hex.decode(transmute([]byte)vj2.udp_token, context.temp_allocator)
	if !akok || !atok_ok || !bytes.equal(akey, bkey) {
		fail("call-key", "hex kaputt oder keys verschieden")
	}

	srv_ep, epok := net.parse_endpoint(addr)
	if !epok {
		fail("endpoint parse", addr)
	}
	srv_ep.port = vj.udp_port

	ua := udp_join(akey, vj.call_id, vj.ssrc, atok, srv_ep, "alice: udp hello → welcome")
	ub := udp_join(bkey, vj2.call_id, vj2.ssrc, btok, srv_ep, "bob: udp hello → welcome")

	// Audio alice → Server → bob (Forwarding, unverändert & authentisch)
	fake1 := []byte{0xF0, 0x0D, 0xAB, 0xBA, 1, 2, 3, 4, 5, 6}
	sbuf: [shared.VOICE_MAX_PACKET]byte
	sn := shared.voice_pack(sbuf[:], akey, shared.VP_AUDIO, 0, vj.ssrc, 1, fake1)
	if _, serr := net.send_udp(ua, sbuf[:sn], srv_ep); serr != nil {
		fail("audio send", serr)
	}
	fvp, fpl := udp_expect(ub, bkey, "bob empfängt alices audio-paket")
	if fvp.ptype != shared.VP_AUDIO || fvp.ssrc != vj.ssrc || fvp.seq != 1 || !bytes.equal(fpl, fake1) {
		fail("forwarding inhalt", "ssrc =", fvp.ssrc, "seq =", fvp.seq)
	}

	// Gefälschtes Paket (falscher Key, gleiche ssrc/addr) wird NICHT
	// geforwardet: bob sieht als Nächstes direkt seq 3.
	zero_key: [shared.VOICE_KEY_LEN]byte
	sn = shared.voice_pack(sbuf[:], zero_key[:], shared.VP_AUDIO, 0, vj.ssrc, 2, fake1)
	net.send_udp(ua, sbuf[:sn], srv_ep)
	fake2 := []byte{9, 9, 9, 9}
	sn = shared.voice_pack(sbuf[:], akey, shared.VP_AUDIO, 0, vj.ssrc, 3, fake2)
	net.send_udp(ua, sbuf[:sn], srv_ep)
	fvp2, fpl2 := udp_expect(ub, bkey, "gefälschtes paket wurde verworfen")
	if fvp2.seq != 3 || !bytes.equal(fpl2, fake2) {
		fail("spoofing-schutz", "seq =", fvp2.seq, "(2 hätte verworfen werden müssen)")
	}

	// Rückrichtung bob → alice
	fake3 := []byte{0xCA, 0xFE, 7, 7, 7}
	sn = shared.voice_pack(sbuf[:], bkey, shared.VP_AUDIO, 0, vj2.ssrc, 1, fake3)
	net.send_udp(ub, sbuf[:sn], srv_ep)
	fvp3, fpl3 := udp_expect(ua, akey, "alice empfängt bobs audio-paket")
	if fvp3.ssrc != vj2.ssrc || !bytes.equal(fpl3, fake3) {
		fail("forwarding rückrichtung", "ssrc =", fvp3.ssrc)
	}

	// Keepalive: PING wird als PONG mit Zeitstempel-Echo beantwortet
	ts := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	sn = shared.voice_pack(sbuf[:], akey, shared.VP_PING, 0, vj.ssrc, 4, ts)
	net.send_udp(ua, sbuf[:sn], srv_ep)
	pvp, ppl := udp_expect(ua, akey, "ping → pong")
	if pvp.ptype != shared.VP_PONG || !bytes.equal(ppl, ts) {
		fail("pong echo", "typ =", pvp.ptype)
	}

	// Mute-Status wird an die anderen signalisiert
	must(b, {kind = shared.K_CALL_MUTE, channel_id = edch.id, muted = true}, "bob mutet sich")
	evm := expect_event(a, shared.EV_CALL_STATE, "alice bekommt mute-status")
	bob_muted := false
	for p in evm.call.peers {
		if p.user_id == bob_id && p.muted {
			bob_muted = true
		}
	}
	if !bob_muted {
		fail("mute-event", "bob nicht als gemutet markiert")
	}

	// Rejoin ersetzt die alte Mitgliedschaft (neue ssrc, weiterhin 2 Peers)
	vj3 := must(a, {kind = shared.K_CALL_JOIN, channel_id = edch.id}, "alice rejoin")
	if len(vj3.call.peers) != 2 || vj3.ssrc == vj.ssrc {
		fail("rejoin", "peers =", len(vj3.call.peers), "ssrc gleich?")
	}
	expect_event(b, shared.EV_CALL_STATE, "bob bekommt rejoin-event")

	// Verlassen: erst bob, dann alice → Call endet (peers leer)
	must(b, {kind = shared.K_CALL_LEAVE}, "bob verlässt call")
	evl := expect_event(a, shared.EV_CALL_STATE, "alice sieht bob gehen")
	if len(evl.call.peers) != 1 || evl.call.peers[0].user_id != alice_id {
		fail("leave event", "peers =", len(evl.call.peers))
	}
	// bob bekommt sein eigenes leave-Event ebenfalls (Banner-Update) …
	evself := expect_event(b, shared.EV_CALL_STATE, "bob sieht eigenes leave")
	if len(evself.call.peers) != 1 {
		fail("eigenes leave event", "peers =", len(evself.call.peers))
	}
	must(a, {kind = shared.K_CALL_LEAVE}, "alice verlässt call")
	// … und danach das Call-Ende.
	evend := expect_event(b, shared.EV_CALL_STATE, "bob sieht call-ende")
	if len(evend.call.peers) != 0 {
		fail("call-ende", "peers =", len(evend.call.peers))
	}
	// Die Systemnachricht trägt jetzt die Endzeit (kein Text-Edit!)
	evfin := expect_event(b, shared.EV_MESSAGE_EDITED, "bob bekommt call-endnachricht")
	if evfin.message.id != vj.call.msg_id || evfin.message.call_end_ms < evfin.message.call_start_ms ||
	   evfin.message.call_start_ms != vj.call.started_ms || evfin.message.edit_count != 0 {
		fail("call-endnachricht", "end =", evfin.message.call_end_ms, "count =", evfin.message.edit_count)
	}
	hcall := must(a, {kind = shared.K_HISTORY, channel_id = edch.id}, "history mit call-karte")
	if len(hcall.messages) != 2 {
		fail("call-karte in history", "anzahl =", len(hcall.messages))
	}
	hcm := hcall.messages[1]
	if hcm.id != vj.call.msg_id || hcm.call_start_ms == 0 || hcm.call_end_ms < hcm.call_start_ms || hcm.edit_count != 0 {
		fail("call-karte inhalt", "start =", hcm.call_start_ms, "end =", hcm.call_end_ms)
	}
	// Die Call-Nachricht ist nicht bearbeitbar (pflegt der Server)
	must_err(a, {kind = shared.K_EDIT_START, channel_id = edch.id, message_id = vj.call.msg_id},
		"not_allowed", "call-nachricht nicht bearbeitbar")
	lu3 := must(b, {kind = shared.K_LIST_USERS}, "list_users nach call")
	for u in lu3.users {
		if u.in_call {
			fail("in_call nach ende", u.username, "hängt im call fest")
		}
	}
	lcd2 := must(d, {kind = shared.K_LIST_CHANNELS}, "list_channels nach call")
	if len(lcd2.calls) != 0 {
		fail("calls nach ende", "anzahl =", len(lcd2.calls))
	}
	step_ok("call sauber beendet")

	fmt.println("\nALLE SMOKE-TESTS BESTANDEN ✔")
}
