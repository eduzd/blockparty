// Social layer test against a running referee (local or live).
// Covers: sign-in, unique usernames, search, visiting a profile, follow/unfollow,
// friend request -> accept, chat delivery + read receipts, offline queue,
// non-friends can't message, unfriend, re-seeding after a server restart.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const crypto = require('crypto');
const URL = process.argv[2] || 'ws://127.0.0.1:8910';
const PHASE = process.argv[3] || 'full';   // full | seed1 | seed2
let failures = 0;
const ok = (cond, what) => { console.log((cond ? 'PASS ' : 'FAIL ') + what); if (!cond) failures++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const uidOf = key => crypto.createHash('sha256').update(key).digest('hex').slice(0, 16);
const tag = Date.now().toString(36).slice(-4);

function user(acct) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const c = { ws, acct, inbox: [], closed: false, uid: uidOf(acct.key) };
    ws.on('message', d => {
      const m = JSON.parse(d.toString());
      if (m.t === 'pong') return;
      c.inbox.push(m);
      if (m.t === 's_msg' && !acct.noGot) ws.send(JSON.stringify({ t: 's_got', mid: m.mid }));
      if (m.t === 's_welcome') { c.welcome = m; resolve(c); }
    });
    ws.on('open', () => {
      ws.send(JSON.stringify(Object.assign({ t: 's_hello', v: 1 }, acct)));
      // Like the app: a ping every 5 s keeps an idle social connection open.
      c.pinger = setInterval(() => { if (ws.readyState === 1) ws.send(JSON.stringify({ t: 'ping', c: 1 })); }, 5000);
    });
    ws.on('close', () => { c.closed = true; clearInterval(c.pinger); });
    ws.on('error', reject);
    setTimeout(() => reject(new Error('no welcome for ' + acct.name)), 70000);
  });
}
const send = (c, m) => c.ws.send(JSON.stringify(m));
async function wait(c, pred, ms = 3000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const i = c.inbox.findIndex(pred);
    if (i >= 0) return c.inbox.splice(i, 1)[0];
    await sleep(30);
  }
  return null;
}
const acct = (name, username, extra = {}) => Object.assign({ key: crypto.randomBytes(24).toString('hex'), name, username, bio: 'Hi, I am ' + name, friends: [], follows: [], req_out: [] }, extra);

