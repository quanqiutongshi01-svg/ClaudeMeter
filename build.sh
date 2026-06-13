#!/bin/bash
# Build ClaudeMeter.app from a single Swift source file using swiftc.
# Requires: Xcode Command Line Tools (xcode-select --install), macOS 14+.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/ClaudeMeter.app"
BIN_NAME="ClaudeMeter"
BUNDLE_ID="com.claudemeter.ClaudeMeter"
VERSION="1.0.0"

echo "==> Cleaning old bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "==> Writing Info.plist (LSUIElement = menu-bar agent, no Dock icon)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeMeter</string>
    <key>CFBundleDisplayName</key>     <string>ClaudeMeter</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key>      <string>${BIN_NAME}</string>
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
    -framework AppKit

echo "==> Ad-hoc code signing"
codesign --force --sign - "$APP" 2>/dev/null || echo "(signing skipped)"

echo "==> Done: $APP"
echo "    Drag it to /Applications, or run: open \"$APP\""
