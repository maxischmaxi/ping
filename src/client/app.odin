package main

// App-Zustand + Verarbeitung eingehender Wire-Nachrichten (Main-Thread).

import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

import rl "vendor:raylib"
import audio "../audio"
import shared "../shared"

HISTORY_PAGE :: 50

Modal_Kind :: enum {
	None,
	Add_Server,
	Create_Channel,
	Members,
	Quick_Switch,
	Confirm_Delete, // Kanal löschen bestätigen (app.confirm_channel)
	Msg_History,    // Bearbeitungsverlauf einer Nachricht (Sheet von rechts)
	Settings,       // App-Einstellungen (Audio-Geräte + Selbsttest)
}

// Kontextmenü (Rechtsklick auf einen Kanal in der Sidebar).
Ctx_Menu :: struct {
	open:       bool,
	channel_id: u64,
	pos:        rl.Vector2, // logische Koordinaten (Öffnungsposition)
}

App :: struct {
	cfg:        Config,
	device_key: DeviceKey,
	fonts:      Fonts,
	ui:         UI_Ctx,
	anim:       Anim_Store,
	dt:         f32,
	caret_t:    f64,
	toasts:     [dynamic]Toast,

	conns:  [dynamic]^Server_Conn,
	active: int, // Index des aktiven Servers

	// Modal-Zustand
	modal:        Modal_Kind,
	modal_input:  Text_Input,
	modal_error:  string,
	modal_scroll: Scroll,

	// Kontextmenü + Lösch-Bestätigung
	ctx:             Ctx_Menu,
	confirm_channel: u64,

	// „Mehr"-Menü einer Nachricht (msgmenu.odin)
	msg_menu: Msg_Menu,

	// Bearbeitungsverlauf (Sheet, sheet.odin); Daten kommen per
	// message_history-Antwort
	history_msg_id:   u64,
	history_loading:  bool,
	history_versions: [dynamic]shared.Chat_Message,
	history_scroll:   Scroll,

	// Theme (hell/dunkel)
	theme_mode: Theme_Mode,
	theme_menu: bool, // Dropdown in der Titelleiste offen
	theme_k:    f32,  // 0 = hell, 1 = dunkel; animiert → weiche Überblendung

	// Zuletzt kopierter Code-Block: zeigt dort kurz ein Häkchen statt des
	// Copy-Icons. Es kann immer nur einer der jüngste sein.
	copied_id: u64,
	copied_at: f64,

	// Quick Switcher
	switcher_sel: int,

	// Aktiver Voice-Call (app-weit höchstens einer, call.odin)
	call: Client_Call,

	// Höhe der Call-Leiste (Top-Bar) in diesem Frame — die gesamte UI
	// rutscht per Camera-Offset um diese Höhe nach unten (main.odin).
	bar_h: f32,

	// Settings-Dialog (settingsui.odin): Gerätelisten + Audio-Selbsttest
	set_devices_out: []audio.Device,
	set_devices_mic: []audio.Device,
	set_dd:          int, // offenes Dropdown: 0 = keins, 1 = Mikro, 2 = Lautsprecher
	mic_test:        bool,
	mic_test_call:   bool, // Test läuft als Loopback in der CALL-Engine
	test_engine:     audio.Engine,
	spk_tone:        audio.Tone,

	// Während eines Tests im Call sind wir automatisch stummgeschaltet —
	// der vorherige Zustand kommt nach dem Test zurück.
	test_muting:       bool,
	test_restore_mute: bool,
	spk_test_until:    i64, // mono_ms-Ende des Ausgabetests im Call (0 = keiner)

	welcome_input: Text_Input,
	welcome_error: string,

	tz: ^datetime.TZ_Region, // lokale Zeitzone (nil → UTC)
}

