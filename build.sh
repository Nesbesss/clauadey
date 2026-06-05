#!/bin/bash
set -e

APP="Claudey.app"
BIN="Claudey"

# Signing identity. Override: SIGN_ID="Developer ID Application: ..." ./build.sh
# Falls back to ad-hoc ("-") if the identity is not found.
SIGN_ID="${SIGN_ID:-0F8E38081F2430E5962FED34123C13A88335007E}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "Signing identity not found, using ad-hoc."
    SIGN_ID="-"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Bundle animated icons (default + presets).
cp claude.gif  "$APP/Contents/Resources/claude.gif"
cp claude2.gif "$APP/Contents/Resources/claude2.gif"
cp claude3.gif "$APP/Contents/Resources/claude3.gif"

# Generate AppIcon.icns from the GIF first frame (Finder / DMG icon).
TMPICON="$(mktemp -d)"
sips -s format png claude.gif --out "$TMPICON/base.png" >/dev/null
mkdir -p "$TMPICON/icon.iconset"
for s in 16 32 64 128 256 512; do
    sips -z "$s" "$s" "$TMPICON/base.png" --out "$TMPICON/icon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$TMPICON/base.png" --out "$TMPICON/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMPICON/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMPICON"

# Build the Rust space binary (egui + egui_term) and bundle it.
echo "Building claudey-space (Rust)…"
( cd claudey-space && cargo build --release )
cp "claudey-space/target/release/claudey-space" "$APP/Contents/Resources/claudey-space"
chmod +x "$APP/Contents/Resources/claudey-space"
# Sign the nested binary first (hardened runtime) so the app can seal it.
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Resources/claudey-space"

# Compile the Swift menubar app via SwiftPM.
swift build -c release
cp ".build/release/$BIN" "$APP/Contents/MacOS/$BIN"

# Info.plist. LSUIElement = menubar-only, no Dock icon.
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Claudey</string>
    <key>CFBundleDisplayName</key>
    <string>Claudey</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.claudey</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>$BIN</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Claudey opens Terminal to run Claude Code.</string>
</dict>
</plist>
EOF

# Sign with hardened runtime + Apple Events entitlement (required to control Terminal
# under the hardened runtime). Stable identity keeps the Automation permission sticky.
codesign --force --options runtime \
    --entitlements claudey.entitlements \
    --sign "$SIGN_ID" "$APP"

codesign --verify --strict --verbose=1 "$APP" && echo "signature OK"

echo "Built $APP (signed: $SIGN_ID)"
echo "Run: open $APP"
