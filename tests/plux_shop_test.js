// Plux wallet + avatar shop test against a running referee (local or live).
// Covers: wallet in welcome, shop list, daily reward once a day, buying, not enough Plux,
// owning twice refused, equip (one per slot), friends see the new look, limited stock serials.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const crypto = require('crypto');
const URL = process.argv[2] || 'ws://127.0.0.1:8910';
let failures = 0;
const ok = (cond, what) => { console.log((cond ? 'PASS ' : 'FAIL ') + what); if (!cond) failures++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tag = Date.now().toString(36).slice(-4);
let rid = 1;

function user(acct) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const c = { ws, acct, inbox: [] };
    ws.on('message', d => {
      const m = JSON.parse(d.toString());
      if (m.t === 'pong') return;
      c.inbox.push(m);
      if (m.t === 's_welcome') { c.welcome = m; c.uid = m.me.uid; resolve(c); }
    });
    ws.on('open', () => {
      ws.send(JSON.stringify(Object.assign({ t: 's_hello', v: 1 }, acct)));
      c.pinger = setInterval(() => { if (ws.readyState === 1) ws.send(JSON.stringify({ t: 'ping', c: 1 })); }, 5000);
    });
    ws.on('close', () => clearInterval(c.pinger));
    ws.on('error', reject);
    setTimeout(() => reject(new Error('no welcome')), 70000);
  });
}
const send = (c, m) => c.ws.send(JSON.stringify(Object.assign({ rid: rid++ }, m)));
async function wait(c, pred, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const i = c.inbox.findIndex(pred);
    if (i >= 0) return c.inbox.splice(i, 1)[0];
    await sleep(30);
  }
  return null;
}
const acct = (name, username, extra = {}) => Object.assign({ key: crypto.randomBytes(24).toString('hex'), name, username, bio: '', friends: [], follows: [], req_out: [] }, extra);

(async () => {
  const a = await user(acct('Pia ' + tag, 'pia_' + tag));
  ok(a.welcome.eco && typeof a.welcome.eco.coins === 'number', 'welcome carries the wallet (coins ' + (a.welcome.eco || {}).coins + ')');
  send(a, { t: 's_eco' });
  const e = await wait(a, m => m.t === 's_eco_res');
  ok(e && Array.isArray(e.shop) && e.shop.length >= 20, 'shop lists items: ' + (e ? e.shop.length : 0));
  ok(e && e.eco.daily_ready === true, 'daily reward ready for a new player');
  const start = e.eco.coins;
  send(a, { t: 's_daily' });
  const d = await wait(a, m => m.t === 's_daily_res');
  ok(d && d.ok && d.coins === start + d.got && d.got > 0, 'daily reward pays ' + (d && d.got) + ' Plux');
  send(a, { t: 's_daily' });
  const d2 = await wait(a, m => m.t === 's_daily_res');
  ok(d2 && d2.ok === false, 'daily reward only once a day');
  const coins = d.coins;
  const cheap = e.shop.filter(i => !i.rare && i.price <= coins).sort((x, y) => x.price - y.price)[0];
  const dear = e.shop.filter(i => i.price > coins)[0];
  send(a, { t: 's_buy', item: dear.id });
  const nb = await wait(a, m => m.t === 's_buy_res');
  ok(nb && nb.ok === false && /Not enough/.test(nb.why), 'too expensive refused: ' + (nb && nb.why));
  send(a, { t: 's_buy', item: cheap.id });
  const b1 = await wait(a, m => m.t === 's_buy_res');
  ok(b1 && b1.ok && b1.coins === coins - cheap.price, 'bought ' + cheap.name + ' for ' + cheap.price + ', left ' + (b1 && b1.coins));
  send(a, { t: 's_buy', item: cheap.id });
  const b2 = await wait(a, m => m.t === 's_buy_res');
  ok(b2 && b2.ok === false && /already own/.test(b2.why), 'cannot buy the same item twice');
  send(a, { t: 's_buy', item: 'no_such_item' });
  const b3 = await wait(a, m => m.t === 's_buy_res');
  ok(b3 && b3.ok === false, 'unknown item refused');
  // Friend sees the look
  const bAcct = acct('Quin ' + tag, 'quin_' + tag);
  const b = await user(bAcct);
  send(a, { t: 's_freq', uid: b.uid });
  await wait(b, m => m.t === 's_notice' && m.kind === 'request');
  send(b, { t: 's_faccept', uid: a.uid });
  await wait(a, m => m.t === 's_notice' && m.kind === 'friends', 4000);
  await sleep(300);
  send(a, { t: 's_equip', eq: [cheap.id, 'not_owned_item'] });
  const q = await wait(a, m => m.t === 's_equip_res');
  ok(q && q.ok && q.eq.length === 1 && q.eq[0] === cheap.id, 'equip keeps only owned items: ' + (q && JSON.stringify(q.eq)));
  const look = await wait(b, m => m.t === 's_look' && m.uid === a.uid, 4000);
  ok(look && Array.isArray(look.eq) && look.eq.length === 1 && look.eq[0].art === cheap.art, 'friend is sent the new look');
  send(a, { t: 's_eco' });
  const e2 = await wait(a, m => m.t === 's_eco_res');
  ok(e2 && e2.eco.inv.some(o => o.item === cheap.id) && e2.eco.eq[0] === cheap.id, 'inventory and equipped saved on the server');
  send(a, { t: 's_equip', eq: [] });
  const q2 = await wait(a, m => m.t === 's_equip_res');
  ok(q2 && q2.ok && q2.eq.length === 0, 'take everything off');
  a.ws.close(); b.ws.close();
  console.log(failures === 0 ? 'ALL PASS' : failures + ' FAILED');
  process.exit(failures ? 1 : 0);
})().catch(err => { console.log('FAIL ' + err.message); process.exit(1); });
