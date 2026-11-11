// Probe Neon's HTTP SQL endpoint the same way the Godot server will call it.
// Usage: NEON_DATABASE_URL=... node tests/neon_probe.js
const conn = process.env.NEON_DATABASE_URL;
if (!conn) { console.error('NEON_DATABASE_URL missing'); process.exit(2); }
const host = new URL(conn).hostname;
const endpoints = [`https://${host.replace(/^[^.]+\./, 'api.')}/sql`, `https://${host}/sql`];
(async () => {
  for (const ep of endpoints) {
    const t0 = Date.now();
    try {
      const r = await fetch(ep, { method: 'POST', headers: { 'Neon-Connection-String': conn, 'Content-Type': 'application/json' },
        body: JSON.stringify({ queries: [{ query: 'select 1 as one, now() as t', params: [] }, { query: 'select $1::text as echo', params: ['hi'] }] }) });
      const txt = await r.text();
      console.log(ep, r.status, Date.now() - t0, 'ms', txt.slice(0, 400));
    } catch (e) { console.log(ep, 'ERR', e.message); }
  }
})();
