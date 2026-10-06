#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_TEMP=$(mktemp -d)
trap 'rm -rf "$TASK_TEMP"' EXIT
curl -fL --retry 2 https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz -o "$TASK_TEMP/source.tar.xz"
tar -xf "$TASK_TEMP/source.tar.xz" -C "$TASK_TEMP"
cd "$TASK_TEMP/ffmpeg-7.1.1"
./configure --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0 --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug --disable-x86asm --enable-ffmpeg --enable-protocol=file,pipe --enable-demuxer=mov,mpegts,aac,mp3,wav,matroska,concat --enable-muxer=mp4,ipod,matroska,mov --enable-parser=aac,h264,hevc,mpegaudio,opus --enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb --enable-decoder=aac --enable-encoder=aac
make -j8
cp ffmpeg "$TASK_ROOT/App/Resources/ffmpeg"
cp COPYING.LGPLv2.1 "$TASK_ROOT/App/Resources/FFmpeg-LICENSE.txt"
mkdir -p "$TASK_ROOT/ThirdParty"
cp "$TASK_TEMP/source.tar.xz" "$TASK_ROOT/ThirdParty/ffmpeg-7.1.1.tar.xz"
