#!/bin/bash
# Build TokenMeter.app from a single Swift source file using swiftc.
# Requires: Xcode Command Line Tools (xcode-select --install), macOS 14+.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/TokenMeter.app"
BIN_NAME="TokenMeter"
BUNDLE_ID="com.tokenmeter.TokenMeter"
VERSION="2.0.6"
ICON_SRC="$DIR/assets/app-icon.png"
ICONSET="$DIR/build/AppIcon.iconset"
ICON_ICNS="$DIR/build/AppIcon.icns"

echo "==> Cleaning old bundle"
rm -rf "$APP" "$DIR/ClaudeMeter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIR/build"

if [[ -f "$ICON_SRC" ]]; then
    echo "==> Generating AppIcon.icns"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    make_icon() {
        local points="$1"
        local pixels="$2"
        local suffix="$3"
        sips -z "$pixels" "$pixels" "$ICON_SRC" --out "$ICONSET/icon_${points}x${points}${suffix}.png" >/dev/null
    }
    make_icon 16 16 ""
    make_icon 16 32 "@2x"
    make_icon 32 32 ""
    make_icon 32 64 "@2x"
    make_icon 128 128 ""
    make_icon 128 256 "@2x"
    make_icon 256 256 ""
    make_icon 256 512 "@2x"
    make_icon 512 512 ""
    make_icon 512 1024 "@2x"
    iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
    cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "==> No app icon source found; building without a custom icon"
fi

echo "==> Writing Info.plist (LSUIElement = menu-bar agent, no Dock icon)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>TokenMeter</string>
    <key>CFBundleDisplayName</key>     <string>TokenMeter</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key>      <string>${BIN_NAME}</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "==> Compiling (swiftc -O)"
swiftc -O \
    -target arm64-apple-macos14.0 \
    "$DIR/main.swift" \
    -o "$APP/Contents/MacOS/${BIN_NAME}" \
    -framework AppKit \
    -lsqlite3

echo "==> Ad-hoc code signing"
codesign --force --sign - "$APP" 2>/dev/null || echo "(signing skipped)"

echo "==> Done: $APP"
echo "    Drag it to /Applications, or run: open \"$APP\""
