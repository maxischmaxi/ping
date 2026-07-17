#!/usr/bin/env bash
# Builds Flurfunk.app from the client binary (signing happens in CI).
# Usage: make_app.sh <client-binary> <version> <outdir>
set -euo pipefail

BIN="$1"; VERSION="$2"; OUT="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$OUT/Flurfunk.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed "s/@VERSION@/$VERSION/g" "$HERE/Info.plist" > "$APP/Contents/Info.plist"
cp "$HERE/flurfunk.icns" "$APP/Contents/Resources/flurfunk.icns"
cp "$BIN" "$APP/Contents/MacOS/flurfunk"
chmod 755 "$APP/Contents/MacOS/flurfunk"
echo "ok: $APP"
