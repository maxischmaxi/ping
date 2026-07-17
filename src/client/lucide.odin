package main

// Lucide-Icon-Renderer. Die Icons liegen als geflattete Polylinien in der
// 24×24-Lucide-Box vor (lucide_gen.odin, erzeugt von assets/icons/
// generate.py). Gezeichnet wird mit DrawLineEx + einem Kreis an jedem
// Stützpunkt — das ergibt Lucides runde Kappen und Gelenke, bleibt bei
// jedem UI-Zoom scharf und lässt sich frei einfärben und drehen.

import "core:math"

import rl "vendor:raylib"

// size = Kantenlänge der 24er-Box in logischen Pixeln, zentriert auf cx/cy.
// thick 0 → Lucide-Standard (Stroke 2 bei 24 → size/12). rot in Grad.
draw_icon :: proc(icon: Icon, cx, cy, size: f32, color: rl.Color, thick: f32 = 0, rot: f32 = 0) {
	s := size / 24
	th := thick > 0 ? thick : max(size / 12, 1.2)
	cr, sr := f32(1), f32(0)
	if rot != 0 {
		a := math.to_radians(rot)
		cr = math.cos(a)
		sr = math.sin(a)
	}
	for poly in LUCIDE[icon] {
		prev: rl.Vector2
		for p, j in poly {
			x := (p[0] - 12) * s
			y := (p[1] - 12) * s
			v := rl.Vector2{cx + x*cr - y*sr, cy + x*sr + y*cr}
			if j > 0 {
				rl.DrawLineEx(prev, v, th, color)
			}
			rl.DrawCircleV(v, th/2, color)
			prev = v
		}
	}
}