app_init :: proc(app: ^App) {
	app.cfg = config_load()
	config_device_key(&app.cfg, &app.device_key)
	if app.cfg.ui_scale > 0 {
		g_scale = clamp(app.cfg.ui_scale, SCALE_MIN, SCALE_MAX)
	}
	app.fonts = fonts_load(g_scale)
	app.tz, _ = timezone.region_load("local")

	// Theme: gemerkte Wahl, sonst Systemeinstellung. Beim Start ohne
	// Animation — die Überblendung ist für den Wechsel im Betrieb da.
	app.theme_mode = theme_mode_from_string(app.cfg.theme)
	sys_theme_start(app.theme_mode == .System)
	app.theme_k = theme_target(app)
	theme_apply(app.theme_k)

	// Alle konfigurierten Server verbinden
	for s, i in app.cfg.servers {
		c := conn_create(s.addr, i, s.server_pub, s.token, &app.device_key)
		append(&app.conns, c)
		conn_start(c)
	}
	if len(app.conns) > 0 {
		app.active = 0
	}
}

SCALE_MIN :: f32(0.7)
SCALE_MAX :: f32(1.8)

// UI-Zoom setzen (Strg +/-/0): Fonts in neuer physischer Größe laden,
// Mess-Caches invalidieren, Wahl persistieren.
app_set_scale :: proc(app: ^App, scale: f32) {
	s := clamp(scale, SCALE_MIN, SCALE_MAX)
	if abs(s - g_scale) < 0.01 {
		return
	}
	g_scale = s
	fonts_unload(&app.fonts)
	app.fonts = fonts_load(g_scale)
	rune_widths_clear()
	for c in app.conns {
		for &cs in c.channels {
			cs.rows_w = -1 // Layout-Cache invalidieren (Messungen ändern sich leicht)
		}
	}
	app.cfg.ui_scale = g_scale
	config_save(&app.cfg)
	toast(app, .Info, fmt.tprintf("Zoom %d %%", int(math.round(g_scale * 100))))
}

// --- Theme ---

// Soll gerade dunkel dargestellt werden?
theme_is_dark :: proc(app: ^App) -> bool {
	switch app.theme_mode {
	case .Light:
		return false
	case .Dark:
		return true
	case .System:
		return sys_theme_is_dark()
	}
	return false
}

@(private = "file")
theme_target :: proc(app: ^App) -> f32 {
	return theme_is_dark(app) ? 1 : 0
}

// Pro Frame vor dem Zeichnen: Überblendung weiterdrehen und die aktiven
// Farben setzen. Muss vor ClearBackground laufen (main.odin).
theme_frame :: proc(app: ^App) {
	target := theme_target(app)
	app.theme_k = exp_smooth(app.theme_k, target, app.dt, 6)
	if abs(app.theme_k - target) < 0.001 {
		app.theme_k = target
	}
	theme_apply(app.theme_k)
}

// Theme umstellen (Dropdown in der Titelleiste) und Wahl merken.
app_set_theme :: proc(app: ^App, mode: Theme_Mode) {
	if app.theme_mode == mode {
		return
	}
	app.theme_mode = mode
	sys_theme_follow(mode == .System) // nur „System" muss dem Desktop folgen
	app.cfg.theme = theme_mode_to_string(mode)
	config_save(&app.cfg)
}

app_active_conn :: proc(app: ^App) -> ^Server_Conn {
	if app.active >= 0 && app.active < len(app.conns) {
		return app.conns[app.active]
	}
	return nil
}

app_total_unread :: proc(app: ^App) -> int {
	total := 0
	for c in app.conns {
		for &cs in c.channels {
			total += cs.unread
		}
	}
	return total
}

// Neuen Server hinzufügen (Add-Server-Modal / Welcome).
app_add_server :: proc(app: ^App, addr: string) {
	entry := Config_Server{addr = strings.clone(addr)}
	append(&app.cfg.servers, entry)
	config_save(&app.cfg)

	c := conn_create(addr, len(app.cfg.servers) - 1, "", "", &app.device_key)
	append(&app.conns, c)
	app.active = len(app.conns) - 1
	conn_start(c)
}

// Config-Eintrag eines Servers aktualisieren + speichern.
app_sync_config :: proc(app: ^App, c: ^Server_Conn) {
	if c.cfg_index < 0 || c.cfg_index >= len(app.cfg.servers) {
		return
	}
	e := &app.cfg.servers[c.cfg_index]
	e.token = strings.clone(c.token)
	if c.server_name != "" {
		e.server_name = strings.clone(c.server_name)
	}
	if c.me.username != "" {
		e.username = strings.clone(c.me.username)
	}
	if c.expected_pub != "" {
		e.server_pub = c.expected_pub
	}
	config_save(&app.cfg)
}

