package main

// Design-Tokens: Farben, Radii, Abstände, Schatten. Eine Quelle für alles,
// damit die UI konsistent aussieht.
//
// Stil: neutrale Zinc-Palette (shadcn-artig) + warmer „Sunset"-Akzent aus
// dem Marken-Logo (Pink → Orange → Gelb). 1-px-Borders, kontrastreicher
// Primary — bewusst kein Slack-Aubergine.
//
// Themes: Es gibt zwei feste Paletten (PAL_LIGHT/PAL_DARK). Die aktiven
// Farben liegen als Laufzeit-Variablen (`COL_*`) vor und werden pro Frame
// aus beiden Paletten interpoliert — dadurch blendet ein Theme-Wechsel
// weich über, statt hart umzuspringen. Widgets lesen einfach `COL_TEXT`
// & Co. und wissen von alldem nichts.

import "core:math"

import rl "vendor:raylib"

// --- Globaler UI-Zoom (Strg +/-/0). Geometrie wird über eine Camera2D
// skaliert, Fonts werden in physischer Pixelgröße neu geladen — Text
// bleibt dadurch auf jeder Stufe scharf. ---
g_scale := f32(1)

// --- Theme-Auswahl ---

Theme_Mode :: enum {
	System, // folgt der Desktop-Einstellung (systheme.odin)
	Light,
	Dark,
}

theme_mode_label :: proc(m: Theme_Mode) -> string {
	switch m {
	case .System:
		return "System"
	case .Light:
		return "Hell"
	case .Dark:
		return "Dunkel"
	}
	return "System"
}

theme_mode_to_string :: proc(m: Theme_Mode) -> string {
	switch m {
	case .System:
		return "system"
	case .Light:
		return "light"
	case .Dark:
		return "dark"
	}
	return "system"
}

theme_mode_from_string :: proc(s: string) -> Theme_Mode {
	switch s {
	case "light":
		return .Light
	case "dark":
		return .Dark
	}
	return .System
}

// --- Paletten ---
//
// Alle Felder sind rl.Color — darauf verlässt sich pal_mix (siehe #assert).

Palette :: struct {
	// Flächen
	chat_bg:           rl.Color, // Leseflächen (Nachrichtenliste)
	panel_bg:          rl.Color, // Auth/Setup/Welcome-Hintergrund
	rail_bg:           rl.Color, // Server-Leiste + Profil-Footer
	rail_item:         rl.Color, // Ruhefläche des „+"-Buttons
	sidebar_bg:        rl.Color,
	surface:           rl.Color, // Karten, Modals, Eingabefelder
	surface_hover:     rl.Color,

	// Text
	text:              rl.Color,
	text_dim:          rl.Color,
	text_faint:        rl.Color,
	sidebar_text:      rl.Color,
	sidebar_dim:       rl.Color,

	// Linien & Hover
	border:            rl.Color,
	border_soft:       rl.Color,
	sidebar_line:      rl.Color,
	sidebar_hover:     rl.Color,
	hover_row:         rl.Color,

	// Primary (kontrastreiche Aktion: dunkel im Hellen, hell im Dunklen)
	primary:           rl.Color,
	primary_hover:     rl.Color,
	primary_fg:        rl.Color, // Text/Icons auf primary

	// Brand-Akzent
	accent:            rl.Color,
	accent_soft:       rl.Color, // Fokus-Glow (Alpha bereits eingebacken)

	// Status / Semantik
	online:            rl.Color,
	red:               rl.Color,
	red_hover:         rl.Color,
	red_soft:          rl.Color, // Hover-Fläche des Danger-Buttons
	badge:             rl.Color,
	yellow:            rl.Color,

	// Inline-Code
	code_bg:           rl.Color,
	code_text:         rl.Color,

	// Code-Blöcke (```lang) + Syntax-Highlighting
	code_block_bg:     rl.Color,
	code_block_border: rl.Color,
	code_block_head:   rl.Color, // Hairline unter dem Sprach-Label
	syn_text:          rl.Color,
	syn_keyword:       rl.Color,
	syn_type:          rl.Color,
	syn_string:        rl.Color,
	syn_number:        rl.Color,
	syn_comment:       rl.Color,

	// Basisfarben für Alpha-Effekte (kippen mit dem Theme)
	overlay:           rl.Color, // Hover-Schleier: dunkel auf hell, hell auf dunkel
	press:             rl.Color, // Press-Tint für Buttons
	scrim:             rl.Color, // Modal-Hintergrund (Alpha eingebacken)
	shadow:            rl.Color, // Schatten (Alpha = Basisstärke)

	// Schwebende Elemente
	tooltip_bg:        rl.Color,
	tooltip_fg:        rl.Color,
	toast_bg:          rl.Color,
	toast_fg:          rl.Color,

	// Kleinkram
	scroll_thumb:      rl.Color,
	scroll_thumb_hot:  rl.Color,
	send_idle:         rl.Color, // Senden-Button ohne Text
}

