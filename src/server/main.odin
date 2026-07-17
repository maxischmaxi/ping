package main

// flurfunk-server: Slack-artiger Chat-Server.
// Transport: Noise XX über TCP (Shared-Package), Nachrichten at rest
// XChaCha20-Poly1305-verschlüsselt pro Channel-Key.

import "core:crypto"
import "core:crypto/ecdh"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"

import shared "../shared"

DEFAULT_PORT :: 7788

// Statischer Noise-Key des Servers (X25519), aus <data>/noise.key.
g_noise_priv: ecdh.Private_Key

usage_exit :: proc() -> ! {
	fmt.printfln("Benutzung: flurfunk-server [-port <n>] [-data <dir>] [-key <pfad>] [-version]")
	os.exit(2)
}

// ---------- Schlüssel-Dateien (32 Bytes roh, 0600) ----------

write_key_file :: proc(path: string, data: []byte) -> bool {
	return os.write_entire_file(path, data, FILE_PERM) == nil
}

load_or_create_master_key :: proc(path: string) -> bool {
	if os.exists(path) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil || len(data) != KEY_LEN {
			return false
		}
		copy(g.master_key[:], data)
		return true
	}
	crypto.rand_bytes(g.master_key[:])
	fmt.printfln("[start] neuer Master-Key: %s", path)
	return write_key_file(path, g.master_key[:])
}

load_or_create_noise_key :: proc(path: string) -> bool {
	if os.exists(path) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil || len(data) != shared.STATIC_KEY_SIZE {
			return false
		}
		return shared.static_key_from_bytes(&g_noise_priv, data)
	}
	if !shared.generate_static_key(&g_noise_priv) {
		return false
	}
	raw := shared.static_key_bytes(&g_noise_priv)
	fmt.printfln("[start] neuer Noise-Key: %s", path)
	return write_key_file(path, raw[:])
}

// ---------- Verbindungs-Thread ----------

// Bearbeitet eine Client-Verbindung; läuft in einem eigenen Thread.
handle_conn :: proc(c: ^Client_Conn) {
	defer {
		net.close(c.sock)
		delete(c.remote)
		free(c)
		free_all(context.temp_allocator)
	}

	if !shared.server_handshake(&c.sc, c.sock, &g_noise_priv) {
		fmt.printfln("[conn] %s: Noise-Handshake fehlgeschlagen", c.remote)
		return
	}
	free_all(context.temp_allocator)

	sync.lock(&g.mu)
	append(&g.conns, c)
	sync.unlock(&g.mu)
	fmt.printfln("[conn] %s: verbunden", c.remote)

	for {
		w, ok := shared.recv_wire(&c.sc, context.temp_allocator)
		if !ok {
			break
		}
		handle_wire(c, w)
		free_all(context.temp_allocator)
	}

	disconnect(c)
	fmt.printfln("[conn] %s: getrennt", c.remote)
}

// Verbindung austragen; ging der User dadurch offline → Presence-Event.
disconnect :: proc(c: ^Client_Conn) {
	sync.lock(&g.mu)
	defer sync.unlock(&g.mu)

	for conn, idx in g.conns {
		if conn == c {
			unordered_remove(&g.conns, idx)
			break
		}
	}
	if c.authed {
		// Diese Verbindung hielt womöglich einen Call.
		call_leave_everywhere(c.user_id, c, 0)
	}
	if c.authed && !user_online(c.user_id) {
		if u := find_user_by_id(c.user_id); u != nil {
			ev := shared.Wire{kind = shared.EV_USER, user = wire_user(u)} // online=false
			broadcast_authed(ev, nil)
		}
	}
}

// ---------- Main ----------

main :: proc() {
	port := DEFAULT_PORT
	data_dir := "./flurfunk-data"
	key_path := ""

	// Einfaches manuelles Parsen von os.args.
	args := os.args
	for i := 1; i < len(args); i += 1 {
		if args[i] == "-version" || args[i] == "--version" {
			fmt.printfln("flurfunk-server %s", shared.VERSION)
			os.exit(0)
		}
		if i + 1 >= len(args) {
			usage_exit() // alle Flags brauchen einen Wert
		}
		switch args[i] {
		case "-port":
			i += 1
			v, ok := strconv.parse_int(args[i], 10)
			if !ok || v < 1 || v > 65535 {
				usage_exit()
			}
			port = v
		case "-data":
			i += 1
			data_dir = args[i]
		case "-key":
			i += 1
			key_path = args[i]
		case:
			usage_exit()
		}
	}
	if key_path == "" {
		key_path = fmt.aprintf("%s/master.key", data_dir)
	}
	g.data_dir = data_dir

	// Datenverzeichnisse anlegen.
	if os.make_directory_all(data_dir) != nil && !os.exists(data_dir) {
		fmt.printfln("[error] Datenverzeichnis %q nicht anlegbar", data_dir)
		os.exit(1)
	}
	msg_dir := fmt.tprintf("%s/messages", data_dir)
	if os.make_directory_all(msg_dir) != nil && !os.exists(msg_dir) {
		fmt.printfln("[error] Verzeichnis %q nicht anlegbar", msg_dir)
		os.exit(1)
	}

	// Schlüssel laden bzw. beim ersten Start erzeugen.
	if !load_or_create_master_key(key_path) {
		fmt.printfln("[error] Master-Key %q nicht ladbar/erzeugbar", key_path)
		os.exit(1)
	}
	noise_path := fmt.tprintf("%s/noise.key", data_dir)
	if !load_or_create_noise_key(noise_path) {
		fmt.printfln("[error] Noise-Key %q nicht ladbar/erzeugbar", noise_path)
		os.exit(1)
	}

	if !load_state() {
		os.exit(1)
	}

	// Fingerprint des öffentlichen Noise-Keys (für TOFU-Pinning der Clients).
	pub: [shared.STATIC_KEY_SIZE]byte
	ecdh.private_key_public_bytes(&g_noise_priv, pub[:])
	fingerprint := string(hex.encode(pub[:], context.temp_allocator))

	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Any, port = port})
	if lerr != nil {
		fmt.printfln("[error] listen auf Port %d fehlgeschlagen: %v", port, lerr)
		os.exit(1)
	}

	// Voice: UDP-SFU auf demselben Port (eigener Thread).
	if !call_udp_start(port) {
		os.exit(1)
	}

	fmt.printfln("[start] flurfunk-server %s lauscht auf Port %d", shared.VERSION, port)
	fmt.printfln("[start] Datenverzeichnis: %s", data_dir)
	fmt.printfln("[start] Noise-Fingerprint: %s", fingerprint)
	free_all(context.temp_allocator)

	// Accept-Loop: ein Thread pro Verbindung, räumt sich selbst auf.
	for {
		client, source, aerr := net.accept_tcp(listener)
		if aerr != nil {
			fmt.printfln("[error] accept fehlgeschlagen: %v", aerr)
			continue
		}
		c := new(Client_Conn)
		c.sock = client
		c.remote = net.endpoint_to_string(source, context.allocator)
		thread.create_and_start_with_poly_data(c, handle_conn, nil, .Normal, true)
	}
}
