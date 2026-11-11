#!/bin/bash
# Fourth batch: is the 0.1 CPU limit about players or about rooms?
#  qb_*  0.1 CPU, caps raised (copy), all players in ONE room
#  qr_*  0.1 CPU, production code, rooms of 2 (many rooms, few players)
#  qn_*  0.1 CPU, copy with the neon balls switched off (balls_enabled=false), rooms of 8
#  cn_*  one core, balls off, rooms of 8 (compare with c1_128)
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
while pgrep -f "phase3[.]sh" > /dev/null; do sleep 5; done
step() { ./run_step.sh "$@" > /dev/null 2>&1; echo "done $1"; }
step qb_32   32  0.1 32 40 1 /tmp/bpstress/game_nocap
step qb_64   64  0.1 64 40 1 /tmp/bpstress/game_nocap
step qb_100  100 0.1 100 40 2 /tmp/bpstress/game_nocap
step qr_6    6   0.1 2 40 1
step qr_8    8   0.1 2 40 1
step qr_10   10  0.1 2 40 1
step qn_32   32  0.1 8 40 2 /tmp/bpstress/game_noballs
step qn_64   64  0.1 8 40 2 /tmp/bpstress/game_noballs
step cn_128  128 1 8 40 4 /tmp/bpstress/game_noballs
echo ALLDONE
