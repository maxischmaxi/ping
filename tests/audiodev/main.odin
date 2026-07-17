package audiodev

// Headless-Gerätecheck: startet die Voice-Engine wie im Call (Duplex-Gerät
// + Worker) für ein paar Sekunden — reproduziert Backend-Warnungen ohne GUI.

import "core:fmt"
import "core:time"

import audio "../../src/audio"

on_pkt :: proc(user: rawptr, payload: []byte) {}

main :: proc() {
	e: audio.Engine
	if !audio.engine_start(&e, on_pkt, nil, {}) {
		fmt.println("engine_start fehlgeschlagen")
		return
	}
	fmt.println("backend:", e.dev.pContext.backend)
	fmt.println("periodSizeInFrames:", e.dev.playback.internalPeriodSizeInFrames,
		"rate:", e.dev.playback.internalSampleRate)
	time.sleep(2 * time.Second)

	// Loopback-Pfad (Mikrofontest) mehrfach schalten — prüft den
	// Nebenläufigkeits-Pfad Worker (push) ↔ Main (set_loopback).
	for _ in 0 ..< 3 {
		audio.engine_set_loopback(&e, true)
		time.sleep(800 * time.Millisecond)
		audio.engine_set_loopback(&e, false)
		time.sleep(200 * time.Millisecond)
	}
	fmt.println("loopback-toggles ok, level:", e.mic_level)

	audio.engine_stop(&e)
	fmt.println("fertig")
}
