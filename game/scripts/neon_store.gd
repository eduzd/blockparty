class_name NeonStore
extends Node
## Permanent storage for the social layer in a Neon Postgres database, spoken to
## over Neon's HTTPS SQL endpoint (no Postgres driver needed in Godot).
##
## Only the Render server uses it: it is switched on by the NEON_DATABASE_URL
## environment variable, so the database address and password never ship in the app.
## The hub keeps everything in memory and writes changes here in the background,
## in order, in small transactions. On start it creates the tables if they are
## missing and loads everything back.

signal loaded(data: Dictionary)
signal load_failed(why: String)

const FLUSH_EVERY_MS := 250
const MAX_BATCH := 40

var enabled := false
var is_loaded := false
var writable := false
var _conn := ""
var _endpoint := ""
var _http: HTTPRequest
var _queue: Array = []        # [{query, params}]
var _inflight: Array = []
var _mode := ""              # "", "load", "write", "single"
var _retry_at := 0
var _backoff := 1.0
var _last_flush := 0
var _log: Callable
var stats := {"written": 0, "failed": 0, "dropped": 0}
var _split_left := 0

const SCHEMA := [
	"create table if not exists bp_users (uid text primary key, name text not null default 'Player', username text not null default '', bio text not null default '', av int not null default -1, last_seen bigint not null default 0, pw text, created bigint not null default 0)",
	"create index if not exists bp_users_username on bp_users (username)",
	"create table if not exists bp_follows (a text not null, b text not null, primary key (a, b))",
	"create table if not exists bp_friends (a text not null, b text not null, primary key (a, b))",
	"create table if not exists bp_requests (to_uid text not null, from_uid text not null, primary key (to_uid, from_uid))",
	"create table if not exists bp_msgs (mid text primary key, from_uid text not null, to_uid text not null, text text not null, ts bigint not null, delivered boolean not null default false)",
	"create index if not exists bp_msgs_pair on bp_msgs (from_uid, to_uid, ts)",
	"create table if not exists bp_sessions (th text primary key, uid text not null, created bigint not null default 0)",
]


func setup(conn: String, log_cb: Callable) -> bool:
	_log = log_cb
	conn = conn.strip_edges()
	var at := conn.find("@")
	if not conn.begins_with("postgres") or at < 0:
		_log.call("NEON_DATABASE_URL does not look like a postgresql:// address; storage is off")
		return false
	var rest := conn.substr(at + 1)
	var host := rest.get_slice("/", 0).get_slice(":", 0).get_slice("?", 0)
	if host == "":
		return false
	_conn = conn
	_endpoint = "https://%s/sql" % host
	_http = HTTPRequest.new()
	_http.timeout = 20.0
	_http.use_threads = true
	_http.request_completed.connect(_on_done)
	add_child(_http)
	enabled = true
	_log.call("storage: Neon at %s" % host)
	return true


## Creates the tables and loads everything. Emits loaded(data) with arrays of rows.
func start_load() -> void:
	if not enabled or _mode != "":
		return
	var qs := []
	for s in SCHEMA + PloxHub.SCHEMA:
		qs.append({"query": s, "params": []})
	qs.append({"query": "select uid, name, username, bio, av, last_seen, pw from bp_users", "params": []})
	qs.append({"query": "select a, b from bp_follows", "params": []})
	qs.append({"query": "select a, b from bp_friends", "params": []})
	qs.append({"query": "select to_uid, from_uid from bp_requests", "params": []})
	# Undelivered messages always, plus the latest history (newest first, capped).
	qs.append({"query": "select mid, from_uid, to_uid, text, ts, delivered from bp_msgs where delivered = false or mid in (select mid from bp_msgs order by ts desc limit 20000) order by ts asc", "params": []})
	qs.append({"query": "select th, uid from bp_sessions", "params": []})
	for l in PloxHub.LOADS:
		qs.append({"query": l[1], "params": []})
	_inflight = qs
	_mode = "load"
	_post(qs)