PAL_LIGHT :: Palette {
	chat_bg           = {255, 255, 255, 255},
	panel_bg          = {250, 250, 250, 255}, // zinc-50
	rail_bg           = {244, 244, 245, 255}, // zinc-100
	rail_item         = {228, 228, 231, 255}, // zinc-200
	sidebar_bg        = {250, 250, 250, 255},
	surface           = {255, 255, 255, 255},
	surface_hover     = {243, 243, 243, 255},

	text              = {24, 24, 27, 255},    // zinc-900
	text_dim          = {113, 113, 122, 255}, // zinc-500
	text_faint        = {161, 161, 170, 255}, // zinc-400
	sidebar_text      = {82, 82, 91, 255},    // zinc-600
	sidebar_dim       = {161, 161, 170, 255}, // zinc-400

	border            = {228, 228, 231, 255}, // zinc-200
	border_soft       = {244, 244, 245, 255}, // zinc-100
	sidebar_line      = {228, 228, 231, 255},
	sidebar_hover     = {24, 24, 27, 12},
	hover_row         = {24, 24, 27, 8},

	primary           = {24, 24, 27, 255}, // zinc-900
	primary_hover     = {39, 39, 42, 255}, // zinc-800
	primary_fg        = {255, 255, 255, 255},

	accent            = {242, 88, 47, 255}, // warmes Orange-Rot
	accent_soft       = {242, 88, 47, 36},

	online            = {16, 185, 129, 255}, // emerald-500
	red               = {225, 55, 55, 255},
	red_hover         = {185, 40, 40, 255},
	red_soft          = {254, 242, 242, 255}, // red-50
	badge             = {240, 71, 47, 255},   // Logo-Rot
	yellow            = {234, 179, 8, 255},

	code_bg           = {244, 244, 245, 255}, // zinc-100
	code_text         = {63, 63, 70, 255},    // zinc-700

	// Heller Code-Block: getönte Fläche + Rahmen, damit er sich vom
	// weißen Chat abhebt, ohne ein dunkler Fremdkörper zu sein.
	code_block_bg     = {244, 244, 245, 255}, // zinc-100
	code_block_border = {228, 228, 231, 255}, // zinc-200
	code_block_head   = {24, 24, 27, 20},
	syn_text          = {39, 39, 42, 255},   // zinc-800
	syn_keyword       = {124, 58, 237, 255}, // violet-600
	syn_type          = {8, 145, 178, 255},  // cyan-600
	syn_string        = {21, 128, 61, 255},  // green-700
	syn_number        = {194, 65, 12, 255},  // orange-700
	syn_comment       = {113, 113, 122, 255}, // zinc-500 — hell genug zum Zurücktreten,
	                                          // dunkel genug zum Lesen (~3.9:1 auf zinc-100)

	overlay           = {24, 24, 27, 255},
	press             = {0, 0, 0, 255},
	scrim             = {9, 9, 11, 115},
	shadow            = {24, 24, 27, 24},

	tooltip_bg        = {24, 24, 27, 240},
	tooltip_fg        = {255, 255, 255, 255},
	toast_bg          = {24, 24, 27, 245},
	toast_fg          = {255, 255, 255, 255},

	scroll_thumb      = {150, 150, 150, 140},
	scroll_thumb_hot  = {120, 120, 120, 200},
	send_idle         = {225, 225, 225, 255},
}

