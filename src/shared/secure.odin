package shared

import "core:crypto/ecdh"
import "core:crypto/noise"
import "core:encoding/json"
import "core:net"
import "core:sync"

// Transportverschlüsselung: Noise XX (X25519 + ChaCha20-Poly1305 + BLAKE2s).
// Beide Seiten haben statische X25519-Keys; der Client pinnt den Server-Key
// beim ersten Verbinden (TOFU, wie SSH).

NOISE_PROTOCOL :: "Noise_XX_25519_ChaChaPoly_BLAKE2s"
NOISE_PROLOGUE :: "flurfunk/1"

STATIC_KEY_SIZE :: 32

// Chunking: Noise-Pakete sind auf 64 KiB begrenzt, App-Nachrichten können
// größer sein. Jeder Chunk: 1 Flag-Byte (1 = letzter) + Payload, versiegelt.
CHUNK_MAX :: 32 * 1024

// Obergrenze einer zusammengesetzten Nachricht — schützt beide Seiten vor
// endlosen Chunk-Strömen (größte legitime Nachricht: Avatar-Upload).
MESSAGE_MAX :: 4 * 1024 * 1024

Secure_Conn :: struct {
	sock:        net.TCP_Socket,
	cs:          noise.Cipher_States,
	wmu:         sync.Mutex, // schützt Sende-Cipher-State + Socket-Writes
	peer_static: [STATIC_KEY_SIZE]byte,
}

generate_static_key :: proc(priv: ^ecdh.Private_Key) -> bool {
	return ecdh.private_key_generate(priv, .X25519)
}

static_key_bytes :: proc(priv: ^ecdh.Private_Key) -> [STATIC_KEY_SIZE]byte {
	out: [STATIC_KEY_SIZE]byte
	ecdh.private_key_bytes(priv, out[:])
	return out
}

static_key_from_bytes :: proc(priv: ^ecdh.Private_Key, b: []byte) -> bool {
	return ecdh.private_key_set_bytes(priv, .X25519, b)
}

@(private)
finish_handshake :: proc(conn: ^Secure_Conn, hs: ^noise.Handshake_State) -> bool {
	peer, pstatus := noise.handshake_peer_identity(hs)
	if pstatus != .Ok {
		return false
	}
	ecdh.public_key_bytes(peer, conn.peer_static[:])
	if noise.handshake_split(hs, &conn.cs) != .Ok {
		return false
	}
	noise.handshake_reset(hs)
	return true
}

// Initiator-Seite (Client). conn.peer_static enthält danach den
// Server-Static-Key für TOFU-Pinning durch den Aufrufer.
client_handshake :: proc(conn: ^Secure_Conn, sock: net.TCP_Socket, static_priv: ^ecdh.Private_Key) -> bool {
	conn.sock = sock

	hs: noise.Handshake_State
	if noise.handshake_init(&hs, true, transmute([]byte)string(NOISE_PROLOGUE), static_priv, nil, NOISE_PROTOCOL) != .Ok {
		return false
	}
	defer noise.handshake_reset(&hs)

	msg1, _, st1 := noise.handshake_initiator_step(&hs, nil, allocator = context.temp_allocator)
	if st1 != .Handshake_Pending {
		return false
	}
	if !write_frame(sock, msg1) {
		return false
	}

	msg2, ok2 := read_frame(sock, context.temp_allocator)
	if !ok2 || msg2 == nil {
		return false
	}
	msg3, _, st3 := noise.handshake_initiator_step(&hs, msg2, allocator = context.temp_allocator)
	if st3 != .Handshake_Complete {
		return false
	}
	if !write_frame(sock, msg3) {
		return false
	}

	return finish_handshake(conn, &hs)
}

// Responder-Seite (Server).
server_handshake :: proc(conn: ^Secure_Conn, sock: net.TCP_Socket, static_priv: ^ecdh.Private_Key) -> bool {
	conn.sock = sock

	hs: noise.Handshake_State
	if noise.handshake_init(&hs, false, transmute([]byte)string(NOISE_PROLOGUE), static_priv, nil, NOISE_PROTOCOL) != .Ok {
		return false
	}
	defer noise.handshake_reset(&hs)

	msg1, ok1 := read_frame(sock, context.temp_allocator)
	if !ok1 || msg1 == nil {
		return false
	}
	msg2, _, st2 := noise.handshake_responder_step(&hs, msg1, allocator = context.temp_allocator)
	if st2 != .Handshake_Pending || msg2 == nil {
		return false
	}
	if !write_frame(sock, msg2) {
		return false
	}

	msg3, ok3 := read_frame(sock, context.temp_allocator)
	if !ok3 || msg3 == nil {
		return false
	}
	out, _, st3 := noise.handshake_responder_step(&hs, msg3, allocator = context.temp_allocator)
	if st3 != .Handshake_Complete || out != nil {
		return false
	}

	return finish_handshake(conn, &hs)
}

// Verschlüsselte Nachricht beliebiger Größe senden. Threadsicher.
secure_send :: proc(conn: ^Secure_Conn, data: []byte) -> bool {
	sync.lock(&conn.wmu)
	defer sync.unlock(&conn.wmu)

	pt: [1 + CHUNK_MAX]byte
	ct: [1 + CHUNK_MAX + noise.TAG_SIZE]byte

	remaining := data
	for {
		n := min(len(remaining), CHUNK_MAX)
		last := n == len(remaining)
		pt[0] = 1 if last else 0
		copy(pt[1:1+n], remaining[:n])

		sealed, st := noise.seal_message(&conn.cs, nil, pt[:1+n], ct[:1+n+noise.TAG_SIZE])
		if st != .Ok {
			return false
		}
		if !write_frame(conn.sock, sealed) {
			return false
		}

		remaining = remaining[n:]
		if last {
			break
		}
	}
	return true
}

// Verschlüsselte Nachricht empfangen. Darf nur von einem einzigen
// Reader-Thread pro Verbindung aufgerufen werden.
secure_recv :: proc(conn: ^Secure_Conn, allocator := context.allocator) -> ([]byte, bool) {
	out := make([dynamic]byte, allocator)
	pt: [1 + CHUNK_MAX]byte

	for {
		frame, ok := read_frame(conn.sock, context.temp_allocator)
		if !ok || frame == nil {
			delete(out)
			return nil, false
		}
		if len(frame) < noise.TAG_SIZE + 1 || len(frame) > 1 + CHUNK_MAX + noise.TAG_SIZE {
			delete(out)
			return nil, false
		}
		plain, st := noise.open_message(&conn.cs, nil, frame, pt[:len(frame)-noise.TAG_SIZE])
		if st != .Ok {
			delete(out)
			return nil, false
		}
		if len(out) + len(plain) - 1 > MESSAGE_MAX {
			delete(out)
			return nil, false
		}
		append(&out, ..plain[1:])
		if plain[0] == 1 {
			break
		}
	}
	return out[:], true
}

// Wire-Envelope als JSON senden/empfangen.
send_wire :: proc(conn: ^Secure_Conn, w: Wire) -> bool {
	data, err := json.marshal(w, {}, context.temp_allocator)
	if err != nil {
		return false
	}
	return secure_send(conn, data)
}

recv_wire :: proc(conn: ^Secure_Conn, allocator := context.allocator) -> (Wire, bool) {
	data, ok := secure_recv(conn, context.temp_allocator)
	if !ok {
		return {}, false
	}
	w: Wire
	if json.unmarshal(data, &w, json.DEFAULT_SPECIFICATION, allocator) != nil {
		return {}, false
	}
	return w, true
}
