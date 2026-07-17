package avatartest

// Headless-Test der Profilbild-Pipeline: beweist, dass die gelinkte raylib
// PNG-Export kann (Bake-Format des Clients) und dass die Crop→Resize→
// Export→Dekodier-Kette funktioniert — reine CPU-Image-APIs, kein Fenster.

import "core:fmt"
import "core:os"

import rl "vendor:raylib"
import shared "../../src/shared"

fail :: proc(step: string, args: ..any) {
	fmt.eprintf("FEHLGESCHLAGEN: %s ", step)
	fmt.eprintln(..args)
	os.exit(1)
}

main :: proc() {
	// 1) Foto-artige Quelle erzeugen und als PNG exportieren
	src := rl.GenImageGradientLinear(800, 600, 45, {200, 60, 40, 255}, {30, 40, 200, 255})
	size: i32
	raw := rl.ExportImageToMemory(src, ".png", &size)
	if raw == nil || size <= 0 {
		fail("png-export", "raylib ohne PNG-Export gebaut?")
	}
	png := ([^]u8)(raw)[:int(size)]
	w, h, ok := shared.png_dims(png)
	if !ok || w != 800 || h != 600 {
		fail("png_dims", "w =", w, "h =", h, "ok =", ok)
	}
	fmt.println("ok: png-export + ihdr-sniffing")

	// 2) Crop + Resize wie der Client (Kreis-Ausschnitt → AVATAR_BAKE_DIM²)
	sub := rl.ImageFromImage(src, {100, 50, 500, 500})
	rl.ImageResize(&sub, shared.AVATAR_BAKE_DIM, shared.AVATAR_BAKE_DIM)
	s2: i32
	raw2 := rl.ExportImageToMemory(sub, ".png", &s2)
	if raw2 == nil || s2 <= 0 {
		fail("bake-export")
	}
	baked := ([^]u8)(raw2)[:int(s2)]
	bw, bh, bok := shared.png_dims(baked)
	if !bok || bw != shared.AVATAR_BAKE_DIM || bh != shared.AVATAR_BAKE_DIM {
		fail("bake-maße", "w =", bw, "h =", bh)
	}
	if int(s2) > shared.AVATAR_MAX_BYTES {
		fail("bake über dem server-limit", "bytes =", s2)
	}
	fmt.printfln("ok: crop+resize+export (%d Bytes, Limit %d)", s2, shared.AVATAR_MAX_BYTES)

	// 3) Dekodier-Roundtrip (Empfangspfad des Clients, ohne GPU-Upload)
	dec := rl.LoadImageFromMemory(".png", raw2, s2)
	if dec.data == nil || dec.width != shared.AVATAR_BAKE_DIM || dec.height != shared.AVATAR_BAKE_DIM {
		fail("png-dekodierung", "w =", dec.width, "h =", dec.height)
	}
	fmt.println("ok: png-dekodier-roundtrip")

	rl.MemFree(raw)
	rl.MemFree(raw2)
	rl.UnloadImage(src)
	rl.UnloadImage(sub)
	rl.UnloadImage(dec)

	fmt.println("\nAVATAR-PIPELINE-TEST BESTANDEN ✔")
}