## Queues one statement. Statements run in the order they were queued.
func exec(query: String, params: Array = []) -> void:
	if not enabled or not writable:
		return
	_queue.append({"query": query, "params": params})


func pending() -> int:
	return _queue.size() + _inflight.size()


func _post(qs: Array) -> void:
	var body := JSON.stringify({"queries": qs}) if qs.size() > 1 else JSON.stringify(qs[0])
	var headers := PackedStringArray(["Content-Type: application/json", "Neon-Connection-String: " + _conn])
	var err := _http.request(_endpoint, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_fail("request error %d" % err, true)


func _process(_delta: float) -> void:
	if not enabled:
		return
	var now := Time.get_ticks_msec()
	if _mode != "" or now < _retry_at:
		return
	if not is_loaded:
		if _retry_at != 0:
			_retry_at = 0
			start_load()
		return
	if _queue.is_empty() or now - _last_flush < FLUSH_EVERY_MS:
		return
	_last_flush = now
	var take := MAX_BATCH
	if _split_left > 0:
		take = 1
		_split_left -= 1
	_inflight = _queue.slice(0, take)
	_queue = _queue.slice(take)
	_mode = "write" if _inflight.size() > 1 else "single"
	_post(_inflight)


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var text := body.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("network result %d" % result, true)
		return
	if code >= 500 or code == 429 or code == 0:
		_fail("HTTP %d %s" % [code, text.substr(0, 200)], true)
		return
	if code != 200:
		# The SQL itself was refused. For a batch, try the statements one by one so a
		# single bad row cannot block everything behind it.
		_fail("HTTP %d %s" % [code, text.substr(0, 300)], false)
		return
	var parsed = JSON.parse_string(text)
	var mode := _mode
	var done := _inflight
	_mode = ""
	_inflight = []
	_backoff = 1.0
	if mode == "load":
		var results: Array = parsed.get("results", []) if parsed is Dictionary else []
		var n := SCHEMA.size() + PloxHub.SCHEMA.size()
		if results.size() < n + 6 + PloxHub.LOADS.size():
			_log.call("storage: unexpected load reply")
			_retry_at = Time.get_ticks_msec() + 5000
			return
		var data := {
			"users": results[n].get("rows", []), "follows": results[n + 1].get("rows", []),
			"friends": results[n + 2].get("rows", []), "requests": results[n + 3].get("rows", []),
			"msgs": results[n + 4].get("rows", []), "sessions": results[n + 5].get("rows", []),
		}
		var plox := {}
		for k in PloxHub.LOADS.size():
			plox[PloxHub.LOADS[k][0]] = results[n + 6 + k].get("rows", [])
		data["plox"] = plox
		is_loaded = true
		writable = true
		_log.call("storage: loaded %d accounts, %d messages" % [data.users.size(), data.msgs.size()])
		loaded.emit(data)
		return
	stats.written += done.size()


func _fail(why: String, transient: bool) -> void:
	var mode := _mode
	var batch := _inflight
	_mode = ""
	_inflight = []
	if mode == "load":
		_log.call("storage: load failed (%s), retrying" % why)
		_retry_at = Time.get_ticks_msec() + int(_backoff * 1000.0)
		_backoff = minf(_backoff * 2.0, 20.0)
		load_failed.emit(why)
		return
	if transient:
		# Put the batch back in front and try again a little later.
		_queue = batch + _queue
		_retry_at = Time.get_ticks_msec() + int(_backoff * 1000.0)
		_backoff = minf(_backoff * 2.0, 30.0)
		stats.failed += 1
		_log.call("storage: write failed (%s), retrying in %.0fs" % [why, _backoff])
		return
	if mode == "single":
		stats.dropped += 1
		_log.call("storage: dropped a statement (%s): %s" % [why, str(batch[0].query).substr(0, 80)])
		return
	# A refused batch: requeue its statements so they go one at a time.
	var singles := []
	for q in batch:
		singles.append(q)
	_queue = singles + _queue
	# Send exactly these statements one at a time.
	_split_left = singles.size()
