# Block Party referee stress test (Nov 11 2026)

Tested code: `game/scripts` at repo HEAD (the 0.3.1 build), copied to `/tmp/bpstress/game`
and run there. **Nothing touched the live Render server.** Pass/fail rules were written
first, in `THRESHOLDS.md`.

## Environment
- Server: Godot 4.7.2 headless referee, local copy, port 9100, on the Sesame VM.
- Two CPU settings:
  - `0.1`: held to 10 ms of CPU per 100 ms by `cpu_quota.py` (SIGSTOP/SIGCONT). This
    stands in for Render's free instance (Render's page says "less than 1 CPU"; a 2026
    pricing summary says 0.1 CPU). The VM refused to move processes into a cgroup, so
    this is an approximation; Render's real CPU speed and scheduler are unknown.
  - `1`: pinned to one full VM core (`taskset -c 7`).
- Copies with one change each (never the repo):
  - `game_nocap`: room/connection caps raised (8 to 100 per room, 50 to 500 rooms, 200 to 2000 connections).
  - `game_noballs`: `balls_enabled := false` (neon-ball physics off).

## Workload (`load.js`)
Each simulated player joins a room (rooms of 8 unless stated), sends its position 20 times
a second and a ping every 2 s, and walks a slow circle, like the app. 40 s measured window
after ramp-up and 3 s warm-up. Not included: voice, chat/social traffic, jumping, pushing balls,
real network delay.

## Results (full table: `logs/SUMMARY.txt`)
0.1 CPU, production code, rooms of 8:
- 8, 16, 24 players: healthy (24 run three times; worst ping p99 86 ms).
- 28 players (4 rooms): degraded both runs (snapshots ~18.8-19/s, gaps over 100 ms).
- 40: ping p95 114 ms. 96: 3.4 snapshots/s. 200: 71 players kicked for `rate_limit`.

Rooms, not players, set the limit at 0.1 CPU:
- Rooms of 2: 8 players (4 rooms) healthy, 10 players (5 rooms) degraded.
- One big room (caps raised): 64 healthy, 100 degraded.
- Balls off, rooms of 8: 128 players (16 rooms) healthy, 200 degraded.
- One core, 128 players: server CPU 35.5% with balls, 13.4% without.

One full core:
- Production code: 200 players (the built-in cap) healthy twice at 50-52% CPU; at 216, 16 were
  turned away by the cap and the rest were fine.
- Caps raised: 300 and 350 healthy twice each (~88% and ~95% CPU); 400 degraded; 600 degraded
  with 8 rate_limit kicks.

Memory stayed at 126-138 MB RSS in every step. Load-generator event-loop delay stayed within
2 ms of its timer resolution, so the generator was not the bottleneck.

Bandwidth: one full room of 8 sent ~121 KiB/s of WebSocket payload to its players
(~0.45 GB an hour, before TCP/TLS overhead). Render's Hobby plan includes 5 GB a month,
then $0.15/GB (render.com/pricing), i.e. ~11 hours of one full room a month.

Client (`client_fps.sh`): rendered client in Xvfb with software OpenGL, 0/3/7 other players
(8 is the room max): median 27/24/29 fps, no trend. This only reflects the VM's software
renderer and says nothing about frame rate on a phone.

## Findings
1. Measured bottleneck: per-room neon-ball physics (runs every server frame for every room).
2. Rate limiter kicks honest players when the server falls behind: backed-up messages are
   counted as one burst over `MAX_MSGS_PER_SEC` (referee_server.gd ~line 212).

## Re-running
`./run_step.sh <label> <players> <0.1|1|full> [room_size] [seconds] [procs] [game_dir]`,
`./ladder.sh`, `phase2.sh`..`phase6.sh` for the exact batches, `python3 summarize.py <prefix>`,
`./client_fps.sh 0 3 7`, `./cleanup.sh` to stop leftovers. Needs `ws` from
`/home/sprite/blockparty/tests/node_modules`. `logs/discarded_cgroup_attempt` holds a first
ladder that did not actually get a CPU limit; it is not used.
