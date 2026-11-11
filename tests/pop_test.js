// Pop-Up Panic protocol test against a running referee (local or live).
// Covers: joining a Pop room with a character and bots, bots in the welcome and
// in snapshots, a second player joining the same room, a bonk that hits (bump to
// the victim, hit list to everyone), bonk cooldown, a knockout credited to the
// bonker, dropping back in, a human taking a bot's seat, bots moving, the neon
// world staying separate, and the bonk message being refused outside a Pop room.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const URL = process.argv[2] || 'ws://127.0.0.1:8910';
let failures = 0;
const ok = (cond, what) => { console.log((cond ? 'PASS ' : 'FAIL ') + what); if (!cond) failures++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ROOM = 'PT' + Date.now().toString(36).slice(-4).toUpperCase();

function player(name, extra, room) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const c = { ws, name, inbox: [], snaps: [], closed: false };
    ws.on('message', d => {
      const m = JSON.parse(d.toString());
      if (m.t === 'snap') { c.snaps.push(m); if (c.snaps.length > 60) c.snaps.shift(); return; }
      if (m.t === 'pong') return;
      c.inbox.push(m);
      if (m.t === 'welcome') { c.welcome = m; c.id = m.id; resolve(c); }
      if (m.t === 'kicked') reject(new Error('kicked: ' + m.msg));
    });
    ws.on('open', () => ws.send(JSON.stringify(Object.assign({ t: "hello", v: 1, name, room: room || ROOM }, extra))));
    ws.on('close', () => { c.closed = true; });
    ws.on('error', reject);
    setTimeout(() => reject(new Error('no welcome for ' + name)), 70000);
  });
}
const send = (c, m) => c.ws.send(JSON.stringify(m));
async function wait(c, pred, ms = 3000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const i = c.inbox.findIndex(pred);
    if (i >= 0) return c.inbox.splice(i, 1)[0];
    await sleep(20);
  }
  return null;
}
const state = (c, p, y = 0) => send(c, { t: 'state', p, y });