// Pro Frame: alle Verbindungen pollen und Nachrichten anwenden.
app_poll :: proc(app: ^App) {
	for c, i in app.conns {
		app_poll_conn(app, c, i == app.active)
	}
	call_tick(app)          // Voice: Keepalive/HELLO-Retries, Trennung erkennen
	settings_test_tick(app) // Audio-Tests: Ton-Ende, Test-Mute zurücknehmen
}

conn_label :: proc(c: ^Server_Conn) -> string {
	return c.server_name != "" ? c.server_name : c.addr
}

@(private = "file")
app_poll_conn :: proc(app: ^App, c: ^Server_Conn, is_active_server: bool) {
	// Inbox + Worker-Änderungen unter Mutex rausholen
	sync.lock(&c.mu)
	msgs: []shared.Wire
	if len(c.inbox) > 0 {
		msgs = make([]shared.Wire, len(c.inbox), context.temp_allocator)
		copy(msgs, c.inbox[:])
		clear(&c.inbox)
	}
	phase := c.phase
	err_text := c.err_text
	dirty := c.dirty
	c.dirty = false
	got_pub := c.got_pub
	c.got_pub = ""
	new_token := c.new_token
	c.new_token = ""
	token_bad := c.token_bad
	c.token_bad = false
	sync.unlock(&c.mu)

	if dirty {
		if got_pub != "" {
			c.expected_pub = got_pub // TOFU: Key übernehmen
		}
		if token_bad {
			c.token = ""
		}
		if new_token != "" {
			c.token = new_token
		}
		app_sync_config(app, c)
	}

	// Phasen-Übergänge: Toasts + Auto-Reconnect planen
	if phase != c.prev_phase {
		if phase == .Failed {
			toast(app, .Error, fmt.tprintf("%s: %s", conn_label(c),
				err_text != "" ? err_text : "Verbindung fehlgeschlagen"))
			// Bei Schlüssel-Mismatch niemals automatisch neu verbinden
			if err_text != "Server-Schlüssel hat sich geändert!" && c.retry_count < 30 {
				delay := f64(min(2 + c.retry_count*2, 15))
				c.retry_at = rl.GetTime() + delay
			} else {
				c.retry_at = 0
			}
		}
		if phase == .Ready && c.prev_phase != .Setup_Needed && c.retry_count > 0 {
			toast(app, .Success, fmt.tprintf("%s: wieder verbunden", conn_label(c)))
		}
		if phase == .Ready {
			c.retry_count = 0
			c.retry_at = 0
		}
		c.prev_phase = phase
	}
	if phase == .Failed && c.retry_at > 0 && rl.GetTime() >= c.retry_at {
		c.retry_at = 0
		c.retry_count += 1
		conn_start(c)
	}

	// Nach Ready einmalig Users + Channels laden
	if phase == .Ready && !c.synced {
		c.synced = true
		conn_request(c, {kind = shared.K_LIST_USERS})
		conn_request(c, {kind = shared.K_LIST_CHANNELS})
	}

	// TCP-Latenz: alle 5 s ein leichtgewichtiger Ping (Kopfzeilen-Indikator)
	if phase == .Ready && !c.rtt_pending && mono_ms() - c.rtt_last >= 5000 {
		c.rtt_pending = true
		c.rtt_sent = mono_ms()
		c.rtt_last = c.rtt_sent
		conn_request(c, {kind = shared.K_PING})
	}

	for w in msgs {
		app_apply_wire(app, c, w, is_active_server)
	}
}

