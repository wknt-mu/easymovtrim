#!/bin/bash
# Builds build/EasyMovTrim.app
#   ./build.sh               -> Apple Silicon (arm64)
#   UNIVERSAL=1 ./build.sh   -> Universal (arm64 + x86_64)
#
# To ship a fully standalone app (no Homebrew needed for MKV/WebM/AVI...),
# put statically linked `ffmpeg` and `ffprobe` binaries in vendor/ before building.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=EasyMovTrim
APP=build/$APP_NAME.app

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release/$APP_NAME
else
    swift build -c release
    BIN=.build/release/$APP_NAME
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon
if [[ ! -f build/AppIcon.icns ]]; then
    swift scripts/make_icon.swift build >/dev/null
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
    rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Optional bundled ffmpeg
for tool in ffmpeg ffprobe; do
    if [[ -x vendor/$tool ]]; then
        cp "vendor/$tool" "$APP/Contents/MacOS/$tool"
        codesign --force --sign - "$APP/Contents/MacOS/$tool"
        echo "bundled vendor/$tool"
    fi
done
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/" 2>/dev/null || true

# Ad-hoc signature (no Developer ID). Set SIGN_IDENTITY to sign with a real certificate.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "built: $APP"
