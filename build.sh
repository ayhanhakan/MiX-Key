#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=MiX-Key.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/MiX-Key" MiXKey.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.ayhanhakan.mixkey</string>
    <key>CFBundleName</key><string>MiX-Key</string>
    <key>CFBundleExecutable</key><string>MiX-Key</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ekran Kaydı izni imzaya bağlı; kalıcı imza yoksa her derlemeden sonra izin yeniden istenir
IMZA="${IMZA:-$(cat .imza 2>/dev/null || true)}"
codesign --force --sign "${IMZA:--}" "$APP"
"$APP/Contents/MacOS/MiX-Key" test
echo "Hazır: $PWD/$APP (imza: ${IMZA:-ad-hoc})"
