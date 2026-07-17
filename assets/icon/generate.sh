#!/usr/bin/env bash
# Renders all icon artifacts from the SVG sources (run after editing them).
# Needs: rsvg-convert, python3. Outputs are committed to the repo.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p png
for s in 16 32 48 64 128 256 512 1024; do
	rsvg-convert -w "$s" -h "$s" flurfunk.svg -o "png/flurfunk-$s.png"
done

tmp="$(mktemp -d)"
for s in 16 32 64 128 256 512 1024; do
	rsvg-convert -w "$s" -h "$s" flurfunk-macos.svg -o "$tmp/$s.png"
done
python3 make_icns.py "$tmp" ../../packaging/macos/flurfunk.icns
rm -rf "$tmp"
echo "done"
