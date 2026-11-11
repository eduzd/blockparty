// Plux + items survive a server restart. Phase 'a' makes an account, collects the daily
// reward, buys and wears an item, saves the account key; restart the server; phase 'b'
// logs back in with the same key and checks the balance, inventory and worn items.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const crypto = require('crypto');
const fs = require('fs');
const URL = process.argv[2] || 'ws://127.0.0.1:9300';
const PHASE = process.argv[3] || 'a';
const FILE = '/tmp/eco_persist_' + (process.argv[4] || 'local') + '.json';
let failures = 0;
const ok = (cond, what) => { console.log((cond ? 'PASS ' : 'FAIL ') + what); if (!cond) failures++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
let rid = 1;
function user(acct) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const c = { ws, inbox: [] };
    ws.on('message', d => { const m = JSON.parse(d.toString()); if (m.t === 'pong') return; c.inbox.push(m); if (m.t === 's_welcome') { c.welcome = m; c.uid = m.me.uid; resolve(c); } });
    ws.on('open', () => ws.send(JSON.stringify(Object.assign({ t: 's_hello', v: 1 }, acct))));
    ws.on('error', reject);
    setTimeout(() => reject(new Error('no welcome')), 90000);
  });
}
const send = (c, m) => c.ws.send(JSON.stringify(Object.assign({ rid: rid++ }, m)));
async function wait(c, pred, ms = 6000) { const end = Date.now() + ms; while (Date.now() < end) { const i = c.inbox.findIndex(pred); if (i >= 0) return c.inbox.splice(i, 1)[0]; await sleep(30); } return null; }
(async () => {
  if (PHASE === 'a') {
    const tag = Date.now().toString(36).slice(-5);
    const acct = { key: crypto.randomBytes(24).toString('hex'), name: 'Eco ' + tag, username: 'eco_' + tag, bio: '', friends: [], follows: [], req_out: [] };
    const a = await user(acct);
    send(a, { t: 's_eco' });
    const e = await wait(a, m => m.t === 's_eco_res');
    send(a, { t: 's_daily' });
    const d = await wait(a, m => m.t === 's_daily_res');
    ok(d && d.ok, 'daily reward collected');
    const coins = d.coins;
    const cheap = e.shop.filter(i => !i.rare && !i.pro && i.price <= coins).sort((x, y) => x.price - y.price)[0];
    send(a, { t: 's_buy', item: cheap.id });
    const b = await wait(a, m => m.t === 's_buy_res');
    ok(b && b.ok, 'bought ' + cheap.id);
    send(a, { t: 's_equip', eq: [cheap.id] });
    const q = await wait(a, m => m.t === 's_equip_res');
    ok(q && q.ok !== false, 'wearing ' + cheap.id);
    await sleep(2500); // let the database write land
    fs.writeFileSync(FILE, JSON.stringify({ acct, coins: b.coins, item: cheap.id, uid: a.uid }));
    console.log('saved: coins ' + b.coins + ', item ' + cheap.id);
    a.ws.close();
  } else {
    const s = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    const a = await user(s.acct);
    ok(a.uid === s.uid, 'same account after the restart');
    send(a, { t: 's_eco' });
    const e = await wait(a, m => m.t === 's_eco_res');
    ok(e && e.eco.coins === s.coins, 'Plux balance kept: ' + (e && e.eco.coins) + ' (was ' + s.coins + ')');
    ok(e && (e.eco.inv || []).some(x => (x.item || x.id || x) === s.item), 'bought item still owned');
    ok(e && (e.eco.eq || []).includes(s.item), 'item still worn');
    ok(e && e.eco.daily_ready === false, 'daily reward not handed out twice after the restart');
    a.ws.close();
  }
  console.log(failures ? failures + ' FAILED' : 'ALL PASSED');
  process.exit(failures ? 1 : 0);
})().catch(e => { console.log('FAIL crashed: ' + e.message); process.exit(1); });
