// Permanent storage + login test. Run phase 'a', restart the server, then phase 'b'.
// Usage: node tests/persist_test.js ws://127.0.0.1:9300 a|b
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const crypto = require('crypto');
const fs = require('fs');
const URL = process.argv[2] || 'ws://127.0.0.1:9300';
const PHASE = process.argv[3] || 'a';
const STATE = '/tmp/persist_test_state.json';
let failures = 0;
const ok = (cond, what) => { console.log((cond ? 'PASS ' : 'FAIL ') + what); if (!cond) failures++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const uidOf = key => crypto.createHash('sha256').update(key).digest('hex').slice(0, 16);

function open(first) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const c = { ws, inbox: [] };
    ws.on('message', d => {
      const m = JSON.parse(d.toString());
      if (m.t === 'pong') return;
      c.inbox.push(m);
      if (m.t === 's_msg' && !c.noGot) ws.send(JSON.stringify({ t: 's_got', mid: m.mid }));
    });
    ws.on('open', () => { if (first) ws.send(JSON.stringify(first)); resolve(c); });
    ws.on('close', () => { c.closed = true; });
    ws.on('error', reject);
  });
}
const send = (c, m) => c.ws.send(JSON.stringify(m));
async function wait(c, pred, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const i = c.inbox.findIndex(pred);
    if (i >= 0) return c.inbox.splice(i, 1)[0];
    await sleep(30);
  }
  return null;
}
async function hello(acct) {
  const c = await open(Object.assign({ t: 's_hello', v: 1 }, acct));
  c.welcome = await wait(c, m => m.t === 's_welcome', 20000);
  return c;
}

(async () => {
  if (PHASE === 'a') {
    const tag = Date.now().toString(36).slice(-5);
    const A = { key: crypto.randomBytes(24).toString('hex'), name: 'Pia', username: 'pia_' + tag, bio: 'hi', av: 4 };
    const B = { key: crypto.randomBytes(24).toString('hex'), name: 'Rex', username: 'rex_' + tag, bio: '', av: 7 };
    const a = await hello(A), b = await hello(B);
    ok(a.welcome && b.welcome, 'both signed in');
    ok(a.welcome.stored === true, 'server says storage is on');
    const bu = uidOf(B.key), au = uidOf(A.key);
    send(a, { t: 's_follow', uid: bu, on: true, rid: 1 });
    send(a, { t: 's_freq', uid: bu, rid: 2 });
    await wait(b, m => m.t === 's_notice' && m.kind === 'request');
    send(b, { t: 's_faccept', uid: au, rid: 3 });
    await wait(a, m => m.t === 's_notice' && m.kind === 'friends');
    send(a, { t: 's_msg', to: bu, mid: 'msg-one-' + tag, text: 'saved forever?' });
    ok(!!(await wait(b, m => m.t === 's_msg' && m.text === 'saved forever?')), 'live message arrives');
    b.ws.close();
    await sleep(400);
    send(a, { t: 's_msg', to: bu, mid: 'msg-two-' + tag, text: 'sent while you were away' });
    ok(!!(await wait(a, m => m.t === 's_ack' && m.state === 'queued' && m.mid === 'msg-two-' + tag)), 'offline message queued');
    send(a, { t: 's_setpw', password: 'short', rid: 9 });
    ok((await wait(a, m => m.t === 's_setpw_res' && m.rid === 9) || {}).why === 'short', 'too-short password refused');
    send(a, { t: 's_setpw', password: 'bounce-123', rid: 10 });
    const sp = await wait(a, m => m.t === 's_setpw_res' && m.rid === 10);
    ok(sp && sp.ok && sp.stored, 'password set and stored');
    await sleep(2500);  // let writes reach the database
    a.ws.close();
    fs.writeFileSync(STATE, JSON.stringify({ A, B, tag }));
  } else {
    const { A, B, tag } = JSON.parse(fs.readFileSync(STATE));
    const au = uidOf(A.key), bu = uidOf(B.key);
    // Rex comes back after the restart claiming nothing: the server remembers.
    const b = await hello({ key: B.key, name: B.name, username: B.username, bio: '', av: 7, friends: [], follows: [] });
    ok(b.welcome && b.welcome.friends.some(f => f.uid === au), 'friendship survived the restart');
    ok(!!(await wait(b, m => m.t === 's_msg' && m.text === 'sent while you were away', 8000)), 'offline message survived the restart');
    send(b, { t: 's_get', uid: bu, rid: 5 });
    const prof = await wait(b, m => m.t === 's_user' && m.rid === 5);
    ok(prof && prof.user && prof.user.followers === 1, 'follower count survived');
    // Pia logs in on a new phone with username + password.
    const bad = await open({ t: 's_login', username: A.username, password: 'nope-nope', rid: 1 });
    ok((await wait(bad, m => m.t === 's_login_res') || {}).ok === false, 'wrong password refused');
    bad.ws.close();
    const p = await open({ t: 's_login', username: '@' + A.username, password: 'bounce-123', rid: 1 });
    const lr = await wait(p, m => m.t === 's_login_res');
    ok(lr && lr.ok && lr.uid === au && lr.token, 'login with username and password works');
    send(p, { t: 's_hello', v: 1, token: lr.token, sync: true });
    const w = await wait(p, m => m.t === 's_welcome', 8000);
    ok(w && w.me.uid === au && w.me.name === 'Pia' && w.me.av === 4, 'new phone gets the same account and avatar');
    ok(w && w.friends.some(f => f.uid === bu), 'new phone sees the friends');
    const hist = w && w.chats ? w.chats[bu] || [] : [];
    ok(hist.some(m => m.text === 'saved forever?') && hist.some(m => m.text === 'sent while you were away'), 'new phone gets the chat history');
    send(p, { t: 's_logout', rid: 2 });
    await wait(p, m => m.t === 's_logout_res');
    p.ws.close();
    const again = await open({ t: 's_hello', v: 1, token: lr.token });
    const err = await wait(again, m => m.t === 'error', 5000);
    ok(err && err.code === 'logged_out', 'token stops working after log out');
    b.ws.close();
  }
  console.log(failures ? failures + ' FAILED' : 'ALL PASSED');
  process.exit(failures ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