PAL_DARK :: Palette {
	// Hierarchie wie im Hellen, nur gespiegelt: die Lesefläche ist der
	// Extremwert (am dunkelsten), das Chrome liegt zur Mitte hin.
	chat_bg           = {9, 9, 11, 255}, // zinc-950
	panel_bg          = {9, 9, 11, 255},
	rail_bg           = {20, 20, 23, 255},
	rail_item         = {39, 39, 42, 255}, // zinc-800
	sidebar_bg        = {15, 15, 17, 255},
	surface           = {24, 24, 27, 255}, // zinc-900 — hebt sich vom Grund ab
	surface_hover     = {39, 39, 42, 255}, // zinc-800

	text              = {250, 250, 250, 255}, // zinc-50
	text_dim          = {161, 161, 170, 255}, // zinc-400
	text_faint        = {113, 113, 122, 255}, // zinc-500
	sidebar_text      = {212, 212, 216, 255}, // zinc-300
	sidebar_dim       = {113, 113, 122, 255}, // zinc-500

	border            = {39, 39, 42, 255}, // zinc-800
	border_soft       = {30, 30, 34, 255},
	sidebar_line      = {34, 34, 38, 255},
	sidebar_hover     = {255, 255, 255, 14},
	hover_row         = {255, 255, 255, 10},

	primary           = {250, 250, 250, 255}, // zinc-50 (shadcn-Dark-Primary)
	primary_hover     = {228, 228, 231, 255}, // zinc-200
	primary_fg        = {24, 24, 27, 255},

	accent            = {245, 101, 60, 255}, // eine Spur heller → trägt auf Schwarz
	accent_soft       = {245, 101, 60, 52},

	online            = {52, 211, 153, 255}, // emerald-400
	red               = {237, 75, 75, 255},
	red_hover         = {248, 113, 113, 255}, // red-400
	red_soft          = {45, 22, 24, 255},
	badge             = {240, 71, 47, 255},
	yellow            = {250, 204, 21, 255},

	code_bg           = {39, 39, 42, 255},    // zinc-800
	code_text         = {228, 228, 231, 255}, // zinc-200

	code_block_bg     = {24, 24, 27, 255}, // zinc-900
	code_block_border = {39, 39, 42, 255},
	code_block_head   = {255, 255, 255, 16},
	syn_text          = {228, 228, 231, 255}, // zinc-200
	syn_keyword       = {192, 132, 252, 255}, // violet-400
	syn_type          = {103, 232, 249, 255}, // cyan-300
	syn_string        = {134, 239, 172, 255}, // green-300
	syn_number        = {253, 186, 116, 255}, // orange-300
	syn_comment       = {113, 113, 122, 255}, // zinc-500

	overlay           = {255, 255, 255, 255},
	press             = {255, 255, 255, 255},
	scrim             = {0, 0, 0, 165},
	shadow            = {0, 0, 0, 56},

	tooltip_bg        = {244, 244, 245, 245}, // invertiert, wie im Hellen
	tooltip_fg        = {24, 24, 27, 255},
	toast_bg          = {39, 39, 42, 250}, // zinc-800
	toast_fg          = {250, 250, 250, 255},

	scroll_thumb      = {160, 160, 175, 110},
	scroll_thumb_hot  = {190, 190, 205, 190},
	send_idle         = {63, 63, 70, 255}, // zinc-700
}

// --- Aktive Farben (von theme_apply pro Frame geschrieben) ---

COL_CHAT_BG: rl.Color
COL_PANEL_BG: rl.Color
COL_RAIL_BG: rl.Color
COL_RAIL_ITEM: rl.Color
COL_SIDEBAR_BG: rl.Color
COL_SURFACE: rl.Color
COL_SURFACE_HOVER: rl.Color

COL_TEXT: rl.Color
COL_TEXT_DIM: rl.Color
COL_TEXT_FAINT: rl.Color
COL_SIDEBAR_TEXT: rl.Color
COL_SIDEBAR_DIM: rl.Color

COL_BORDER: rl.Color
COL_BORDER_SOFT: rl.Color
COL_SIDEBAR_LINE: rl.Color
COL_SIDEBAR_HOVER: rl.Color
COL_HOVER_ROW: rl.Color

COL_PRIMARY: rl.Color
COL_PRIMARY_HOVER: rl.Color
COL_PRIMARY_FG: rl.Color

COL_ACCENT: rl.Color
COL_ACCENT_SOFT: rl.Color

