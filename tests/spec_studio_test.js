// 0.8.0 step 2: Studio makes spec-format games (any genre) for 0.8.0 phones, while
// 0.7.2 phones keep getting obby levels and never see spec games.
//   Local:  ADMIN_PW=localadmin123 MOCK=http://127.0.0.1:8777/v1 node spec_studio_test.js ws://127.0.0.1:8910
//   Live:   PROMPTS=1 OUT=/tmp/live_specs node spec_studio_test.js wss://blockparty-server.onrender.com
// Live mode never touches the admin settings: it uses the Omni Route settings saved on the server.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const fs = require('fs');
const URL = process.argv[2] || 'ws://127.0.0.1:8910';
const ADMIN_PW = process.env.ADMIN_PW || '';
const MOCK = process.env.MOCK || '';
const OUT = process.env.OUT || '/tmp/spec_out';
const ONLY = process.env.ONLY ? process.env.ONLY.split(',').map(Number) : null;
let failures = 0, passes = 0;
const ok = (c, w) => { console.log((c ? 'PASS ' : 'FAIL ') + w); if (c) passes++; else failures++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tag = Date.now().toString(36).slice(-5);
let rid = 1;
function conn() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL, { maxPayload: 4 << 20 });
    const c = { ws, inbox: [] };
    ws.on('message', d => { const m = JSON.parse(d.toString()); if (m.t !== 'pong') c.inbox.push(m); });
    ws.on('open', () => { c.pinger = setInterval(() => ws.readyState === 1 && ws.send('{"t":"ping","c":1}'), 5000); resolve(c); });
    ws.on('close', (code, why) => { c.closed = true; c.closeWhy = code + ' ' + why; clearInterval(c.pinger); });
    ws.on('error', reject);
  });
}
const send = (c, m) => { const r = rid++; c.ws.send(JSON.stringify(Object.assign({ rid: r }, m))); return r; };
async function wait(c, pred, ms = 8000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const i = c.inbox.findIndex(pred); if (i >= 0) return c.inbox.splice(i, 1)[0]; if (c.closed) return null; await sleep(25); }
  return null;
}
async function ask(c, m, t, ms = 30000) { const r = send(c, m); return wait(c, x => (x.t === t || x.t === 'a_err') && (x.rid === r || x.rid === undefined), ms); }
async function hello(c, extra) { send(c, Object.assign({ t: 's_hello', v: 1 }, extra)); return wait(c, m => m.t === 's_welcome' || m.t === 'error', 90000); }

const PROMPTS = [
  'A 3-lap car race around a volcano with rivals',
  'Zombie waves in a graveyard, and I shoot them',
  'Collect 20 coins before time runs out in a candy city',
  'A top-down maze where I escape from a chasing ghost',
  'A sumo push-off on a shrinking platform against bots',
  'A lava obby with spinning hammers at sunset',
  'A tall tower of ice platforms with jump pads to climb to the top',
  'A racing game against other cars with checkpoints around a desert track',
  'Robots attack in waves at a space base, survive with a blaster',
  'Grab all the gems in a spooky forest at night while owls chase me',
];

function describe(lv) {
  const r = lv.rules || {}, w = r.win || {};
  const shapes = {};
  for (const e of lv.entities || []) shapes[e.shape] = (shapes[e.shape] || 0) + 1;
  const behs = {};
  for (const e of lv.entities || []) for (const b of e.behaviors || []) behs[b.type] = (behs[b.type] || 0) + 1;
  return `"${lv.title}" | controls ${lv.controls} | genre ${(lv.plan || {}).genre || '-'} | win ${w.type}${w.value ? ' ' + w.value : ''}${w.target ? ' ' + w.target : ''}` +
    ` | lose ${(r.lose || []).map(l => l.type).join(',') || '-'} | timer ${r.timer} laps ${r.laps} waves ${(r.waves || []).length} checkpoints ${(r.checkpoints || []).length}` +
    ` | abilities ${(lv.player || {}).abilities.join(',') || '-'} | lives ${(lv.player || {}).lives} | sky ${(lv.world || {}).sky} | ${(lv.entities || []).length} objects` +
    ` | shapes ${JSON.stringify(shapes)} | behaviours ${JSON.stringify(behs)}`;
}

