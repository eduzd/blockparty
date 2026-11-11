class_name SocialClient
extends Node
## The phone side of the social layer: this phone's account, friends, follows,
## friend requests and chats, kept in user://social.json and synced with the
## Block Party server over its own WebSocket while the app is open.

signal changed                                   # anything in `data` changed
signal state_changed(state: String)              # offline / connecting / online / elsewhere
signal notice(kind: String, who: Dictionary)     # follow, request, friends, declined, unfriended
signal chat_message(uid: String, m: Dictionary)  # incoming message
signal chat_updated(uid: String)                 # message states changed (sent, delivered, read)
signal user_loaded(uid: String, user: Dictionary)
signal search_done(q: String, users: Array)
signal list_done(uid: String, kind: String, users: Array)
signal profile_saved(ok: bool, why: String)
signal typing(uid: String)

const STORE_PATH := "user://social.json"
const PING_EVERY_MS := 5000
const SILENCE_MS := 16000
const CONNECT_TIMEOUT_MS := 25000
const MAX_CHAT := 400

var state := "offline"
var url := ""
var data := {}
var uid := ""
var active_chat := ""   # the chat open on screen (marks incoming as read)

var _ws: WebSocketPeer
var _opened_at := 0
var _welcomed := false
var _retry_at := 0
var _backoff := 1.0
var _last_rx := 0
var _last_ping := 0
var _save_at := 0
var _rid := 0
var _search_rid := 0
var _hello_sent := false


func _ready() -> void:
	_load()


# ------------------------------------------------------------------ storage

func _load() -> void:
	var f := FileAccess.open(STORE_PATH, FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			data = parsed
	for k in ["friends", "following", "req_out", "req_in", "chats", "unread", "cards"]:
		if not (data.get(k) is Dictionary):
			data[k] = {}
	if not (data.get("key") is String) or str(data.key).length() < 32:
		data.key = Crypto.new().generate_random_bytes(24).hex_encode()
	uid = SocialHub.uid_for_key(data.key)
	for k in ["name", "username", "bio"]:
		if not (data.get(k) is String):
			data[k] = ""
	if not (data.get("me") is Dictionary):
		data.me = {}
	_save_now()


func _save_now() -> void:
	var f := FileAccess.open(STORE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
	_save_at = 0


func _save_soon() -> void:
	if _save_at == 0:
		_save_at = Time.get_ticks_msec() + 400


func _touch() -> void:
	_save_soon()
	changed.emit()


## Sets the account up the first time, from the name the player already uses.
func ensure_profile(fallback_name: String) -> void:
	if str(data.name) == "":
		data.name = Protocol.sanitize_name(fallback_name)
	if str(data.username) == "":
		var base := SocialHub.clean_username(str(data.name).replace(" ", "_"))
		if base.length() < 3:
			base = "player"
		data.username = base.substr(0, 15) + str(randi_range(10, 9999))
	_save_now()


# ------------------------------------------------------------------ connection

func start(p_url: String) -> void:
	if p_url.strip_edges() == url and state != "offline" and state != "elsewhere":
		return
	url = p_url.strip_edges()
	_backoff = 1.0
	_open()


func stop() -> void:
	if _ws:
		_ws.close(1000, "bye")
		_ws = null
	_set_state("offline")


func is_online() -> bool:
	return state == "online"


func _set_state(s: String) -> void:
	if s != state:
		state = s
		state_changed.emit(s)


func _open() -> void:
	if url == "" or url.contains("YOUR-SERVICE"):
		_set_state("offline")
		return
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 262144
	_ws.outbound_buffer_size = 65536
	_welcomed = false
	_hello_sent = false
	if _ws.connect_to_url(url) != OK:
		_ws = null
		_schedule_retry()
		return
	_opened_at = Time.get_ticks_msec()
	_set_state("connecting")


func _schedule_retry() -> void:
	_ws = null
	_retry_at = Time.get_ticks_msec() + int(_backoff * 1000.0)
	_backoff = minf(_backoff * 2.0, 15.0)
	if state != "elsewhere":
		_set_state("connecting" if url != "" else "offline")


## Starts over right away (for example when the app comes back to the front).
func reconnect_now() -> void:
	if state == "online" or url == "":
		return
	_backoff = 1.0
	if _ws:
		_ws.close()
	_open()


func _send(msg: Dictionary) -> bool:
	if _ws and _welcomed and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))
		return true
	return false