// Eine Wire-Nachricht anwenden (Antwort oder Event).
@(private = "file")
app_apply_wire :: proc(app: ^App, c: ^Server_Conn, w: shared.Wire, is_active_server: bool) {
	if w.seq != 0 {
		p, has := c.pending[w.seq]
		if !has {
			return
		}
		delete_key(&c.pending, w.seq)
		app_apply_reply(app, c, w, p)
		return
	}

	switch w.kind {
	case shared.EV_MESSAGE:
		app_add_message(app, c, w.message, is_active_server)
	case shared.EV_MESSAGE_EDITED:
		app_apply_edit(c, w.message)
	case shared.EV_CHANNEL:
		existed := conn_find_channel(c, w.channel.id) != nil
		app_upsert_channel(app, c, w.channel)
		if !existed && !w.channel.is_dm {
			toast(app, .Info, fmt.tprintf("Du wurdest zu #%s hinzugefügt", w.channel.name))
		}
	case shared.EV_CHANNEL_REMOVED:
		if cs := conn_find_channel(c, w.channel_id); cs != nil && !cs.ch.is_dm {
			if w.err == "deleted" {
				toast(app, .Info, fmt.tprintf("Kanal #%s wurde gelöscht", cs.ch.name))
			} else {
				toast(app, .Info, fmt.tprintf("Du wurdest aus #%s entfernt", cs.ch.name))
			}
		}
		app_remove_channel(c, w.channel_id)
	case shared.EV_USER:
		app_upsert_user(c, w.user)
	case shared.EV_SERVER:
		c.server_name = strings.clone(w.server_name)
		app_sync_config(app, c)
	case shared.EV_CALL_STATE:
		app_apply_call_state(app, c, w.channel_id, w.call)
	}
}

