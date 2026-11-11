class_name AdminNet
extends Node
## Plux Admin's link to the server: one WebSocket, a password sign-in, requests
## answered in order by reply type, a keep-alive, and automatic reconnects.

signal status_changed(state: String)   # "off", "connecting", "signing_in", "ready", "waking"
signal signed_out(why: String)
signal stats(s: Dictionary)

const SERVER := "wss://blockparty-server.onrender.com"
const SAVE_PATH := "user://admin_login.bin"

var ws := WebSocketPeer.new()
var state := "off"
var pw := ""
var remember := true
var cfg := {}
var defaults := {}
var last_stats := {}
var _pending: Array = []      # [msg, resp, cb] waiting for sign-in
var _waiters := {}            # resp type -> Array of [msg, cb]
var _was_open := false
var _retry_at := 0.0
var _retries := 0
var _keepalive := 0.0
var _connect_started := 0.0
var _login_cb: Callable


func _ready() -> void:
	ws.inbound_buffer_size = 4 * 1024 * 1024
	ws.outbound_buffer_size = 1024 * 1024
	ws.max_queued_packets = 4096


func saved_password() -> String:
	if not FileAccess.file_exists(SAVE_PATH):
		return ""
	var f := FileAccess.open_encrypted_with_pass(SAVE_PATH, FileAccess.READ, _device_key())
	if f == null:
		return ""
	return f.get_as_text()


func _device_key() -> String:
	return (OS.get_unique_id() + ":plux-admin-local").sha256_text()


func _store_password() -> void:
	if remember and pw != "":
		var f := FileAccess.open_encrypted_with_pass(SAVE_PATH, FileAccess.WRITE, _device_key())
		if f:
			f.store_string(pw)
	elif FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


func sign_in(password: String, keep: bool, done: Callable) -> void:
	pw = password
	remember = keep
	_login_cb = done
	_retries = 0
	if state == "ready" or state == "signing_in":
		_send({"t": "a_login", "pw": pw})
		_set_state("signing_in")
	else:
		_open()


func sign_out() -> void:
	if state == "ready":
		_send({"t": "a_logout"})
	pw = ""
	remember = false
	_store_password()
	ws.close()
	_fail_all("Signed out.")
	_set_state("off")


## Sends msg and calls cb(reply) when the reply of type resp arrives.
func rq(msg: Dictionary, resp: String, cb: Callable = Callable()) -> void:
	if state != "ready":
		_pending.append([msg, resp, cb])
		if state == "off" and pw != "":
			_open()
		return
	if not _waiters.has(resp):
		_waiters[resp] = []
	_waiters[resp].append([msg, cb])
	_send(msg)


func _send(msg: Dictionary) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(msg))


func _open() -> void:
	ws = WebSocketPeer.new()
	ws.inbound_buffer_size = 4 * 1024 * 1024
	ws.outbound_buffer_size = 1024 * 1024
	ws.max_queued_packets = 4096
	var url := SERVER
	if not OS.has_feature("mobile") and OS.get_environment("PLUX_SERVER") != "":
		url = OS.get_environment("PLUX_SERVER")   # desktop test runs only
	var err := ws.connect_to_url(url)
	_connect_started = Time.get_ticks_msec() / 1000.0
	if err != OK:
		_set_state("off")
		_schedule_retry()
		return
	_set_state("connecting")


func _set_state(s: String) -> void:
	if s != state:
		state = s
		status_changed.emit(s)


func _schedule_retry() -> void:
	_retries += 1
	_retry_at = Time.get_ticks_msec() / 1000.0 + minf(2.0 * _retries, 15.0)


func _fail_all(why: String) -> void:
	for resp in _waiters:
		for w in _waiters[resp]:
			var msg: Dictionary = w[0]
			# Reads are sent again after reconnecting; changes are not, so nothing happens twice.
			if resp != "a_ok" and resp != "a_ai_test_res" and why != "Signed out.":
				_pending.append([msg, resp, w[1]])
			elif w[1].is_valid():
				w[1].call({"t": resp, "ok": false, "why": "The connection dropped. Check, then try again."})
	_waiters.clear()
	if why == "Signed out.":
		_pending.clear()


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if state == "off":
		if pw != "" and _retry_at > 0.0 and now >= _retry_at:
			_retry_at = 0.0
			_open()
		return
	ws.poll()
	var rs := ws.get_ready_state()
	if rs == WebSocketPeer.STATE_CONNECTING:
		if state == "connecting" and now - _connect_started > 6.0:
			_set_state("waking")   # the free server sleeps; waking it takes up to a minute
		if now - _connect_started > 75.0:
			ws.close()
		return
	if rs == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			_set_state("signing_in")
			_send({"t": "a_login", "pw": pw})
		while ws.get_available_packet_count() > 0:
			var m = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if m is Dictionary:
				_on_msg(m)
		if state == "ready":
			_keepalive += delta
			if _keepalive >= 10.0:
				_keepalive = 0.0
				rq({"t": "a_stats"}, "a_stats_res")
		return
	if rs == WebSocketPeer.STATE_CLOSED:
		var was := _was_open
		_was_open = false
		_fail_all("closed")
		_set_state("off")
		if pw != "":
			_schedule_retry()
		if not was and _login_cb.is_valid() and _retries >= 3:
			var cb := _login_cb
			_login_cb = Callable()
			cb.call(false, "Can't reach the Plux server. Check your internet. The free server can take a minute to wake up.")


func _on_msg(m: Dictionary) -> void:
	var t := str(m.get("t", ""))
	if t == "a_login_res":
		if m.get("ok", false):
			_retries = 0
			cfg = m.get("cfg", {})
			defaults = m.get("defaults", {})
			last_stats = m.get("stats", {})
			_store_password()
			_set_state("ready")
			if _login_cb.is_valid():
				var cb := _login_cb
				_login_cb = Callable()
				cb.call(true, "")
			stats.emit(last_stats)
			var p := _pending
			_pending = []
			for x in p:
				rq(x[0], x[1], x[2])
		else:
			var why := str(m.get("why", "Wrong password."))
			pw = ""
			_store_password()
			_fail_all("Signed out.")
			ws.close()
			_set_state("off")
			if _login_cb.is_valid():
				var cb2 := _login_cb
				_login_cb = Callable()
				cb2.call(false, why)
			else:
				signed_out.emit(why)
		return
	if t == "a_err":
		if str(m.get("why", "")) == "not_admin" and pw != "":
			_set_state("signing_in")
			_send({"t": "a_login", "pw": pw})
		return
	if t == "a_stats_res":
		last_stats = m.get("stats", {})
		stats.emit(last_stats)
	if m.has("cfg") and m.cfg is Dictionary and (t == "a_ok" or t == "a_cfg_res"):
		cfg = m.cfg
		if m.has("defaults"):
			defaults = m.defaults
	if _waiters.has(t) and not _waiters[t].is_empty():
		var w: Array = _waiters[t].pop_front()
		if w[1].is_valid():
			w[1].call(m)
