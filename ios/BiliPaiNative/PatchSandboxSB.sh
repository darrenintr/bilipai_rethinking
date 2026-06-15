#!/bin/sh
# Patches the Xcode-generated .sb sandbox policy file to allow file-write-create
# in Build/Products/.  The patched file is copied to TARGET_TEMP_DIR before the
# [CP] Embed Pods Frameworks phase so sandbox-exec uses the allow rule.
set -euo pipefail

SB_SOURCE="${PROJECT_DIR}/BiliPaiNative.build sandboxes/CustomPolicy.sb"
SB_DEST_DIR="${TARGET_TEMP_DIR}"
SB_DEST="${SB_DEST_DIR}"/custom.sb

# Create the patched .sb file if it doesn't exist yet.
if [ ! -f "$SB_SOURCE" ]; then
    mkdir -p "$(dirname "$SB_SOURCE")"
    cat > "$SB_SOURCE" << 'POLICY'
(version 1)
(allow default)
(deny file-write-create)
(deny file-write-data)
(allow file-write-create (subpath "Build/Products/"))
(allow file-write-data (subpath "Build/Products/"))
POLICY
fi

# Copy the patched .sb to TARGET_TEMP_DIR so the Embed phase picks it up.
if [ -f "$SB_SOURCE" ]; then
    cp -f "$SB_SOURCE" "$SB_DEST"
fi