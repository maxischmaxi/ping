package main

// Voice-Call-Logik des Clients. App-weit gibt es höchstens EINEN aktiven
// Call (wie bei Slack-Huddles) — er lebt auf App-Ebene, damit er Channel-
// und Server-Wechsel übersteht. Die Signalisierung läuft über die
// Server_Conn, das Audio über Voice_Link (UDP) + audio.Engine.

import "core:encoding/hex"
import "core:fmt"
import "core:net"

import rl "vendor:raylib"

import audio "../audio"
import shared "../shared"

Client_Call :: struct {
	active:     bool,
	joining:    bool,
	conn:       ^Server_Conn,
	channel_id: u64,
	muted:      bool,
	engine:     audio.Engine,
	link:       Voice_Link,
	started_ms: i64, // mono_ms beim Beitritt (Dauer-Anzeige)

	// Popout-Panel (ausgegliederte Call-Controls)
	popout:      bool,
	popout_pos:  rl.Vector2,
	popout_drag: bool,
	drag_off:    rl.Vector2,
}

// Engine-Optionen aus der Config (Geräte + DSP-Schalter).
audio_opts :: proc(cfg: ^Config) -> audio.Engine_Options {
	return {
		mic_name   = cfg.audio_mic,
		out_name   = cfg.audio_out,
		no_denoise = cfg.denoise_off,
		no_aec     = cfg.aec_off,
		no_gate    = cfg.gate_off,
	}
}

// Beitreten (oder Call starten — der Server startet implizit).
call_join :: proc(app: ^App, c: ^Server_Conn, channel_id: u64) {
	if app.call.joining {
		return
	}
	if app.call.active && app.call.conn == c && app.call.channel_id == channel_id {
		return // schon drin
	}
	if app.call.active {
		call_hangup(app) // Wechsel: alten Call sauber verlassen
	}
	// Laufende Audio-Tests geben die Geräte frei, bevor der Call sie öffnet.
	settings_mic_test_stop(app)
	audio.tone_stop(&app.spk_tone)
	app.call.joining = true
	conn_request(c, {kind = shared.K_CALL_JOIN, channel_id = channel_id}, {channel_id = channel_id})
}

// Antwort auf call_join: Audio-Engine + UDP-Link hochfahren.
call_begin :: proc(app: ^App, c: ^Server_Conn, w: shared.Wire) {
	key, kok := hex.decode(transmute([]byte)w.call_key, context.temp_allocator)
	token, tok := hex.decode(transmute([]byte)w.udp_token, context.temp_allocator)
	if !kok || !tok || len(key) != shared.VOICE_KEY_LEN || len(token) != shared.VOICE_TOKEN_LEN {
		toast(app, .Error, "Call-Schlüssel unlesbar")
		return
	}
	ep, rerr := net.resolve_ip4(c.addr)
	if rerr != nil {
		toast(app, .Error, "Server-Adresse nicht auflösbar")
		return
	}
	ep.port = w.udp_port

	if !audio.engine_start(&app.call.engine, voice_on_packet, &app.call.link, audio_opts(&app.cfg)) {
		toast(app, .Error, "Kein Audiogerät verfügbar")
		conn_request(c, {kind = shared.K_CALL_LEAVE})
		return
	}
	if !voice_link_start(&app.call.link, &app.call.engine, ep, key, token, w.call_id, w.ssrc) {
		audio.engine_stop(&app.call.engine)
		toast(app, .Error, "UDP-Socket fehlgeschlagen")
		conn_request(c, {kind = shared.K_CALL_LEAVE})
		return
	}

	app.call.active = true
	app.call.conn = c
	app.call.channel_id = w.channel_id
	app.call.muted = false
	app.call.started_ms = mono_ms()
	app.call.popout = false
	conn_set_call_state(c, w.call)
	audio.engine_blip(&app.call.engine, true)
}

// Auflegen: Server benachrichtigen, dann lokal abbauen.
call_hangup :: proc(app: ^App) {
	if !app.call.active {
		return
	}
	c := app.call.conn
	if conn_phase(c) == .Ready {
		conn_request(c, {kind = shared.K_CALL_LEAVE})
	}
	call_teardown(app)
}

// Nur lokal abbauen (Verbindung weg / Server hat uns entfernt).
call_teardown :: proc(app: ^App) {
	if !app.call.active {
		return
	}
	settings_call_ended(app)            // laufende Audio-Tests hingen an dieser Engine
	audio.engine_stop(&app.call.engine) // stoppt on_packet-Aufrufe …
	voice_link_stop(&app.call.link)     // … dann darf der Socket zu
	app.call.active = false
	app.call.joining = false
	app.call.conn = nil
	app.call.channel_id = 0
	app.call.muted = false
	app.call.popout = false
	app.call.popout_drag = false
}

