#!/bin/zsh
# Builds dist/GridPilot.app from the SPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/GridPilot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/GridPilot "$APP/Contents/MacOS/gridpilot"

VERSION=$(grep 'appVersion = ' Sources/GridPilot/App/CLI.swift | sed 's/.*"\(.*\)".*/\1/')

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>gridpilot</string>
    <key>CFBundleIdentifier</key><string>io.gridpilot.app</string>
    <key>CFBundleName</key><string>GridPilot</string>
    <key>CFBundleDisplayName</key><string>GridPilot</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>GridPilot scripts Spotify and iTerm from your MIDI controller.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP"
