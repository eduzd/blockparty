#!/usr/bin/env python3
"""Print a table of stress steps and apply the rules in THRESHOLDS.md.
usage: summarize.py <prefix> [prefix...]"""
import glob, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def verdict(r):
    why = []
    if r['joins'] < r['players'] or r['failedJoins']:
        why.append('joins %d/%d' % (r['joins'], r['players']))
    if r['disconnects']:
        why.append('%d disconnects' % r['disconnects'])
    if r['kicks']:
        why.append('kicks %s' % r['kicks'])
    rtt, age, gap = r['rtt'], r['snapAge'], r['srvGap']
    if rtt['p95'] is None or rtt['p95'] > 100 or rtt['p99'] > 200:
        why.append('rtt p95/p99 %s/%s' % (rtt['p95'], rtt['p99']))
    if age['p95'] is None or age['p95'] > 100:
        why.append('snapAge p95 %s' % age['p95'])
    if gap['p99'] is None or gap['p99'] > 100:
        why.append('srvGap p99 %s' % gap['p99'])
    if r['snapHzPerPlayer']['mean'] < 19:
        why.append('snap Hz %s' % r['snapHzPerPlayer']['mean'])
    lg = max((l['p99'] for l in r['loadgenLoopDelayMs']), default=0) - 10
    invalid = lg > 30
    return ('INVALID' if invalid else ('ok' if not why else 'DEGRADED')), why, lg


for pfx in sys.argv[1:]:
    rows = []
    for f in glob.glob(os.path.join(HERE, 'logs', pfx + '_*.json')):
        if f.endswith('.client.json') or f.endswith('.quota.json'):
            continue
        rows.append(json.load(open(f)))
    rows.sort(key=lambda r: (r['players'], r['label']))
    print('== %s' % pfx)
    print('%-12s %4s %5s %-9s %11s %10s %9s %11s %7s %7s %8s %6s  %s' % (
        'step', 'plyr', 'rooms', 'verdict', 'rtt p50/95/99', 'age p50/95', 'gap p99', 'Hz mean/min', 'srvCPU%', 'RSS MB', 'thrtl ms', 'lg+ms', 'reasons'))
    for r in rows:
        v, why, lg = verdict(r)
        print('%-12s %4d %5d %-9s %11s %10s %9s %11s %7s %7s %8s %6.1f  %s' % (
            r['label'], r['players'], r['rooms'], v,
            '%s/%s/%s' % (r['rtt']['p50'], r['rtt']['p95'], r['rtt']['p99']),
            '%s/%s' % (r['snapAge']['p50'], r['snapAge']['p95']),
            r['srvGap']['p99'], '%s/%s' % (r['snapHzPerPlayer']['mean'], r['snapHzPerPlayer']['min']),
            r['serverCpuPct']['mean'], r['serverRssMB']['max'], r['throttledMs'], lg, '; '.join(why)))