@(private = "file")
app_apply_reply :: proc(app: ^App, c: ^Server_Conn, w: shared.Wire, p: Pending) {
	switch p.kind {
	case shared.K_LOGIN, shared.K_REGISTER:
		c.auth_busy = false
		if !w.ok {
			c.auth_error = strings.clone(translate_err(w.err))
			return
		}
		c.token = strings.clone(w.token)
		c.me = w.user
		c.server_name = strings.clone(w.server_name)
		c.initialized = w.initialized
		c.setup_needed = w.setup_needed
		c.auth_error = ""
		ti_clear(&c.auth_pass)
		sync.lock(&c.mu)
		c.phase = .Setup_Needed if w.setup_needed else .Ready
		sync.unlock(&c.mu)
		app_sync_config(app, c)
		app.ui.focus = w.setup_needed ? .Setup_Name : .Message

	case shared.K_SETUP:
		if !w.ok {
			c.setup_error = strings.clone(translate_err(w.err))
			return
		}
		c.server_name = strings.clone(w.server_name)
		c.initialized = true
		c.setup_needed = false
		sync.lock(&c.mu)
		c.phase = .Ready
		sync.unlock(&c.mu)
		app_sync_config(app, c)
		app.ui.focus = .Message
		toast(app, .Success, fmt.tprintf("Server „%s“ ist eingerichtet", c.server_name))

	case shared.K_LIST_USERS:
		clear(&c.users)
		for u in w.users {
			append(&c.users, u)
		}

	case shared.K_LIST_CHANNELS:
		for ch in w.channels {
			app_upsert_channel(app, c, ch)
		}
		clear(&c.calls)
		for info in w.calls {
			conn_set_call_state(c, info)
		}
		// ersten Channel aktivieren
		if c.active_channel == 0 {
			for &cs in c.channels {
				if !cs.ch.is_dm {
					app_activate_channel(app, c, cs.ch.id)
					break
				}
			}
		}

	case shared.K_CREATE_CHANNEL:
		if !w.ok {
			toast(app, .Error, translate_err(w.err))
			return
		}
		app_upsert_channel(app, c, w.channel)
		app_activate_channel(app, c, w.channel.id)
		toast(app, .Success, fmt.tprintf("Kanal #%s erstellt", w.channel.name))

	case shared.K_OPEN_DM:
		if !w.ok {
			toast(app, .Error, translate_err(w.err))
			return
		}
		app_upsert_channel(app, c, w.channel)
		app_activate_channel(app, c, w.channel.id)

	case shared.K_INVITE, shared.K_KICK:
		if !w.ok {
			toast(app, .Error, translate_err(w.err))
			return
		}
		app_upsert_channel(app, c, w.channel)

	case shared.K_LEAVE:
		if !w.ok {
			toast(app, .Error, translate_err(w.err))
			return
		}
		if cs := conn_find_channel(c, p.channel_id); cs != nil {
			toast(app, .Info, fmt.tprintf("Du hast #%s verlassen", cs.ch.name))
		}
		app_remove_channel(c, p.channel_id)

	case shared.K_DELETE_CHANNEL:
		if !w.ok {
			toast(app, .Error, translate_err(w.err))
			return
		}
		if cs := conn_find_channel(c, p.channel_id); cs != nil {
			toast(app, .Success, fmt.tprintf("Kanal #%s gelöscht", cs.ch.name))
		}
		app_remove_channel(c, p.channel_id)

	case shared.K_SEND:
		if !w.ok {
			toast(app, .Error, fmt.tprintf("Nachricht nicht gesendet: %s", translate_err(w.err)))
			return
		}
		app_add_message(app, c, w.message, true)

	case shared.K_EDIT_START:
		// Der Editor wurde optimistisch geöffnet — lehnt der Server den
		// Einstieg ab (Frist/Limit), wieder schließen.
		if !w.ok && c.edit_msg_id == p.message_id {
			toast(app, .Error, translate_err(w.err))
			stop_edit(app, c)
		}

	case shared.K_EDIT_MESSAGE:
		c.edit_busy = false
		if !w.ok {
			toast(app, .Error, fmt.tprintf("Nicht gespeichert: %s", translate_err(w.err)))
			// Bei endgültigen Fehlern den Editor schließen; sonst bleibt der
			// getippte Text stehen (Abbrechen geht immer).
			if w.err == "edit_window" || w.err == "edit_limit" || w.err == "not_found" {
				if c.edit_msg_id == p.message_id {
					stop_edit(app, c)
				}
			}
			return
		}
		app_apply_edit(c, w.message)
		if c.edit_msg_id == w.message.id {
			stop_edit(app, c)
		}

	case shared.K_CALL_JOIN:
		app.call.joining = false
		if !w.ok {
			toast(app, .Error, fmt.tprintf("Call-Beitritt fehlgeschlagen: %s", translate_err(w.err)))
			return
		}
		call_begin(app, c, w)

	case shared.K_CALL_LEAVE:
	// lokal längst abgebaut — nichts zu tun

	case shared.K_CALL_MUTE:
		if !w.ok {
			toast(app, .Error, translate_err(w.err))
		}

	case shared.K_PING:
		c.rtt_pending = false
		rtt := f32(mono_ms() - c.rtt_sent)
		// Geglättet, damit die Anzeige nicht zappelt (erster Wert direkt)
		c.rtt_ms = c.rtt_ms <= 0 ? rtt : c.rtt_ms*0.6 + rtt*0.4

	case shared.K_MESSAGE_HISTORY:
		if app.modal != .Msg_History || app.history_msg_id != p.message_id {
			return
		}
		app.history_loading = false
		if !w.ok {
			toast(app, .Error, translate_err(w.err))
			close_modal(app)
			return
		}
		clear(&app.history_versions)
		for v in w.messages {
			append(&app.history_versions, v)
		}

	case shared.K_HISTORY:
		cs := conn_find_channel(c, w.channel_id != 0 ? w.channel_id : p.channel_id)
		if cs == nil {
			return
		}
		cs.history_loading = false
		if !w.ok {
			return
		}
		if p.before_id == 0 {
			// initiale Ladung
			clear(&cs.messages)
			for m in w.messages {
				append(&cs.messages, m)
			}
			cs.history_loaded = true
			cs.history_done = len(w.messages) < HISTORY_PAGE
			cs.stick_bottom = true
		} else {
			// ältere Seite voranstellen (Scroll-Anpassung macht das Chat-Layout)
			if len(w.messages) == 0 {
				cs.history_done = true
				return
			}
			first_id := len(cs.messages) > 0 ? cs.messages[0].id : max(u64)
			insert_at := 0
			for m in w.messages {
				if m.id < first_id {
					inject_at(&cs.messages, insert_at, m)
					insert_at += 1
				}
			}
			cs.history_done = len(w.messages) < HISTORY_PAGE
			cs.adjust_scroll = true
		}
	}
}

