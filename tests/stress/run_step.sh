#!/bin/bash
# One stress step against a fresh, isolated local referee (never the live Render server).
# usage: run_step.sh <label> <players> <cpu: 0.1|1|full> [room_size] [duration] [procs] [game_dir]
#   cpu 0.1  -> server held to 10 ms of CPU per 100 ms by cpu_quota.py (an approximation
#              of Render's free instance, 0.1 CPU; this VM can't place processes in a cgroup)
#   cpu 1    -> server pinned to one core with taskset
#   cpu full -> no limit
# Output: logs/<label>.json (client metrics + server CPU/RSS/throttling) and logs/<label>.server.log
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=$1; PLAYERS=$2; CPU=$3; RS=${4:-8}; DUR=${5:-40}; PROCS=${6:-2}
GAME=${7:-/tmp/bpstress/game}
PORT=${PORT:-9100}
GODOT=${GODOT:-/home/sprite/tools/godot}
LOGS=$HERE/logs; mkdir -p "$LOGS"

# Fresh server for every step so earlier steps can't leak into this one.
pkill -f "bpstress-port-$PORT" 2>/dev/null; sleep 0.5
cd "$GAME"
if [ "$CPU" = "1" ]; then
  PORT=$PORT taskset -c 7 "$GODOT" --headless --path . -- --server "bpstress-port-$PORT" > "$LOGS/$LABEL.server.log" 2>&1 &
else
  PORT=$PORT "$GODOT" --headless --path . -- --server "bpstress-port-$PORT" > "$LOGS/$LABEL.server.log" 2>&1 &
fi
SPID=$!
QPID=""
if [ "$CPU" = "0.1" ]; then
  # 0.1 CPU quota (10 ms per 100 ms), see cpu_quota.py. Started after the server is listening.
  :
fi
for i in $(seq 1 60); do grep -q "listening" "$LOGS/$LABEL.server.log" && break; sleep 0.25; done
if [ "$CPU" = "0.1" ]; then
  rm -f "$LOGS/$LABEL.quota.json"
  taskset -c 6 python3 "$HERE/cpu_quota.py" $SPID 10 100 "$LOGS/$LABEL.quota.json" &
  QPID=$!
fi
sleep 1

# Sample the server's CPU (all threads) and RSS once a second while the load runs.
CLK=$(getconf CLK_TCK)
thr0=$( [ "$CPU" = "0.1" ] && python3 -c "import json;d=json.load(open('$LOGS/$LABEL.quota.json'));print(d['throttled'],d['throttled_ms']*1000)" 2>/dev/null || echo "0 0")
( prev=""; while kill -0 $SPID 2>/dev/null; do
    read -r ut st <<<"$(awk '{print $14, $15}' /proc/$SPID/stat 2>/dev/null)"
    rss=$(awk '/VmRSS/{print $2}' /proc/$SPID/status 2>/dev/null)
    echo "$(date +%s.%N) $ut $st $rss"; sleep 1; done ) > "$LOGS/$LABEL.samples" &
SAMP=$!

node "$HERE/load.js" --url ws://127.0.0.1:$PORT --players "$PLAYERS" --room-size "$RS" --duration "$DUR" \
  --ramp $(( PLAYERS < 40 ? 4 : PLAYERS / 10 )) --procs "$PROCS" --tag "$(echo $LABEL | tr -dc 'A-Za-z' | head -c1)" --out "$LOGS/$LABEL.client.json" > /dev/null
thr1=$( [ "$CPU" = "0.1" ] && python3 -c "import json;d=json.load(open('$LOGS/$LABEL.quota.json'));print(d['throttled'],d['throttled_ms']*1000)" 2>/dev/null || echo "0 0")
kill $SAMP 2>/dev/null
alive=$(kill -0 $SPID 2>/dev/null && echo yes || echo no)
[ -n "$QPID" ] && kill $QPID 2>/dev/null && sleep 0.3
kill -CONT $SPID 2>/dev/null; kill $SPID 2>/dev/null; wait $SPID 2>/dev/null

# Server CPU over the measured window: the middle samples (skip ramp/warm-up and teardown).
python3 - "$LOGS/$LABEL.samples" "$CLK" "$LOGS/$LABEL.client.json" "$LABEL" "$CPU" "$alive" "$thr0" "$thr1" > "$LOGS/$LABEL.json" <<'EOF'
import json, sys
samp, clk, cj, label, cpu, alive, thr0, thr1 = sys.argv[1:]
rows = [l.split() for l in open(samp) if len(l.split()) == 4]
rows = [(float(t), int(u) + int(s), int(r)) for t, u, s, r in rows]
c = json.load(open(cj))
ramp = c['players'] // 10 if c['players'] >= 40 else 4
skip = ramp + 3 + 1
win = rows[skip: skip + int(c['seconds'])]
cpu_pct = []
for a, b in zip(win, win[1:]):
    cpu_pct.append(100.0 * (b[1] - a[1]) / int(clk) / (b[0] - a[0]))
t0 = [int(x) for x in thr0.split()]; t1 = [int(x) for x in thr1.split()]
out = {'label': label, 'serverCpuLimit': cpu, 'serverAliveAtEnd': alive == 'yes', **c,
       'serverCpuPct': {'mean': round(sum(cpu_pct) / len(cpu_pct), 1) if cpu_pct else None, 'max': round(max(cpu_pct), 1) if cpu_pct else None},
       'serverRssMB': {'max': round(max(r[2] for r in rows) / 1024, 1) if rows else None},
       'throttledPeriods': (t1[0] - t0[0]) if len(t0) == 2 and len(t1) == 2 else None,
       'throttledMs': round((t1[1] - t0[1]) / 1000) if len(t0) == 2 and len(t1) == 2 else None}
print(json.dumps(out))
EOF
cat "$LOGS/$LABEL.json"
