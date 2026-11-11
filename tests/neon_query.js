// Runs one read-only SQL query on Neon. Usage: NEON_DATABASE_URL=... node tests/neon_query.js "select ..."
const conn = process.env.NEON_DATABASE_URL;
const host = new URL(conn).hostname;
(async () => {
  const r = await fetch(`https://${host}/sql`, { method: 'POST', headers: { 'Neon-Connection-String': conn, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: process.argv[2], params: [] }) });
  const j = await r.json();
  console.log(r.status, JSON.stringify(j.rows || j));
})();
