// Trading test (0.7.0) against a running server.
//   node trade_test.js <url> [a|b]
// a (default): offers, accept, decline, cancel, stale offers, races, limited items (with ADMIN_PW),
//              then saves the two players' keys and expected wallets to /tmp/trade_state.json.
// b:           run after a server restart: Plux balances, owned copies (same oids and serials),
//              equipped items and trade history must all come back from the database.
// Set NEON_DATABASE_URL to also check the rows in the database after the trades.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const crypto = require('crypto');
const fs = require('fs');
const URL = process.argv[2] || 'ws://127.0.0.1:8910';
const PHASE = process.argv[3] || 'a';
const ADMIN_PW = process.env.ADMIN_PW || '';
const STATE = process.env.TRADE_STATE || '/tmp/trade_state.json';
let failures = 0, passes = 0;
const ok = (cond, what) => { console.log((cond ? 'PASS ' : 'FAIL ') + what); if (!cond) failures++; else passes++; };
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
    setTimeout(() => reject(new Error('no welcome')), 90000);
  });
}
function admin() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const c = { ws, inbox: [] };
    ws.on('message', d => { const m = JSON.parse(d.toString()); if (m.t !== 'pong') c.inbox.push(m); });
    ws.on('open', () => resolve(c));
    ws.on('error', reject);
  });
}
const send = (c, m) => { const r = rid++; c.ws.send(JSON.stringify(Object.assign({ rid: r }, m))); return r; };
async function wait(c, pred, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const i = c.inbox.findIndex(pred);
    if (i >= 0) return c.inbox.splice(i, 1)[0];
    await sleep(30);
  }
  return null;
}
async function ask(c, m, t, ms) { const r = send(c, m); return wait(c, x => x.t === t && x.rid === r, ms); }
const acct = (name, username) => ({ key: crypto.randomBytes(24).toString('hex'), name, username, bio: '', friends: [], follows: [], req_out: [] });
async function eco(c) { const e = await ask(c, { t: 's_eco' }, 's_eco_res'); return e.eco; }
const invMap = e => Object.fromEntries(e.inv.map(i => [i.oid, i.item + '#' + i.serial]));
async function buy(c, item) { const r = await ask(c, { t: 's_buy', item }, 's_buy_res'); if (!r || !r.ok) throw new Error('buy ' + item + ' failed: ' + JSON.stringify(r)); return r.oid; }

