#!/usr/bin/env bash
# PNGs of the onboarding, menu bar panel, Settings tabs and menu bar glyphs (light + dark) into
# docs/screenshots, rendered by the app itself with sample data. Run it from Terminal yourself:
# macOS lets the app become active (accent-coloured controls) only right after you used Terminal.
# Usage: scripts/snapshots.sh [app]   (default: build/Clackwise.app from scripts/build_app.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Clackwise.app}"
OUT="$ROOT/docs/screenshots"
LOG="$(mktemp)"
mkdir -p "$OUT"
# A running copy (same bundle ID) can keep the snapshot instance from becoming the active app, which
# draws switches and sliders grey: quit it for the run and start it again afterwards.
RUNNING_APP="$(pgrep -x Clackwise >/dev/null && ps -o command= -p "$(pgrep -x Clackwise | head -1)" | sed 's#/Contents/MacOS/.*##' || true)"
if [[ -n "$RUNNING_APP" ]]; then
  osascript -e 'tell application id "io.github.bobk4ta.clackwise" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Clackwise >/dev/null || break; sleep 0.3; done
fi
open -n -W --stdout "$LOG" --stderr "$LOG" "$APP" --args --snapshots "$OUT"
cat "$LOG"; rm -f "$LOG"
[[ -n "$RUNNING_APP" ]] && open "$RUNNING_APP" || true
