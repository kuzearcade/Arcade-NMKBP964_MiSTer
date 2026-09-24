#!/bin/bash
# Oracle capture: tools/run_oracle_capture.sh <game> <name> <from> <frames> [play]
# Writes sim/oracle/traces/<name>/ (gitignored). Uses the PATCHED MAME in ~/mame
# with MP_ORACLE=1 (tools/mame-patches/macrossp-oracle.patch: no speedup, no
# sound-command stall). "play" adds sim/oracle/macplus_play.lua.
# MS1-14: SDL dummy drivers; never -sound none when audio matters; never pipe stdout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$1"; N="$2"; FROM="$3"; FR="$4"; PLAY="${5:-}"
OUT="$ROOT/sim/oracle/traces/$N"; rm -rf "$OUT"; mkdir -p "$OUT"
export MP_ORACLE=1 MP_OUT="$OUT" MP_FROM="$FROM" MP_FRAMES="$FR" SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
[ "$PLAY" = play ] && export MP_PLAY="$ROOT/sim/oracle/macplus_play.lua"
cd "$OUT"
"${MAME:-$HOME/mame/mame}" "$G" -rompath "$ROOT/mame_roms" -video none -sound none -nothrottle \
  -autoboot_script "$ROOT/sim/oracle/macplus_capture.lua" > "$OUT/mame.log" 2>&1 || true
echo "$N: $(ls "$OUT" | grep -c '^s.*\.bin$') states, $(grep -c 'tap error' "$OUT/mame.log" || true) tap errors"
