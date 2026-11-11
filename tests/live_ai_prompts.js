// 0.7.2: real prompts through the live server's AI path (the user's saved Omni Route settings).
//   node live_ai_prompts.js wss://blockparty-server.onrender.com "prompt 1" "prompt 2" ...
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const fs = require('fs');
const URL = process.argv[2];
const prompts = process.argv.slice(3);
let rid = 1;
const sleep = ms => new Promise(r => setTimeout(r, ms));
function conn() { return new Promise((res, rej) => { const ws = new WebSocket(URL); const c = { ws, inbox: [] };
  ws.on('message', d => c.inbox.push(JSON.parse(d.toString()))); ws.on('open', () => res(c)); ws.on('error', rej); }); }
async function ask(c, m, t, ms = 60000) { const r = rid++; c.ws.send(JSON.stringify(Object.assign({ rid: r }, m)));
  const end = Date.now() + ms; while (Date.now() < end) { const i = c.inbox.findIndex(x => x.t === t || x.t === 's_err'); if (i >= 0) return c.inbox.splice(i, 1)[0]; await sleep(50); } return null; }
(async () => {
  const out = [];
  let pl = null, used = 99;
  for (const p of prompts) {
    if (used >= 4) {   // fresh test account every 4 builds (daily cap 5)
      pl = await conn();
      const nm = 'aitest' + Date.now().toString(36).slice(-6);
      const su = await ask(pl, { t: 's_signup', username: nm, password: 'secret12', birthday: '2000-02-02' }, 's_signup_res', 90000);
      if (!su || !su.ok) { console.log('signup failed', JSON.stringify(su)); process.exit(1); }
      pl.ws.send(JSON.stringify({ t: 's_hello', v: 1, token: su.token, rid: rid++ }));
      await sleep(2000); used = 0;
    }
    const t0 = Date.now();
    const r = await ask(pl, { t: 's_ai_build', prompt: p }, 's_ai_res', 340000);
    used++;
    const secs = ((Date.now() - t0) / 1000).toFixed(0);
    if (!r) { console.log(`TIMEOUT "${p}"`); out.push({ p, ok: false }); continue; }
    if (!r.ok) { console.log(`FAIL "${p}" ${secs}s: ${r.why}`); out.push({ p, ok: false, why: r.why }); continue; }
    const lv = r.level, kinds = {};
    lv.parts.forEach(x => kinds[x[0]] = (kinds[x[0]] || 0) + 1);
    const cols = {}; lv.parts.forEach(x => cols[x[8]] = (cols[x[8]] || 0) + 1);
    console.log(`OK "${p}" ${secs}s source=${r.source} title="${lv.title}" sky=${lv.sky} parts=${lv.parts.length} kinds=${JSON.stringify(kinds)} colors=${JSON.stringify(cols)}`);
    out.push({ p, ok: true, source: r.source, level: lv });
  }
  fs.writeFileSync('/tmp/live_ai_levels.json', JSON.stringify(out, null, 1));
  process.exit(0);
})();
