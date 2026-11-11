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

(async () => {
  let ad = null, saved = null;
  try {
    if (ADMIN_PW) {
      ad = await conn();
      const li = await ask(ad, { t: 'a_login', pw: ADMIN_PW }, 'a_login_res');
      ok(li && li.ok, 'admin signs in');
      const cfg = await ask(ad, { t: 'a_cfg_set', values: {} }, 'a_ok');
      saved = {}; for (const k of ['banned_words', 'f_buy_plux', 'pay_mode', 'pay_testers', 'f_invites', 'download_url']) saved[k] = cfg.cfg[k];
      await ask(ad, { t: 'a_cfg_set', values: { banned_words: (saved.banned_words ? saved.banned_words + ',' : '') + 'zorkbad' } }, 'a_ok');
    }
    const un = 'sign_' + tag;
    // ----- username checks before signing in
    const p = await conn();
    let r = await ask(p, { t: 's_name_check', username: un }, 's_name_res');
    ok(r && r.ok, 'a free username shows as available');
    r = await ask(p, { t: 's_name_check', username: 'ab' }, 's_name_res');
    ok(r && !r.ok && /3/.test(r.why), 'too short is refused: ' + (r && r.why));
    r = await ask(p, { t: 's_name_check', username: 'bad name!' }, 's_name_res');
    ok(r && !r.ok && /letters/.test(r.why), 'spaces and symbols are refused: ' + (r && r.why));
    r = await ask(p, { t: 's_name_check', username: 'xadminx' + tag }, 's_name_res');
    ok(r && !r.ok && /allowed/.test(r.why), 'names pretending to be staff are refused');
    if (ADMIN_PW) { r = await ask(p, { t: 's_name_check', username: 'zorkbad' + tag }, 's_name_res'); ok(r && !r.ok && /allowed/.test(r.why), 'a banned word from Plux Admin blocks the name'); }
    // ----- sign up
    r = await ask(p, { t: 's_signup', username: un, password: 'secret12', birthday: '2030-01-01' }, 's_signup_res');
    ok(r && !r.ok && r.field === 'birthday', 'a birthday in the future is refused');
    r = await ask(p, { t: 's_signup', username: un, password: 'secret12', birthday: '2010-02-30' }, 's_signup_res');
    ok(r && !r.ok && r.field === 'birthday', 'a date that does not exist is refused');
    r = await ask(p, { t: 's_signup', username: un, password: 'secret12', birthday: '2010-05-04', email: 'not-an-email' }, 's_signup_res');
    ok(r && !r.ok && r.field === 'email', 'a bad email is refused');
    r = await ask(p, { t: 's_signup', username: un, password: '123', birthday: '2010-05-04' }, 's_signup_res');
    ok(r && !r.ok && r.field === 'password', 'a short password is refused');
    r = await ask(p, { t: 's_signup', username: un, password: 'secret12', birthday: '2010-05-04', email: 'Test@Example.com' }, 's_signup_res');
    ok(r && r.ok && r.token && r.uid, 'sign-up works and gives a session');
    // signup counts as one of the 5 tries on this connection; use a fresh one for the rest
    const token = r.token, uid = r.uid;
    let w = await hello(p, { token });
    ok(w && w.t === 's_welcome' && w.me.uid === uid && w.me.username === un && w.me.has_pw && w.me.has_bday && w.me.email === 'test@example.com', 'the new account signs in with its session');
    ok(w && w.eco && w.eco.coins >= 0, 'the new account gets a Plux wallet (' + (w && w.eco && w.eco.coins) + ')');
    const p2 = await conn();
    r = await ask(p2, { t: 's_signup', username: un.toUpperCase(), password: 'secret12', birthday: '2010-05-04' }, 's_signup_res');
    ok(r && !r.ok && /taken/.test(r.why), 'the same username cannot be taken twice (any case)');
    r = await ask(p2, { t: 's_name_check', username: un }, 's_name_res');
    ok(r && !r.ok && /taken/.test(r.why), 'the live check now says taken');
    // ----- log in, stays logged in with the token
    const p3 = await conn();
    r = await ask(p3, { t: 's_login', username: un, password: 'secret12' }, 's_login_res');
    ok(r && r.ok && r.uid === uid, 'log in with username and password');
    w = await hello(p3, { token: r.token });
    ok(w && w.t === 's_welcome' && w.me.uid === uid, 'the login session signs in');
    const keep = r.token;
    p3.ws.close(); await sleep(300);
    const p4 = await conn();
    w = await hello(p4, { token: keep });
    ok(w && w.t === 's_welcome' && w.me.uid === uid, 'reopening the app with the saved session stays logged in');
    // ----- rate limit
    let slow = false;
    for (let i = 0; i < 8 && !slow; i++) {
      const q = await conn();
      const x = await ask(q, { t: 's_login', username: un, password: 'wrong' + i }, 's_login_res');
      if (x && x.why === 'slow') slow = true;
      q.ws.close();
    }
    ok(slow, 'after 6 wrong passwords that username is paused, even across new connections');
    const q2 = await conn();
    r = await ask(q2, { t: 's_login', username: un, password: 'secret12' }, 's_login_res');
    ok(r && !r.ok && r.why === 'slow', 'while paused, even the right password waits');
    // ----- an old phone account finishes its setup and keeps everything
    const key = crypto.randomBytes(24).toString('hex');
    const o = await conn();
    w = await hello(o, { key, name: 'Old ' + tag, username: 'old_' + tag, bio: '', friends: [], follows: [], req_out: [] });
    ok(w && w.me && w.me.has_pw === false, 'an old phone account shows it has no password yet');
    await ask(o, { t: 's_daily' }, 's_daily_res');
    const before = await eco(o);
    r = await ask(o, { t: 's_finish', username: 'old_' + tag, password: 'oldpass1', birthday: '2001-09-09' }, 's_finish_res');
    ok(r && r.ok && r.me.has_pw && r.me.has_bday, 'finishing the account works');
    const o2 = await conn();
    r = await ask(o2, { t: 's_login', username: 'old_' + tag, password: 'oldpass1' }, 's_login_res');
    ok(r && r.ok && r.uid === w.me.uid, 'that account can now log in on another phone');
    const w2 = await hello(o2, { token: r.token });
    const after = await eco(o2);
    ok(after.coins === before.coins, 'and keeps its Plux (' + after.coins + ')');
    // ----- friend + invites + presence
    send(o2, { t: 's_freq', uid });
    await wait(p4, m => m.t === 's_notice' && m.kind === 'request');
    send(p4, { t: 's_faccept', uid: w.me.uid });
    await wait(o2, m => m.t === 's_notice' && m.kind === 'friends');
    await sleep(300);
    send(o2, { t: 's_playing', what: 'pop', room: 'ROOM' + tag.toUpperCase() });
    const pl = await wait(p4, m => m.t === 's_playing' && m.uid === w.me.uid);
    ok(pl && pl.playing.title === 'Pop-Up Panic' && pl.playing.room === 'ROOM' + tag.toUpperCase(), 'friends see "Playing Pop-Up Panic" with the room to join');
    r = await ask(o2, { t: 's_invite', to: [uid], what: 'pop', room: 'ROOM' + tag.toUpperCase() }, 's_invite_res');
    ok(r && r.ok && r.sent === 1, 'invite sent to an online friend');
    const inv = await wait(p4, m => m.t === 's_invite_in');
    ok(inv && inv.from.uid === w.me.uid && inv.title === 'Pop-Up Panic' && inv.room === 'ROOM' + tag.toUpperCase(), 'the friend gets the invite with who, which game and the room');
    send(p4, { t: 's_invite_reply', to: w.me.uid, join: true });
    const ans = await wait(o2, m => m.t === 's_invite_ans');
    ok(ans && ans.join === true, 'the inviter hears they are joining');
    r = await ask(o2, { t: 's_invite', to: ['f'.repeat(32)], what: 'pop', room: 'X1' }, 's_invite_res');
    ok(r && r.sent === 0 && !r.ok, 'invites only go to friends');
    if (ADMIN_PW) {
      await ask(ad, { t: 'a_cfg_set', values: { f_invites: false } }, 'a_ok');
      r = await ask(o2, { t: 's_invite', to: [uid], what: 'pop', room: 'ROOM1' }, 's_invite_res');
      ok(r && !r.ok && /off/.test(r.why), 'Plux Admin can switch invites off');
      await ask(ad, { t: 'a_cfg_set', values: { f_invites: true } }, 'a_ok');
    }
    // ----- invite code
    const code = await ask(o2, { t: 's_invite_code' }, 's_invite_code_res');
    ok(code && /^[0-9A-F]{8}$/.test(code.code) && code.text.includes(code.code), 'each player has an invite code to share: ' + (code && code.code));
    const n = await conn();
    r = await ask(n, { t: 's_signup', username: 'newbie_' + tag, password: 'newbie12', birthday: '2008-03-03', invite: code.code }, 's_signup_res');
    ok(r && r.ok && r.invited_by === 'Old ' + tag, 'signing up with the code works and names the inviter');
    const nf = await wait(o2, m => m.t === 's_notice' && m.kind === 'friends' && m.invite);
    ok(nf && nf.from.username === 'newbie_' + tag, 'the inviter is told and they are friends');
    const nw = await hello(n, { token: r.token });
    ok(nw && nw.friends.some(f => f.uid === w.me.uid), 'the new player starts with the inviter as a friend');
    // ----- Plux packs
    r = await ask(p4, { t: 's_packs' }, 's_packs_res');
    ok(r && r.packs.length >= 1 && (ADMIN_PW ? r.open === (saved.f_buy_plux && saved.pay_testers.includes(un)) : true), 'the Get Plux store lists ' + (r && r.packs.length) + ' packs; open=' + (r && r.open) + ' (' + (r && r.why) + ')');
    r = await ask(p4, { t: 's_pay_start', pack: 'p80' }, 's_pay_start_res');
    ok(r && !r.ok, 'with buying switched off (the default), no order can start');
    if (ADMIN_PW) {
      await ask(ad, { t: 'a_cfg_set', values: { f_buy_plux: true, pay_mode: 'sandbox', pay_testers: un } }, 'a_ok');
      r = await ask(o2, { t: 's_pay_start', pack: 'p80' }, 's_pay_start_res');
      ok(r && !r.ok && /tested/.test(r.why), 'in test mode, players not on the tester list cannot buy');
      const e0 = await eco(p4);
      r = await ask(p4, { t: 's_pay_start', pack: 'p400' }, 's_pay_start_res');
      ok(r && r.ok && r.order.plux === 440 && r.order.test === true, 'a tester starts a test order for 400 + 40 bonus Plux');
      const oid = r.order.id;
      const e1 = await eco(p4);
      ok(e1.coins === e0.coins, 'starting an order adds nothing yet');
      r = await ask(p4, { t: 's_pay_confirm', order: oid }, 's_pay_res');
      const e2 = await eco(p4);
      ok(r && r.ok && e2.coins === e0.coins + 440, 'after the (test) payment is confirmed on the server, exactly 440 Plux are added (' + e0.coins + '->' + e2.coins + ')');
      const r1 = send(p4, { t: 's_pay_confirm', order: oid }), r2 = send(p4, { t: 's_pay_confirm', order: oid });
      const c1 = await wait(p4, m => m.rid === r1), c2 = await wait(p4, m => m.rid === r2);
      const e3 = await eco(p4);
      ok(c1 && c2 && !c1.ok && !c2.ok && e3.coins === e2.coins, 'confirming the same order again, twice at once, adds nothing');
      r = await ask(o2, { t: 's_pay_confirm', order: oid }, 's_pay_res');
      ok(r && !r.ok, 'someone else cannot confirm your order');
      await ask(ad, { t: 'a_cfg_set', values: { pay_mode: 'live' } }, 'a_ok');
      r = await ask(p4, { t: 's_pay_start', pack: 'p80' }, 's_pay_start_res');
      ok(r && !r.ok && /set up/.test(r.why), 'live mode with no provider set up refuses orders: ' + (r && r.why));
      const ao = await ask(ad, { t: 'a_orders' }, 'a_orders_res');
      ok(ao && ao.orders.some(x => x.id === oid && x.status === 'paid' && x.test && x.username === un), 'Plux Admin lists the order as a paid test order');
      const au = await ask(ad, { t: 'a_users', q: '', sort: 'new' }, 'a_users_res');
      const row = au && au.users.find(x => x.username === un);
      ok(row && row.has_pw && row.age >= 13 && row.email === 'test@example.com' && row.created > 0, 'Plux Admin shows the signup with age and email (age ' + (row && row.age) + ')');
      ok(au && au.users[0].created >= au.users[au.users.length - 1].created, 'newest signups come first');
    }
    // ----- rewards from games
    if (ADMIN_PW) {
      const e0 = await eco(p4);
      // publish a tiny Studio game as the old account, play it as the new one
      const level = { title: 'Test run ' + tag, parts: [['block', 0, -0.5, 0, 8, 1, 8], ['block', 0, -0.5, -12, 8, 1, 8]], spawn: [0, 1, 0], goal: [0, 1, -12] };
      const pub = await ask(o2, { t: 's_studio_publish', level }, 's_studio_save_res');
      ok(pub && pub.ok && pub.published, 'a Studio game is published' + (pub && !pub.ok ? ': ' + pub.why : ''));
      const gid = pub && pub.gid;
      r = await ask(p4, { t: 's_game_done', gid, ms: 1000 }, 's_game_done_res');
      ok(r && r.got === 0, 'reaching the goal in 1 second (too fast to be real) pays nothing');
      r = await ask(p4, { t: 's_game_done', gid, ms: 15000 }, 's_game_done_res');
      ok(r && r.got === 15, 'reaching the goal of a Studio game pays 5 + 10 first-time bonus Plux (' + (r && r.got) + ')');
      r = await ask(p4, { t: 's_game_done', gid, ms: 15000 }, 's_game_done_res');
      ok(r && r.got === 0, 'finishing again straight away pays nothing (once per 10 minutes)');
      r = await ask(o2, { t: 's_game_done', gid, ms: 15000 }, 's_game_done_res');
      ok(r && r.got === 0, 'you are not paid for finishing your own game');
      await ask(ad, { t: 'a_game_set', gid, status: 'removed' }, 'a_ok');
    }
    // Neon Bounce pays for staying: checked with a short reward time.
    if (ADMIN_PW) {
      await ask(ad, { t: 'a_cfg_set', values: { neon_reward_s: 15 } }, 'a_ok');
      const tk = await ask(p4, { t: 's_ticket' }, 's_ticket_res');
      const e0 = await eco(p4);
      const g = await conn();
      send(g, { t: 'hello', v: 1, name: 'Neo', room: 'NEON' + tag.toUpperCase(), tk: tk && tk.ticket });
      const wel = await wait(g, m => m.t === 'welcome', 10000);
      const iv = setInterval(() => g.ws.send(JSON.stringify({ t: 'state', p: [0, 1, 0], y: 0, s: 0 })), 100);
      await sleep(31500);
      clearInterval(iv); g.ws.close();
      const got = await wait(p4, m => m.t === 's_plux' && m.why === 'neon', 6000);
      const e1 = await eco(p4);
      ok(wel && got && e1.coins === e0.coins + 10, 'staying 31 s in Neon Bounce pays 2 x 5 Plux when the reward time is 15 s (' + e0.coins + '->' + e1.coins + ')');
      await ask(ad, { t: 'a_cfg_set', values: { neon_reward_s: 60 } }, 'a_ok');
    }
    for (const c of [p, p2, p4, q2, o, o2, n]) c.ws.close();
  } catch (e) { console.log('FAIL crashed: ' + e.stack); failures++; }
  if (ad && saved) await ask(ad, { t: 'a_cfg_set', values: saved }, 'a_ok');
  console.log(failures ? `FAILED ${failures} (passed ${passes})` : `ALL PASSED (${passes})`);
  process.exit(failures ? 1 : 0);
})();
