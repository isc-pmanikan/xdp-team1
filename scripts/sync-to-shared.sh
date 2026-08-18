#!/bin/bash
# Copies the code, the CSV, and the dashboard to a place the IRIS server can read.
#
# Why this exists: the IRIS server processes run under their own uid, not the
# logged-in user's, and ~/Documents is mode 700 on macOS. Anything that IRIS
# itself opens by path -- $System.OBJ.LoadDir, %Stream.FileCharacter, a CSP
# application's physical path -- therefore cannot live inside this checkout.
# The VSCode ObjectScript extension is unaffected: it reads files as you and
# sends their contents over HTTP, so compile-on-save keeps working normally.
#
# Run this after editing anything under src/ or web/, then recompile.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED=/Users/Shared/xdp-team1

mkdir -p "$SHARED/src" "$SHARED/data" "$SHARED/web"

rsync -a --delete --exclude='*.csv' "$REPO/src/" "$SHARED/src/"
rsync -a "$REPO/web/" "$SHARED/web/"
rsync -a "$REPO/src/Boston311-2026-Base.csv" "$SHARED/data/"

# World-readable so the IRIS uid can traverse and read; not writable by it.
chmod -R a+rX "$SHARED"

echo "Synced to $SHARED"
find "$SHARED" -type f | sed "s|$SHARED|  |"
