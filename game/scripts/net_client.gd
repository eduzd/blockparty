class_name NetClient
extends Node
## WebSocket client with cold-start retries and automatic rejoin.

signal joined(welcome: Dictionary)
signal message(msg: Dictionary)
signal status_changed(text: String, is_problem: bool)
signal gave_up(reason: String)

enum State { IDLE, CONNECTING, WAITING_WELCOME, IN_ROOM, RETRY_WAIT }

const CONNECT_TIMEOUT_MS := 20000
const GIVE_UP_AFTER_MS := 150000   # Render free tier can take about a minute to wake
const SILENCE_TIMEOUT_MS := 8000
const PING_EVERY_MS := 2000

var state: State = State.IDLE
var url := ""
var player_name := ""
var room := ""
var my_id := -1
var latency_ms := -1
var ever_joined := false

var _ws: WebSocketPeer
var _attempt := 0
var _phase_started := 0
var _trying_since := 0
var _retry_at := 0
var _last_rx := 0
var _last_ping := 0


func join(p_url: String, p_name: String, p_room: String) -> void:
	url = p_url.strip_edges()
	player_name = p_name
	room = p_room
	ever_joined = false
	_attempt = 0
	_trying_since = Time.get_ticks_msec()
	_open()


func leave() -> void:
	state = State.IDLE
	if _ws:
		_ws.close(1000, "bye")
		_ws = null


func send(data: Dictionary) -> void:
	if state == State.IN_ROOM and _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(Protocol.encode(data))


func is_in_room() -> bool:
	return state == State.IN_ROOM


func _open() -> void:
	_attempt += 1
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 65536
	var err := _ws.connect_to_url(url)
	if err != OK:
		state = State.IDLE
		gave_up.emit("That server address doesn't look right: %s" % url)
		return
	state = State.CONNECTING
	_phase_started = Time.get_ticks_msec()
	if ever_joined:
		status_changed.emit("Connection lost. Reconnecting (try %d)..." % _attempt, true)
	elif _attempt == 1:
		status_changed.emit("Connecting...", false)
	else:
		status_changed.emit("Waking up the server, this can take a minute (try %d)..." % _attempt, true)


func _process(_delta: float) -> void:
	if state == State.IDLE:
		return
	var now := Time.get_ticks_msec()
	if state == State.RETRY_WAIT:
		if now >= _retry_at:
			_open()
		return

	_ws.poll()
	var ws_state := _ws.get_ready_state()
	if ws_state == WebSocketPeer.STATE_OPEN:
		if state == State.CONNECTING:
			state = State.WAITING_WELCOME
			_phase_started = now
			_last_rx = now
			_ws.send_text(Protocol.encode({"t": "hello", "v": Protocol.VERSION, "name": player_name, "room": room}))
		while _ws.get_available_packet_count() > 0:
			var text := _ws.get_packet().get_string_from_utf8()
			var msg = Protocol.decode(text)
			if msg == null:
				continue
			_last_rx = now
			_handle(msg, now)
			if state == State.IDLE:
				return
		if state == State.IN_ROOM:
			if now - _last_ping > PING_EVERY_MS:
				_last_ping = now
				_ws.send_text(Protocol.encode({"t": "ping", "c": now}))
			if now - _last_rx > SILENCE_TIMEOUT_MS:
				_ws.close()
				_schedule_retry(now)
		elif now - _phase_started > CONNECT_TIMEOUT_MS:
			_ws.close()
			_schedule_retry(now)
	elif ws_state == WebSocketPeer.STATE_CLOSED:
		_schedule_retry(now)
	elif now - _phase_started > CONNECT_TIMEOUT_MS:
		_ws.close()
		_schedule_retry(now)


func _handle(msg: Dictionary, now: int) -> void:
	match msg.t:
		"welcome":
			state = State.IN_ROOM
			my_id = int(msg.get("id", -1))
			room = str(msg.get("room", room))
			ever_joined = true
			_attempt = 0
			_last_ping = 0
			status_changed.emit("Connected", false)
			joined.emit(msg)
		"pong":
			var sent = Protocol.parse_number(msg.get("c"))
			if sent != null:
				latency_ms = now - int(sent)
		"error":
			if msg.get("fatal", false):
				state = State.IDLE
				_ws.close()
				gave_up.emit(str(msg.get("msg", msg.get("code", "Server refused"))))
			else:
				message.emit(msg)
		_:
			message.emit(msg)


func _schedule_retry(now: int) -> void:
	if state == State.IN_ROOM:
		# Dropped mid-game: start a fresh retry window.
		_trying_since = now
		_attempt = 0
	if now - _trying_since > GIVE_UP_AFTER_MS:
		state = State.IDLE
		gave_up.emit("Couldn't reach the server. Check the address and your internet, then try again.")
		return
	var wait_ms := mini(1000 * int(pow(2.0, float(mini(_attempt, 3)))), 8000)
	state = State.RETRY_WAIT
	_retry_at = now + wait_ms
	if ever_joined:
		status_changed.emit("Connection lost. Reconnecting...", true)
	else:
		status_changed.emit("Waking up the server, this can take a minute...", true)