async function phaseA() {
  const A = acct('Tara ' + tag, 'tara_' + tag), B = acct('Uli ' + tag, 'uli_' + tag), C = acct('Vic ' + tag, 'vic_' + tag);
  const a = await user(A), b = await user(B), c = await user(C);
  for (const p of [a, b]) await ask(p, { t: 's_daily' }, 's_daily_res');
  // a: blush 30 + glasses 50 + cap 40 = 120 of 150. b: cap 40 + shades 60 = 100 of 150.
  const aBlush = await buy(a, 'blush'), aGlasses = await buy(a, 'glasses'), aCap = await buy(a, 'cap_sky');
  const bCap = await buy(b, 'cap_sky'), bShades = await buy(b, 'shades');
  await ask(a, { t: 's_equip', eq: ['blush', 'cap_sky'] }, 's_equip_res');

  // Not friends yet
  let r = await ask(a, { t: 's_inv', w: b.uid }, 's_inv_res');
  ok(r && r.ok === false, 'cannot see the items of someone who is not a friend');
  r = await ask(a, { t: 's_trade_offer', to: b.uid, give: [aBlush], get: [bShades] }, 's_trade_res');
  ok(r && r.ok === false && /friends/.test(r.why), 'cannot offer a trade to a non-friend: ' + (r && r.why));

  send(a, { t: 's_freq', uid: b.uid });
  await wait(b, m => m.t === 's_notice' && m.kind === 'request');
  send(b, { t: 's_faccept', uid: a.uid });
  await wait(a, m => m.t === 's_notice' && m.kind === 'friends', 5000);
  await sleep(300);

  r = await ask(a, { t: 's_inv', w: b.uid }, 's_inv_res');
  ok(r && r.ok && r.items.length === 2 && r.items.every(i => i.name && i.oid), 'a friend\'s items are listed (' + (r && r.items.length) + ')');

  // Bad offers
  r = await ask(a, { t: 's_trade_offer', to: b.uid, give: [bShades], get: [] }, 's_trade_res');
  ok(r && r.ok === false, 'cannot offer an item you do not own');
  r = await ask(a, { t: 's_trade_offer', to: b.uid, give: [aCap], get: [bShades] }, 's_trade_res');
  ok(r && r.ok === false && /already has/.test(r.why), 'cannot give someone a duplicate: ' + (r && r.why));
  r = await ask(a, { t: 's_trade_offer', to: b.uid, give: [aBlush], get: [], cg: 999999 }, 's_trade_res');
  ok(r && r.ok === false && /Plux/.test(r.why), 'cannot offer more Plux than you have');
  r = await ask(a, { t: 's_trade_offer', to: b.uid, give: [aBlush, aBlush], get: [] }, 's_trade_res');
  ok(r && r.ok === false, 'the same copy twice in one offer is refused');
  r = await ask(a, { t: 's_trade_offer', to: b.uid, give: [], get: [] }, 's_trade_res');
  ok(r && r.ok === false, 'an empty offer is refused');

  // Good offer: a gives Rosy Cheeks (worn) + 10 Plux for b's Cool Shades.
  const ea0 = await eco(a), eb0 = await eco(b);
  r = await ask(a, { t: 's_trade_offer', to: b.uid, give: [aBlush], get: [bShades], cg: 10 }, 's_trade_res');
  ok(r && r.ok && r.trade.status === 'open', 'offer sent');
  const t1 = r && r.trade.id;
  const nb = await wait(b, m => m.t === 's_trade_new' && m.trade.id === t1);
  ok(nb && nb.trade.give[0].name === 'Rosy Cheeks' && nb.trade.get[0].name === 'Cool Shades' && nb.trade.cg === 10, 'the friend is told straight away, with both sides shown');
  r = await ask(b, { t: 's_trades' }, 's_trades_res');
  ok(r && r.trades.some(t => t.id === t1 && t.status === 'open' && !t.mine), 'the offer is in the friend\'s trade list');
  r = await ask(a, { t: 's_trade_accept', id: t1 }, 's_trade_res');
  ok(r && r.ok === false, 'the sender cannot accept their own offer');
  r = await ask(b, { t: 's_trade_accept', id: t1 }, 's_trade_res');
  ok(r && r.ok && r.trade.status === 'done', 'friend accepts: trade done');
  const ua = await wait(a, m => m.t === 's_trade_upd' && m.trade.id === t1);
  ok(ua && ua.trade.status === 'done' && ua.eco, 'the sender hears it went through, with the new wallet');
  const ea1 = await eco(a), eb1 = await eco(b);
  const ma = invMap(ea1), mb = invMap(eb1);
  ok(ma[bShades] && !ma[aBlush] && mb[aBlush] && !mb[bShades], 'the exact copies swapped owners');
  ok(ea1.inv.length === ea0.inv.length && eb1.inv.length === eb0.inv.length, 'nobody gained or lost an item count (' + ea1.inv.length + ', ' + eb1.inv.length + ')');
  ok(ea1.coins === ea0.coins - 10 && eb1.coins === eb0.coins + 10, 'exactly 10 Plux moved (' + ea0.coins + '->' + ea1.coins + ', ' + eb0.coins + '->' + eb1.coins + ')');
  ok(!ea1.eq.includes('blush') && ea1.eq.includes('cap_sky'), 'the traded item is taken off, the rest stays on');
  r = await ask(b, { t: 's_trade_accept', id: t1 }, 's_trade_res');
  ok(r && r.ok === false, 'a finished trade cannot be accepted again');

  // Decline and cancel
  r = await ask(a, { t: 's_trade_offer', to: b.uid, give: [aGlasses], get: [] }, 's_trade_res');
  const t2 = r.trade.id;
  r = await ask(b, { t: 's_trade_decline', id: t2 }, 's_trade_res');
  ok(r && r.ok && r.trade.status === 'declined', 'friend can decline');
  ok(!!(await wait(a, m => m.t === 's_trade_upd' && m.trade.id === t2 && m.trade.status === 'declined')), 'the sender is told it was declined');
  r = await ask(a, { t: 's_trade_offer', to: b.uid, give: [aGlasses], get: [] }, 's_trade_res');
  const t3 = r.trade.id;
  r = await ask(a, { t: 's_trade_cancel', id: t3 }, 's_trade_res');
  ok(r && r.ok && r.trade.status === 'cancelled', 'sender can cancel');
  r = await ask(b, { t: 's_trade_accept', id: t3 }, 's_trade_res');
  ok(r && r.ok === false, 'a cancelled offer cannot be accepted');

  // Two offers using the same copy: the first accepted wins, the other closes itself.
  const o1 = (await ask(a, { t: 's_trade_offer', to: b.uid, give: [aGlasses], get: [] }, 's_trade_res')).trade.id;
  const o2 = (await ask(a, { t: 's_trade_offer', to: b.uid, give: [aGlasses], get: [aBlush] }, 's_trade_res')).trade.id;
  // Race: b accepts both at the same moment.
  const r1 = send(b, { t: 's_trade_accept', id: o1 }), r2 = send(b, { t: 's_trade_accept', id: o2 });
  const x1 = await wait(b, m => m.t === 's_trade_res' && m.rid === r1), x2 = await wait(b, m => m.t === 's_trade_res' && m.rid === r2);
  ok(x1 && x2 && (x1.ok ? 1 : 0) + (x2.ok ? 1 : 0) === 1, 'two offers for the same copy accepted at once: exactly one goes through');
  const ea2 = await eco(a), eb2 = await eco(b);
  const glassesCount = [...ea2.inv, ...eb2.inv].filter(i => i.oid === aGlasses).length;
  ok(glassesCount === 1 && invMap(eb2)[aGlasses], 'the copy exists exactly once, with the friend');

  // Race: cancel and accept at the same moment.
  const o3 = (await ask(b, { t: 's_trade_offer', to: a.uid, give: [aGlasses], get: [] }, 's_trade_res')).trade.id;
  const rc = send(b, { t: 's_trade_cancel', id: o3 }), ra = send(a, { t: 's_trade_accept', id: o3 });
  const yc = await wait(b, m => m.t === 's_trade_res' && m.rid === rc), ya = await wait(a, m => m.t === 's_trade_res' && m.rid === ra);
  ok(yc && ya && (yc.ok ? 1 : 0) + (ya.ok ? 1 : 0) === 1, 'cancel and accept at the same moment: exactly one wins');
  const ea3 = await eco(a), eb3 = await eco(b);
  ok([...ea3.inv, ...eb3.inv].filter(i => i.oid === aGlasses).length === 1, 'still exactly one copy after that race');

  // Plux the other way: b asks for Plux it then spends before a accepts -> refused, nothing moves.
  aHas = new Set(ea3.inv.map(i => i.item));
  const ebBefore = (await eco(b)).coins;
  const askPlux = Math.max(1, ebBefore);
  const o4 = (await ask(a, { t: 's_trade_offer', to: b.uid, give: [], get: [mbFirst(eb3)], cw: 0, cg: 0 }, 's_trade_res'));
  ok(o4 && o4.ok, 'offer asking for an item, giving nothing, is allowed (a gift request)');
  r = await ask(b, { t: 's_trade_offer', to: a.uid, give: [mbFirst(eb3)], get: [], cw: ea3.coins + 1 }, 's_trade_res');
  ok(r && r.ok === false && /much Plux/.test(r.why), 'cannot ask for more Plux than the friend has');
  if (o4 && o4.ok) await ask(a, { t: 's_trade_cancel', id: o4.trade.id }, 's_trade_res');

  // Limited items trade with their serial (needs the admin password to fund the buyer).
  let limited = null;
  if (ADMIN_PW) {
    const ad = await admin();
    const li = await ask(ad, { t: 'a_login', pw: ADMIN_PW }, 'a_login_res', 90000);
    ok(li && li.ok, 'admin signs in for the limited-item part');
    const testId = 'test_ltd_' + tag;
    await ask(ad, { t: 'a_item_save', item: { id: testId, name: 'Test Limited ' + tag, slot: 'hat', art: 'crown', col: '#FFC107', price: 5, rare: true, stock: 2 } }, 'a_ok');
    await ask(ad, { t: 'a_plux', uid: c.uid, delta: 5, reason: 'trade test' }, 'a_ok');
    send(c, { t: 's_eco' }); await wait(c, m => m.t === 's_eco_res');
    const cBuy = await ask(c, { t: 's_buy', item: testId }, 's_buy_res');
    ok(cBuy && cBuy.ok && cBuy.serial >= 1, 'a limited copy is bought with serial #' + (cBuy && cBuy.serial));
    send(c, { t: 's_freq', uid: a.uid });
    await wait(a, m => m.t === 's_notice' && m.kind === 'request');
    send(a, { t: 's_faccept', uid: c.uid });
    await wait(c, m => m.t === 's_notice' && m.kind === 'friends', 5000);
    await sleep(300);
    const lo = await ask(c, { t: 's_trade_offer', to: a.uid, give: [cBuy.oid], get: [] }, 's_trade_res');
    ok(lo && lo.ok && lo.trade.give[0].rare === true && lo.trade.give[0].serial === cBuy.serial, 'a limited item can be offered, its number shown');
    const la = await ask(a, { t: 's_trade_accept', id: lo.trade.id }, 's_trade_res');
    const eaL = await eco(a), ecL = await eco(c);
    ok(la && la.ok && eaL.inv.some(i => i.oid === cBuy.oid && i.serial === cBuy.serial) && !ecL.inv.some(i => i.oid === cBuy.oid), 'the limited copy moved with the same number #' + cBuy.serial);
    // Hide the test item again so it doesn't sit in the shop.
    await ask(ad, { t: 'a_item_save', item: { id: testId, name: 'Test Limited ' + tag, slot: 'hat', art: 'crown', col: '#FFC107', price: 5, rare: true, stock: 2, hidden: true } }, 'a_ok');
    const at = await ask(ad, { t: 'a_trades', q: 'tara_' + tag }, 'a_trades_res');
    ok(at && at.trades.length >= 3, 'the admin app sees this player\'s trades (' + (at && at.trades.length) + ')');
    limited = { oid: cBuy.oid, serial: cBuy.serial };
    ad.ws.close();
  } else console.log('SKIP limited-item part (set ADMIN_PW)');

  const finA = await eco(a), finB = await eco(b);
  // Database check: every copy has exactly one row, with the right owner.
  if (process.env.NEON_DATABASE_URL) {
    await sleep(4000);
    const { execFileSync } = require('child_process');
    const oids = [...finA.inv, ...finB.inv].map(i => i.oid);
    const out = execFileSync('node', [__dirname + '/neon_query.js', "select oid, uid from plox_owned where oid in ('" + oids.join("','") + "')"]).toString();
    const rows = JSON.parse(out.slice(out.indexOf(' ') + 1));
    const want = Object.fromEntries([...finA.inv.map(i => [i.oid, a.uid]), ...finB.inv.map(i => [i.oid, b.uid])]);
    ok(rows.length === oids.length && rows.every(rw => want[rw.oid] === rw.uid), 'database: each copy has exactly one row with the right owner (' + rows.length + '/' + oids.length + ')');
    const w = JSON.parse((s => s.slice(s.indexOf(' ') + 1))(execFileSync('node', [__dirname + '/neon_query.js', "select uid, coins from plox_wallet where uid in ('" + a.uid + "','" + b.uid + "')"]).toString()));
    const wc = Object.fromEntries(w.map(x => [x.uid, Number(x.coins)]));
    ok(wc[a.uid] === finA.coins && wc[b.uid] === finB.coins, 'database: Plux balances match the server (' + wc[a.uid] + ', ' + wc[b.uid] + ')');
  }
  fs.writeFileSync(STATE, JSON.stringify({ A, B, a: { coins: finA.coins, inv: invMap(finA), eq: finA.eq }, b: { coins: finB.coins, inv: invMap(finB), eq: finB.eq }, t1, limited }));
  for (const p of [a, b, c]) p.ws.close();
}
let aHas = new Set();
function mbFirst(e) { const x = e.inv.find(i => !aHas.has(i.item)); return x && x.oid; }

