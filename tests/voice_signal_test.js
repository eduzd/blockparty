// Voice signalling test against a local headless referee.
// Checks: welcome carries ICE servers; vjoin/vpeers; offer/answer/ICE relay with
// the server stamping "from"; no relay across rooms or to non-voice players;
// oversized SDP rejected; vleave broadcast on disconnect.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const URL = process.argv[2] || 'ws://127.0.0.1:7777';
const VERSION = parseInt(process.argv[3] || '1');
let failures = 0;
const ok = (cond, what) => { console.log((cond ? 'PASS ' : 'FAIL ') + what); if (!cond) failures++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));

function client(name, room) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const c = { ws, name, inbox: [], id: null, welcome: null, closed: false };
    ws.on('message', d => {
      const m = JSON.parse(d.toString());
      if (m.t === 'welcome') { c.id = m.id; c.welcome = m; resolve(c); }
      if (m.t !== 'snap' && m.t !== 'pong' && m.t !== 'balls') c.inbox.push(m);
    });
    ws.on('open', () => ws.send(JSON.stringify({ t: 'hello', v: VERSION, name, room })));
    ws.on('close', () => { c.closed = true; });
    ws.on('error', reject);
    setTimeout(() => reject(new Error('no welcome for ' + name)), 5000);
  });
}
const send = (c, m) => c.ws.send(JSON.stringify(m));
const take = (c, pred) => { const i = c.inbox.findIndex(pred); return i < 0 ? null : c.inbox.splice(i, 1)[0]; };

(async () => {
  const a = await client('Ana', 'TEST1');
  const b = await client('Ben', 'TEST1');
  const x = await client('Xan', 'OTHER');
  ok(a.welcome.voice && Array.isArray(a.welcome.voice.ice) && a.welcome.voice.ice.length > 0, 'welcome has ICE servers: ' + JSON.stringify(a.welcome.voice && a.welcome.voice.ice));
  ok(JSON.stringify(a.welcome.voice.talkers) === '[]', 'no talkers at start');

  send(a, { t: 'vjoin' });
  await sleep(300);
  const p1 = take(a, m => m.t === 'vpeers');
  ok(p1 && p1.ids.length === 0, 'first talker gets empty vpeers');
  ok(take(b, m => m.t === 'vjoin' && m.id === a.id), 'room mate told Ana joined voice');
  ok(!take(x, m => m.t === 'vjoin'), 'other room not told');

  // Ben not in voice yet: signals to him are dropped.
  send(a, { t: 'vsig', to: b.id, k: 'offer', sdp: 'v=0 early' });
  await sleep(200);
  ok(!take(b, m => m.t === 'vsig'), 'no signal relayed to a player not in voice');

  send(b, { t: 'vjoin' });
  await sleep(300);
  const p2 = take(b, m => m.t === 'vpeers');
  ok(p2 && p2.ids.length === 1 && p2.ids[0] === a.id, 'second talker told to call Ana');

  const sdp = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n' + 'a=x\r\n'.repeat(400);  // ~2.4 KB, like a real offer
  send(b, { t: 'vsig', to: a.id, k: 'offer', sdp, from: 999 });
  send(a, { t: 'vsig', to: b.id, k: 'answer', sdp: 'v=0 answer' });
  send(b, { t: 'vsig', to: a.id, k: 'ice', mid: '0', idx: 0, cand: 'candidate:1 1 udp 2122260223 192.168.1.5 50000 typ host' });
  send(b, { t: 'vsig', to: x.id, k: 'offer', sdp: 'v=0 cross-room' });
  await sleep(400);
  const off = take(a, m => m.t === 'vsig' && m.k === 'offer');
  ok(off && off.from === b.id && off.sdp === sdp, 'offer relayed whole (' + sdp.length + ' chars), from stamped by server (not spoofed 999)');
  ok(take(b, m => m.t === 'vsig' && m.k === 'answer' && m.from === a.id), 'answer relayed back');
  const ice = take(a, m => m.t === 'vsig' && m.k === 'ice');
  ok(ice && ice.mid === '0' && ice.idx === 0 && ice.cand.startsWith('candidate:'), 'ICE candidate relayed');
  ok(!take(x, m => m.t === 'vsig'), 'signal to another room dropped');

  const late = await client('Lia', 'TEST1');
  ok(JSON.stringify(late.welcome.voice.talkers.sort()) === JSON.stringify([a.id, b.id].sort()), 'late joiner sees who is in voice');

  // ICE burst of 40 within a second must not trip the limit.
  for (let i = 0; i < 40; i++) send(b, { t: 'vsig', to: a.id, k: 'ice', mid: '0', idx: 0, cand: 'candidate:' + i + ' 1 udp 1 10.0.0.1 ' + (5000 + i) + ' typ host' });
  await sleep(400);
  ok(!b.closed && a.inbox.filter(m => m.t === 'vsig' && m.k === 'ice').length === 40, 'burst of 40 ICE candidates relayed, sender not kicked');
  a.inbox = a.inbox.filter(m => !(m.t === 'vsig'));

  send(a, { t: 'vleave' });
  await sleep(250);
  ok(take(b, m => m.t === 'vleave' && m.id === a.id), 'vleave broadcast when Ana turns voice off');
  send(b, { t: 'vsig', to: a.id, k: 'offer', sdp: 'v=0 after leave' });
  await sleep(200);
  ok(!take(a, m => m.t === 'vsig'), 'no signals to Ana after she left voice');

  send(a, { t: 'vjoin' });
  await sleep(250);
  take(b, m => m.t === 'vjoin');
  b.ws.close();
  await sleep(500);
  ok(take(a, m => m.t === 'vleave' && m.id === b.id), 'disconnect sends vleave to the room');
  ok(take(a, m => m.t === 'leave' && m.id === b.id), 'and the normal leave');

  const big = 'v=0' + 'x'.repeat(7500);
  send(a, { t: 'vsig', to: late.id, k: 'offer', sdp: big });
  await sleep(300);
  ok(!take(late, m => m.t === 'vsig'), 'oversized SDP not relayed');

  // A non-voice message over 1 KB is still refused (kick), as before.
  const c2 = await client('Max', 'TEST1');
  send(c2, { t: 'state', pad: 'y'.repeat(2000) });
  await sleep(2000);
  ok(c2.closed || c2.inbox.some(m => m.t === 'error' && m.code === 'too_big' && m.fatal), 'oversized game message still refused (fatal too_big)');

  for (const c of [a, x, late]) c.ws.close();
  console.log(failures === 0 ? 'ALL PASS' : failures + ' FAILED');
  process.exit(failures ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
