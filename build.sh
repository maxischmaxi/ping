#!/usr/bin/env bash
# Baut Server und Client nach bin/.
# Nutzung: ./build.sh [debug]
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
FLAGS="-o:speed"
if [[ "$MODE" == "debug" ]]; then
	FLAGS="-debug"
fi

# miniaudio (Odin-Vendor) einmalig kompilieren — das Voice-Audio des
# Clients linkt gegen vendor/miniaudio/lib/miniaudio.a.
MA_DIR="$(odin root)/vendor/miniaudio"
if [[ ! -f "$MA_DIR/lib/miniaudio.a" ]]; then
	echo "== miniaudio bauen (einmalig) =="
	make -C "$MA_DIR/src"
fi

mkdir -p bin
echo "== Server =="
odin build src/server -out:bin/flurfunk-server $FLAGS
echo "== Client =="
odin build src/client -out:bin/flurfunk $FLAGS
echo "Fertig: bin/flurfunk-server, bin/flurfunk"
