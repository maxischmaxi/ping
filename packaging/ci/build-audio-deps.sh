#!/usr/bin/env bash
# Builds static audio libs into a prefix (used by the release CI).
# Usage: build-audio-deps.sh <prefix> <lib>...   (libs: rnnoise opus speexdsp)
set -euo pipefail

PREFIX="$1"; shift
JOBS="$(getconf _NPROCESSORS_ONLN)"
mkdir -p "$PREFIX/src"

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

for lib in "$@"; do
	cd "$PREFIX/src"
	case "$lib" in
	rnnoise)
		# No dist tarball for 0.2 — build from the git tag. Pre-fetch the
		# model with curl so autogen.sh skips its wget call (absent on macOS).
		fetch "https://github.com/xiph/rnnoise/archive/refs/tags/v0.2.tar.gz" rnnoise.tar.gz
		tar xf rnnoise.tar.gz && cd rnnoise-0.2
		model="rnnoise_data-$(cat model_version).tar.gz"
		fetch "https://media.xiph.org/rnnoise/models/$model" "$model"
		./autogen.sh
		;;
	opus)
		fetch "https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz" opus.tar.gz
		tar xf opus.tar.gz && cd opus-1.5.2
		;;
	speexdsp)
		fetch "https://downloads.xiph.org/releases/speex/speexdsp-1.2.1.tar.gz" speexdsp.tar.gz
		tar xf speexdsp.tar.gz && cd speexdsp-1.2.1
		;;
	*)
		echo "unknown lib: $lib" >&2; exit 1
		;;
	esac
	./configure --prefix="$PREFIX" --disable-shared --enable-static \
		--disable-examples --disable-doc --disable-extra-programs CFLAGS="-O2"
	make -j"$JOBS"
	make install
done

echo "done: $(ls "$PREFIX"/lib/*.a 2>/dev/null | tr '\n' ' ')"