async function full() {
  const A = acct('Ana ' + tag, 'ana_' + tag), B = acct('Ben ' + tag, 'ben_' + tag);
  const a = await user(A), b = await user(B);
  ok(a.welcome.me.username === 'ana_' + tag, 'welcome returns my card with my username');
  // Username clash gets a new name
  const C = acct('Cleo', 'ana_' + tag);
  const c = await user(C);
  ok(c.welcome.me.username !== 'ana_' + tag && c.welcome.me.username.startsWith('ana_'), 'taken username is changed: ' + c.welcome.me.username);
  // Search
  send(a, { t: 's_search', q: 'ben_' + tag, rid: 1 });
  const s = await wait(a, m => m.t === 's_search_res');
  ok(s && s.users.length >= 1 && s.users[0].uid === b.uid, 'search finds Ben by username');
  send(a, { t: 's_search', q: '@BEN', rid: 2 });
  const s2 = await wait(a, m => m.t === 's_search_res');
  ok(s2 && s2.users.some(u => u.uid === b.uid), 'search is case-insensitive and takes @');
  // Visit profile
  send(a, { t: 's_get', uid: b.uid, rid: 3 });
  const prof = await wait(a, m => m.t === 's_user');
  ok(prof && prof.user.name === 'Ben ' + tag && prof.user.bio === 'Hi, I am Ben ' + tag && prof.user.online === true, 'profile shows name, bio, online');
  // Follow
  send(a, { t: 's_follow', uid: b.uid, on: true, rid: 4 });
  const f = await wait(a, m => m.t === 's_user');
  ok(f && f.user.i_follow === true && f.user.followers === 1, 'follow: i_follow and follower count 1');
  const fn = await wait(b, m => m.t === 's_notice' && m.kind === 'follow');
  ok(fn && fn.from.uid === a.uid, 'Ben is told Ana followed him');
  send(b, { t: 's_list', uid: b.uid, kind: 'followers', rid: 5 });
  const fl = await wait(b, m => m.t === 's_list_res');
  ok(fl && fl.users.length === 1 && fl.users[0].uid === a.uid && fl.users[0].follows_me === true, 'followers list has Ana');
  // Non-friends can't chat
  send(a, { t: 's_msg', to: b.uid, mid: 'm0000000001', text: 'hi' });
  const nf = await wait(a, m => m.t === 's_ack');
  ok(nf && nf.state === 'not_friends', 'message to a non-friend refused');
  // Friend request -> accept
  send(a, { t: 's_freq', uid: b.uid, rid: 6 });
  const fr = await wait(a, m => m.t === 's_user');
  ok(fr && fr.user.req_out === true && fr.user.friend === false, 'request pending for Ana');
  const rq = await wait(b, m => m.t === 's_notice' && m.kind === 'request');
  ok(rq && rq.from.uid === a.uid && rq.from.req_in === true, 'Ben gets the request');
  send(b, { t: 's_faccept', uid: a.uid, rid: 7 });
  const fa = await wait(a, m => m.t === 's_notice' && m.kind === 'friends');
  const fb = await wait(b, m => m.t === 's_user');
  ok(fa && fb && fb.user.friend === true, 'accepted: both are friends');
  // Chat
  send(a, { t: 's_msg', to: b.uid, mid: 'm0000000002', text: 'Hey Ben!', ts: 1 });
  const sent = await wait(a, m => m.t === 's_ack' && m.mid === 'm0000000002' && m.state === 'queued');
  ok(!!sent, 'server confirms it has the message');
  const ack = await wait(a, m => m.t === 's_ack' && m.mid === 'm0000000002' && m.state === 'delivered');
  const got = await wait(b, m => m.t === 's_msg');
  ok(ack && ack.state === 'delivered' && got && got.text === 'Hey Ben!' && got.from === a.uid, 'message delivered live');
  send(b, { t: 's_typing', to: a.uid });
  ok(!!(await wait(a, m => m.t === 's_typing' && m.from === b.uid)), 'typing indicator relayed');
  send(b, { t: 's_read', to: a.uid });
  ok(!!(await wait(a, m => m.t === 's_read' && m.from === b.uid)), 'read receipt relayed');
  // Offline queue
  b.ws.close();
  const pres = await wait(a, m => m.t === 's_presence' && m.uid === b.uid && m.online === false, 25000);
  ok(!!pres, 'Ana sees Ben go offline');
  send(a, { t: 's_msg', to: b.uid, mid: 'm0000000003', text: 'You there?' });
  const q = await wait(a, m => m.t === 's_ack' && m.mid === 'm0000000003');
  ok(q && q.state === 'queued', 'message to offline friend is queued');
  ok(!(await wait(a, m => m.t === 's_ack' && m.mid === 'm0000000003' && m.state === 'delivered', 1000)), 'not marked delivered while Ben is away');
  B.friends = [a.uid];
  let b2 = await user(B);
  ok(b2.welcome.friends.some(u => u.uid === a.uid), 'Ben reconnects: still friends');
  const late = await wait(b2, m => m.t === 's_msg' && m.mid === 'm0000000003');
  ok(!!late && late.text === 'You there?', 'queued message arrives on reconnect');
  const dl = await wait(a, m => m.t === 's_ack' && m.mid === 'm0000000003' && m.state === 'delivered');
  ok(!!dl, 'Ana told it was delivered');
  ok(!!(await wait(a, m => m.t === 's_presence' && m.uid === b.uid && m.online === true)), 'Ana sees Ben come online');
  // A phone whose connection dies without confirming: the message comes again.
  B.noGot = true;
  const b3 = await user(B);
  await sleep(300);
  send(a, { t: 's_msg', to: b.uid, mid: 'm0000000005', text: 'Lost in the tunnel?' });
  ok(!!(await wait(b3, m => m.t === 's_msg' && m.mid === 'm0000000005')), 'sent to the new connection');
  delete B.noGot;
  const b4 = await user(B);   // replaces b3 (signed in elsewhere), unconfirmed message requeued
  ok(!!(await wait(b4, m => m.t === 's_msg' && m.mid === 'm0000000005')), 'unconfirmed message re-delivered after reconnect');
  ok(!!(await wait(a, m => m.t === 's_ack' && m.mid === 'm0000000005' && m.state === 'delivered')), 'delivered only once confirmed');
  b2.ws.close(); b3.ws.close();
  const bOld = b2; b2 = b4;
  // Edit profile
  send(b2, { t: 's_profile', name: 'Benny', username: 'benny_' + tag, bio: 'new bio', rid: 9 });
  const pr = await wait(b2, m => m.t === 's_profile_res');
  ok(pr && pr.ok && pr.me.username === 'benny_' + tag && pr.me.name === 'Benny', 'profile edit saved');
  send(c, { t: 's_profile', name: 'Cleo', username: 'benny_' + tag, bio: '', rid: 10 });
  const pr2 = await wait(c, m => m.t === 's_profile_res');
  ok(pr2 && pr2.ok === false && pr2.why === 'taken', 'someone else cannot take that username');
  // Decline + cancel
  send(c, { t: 's_freq', uid: a.uid, rid: 11 });
  await wait(a, m => m.t === 's_notice' && m.kind === 'request');
  send(a, { t: 's_fdecline', uid: c.uid, rid: 12 });
  ok(!!(await wait(c, m => m.t === 's_notice' && m.kind === 'declined')), 'decline reaches the sender');
  // Unfriend
  send(a, { t: 's_funfriend', uid: b.uid, rid: 13 });
  const uf = await wait(b2, m => m.t === 's_notice' && m.kind === 'unfriended');
  ok(!!uf, 'unfriend reaches the other side');
  send(b2, { t: 's_msg', to: a.uid, mid: 'm0000000004', text: 'hello?' });
  const nf2 = await wait(b2, m => m.t === 's_ack' && m.mid === 'm0000000004');
  ok(nf2 && nf2.state === 'not_friends', 'cannot message after unfriend');
  // Bad input
  send(a, { t: 's_follow', uid: 'NOT-A-UID', on: true });
  ok(!!(await wait(a, m => m.t === 'error')), 'bad uid rejected');
  for (const x of [a, b2, c]) x.ws.close();
}

