// 0.7.2: the server reads every common AI reply shape. Local only, with mock_omni.py.
//   MOCK=http://127.0.0.1:8777/v1 node ai_shapes_test.js ws://127.0.0.1:8910
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const URL = process.argv[2] || 'ws://127.0.0.1:8910';
const MOCK = process.env.MOCK || 'http://127.0.0.1:8777/v1';
let rid = 1, fails = 0, passes = 0;
const ok = (c, w) => { console.log((c ? 'PASS ' : 'FAIL ') + w); c ? passes++ : fails++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
function conn() { return new Promise((res, rej) => { const ws = new WebSocket(URL); const c = { ws, inbox: [] };
  ws.on('message', d => c.inbox.push(JSON.parse(d.toString()))); ws.on('open', () => res(c)); ws.on('error', rej); }); }
async function ask(c, m, t, ms = 60000) { const r = rid++; c.ws.send(JSON.stringify(Object.assign({ rid: r }, m)));
  const end = Date.now() + ms; while (Date.now() < end) { const i = c.inbox.findIndex(x => x.t === t || x.t === 'a_err'); if (i >= 0) return c.inbox.splice(i, 1)[0]; await sleep(20); } return null; }
(async () => {
  const ad = await conn();
  const li = await ask(ad, { t: 'a_login', pw: process.env.ADMIN_PW || 'localadmin123' }, 'a_login_res');
  ok(li && li.ok, 'admin signs in');
  const cases = [['mock-model', true], ['mock-fenced', true], ['mock-trailing', true], ['mock-wrapped', true], ['mock-parts', true],
    ['mock-reasoning', true], ['mock-think', true], ['mock-cut', true], ['mock-sse', true], ['mock-badfirst', true], ['mock-broken', true], ['mock-luau', false], ['mock-empty', false]];
  for (const [model, want] of cases) {
    await ask(ad, { t: 'a_ai_set', base: MOCK, model, key: 'test-omni-key-1234' }, 'a_ok');
    const r = await ask(ad, { t: 'a_ai_test', full: true }, 'a_ai_test_res');
    ok(r && r.ok === want && (!want || r.parts >= 3), `${model}: ${want ? 'level read' : 'clear error'} (${r && (r.ok ? r.info : r.why)})`);
  }
  // Wrong address and wrong key give the real message.
  await ask(ad, { t: 'a_ai_set', base: MOCK.replace('/v1', '/nope'), model: 'mock-model', key: 'test-omni-key-1234' }, 'a_ok');
  let r = await ask(ad, { t: 'a_ai_test' }, 'a_ai_test_res');
  ok(r && !r.ok && /HTTP 404/.test(r.why), 'wrong address: ' + (r && r.why));
  await ask(ad, { t: 'a_ai_set', base: MOCK + '/', model: 'mock-model', key: 'wrong-key-9999' }, 'a_ok');
  r = await ask(ad, { t: 'a_ai_test' }, 'a_ai_test_res');
  ok(r && !r.ok && /401/.test(r.why) && /Invalid API key/.test(r.why), 'wrong key: ' + (r && r.why));
  await ask(ad, { t: 'a_ai_set', base: MOCK.replace('/v1', ''), model: 'mock-model', key: 'test-omni-key-1234' }, 'a_ok');
  r = await ask(ad, { t: 'a_ai_test' }, 'a_ai_test_res');
  ok(r && r.ok, 'bare host without /v1 works: ' + (r && (r.info || r.why)));
  const g = await ask(ad, { t: 'a_ai_get' }, 'a_ai_res');
  const log = (g && g.log) || [];
  ok(log.length > 5 && log.some(e => e.ok && /AI, \d+ parts/.test(e.why)) && log.some(e => !e.ok && e.why.length > 10), 'usage log has success details and real errors');
  // AI only: a failed build gives an error with Retry, never a stand-in game.
  await ask(ad, { t: 'a_ai_set', base: MOCK, model: 'mock-luau', key: 'test-omni-key-1234' }, 'a_ok');
  const pl = await conn();
  const nm = 'shp' + Date.now().toString(36).slice(-6);
  const su = await ask(pl, { t: 's_signup', username: nm, password: 'secret12', birthday: '2000-02-02' }, 's_signup_res', 30000);
  pl.ws.send(JSON.stringify({ t: 's_hello', v: 1, token: su && su.token, rid: rid++ }));
  await sleep(1500);
  let b = await ask(pl, { t: 's_ai_build', prompt: 'a lava obby with hammers' }, 's_ai_res', 120000);
  ok(b && b.ok === false && b.retry === true && !b.level, 'failed AI build: error + Retry, no fallback game (' + (b && b.why) + ')');
  await ask(ad, { t: 'a_ai_set', base: MOCK, model: 'mock-broken', key: 'test-omni-key-1234' }, 'a_ok');
  b = await ask(pl, { t: 's_ai_build', prompt: 'a lava obby with hammers' }, 's_ai_res', 120000);
  ok(b && b.ok && b.source === 'ai' && b.level && b.level.parts.length > 3, 'unfinishable level gets fixed by the AI (' + (b && (b.why || '')) + ')');
  const g2 = await ask(ad, { t: 'a_ai_get' }, 'a_ai_res');
  ok(g2 && g2.log && g2.log.some(e => /fixed \dx/.test(e.why)), 'usage log shows the fix: ' + JSON.stringify(g2 && g2.log && g2.log[0]));
  console.log(`${passes} passed, ${fails} failed`);
  process.exit(fails ? 1 : 0);
})();