func _next_rid() -> int:
	_rid += 1
	return _rid


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _save_at != 0 and now >= _save_at:
		_save_now()
	if _ws == null:
		if _retry_at != 0 and now >= _retry_at and state != "elsewhere" and url != "":
			_retry_at = 0
			_open()
		return
	_ws.poll()
	var rs := _ws.get_ready_state()
	if rs == WebSocketPeer.STATE_CONNECTING:
		if now - _opened_at > CONNECT_TIMEOUT_MS:
			_ws.close()
			_schedule_retry()
		return
	if rs == WebSocketPeer.STATE_CLOSED:
		_welcomed = false
		if state == "elsewhere":
			_ws = null
			return
		_schedule_retry()
		return
	if rs != WebSocketPeer.STATE_OPEN:
		return
	if not _hello_sent:
		_hello_sent = true
		_send_hello()
		_last_rx = now
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		_last_rx = now
		var msg = JSON.parse_string(pkt.get_string_from_utf8())
		if msg is Dictionary and msg.get("t") is String:
			_on_msg(msg)
		if _ws == null:
			return
	if _welcomed and now - _last_ping > PING_EVERY_MS:
		_last_ping = now
		_send({"t": "ping", "c": now})
	if now - _last_rx > SILENCE_MS:
		_ws.close()
		_schedule_retry()


func _send_hello() -> void:
	var hello := {"t": "s_hello", "v": Protocol.VERSION, "key": data.key, "name": data.name,
		"username": data.username, "bio": data.bio, "friends": data.friends.keys(),
		"follows": data.following.keys(), "req_out": data.req_out.keys()}
	_ws.send_text(JSON.stringify(hello))


# ------------------------------------------------------------------ incoming

func _on_msg(msg: Dictionary) -> void:
	match msg.t:
		"s_welcome":
			_welcomed = true
			_backoff = 1.0
			var me: Dictionary = msg.get("me", {})
			data.me = me
			if me.get("username", "") is String and me.username != "":
				data.username = me.username
			var fr := {}
			for u in msg.get("friends", []):
				if u is Dictionary and SocialHub.valid_uid(u.get("uid")):
					fr[u.uid] = u
					data.cards[u.uid] = u
			data.friends = fr
			var fo := {}
			for u in msg.get("following", []):
				if u is Dictionary and SocialHub.valid_uid(u.get("uid")):
					fo[u.uid] = data.following.get(u.uid, u) if str(u.get("username", "")) == "" else u
			data.following = fo
			var ri := {}
			for u in msg.get("req_in", []):
				if u is Dictionary and SocialHub.valid_uid(u.get("uid")):
					ri[u.uid] = u
			data.req_in = ri
			for x in data.req_out.keys():
				if fr.has(x):
					data.req_out.erase(x)
			_set_state("online")
			_resend_outbox()
			_touch()
		"pong":
			pass
		"error":
			if msg.get("code") == "signed_in_elsewhere":
				_set_state("elsewhere")
				_ws.close()
				_ws = null
		"s_user":
			if msg.get("user") is Dictionary:
				_absorb(msg.user)
				user_loaded.emit(str(msg.uid), msg.user)
			else:
				user_loaded.emit(str(msg.get("uid", "")), {})
		"s_search_res":
			if int(msg.get("rid", 0)) == _search_rid:
				search_done.emit(str(msg.get("q", "")), msg.get("users", []))
		"s_list_res":
			list_done.emit(str(msg.get("uid", "")), str(msg.get("kind", "")), msg.get("users", []))
		"s_profile_res":
			if msg.get("me") is Dictionary:
				data.me = msg.me
				data.username = str(msg.me.get("username", data.username))
			_touch()
			profile_saved.emit(bool(msg.get("ok", false)), str(msg.get("why", "")))
		"s_notice":
			var who: Dictionary = msg.get("from", {})
			var w := str(who.get("uid", ""))
			if not SocialHub.valid_uid(w):
				return
			match str(msg.get("kind", "")):
				"request":
					data.req_in[w] = who
				"friends":
					data.friends[w] = who
					data.req_in.erase(w)
					data.req_out.erase(w)
				"declined":
					data.req_out.erase(w)
				"cancelled":
					data.req_in.erase(w)
				"unfriended":
					data.friends.erase(w)
				"follow":
					if data.me is Dictionary:
						data.me["followers"] = int(data.me.get("followers", 0)) + 1
			if who.has("name"):
				data.cards[w] = who
			_touch()
			notice.emit(str(msg.kind), who)
		"s_presence":
			var w := str(msg.get("uid", ""))
			if data.friends.has(w):
				data.friends[w]["online"] = bool(msg.get("online", false))
				if not bool(msg.get("online", false)):
					data.friends[w]["seen"] = int(Time.get_unix_time_from_system())
				_touch()
		"s_msg":
			_on_chat(msg)
		"s_ack":
			_set_msg_state(str(msg.get("to", "")), str(msg.get("mid", "")), str(msg.get("state", "")))
		"s_read":
			var w := str(msg.get("from", ""))
			var changed_any := false
			for m in data.chats.get(w, []):
				if m.from == uid and m.state in ["delivered", "queued", "sent"]:
					m.state = "read"
					changed_any = true
			if changed_any:
				_save_soon()
				chat_updated.emit(w)
		"s_typing":
			typing.emit(str(msg.get("from", "")))


