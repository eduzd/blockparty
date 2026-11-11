class_name RefereeServer
extends Node
## Authoritative referee. Runs inside the app ("Host on this phone")
## or headless on Render. Speaks small JSON messages over WebSocket.

signal log_line(text: String)

var port := 0
var _tcp := TCPServer.new()
var _pending: Array = []      # [{ws, since}]
var _closing: Array = []      # [{ws, since}]
var _clients := {}            # id -> Dictionary
var _rooms := {}              # code -> Array[int]
var _balls := {}              # code -> BallSim
var _wind := {}               # code -> {now: Vector2, target: Vector2, next_change: float}
var _clock := 0.0
var _gravity := {}            # code -> {sign: float} (follows BeatClock)
var balls_enabled := true
var _pop := {}                # room key "P:CODE" -> PopRoom (Pop-Up Panic)
var _snap_n := 0
## ICE servers handed to voice clients in the welcome. Free public STUN by default.
## A TURN relay can be added later with the VOICE_ICE_SERVERS environment variable
## (a JSON array like [{"urls":["turn:host:3478"],"username":"u","credential":"p"}])
## so no address or credential is baked into the app.
var voice_ice: Array = [{"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]}]
var _next_id := 1
var _snap_accum := 0.0
## Profiles, friends, follows and chat (see SocialHub). Same port as the game.
var social: SocialHub
var plox: PloxHub
var _bytes_out := 0
var _bytes_in := 0
var _bytes_at := 0
## Permanent storage for the social layer, when NEON_DATABASE_URL is set (Render).
var store: NeonStore
var _store_wait_since := 0
const STORE_GIVE_UP_MS := 45000


func start(p_port: int, bind_address: String = "*") -> Error:
	social = SocialHub.new(func(cid: int, data: Dictionary):
		if _clients.has(cid):
			_send(_clients[cid], data), _log)
	plox = PloxHub.new(social)
	plox.referee = self
	add_child(plox)
	social.plox = plox
	if OS.has_environment("NEON_DATABASE_URL") and OS.get_environment("NEON_DATABASE_URL") != "":
		store = NeonStore.new()
		add_child(store)
		if store.setup(OS.get_environment("NEON_DATABASE_URL"), _log):
			social.attach_store(store)
			store.loaded.connect(func(data: Dictionary):
				social.load_from(data)
				plox.load_from(data.get("plox", {}))
				_release_held())
			_store_wait_since = Time.get_ticks_msec()
			store.start_load()
		else:
			store.queue_free()
			store = null
	if OS.has_environment("VOICE_ICE_SERVERS"):
		var parsed = JSON.parse_string(OS.get_environment("VOICE_ICE_SERVERS"))
		if parsed is Array:
			voice_ice = parsed
		else:
			_log("VOICE_ICE_SERVERS is not a JSON array; using public STUN")
	var err := _tcp.listen(p_port, bind_address)
	if err == OK:
		port = p_port
		_log("Referee listening on port %d" % p_port)
	else:
		_log("Could not listen on port %d (error %d)" % [p_port, err])
	return err


func stop() -> void:
	for id in _clients.keys():
		_clients[id].ws.close(1001, "server stopping")
		if social:
			social.on_disconnect(id, 0)
	_clients.clear()
	_rooms.clear()
	_balls.clear()
	_wind.clear()
	_gravity.clear()
	_pop.clear()
	_pending.clear()
	_tcp.stop()


func is_running() -> bool:
	return _tcp.is_listening()


func player_count() -> int:
	return _clients.size()


func _process(delta: float) -> void:
	if not _tcp.is_listening():
		return
	var now := Time.get_ticks_msec()
	if now - _bytes_at > 2000 and plox:
		_bytes_at = now
		# Rough bandwidth count for the admin app (WebSocket payloads plus ~6 bytes of framing).
		plox.note_bytes(_bytes_out, _bytes_in)
		_bytes_out = 0
		_bytes_in = 0
	_accept_new(now)
	_poll_pending(now)
	_poll_clients(now)
	_poll_closing(now)
	if store != null and store.enabled and not store.is_loaded and now - _store_wait_since > STORE_GIVE_UP_MS:
		# The database never answered: carry on in memory so nobody is locked out.
		_log("storage: database not reachable, running in memory only")
		store.enabled = false
		_release_held()
	_clock += delta
	for room in _rooms.keys():
		if _pop.has(room):
			continue
		_update_wind(room, delta)
		_update_gravity(room, now)
	for room in _pop.keys():
		_pop_tick(room, delta, now)
	if balls_enabled:
		for room in _balls.keys():
			var feet := {}
			for id in _rooms.get(room, []):
				feet[id] = _clients[id].pos
			_balls[room].wind = _wind[room].now
			_balls[room].gravity_sign = _gravity[room].sign
			for knock in _balls[room].advance(delta, feet, now / 1000.0):
				_knock(knock[0], knock[1])
	_snap_accum += delta
	var step := 1.0 / Protocol.SNAPSHOT_HZ
	if _snap_accum >= step:
		_snap_accum = fmod(_snap_accum, step)
		_broadcast_snapshots(now)


func _accept_new(now: int) -> void:
	while _tcp.is_connection_available():
		var conn: StreamPeerTCP = _tcp.take_connection()
		if _clients.size() + _pending.size() >= Protocol.MAX_CONNECTIONS:
			conn.disconnect_from_host()
			continue
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 16384
		ws.outbound_buffer_size = 65536
		if ws.accept_stream(conn) == OK:
			_pending.append({"ws": ws, "since": now})


func _poll_pending(now: int) -> void:
	for i in range(_pending.size() - 1, -1, -1):
		var entry: Dictionary = _pending[i]
		var ws: WebSocketPeer = entry.ws
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			_pending.remove_at(i)
			var id := _next_id
			_next_id += 1
			_clients[id] = {
				"id": id, "ws": ws, "name": "", "room": "", "color": 0,
				"pos": Protocol.SPAWN, "yaw": 0.0,
				"joined_at": now, "last_msg": now, "last_move": now,
				"h_budget": Protocol.H_BUDGET_MAX, "up_budget": Protocol.UP_BUDGET_MAX,
				"win_start": now, "win_count": 0, "bad": 0,
			}
		elif state == WebSocketPeer.STATE_CLOSED or now - int(entry.since) > Protocol.HELLO_TIMEOUT_MS:
			# Also clears Render's plain TCP health probes.
			ws.close()
			_pending.remove_at(i)


func _poll_clients(now: int) -> void:
	for id in _clients.keys():
		if not _clients.has(id):
			continue
		var c: Dictionary = _clients[id]
		var ws: WebSocketPeer = c.ws
		ws.poll()
		if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
			_remove(id, "disconnected")
			continue
		while _clients.has(id) and ws.get_available_packet_count() > 0:
			var pkt := ws.get_packet()
			_bytes_in += pkt.size() + 6
			_handle_packet(c, pkt, ws.was_string_packet(), now)
		if not _clients.has(id):
			continue
		if c.room == "" and not bool(c.get("social", false)) and not c.has("held") and not bool(c.get("admin", false)) \
				and now - int(c.joined_at) > Protocol.HELLO_TIMEOUT_MS:
			_kick(id, "hello_timeout", "No hello received")
		elif now - int(c.last_msg) > Protocol.IDLE_TIMEOUT_MS:
			_kick(id, "idle", "Timed out")


func _poll_closing(now: int) -> void:
	for i in range(_closing.size() - 1, -1, -1):
		var ws: WebSocketPeer = _closing[i].ws
		ws.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED or now - int(_closing[i].since) > 3000:
			_closing.remove_at(i)


func _handle_packet(c: Dictionary, pkt: PackedByteArray, is_text: bool, now: int) -> void:
	var id: int = c.id
	if pkt.size() > Protocol.MAX_SIGNAL_BYTES:
		_kick(id, "too_big", "Message too large")
		return
	var msg = Protocol.decode(pkt.get_string_from_utf8(), Protocol.MAX_SIGNAL_BYTES) if is_text else null
	if msg == null:
		_bad(c, "bad_message")
		return
	var is_signal: bool = msg.t == "vsig"
	var is_social := SocialHub.is_social(msg.t)
	if pkt.size() > Protocol.MAX_MESSAGE_BYTES and not is_signal and not is_social and not str(msg.t).begins_with("a_"):
		_kick(id, "too_big", "Message too large")
		return
	# Rate limits (0.6.0): token buckets refilled by the clock, not by how often
	# we got round to reading. When the server falls behind, or a phone's
	# connection freezes and then catches up, a backlog arrives at once: we
	# drop what is over the limit instead of kicking. Only a client that keeps
	# sending far over the limit for several seconds is kicked.
	var over := not _take_token(c, "sig" if is_signal else "msg", now,
		Protocol.MAX_SIGNALS_PER_SEC if is_signal else Protocol.MAX_MSGS_PER_SEC)
	c.last_msg = now
	if over:
		c.dropped = int(c.get("dropped", 0)) + 1
		if now - int(c.get("drop_since", 0)) > Protocol.FLOOD_WINDOW_MS:
			c.drop_since = now
			c.dropped = 1
		elif int(c.dropped) > Protocol.FLOOD_KICK_DROPS:
			_kick(id, "rate_limit", "Too many messages")
			return
		# Movement is sent 20 times a second, so a newer one is always coming:
		# drop it. Anything else (a chat message, a purchase) still goes through.
		if msg.t == "state":
			return
	if plox.is_admin_type(str(msg.t)):
		# Admin app: never a player connection. The password is checked by PloxHub.
		if c.room != "" or bool(c.get("social", false)):
			_bad(c, "not_admin")
			return
		c.admin = true
		var aerr := plox.admin_handle(c.id, msg, func(d: Dictionary): _send(c, d))
		if aerr != "":
			_bad(c, aerr)
		return
	if is_social:
		_on_social(c, msg)
		return
	match msg.t:
		"hello":
			_on_hello(c, msg, now)
		"state":
			if c.room == "":
				_bad(c, "not_in_room")
			elif _pop.has(c.room):
				_on_pop_state(c, msg, now)
			else:
				_on_state(c, msg, now)
		"bonk":
			if c.room == "" or not _pop.has(c.room):
				_bad(c, "not_in_room")
			else:
				var by = Protocol.parse_number(msg.get("y"))
				if by == null:
					_bad(c, "bad_state")
				elif not bool(c.get("pop_out", false)):
					_pop[c.room].bonk(c.id, wrapf(float(by), -PI, PI), now)
		"ping":
			var stamp = Protocol.parse_number(msg.get("c"))
			_send(c, {"t": "pong", "c": stamp if stamp != null else 0})
		"vjoin":
			_on_voice_join(c)
		"vleave":
			_on_voice_leave(c)
		"vsig":
			_on_voice_signal(c, msg)
		_:
			_bad(c, "unknown_type")


# ---------------------------------------------------------------- social
# A social connection never joins a room: it says s_hello instead of hello and then
# only sends s_* messages (and pings) while the app is open.

func _store_waiting() -> bool:
	return store != null and store.enabled and not store.is_loaded


## Sign-ins that arrived while the database was still loading go through now.
func _release_held() -> void:
	for id in _clients.keys():
		if not _clients.has(id) or not _clients[id].has("held"):
			continue
		var c: Dictionary = _clients[id]
		var held: Array = c.held
		c.erase("held")
		c.joined_at = Time.get_ticks_msec()
		for m in held:
			if _clients.has(id):
				_on_social(c, m)


func _on_social(c: Dictionary, msg: Dictionary) -> void:
	var unix := int(Time.get_unix_time_from_system())
	if (msg.t == "s_hello" or msg.t == "s_login") and _store_waiting() and not bool(c.get("social", false)):
		# Hold sign-ins until the accounts are loaded from the database.
		var held: Array = c.get("held", [])
		if held.size() >= 3:
			_bad(c, "busy")
			return
		held.append(msg)
		c.held = held
		return
	if msg.t == "s_login":
		if c.room != "" or bool(c.get("social", false)):
			_bad(c, "already_joined")
			return
		c.login_tries = int(c.get("login_tries", 0)) + 1
		if c.login_tries > 5:
			_kick(c.id, "rate_limit", "Too many tries")
			return
		var res := social.on_login(msg, unix)
		if msg.has("rid"):
			res["rid"] = msg.rid
		_send(c, res)
		c.joined_at = Time.get_ticks_msec()
		return
	if msg.t == "s_hello":
		if c.room != "" or bool(c.get("social", false)):
			_bad(c, "already_joined")
			return
		if msg.get("v") != Protocol.VERSION and msg.get("v") != float(Protocol.VERSION):
			_kick(c.id, "bad_version", "Please update the app")
			return
		var err := social.on_hello(c.id, msg, unix)
		if err != "":
			_kick(c.id, err, "Sign-in refused")
			return
		c.social = true
		return
	if not bool(c.get("social", false)) or not social.is_signed_in(c.id):
		_bad(c, "not_signed_in")
		return
	var err2 := social.handle(c.id, msg, unix)
	if err2 != "":
		_bad(c, err2)


# ---------------------------------------------------------------- voice signalling
# Voice audio goes phone to phone over WebRTC. The referee only passes the small
# setup messages (offers, answers, ICE candidates) between talkers in the SAME room,
# and tells the room who is in voice. It never sees or stores any audio.

func _voice_members(room: String) -> Array:
	var out := []
	for other_id in _rooms.get(room, []):
		if _clients.has(other_id) and bool(_clients[other_id].get("voice", false)):
			out.append(other_id)
	return out


func _on_voice_join(c: Dictionary) -> void:
	if c.room == "":
		_bad(c, "not_in_room")
		return
	if bool(c.get("voice", false)):
		return
	var others := _voice_members(c.room)
	c.voice = true
	# The newcomer calls everyone already talking; they answer.
	_send(c, {"t": "vpeers", "ids": others})
	_broadcast(c.room, {"t": "vjoin", "id": c.id}, c.id)


func _on_voice_leave(c: Dictionary) -> void:
	if not bool(c.get("voice", false)):
		return
	c.voice = false
	if c.room != "":
		_broadcast(c.room, {"t": "vleave", "id": c.id}, c.id)


func _on_voice_signal(c: Dictionary, msg: Dictionary) -> void:
	if c.room == "" or not bool(c.get("voice", false)):
		_bad(c, "not_in_voice")
		return
	var to = Protocol.parse_number(msg.get("to"))
	if to == null or not _clients.has(int(to)) or int(to) == c.id:
		return   # they may have just left; not the sender's fault
	var target: Dictionary = _clients[int(to)]
	if target.room != c.room or not bool(target.get("voice", false)):
		return
	var out := {"t": "vsig", "from": c.id}
	match msg.get("k"):
		"offer", "answer":
			var sdp = msg.get("sdp")
			if not (sdp is String) or sdp.length() > Protocol.MAX_SDP_CHARS:
				_bad(c, "bad_signal")
				return
			out.k = msg.k
			out.sdp = sdp
		"ice":
			var cand = msg.get("cand")
			var mid = msg.get("mid")
			var idx = Protocol.parse_number(msg.get("idx"))
			if not (cand is String) or cand.length() > Protocol.MAX_ICE_CHARS or not (mid is String) \
					or mid.length() > 16 or idx == null:
				_bad(c, "bad_signal")
				return
			out.k = "ice"
			out.cand = cand
			out.mid = mid
			out.idx = clampi(int(idx), 0, 16)
		_:
			_bad(c, "bad_signal")
			return
	_send(target, out)


func _on_hello(c: Dictionary, msg: Dictionary, now: int) -> void:
	if c.room != "":
		_bad(c, "already_joined")
		return
	if msg.get("v") != Protocol.VERSION and msg.get("v") != float(Protocol.VERSION):
		_kick(c.id, "bad_version", "Please update the app")
		return
	var room := Protocol.sanitize_room(msg.get("room"))
	if str(msg.get("g", "")) == "pop":
		_on_pop_hello(c, msg, room, now)
		return
	var members: Array = _rooms.get(room, [])
	if not _rooms.has(room) and _rooms.size() >= Protocol.MAX_ROOMS:
		_kick(c.id, "server_full", "Server is full, try later")
		return
	if members.size() >= Protocol.MAX_PLAYERS_PER_ROOM:
		_kick(c.id, "room_full", "Room %s is full (%d players)" % [room, Protocol.MAX_PLAYERS_PER_ROOM])
		return
	var used := {}
	for other_id in members:
		used[_clients[other_id].color] = true
	var color := 0
	while used.has(color):
		color += 1
	c.name = Protocol.sanitize_name(msg.get("name"))
	c.room = room
	c.color = color
	var angle := TAU * float(members.size()) / Protocol.MAX_PLAYERS_PER_ROOM
	c.pos = Protocol.SPAWN + Vector3(cos(angle), 0, sin(angle)) * 2.0
	c.last_move = now
	members.append(c.id)
	_rooms[room] = members
	if balls_enabled and not _balls.has(room):
		_balls[room] = BallSim.new(room.hash())
	if not _gravity.has(room):
		_gravity[room] = {"sign": BeatClock.gravity_sign(now / 1000.0)}
	if not _wind.has(room):
		_wind[room] = {"now": Vector2.ZERO, "target": Vector2.ZERO, "next_change": _clock + randf_range(2.0, 5.0)}
	if _balls.has(room):
		_balls[room].on_player_spawned(c.id)
	var others := []
	for other_id in members:
		if other_id != c.id:
			others.append(_describe(_clients[other_id]))
	_send(c, {"t": "welcome", "id": c.id, "room": room, "name": c.name, "c": color,
		"spawn": Protocol.vec_to_array(c.pos), "max": Protocol.MAX_PLAYERS_PER_ROOM, "players": others,
		"ball_radii": BallSim.RADII if balls_enabled else [], "g": _gravity[room].sign, "ts": now,
		"voice": {"ice": voice_ice, "talkers": _voice_members(room)}})
	_broadcast(room, {"t": "join", "p": _describe(c)}, c.id)
	_log("%s joined room %s (%d/%d)" % [c.name, room, members.size(), Protocol.MAX_PLAYERS_PER_ROOM])


func _on_state(c: Dictionary, msg: Dictionary, now: int) -> void:
	var target = Protocol.parse_vec3(msg.get("p"))
	var yaw = Protocol.parse_number(msg.get("y"))
	if target == null or yaw == null:
		_bad(c, "bad_state")
		return
	var dt := clampf(float(now - int(c.last_move)) / 1000.0, 0.0, 1.0)
	c.last_move = now
	var wind_speed: float = _wind[c.room].now.length() if _wind.has(c.room) else 0.0
	var h_rate := (Protocol.MOVE_SPEED + wind_speed + 1.0) * 1.35
	c.h_budget = maxf(c.h_budget, minf(c.h_budget + h_rate * dt, Protocol.H_BUDGET_MAX))
	c.up_budget = maxf(c.up_budget, minf(c.up_budget + Protocol.UP_BUDGET_RATE * dt, Protocol.UP_BUDGET_MAX))
	c.yaw = wrapf(float(yaw), -PI, PI)

	var current: Vector3 = c.pos
	var g: float = _gravity[c.room].sign if _gravity.has(c.room) else 1.0
	var in_grace: bool = now < int(c.get("grace_until", 0))
	# Trampoline floor: anyone near the ground may be launched to the ceiling.
	if g > 0.0 and (current.y < Protocol.TRAMPOLINE_ZONE_Y or target.y < Protocol.TRAMPOLINE_ZONE_Y):
		c.up_budget = maxf(c.up_budget, Protocol.TRAMPOLINE_UP_BUDGET)
	if in_grace:
		c.up_budget = maxf(c.up_budget, Protocol.TRAMPOLINE_UP_BUDGET)
	if target.y < Protocol.MIN_Y:
		_correct(c, Protocol.SPAWN, "fell")
		if _balls.has(c.room):
			_balls[c.room].on_player_spawned(c.id)
		return
	var h_step := Vector2(target.x - current.x, target.z - current.z).length()
	# "Up" means against gravity: falling is free, jumping costs budget.
	var up_step := maxf((target.y - current.y) * g, 0.0)
	if in_grace:
		up_step = 0.0
	if h_step > c.h_budget or up_step > c.up_budget:
		_correct(c, current, "too_fast")
		return
	c.h_budget -= h_step
	c.up_budget -= up_step
	var clamped := Vector3(
		clampf(target.x, -Protocol.WORLD_HALF, Protocol.WORLD_HALF),
		clampf(target.y, Protocol.MIN_Y, Protocol.MAX_Y),
		clampf(target.z, -Protocol.WORLD_HALF, Protocol.WORLD_HALF))
	c.pos = clamped
	if not clamped.is_equal_approx(target):
		_correct(c, clamped, "out_of_bounds")


func _correct(c: Dictionary, pos: Vector3, reason: String) -> void:
	c.pos = pos
	c.h_budget = Protocol.H_BUDGET_MAX
	c.up_budget = Protocol.UP_BUDGET_MAX
	_send(c, {"t": "correct", "p": Protocol.vec_to_array(pos), "why": reason})


func _update_wind(room: String, delta: float) -> void:
	var w: Dictionary = _wind[room]
	if _clock >= float(w.next_change):
		if w.target == Vector2.ZERO and randf() < 0.75:
			# A gust: random direction and strength, lasting 1.5 to 3.5 s
			w.target = Vector2.from_angle(randf() * TAU) * randf_range(3.0, Protocol.WIND_MAX)
			w.next_change = _clock + randf_range(1.5, 3.5)
		else:
			w.target = Vector2.ZERO
			w.next_change = _clock + randf_range(2.0, 6.0)
	w.now = (w.now as Vector2).move_toward(w.target, Protocol.WIND_MAX * 1.5 * delta)


func _update_gravity(room: String, now: int) -> void:
	var gr: Dictionary = _gravity[room]
	# Locked to the beat drop: same clock as the music and the origami fold.
	var s := BeatClock.gravity_sign(now / 1000.0)
	if s != float(gr.sign):
		gr.sign = s
		for id in _rooms[room]:
			_clients[id].grace_until = now + Protocol.FLIP_GRACE_MS
		_broadcast(room, {"t": "gravity", "g": gr.sign}, -1)
		_log("Gravity flipped in room %s (%s)" % [room, "upside down" if gr.sign < 0.0 else "normal"])


func _knock(id: int, velocity: Vector3) -> void:
	if not _clients.has(id):
		return
	var c: Dictionary = _clients[id]
	c.h_budget += Protocol.BUMP_BUDGET
	c.up_budget += Protocol.BUMP_BUDGET
	_send(c, {"t": "bump", "v": Protocol.vec_to_array(velocity)})


func _broadcast_snapshots(now: int) -> void:
	_snap_n += 1
	for room in _rooms.keys():
		var list := []
		for id in _rooms[room]:
			var c: Dictionary = _clients[id]
			var p: Vector3 = c.pos
			list.append([id, snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01), snappedf(c.yaw, 0.01)])
		var snap := {"t": "snap", "ts": now, "pl": list}
		if _pop.has(room):
			var pr: PopRoom = _pop[room]
			list.append_array(pr.bot_snapshot_entries())
			if _snap_n % Protocol.SNAPSHOT_HZ == 0:
				snap["sc"] = pr.score_list()
			_broadcast(room, snap, -1)
			continue
		if _balls.has(room):
			snap["b"] = _balls[room].to_array()
		if _wind.has(room):
			var w: Vector2 = _wind[room].now
			snap["w"] = [snappedf(w.x, 0.01), snappedf(w.y, 0.01)]
		if _gravity.has(room):
			snap["g"] = _gravity[room].sign
			snap["gn"] = snappedf(BeatClock.until_drop(now / 1000.0), 0.1)
		_broadcast(room, snap, -1)


# ---------------------------------------------------------------- Pop-Up Panic
# A second game on the same referee. Its rooms are keyed "P:CODE" so they never mix
# with the neon world. The phone moves its own character (instant controls); the
# referee keeps the round clock and scores, checks every bonk, and runs the bots.

func _on_pop_hello(c: Dictionary, msg: Dictionary, code: String, now: int) -> void:
	var key := "P:" + code
	var members: Array = _rooms.get(key, [])
	if not _rooms.has(key) and _rooms.size() >= Protocol.MAX_ROOMS:
		_kick(c.id, "server_full", "Server is full, try later")
		return
	if members.size() >= Protocol.MAX_PLAYERS_PER_ROOM:
		_kick(c.id, "room_full", "Room %s is full (%d players)" % [code, Protocol.MAX_PLAYERS_PER_ROOM])
		return
	var pr: PopRoom = _pop.get(key)
	if pr == null:
		pr = PopRoom.new(code, now)
		pr.broadcast = func(data: Dictionary): _broadcast(key, data, -1)
		pr.knock_human = func(hid: int, v: Vector3): _pop_knock(hid, v)
		pr.respawn_human = func(hid: int, pos: Vector3):
			if _clients.has(hid):
				_clients[hid].pop_out = false
				_correct(_clients[hid], pos, "round")
		pr.new_id = func() -> int:
			var nid := _next_id
			_next_id += 1
			return nid
		var nb = Protocol.parse_number(msg.get("bots"))
		pr.want_bots = clampi(int(nb) if nb != null else 3, 0, mini(PopRules.MAX_BOTS, plox.cfg.i("pop_max_bots")))
		pr.round_len_s = float(plox.cfg.i("pop_round_s"))
		pr.on_round_end = func(scores: Dictionary, human_ids: Array):
			var uids := {}
			for hid in human_ids:
				if _clients.has(hid):
					uids[hid] = str(_clients[hid].get("uid", ""))
			plox.on_pop_round(scores, uids)
		_pop[key] = pr
	var used := {}
	for other_id in members:
		used[_clients[other_id].color] = true
	var color := 0
	while used.has(color):
		color += 1
	var ch = Protocol.parse_number(msg.get("ch"))
	c.name = Protocol.sanitize_name(msg.get("name"))
	c.uid = plox.ticket_uid(msg.get("tk"))   # who to pay Plux to (empty = guest)
	c.room = key
	c.color = color
	c.ch = clampi(int(ch) if ch != null else color, 0, PopRules.CHARACTERS.size() - 1)
	c.pos = PopRules.random_spawn(pr.rng)
	c.last_move = now
	c.pop_out = false
	members.append(c.id)
	_rooms[key] = members
	pr.add_human(c, now)
	var others := []
	for other_id in members:
		if other_id != c.id:
			others.append(_describe(_clients[other_id]))
	for b in pr.bots.values():
		others.append(pr.describe_bot(b))
	_send(c, {"t": "welcome", "id": c.id, "room": code, "name": c.name, "c": color, "g": "pop", "ch": c.ch,
		"spawn": Protocol.vec_to_array(c.pos), "max": Protocol.MAX_PLAYERS_PER_ROOM, "players": others,
		"ts": now, "r": pr.round_info(now), "sc": pr.score_list(),
		"voice": {"ice": voice_ice, "talkers": _voice_members(key)}})
	_broadcast(key, {"t": "join", "p": _describe(c)}, c.id)
	pr.fill_bots()
	_log("%s joined Pop-Up Panic room %s (%d people, %d bots)" % [c.name, code, members.size(), pr.bots.size()])


func _on_pop_state(c: Dictionary, msg: Dictionary, now: int) -> void:
	var target = Protocol.parse_vec3(msg.get("p"))
	var yaw = Protocol.parse_number(msg.get("y"))
	if target == null or yaw == null:
		_bad(c, "bad_state")
		return
	c.last_move = now
	if bool(c.get("pop_out", false)):
		return   # waiting to drop back in
	c.yaw = wrapf(float(yaw), -PI, PI)
	var pr: PopRoom = _pop[c.room]
	if target.y < PopRules.FALL_Y:
		c.pop_out = true
		c.pop_back_at = now + 1700
		c.pos = Vector3(target.x, PopRules.FALL_Y, target.z)
		pr.knocked_out(c.id, now)
		return
	# Light sanity limits only: this is a party game among friends.
	c.pos = Vector3(clampf(target.x, -40.0, 40.0), clampf(target.y, PopRules.FALL_Y, 30.0), clampf(target.z, -40.0, 40.0))
	if absf(c.pos.y) < 0.05 and PopRules.on_table(c.pos):
		pr.landed(c.id)


func _pop_tick(key: String, delta: float, now: int) -> void:
	var pr: PopRoom = _pop[key]
	pr.tick(delta, now)
	for id in _rooms.get(key, []):
		var c: Dictionary = _clients[id]
		if bool(c.get("pop_out", false)) and now >= int(c.get("pop_back_at", 0)):
			c.pop_out = false
			var m := pr._meta_for(id)
			m.shield_until = now + int(PopRules.SHIELD_S * 1000.0)
			_correct(c, PopRules.random_spawn(pr.rng), "respawn")


func _pop_knock(id: int, v: Vector3) -> void:
	if _clients.has(id):
		_send(_clients[id], {"t": "bump", "v": Protocol.vec_to_array(v)})


func _describe(c: Dictionary) -> Dictionary:
	var d := {"id": c.id, "name": c.name, "c": c.color, "p": Protocol.vec_to_array(c.pos), "y": snappedf(c.yaw, 0.01)}
	if c.has("ch"):
		d["ch"] = c.ch
	return d


func _bad(c: Dictionary, code: String) -> void:
	c.bad += 1
	if c.bad > Protocol.MAX_BAD_MESSAGES:
		_kick(c.id, "too_many_errors", "Too many invalid messages")
	else:
		_send(c, {"t": "error", "code": code})


## Token bucket per client and kind. Refills at `rate` per second of real time
## and holds a few seconds' worth, so bursts after a lag are absorbed.
func _take_token(c: Dictionary, kind: String, now: int, rate: int) -> bool:
	var tk := "tok_" + kind
	var tt := "tok_at_" + kind
	var cap := float(rate) * Protocol.RATE_BURST_SECONDS
	var tokens: float = float(c.get(tk, cap))
	var at: int = int(c.get(tt, now))
	tokens = minf(cap, tokens + float(now - at) * float(rate) / 1000.0)
	c[tt] = now
	if tokens >= 1.0:
		c[tk] = tokens - 1.0
		return true
	c[tk] = tokens
	return false


func _kick(id: int, code: String, text: String) -> void:
	if not _clients.has(id):
		return
	var c: Dictionary = _clients[id]
	_send(c, {"t": "error", "code": code, "msg": text, "fatal": true})
	c.ws.close(4000, code)
	_closing.append({"ws": c.ws, "since": Time.get_ticks_msec()})
	_remove(id, code)


func _remove(id: int, reason: String) -> void:
	if not _clients.has(id):
		return
	var c: Dictionary = _clients[id]
	_clients.erase(id)
	if plox:
		plox.admin_drop(id)
	if bool(c.get("social", false)) and social:
		social.on_disconnect(id, int(Time.get_unix_time_from_system()))
	if c.room != "" and _rooms.has(c.room):
		var members: Array = _rooms[c.room]
		members.erase(id)
		if _pop.has(c.room):
			_pop[c.room].remove_human(id)
		if members.is_empty():
			_rooms.erase(c.room)
			_pop.erase(c.room)
			_balls.erase(c.room)
			_wind.erase(c.room)
			_gravity.erase(c.room)
		else:
			if bool(c.get("voice", false)):
				_broadcast(c.room, {"t": "vleave", "id": id}, -1)
			_broadcast(c.room, {"t": "leave", "id": id}, -1)
			if _balls.has(c.room):
				_balls[c.room].forget_player(id)
		_log("%s left room %s (%s)" % [c.name, c.room, reason])


func _send(c: Dictionary, data: Dictionary) -> void:
	var ws: WebSocketPeer = c.ws
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var text := Protocol.encode(data)
		_bytes_out += text.length()
		ws.send_text(text)


## For the admin app's live stats.
func room_stats() -> Dictionary:
	var in_games := 0
	for r in _rooms.values():
		in_games += r.size()
	return {"connections": _clients.size(), "rooms": _rooms.size(), "pop_rooms": _pop.size(), "in_games": in_games}


func drop_client(id: int) -> void:
	if _clients.has(id):
		var c: Dictionary = _clients[id]
		c.ws.close(4000, "banned")
		_closing.append({"ws": c.ws, "since": Time.get_ticks_msec()})
		_remove(id, "banned")


func _broadcast(room: String, data: Dictionary, except_id: int) -> void:
	if not _rooms.has(room):
		return
	var text := Protocol.encode(data)
	_bytes_out += (text.length() + 6) * _rooms[room].size()
	for id in _rooms[room]:
		if id == except_id:
			continue
		var ws: WebSocketPeer = _clients[id].ws
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(text)


func _log(text: String) -> void:
	print("[referee] ", text)
	log_line.emit(text)
