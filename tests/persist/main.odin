package persist

// Persistenz-Test: läuft gegen einen NEU GESTARTETEN Server mit dem
// Datenbestand aus dem Smoke-Test (alice/general/DM müssen existieren).
// Nutzung: persist <host:port>

import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:os"
import "core:crypto/ecdh"

import shared "../../src/shared"

fail :: proc(step: string, args: ..any) {
	fmt.eprintf("FEHLGESCHLAGEN: %s ", step)
	fmt.eprintln(..args)
	os.exit(1)
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("Nutzung: persist <host:port>")
		os.exit(2)
	}

	sock, derr := net.dial_tcp(os.args[1])
	if derr != nil {
		fail("dial", derr)
	}
	priv: ecdh.Private_Key
	if !shared.generate_static_key(&priv) {
		fail("keygen")
	}
	conn: shared.Secure_Conn
	if !shared.client_handshake(&conn, sock, &priv) {
		fail("handshake")
	}

	seq: u64 = 1
	request :: proc(conn: ^shared.Secure_Conn, seq: ^u64, w: shared.Wire) -> shared.Wire {
		w := w
		w.seq = seq^
		seq^ += 1
		if !shared.send_wire(conn, w) {
			fail("send", w.kind)
		}
		for {
			r, ok := shared.recv_wire(conn)
			if !ok {
				fail("recv", w.kind)
			}
			if r.seq == w.seq && r.kind == w.kind {
				return r
			}
			// Events ignorieren
		}
	}

	lg := request(&conn, &seq, {kind = shared.K_LOGIN, username = "alice", password = "geheim123"})
	if !lg.ok || lg.server_name != "ACME Corp" || !lg.user.is_admin || lg.setup_needed {
		fail("login nach neustart", "ok =", lg.ok, "name =", lg.server_name)
	}
	fmt.println("ok: login nach neustart, servername erhalten")

	// OAuth: Konto (ohne Passwort) und Provider-Konfiguration überleben den
	// Neustart (users.json/oauth.json aus dem Smoke-Test)
	pw := request(&conn, &seq, {kind = shared.K_LOGIN, username = "mia.muster", password = "egal123"})
	if pw.ok || pw.err != "invalid_credentials" {
		fail("oauth-konto nach neustart", "err =", pw.err)
	}
	as := request(&conn, &seq, {kind = shared.K_ADMIN_STATE})
	oauth_ok := false
	for p in as.admin.oauth {
		if p.id == "oidc" && !p.enabled && p.client_id == "test-client" && p.label == "Test-SSO" {
			oauth_ok = true
		}
	}
	if !as.ok || !oauth_ok {
		fail("oauth-konfiguration nach neustart")
	}
	fmt.println("ok: oauth-konto und provider-konfiguration nach neustart")

	lc := request(&conn, &seq, {kind = shared.K_LIST_CHANNELS})
	if len(lc.channels) != 5 { // general + DM + büro-küche + bulk + edits (aus dem Smoke-Test)
		fail("channels nach neustart", "erwartet 5, bekommen", len(lc.channels))
	}
	if len(lc.calls) != 0 { // Calls sind flüchtig — ein Neustart beendet sie
		fail("calls nach neustart", "erwartet 0, bekommen", len(lc.calls))
	}
	fmt.println("ok: channels nach neustart vorhanden, keine geister-calls")

	h := request(&conn, &seq, {kind = shared.K_HISTORY, channel_id = 1})
	if len(h.messages) != 2 {
		fail("history nach neustart", "erwartet 2, bekommen", len(h.messages))
	}
	if h.messages[0].text != "hallo *welt* von _alice_" || h.messages[1].text != "hi zurück 🎉" {
		fail("history texte", "entschlüsselte texte falsch:", h.messages[0].text, "/", h.messages[1].text)
	}
	fmt.println("ok: history nach neustart korrekt entschlüsselt (inkl. emoji)")

	// Edits überleben den Neustart: Replay aus dem verschlüsselten Log
	edch_id: u64
	for ch in lc.channels {
		if ch.name == "edits" {
			edch_id = ch.id
		}
	}
	if edch_id == 0 {
		fail("edits-channel fehlt")
	}
	// edits enthält die Textnachricht + die Call-Karte aus dem Smoke-Test
	he := request(&conn, &seq, {kind = shared.K_HISTORY, channel_id = edch_id})
	if len(he.messages) != 2 || he.messages[0].text != "version vier" ||
	   he.messages[0].edit_count != 3 || he.messages[0].edited_ms == 0 {
		fail("edit nach neustart", "anzahl =", len(he.messages), "count =", he.messages[0].edit_count)
	}
	// Die Call-Systemnachricht überlebt den Neustart inkl. Start/Ende
	cm := he.messages[1]
	if cm.call_start_ms == 0 || cm.call_end_ms < cm.call_start_ms || cm.edit_count != 0 {
		fail("call-karte nach neustart", "start =", cm.call_start_ms, "end =", cm.call_end_ms)
	}
	fmt.println("ok: call-systemnachricht nach neustart korrekt")
	mh := request(&conn, &seq, {kind = shared.K_MESSAGE_HISTORY, channel_id = edch_id, message_id = he.messages[0].id})
	if len(mh.messages) != 4 || mh.messages[0].text != "version eins" || mh.messages[3].text != "version vier" {
		fail("versionen nach neustart", "anzahl =", len(mh.messages))
	}
	// Neue Edits sind nach dem Neustart gesperrt (Freigaben leben nur im RAM,
	// und die Frist ist ohnehin um)
	er := request(&conn, &seq, {kind = shared.K_EDIT_MESSAGE, channel_id = edch_id, message_id = he.messages[0].id, text = "hack"})
	if er.err != "edit_window" {
		fail("edit-freigabe nach neustart", "err =", er.err)
	}
	fmt.println("ok: edits und versionen nach neustart korrekt")

	// Tabs/Spaces in Code-Blöcken überleben das verschlüsselte Log byte-genau
	// (Nachricht stammt aus dem Smoke-Test, Channel "büro-küche")
	tabtext := "```go\nfunc main() {\n\tif x {\n\t\tfmt.Println(\"tabs\")\n\t}\n    spaces()\n}\n```"
	uml_id: u64
	for ch in lc.channels {
		if ch.name == "büro-küche" {
			uml_id = ch.id
		}
	}
	if uml_id == 0 {
		fail("büro-küche fehlt")
	}
	ht := request(&conn, &seq, {kind = shared.K_HISTORY, channel_id = uml_id})
	if len(ht.messages) != 1 || ht.messages[0].text != tabtext {
		fail("tabs nach neustart", "text nicht byte-genau erhalten")
	}
	fmt.println("ok: tabs in code-blöcken nach neustart byte-genau")

	// Profilbild überlebt den Neustart: Version aus users.json, Datei
	// entschlüsselbar, Inhalt byte-genau (Smoke-Test setzte zuletzt v3).
	if lg.user.avatar != 3 {
		fail("avatar-version nach neustart", "avatar =", lg.user.avatar)
	}
	av := request(&conn, &seq, {kind = shared.K_AVATAR_GET, user_id = lg.user.id})
	if !av.ok {
		fail("avatar_get nach neustart", av.err)
	}
	{
		// identisch zum fake_png(256, 256, 64) aus dem Smoke-Test
		buf := make([dynamic]byte)
		sig := [8]byte{137, 'P', 'N', 'G', 13, 10, 26, 10}
		append(&buf, ..sig[:])
		be32 :: proc(buf: ^[dynamic]byte, v: int) {
			append(buf, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
		}
		be32(&buf, 13)
		append(&buf, 'I', 'H', 'D', 'R')
		be32(&buf, 256)
		be32(&buf, 256)
		append(&buf, 8, 6, 0, 0, 0)
		append(&buf, 0xAA, 0xBB, 0xCC, 0xDD)
		for i in 0 ..< 64 {
			append(&buf, byte(i))
		}
		if av.data != base64.encode(buf[:], base64.ENC_TABLE) {
			fail("avatar-inhalt nach neustart", "bytes stimmen nicht")
		}
	}
	fmt.println("ok: profilbild nach neustart erhalten und entschlüsselbar")

	s := request(&conn, &seq, {kind = shared.K_SEND, channel_id = 1, text = "nach dem neustart"})
	if !s.ok {
		fail("send nach neustart", s.err)
	}
	h2 := request(&conn, &seq, {kind = shared.K_HISTORY, channel_id = 1})
	if len(h2.messages) != 3 || h2.messages[2].text != "nach dem neustart" {
		fail("history nach send", "anzahl =", len(h2.messages))
	}
	if h2.messages[2].id <= h2.messages[1].id {
		fail("message-id monotonie", "id nicht größer als vorherige")
	}
	fmt.println("ok: message-ids nach neustart monoton, senden funktioniert")

	fmt.println("\nPERSISTENZ-TEST BESTANDEN ✔")
}
