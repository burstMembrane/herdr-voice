#!/bin/bash
# Builds ~/.local/share/herdr-voice/AppleSTT.app, signed with your Apple Development identity so its permissions persist.
set -e
cd "$(dirname "$0")"; A="$HOME/.local/share/herdr-voice/AppleSTT.app"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS"
cat > "$A/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.herdrvoice.applestt</string>
<key>CFBundleName</key><string>AppleSTT</string>
<key>CFBundleExecutable</key><string>AppleSTT</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSSpeechRecognitionUsageDescription</key><string>Turns what you say into text for your voice line to the product manager.</string>
<key>NSMicrophoneUsageDescription</key><string>Listens for your voice.</string>
</dict></plist>
PL
swiftc -O main.swift -o "$A/Contents/MacOS/AppleSTT"
ID=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$A"; echo "built $A"
