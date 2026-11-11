#!/bin/bash
# Second batch: repeats near the 0.1 CPU limit, the one-core ladder up to the built-in
# 200-connection cap, then a copy with the caps raised (labelled nocap) to find where the
# referee code itself stops keeping up on one core.
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
step() { ./run_step.sh "$@" > /dev/null 2>&1; echo "done $1"; }
# 0.1 CPU quota: bracket the first failure (24 ok, 32 degraded in the first ladder)
step q01_24_r2 24 0.1 8 40 2
step q01_28    28 0.1 8 40 2
step q01_28_r2 28 0.1 8 40 2
step q01_32_r2 32 0.1 8 40 2
step q01_24_r3 24 0.1 8 40 2
# One full core, production code, rooms of 8 (cap 200 connections, 50 rooms)
step c1_8     8   1 8 40 2
step c1_64    64  1 8 40 2
step c1_128   128 1 8 40 4
step c1_200   200 1 8 40 6
step c1_200_r2 200 1 8 40 6
# Caps raised (copy only), one core, rooms of 8
step n1_300   300 1 8 40 6 /tmp/bpstress/game_nocap
step n1_400   400 1 8 40 6 /tmp/bpstress/game_nocap
step n1_600   600 1 8 40 7 /tmp/bpstress/game_nocap
# Caps raised, one core, ONE big room
step b1_16    16  1 16 40 1 /tmp/bpstress/game_nocap
step b1_32    32  1 32 40 1 /tmp/bpstress/game_nocap
step b1_50    50  1 50 40 1 /tmp/bpstress/game_nocap
step b1_100   100 1 100 40 1 /tmp/bpstress/game_nocap
echo ALLDONE
