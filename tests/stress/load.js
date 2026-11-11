// Block Party referee stress load generator.
// Simulates game players the way the app behaves (protocol v1):
//   hello -> welcome, then "state" (position + yaw) 20 times a second and a
//   "ping" every 2 s, exactly like scripts/main.gd + scripts/net_client.gd.
// Players walk slow circles around the spawn pad (well under the referee's speed budget).
//
// usage: node load.js --url ws://127.0.0.1:9100 --players 64 --room-size 8 \
//          --duration 40 --ramp 5 --procs 2 --out result.json [--tag R]
// With --procs N the players are split across N child processes so the load
// generator itself is less likely to be the bottleneck. Each child reports its own
// event-loop delay; the parent merges everything into one JSON summary.
//
// Metrics per run:
//   rtt          ping -> pong round trip (ms). Includes the referee's main-loop delay.
//   snapAge      extra one-way delay of each snapshot over the fastest one seen by
//                that player (ms): recv_local - server_ts - min(recv_local - server_ts).
//                Rises when the referee or the network queue falls behind.
//   srvGap       gap between consecutive snapshot server timestamps (ms). 50 ms = 20 Hz.
//                Rises when the referee's loop can't keep up.
//   snapHz       snapshots received per player per second.
//   joins / failedJoins / disconnects / kicks (fatal errors by code) / corrections.
'use strict';
const path = require('path');
const { fork } = require('child_process');
const { monitorEventLoopDelay } = require('perf_hooks');
let WebSocket;
try { WebSocket = require('ws'); } catch (e) { WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws'); }

function args() {
  const a = { url: 'ws://127.0.0.1:9100', players: 8, 'room-size': 8, duration: 40, ramp: 5, procs: 1, out: '', tag: 'S', offset: 0, warm: 3 };
  const v = process.argv.slice(2);
  for (let i = 0; i < v.length; i += 2) a[v[i].replace(/^--/, '')] = v[i + 1];
  for (const k of ['players', 'room-size', 'duration', 'ramp', 'procs', 'offset', 'warm']) a[k] = Number(a[k]);
  return a;
}

const pct = (arr, p) => {
  if (!arr.length) return null;
  const s = Float64Array.from(arr).sort();
  return +s[Math.min(s.length - 1, Math.floor(p / 100 * s.length))].toFixed(1);
};
const summary = arr => ({ n: arr.length, p50: pct(arr, 50), p95: pct(arr, 95), p99: pct(arr, 99), max: arr.length ? +arr.reduce((a, b) => (b > a ? b : a), -Infinity).toFixed(1) : null });

async function runChild(o) {
  const t0 = Date.now();
  const measureFrom = t0 + (o.ramp + o.warm) * 1000;
  const endAt = measureFrom + o.duration * 1000;
  const res = { rtt: [], snapAge: [], srvGap: [], snaps: 0, joins: 0, failedJoins: 0, disconnects: 0, kicks: {}, corrections: {}, errors: {}, bytesIn: 0, msgsOut: 0, joinMs: [], perPlayerHz: [] };
  const el = monitorEventLoopDelay({ resolution: 10 });
  const players = [];
  for (let i = 0; i < o.players; i++) {
    const gi = o.offset + i;
    const room = o.room ? String(o.room) : (o.tag + Math.floor(gi / o['room-size']).toString(36)).toUpperCase().slice(0, 6);
    players.push({ gi, room });
  }
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  let measuring = false;

  function start(p) {
    const ws = new WebSocket(o.url, { perMessageDeflate: false });
    p.ws = ws; p.minOff = Infinity; p.lastTs = null; p.snapsMeasured = 0; p.ended = false;
    const opened = Date.now();
    let angle = (p.gi % 8) / 8 * Math.PI * 2, pos = null, yaw = 0, sendT = null, pingT = null;
    const joinTimer = setTimeout(() => { if (!p.joined) { res.failedJoins++; try { ws.terminate(); } catch (e) {} } }, 15000);
    ws.on('open', () => ws.send(JSON.stringify({ t: 'hello', v: 1, name: 'Stress' + p.gi, room: p.room })));
    ws.on('message', (d) => {
      const now = Date.now();
      if (measuring) res.bytesIn += d.length;
      let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
      switch (m.t) {
        case 'welcome': {
          p.joined = true; clearTimeout(joinTimer); res.joins++; res.joinMs.push(now - opened);
          pos = { x: m.spawn[0], y: m.spawn[1], z: m.spawn[2] };
          const cx = pos.x, cz = pos.z, r = 1.5;
          const dt = 1 / 20;
          sendT = setInterval(() => {
            if (ws.readyState !== 1) return;
            angle += 2.0 * dt / r * 0.5;      // ~1.5 m/s walk around a 1.5 m circle
            pos.x = cx + Math.cos(angle) * r; pos.z = cz + Math.sin(angle) * r;
            yaw = Math.atan2(Math.cos(angle), -Math.sin(angle));
            ws.send(JSON.stringify({ t: 'state', p: [+pos.x.toFixed(2), +pos.y.toFixed(2), +pos.z.toFixed(2)], y: +yaw.toFixed(2) }));
            if (measuring) res.msgsOut++;
          }, 50);
          pingT = setInterval(() => {
            if (ws.readyState !== 1) return;
            ws.send(JSON.stringify({ t: 'ping', c: Date.now() }));
            if (measuring) res.msgsOut++;
          }, 2000);
          p.timers = [sendT, pingT];
          break;
        }
        case 'snap': {
          const off = now - m.ts;
          if (off < p.minOff) p.minOff = off;
          if (measuring) {
            res.snaps++; p.snapsMeasured++;
            res.snapAge.push(off - p.minOff);
            if (p.lastTs !== null) res.srvGap.push(m.ts - p.lastTs);
          }
          p.lastTs = m.ts;
          break;
        }
        case 'pong':
          if (measuring && typeof m.c === 'number' && m.c > 1e12) res.rtt.push(now - m.c);
          break;
        case 'correct':
          if (measuring) res.corrections[m.why] = (res.corrections[m.why] || 0) + 1;
          if (m.p) pos = { x: m.p[0], y: m.p[1], z: m.p[2] };
          break;
        case 'error':
          if (m.fatal) res.kicks[m.code] = (res.kicks[m.code] || 0) + 1;
          else res.errors[m.code] = (res.errors[m.code] || 0) + 1;
          break;
      }
    });
    ws.on('close', () => { (p.timers || []).forEach(clearInterval); if (!p.ended && p.joined) res.disconnects++; });
    ws.on('error', () => {});
  }

  const gap = o.players > 1 ? (o.ramp * 1000) / o.players : 0;
  for (const p of players) { start(p); if (gap) await sleep(gap); }
  while (Date.now() < measureFrom) await sleep(50);
  measuring = true; el.enable();
  const mStart = Date.now();
  while (Date.now() < endAt) await sleep(100);
  measuring = false; el.disable();
  const mSecs = (Date.now() - mStart) / 1000;
  for (const p of players) { if (p.joined) res.perPlayerHz.push(p.snapsMeasured / mSecs); }
  for (const p of players) { p.ended = true; (p.timers || []).forEach(clearInterval); try { p.ws.close(1000, 'bye'); } catch (e) {} }
  await sleep(300);
  res.mSecs = mSecs;
  res.loop = { p50: +(el.percentile(50) / 1e6).toFixed(1), p99: +(el.percentile(99) / 1e6).toFixed(1), max: +(el.max / 1e6).toFixed(1) };
  return res;
}

function merge(parts) {
  const out = { rtt: [], snapAge: [], srvGap: [], snaps: 0, joins: 0, failedJoins: 0, disconnects: 0, kicks: {}, corrections: {}, errors: {}, bytesIn: 0, msgsOut: 0, joinMs: [], perPlayerHz: [], loops: [], mSecs: 0 };
  for (const r of parts) {
    for (const k of ['rtt', 'snapAge', 'srvGap', 'joinMs', 'perPlayerHz']) for (const x of r[k]) out[k].push(x);
    for (const k of ['snaps', 'joins', 'failedJoins', 'disconnects', 'bytesIn', 'msgsOut']) out[k] += r[k];
    for (const k of ['kicks', 'corrections', 'errors']) for (const [c, n] of Object.entries(r[k])) out[k][c] = (out[k][c] || 0) + n;
    out.loops.push(r.loop); out.mSecs = Math.max(out.mSecs, r.mSecs);
  }
  return out;
}

function report(o, m) {
  return {
    players: o.players, roomSize: o['room-size'], rooms: Math.ceil(o.players / o['room-size']), procs: o.procs, seconds: +m.mSecs.toFixed(1),
    joins: m.joins, failedJoins: m.failedJoins, disconnects: m.disconnects, kicks: m.kicks, errors: m.errors, corrections: m.corrections,
    rtt: summary(m.rtt), snapAge: summary(m.snapAge), srvGap: summary(m.srvGap),
    snapHzPerPlayer: { mean: m.perPlayerHz.length ? +(m.perPlayerHz.reduce((a, b) => a + b, 0) / m.perPlayerHz.length).toFixed(2) : 0, min: m.perPlayerHz.length ? +m.perPlayerHz.reduce((a, b) => (b < a ? b : a), Infinity).toFixed(2) : 0 },
    joinMs: summary(m.joinMs),
    inKBps: +(m.bytesIn / 1024 / m.mSecs).toFixed(1), outMsgsPerSec: +(m.msgsOut / m.mSecs).toFixed(0),
    loadgenLoopDelayMs: m.loops,
  };
}

async function main() {
  if (process.send && process.env.BP_CHILD) {
    process.on('message', async (o) => { const r = await runChild(o); process.send(r, () => process.exit(0)); });
    return;
  }
  const o = args();
  const rs = o['room-size'];
  const per = Math.ceil(o.players / o.procs / rs) * rs;
  const jobs = [];
  for (let k = 0; k < o.procs; k++) {
    const n = Math.min(per, o.players - k * per);
    if (n <= 0) break;
    // Keep each child's players in whole rooms so rooms fill to room-size.
    const sub = Object.assign({}, o, { players: n, offset: k * per });
    jobs.push(new Promise((resolve) => {
      const c = fork(__filename, [], { env: Object.assign({}, process.env, { BP_CHILD: '1' }) });
      c.on('message', resolve);
      c.send(sub);
    }));
  }
  const parts = await Promise.all(jobs);
  const rep = report(o, merge(parts));
  const text = JSON.stringify(rep);
  if (o.out) require('fs').writeFileSync(o.out, text + '\n');
  console.log(text);
}
main();
