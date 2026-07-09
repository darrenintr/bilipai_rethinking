#!/usr/bin/env bash
# build-ffmpeg.sh — Build FFmpeg as a static library for iOS arm64.
#
# Used by the iOS Unsigned IPA GitHub Actions workflow to produce a
# minimal FFmpeg static archive that the Paladala target links in.
# This script MUST run on macOS (it shells out to xcrun for the
# iPhoneOS SDK and uses Xcode's clang for cross-compilation).
#
# What we enable (minimal set for B 站 playback):
#   - Protocols: file, http, https, tcp, tls   (for B 站 CDN + Referer)
#   - Demuxers:  mov, mp4, m4v, hls, flv       (covers MP4 + HLS + FLV)
#   - Decoders:  h264, hevc, aac, mp3float      (system VideoToolbox does
#                                                the actual H.264/HEVC
#                                                hardware decode — these
#                                                are the SW fallbacks)
#   - Parsers:   h264, hevc, aac
#
# What we deliberately DISABLE (smaller binary, fewer attack surfaces):
#   - libavfilter   (no on-device filters)
#   - libavdevice   (no device input)
#   - libpostproc   (no postprocessing)
#   - encoders      (we don't record / re-encode)
#   - network muxers (we only consume streams, never push)
#   - GPL codecs    (LGPL-only build to keep the binary redistributable
#                    without forcing Paladala to GPL)
#
# Output (consumed by the CI workflow via $RUNNER_TEMP/ffmpeg-build):
#   arm64/
#     include/libavformat/avformat.h, libavcodec/avcodec.h, ...
#     lib/libavformat.a, libavcodec.a, libavutil.a, libswresample.a
#
# Expected CI cache key:  ffmpeg-${FFMPEG_VERSION}-${PLATFORM_MIN_VERSION}-arm64

set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.1}"
PLATFORM_MIN_VERSION="${PLATFORM_MIN_VERSION:-18.0}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/build/ffmpeg-build}"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "::error::build-ffmpeg.sh must run on macOS (requires xcrun + iPhoneOS SDK)" >&2
  exit 1
fi

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --find clang)"

echo "FFmpeg build configuration:"
echo "  version:       ${FFMPEG_VERSION}"
echo "  iPhoneOS SDK:  ${SDK_PATH}"
echo "  compiler:      ${CLANG}"
echo "  min iOS:       ${PLATFORM_MIN_VERSION}"
echo "  output:        ${OUTPUT_DIR}"

SRC_DIR="${OUTPUT_DIR}/src"
INSTALL_DIR="${OUTPUT_DIR}/arm64"

# --------------------------------------------------------------------
# Download FFmpeg source if not cached.
# Cached by GitHub Actions `actions/cache` keyed on the configure
# command line + version (see ios-unsigned-ipa.yml).  When the
# cache hits, only `make install` runs (which is fast).
# --------------------------------------------------------------------
if [ ! -d "${SRC_DIR}/ffmpeg" ]; then
  echo ""
  echo "=== Downloading FFmpeg ${FFMPEG_VERSION} ==="
  mkdir -p "${SRC_DIR}"
  curl -fsSL \
    "https://www.ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" \
    -o "${SRC_DIR}/ffmpeg.tar.gz"
  tar -xzf "${SRC_DIR}/ffmpeg.tar.gz" -C "${SRC_DIR}"
  # The n7.x tarball extracts to ffmpeg/; older versions extract to
  # ffmpeg-${VERSION}/.  Normalise to a single `ffmpeg/` path.
  if [ ! -d "${SRC_DIR}/ffmpeg" ] && [ -d "${SRC_DIR}/ffmpeg-${FFMPEG_VERSION}" ]; then
    mv "${SRC_DIR}/ffmpeg-${FFMPEG_VERSION}" "${SRC_DIR}/ffmpeg"
  fi
  rm -f "${SRC_DIR}/ffmpeg.tar.gz"
fi

cd "${SRC_DIR}/ffmpeg"

