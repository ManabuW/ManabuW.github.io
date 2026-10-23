#!/bin/bash
# Android 用 FFmpeg（LGPL・詰め替え専用）をビルドし、app の jniLibs に libffmpeg.so として置く。
#
# - 中身を作り直さず入れ物だけを詰め替える用途（映像と音声の結合、HLS の mp4 化）に必要な部品だけを入れる。
#   デコーダー・エンコーダーは含めない（サイズ削減と特許面の配慮）。
# - GPL の部品は入れない。configure の結果が LGPL でなければ失敗する。
# - Google Play の 16KB ページ要件に合わせてリンクする。
#
# 使い方: ffmpeg/build-android.sh   （ANDROID_NDK_HOME 未設定なら SDK 内の NDK 28.2 を使う）
set -euo pipefail

FFMPEG_VERSION="9.0.2"
API_LEVEL=29
ABI="arm64-v8a"
TARGET="aarch64-linux-android"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/ffmpeg/work"
SRC_TARBALL="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
SRC_DIR="$WORK/ffmpeg-$FFMPEG_VERSION"
OUT_DIR="$WORK/out-$ABI"
DEST="$ROOT/app/src/main/jniLibs/$ABI/libffmpeg.so"

NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
[ -d "$TOOLCHAIN" ] || { echo "NDK が見つかりません: $NDK" >&2; exit 1; }

mkdir -p "$WORK"
if [ ! -f "$SRC_TARBALL" ]; then
  curl -fL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$SRC_TARBALL"
fi
# このソース（と本スクリプト）は GPL/LGPL の義務として、アプリの配布先に提供する（docs/release.md）
shasum -a 256 "$SRC_TARBALL"
rm -rf "$SRC_DIR" "$OUT_DIR"
tar -xf "$SRC_TARBALL" -C "$WORK"

cd "$SRC_DIR"
./configure \
  --prefix="$OUT_DIR" \
  --target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile \
  --cc="$TOOLCHAIN/bin/$TARGET$API_LEVEL-clang" \
  --cxx="$TOOLCHAIN/bin/$TARGET$API_LEVEL-clang++" \
  --nm="$TOOLCHAIN/bin/llvm-nm" --ar="$TOOLCHAIN/bin/llvm-ar" \
  --ranlib="$TOOLCHAIN/bin/llvm-ranlib" --strip="$TOOLCHAIN/bin/llvm-strip" \
  --sysroot="$TOOLCHAIN/sysroot" \
  --extra-ldflags="-Wl,-z,max-page-size=16384" \
  --enable-pic --enable-static --disable-shared \
  --disable-everything --disable-autodetect --disable-doc --disable-debug \
  --disable-ffplay --disable-ffprobe --enable-ffmpeg \
  --disable-avdevice --disable-swscale --disable-network \
  --enable-protocol=file,pipe \
  --enable-demuxer=mov,matroska,mpegts,aac,mp3,ogg,flv,h264,hevc \
  --enable-muxer=mp4,mov,ipod,matroska,webm \
  --enable-parser=h264,hevc,aac,aac_latm,mpegaudio,vp8,vp9,av1,opus,vorbis \
  --enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe \
  | tee "$WORK/configure.log"

# GPL の部品が入っていないことを確認する（入るとアプリ全体のソース公開義務が生じる）
grep -q "^License: LGPL version 2.1 or later" "$WORK/configure.log" || {
  echo "LGPL 以外のライセンスになっています。ビルドを中止します。" >&2; exit 1; }

make -j"$(sysctl -n hw.ncpu)"
make install

mkdir -p "$(dirname "$DEST")"
"$TOOLCHAIN/bin/llvm-strip" -o "$DEST" "$OUT_DIR/bin/ffmpeg"

# 16KB ページに合わせてリンクされているか確認する
"$TOOLCHAIN/bin/llvm-readelf" -lW "$DEST" | awk '/LOAD/ {print $NF}' | grep -qv "0x4000" && {
  echo "16KB 境界になっていない LOAD セグメントがあります" >&2; exit 1; } || true
ls -l "$DEST"
echo "完了: $DEST（FFmpeg $FFMPEG_VERSION, LGPL-2.1-or-later）"
