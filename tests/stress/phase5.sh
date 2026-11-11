#!/bin/bash
# Fifth batch: bracket the one-core breaking point (300 ok, 400 degraded) and confirm
# the production connection cap (200) turns extra players away.
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
while pgrep -f "phase4[.]sh" > /dev/null; do sleep 5; done
step() { ./run_step.sh "$@" > /dev/null 2>&1; echo "done $1"; }
step n1_350    350 1 8 40 6 /tmp/bpstress/game_nocap
step n1_350_r2 350 1 8 40 6 /tmp/bpstress/game_nocap
step n1_300_r2 300 1 8 40 6 /tmp/bpstress/game_nocap
step c1_216    216 1 8 40 6
echo ALLDONE
