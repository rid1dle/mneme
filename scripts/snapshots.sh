#!/bin/zsh
# Draws every shelf state into PNGs for review, off screen: scripts/snapshots.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-build/snapshots}
mkdir -p "$OUT" build/fixtures
for v in normal long many empty; do ./build/tests --fixture build/fixtures/$v $v; done
APP=build/Mneme.app/Contents/MacOS/Mneme
shot() { local name=$1 store=$2; shift 2; "$APP" --store build/fixtures/$store --snapshot "$OUT/$name.png" --width 1280 "$@" 2>/dev/null; echo "$OUT/$name.png"; }
shot light          normal --appearance light
shot dark           normal --appearance dark
shot solid-light    normal --appearance light --shell solid
shot solid-dark     normal --appearance dark --shell solid
shot search         normal --appearance light --search invoice
shot images         normal --appearance dark --kind image
shot pinboard       normal --appearance light --pinboard Work
shot selected-3     normal --appearance light --select 3
shot preset-paper   normal --theme 2
shot preset-midnight normal --theme 3
shot empty          empty  --appearance light
shot no-match       normal --appearance dark --search zzzqqq
shot long           long   --appearance light
shot many           many   --appearance dark
