#!/bin/bash
# QR 스캐너 앱 빌드: ./build.sh  →  build/QR 스캐너.app
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
APP="build/QR 스캐너.app"
mkdir -p build

# 아이콘 (최초 1회)
if [ ! -f build/AppIcon.icns ]; then
  swiftc -O Tools/make_icon.swift -o build/make_icon
  build/make_icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target "${ARCH}-apple-macos14.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/QRScanner"

cp Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "✅ 빌드 완료: $APP"
