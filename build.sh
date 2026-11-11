#!/bin/zsh
# SidecarPortrait.app 빌드 스크립트
set -euo pipefail
cd "$(dirname "$0")"

APP="build/SidecarPortrait.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -import-objc-header Sources/CGVirtualDisplayPrivate.h \
  -framework Cocoa -framework ScreenCaptureKit \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/SidecarPortrait"

cp Info.plist "$APP/Contents/Info.plist"

# 서명 ID를 인자로 주면 그것으로, 없으면 임시(ad-hoc) 서명
codesign --force --sign "${1:--}" "$APP"
echo "built: $APP"
