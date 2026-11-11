// 0.7.0 checks: sign-up, log-in, finishing old accounts, rate limits, Plux packs
// (sandbox), game rewards, invites and invite codes.
//   ADMIN_PW=... node account_pay_test.js <url>
// Puts every setting it changes back the way it found it.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const crypto = require('crypto');
const URL = process.argv[2] || 'ws://127.0.0.1:8910';
const ADMIN_PW = process.env.ADMIN_PW || '';
let failures = 0, passes = 0;
const ok = (c, w) => { console.log((c ? 'PASS ' : 'FAIL ') + w); if (c) passes++; else failures++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tag = Date.now().toString(36).slice(-5);
let rid = 1;

function conn() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const c = { ws, inbox: [] };
    ws.on('message', d => { const m = JSON.parse(d.toString()); if (m.t !== 'pong') c.inbox.push(m); });
    ws.on('open', () => { c.pinger = setInterval(() => ws.readyState === 1 && ws.send('{"t":"ping","c":1}'), 5000); resolve(c); });
    ws.on('close', () => { c.closed = true; clearInterval(c.pinger); });
    ws.on('error', reject);
  });
}
const send = (c, m) => { const r = rid++; c.ws.send(JSON.stringify(Object.assign({ rid: r }, m))); return r; };
async function wait(c, pred, ms = 6000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const i = c.inbox.findIndex(pred); if (i >= 0) return c.inbox.splice(i, 1)[0]; await sleep(25); }
  return null;
}
async function ask(c, m, t, ms = 90000) { const r = send(c, m); return wait(c, x => x.t === t && (x.rid === r || x.rid === undefined), ms); }
async function hello(c, extra) { send(c, Object.assign({ t: 's_hello', v: 1 }, extra)); return wait(c, m => m.t === 's_welcome' || m.t === 'error', 90000); }
async function eco(c) { return (await ask(c, { t: 's_eco' }, 's_eco_res')).eco; }