# --------------------------------------------------------------------
# Configure: minimal FFmpeg for B 站 playback on iOS arm64.
#
# Notes on individual flags:
#   --disable-everything       start from zero; every codec/protocol/etc
#                              must be re-enabled explicitly so the
#                              configure can't quietly pull in GPL
#                              codecs via auto-detection
#   --enable-gpl / --enable-nonfree
#                              left OFF — our decoder list (h264, hevc,
#                              aac, mp3) is all LGPL or native
#   --enable-static --disable-shared
#                              produce .a so xcodebuild can link with
#                              OTHER_LDFLAGS="-lavformat ..." and
#                              there's no dyld dependency at runtime
#   --disable-programs         skip ffmpeg/ffprobe CLIs (saves ~5MB)
#   --disable-doc              skip HTML/text docs
#   --extra-cflags=-fembed-bitcode
#                              preserve bitcode compatibility for
#                              App Store submission (no-op for
#                              Xcode 14+ but harmless)
#   --pkg-config-flags=--static
#                              force static linking of any zlib / tls
#                              dependencies so the binary has no dylib
#                              deps that aren't in the iOS runtime
# --------------------------------------------------------------------
echo ""
echo "=== Configuring FFmpeg for arm64-apple-darwin ==="
./configure \
  --prefix="${INSTALL_DIR}" \
  --enable-cross-compile \
  --target-os=darwin \
  --arch=arm64 \
  --cc="${CLANG}" \
  --sysroot="${SDK_PATH}" \
  --extra-cflags="-mios-version-min=${PLATFORM_MIN_VERSION} -fembed-bitcode" \
  --extra-ldflags="-mios-version-min=${PLATFORM_MIN_VERSION}" \
  --pkg-config-flags=--static \
  --disable-everything \
  --enable-static \
  --disable-shared \
  --enable-protocol=file,http,https,tcp,tls \
  --enable-demuxer=mov,mp4,m4v,hls,flv \
  --enable-decoder=h264,hevc,aac,mp3float \
  --enable-parser=h264,hevc,aac \
  --disable-programs \
  --disable-doc \
  > "${OUTPUT_DIR}/configure.log" 2>&1

# --------------------------------------------------------------------
# Build + install.
# `make -j$(sysctl -n hw.ncpu)` saturates the runner — a 4-core
# macos-15 runner gets ~4x the throughput of single-threaded.  Total
# wall clock should be 15-25 minutes for this minimal config.
# --------------------------------------------------------------------
echo ""
echo "=== Building (this takes 15-25 min on a 4-core runner) ==="
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
make -j"${JOBS}" > "${OUTPUT_DIR}/make.log" 2>&1

echo ""
echo "=== Installing into ${INSTALL_DIR} ==="
make install > "${OUTPUT_DIR}/install.log" 2>&1

# --------------------------------------------------------------------
# Smoke check — make sure we actually produced the four archives the
# App target will link.  If any of these is missing, surface the path
# so the failure is obvious in the CI log.
# --------------------------------------------------------------------
echo ""
echo "=== Verifying build artifacts ==="
REQUIRED_LIBS=(
  "${INSTALL_DIR}/lib/libavformat.a"
  "${INSTALL_DIR}/lib/libavcodec.a"
  "${INSTALL_DIR}/lib/libavutil.a"
  "${INSTALL_DIR}/lib/libswresample.a"
)
MISSING=0
for lib in "${REQUIRED_LIBS[@]}"; do
  if [ -f "${lib}" ]; then
    SIZE=$(du -h "${lib}" | cut -f1)
    echo "  ✓ ${lib} (${SIZE})"
  else
    echo "  ✗ MISSING: ${lib}"
    MISSING=1
  fi
done

if [ "${MISSING}" -ne 0 ]; then
  echo "::error::One or more FFmpeg archives missing — see ${OUTPUT_DIR}/configure.log" >&2
  exit 1
fi

echo ""
echo "=== FFmpeg build complete ==="
echo "  Headers:  ${INSTALL_DIR}/include"
echo "  Libs:     ${INSTALL_DIR}/lib"
echo "  Size:     $(du -sh "${INSTALL_DIR}" | cut -f1)"
