package audio

// Minimale Bindings für die drei System-Bibliotheken der Voice-Pipeline:
//   libopus     — Sprach-Codec (48 kHz, VBR, in-band FEC, PLC, DTX)
//   librnnoise  — ML-Rauschunterdrückung (Xiph, 480-Sample-Frames @ 48 kHz)
//   libspeexdsp — Acoustic Echo Cancellation (MDF)
// Nur die tatsächlich genutzten Funktionen sind gebunden.

import "core:c"

// ---------- libopus ----------

foreign import opus_lib "system:opus"

Opus_Encoder :: struct {}
Opus_Decoder :: struct {}

OPUS_APPLICATION_VOIP :: 2048
OPUS_SIGNAL_VOICE :: 3001
OPUS_BANDWIDTH_FULLBAND :: 1105

OPUS_SET_BITRATE :: 4002
OPUS_SET_VBR :: 4006
OPUS_SET_BANDWIDTH :: 4008
OPUS_SET_COMPLEXITY :: 4010
OPUS_SET_INBAND_FEC :: 4012
OPUS_SET_PACKET_LOSS_PERC :: 4014
OPUS_SET_DTX :: 4016
OPUS_SET_SIGNAL :: 4024

@(default_calling_convention = "c")
foreign opus_lib {
	opus_encoder_create :: proc(fs: c.int32_t, channels: c.int, application: c.int, error: ^c.int) -> ^Opus_Encoder ---
	opus_encode_float :: proc(st: ^Opus_Encoder, pcm: [^]f32, frame_size: c.int, data: [^]byte, max_bytes: c.int32_t) -> c.int32_t ---
	opus_encoder_ctl :: proc(st: ^Opus_Encoder, request: c.int, #c_vararg args: ..any) -> c.int ---
	opus_encoder_destroy :: proc(st: ^Opus_Encoder) ---

	opus_decoder_create :: proc(fs: c.int32_t, channels: c.int, error: ^c.int) -> ^Opus_Decoder ---
	opus_decode_float :: proc(st: ^Opus_Decoder, data: [^]byte, len: c.int32_t, pcm: [^]f32, frame_size: c.int, decode_fec: c.int) -> c.int ---
	opus_decoder_destroy :: proc(st: ^Opus_Decoder) ---
}

// ---------- librnnoise ----------

foreign import rnnoise_lib "system:rnnoise"

Denoise_State :: struct {}

@(default_calling_convention = "c")
foreign rnnoise_lib {
	rnnoise_get_frame_size :: proc() -> c.int ---
	rnnoise_create :: proc(model: rawptr) -> ^Denoise_State ---
	// Erwartet/liefert Samples in 16-Bit-Skala (±32768) als f32.
	// Rückgabe: Sprach-Wahrscheinlichkeit 0..1 (VAD).
	rnnoise_process_frame :: proc(st: ^Denoise_State, out: [^]f32, input: [^]f32) -> f32 ---
	rnnoise_destroy :: proc(st: ^Denoise_State) ---
}

// ---------- libspeexdsp (nur AEC) ----------

foreign import speexdsp_lib "system:speexdsp"

Speex_Echo_State :: struct {}

SPEEX_ECHO_SET_SAMPLING_RATE :: 24

@(default_calling_convention = "c")
foreign speexdsp_lib {
	speex_echo_state_init :: proc(frame_size: c.int, filter_length: c.int) -> ^Speex_Echo_State ---
	// Direkte API: Mikrofon-Frame + zeitlich passender Playback-Frame rein,
	// echofreier Frame raus. Die Ausrichtung der Referenz machen wir selbst
	// (dsp.odin) — die gepufferte API (speex_echo_playback/capture) verträgt
	// keine burstweise Fütterung und spammt sonst xrun-Warnungen.
	speex_echo_cancellation :: proc(st: ^Speex_Echo_State, rec: [^]i16, play: [^]i16, out: [^]i16) ---
	speex_echo_state_reset :: proc(st: ^Speex_Echo_State) ---
	speex_echo_state_destroy :: proc(st: ^Speex_Echo_State) ---
	speex_echo_ctl :: proc(st: ^Speex_Echo_State, request: c.int, ptr: rawptr) -> c.int ---
}