// Restart test, phase 1: two users become friends and follow each other; their
// state is printed. Phase 2 (after the server restarts) signs in with that state.
const fs = require('fs');
async function seed1() {
  const A = acct('Rae', 'rae_' + tag), B = acct('Sol', 'sol_' + tag);
  const a = await user(A), b = await user(B);
  send(a, { t: 's_freq', uid: b.uid }); await wait(b, m => m.t === 's_notice');
  send(b, { t: 's_faccept', uid: a.uid }); await wait(a, m => m.t === 's_notice' && m.kind === 'friends');
  send(a, { t: 's_follow', uid: b.uid, on: true }); await wait(a, m => m.t === 's_user' && m.user.i_follow);
  A.friends = [b.uid]; A.follows = [b.uid]; B.friends = [a.uid];
  fs.writeFileSync('/tmp/social_seed.json', JSON.stringify({ A, B }));
  ok(true, 'seeded');
  a.ws.close(); b.ws.close();
}
async function seed2() {
  const { A, B } = JSON.parse(fs.readFileSync('/tmp/social_seed.json'));
  const b = await user(B);
  ok(b.welcome.friends.length === 1, 'after restart, Sol (first back) still has Rae as a friend');
  const a = await user(A);
  ok(a.welcome.friends.length === 1 && a.welcome.following.length === 1, 'Rae still has the friend and the follow');
  send(b, { t: 's_get', uid: b.uid });
  const me = await wait(b, m => m.t === 's_user');
  ok(me && me.user.followers === 1, 'Sol follower count rebuilt to 1');
  send(a, { t: 's_msg', to: b.uid, mid: 'm0000000099', text: 'still here' });
  ok(!!(await wait(b, m => m.t === 's_msg' && m.text === 'still here')), 'chat works after restart');
  a.ws.close(); b.ws.close();
}

(async () => {
  try {
    if (PHASE === 'seed1') await seed1(); else if (PHASE === 'seed2') await seed2(); else await full();
  } catch (e) { ok(false, 'exception: ' + e.message); }
  await sleep(200);
  console.log(failures === 0 ? 'ALL PASSED' : failures + ' FAILED');
  process.exit(failures ? 1 : 0);
})();