COL_ONLINE: rl.Color
COL_RED: rl.Color
COL_RED_HOVER: rl.Color
COL_RED_SOFT: rl.Color
COL_BADGE: rl.Color
COL_YELLOW: rl.Color

CODE_BG: rl.Color
CODE_TEXT: rl.Color
CODE_BLOCK_BG: rl.Color
CODE_BLOCK_BORDER: rl.Color
CODE_BLOCK_HEAD: rl.Color
SYN_TEXT: rl.Color
SYN_KEYWORD: rl.Color
SYN_TYPE: rl.Color
SYN_STRING: rl.Color
SYN_NUMBER: rl.Color
SYN_COMMENT: rl.Color

COL_OVERLAY: rl.Color
COL_PRESS: rl.Color
COL_SCRIM: rl.Color
COL_SHADOW: rl.Color

COL_TOOLTIP_BG: rl.Color
COL_TOOLTIP_FG: rl.Color
COL_TOAST_BG: rl.Color
COL_TOAST_FG: rl.Color

COL_SCROLL_THUMB: rl.Color
COL_SCROLL_THUMB_HOT: rl.Color
COL_SEND_IDLE: rl.Color

// --- Theme-unabhängige Konstanten ---

// Reines Weiß: Text/Icons auf gesättigten Flächen (Avatare, Badges, Logo) —
// das bleibt in beiden Themes weiß. Für Kartenflächen COL_SURFACE nehmen!
COL_WHITE :: rl.Color{255, 255, 255, 255}

// Marken-Verlauf aus dem Logotype
LOGO_PINK :: rl.Color{238, 42, 155, 255}   // #ee2a9b
LOGO_ORANGE :: rl.Color{247, 109, 60, 255} // #f76d3c
LOGO_AMBER :: rl.Color{255, 180, 63, 255}  // #ffb43f

RADIUS_CARD :: f32(10)
RADIUS_INPUT :: f32(8)
RADIUS_BTN :: f32(8)

// --- Theme anwenden ---

@(private = "file")
PAL_N :: size_of(Palette) / size_of(rl.Color)
#assert(size_of(Palette) == PAL_N * size_of(rl.Color)) // nur rl.Color-Felder → kein Padding

// Zwei Paletten mischen (t: 0 = a, 1 = b). Nutzt aus, dass Palette
// speicherlayout-gleich zu einem rl.Color-Array ist.
@(private = "file")
pal_mix :: proc(a, b: Palette, t: f32) -> Palette {
	if t <= 0 {
		return a
	}
	if t >= 1 {
		return b
	}
	aa := transmute([PAL_N]rl.Color)a
	bb := transmute([PAL_N]rl.Color)b
	out: [PAL_N]rl.Color
	for i in 0 ..< PAL_N {
		out[i] = mix(aa[i], bb[i], t)
	}
	return transmute(Palette)out
}

// Aktive Farben setzen. k: 0 = hell, 1 = dunkel; Zwischenwerte während
// der Überblendung. Muss vor dem Zeichnen (und vor ClearBackground) laufen.
theme_apply :: proc(k: f32) {
	p := pal_mix(PAL_LIGHT, PAL_DARK, clamp(k, 0, 1))

	COL_CHAT_BG = p.chat_bg
	COL_PANEL_BG = p.panel_bg
	COL_RAIL_BG = p.rail_bg
	COL_RAIL_ITEM = p.rail_item
	COL_SIDEBAR_BG = p.sidebar_bg
	COL_SURFACE = p.surface
	COL_SURFACE_HOVER = p.surface_hover

	COL_TEXT = p.text
	COL_TEXT_DIM = p.text_dim
	COL_TEXT_FAINT = p.text_faint
	COL_SIDEBAR_TEXT = p.sidebar_text
	COL_SIDEBAR_DIM = p.sidebar_dim

	COL_BORDER = p.border
	COL_BORDER_SOFT = p.border_soft
	COL_SIDEBAR_LINE = p.sidebar_line
	COL_SIDEBAR_HOVER = p.sidebar_hover
	COL_HOVER_ROW = p.hover_row

	COL_PRIMARY = p.primary
	COL_PRIMARY_HOVER = p.primary_hover
	COL_PRIMARY_FG = p.primary_fg

	COL_ACCENT = p.accent
	COL_ACCENT_SOFT = p.accent_soft

	COL_ONLINE = p.online
	COL_RED = p.red
	COL_RED_HOVER = p.red_hover
	COL_RED_SOFT = p.red_soft
	COL_BADGE = p.badge
	COL_YELLOW = p.yellow

	CODE_BG = p.code_bg
	CODE_TEXT = p.code_text
	CODE_BLOCK_BG = p.code_block_bg
	CODE_BLOCK_BORDER = p.code_block_border
	CODE_BLOCK_HEAD = p.code_block_head
	SYN_TEXT = p.syn_text
	SYN_KEYWORD = p.syn_keyword
	SYN_TYPE = p.syn_type
	SYN_STRING = p.syn_string
	SYN_NUMBER = p.syn_number
	SYN_COMMENT = p.syn_comment

	COL_OVERLAY = p.overlay
	COL_PRESS = p.press
	COL_SCRIM = p.scrim
	COL_SHADOW = p.shadow

	COL_TOOLTIP_BG = p.tooltip_bg
	COL_TOOLTIP_FG = p.tooltip_fg
	COL_TOAST_BG = p.toast_bg
	COL_TOAST_FG = p.toast_fg

	COL_SCROLL_THUMB = p.scroll_thumb
	COL_SCROLL_THUMB_HOT = p.scroll_thumb_hot
	COL_SEND_IDLE = p.send_idle
}

