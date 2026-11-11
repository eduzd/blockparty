# Stress test pass/fail rules (written before any step was run, Nov 11 2026)

All steps run against a fresh local copy of the referee on this VM, never the live
Render server. Client and server share localhost, so network delay is ~0 ms: every
millisecond measured here is the referee (or the load generator) falling behind.

A step is **healthy** only if ALL hold over its 40 s measured window:

1. Every simulated player joins (no failed joins), and none are disconnected or kicked.
2. Ping round trip (rtt) p95 <= 100 ms and p99 <= 200 ms.
3. Snapshot extra delay (snapAge) p95 <= 100 ms.
4. Server snapshot gaps (srvGap) p99 <= 100 ms (20 Hz target = 50 ms), and each player
   receives >= 19 snapshots per second on average.

Why these numbers: the app sends and receives at 20 Hz and draws others with
interpolation. Over the internet a phone already pays its own ping (about 230 ms from a
US data centre to Render Singapore in an earlier check). Adding more than ~100 ms of
server-side delay on top, or missing more than one snapshot in a row, makes other
players visibly stutter or rubber-band.

The step is **invalid** (load generator bottleneck, not the server) if any load-generator
process shows event-loop delay p99 more than 30 ms above its 10 ms timer resolution.

"First degradation" = the lowest tested player count that is not healthy.
"Largest stable" = the highest tested count below it that is healthy, confirmed by a
repeat run.
