#!/usr/bin/env python3
"""Hold a process to a CPU quota the way a container CPU limit does (CFS bandwidth):
in every PERIOD it may use at most QUOTA of CPU time; once it has, all its threads
are stopped (SIGSTOP) until the period ends, then resumed (SIGCONT).

This VM can't move processes into a cgroup, so this stands in for Render's
0.1 CPU free instance (quota 10 ms per 100 ms). It is an approximation: Render's real
scheduler, period and any burst allowance are not known.

usage: cpu_quota.py <pid> [quota_ms=10] [period_ms=100] [stats_file]
CPU time is read in nanoseconds from /proc/<pid>/task/*/schedstat.
"""
import json, os, signal, sys, time

pid = int(sys.argv[1])
quota = float(sys.argv[2] if len(sys.argv) > 2 else 10) / 1000.0
period = float(sys.argv[3] if len(sys.argv) > 3 else 100) / 1000.0
stats_file = sys.argv[4] if len(sys.argv) > 4 else None


def runtime():
    total = 0
    try:
        for t in os.listdir('/proc/%d/task' % pid):
            try:
                with open('/proc/%d/task/%s/schedstat' % (pid, t)) as f:
                    total += int(f.read().split()[0])
            except (FileNotFoundError, ProcessLookupError, ValueError):
                pass
    except FileNotFoundError:
        return None
    return total / 1e9


periods = throttled = 0
throttled_s = 0.0
stopped = False


def write_stats():
    if stats_file:
        with open(stats_file + '.tmp', 'w') as f:
            json.dump({'periods': periods, 'throttled': throttled, 'throttled_ms': round(throttled_s * 1000)}, f)
        os.replace(stats_file + '.tmp', stats_file)


def bye(*_):
    try:
        os.kill(pid, signal.SIGCONT)
    except ProcessLookupError:
        pass
    write_stats()
    sys.exit(0)


signal.signal(signal.SIGTERM, bye)
signal.signal(signal.SIGINT, bye)
next_stats = time.monotonic() + 1
while True:
    start = time.monotonic()
    used0 = runtime()
    if used0 is None:
        bye()
    periods += 1
    end = start + period
    while time.monotonic() < end:
        r = runtime()
        if r is None:
            bye()
        if r - used0 >= quota:
            os.kill(pid, signal.SIGSTOP)
            t = time.monotonic()
            throttled += 1
            time.sleep(max(0.0, end - t))
            throttled_s += time.monotonic() - t
            os.kill(pid, signal.SIGCONT)
            break
        time.sleep(0.0005)
    if time.monotonic() >= next_stats:
        write_stats()
        next_stats = time.monotonic() + 1
