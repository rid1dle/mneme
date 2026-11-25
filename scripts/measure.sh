#!/bin/zsh
# Opens and closes the shelf off screen on the 10,000-item store, then reads memory after it sits idle.
#   scripts/measure.sh [cycles] [idle-seconds]
set -euo pipefail
cd "$(dirname "$0")/.."
CYCLES=${1:-20}; IDLE=${2:-60}
[[ -d build/fixtures/many ]] || ./build/tests --fixture build/fixtures/many many
LOG=build/measure.log
build/Mneme.app/Contents/MacOS/Mneme --store build/fixtures/many --measure $CYCLES > $LOG 2>&1 &
PID=$!
for _ in {1..120}; do grep -q "first frame" $LOG && break; sleep 0.5; done
cat $LOG
echo "after opens: $(vmmap --summary $PID 2>/dev/null | grep 'Physical footprint:' | tr -s ' ')"
sleep $IDLE
echo "after ${IDLE}s idle: $(vmmap --summary $PID 2>/dev/null | grep -E 'Physical footprint' | tr -s ' ' | paste -sd ';' -)"
echo "cpu over idle: $(ps -o %cpu= -p $PID)%"
kill $PID
