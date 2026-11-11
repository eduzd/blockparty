const WebSocket = require('/home/sprite/blockparty/tests/node_modules/ws');
const ws = new WebSocket(process.argv[2]);
ws.on('open', () => ws.send(JSON.stringify({ t: 'a_login', pw: 'definitely-wrong-pw', rid: 1 })));
ws.on('message', d => { const m = JSON.parse(d); if (m.t === 'a_login_res' || m.t === 'error') { console.log(JSON.stringify(m)); process.exit(0); } });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 90000);