// Einen Edit auf die lokale Kopie der Nachricht anwenden (Event oder
// eigene edit-Antwort). Der Layout-Cache wird invalidiert — die neue
// Fassung kann anders hoch sein.
@(private = "file")
app_apply_edit :: proc(c: ^Server_Conn, m: shared.Chat_Message) {
	cs := conn_find_channel(c, m.channel_id)
	if cs == nil {
		return
	}
	for &ex in cs.messages {
		if ex.id == m.id {
			ex.text = m.text
			ex.edited_ms = m.edited_ms
			ex.edit_count = m.edit_count
			ex.call_end_ms = m.call_end_ms // Call-Karte: „läuft“ → „beendet“
			cs.rows_w = -1
			// Selektions-Indizes dieser Nachricht sind hinfällig
			if g_sel.active && g_sel.conn == c && g_sel.channel == m.channel_id {
				sel_clear()
			}
			return
		}
	}
}

// Nachricht an einen Channel anhängen (Event oder eigene send-Antwort).
@(private = "file")
app_add_message :: proc(app: ^App, c: ^Server_Conn, m: shared.Chat_Message, is_active_server: bool) {
	cs := conn_find_channel(c, m.channel_id)
	if cs == nil {
		return
	}
	if cs.history_loaded {
		// Duplikate vermeiden (eigene Nachricht könnte doppelt ankommen)
		if len(cs.messages) > 0 && cs.messages[len(cs.messages)-1].id >= m.id {
			return
		}
		append(&cs.messages, m)
	}
	is_active_channel := is_active_server && c.active_channel == m.channel_id
	if m.author_id != c.me.id {
		if !is_active_channel || !rl.IsWindowFocused() {
			cs.unread += 1
			anim_pop(app, anim_id(.Badge_Pop, cs.ch.id))
		}
	} else if is_active_channel {
		// eigene Nachricht → ans Ende springen, Divider erledigt
		cs.stick_bottom = true
		cs.divider_id = 0
	}
}

app_upsert_channel :: proc(app: ^App, c: ^Server_Conn, ch: shared.Channel) {
	if cs := conn_find_channel(c, ch.id); cs != nil {
		cs.ch = ch // member_ids ersetzen
		return
	}
	cs: Channel_State
	cs.ch = ch
	cs.stick_bottom = true
	append(&c.channels, cs)
}

app_remove_channel :: proc(c: ^Server_Conn, id: u64) {
	for cs, i in c.channels {
		if cs.ch.id == id {
			ordered_remove(&c.channels, i)
			break
		}
	}
	if c.active_channel == id {
		c.active_channel = 0
	}
}

app_upsert_user :: proc(c: ^Server_Conn, u: shared.User) {
	if u.id == c.me.id {
		c.me = u
	}
	if ex := conn_find_user(c, u.id); ex != nil {
		ex^ = u
		return
	}
	append(&c.users, u)
}

// Channel aktivieren: Unread löschen, Divider setzen, ggf. History laden.
app_activate_channel :: proc(app: ^App, c: ^Server_Conn, id: u64) {
	if c.active_channel == id {
		app.ui.focus = .Message
		return
	}
	c.active_channel = id
	cs := conn_find_channel(c, id)
	if cs == nil {
		return
	}
	cs.unread = 0
	cs.stick_bottom = true

	// „Neu"-Divider: markiert die erste ungelesene Nachricht
	cs.divider_id = 0
	if cs.last_read_id > 0 && len(cs.messages) > 0 &&
	   cs.messages[len(cs.messages)-1].id > cs.last_read_id {
		cs.divider_id = cs.last_read_id
	}

	if !cs.history_loaded && !cs.history_loading {
		cs.history_loading = true
		conn_request(c, {kind = shared.K_HISTORY, channel_id = id, limit = HISTORY_PAGE}, {channel_id = id})
	}
	app.ui.focus = .Message
}

// Ältere Nachrichten nachladen (beim Hochscrollen).
app_request_older :: proc(c: ^Server_Conn, cs: ^Channel_State) {
	if cs.history_loading || cs.history_done || !cs.history_loaded || len(cs.messages) == 0 {
		return
	}
	cs.history_loading = true
	conn_request(c,
		{kind = shared.K_HISTORY, channel_id = cs.ch.id, before_id = cs.messages[0].id, limit = HISTORY_PAGE},
		{channel_id = cs.ch.id, before_id = cs.messages[0].id})
}

