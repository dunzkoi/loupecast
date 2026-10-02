#!/bin/bash
# Builds dist/Loupecast.app (release build). Version comes from version.txt (maintained by release-please).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Loupecast
BIN="$(swift build -c release --show-bin-path)/Loupecast"
APP=dist/Loupecast.app
VERSION="$(cat version.txt 2>/dev/null || echo 0.0.0)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Loupecast"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # regenerate with: swift scripts/make-icon.swift
cp Resources/start.wav Resources/stop.wav "$APP/Contents/Resources/"   # python3 scripts/make-sounds.py
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.flowoodz.loupecast</string>
	<key>CFBundleName</key>
	<string>Loupecast</string>
	<key>CFBundleDisplayName</key>
	<string>Loupecast</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleExecutable</key>
	<string>Loupecast</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>마이크 소리를 녹음하려면 접근 권한이 필요합니다.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
# A stable local identity keeps the TCC (screen recording) grant across rebuilds; ad-hoc otherwise.
SIGN_ID="${LOUPECAST_SIGN_ID:-Loupe Local Dev}"
security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 || SIGN_ID=-
codesign --force --sign "$SIGN_ID" --identifier com.flowoodz.loupecast "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "built $APP"
