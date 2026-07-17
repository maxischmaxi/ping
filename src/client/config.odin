package main

// Config-Persistenz: ~/.config/flurfunk/client.json (XDG_CONFIG_HOME respektiert).

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"

import shared "../shared"

Config_Server :: struct {
	addr:        string `json:"addr"`,
	server_pub:  string `json:"server_pub,omitempty"`, // hex, TOFU-gepinnter Server-Key
	token:       string `json:"token,omitempty"`,
	username:    string `json:"username,omitempty"`,
	server_name: string `json:"server_name,omitempty"`,
}

Config :: struct {
	device_key: string                  `json:"device_key"`, // hex(32B X25519-Private)
	ui_scale:   f32                     `json:"ui_scale,omitempty"`, // UI-Zoom (Strg +/-), 0 = Standard
	theme:      string                  `json:"theme,omitempty"`, // "system" (Default) | "light" | "dark"

	// Audio (Settings-Dialog). Geräte per Name ("" = Systemstandard);
	// die Schalter sind negativ benannt, damit der Nullwert = Default (an).
	audio_mic:   string `json:"audio_mic,omitempty"`,
	audio_out:   string `json:"audio_out,omitempty"`,
	denoise_off: bool   `json:"denoise_off,omitempty"`,
	aec_off:     bool   `json:"aec_off,omitempty"`,
	gate_off:    bool   `json:"gate_off,omitempty"`,

	// Desktop-Verhalten (ebenfalls negativ benannt: Nullwert = Default).
	quit_on_close: bool `json:"quit_on_close,omitempty"`, // true = X beendet die App statt Tray
	notify_off:    bool `json:"notify_off,omitempty"`,    // true = keine Desktop-Benachrichtigungen

	servers:    [dynamic]Config_Server `json:"servers"`,
}

config_dir :: proc(allocator := context.allocator) -> string {
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if xdg != "" {
		return fmt.aprintf("%s/flurfunk", xdg, allocator = allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.config/flurfunk", home, allocator = allocator)
}

// One-time migration: adopt the old "ping" config dir if the new one is absent.
config_migrate :: proc() {
	new_dir := config_dir(context.temp_allocator)
	if os.exists(new_dir) {
		return
	}
	old_dir: string
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if xdg != "" {
		old_dir = fmt.tprintf("%s/ping", xdg)
	} else {
		home := os.get_env("HOME", context.temp_allocator)
		old_dir = fmt.tprintf("%s/.config/ping", home)
	}
	if os.exists(old_dir) {
		_ = os.rename(old_dir, new_dir)
	}
}

config_path :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf("%s/client.json", config_dir(context.temp_allocator), allocator = allocator)
}

config_load :: proc() -> Config {
	config_migrate()
	cfg: Config
	path := config_path(context.temp_allocator)
	data, err := os.read_entire_file(path, context.allocator)
	if err == nil && len(data) > 0 {
		// Fehler beim Parsen → leere Config (Neustart des Setups)
		_ = json.unmarshal(data, &cfg, json.DEFAULT_SPECIFICATION, context.allocator)
	}
	if cfg.device_key == "" {
		// Erster Start: Device-Key generieren und sofort persistieren
		priv: DeviceKey
		if shared.generate_static_key(&priv) {
			raw := shared.static_key_bytes(&priv)
			enc, _ := hex.encode(raw[:], context.allocator)
			cfg.device_key = string(enc)
			config_save(&cfg)
		}
	}
	return cfg
}

config_save :: proc(cfg: ^Config) {
	// Verzeichnisse anlegen (Fehler ignorieren, existiert vermutlich schon)
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if xdg == "" {
		home := os.get_env("HOME", context.temp_allocator)
		_ = os.make_directory(fmt.tprintf("%s/.config", home))
	}
	_ = os.make_directory(config_dir(context.temp_allocator))

	data, err := json.marshal(cfg^, {pretty = true}, context.temp_allocator)
	if err != nil {
		return
	}
	_ = os.write_entire_file(config_path(context.temp_allocator), data)
}

// Device-Key aus der Config laden (hex → Private_Key).
config_device_key :: proc(cfg: ^Config, priv: ^DeviceKey) -> bool {
	raw, ok := hex.decode(transmute([]byte)cfg.device_key, context.temp_allocator)
	if !ok || len(raw) != shared.STATIC_KEY_SIZE {
		return false
	}
	return shared.static_key_from_bytes(priv, raw)
}
