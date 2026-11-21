// node cfg_probe.js <url> <adminpw> '<json values>'  : sets live config values as admin and prints the result.
const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const ws = new WebSocket(process.argv[2]);
let rid = 1;
const send = m => ws.send(JSON.stringify(Object.assign({ rid: rid++ }, m)));
ws.on('open', () => send({ t: 'a_login', pw: process.argv[3] }));
ws.on('message', d => {
  const m = JSON.parse(d);
  if (m.t === 'a_login_res') { if (!m.ok) { console.log(JSON.stringify(m)); process.exit(1); } send({ t: 'a_cfg_set', values: JSON.parse(process.argv[4] || '{}') }); }
  else if (m.t === 'a_ok') { console.log('set', JSON.stringify(m.changed), m.ok, m.why || ''); send({ t: 'a_cfg' }); }
  else if (m.t === 'a_cfg_res') { const c = m.cfg; console.log('now', JSON.stringify({ ai_limit_on: c.ai_limit_on, ai_per_day: c.ai_per_day, ai_one_at_a_time: c.ai_one_at_a_time, ai_global_on: c.ai_global_on, ai_global_per_day: c.ai_global_per_day })); process.exit(0); }
});
setTimeout(() => { console.log('timeout'); process.exit(1); }, 90000);
