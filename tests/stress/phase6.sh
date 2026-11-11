#!/bin/bash
# Sixth batch: with the neon balls off, how far does the 0.1 CPU server go?
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
while pgrep -f "phase5[.]sh" > /dev/null; do sleep 5; done
step() { ./run_step.sh "$@" > /dev/null 2>&1; echo "done $1"; }
step qn_96     96  0.1 8 40 4 /tmp/bpstress/game_noballs
step qn_128    128 0.1 8 40 4 /tmp/bpstress/game_noballs
step qn_200    200 0.1 8 40 6 /tmp/bpstress/game_noballs
echo ALLDONE
