// 0.7.1 checks: Studio AI through Omni Route (OpenAI-compatible), admin AI settings,
// Studio Builder agent rules, "AI not set up" flag, and the admin dashboard numbers.
//   ADMIN_PW=... MOCK=http://127.0.0.1:8777/v1 node studio_ai_test.js <url>
// With MOCK set (local only) it points the server at tests/mock_omni.py, then puts
// the AI settings and the agent back. Without MOCK (live) it never touches the key.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const fs = require('fs');
const URL = process.argv[2] || 'ws://127.0.0.1:8910';
const ADMIN_PW = process.env.ADMIN_PW || '';
const MOCK = process.env.MOCK || '';
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
async function ask(c, m, t, ms = 90000) { const r = send(c, m); return wait(c, x => (x.t === t || x.t === 'a_err') && (x.rid === r || x.rid === undefined), ms); }
async function hello(c, extra) { send(c, Object.assign({ t: 's_hello', v: 1 }, extra)); return wait(c, m => m.t === 's_welcome' || m.t === 'error', 90000); }

(async () => {
  let ad = null, origAgent = null, origAi = null;
  try {
    // Players can't use admin messages.
    const p = await conn();
    const su = await ask(p, { t: 's_signup', username: 'ai' + tag, password: 'secret12', birthday: '2000-02-02' }, 's_signup_res');
    ok(su && su.ok, 'player signs up');
    await hello(p, { token: su.token });
    const refused = m => (m.t === 'a_err' && m.why === 'not_admin') || (m.t === 'error' && m.code === 'not_admin');
    send(p, { t: 'a_ai_get' });
    const na = await wait(p, m => refused(m) || m.t === 'a_ai_res', 8000);
    ok(na && refused(na), 'a player cannot read AI settings');
    send(p, { t: 'a_agent_save', agent: { id: 'studio_builder', name: 'x', on: false } });
    const nb = await wait(p, m => refused(m) || m.t === 'a_ok', 8000);
    ok(nb && refused(nb), 'a player cannot change agent rules');

    // Admin sign-in is checked on the server.
    ad = await conn();
    const bad = await ask(ad, { t: 'a_login', pw: 'wrong-password-' + tag }, 'a_login_res');
    ok(bad && bad.ok === false, 'wrong admin password is refused');
    const li = await ask(ad, { t: 'a_login', pw: ADMIN_PW }, 'a_login_res');
    ok(li && li.ok, 'admin signs in');
    const st = li && li.stats || {};
    ok(typeof st.accounts === 'number' && typeof st.online === 'number' && typeof st.uptime_s === 'number' && 'storage' in st && 'ai_ready' in st,
      `dashboard numbers: ${st.accounts} players, ${st.online} online, storage ${st.storage}, version ${st.version}`);
    const st2 = await ask(ad, { t: 'a_stats' }, 'a_stats_res');
    ok(st2 && st2.stats && st2.stats.accounts >= 1, 'dashboard refresh works');

    origAi = await ask(ad, { t: 'a_ai_get' }, 'a_ai_res');
    ok(origAi && typeof origAi.ready === 'boolean', `AI settings read (ready: ${origAi && origAi.ready})`);
    ok(origAi && (origAi.key === '' || origAi.key.startsWith('•')), 'stored key only ever comes back masked');
    const ags = await ask(ad, { t: 'a_agents' }, 'a_agents_res');
    origAgent = (ags && ags.agents || []).find(a => a.id === 'studio_builder');
    ok(!!origAgent, 'Studio Builder agent exists');
    const keys = (ags && ags.schema || []).map(o => o.key);
    ok(['tone', 'strict', 'age', 'size', 'difficulty', 'theme', 'max_parts', 'allow_lava', 'allow_spinner', 'allow_ice'].every(k => keys.includes(k)), 'rule options for tone, strictness, age, size, difficulty, theme, most objects, lava, hammers, ice');

    // Studio tells the app whether AI is set up.
    const mine0 = await ask(p, { t: 's_studio_mine' }, 's_studio_mine_res');
    ok(mine0 && typeof mine0.ai === 'boolean', `Studio gets the "AI set up" flag (${mine0 && mine0.ai})`);

    if (MOCK) {
      // Wrong key, then the right key, through the OpenAI-compatible endpoint.
      let r = await ask(ad, { t: 'a_ai_set', base: MOCK, model: 'mock-model', key: 'wrong-key-0000' }, 'a_ok');
      ok(r && r.ok && r.key === '••••••••0000', 'key saved and shown masked');
      r = await ask(ad, { t: 'a_ai_test' }, 'a_ai_test_res', 30000);
      ok(r && r.ok === false && /401/.test(r.why), `Test connection with a wrong key fails clearly (${r && r.why})`);
      r = await ask(ad, { t: 'a_ai_set', base: MOCK, model: 'mock-model', key: 'test-omni-key-1234' }, 'a_ok');
      ok(r && r.ok && r.ready, 'right key saved, AI ready');
      const g = await ask(ad, { t: 'a_ai_get' }, 'a_ai_res');
      ok(g && g.key === '••••••••1234' && !JSON.stringify(g).includes('test-omni-key'), 'full key never sent back to the admin app');
      r = await ask(ad, { t: 'a_ai_test' }, 'a_ai_test_res', 30000);
      ok(r && r.ok, `Test connection passes (${r && r.ms} ms)`);
      const last0 = JSON.parse(fs.readFileSync('/tmp/mock_omni_last.json'));
      ok(last0.auth_ok && last0.body.model === 'mock-model' && last0.path === '/v1/chat/completions', 'server calls {base}/chat/completions with the key and model');

      // Rules from the admin app reach every Studio AI call and are enforced.
      const rules = Object.assign({}, origAgent, { on: true, rules: 'Always put a star near the start. ' + tag,
        opts: Object.assign({}, origAgent.opts, { allow_lava: false, theme: 'ice', difficulty: 'easy', age: 'all', tone: 'funny' }) });
      r = await ask(ad, { t: 'a_agent_save', agent: rules }, 'a_ok');
      ok(r && r.ok && r.agent.opts.allow_lava === false && r.agent.opts.theme === 'ice', 'Studio Builder rules saved on the server');
      const mine1 = await ask(p, { t: 's_studio_mine' }, 's_studio_mine_res');
      ok(mine1 && mine1.ai === true, 'Studio sees AI as set up');
      const b = await ask(p, { t: 's_ai_build', prompt: 'a volcano run with lots of lava' }, 's_ai_res', 40000);
      ok(b && b.ok && !b.quick, `Studio game built by the AI: "${b && b.level && b.level.title}"`);
      const kinds = (b && b.level && b.level.parts || []).map(x => x[0]);
      ok(kinds.length >= 5 && !kinds.includes('lava'), `"no lava" rule enforced on the result (${kinds.join(',')})`);
      const last = JSON.parse(fs.readFileSync('/tmp/mock_omni_last.json'));
      const sys = (last.body.messages || [])[0].content || '';
      ok(sys.includes('Do not use lava.') && sys.includes('ice world') && sys.includes('Always put a star near the start. ' + tag) && sys.includes('beginners'),
        'dropdowns, toggles and extra rules are in the AI instructions');
      ok(!sys.includes('test-omni-key') && last.body.messages[1].content.includes('volcano'), 'player prompt sent, key not in the prompt');
      const ed = await ask(p, { t: 's_ai_build', prompt: 'make it harder', base: b.level }, 's_ai_res', 40000);
      ok(ed && ed.ok && !ed.quick, 'changing the game in words also goes through the AI');

      // Agent switched off: 0.7.2 AI only, so a clear "not set up" error and no game.
      r = await ask(ad, { t: 'a_agent_save', agent: Object.assign({}, rules, { on: false }) }, 'a_ok');
      const mine2 = await ask(p, { t: 's_studio_mine' }, 's_studio_mine_res');
      ok(mine2 && mine2.ai === false, 'agent off: Studio shows "AI not set up yet"');
      const q = await ask(p, { t: 's_ai_build', prompt: 'ice race' }, 's_ai_res', 20000);
      ok(q && q.ok === false && q.ai_off && !q.level, 'agent off: clear "AI isn\'t switched on" error, no stand-in game');

      // AI down: 0.7.2 error with Retry, no stand-in game.
      await ask(ad, { t: 'a_agent_save', agent: rules }, 'a_ok');
      await ask(ad, { t: 'a_ai_set', base: 'http://127.0.0.1:1/v1', model: 'mock-model' }, 'a_ok');
      const f = await ask(p, { t: 's_ai_build', prompt: 'sky islands' }, 's_ai_res', 40000);
      ok(f && f.ok === false && f.retry === true && !f.level, 'AI unreachable: error with Retry, no stand-in game (' + (f && f.why) + ')');

      // Clear the key: not set up.
      await ask(ad, { t: 'a_ai_set', base: MOCK, model: 'mock-model', clear_key: true }, 'a_ok');
      const mine3 = await ask(p, { t: 's_studio_mine' }, 's_studio_mine_res');
      ok(mine3 && mine3.ai === false, 'no key: Studio shows "AI not set up yet"');
    } else {
      const b = await ask(p, { t: 's_ai_build', prompt: 'a short jump course' }, 's_ai_res', 60000);
      ok(b && b.ok && b.level && b.level.parts.length >= 3, `Studio builds a game on this server (${b && (b.quick ? 'word builder' : 'AI')})`);
      ok(mine0 && mine0.ai === (origAi.ready && origAgent.on !== false), 'flag matches the AI settings');
    }
  } catch (e) { ok(false, 'crashed: ' + e.message); }
  finally {
    try {
      if (MOCK && ad && origAi) await ask(ad, { t: 'a_ai_set', base: origAi.base, model: origAi.model, clear_key: true }, 'a_ok');
      if (ad && origAgent && MOCK) await ask(ad, { t: 'a_agent_save', agent: origAgent }, 'a_ok');
    } catch (e) {}
  }
  console.log(`studio_ai: ${passes} passed, ${failures} failed`);
  process.exit(failures ? 1 : 0);
})();
