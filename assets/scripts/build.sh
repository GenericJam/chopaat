#!/usr/bin/env bash
# Rebuild every asset from its script, render the contact sheets, and
# run the gate. Deterministic: priv/assets and assets/contact_sheets
# are pure functions of these scripts.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
SCRIPTS="$REPO/assets/scripts"
OUT="$REPO/priv/assets"
SHEETS="$REPO/assets/contact_sheets"

mkdir -p "$OUT" "$SHEETS"

"$BLENDER" --background --python "$SCRIPTS/probe.py" -- "$OUT/probe.glb"
"$BLENDER" --background --python "$SCRIPTS/board.py" -- "$OUT/board.glb" 4
"$BLENDER" --background --python "$SCRIPTS/board.py" -- "$OUT/board_6p.glb" 6
"$BLENDER" --background --python "$SCRIPTS/pawn.py" -- "$OUT/pawn.glb"
"$BLENDER" --background --python "$SCRIPTS/cowrie.py" -- "$OUT"
node "$SCRIPTS/shell_pool.mjs"
"$BLENDER" --background --python "$SCRIPTS/contact_sheet.py" -- "$SHEETS" "$OUT"

node "$SCRIPTS/gate.mjs"
