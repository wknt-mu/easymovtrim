#!/bin/bash
# Creates dist/EasyMovTrim-<version>-mac.dmg (universal: Apple Silicon + Intel)
# with bundled LGPL ffmpeg. Run scripts/build_ffmpeg_mac.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in ffmpeg ffprobe; do
    if [[ ! -x vendor/$tool ]]; then
        echo "vendor/$tool がありません。先に scripts/build_ffmpeg_mac.sh を実行してください。" >&2
        exit 1
    fi
done

UNIVERSAL=1 ./build.sh

APP=build/EasyMovTrim.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=dist/EasyMovTrim-$VERSION-mac.dmg

echo "== architectures"
for bin in EasyMovTrim ffmpeg ffprobe; do
    lipo -info "$APP/Contents/MacOS/$bin"
done

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp packaging/mac/README_FIRST.txt "$STAGE/はじめにお読みください.txt"
cp THIRD_PARTY_NOTICES.md "$STAGE/THIRD_PARTY_NOTICES.md"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "EasyMovTrim $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
echo "== created $DMG ($(du -h "$DMG" | cut -f1))"
