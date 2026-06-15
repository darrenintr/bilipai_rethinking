#!/bin/sh
# Patches the Xcode-generated .sb sandbox policy file to allow file-write-create
# in Build/Products/.  This must run BEFORE the [CP] Embed Pods Frameworks phase
# so that sandbox-exec uses the patched policy when wrapping the embed script.
# The .sb file is written by Xcode just before the Embed phase and lives in TARGET_TEMP_DIR.
set -euo pipefail

SB_FILE="${TARGET_TEMP_DIR}"/*.sb
if [ -f "$SB_FILE" ] && ! grep -q 'file-write-create' "$SB_FILE"; then
    echo '(allow file-write-create (subpath "Build/Products/"))' >> "$SB_FILE"
fi