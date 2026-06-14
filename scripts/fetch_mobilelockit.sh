#!/usr/bin/env bash
# fetch_mobilelockit.sh — download the prebuilt MobileVLCKit xcframework
# from VLC's CocoaPods CDN and place it where the local Swift Package
# (ios/BiliPaiNative/LocalPackages/MobileVLCKit/Package.swift) expects it.
#
# Run this once after cloning, and any time the pinned URL is bumped.
# The .xcframework is NOT committed to the repo (see
# LocalPackages/MobileVLCKit/Sources/MobileVLCKit/.gitignore).
#
# Usage:
#   bash scripts/fetch_mobilelockit.sh            # fetch into the local SPM package
#   bash scripts/fetch_mobilelockit.sh --clean    # nuke a stale xcframework first
#
# Environment overrides:
#   VLC_XCFRAMEWORK_URL    Full URL of the .tar.xz to download
#   VLC_XCFRAMEWORK_SHA256 Expected SHA-256 of the .tar.xz (optional but recommended)

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned version
# ---------------------------------------------------------------------------
# The URL is the canonical CocoaPods CDN tarball VLC publishes for the
# MobileVLCKit binary. Format:
#   MobileVLCKit-<semver>-<short_git_hash>-<short_build_hash>.tar.xz
#
# To bump the version: update the URL below, and (if you have one) the
# matching SHA-256. The URL must be the exact .tar.xz; the script will
# refuse anything that doesn't end in `.tar.xz`.
#
# NOTE: the exact `git_hash` and `build_hash` segments change with every
# upstream release. When bumping, browse
# https://download.videolan.org/pub/cocoapods/prod/ to find the current
# filename and paste it here.
#
# Pinned: MobileVLCKit 3.7.3 (released 2026-02-25). This is the latest
# stable release on the CocoaPods CDN. The previous 3.6.0 line is also
# available at the same directory.
#
# The tarball's top-level directory is `MobileVLCKit-binary/`, which
# contains the `MobileVLCKit.xcframework` we want plus a `Sample Code/`
# and `doc/` directory we discard. We use `tar --strip-components=1`
# to drop the wrapper so the xcframework lands at exactly
# `Sources/MobileVLCKit/MobileVLCKit.xcframework` (the path the local
# Package.swift's binaryTarget expects).
VLC_XCFRAMEWORK_URL="${VLC_XCFRAMEWORK_URL:-https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz}"
VLC_XCFRAMEWORK_SHA256="${VLC_XCFRAMEWORK_SHA256:-0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9}"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST_DIR="${REPO_ROOT}/ios/BiliPaiNative/LocalPackages/MobileVLCKit/Sources/MobileVLCKit"

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--clean" ]]; then
    echo "Cleaning stale xcframework at ${DEST_DIR}/MobileVLCKit.xcframework"
    rm -rf "${DEST_DIR}/MobileVLCKit.xcframework"
fi

mkdir -p "${DEST_DIR}"

# ---------------------------------------------------------------------------
# Sanity
# ---------------------------------------------------------------------------
if [[ ! "${VLC_XCFRAMEWORK_URL}" =~ \.tar\.xz$ ]]; then
    echo "::error::VLC_XCFRAMEWORK_URL must end in .tar.xz (got: ${VLC_XCFRAMEWORK_URL})" >&2
    exit 1
fi

if [[ -d "${DEST_DIR}/MobileVLCKit.xcframework" ]]; then
    echo "MobileVLCKit.xcframework already present at ${DEST_DIR}; skipping fetch."
    echo "Re-run with --clean to force re-download."
    exit 0
fi

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

TARBALL_PATH="${WORK_DIR}/MobileVLCKit.tar.xz"
echo "Downloading ${VLC_XCFRAMEWORK_URL}"
curl --fail --location --silent --show-error \
     --retry 3 --retry-delay 5 \
     -o "${TARBALL_PATH}" \
     "${VLC_XCFRAMEWORK_URL}"

# ---------------------------------------------------------------------------
# Optional integrity check
# ---------------------------------------------------------------------------
if [[ -n "${VLC_XCFRAMEWORK_SHA256}" ]]; then
    echo "Verifying SHA-256"
    ACTUAL_SHA="$(shasum -a 256 "${TARBALL_PATH}" | awk '{print $1}')"
    if [[ "${ACTUAL_SHA}" != "${VLC_XCFRAMEWORK_SHA256}" ]]; then
        echo "::error::SHA-256 mismatch: expected ${VLC_XCFRAMEWORK_SHA256}, got ${ACTUAL_SHA}" >&2
        exit 1
    fi
    echo "SHA-256 OK"
else
    echo "VLC_XCFRAMEWORK_SHA256 not set — skipping integrity check (set it for production CI)."
fi

# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------
echo "Extracting into ${DEST_DIR} (stripping top-level MobileVLCKit-binary/ wrapper)"
tar -xJf "${TARBALL_PATH}" -C "${DEST_DIR}" --strip-components=1

if [[ ! -d "${DEST_DIR}/MobileVLCKit.xcframework" ]]; then
    echo "::error::Extraction did not produce MobileVLCKit.xcframework at ${DEST_DIR}" >&2
    echo "::group::Contents of ${DEST_DIR}"
    ls -la "${DEST_DIR}"
    echo "::endgroup::"
    exit 1
fi

# The tarball also ships a `Sample Code/` and `doc/` directory we do
# not need; the binaryTarget in Package.swift only references the
# .xcframework so these would otherwise inflate the on-disk footprint
# by ~5 MB and clutter the SPM layout.
rm -rf "${DEST_DIR}/Sample Code" "${DEST_DIR}/doc"

echo "MobileVLCKit.xcframework installed at ${DEST_DIR}/MobileVLCKit.xcframework"
echo "Done."
