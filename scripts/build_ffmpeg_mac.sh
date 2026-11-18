#!/bin/bash
# Builds self-contained, LGPL-licensed universal (arm64 + x86_64) ffmpeg/ffprobe
# into vendor/ for bundling inside EasyMovTrim.app.
#
#   scripts/build_ffmpeg_mac.sh            # uses FFMPEG_VERSION (default below)
#
# Only macOS system frameworks are linked (VideoToolbox, AudioToolbox, zlib, bzip2, iconv),
# so the binaries run on any Mac (macOS 11+). No GPL / nonfree components are enabled.
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG_VERSION=${FFMPEG_VERSION:-8.0.1}
WORK=vendor/ffmpeg-build
SRC_TAR=$WORK/download/ffmpeg-$FFMPEG_VERSION.tar.xz
JOBS=$(sysctl -n hw.ncpu)

mkdir -p "$WORK/download"
if [[ ! -f "$SRC_TAR" ]]; then
    curl -fL --proto '=https' -o "$SRC_TAR" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
fi

COMMON=(
    --disable-autodetect
    --enable-videotoolbox --enable-audiotoolbox
    --enable-zlib --enable-bzlib --enable-iconv
    --disable-gpl --disable-nonfree
    --disable-doc --disable-ffplay --disable-network --disable-debug
    --enable-static --disable-shared
    --target-os=darwin
)

for ARCH in arm64 x86_64; do
    if [[ -x "$WORK/out-$ARCH/bin/ffmpeg" ]]; then
        echo "== $ARCH already built"
        continue
    fi
    echo "== building ffmpeg $FFMPEG_VERSION for $ARCH"
    rm -rf "$WORK/src-$ARCH"
    mkdir -p "$WORK/src-$ARCH"
    tar -xf "$SRC_TAR" -C "$WORK/src-$ARCH" --strip-components=1
    EXTRA=()
    if [[ "$ARCH" == "x86_64" ]]; then
        # nasm is optional; without it x86 SIMD is disabled (slower but fully functional).
        command -v nasm >/dev/null || EXTRA+=(--disable-x86asm)
    fi
    if [[ "$ARCH" != "$(uname -m)" ]]; then
        EXTRA+=(--enable-cross-compile)
    fi
    (
        cd "$WORK/src-$ARCH"
        ./configure --prefix="$PWD/../out-$ARCH" --arch="$ARCH" \
            --cc="clang -arch $ARCH" \
            --extra-cflags="-mmacosx-version-min=11.0" \
            --extra-ldflags="-mmacosx-version-min=11.0" --extra-libs="-liconv" \
            "${COMMON[@]}" ${EXTRA[@]+"${EXTRA[@]}"} >configure.log
        make -j"$JOBS" >make.log 2>&1
        make install >/dev/null
    )
done

for tool in ffmpeg ffprobe; do
    lipo -create "$WORK/out-arm64/bin/$tool" "$WORK/out-x86_64/bin/$tool" -output "vendor/$tool"
    chmod +x "vendor/$tool"
done
echo "== done"
lipo -info vendor/ffmpeg vendor/ffprobe
otool -L vendor/ffmpeg | grep -v ':$'
