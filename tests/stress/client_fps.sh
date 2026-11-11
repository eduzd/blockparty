#!/bin/bash
# Rendered-client frame-rate trend on THIS VM (software OpenGL in Xvfb, no GPU).
# It shows whether more visible players change the client's frame cost here; it
# says nothing about frame rate on a real phone.
# usage: client_fps.sh [bot counts...]   (default 0 3 7; a room holds 8)
HERE=$(cd "$(dirname "$0")" && pwd)
LOGS=$HERE/logs; mkdir -p "$LOGS"
GAME=${GAME:-/tmp/bpstress/game}
GODOT=/home/sprite/tools/Godot_v4.7.2-stable_linux.x86_64
PORT=9101
COUNTS=${*:-0 3 7}
cd "$GAME"
PORT=$PORT taskset -c 7 "$GODOT" --headless --path . -- --server bpstress-port-$PORT > "$LOGS/fps.server.log" 2>&1 &
SPID=$!
sleep 3
for n in $COUNTS; do
  BPID=""
  if [ "$n" -gt 0 ]; then
    node "$HERE/load.js" --url ws://127.0.0.1:$PORT --players $n --room PLAY --duration 50 --ramp 2 --warm 1 --procs 1 > /dev/null &
    BPID=$!
    sleep 4
  fi
  D=$(mktemp -d); U="$D/godot/app_userdata/Block Party"; mkdir -p "$U"
  printf '[p]\n\nserver="ws://127.0.0.1:%d"\nname="Viewer"\nroom="PLAY"\n' $PORT > "$U/settings.cfg"
  XDG_DATA_HOME=$D AUTOTEST_SECONDS=40 LP_NUM_THREADS=4 timeout 90 taskset -c 0-3 xvfb-run -a -s "-screen 0 1200x1200x24" \
    "$GODOT" --rendering-driver opengl3 --path . --resolution 412x900 --print-fps -- --autotest=join:ws://127.0.0.1:$PORT \
    > "$LOGS/fps_bots$n.log" 2>&1
  [ -n "$BPID" ] && wait $BPID
  python3 - "$LOGS/fps_bots$n.log" $n <<'EOF'
import re, sys, statistics
lines = open(sys.argv[1]).read().splitlines()
fps = [(int(m.group(1)), float(m.group(2))) for l in lines for m in [re.search(r'FPS: (\d+) \(([\d.]+) mspf\)', l)] if m]
res = [l for l in lines if 'AUTOTEST RESULT' in l]
steady = fps[10:]   # skip the first 10 s (joining, shader warm-up)
if steady:
    f = [x[0] for x in steady]; ms = [x[1] for x in steady]
    print('bots=%s samples=%d fps median=%s min=%s  mspf median=%.2f max=%.2f' % (sys.argv[2], len(steady), statistics.median(f), min(f), statistics.median(ms), max(ms)))
else:
    print('bots=%s no fps samples' % sys.argv[2])
print(res[0][:220] if res else 'no AUTOTEST RESULT line')
EOF
  rm -rf "$D"
done
kill $SPID
