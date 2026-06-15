#!/bin/sh
# Placeholder script. Framework embedding is handled by:
# 1. Podfile post_install: replaces rsync --delete -av with cp -R
# 2. Workflow: manual cp -R step after build
set -euo pipefail
echo "[PatchSandboxSB] no-op (frameworks embedded via Podfile cp replacement + workflow step)"