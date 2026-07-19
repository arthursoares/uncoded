#!/bin/bash
# Builds a distributable DMG: Uncoded.app + /Applications symlink.
# usage: scripts/make_dmg.sh <path/to/Uncoded.app> [output-dir]
set -euo pipefail

APP="$1"
OUT="${2:-dist}"

VERSION=$(defaults read "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")/Contents/Info" CFBundleShortVersionString)
mkdir -p "$OUT"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$OUT/Uncoded-$VERSION.dmg"
hdiutil create -volname "Uncoded" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "created $DMG"