// --- Zeichen-Helfer ---

// Rundung als raylib-"roundness" (0..1) für ein Rechteck umrechnen.
roundness :: proc(r: rl.Rectangle, radius: f32) -> f32 {
	m := min(r.width, r.height)
	if m <= 0 {
		return 0
	}
	return clamp(radius * 2 / m, 0, 1)
}

// Gefülltes Rounded-Rect mit Pixel-Radius statt roundness.
rrect :: proc(r: rl.Rectangle, radius: f32, col: rl.Color) {
	rl.DrawRectangleRounded(r, roundness(r, radius), 8, col)
}

rrect_lines :: proc(r: rl.Rectangle, radius: f32, thick: f32, col: rl.Color) {
	rl.DrawRectangleRoundedLinesEx(r, roundness(r, radius), 8, thick, col)
}

// Rounded-Rect mit horizontalem Farbverlauf (für das Marken-Logo).
// Trick: Gradient-Rechteck zeichnen, dann die vier Ecken mit der
// Hintergrundfarbe maskieren und als Viertelkreise neu füllen.
rrect_gradient_h :: proc(r: rl.Rectangle, radius: f32, c0, c1: rl.Color, bg: rl.Color) {
	rl.DrawRectangleGradientEx(r, c0, c0, c1, c1)
	rad := min(radius, min(r.width, r.height)/2)
	corners := [4]struct {
		px, py: f32, // Eck-Quadrat (oben links)
		cx, cy: f32, // Kreiszentrum
		a0, a1: f32, // Sektor-Winkel
		col:    rl.Color,
	}{
		{r.x, r.y, r.x + rad, r.y + rad, 180, 270, c0},
		{r.x + r.width - rad, r.y, r.x + r.width - rad, r.y + rad, 270, 360, c1},
		{r.x, r.y + r.height - rad, r.x + rad, r.y + r.height - rad, 90, 180, c0},
		{r.x + r.width - rad, r.y + r.height - rad, r.x + r.width - rad, r.y + r.height - rad, 0, 90, c1},
	}
	for c in corners {
		rl.DrawRectangleRec({c.px, c.py, rad, rad}, bg)
		rl.DrawCircleSector({c.cx, c.cy}, rad, c.a0, c.a1, 16, c.col)
	}
}

// Weicher Schatten: mehrere wachsende, transparente Schichten.
// Die Basisstärke steckt im Alpha von COL_SHADOW (dunkle Themes brauchen
// mehr, damit der Schatten auf schwarzem Grund überhaupt trägt).
draw_shadow :: proc(r: rl.Rectangle, radius: f32, strength: f32 = 1) {
	layers := 6
	for i in 1 ..= layers {
		f := f32(i)
		col := COL_SHADOW
		col.a = u8(clamp(f32(COL_SHADOW.a) * strength * (1 - f/f32(layers+1)) / f, 0, 255))
		grow := f * 2.2
		sr := rl.Rectangle{r.x - grow, r.y - grow + f*0.9, r.width + grow*2, r.height + grow*2}
		rrect(sr, radius + grow, col)
	}
}