call_set_mute :: proc(app: ^App, muted: bool) {
	if !app.call.active {
		return
	}
	app.call.muted = muted
	app.call.engine.muted = muted
	if conn_phase(app.call.conn) == .Ready {
		conn_request(app.call.conn, {kind = shared.K_CALL_MUTE, muted = muted})
	}
}

// Pro Frame: Keepalive/Retries treiben; Verbindungsverlust erkennen.
call_tick :: proc(app: ^App) {
	if !app.call.active {
		return
	}
	if conn_phase(app.call.conn) != .Ready {
		call_teardown(app)
		toast(app, .Error, "Call getrennt (Verbindung zum Server verloren)")
		return
	}
	voice_tick(&app.call.link)
}

// Call-Stand eines Channels übernehmen (Event/Reply/list_channels).
conn_set_call_state :: proc(c: ^Server_Conn, info: shared.Call_Info) {
	if len(info.peers) == 0 {
		delete_key(&c.calls, info.channel_id)
		return
	}
	c.calls[info.channel_id] = {
		peers      = info.peers,
		msg_id     = info.msg_id,
		started_ms = info.started_ms,
	}
}

// EV_CALL_STATE anwenden: Banner-Daten, Blips, Stream-Sync, Rauswurf-Erkennung.
app_apply_call_state :: proc(app: ^App, c: ^Server_Conn, channel_id: u64, info: shared.Call_Info) {
	info := info
	if info.channel_id == 0 {
		info.channel_id = channel_id
	}
	mine := app.call.active && app.call.conn == c && app.call.channel_id == channel_id

	if mine {
		// Beitritts-/Abschieds-Blips (Vergleich alte ↔ neue ssrc-Menge)
		old := c.calls[channel_id].peers
		for p in info.peers {
			if p.ssrc == app.call.link.ssrc {
				continue
			}
			found := false
			for o in old {
				if o.ssrc == p.ssrc {
					found = true
				}
			}
			if !found {
				audio.engine_blip(&app.call.engine, true)
			}
		}
		for o in old {
			if o.ssrc == app.call.link.ssrc {
				continue
			}
			found := false
			for p in info.peers {
				if p.ssrc == o.ssrc {
					found = true
				}
			}
			if !found {
				audio.engine_blip(&app.call.engine, false)
			}
		}
	}

	conn_set_call_state(c, info)

	if mine {
		// Bin ich (mit genau meiner ssrc) noch drin? Sonst hat der Server
		// die Mitgliedschaft ersetzt/beendet → lokal abbauen.
		me_in := false
		keep := make([dynamic]u32, context.temp_allocator)
		for p in info.peers {
			if p.ssrc == app.call.link.ssrc {
				me_in = true
			} else {
				append(&keep, p.ssrc)
			}
		}
		if !me_in {
			call_teardown(app)
			toast(app, .Info, "Du hast den Call verlassen")
			return
		}
		audio.engine_sync_streams(&app.call.engine, keep[:])
	}
}

// Läuft in diesem Channel gerade ein Call? (fürs Banner/Header-Icon)
channel_call_peers :: proc(c: ^Server_Conn, channel_id: u64) -> []shared.Call_Peer {
	return c.calls[channel_id].peers
}

// Ist der User gerade Teilnehmer im aktiven eigenen Call dieses Channels?
call_is_here :: proc(app: ^App, c: ^Server_Conn, channel_id: u64) -> bool {
	return app.call.active && app.call.conn == c && app.call.channel_id == channel_id
}

// Sprech-Pegel eines Peers, normalisiert auf 0..1 fürs UI.
call_peer_level :: proc(app: ^App, p: shared.Call_Peer) -> f32 {
	if !app.call.active {
		return 0
	}
	lvl: f32
	if p.ssrc == app.call.link.ssrc {
		lvl = app.call.engine.mic_level
		if app.call.muted {
			return 0
		}
	} else {
		lvl = audio.engine_stream_level(&app.call.engine, p.ssrc)
	}
	return clamp(lvl * 7, 0, 1)
}

// Sekunden → "MM:SS" bzw. "H:MM:SS".
format_duration :: proc(s: i64) -> string {
	s := max(s, 0)
	if s >= 3600 {
		return fmt.tprintf("%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
	}
	return fmt.tprintf("%02d:%02d", s / 60, s % 60)
}

// Dauer seit Beitritt (eigener Call).
call_duration_label :: proc(app: ^App) -> string {
	return format_duration((mono_ms() - app.call.started_ms) / 1000)
}
