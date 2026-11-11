#!/bin/bash
# Run a ladder of steps one after another. usage: ladder.sh <prefix> <cpu> <room_size> <counts...>
HERE=$(cd "$(dirname "$0")" && pwd)
PFX=$1; CPU=$2; RS=$3; shift 3
for n in "$@"; do
  procs=2; [ "$n" -ge 96 ] && procs=4; [ "$n" -ge 200 ] && procs=6
  "$HERE/run_step.sh" "${PFX}_${n}" "$n" "$CPU" "$RS" 40 "$procs" ${GAME_DIR:-} > /dev/null 2>&1
  echo "done ${PFX}_${n}"
done
