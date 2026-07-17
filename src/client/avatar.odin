package main

// Profilbild-Cache: pro Verbindung eine Map user_id → Textur. Bilder kommen
// als base64-PNG per avatar_get; die Kreisform wird beim Hochladen in den
// Alpha-Kanal gebacken (raylib kann Texturen nicht rund clippen). Alles hier
// läuft auf dem Main-Thread — nur der besitzt den GL-Kontext.

import "core:encoding/base64"
import "core:math"

import rl "vendor:raylib"
import shared "../shared"

Avatar_State :: struct {
	ver:        u64, // Version der geladenen Textur
	req_ver:    u64, // Version, die der laufende avatar_get holt
	tex:        rl.Texture2D,
	has_tex:    bool,
	pending:    bool, // avatar_get unterwegs
	failed_ver: u64,  // diese Version schlug fehl → erst bei Wechsel neu versuchen
}

// PNG dekodieren, Kreis in den Alpha-Kanal stanzen und als Textur hochladen.
// Gibt has_tex=false zurück, wenn das PNG nicht dekodierbar ist.
avatar_png_texture :: proc(png: []byte) -> (tex: rl.Texture2D, ok: bool) {
	if len(png) == 0 {
		return
	}
	img := rl.LoadImageFromMemory(".png", raw_data(png), i32(len(png)))
	if img.data == nil {
		return
	}
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
	avatar_mask_circle(&img)
	tex = rl.LoadTextureFromImage(img)
	rl.UnloadImage(img)
	if tex.id == 0 {
		return
	}
	// Avatare werden fast immer verkleinert gezeichnet — ohne Mipmaps flimmert das.
	rl.GenTextureMipmaps(&tex)
	rl.SetTextureFilter(tex, .TRILINEAR)
	return tex, true
}

// Alpha außerhalb des Innenkreises auf 0, mit ~1 px weicher Kante.
@(private = "file")
avatar_mask_circle :: proc(img: ^rl.Image) {
	w := int(img.width)
	h := int(img.height)
	if w <= 0 || h <= 0 {
		return
	}
	px := ([^]u8)(img.data)
	cx := f32(w) / 2
	cy := f32(h) / 2
	r := min(cx, cy)
	for y in 0 ..< h {
		dy := f32(y) + 0.5 - cy
		for x in 0 ..< w {
			dx := f32(x) + 0.5 - cx
			d := math.sqrt(dx*dx + dy*dy)
			a := clamp(r - d + 0.5, 0, 1)
			if a >= 1 {
				continue
			}
			i := (y*w + x)*4 + 3
			px[i] = u8(f32(px[i]) * a)
		}
	}
}

// Fertige Textur in den Cache legen (ersetzt eine ältere Version).
avatar_cache_put :: proc(c: ^Server_Conn, uid: u64, ver: u64, png: []byte) {
	e := c.avatars[uid]
	tex, ok := avatar_png_texture(png)
	if !ok {
		e.pending = false
		e.failed_ver = ver
		c.avatars[uid] = e
		return
	}
	if e.has_tex {
		rl.UnloadTexture(e.tex)
	}
	e.tex = tex
	e.has_tex = true
	e.ver = ver
	e.pending = false
	e.failed_ver = 0
	c.avatars[uid] = e
}

// Aktuelle Avatar-Version eines Users aus Sicht dieser Verbindung.
@(private = "file")
avatar_ver_of :: proc(c: ^Server_Conn, uid: u64) -> u64 {
	if u := conn_find_user(c, uid); u != nil {
		return u.avatar
	}
	if uid == c.me.id {
		return c.me.avatar
	}
	return 0
}

// Textur für einen User holen; stößt bei Bedarf den Abruf an. Solange die
// neue Version lädt, bleibt die alte Textur sichtbar (kein Flackern).
avatar_texture :: proc(app: ^App, c: ^Server_Conn, uid: u64) -> (rl.Texture2D, bool) {
	ver := avatar_ver_of(c, uid)
	e, has := c.avatars[uid]
	if ver == 0 {
		// Bild wurde entfernt → Textur aufräumen
		if has {
			if e.has_tex {
				rl.UnloadTexture(e.tex)
			}
			delete_key(&c.avatars, uid)
		}
		return {}, false
	}
	if has && e.has_tex && e.ver == ver {
		return e.tex, true
	}
	if !has || (!e.pending && e.failed_ver != ver) {
		if conn_phase(c) == .Ready {
			e.pending = true
			e.req_ver = ver
			c.avatars[uid] = e
			conn_request(c, {kind = shared.K_AVATAR_GET, user_id = uid}, {user_id = uid})
		}
	}
	if has && e.has_tex {
		return e.tex, true // alte Version zeigen, bis die neue da ist
	}
	return {}, false
}

// Antwort auf avatar_get anwenden (app_apply_reply).
avatar_apply_get :: proc(c: ^Server_Conn, w: shared.Wire, p: Pending) {
	e := c.avatars[p.user_id]
	e.pending = false
	if !w.ok {
		e.failed_ver = e.req_ver
		c.avatars[p.user_id] = e
		return
	}
	png, derr := base64.decode(w.data, base64.DEC_TABLE, nil, context.temp_allocator)
	if derr != nil {
		e.failed_ver = e.req_ver // sonst fragt jeder Frame neu an
		c.avatars[p.user_id] = e
		return
	}
	c.avatars[p.user_id] = e
	ver := w.user.avatar
	if ver == 0 {
		ver = e.req_ver
	}
	avatar_cache_put(c, p.user_id, ver, png)
}

// Alle Texturen dieser Verbindung freigeben (Reconnect/Server entfernen).
avatar_cache_clear :: proc(c: ^Server_Conn) {
	for _, e in c.avatars {
		if e.has_tex {
			rl.UnloadTexture(e.tex)
		}
	}
	clear(&c.avatars)
}