// DrawTextEx mit auf ganze PHYSISCHE Pixel gerundeter Position. Subpixel-
// Positionen werden vom Bilinear-Filter der Font-Textur verwischt — beim
// UI-Zoom zählt das physische Raster (logisch × g_scale).
draw_text :: proc(font: rl.Font, text: cstring, pos: rl.Vector2, size, spacing: f32, tint: rl.Color) {
	p := rl.Vector2{
		math.round(pos.x * g_scale) / g_scale,
		math.round(pos.y * g_scale) / g_scale,
	}
	rl.DrawTextEx(font, text, p, size, spacing, tint)
}

// Aktueller Scissor-Bereich in logischen Koordinaten. ui_hover zieht ihn
// mit heran: was weggeschnitten ist, darf auch nicht anklickbar sein —
// sonst reagiert z. B. eine halb weggescrollte Zeile durch die Kopfzeile
// hindurch. raylib-Scissor verschachtelt nicht — deshalb führt der Stack
// hier Buch: ein inneres scissor_begin schneidet mit dem äußeren Bereich,
// und scissor_end spannt den äußeren wieder auf (der Inline-Editor liegt
// z. B. im Scissor der Nachrichtenliste).
g_clip: rl.Rectangle
g_clip_on: bool

// Vertikaler Versatz der gesamten UI in logischen Pixeln (Call-Leiste am
// oberen Rand, main.odin setzt ihn pro Frame). raylib-Scissor arbeitet in
// physischen Fenster-Koordinaten und muss ihn mitrechnen — die Camera2D
// verschiebt nur das Zeichnen, nicht den Scissor.
g_off_y := f32(0)

@(private = "file")
Clip_Frame :: struct {
	rect: rl.Rectangle,
	on:   bool,
}

@(private = "file")
g_clip_stack: [8]Clip_Frame

@(private = "file")
g_clip_depth: int

@(private = "file")
rect_intersect :: proc(a, b: rl.Rectangle) -> rl.Rectangle {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.width, b.x + b.width)
	y1 := min(a.y + a.height, b.y + b.height)
	return {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

@(private = "file")
apply_scissor :: proc(r: rl.Rectangle) {
	if r.width <= 0 || r.height <= 0 {
		rl.BeginScissorMode(0, 0, 0, 0) // leerer Schnitt → nichts zeichnen
		return
	}
	rl.BeginScissorMode(
		i32(r.x * g_scale), i32((r.y + g_off_y) * g_scale),
		i32(r.width * g_scale) + 1, i32(r.height * g_scale) + 1,
	)
}

// Scissor in logischen Koordinaten (rechnet den UI-Zoom ein — raylib-
// Scissor arbeitet in physischen Fenster-Pixeln).
scissor_begin :: proc(x, y, w, h: f32) {
	assert(g_clip_depth < len(g_clip_stack))
	g_clip_stack[g_clip_depth] = {g_clip, g_clip_on}
	g_clip_depth += 1

	r := rl.Rectangle{x, y, w, h}
	if g_clip_on {
		r = rect_intersect(r, g_clip)
	}
	g_clip = r
	g_clip_on = true
	apply_scissor(r)
}

scissor_end :: proc() {
	assert(g_clip_depth > 0)
	g_clip_depth -= 1
	prev := g_clip_stack[g_clip_depth]
	g_clip = prev.rect
	g_clip_on = prev.on
	if prev.on {
		apply_scissor(prev.rect)
	} else {
		rl.EndScissorMode()
	}
}

// Farbe mit Alpha multiplizieren.
fade :: proc(c: rl.Color, alpha: f32) -> rl.Color {
	out := c
	out.a = u8(clamp(f32(c.a) * alpha, 0, 255))
	return out
}

// Linear zwischen zwei Farben mischen.
mix :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	t := clamp(t, 0, 1)
	return rl.Color{
		u8(f32(a.r) + (f32(b.r) - f32(a.r)) * t),
		u8(f32(a.g) + (f32(b.g) - f32(a.g)) * t),
		u8(f32(a.b) + (f32(b.b) - f32(a.b)) * t),
		u8(f32(a.a) + (f32(b.a) - f32(a.a)) * t),
	}
}