// Plux Pro: tiers, test-mode subscribe, allowance, perks, cancel, renew, admin grant/remove.
(async () => {
  let ad = null, saved = null;
  try {
    ad = await conn();
    const li = await ask(ad, { t: 'a_login', pw: ADMIN_PW }, 'a_login_res');
    ok(li && li.ok, 'admin signs in');
    const cfg = await ask(ad, { t: 'a_cfg_set', values: {} }, 'a_ok');
    saved = {}; for (const k of ['f_pro', 'pro_tiers', 'trade_pro_only', 'f_buy_plux', 'pay_mode', 'pay_testers', 'ai_per_day']) saved[k] = cfg.cfg[k];
    ok(cfg.cfg.f_pro === false || saved.f_pro !== undefined, 'Pro settings exist (f_pro=' + saved.f_pro + ')');
    const mk = async (n) => { const c = await conn(); const r = await ask(c, { t: 's_signup', username: n, password: 'secret12', birthday: '2000-02-02' }, 's_signup_res'); const w = await hello(c, { token: r.token }); return { c, uid: r.uid, w }; };
    const A = await mk('pro_a' + tag), B = await mk('pro_b' + tag);
    let r = await ask(A.c, { t: 's_pro' }, 's_pro_res');
    ok(r && r.tiers.length === 3 && !r.open && !r.me.active, 'Pro lists 3 tiers and is closed by default (' + (r && r.why) + ')');
    r = await ask(A.c, { t: 's_pay_start', pack: 'pro:pro450' }, 's_pay_start_res');
    ok(r && !r.ok, 'no Pro order while Pro is off');
    // bad tier list is refused
    let bad = await ask(ad, { t: 'a_cfg_set', values: { pro_tiers: '[{"id":"x","price":-1}]' } }, 'a_ok');
    const after = await ask(ad, { t: 'a_cfg_set', values: {} }, 'a_ok');
    ok(after.cfg.pro_tiers === saved.pro_tiers, 'a broken tier list is not saved');
    const tiers = JSON.stringify([{ id: 'pro450', name: 'Pro Test', price: 4.99, cur: 'USD', plux_month: 450, buy_bonus: 10, ai_extra: 7, outfits: 12 }]);
    await ask(ad, { t: 'a_cfg_set', values: { f_pro: true, f_buy_plux: true, pay_mode: 'sandbox', pay_testers: 'pro_a' + tag + ',pro_b' + tag, pro_tiers: tiers, trade_pro_only: true, ai_per_day: 5 } }, 'a_ok');
    r = await ask(A.c, { t: 's_pro' }, 's_pro_res');
    ok(r && r.open && r.sandbox && r.tiers[0].name === 'Pro Test', 'admin edits show up: one tier named Pro Test, open in test mode');
    const e0 = await eco(A.c);
    r = await ask(A.c, { t: 's_pay_start', pack: 'pro:pro450' }, 's_pay_start_res');
    ok(r && r.ok && r.order.test, 'a tester starts a test Pro order');
    const oid = r && r.order.id;
    let e1 = await eco(A.c);
    ok(!e1.pro.active, 'starting the order does not turn Pro on');
    r = await ask(A.c, { t: 's_pay_confirm', order: oid }, 's_pay_res');
    e1 = await eco(A.c);
    ok(r && r.ok && r.pro && r.pro.active && e1.coins === e0.coins + 450, 'after the server confirms the payment Pro is on and 450 Plux arrive (' + e0.coins + '->' + e1.coins + ')');
    const days = (e1.pro.until - Date.now() / 1000) / 86400;
    ok(days > 29.9 && days < 30.1, 'Pro lasts 30 days (' + days.toFixed(2) + ')');
    r = await ask(A.c, { t: 's_pro' }, 's_pro_res');
    const e2 = await eco(A.c);
    ok(e2.coins === e1.coins, 'the monthly allowance is not paid twice in a month');
    r = await ask(A.c, { t: 's_packs' }, 's_packs_res');
    ok(r && r.pro_bonus === 10, 'packs show the 10% Pro bonus');
    r = await ask(A.c, { t: 's_pay_start', pack: 'p400' }, 's_pay_start_res');
    ok(r && r.ok && r.order.plux === 400 + 40 + 40, 'a 400 pack gives Pro members 40 extra on top of the pack bonus (' + (r && r.order.plux) + ')');
    r = await ask(A.c, { t: 's_studio_mine' }, 's_studio_mine_res');
    const cardB = await ask(B.c, { t: 's_get', uid: A.uid }, 's_user');
    ok(cardB && cardB.user && cardB.user.pro === true, 'others see the Pro badge on the profile');
    // trading Pro-only: B is not Pro
    r = await ask(A.c, { t: 's_trade_offer', to: B.uid, give: [], get: [] }, 's_trade_res');
    ok(r && !r.ok && /Pro/.test(r.why || ''), 'with Pro-only trading on, a trade with a non-Pro player is refused: ' + (r && r.why));
    // renew + cancel
    r = await ask(A.c, { t: 's_pro_renew_test' }, 's_pro_renew_res');
    const d2 = (r.me.until - Date.now() / 1000) / 86400;
    ok(r && r.ok && d2 > 59.9, 'a (test) renewal adds another 30 days (' + d2.toFixed(1) + ')');
    r = await ask(A.c, { t: 's_pro_cancel' }, 's_pro_cancel_res');
    ok(r && r.ok && r.me.active && !r.me.auto, 'cancelling keeps Pro until the paid time ends, with renewal off');
    r = await ask(A.c, { t: 's_pro_renew_test' }, 's_pro_renew_res');
    ok(r && !r.ok, 'a cancelled membership does not renew');
    // admin grant / remove
    r = await ask(ad, { t: 'a_pro_set', uid: B.uid, tier: 'pro450', days: 7 }, 'a_ok');
    const pb = await wait(B.c, m => m.t === 's_pro', 6000);
    const eb = await eco(B.c);
    ok(r && r.pro.active && pb && eb.pro.active && eb.coins >= 450, 'the admin gives Pro to a player for 7 days; they are told and get the allowance');
    const ao = await ask(ad, { t: 'a_orders' }, 'a_orders_res');
    ok(ao && ao.pro.some(x => x.uid === B.uid && x.source === 'admin'), 'Plux Admin lists Pro members');
    // saved outfits: 3 free, 12 with this Pro tier
    const sh = (await eco(B.c));
    let ob = await ask(B.c, { t: 's_outfits' }, 's_outfits_res');
    ok(ob && ob.cap === 12, 'Pro raises the saved outfits limit to 12 (' + (ob && ob.cap) + ')');
    r = await ask(ad, { t: 'a_pro_set', uid: B.uid, days: 0 }, 'a_ok');
    ob = await ask(B.c, { t: 's_outfits' }, 's_outfits_res');
    ok(ob && ob.cap === 3, 'without Pro it is 3');
    ob = await ask(B.c, { t: 's_outfit_save', name: 'x' }, 's_outfit_save_res');
    ok(ob && !ob.ok && /Put something on/.test(ob.why), 'saving an empty outfit is refused');
    const eb2 = await eco(B.c);
    ok(r && !r.pro.active && !eb2.pro.active, 'the admin removes Pro');
    for (const x of [A, B]) x.c.ws.close();
  } catch (e) { console.log('FAIL crashed: ' + e.stack); failures++; }
  if (ad && saved) await ask(ad, { t: 'a_cfg_set', values: saved }, 'a_ok');
  console.log(failures ? `FAILED ${failures} (passed ${passes})` : `ALL PASSED (${passes})`);
  process.exit(failures ? 1 : 0);
})();