async function phaseB() {
  const st = JSON.parse(fs.readFileSync(STATE));
  const a = await user(st.A), b = await user(st.B);
  const ea = await eco(a), eb = await eco(b);
  ok(ea.coins === st.a.coins && eb.coins === st.b.coins, 'after restart: Plux balances came back (' + ea.coins + '/' + st.a.coins + ', ' + eb.coins + '/' + st.b.coins + ')');
  ok(JSON.stringify(invMap(ea)) === JSON.stringify(st.a.inv), 'after restart: player 1 owns the same copies with the same numbers (' + ea.inv.length + ')');
  ok(JSON.stringify(invMap(eb)) === JSON.stringify(st.b.inv), 'after restart: player 2 owns the same copies with the same numbers (' + eb.inv.length + ')');
  ok(JSON.stringify(ea.eq) === JSON.stringify(st.a.eq), 'after restart: equipped items came back');
  const tl = await ask(a, { t: 's_trades' }, 's_trades_res');
  ok(tl && tl.trades.some(t => t.id === st.t1 && t.status === 'done'), 'after restart: the finished trade is still in the history');
  if (st.limited) ok(ea.inv.some(i => i.oid === st.limited.oid && i.serial === st.limited.serial), 'after restart: the traded limited copy keeps its number #' + st.limited.serial);
  for (const p of [a, b]) p.ws.close();
}

(async () => {
  try { await (PHASE === 'b' ? phaseB() : phaseA()); }
  catch (e) { console.log('FAIL crashed: ' + e.message); failures++; }
  console.log(failures ? `FAILED ${failures} (passed ${passes})` : `ALL PASSED (${passes})`);
  process.exit(failures ? 1 : 0);
})();