(async () => {
  let ad = null, origAi = null;
  fs.mkdirSync(OUT, { recursive: true });
  try {
    if (MOCK) {
      ad = await conn();
      const li = await ask(ad, { t: 'a_login', pw: ADMIN_PW }, 'a_login_res');
      ok(li && li.ok, 'admin signs in (local)');
      origAi = await ask(ad, { t: 'a_ai_get' }, 'a_ai_res');
      const r = await ask(ad, { t: 'a_ai_set', base: MOCK, model: 'mock-model', key: 'test-omni-key-1234' }, 'a_ok');
      ok(r && r.t === 'a_ok', 'AI pointed at the mock router');
    }
    const p = await conn();
    const su = await ask(p, { t: 's_signup', username: 'sp' + tag, password: 'secret12', birthday: '2000-02-02' }, 's_signup_res');
    ok(su && su.ok, 'player signs up');
    const w = await hello(p, { token: su.token, app: 11 });
    ok(w && w.t === 's_welcome', '0.8.0 phone is welcomed');
    const mine0 = await ask(p, { t: 's_studio_mine', spec: 1 }, 's_studio_mine_res');
    ok(mine0 && mine0.ai === true, `Studio says the AI is set up (${mine0 && mine0.ai})`);

    const results = [];
    if (process.env.PROMPTS) {
      for (let i = 0; i < PROMPTS.length; i++) {
        if (ONLY && !ONLY.includes(i + 1)) continue;
        const t0 = Date.now();
        const res = await ask(p, { t: 's_ai_build', prompt: PROMPTS[i], spec: 1 }, 's_ai_res', 340000);
        const secs = ((Date.now() - t0) / 1000).toFixed(1);
        if (res && res.ok && res.level && res.level.entities) {
          const f = `${OUT}/p${i + 1}.json`;
          fs.writeFileSync(f, JSON.stringify(res.level));
          console.log(`PROMPT ${i + 1} OK in ${secs} s (server ${res.ms} ms): ${PROMPTS[i]}\n   -> ${describe(res.level)}\n   info: ${res.info || res.level._info || ''}\n   intro: ${res.level.intro}\n   file ${f}`);
          results.push({ i: i + 1, prompt: PROMPTS[i], ok: true, secs, ms: res.ms, info: res.info || '', desc: describe(res.level), file: f });
        } else {
          console.log(`PROMPT ${i + 1} FAILED in ${secs} s: ${PROMPTS[i]}\n   why: ${res ? res.why : 'no answer'}`);
          results.push({ i: i + 1, prompt: PROMPTS[i], ok: false, secs, why: res ? res.why : 'no answer' });
        }
        fs.writeFileSync(`${OUT}/results.json`, JSON.stringify(results, null, 1));
      }
      ok(results.every(r => r.ok), `${results.filter(r => r.ok).length} of ${results.length} prompts made a game`);
    }

    // One spec game end to end: build, change with words, publish, discover, play.
    const quick = process.env.PROMPTS && results.find(r => r.ok) ? JSON.parse(fs.readFileSync(results.find(r => r.ok).file)) : null;
    let spec = quick;
    if (!spec) {
      const b = await ask(p, { t: 's_ai_build', prompt: 'A 3-lap car race around a volcano with rivals', spec: 1 }, 's_ai_res', 340000);
      ok(b && b.ok && b.spec === 1 && b.level && Array.isArray(b.level.entities), `0.8.0 build returns a spec game (${b && (b.info || b.why)})`);
      spec = b && b.level;
      if (MOCK) ok(spec && spec.controls === 'vehicle', `mock race prompt gives a driving game (${spec && spec.controls})`);
    }
    if (MOCK) {
      const u = await ask(p, { t: 's_ai_build', prompt: 'zombie waves unwinnable', spec: 1 }, 's_ai_res', 60000);
      ok(u && u.ok && /fixed 1x/.test(u.info || ''), `an unwinnable answer goes back to the AI and comes back fixed (${u && (u.info || u.why)})`);
      const nc = await ask(p, { t: 's_ai_build', prompt: 'A 3-lap car race nevercar', spec: 1 }, 's_ai_res', 60000);
      ok(nc && nc.ok && /still missing/.test(nc.info || ''), `a game missing what the prompt asked for is sent back twice, then kept with a note (${nc && (nc.info || nc.why)})`);
      const old = await ask(p, { t: 's_ai_build', prompt: 'A lava obby with jump pads' }, 's_ai_res', 60000);
      ok(old && old.ok && Array.isArray(old.level.parts) && !old.level.entities, 'a 0.7.2 request (no spec flag) still gets an obby level');
    }
    if (spec) {
      const ch = await ask(p, { t: 's_ai_build', prompt: 'Make it night', base: spec, spec: 1 }, 's_ai_res', 340000);
      ok(ch && ch.ok && ch.level && Array.isArray(ch.level.entities), `change with words keeps the spec format (${ch && (ch.info || ch.why)}, ${JSON.stringify(spec).length} bytes sent)`);
      const pub = await ask(p, { t: 's_studio_publish', level: spec }, 's_studio_save_res', 30000);
      ok(pub && pub.ok && pub.gid, `a spec game publishes (${pub && (pub.why || pub.gid)}, ${JSON.stringify(spec).length} bytes)`);
      const gid = pub && pub.gid;
      const card = pub && pub.game;
      ok(card && card.spec === 1, `its card is tagged as a 0.8.0 game (${card && card.genre}, ${card && card.controls})`);
      // A 0.7.2 phone in another account.
      const o = await conn();
      const su2 = await ask(o, { t: 's_signup', username: 'so' + tag, password: 'secret12', birthday: '2000-02-02' }, 's_signup_res');
      await hello(o, { token: su2.token, app: 9 });
      const g72 = await ask(o, { t: 's_games', sort: 'new' }, 's_games_res');
      ok(g72 && !g72.games.some(g => g.gid === gid), '0.7.2 phones do not see the spec game in discovery');
      ok(g72 && g72.games.every(g => !g.spec), '0.7.2 discovery has only old-style games');
      const get72 = await ask(o, { t: 's_game_get', gid }, 's_game_res');
      ok(get72 && get72.ok === false, `a 0.7.2 phone opening it by id is refused (${get72 && get72.why})`);
      const g80 = await ask(o, { t: 's_games', sort: 'new', spec: 1 }, 's_games_res');
      ok(g80 && g80.games.some(g => g.gid === gid), '0.8.0 phones see it in discovery');
      const get80 = await ask(o, { t: 's_game_get', gid, spec: 1 }, 's_game_res');
      ok(get80 && get80.ok && get80.level && Array.isArray(get80.level.entities) && get80.level.entities.length === spec.entities.length,
        `a 0.8.0 phone gets the whole spec game (${get80 && get80.level && get80.level.entities.length} objects)`);
      const m72 = await ask(p, { t: 's_studio_mine' }, 's_studio_mine_res');
      ok(m72 && !m72.games.some(g => g.gid === gid), "a 0.7.2 phone's Your games list leaves the spec game out");
      const m80 = await ask(p, { t: 's_studio_mine', spec: 1 }, 's_studio_mine_res');
      ok(m80 && m80.games.some(g => g.gid === gid), "0.8.0 Your games list has it");
      const del = await ask(p, { t: 's_studio_delete', gid }, 's_studio_delete_res');
      ok(del && del.ok !== false, 'test game deleted');
      o.ws.close();
    }
    // Big messages are only allowed for Studio.
    const big = await conn();
    big.ws.send(JSON.stringify({ t: 's_chat', to: 'x', text: 'y'.repeat(9000) }));
    await sleep(1500);
    ok(big.closed, `a big non-Studio message is still refused (${big.closeWhy || 'open'})`);
    p.ws.close();
  } catch (e) {
    ok(false, 'error: ' + (e && e.stack || e));
  } finally {
    if (MOCK && ad && origAi) await ask(ad, { t: 'a_ai_set', base: origAi.base, model: origAi.model, clear_key: true }, 'a_ok');
    console.log(`DONE ${passes} passed, ${failures} failed`);
    process.exit(failures ? 1 : 0);
  }
})();
