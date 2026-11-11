#!/bin/bash
# Reruns of steps whose first attempt lost its results to a load-generator reporting bug
# (Math.max on a 100k+ element array overflowed the stack; fixed in load.js), plus
# refinement around the one-core / caps-raised breaking point.
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
while pgrep -f phase2.sh > /dev/null; do sleep 5; done
step() { ./run_step.sh "$@" > /dev/null 2>&1; echo "done $1"; }
step c1_200    200 1 8 40 6
step c1_200_r2 200 1 8 40 6
step n1_300    300 1 8 40 6 /tmp/bpstress/game_nocap
step n1_400    400 1 8 40 6 /tmp/bpstress/game_nocap
echo ALLDONE