// Anzeigename eines Users (Fallback: username, Fallback: "User #id").
user_label :: proc(c: ^Server_Conn, id: u64) -> string {
	if u := conn_find_user(c, id); u != nil {
		if u.display_name != "" {
			return u.display_name
		}
		return u.username
	}
	if id == c.me.id {
		if c.me.display_name != "" {
			return c.me.display_name
		}
		return c.me.username
	}
	return fmt.tprintf("User #%d", id)
}

// Titel eines Channels (# name bzw. DM-Partner).
channel_title :: proc(c: ^Server_Conn, cs: ^Channel_State) -> string {
	if cs.ch.is_dm {
		for m in cs.ch.member_ids {
			if m != c.me.id {
				return user_label(c, m)
			}
		}
		return user_label(c, c.me.id)
	}
	return fmt.tprintf("# %s", cs.ch.name)
}

// Fehlercodes vom Server in deutsche Meldungen übersetzen.
translate_err :: proc(code: string) -> string {
	switch code {
	case "invalid_credentials":
		return "Falscher Nutzername oder Passwort"
	case "username_taken":
		return "Nutzername bereits vergeben"
	case "invalid_token":
		return "Sitzung abgelaufen, bitte neu anmelden"
	case "name_taken":
		return "Kanal existiert bereits"
	case "not_found":
		return "Nicht gefunden"
	case "not_a_member":
		return "Du bist kein Mitglied dieses Kanals"
	case "already_member":
		return "Bereits Mitglied"
	case "not_allowed":
		return "Keine Berechtigung"
	case "not_authenticated":
		return "Nicht angemeldet"
	case "invalid_request":
		return "Ungültige Eingabe"
	case "edit_window":
		return "Die Bearbeitungsfrist (1 Minute) ist abgelaufen"
	case "edit_limit":
		return "Diese Nachricht wurde bereits 3-mal bearbeitet"
	}
	return fmt.tprintf("Fehler: %s", code)
}

// --- Zeit-Formatierung ---

// Unix-Millisekunden „jetzt" (lokale Uhr — Nachrichten-Zeitstempel kommen
// vom Server; leichte Uhren-Drift betrifft nur die Anzeige).
unix_now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private = "file")
local_datetime :: proc(app: ^App, ts_ms: i64) -> (datetime.DateTime, bool) {
	t := time.unix(ts_ms / 1000, (ts_ms % 1000) * 1_000_000)
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return dt, false
	}
	if app.tz != nil {
		if local, lok := timezone.datetime_to_tz(dt, app.tz); lok {
			dt = local
		}
	}
	return dt, true
}

// Unix-Millisekunden → "HH:MM" in lokaler Zeit.
format_time_hm :: proc(app: ^App, ts_ms: i64) -> string {
	dt, ok := local_datetime(app, ts_ms)
	if !ok {
		return "??:??"
	}
	return fmt.tprintf("%02d:%02d", dt.hour, dt.minute)
}

// Lokaler Tages-Schlüssel (JJJJMMTT) für Day-Separator.
day_key :: proc(app: ^App, ts_ms: i64) -> i64 {
	dt, ok := local_datetime(app, ts_ms)
	if !ok {
		return 0
	}
	return i64(dt.year)*10000 + i64(dt.month)*100 + i64(dt.day)
}

// "Heute" / "Gestern" / "14. Juli 2026"
format_day_label :: proc(app: ^App, ts_ms: i64) -> string {
	dt, ok := local_datetime(app, ts_ms)
	if !ok {
		return "?"
	}
	now_ms := unix_now_ms()
	today := day_key(app, now_ms)
	yesterday := day_key(app, now_ms - 24*60*60*1000)
	key := i64(dt.year)*10000 + i64(dt.month)*100 + i64(dt.day)
	if key == today {
		return "Heute"
	}
	if key == yesterday {
		return "Gestern"
	}
	months := [12]string{
		"Januar", "Februar", "März", "April", "Mai", "Juni",
		"Juli", "August", "September", "Oktober", "November", "Dezember",
	}
	m := clamp(int(dt.month), 1, 12)
	return fmt.tprintf("%d. %s %d", dt.day, months[m-1], dt.year)
}
