#!/bin/bash
set -e

# Build + sign, then package Claudey.app into a DMG in ~/Downloads.
./build.sh

APP="Claudey.app"
VOL="Claudey"
DMG="$HOME/Downloads/Claudey.dmg"

STAGE="$(mktemp -d)/$VOL"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# Drag-to-install convenience.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo "DMG built: $DMG"