## Keeps the local lists in line with what the server says about one person.
func _absorb(u: Dictionary) -> void:
	var w := str(u.get("uid", ""))
	if not SocialHub.valid_uid(w) or w == uid:
		return
	data.cards[w] = u
	if bool(u.get("friend", false)):
		data.friends[w] = u
	else:
		data.friends.erase(w)
	if bool(u.get("i_follow", false)):
		data.following[w] = {"uid": w, "name": u.get("name", ""), "username": u.get("username", "")}
	else:
		data.following.erase(w)
	if bool(u.get("req_out", false)):
		data.req_out[w] = {"uid": w, "name": u.get("name", ""), "username": u.get("username", "")}
	else:
		data.req_out.erase(w)
	if bool(u.get("req_in", false)):
		data.req_in[w] = u
	else:
		data.req_in.erase(w)
	data.me["following"] = data.following.size()
	data.me["friends"] = data.friends.size()
	_touch()


func _on_chat(msg: Dictionary) -> void:
	var w := str(msg.get("from", ""))
	if not SocialHub.valid_uid(w):
		return
	var chat: Array = data.chats.get(w, [])
	for m in chat:
		if m.mid == msg.get("mid"):
			return   # already have it (re-sent after a reconnect)
	var m := {"mid": str(msg.mid), "from": w, "text": str(msg.get("text", "")),
		"ts": int(msg.get("ts", Time.get_unix_time_from_system())), "state": "in"}
	chat.append(m)
	if chat.size() > MAX_CHAT:
		chat = chat.slice(chat.size() - MAX_CHAT)
	data.chats[w] = chat
	if active_chat == w:
		_send({"t": "s_read", "to": w})
	else:
		data.unread[w] = int(data.unread.get(w, 0)) + 1
	_touch()
	chat_message.emit(w, m)


func _set_msg_state(to: String, mid: String, st: String) -> void:
	for m in data.chats.get(to, []):
		if m.mid == mid and m.from == uid:
			if m.state == "read" and st != "not_friends":
				return
			m.state = "failed" if st == "not_friends" else st
			_save_soon()
			chat_updated.emit(to)
			return


func _resend_outbox() -> void:
	for w in data.chats:
		for m in data.chats[w]:
			if m.from == uid and m.state == "sending":
				_send({"t": "s_msg", "to": w, "mid": m.mid, "text": m.text, "ts": m.ts})


# ------------------------------------------------------------------ actions

func search(q: String) -> void:
	_search_rid = _next_rid()
	_send({"t": "s_search", "q": q, "rid": _search_rid})


func get_user(w: String) -> void:
	_send({"t": "s_get", "uid": w, "rid": _next_rid()})


func get_list(w: String, kind: String) -> void:
	_send({"t": "s_list", "uid": w, "kind": kind, "rid": _next_rid()})


func follow(w: String, on: bool) -> bool:
	return _send({"t": "s_follow", "uid": w, "on": on, "rid": _next_rid()})


func add_friend(w: String) -> bool:
	return _send({"t": "s_freq", "uid": w, "rid": _next_rid()})


func accept(w: String) -> bool:
	return _send({"t": "s_faccept", "uid": w, "rid": _next_rid()})


func decline(w: String) -> bool:
	return _send({"t": "s_fdecline", "uid": w, "rid": _next_rid()})


func cancel_request(w: String) -> bool:
	return _send({"t": "s_fcancel", "uid": w, "rid": _next_rid()})


func unfriend(w: String) -> bool:
	return _send({"t": "s_funfriend", "uid": w, "rid": _next_rid()})


func save_profile(name: String, username: String, bio: String) -> bool:
	data.name = Protocol.sanitize_name(name)
	data.bio = SocialHub.clean_text(bio, 150)
	var want := SocialHub.clean_username(username)
	_save_now()
	changed.emit()
	return _send({"t": "s_profile", "name": data.name, "username": want, "bio": data.bio, "rid": _next_rid()})


func send_text(w: String, text: String) -> void:
	var t := SocialHub.clean_text(text, SocialHub.MAX_TEXT, true)
	if t == "" or not SocialHub.valid_uid(w):
		return
	var m := {"mid": "%s%d%04d" % [uid.substr(0, 6), Time.get_ticks_msec(), randi() % 10000], "from": uid,
		"text": t, "ts": int(Time.get_unix_time_from_system()), "state": "sending"}
	var chat: Array = data.chats.get(w, [])
	chat.append(m)
	data.chats[w] = chat
	_send({"t": "s_msg", "to": w, "mid": m.mid, "text": t, "ts": m.ts})
	_touch()
	chat_updated.emit(w)


func send_typing(w: String) -> void:
	_send({"t": "s_typing", "to": w})


func open_chat(w: String) -> void:
	active_chat = w
	if int(data.unread.get(w, 0)) > 0:
		data.unread.erase(w)
		_touch()
	_send({"t": "s_read", "to": w})


func close_chat() -> void:
	active_chat = ""


func unread_total() -> int:
	var n := 0
	for w in data.unread:
		n += int(data.unread[w])
	return n


func card_for(w: String) -> Dictionary:
	if data.friends.has(w):
		return data.friends[w]
	if data.cards.has(w):
		return data.cards[w]
	if data.req_in.has(w):
		return data.req_in[w]
	return {"uid": w, "name": "Player", "username": ""}
