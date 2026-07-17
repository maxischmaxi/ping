package main

// Desktop-Benachrichtigungen: neue Nachrichten und eingehende Calls, aber
// nur wenn das Fenster unfokussiert oder versteckt ist (wie Slack). Ein
// Klick auf die Benachrichtigung öffnet das Fenster im passenden Channel.

import "core:fmt"
import "core:strings"

import rl "vendor:raylib"

import desk "../desktop"
import shared "../shared"

Notif_Target :: struct {
	conn:       ^Server_Conn,
	channel_id: u64,
}

// Stabiler Schlüssel pro (Server, Channel): Folge-Nachrichten ERSETZEN die
// sichtbare Benachrichtigung desselben Channels, statt sich zu stapeln.
@(private = "file")
notif_tag :: proc(c: ^Server_Conn, channel_id: u64) -> u64 {
	h := u64(uintptr(rawptr(c))) * 0x9E3779B97F4A7C15
	h ~= channel_id * 0xff51afd7ed558ccd
	return h | 1
}

app_notify_message :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, m: shared.Chat_Message) {
	if app.cfg.notify_off || m.author_id == c.me.id {
		return
	}
	if rl.IsWindowFocused() && !app.hidden {
		return
	}
	author := user_label(c, m.author_id)
	is_call := m.call_start_ms > 0
	title, body: string
	if is_call {
		if m.call_end_ms > 0 {
			return // bereits beendete Calls nicht melden
		}
		if cs.ch.is_dm {
			title = fmt.tprintf("%s ruft an", author)
			body = "Eingehender Anruf — zum Beitreten klicken"
		} else {
			title = fmt.tprintf("Voice-Call in #%s", cs.ch.name)
			body = fmt.tprintf("%s hat einen Call gestartet", author)
		}
	} else {
		title = cs.ch.is_dm ? author : fmt.tprintf("%s in #%s", author, cs.ch.name)
		body = notif_preview(m.text)
	}
	if len(app.conns) > 1 {
		title = fmt.tprintf("%s · %s", title, conn_label(c))
	}
	tag := notif_tag(c, m.channel_id)
	app.notif_targets[tag] = {c, m.channel_id}
	desk.notify(tag, title, body, is_call ? .Call : .Message)
}

// Mehrzeiler/Tabs auf eine lesbare Vorschauzeile eindampfen.
@(private = "file")
notif_preview :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	last_space := true
	for r in text {
		r := r
		if r == '\n' || r == '\t' || r == '\r' {
			r = ' '
		}
		if r == ' ' && last_space {
			continue
		}
		last_space = r == ' '
		strings.write_rune(&b, r)
		n += 1
		if n >= 140 {
			strings.write_string(&b, "…")
			break
		}
	}
	return strings.to_string(b)
}

// Klick auf eine Benachrichtigung → Server + Channel aktivieren.
app_notif_clicked :: proc(app: ^App, tag: u64) {
	t, has := app.notif_targets[tag]
	if !has {
		return
	}
	for c, i in app.conns {
		if c != t.conn {
			continue
		}
		app.active = i
		if conn_find_channel(c, t.channel_id) != nil {
			app_activate_channel(app, c, t.channel_id)
		}
		return
	}
}

// Aus den Einstellungen: Probe-Benachrichtigung.
app_notify_test :: proc(app: ^App) -> bool {
	return desk.notify(0xF1F0, "Flurfunk", "So sehen Benachrichtigungen aus 👋", .Message)
}