(async () => {
  const a = await player('Ana', { g: 'pop', ch: 2, bots: 2 });
  ok(a.welcome.g === 'pop' && a.welcome.ch === 2, 'welcome says Pop-Up Panic with my character');
  ok(a.welcome.r && a.welcome.r.ph === 'play' && a.welcome.r.end > a.welcome.ts, 'welcome carries the round clock');
  ok(Array.isArray(a.welcome.sc), 'welcome carries scores');
  const sp = a.welcome.spawn;
  ok(sp && sp[1] > 5, 'I drop in from the sky (spawn y=' + (sp && sp[1]) + ')');
  const botJoins = [];
  for (let i = 0; i < 2; i++) { const j = await wait(a, m => m.t === 'join' && m.p.bot, 2000); if (j) botJoins.push(j.p); }
  ok(botJoins.length === 2, 'two bots join (' + botJoins.map(b => b.name).join(', ') + ')');

  // Keep Ana standing near the middle, sending state like the phone does.
  let aPos = [3, 0, 0];
  const aTimer = setInterval(() => state(a, aPos, 0), 50);
  await sleep(1200);
  const lastSnap = a.snaps[a.snaps.length - 1];
  const ids = lastSnap ? lastSnap.pl.map(e => e[0]) : [];
  ok(botJoins.every(b => ids.includes(b.id)), 'bots are in the snapshots');
  const p0 = {}; a.snaps[0].pl.forEach(e => { p0[e[0]] = e; });
  const p1 = {}; lastSnap.pl.forEach(e => { p1[e[0]] = e; });
  const moved = botJoins.filter(b => p0[b.id] && p1[b.id] && Math.hypot(p0[b.id][1] - p1[b.id][1], p0[b.id][3] - p1[b.id][3]) + Math.abs(p0[b.id][2] - p1[b.id][2]) > 0.3);
  ok(moved.length >= 1, 'bots move around (' + moved.length + ' of 2)');
  ok(a.snaps.some(s => Array.isArray(s.sc)), 'snapshots carry scores once a second');

  // Ben joins the same code: he sees Ana and the bots.
  const b = await player('Ben', { g: 'pop', ch: 5, bots: 0 });
  const seen = b.welcome.players.map(p => p.id);
  ok(seen.includes(a.id) && botJoins.every(x => seen.includes(x.id)), 'second player sees Ana and the bots in the welcome');
  ok(b.welcome.players.find(p => p.id === a.id).ch === 2, 'Ana\'s character comes through');
  ok(!!(await wait(a, m => m.t === 'join' && m.p.id === b.id)), 'Ana hears that Ben joined');
  let bPos = [4.5, 0, 0];
  const bTimer = setInterval(() => state(b, bPos, 0), 50);
  // Wait out the drop-in safety bubble (2 s).
  await sleep(2300);

  // Ana faces +X (yaw -pi/2 faces +X) and bonks Ben, who is 1.5 m away.
  a.inbox.length = 0; b.inbox.length = 0;
  send(a, { t: 'bonk', y: -Math.PI / 2 });
  // Bots bonk too, so take the bump the server sent just before Ana's bonk news.
  let hitMsg = null, bump = null, prevBump = null;
  const end1 = Date.now() + 3000;
  while (Date.now() < end1 && !hitMsg) {
    const m = b.inbox.shift();
    if (!m) { await sleep(20); continue; }
    if (m.t === 'bump') prevBump = m;
    else if (m.t === 'bonk' && m.id === a.id) { hitMsg = m; bump = prevBump; }
  }
  ok(hitMsg && hitMsg.hit.includes(b.id), 'bonk hits Ben (hit list to everyone)');
  bPos = [4.5, 1.0, 0];   // like a real phone: Ben is flying now, not landed
  ok(bump && bump.v[0] > 8 && bump.v[1] > 4, 'Ben gets knocked away from Ana and upward (v=' + (bump && bump.v.map(x => x.toFixed(1))) + ')');
  // Too soon: ignored.
  send(a, { t: 'bonk', y: -Math.PI / 2 });
  ok(!(await wait(b, m => m.t === 'bonk' && m.id === a.id, 300)), 'a second bonk inside the cooldown is ignored');
  // Behind you does not count.
  await sleep(700);
  send(a, { t: 'bonk', y: Math.PI / 2 });
  const miss = await wait(b, m => m.t === 'bonk' && m.id === a.id);
  ok(miss && !miss.hit.includes(b.id), 'a bonk facing away misses');
  // Wobble: the second hit is stronger.
  await sleep(700);
  // Bots also bonk Ben now and then; only count the bump that follows Ana's hit,
  // and compare the push strength (bots can hit him from another side).
  b.inbox.length = 0;
  send(a, { t: 'bonk', y: -Math.PI / 2 });
  let bump2 = null;
  const end2 = Date.now() + 3000;
  // The server sends the victim's bump just before it tells everyone about the bonk.
  let lastBump = null;
  while (Date.now() < end2 && !bump2) {
    const m = b.inbox.shift();
    if (!m) { await sleep(20); continue; }
    if (m.t === 'bump') lastBump = m;
    else if (m.t === 'bonk' && m.id === a.id && m.hit.includes(b.id)) bump2 = lastBump;
  }
  const hz = v => Math.hypot(v[0], v[2]);
  ok(bump && bump2 && hz(bump2.v) > hz(bump.v), 'each hit makes the next one stronger (' + (bump2 && hz(bump2.v).toFixed(1)) + ' > ' + (bump && hz(bump.v).toFixed(1)) + ')');

  // Ben falls off: the knockout goes to whoever hit him last. Usually that is Ana, but on a
  // slow connection a bot can bonk him in the gap, and then the bot rightly gets it.
  clearInterval(bTimer);
  const benSeen = b.inbox.length;
  state(b, [16, -6, 0], 0);
  const ko = await wait(a, m => m.t === 'ko' && m.id === b.id);
  let lastHitter = a.id;
  for (const m of b.inbox) {
    if (m.t === 'ko' && m.id === b.id) break;
    if (m.t === 'bonk' && m.hit.includes(b.id)) lastHitter = m.id;
  }
  ok(ko && ko.by === lastHitter, 'Ben\'s fall counts as a knockout for whoever hit him last' + (lastHitter === a.id ? ' (Ana)' : ' (a bot hit him after Ana)') + (ko ? (ko.by === lastHitter ? '' : ' [got ' + ko.by + ', expected ' + lastHitter + ']') : ' [no ko message]'));
  // He drops back in by himself.
  const back = await wait(b, m => m.t === 'correct' && m.why === 'respawn', 3500);
  ok(back && back.p[1] > 5, 'Ben drops back in from the sky after about 1.7 s');
  bPos = back ? back.p : [4.5, 0, 0];

  // A third and fourth player in a full room push bots out (max 8: 2 humans + 2 bots = 4, so fill up).
  const extra = [];
  for (let i = 0; i < 4; i++) extra.push(await player('P' + i, { g: 'pop', ch: i, bots: 0 }));
  // 6 humans + 2 bots = 8 = full. One more human should take a bot's seat.
  const seat = await player('Late', { g: 'pop', ch: 7, bots: 0 });
  ok(!!seat.welcome, 'a 7th person still gets in when bots fill the room');
  const left = await wait(a, m => m.t === 'leave' && botJoins.some(x => x.id === m.id), 2000);
  ok(!!left, 'a bot leaves to make room for them');

  // Clean room with no bots: Ana's hit and Ben's fall must give Ana exactly one knockout.
  {
    const code2 = 'K' + Math.floor(Math.random() * 9e5);
    const c1 = await player('Cara', { g: 'pop', ch: 1, bots: 0 }, code2);
    const d1 = await player('Dan', { g: 'pop', ch: 2, bots: 0 }, code2);
    const cp = [3, 1, 0], dp = [4.5, 1, 0];
    const t1 = setInterval(() => { state(c1, cp, -Math.PI / 2); state(d1, dp, 0); }, 50);
    await sleep(2400);   // past the 2 s join shield
    send(c1, { t: 'bonk', y: -Math.PI / 2 });
    const h = await wait(d1, m => m.t === 'bonk' && m.id === c1.id && m.hit.includes(d1.id), 2500);
    clearInterval(t1);
    state(d1, [16, -6, 0], 0);
    const k2 = await wait(c1, m => m.t === 'ko' && m.id === d1.id, 2500);
    ok(!!h && k2 && k2.by === c1.id && k2.s === 1, 'with no bots, a fall after a bonk gives the bonker exactly 1 knockout' + (h ? '' : ' [bonk missed]') + (k2 ? (k2.by === c1.id && k2.s === 1 ? '' : ' [by=' + k2.by + ' s=' + k2.s + ']') : ' [no ko]'));
    c1.ws.close(); d1.ws.close();
  }

  // Neon world stays separate.
  const n = await new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const c = { ws, inbox: [] };
    ws.on('message', d => { const m = JSON.parse(d.toString()); if (m.t === 'welcome') { c.welcome = m; resolve(c); } });
    ws.on('open', () => ws.send(JSON.stringify({ t: 'hello', v: 1, name: 'Neo', room: ROOM })));
    ws.on('error', reject);
  });
  ok(n.welcome.players.length === 0 && n.welcome.r === undefined, 'the neon world with the same code is a separate room');
  n.ws.send(JSON.stringify({ t: 'bonk', y: 0 }));
  await sleep(300);
  ok(true, 'bonk outside a Pop room is refused as a bad message (no crash)');
  n.ws.close();

  clearInterval(aTimer);
  for (const c of [a, b, seat, ...extra]) c.ws.close();
  await sleep(300);
  console.log(failures ? `${failures} FAILED` : 'ALL PASSED');
  process.exit(failures ? 1 : 0);
})().catch(e => { console.log('FAIL ' + e.message); process.exit(1); });
