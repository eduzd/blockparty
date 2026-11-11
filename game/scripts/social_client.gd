class_name SocialClient
extends Node
## The phone side of the social layer: this phone's account, friends, follows,
## friend requests and chats, kept in user://social.json and synced with the
## Plux server over its own WebSocket while the app is open.

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
signal login_done(ok: bool, why: String)        # after login(): ok, or why it failed
signal password_saved(ok: bool, why: String)
signal account_switched                         # logged in, logged out or the login expired
# 0.6.0 Plox
signal cfg_changed                              # live settings from the server changed
signal eco_changed                              # Plux, inventory, equipped items or shop changed
signal plux_earned(amount: int, why: String)
signal reply(t: String, msg: Dictionary)         # Studio, games, AI and shop answers
signal pre_reply(msg: Dictionary)                 # answers on the sign-up / log-in socket (0.7.0)
signal invite_in(msg: Dictionary)                 # a friend invited you to a game
signal trades_changed                             # a trade offer arrived or changed
signal banned(text: String)

## App version code (export_presets version/code). The server can ask older apps to update.
const APP_VERSION := 7
var cfg := LiveConfig.DEFAULTS.duplicate(true)
var eco := {"coins": 0, "eq": [], "inv": [], "daily_ready": false, "daily": 0}
var shop: Array = []
var shop_by_id := {}
var pop_ticket := ""

const STORE_PATH := "user://social.json"
const PING_EVERY_MS := 5000
const SILENCE_MS := 16000
const CONNECT_TIMEOUT_MS := 25000
const MAX_CHAT := 400
## The phone's own account is kept here while it is logged in to another one.
const DEVICE_PATH := "user://social_device.json"

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
var _login_ws: WebSocketPeer
var _login_msg := {}
var _login_at := 0
## 0.7.0: while the welcome screen is up, the phone's own account isn't connected.
var hold := false
var _pre_ws: WebSocketPeer
var _pre_queue: Array = []
var _pre_wait: Array = []      # types still waiting for an answer
var _pre_at := 0
var trades: Array = []         # latest trade list from the server
var invites: Array = []        # invites waiting on screen


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
	if is_logged_in() and SocialHub.valid_uid(data.get("login_uid")):
		uid = str(data.login_uid)
	else:
		data.erase("token")
		uid = SocialHub.uid_for_key(data.key)
	for k in ["name", "username", "bio"]:
		if not (data.get(k) is String):
			data[k] = ""
	data.av = SocialHub.clean_av(data.get("av", -1))
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
	if hold:
		_set_state("offline")
		return
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
	if _login_ws != null:
		_poll_login(now)
	if _pre_ws != null:
		_poll_pre(now)
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
	var hello := {}
	if is_logged_in():
		# An account this phone logged in to: the server holds it, so send no profile.
		hello = {"t": "s_hello", "v": Protocol.VERSION, "token": data.token, "sync": bool(data.get("need_sync", false))}
	else:
		hello = {"t": "s_hello", "v": Protocol.VERSION, "key": data.key, "name": data.name,
			"username": data.username, "bio": data.bio, "av": data.av, "friends": data.friends.keys(),
			"follows": data.following.keys(), "req_out": data.req_out.keys()}
	_ws.send_text(JSON.stringify(hello))


# ------------------------------------------------------------------ login

## True when this phone is signed in to an account with a password (not its own).
func is_logged_in() -> bool:
	return data.get("token") is String and str(data.token).length() >= 32


## True when the account has a password, so it can be logged in to elsewhere.
func has_password() -> bool:
	return bool(data.get("me", {}).get("has_pw", false))


## Logs in to an account with its @username and password. Answers with login_done.
func login(username: String, password: String) -> void:
	if url == "":
		login_done.emit(false, "offline")
		return
	if _login_ws != null:
		_login_ws.close()
	_login_ws = WebSocketPeer.new()
	_login_msg = {"t": "s_login", "username": username.strip_edges().trim_prefix("@"), "password": password}
	_login_at = Time.get_ticks_msec()
	if _login_ws.connect_to_url(url) != OK:
		_login_ws = null
		login_done.emit(false, "offline")


func _poll_login(now: int) -> void:
	_login_ws.poll()
	var rs := _login_ws.get_ready_state()
	if now - _login_at > 75000 or rs == WebSocketPeer.STATE_CLOSED:
		_login_ws.close()
		_login_ws = null
		login_done.emit(false, "offline")
		return
	if rs != WebSocketPeer.STATE_OPEN:
		return
	if not _login_msg.is_empty():
		_login_ws.send_text(JSON.stringify(_login_msg))
		_login_msg = {}
	while _login_ws != null and _login_ws.get_available_packet_count() > 0:
		var msg = JSON.parse_string(_login_ws.get_packet().get_string_from_utf8())
		if not (msg is Dictionary):
			continue
		if msg.get("t") == "s_login_res":
			_login_ws.close()
			_login_ws = null
			if bool(msg.get("ok", false)) and SocialHub.valid_uid(msg.get("uid")) and msg.get("token") is String:
				_switch_to(str(msg.uid), str(msg.token), msg.get("me", {}))
				login_done.emit(true, "")
			else:
				login_done.emit(false, str(msg.get("why", "wrong")))
		elif msg.get("t") == "error":
			_login_ws.close()
			_login_ws = null
			login_done.emit(false, "slow" if msg.get("code") == "rate_limit" else "offline")


# ------------------------------------------------------------------ welcome (0.7.0)

## True on a phone that has never had an account: show Sign up / Log in first.
func needs_welcome() -> bool:
	return not is_logged_in() and (data.me as Dictionary).is_empty() and not bool(data.get("used", false))


## Sends a message on the sign-up socket (s_name_check, s_signup, s_login).
## Every answer comes back as pre_reply.
func pre_send(msg: Dictionary) -> void:
	if url == "" or url.contains("YOUR-SERVICE"):
		pre_reply.emit({"t": str(msg.t) + "_res", "ok": false, "why": "offline"})
		return
	_pre_queue.append(msg)
	_pre_wait.append(str(msg.t))
	_pre_at = Time.get_ticks_msec()
	if _pre_ws == null:
		_pre_ws = WebSocketPeer.new()
		if _pre_ws.connect_to_url(url) != OK:
			_pre_ws = null
			_pre_fail("offline")


func _pre_fail(why: String) -> void:
	for t in _pre_wait:
		pre_reply.emit({"t": t + "_res", "ok": false, "why": why})
	_pre_wait.clear()
	_pre_queue.clear()


func _poll_pre(now: int) -> void:
	_pre_ws.poll()
	var rs := _pre_ws.get_ready_state()
	if rs == WebSocketPeer.STATE_CLOSED or (not _pre_wait.is_empty() and now - _pre_at > 75000):
		_pre_ws.close()
		_pre_ws = null
		_pre_fail("offline")
		return
	if rs != WebSocketPeer.STATE_OPEN:
		return
	for m in _pre_queue:
		_pre_ws.send_text(JSON.stringify(m))
	_pre_queue.clear()
	while _pre_ws != null and _pre_ws.get_available_packet_count() > 0:
		var msg = JSON.parse_string(_pre_ws.get_packet().get_string_from_utf8())
		if not (msg is Dictionary) or not (msg.get("t") is String):
			continue
		if msg.t == "error":
			var why := "slow" if msg.get("code") == "rate_limit" else "offline"
			_pre_ws.close()
			_pre_ws = null
			_pre_fail(why)
			return
		var t0 := str(msg.t).trim_suffix("_res")
		if t0 == "s_name":
			t0 = "s_name_check"
		_pre_wait.erase(t0)
		if (msg.t == "s_login_res" or msg.t == "s_signup_res") and bool(msg.get("ok", false)) \
				and SocialHub.valid_uid(msg.get("uid")) and msg.get("token") is String:
			_pre_ws.close()
			_pre_ws = null
			_pre_queue.clear()
			_pre_wait.clear()
			hold = false
			_switch_to(str(msg.uid), str(msg.token), msg.get("me", {}))
		pre_reply.emit(msg)
	if _pre_ws != null and _pre_wait.is_empty() and now - _pre_at > 60000:
		_pre_ws.close()
		_pre_ws = null


func _switch_to(new_uid: String, token: String, me: Dictionary) -> void:
	if not is_logged_in():
		# Keep this phone's own account to come back to on log out.
		var f := FileAccess.open(DEVICE_PATH, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(data))
	var key: String = data.key
	data = {"key": key, "token": token, "login_uid": new_uid, "need_sync": true,
		"name": str(me.get("name", "Player")), "username": str(me.get("username", "")),
		"bio": str(me.get("bio", "")), "av": SocialHub.clean_av(me.get("av", -1)), "me": me}
	for k in ["friends", "following", "req_out", "req_in", "chats", "unread", "cards"]:
		data[k] = {}
	uid = new_uid
	_save_now()
	account_switched.emit()
	_touch()
	_force_reconnect()


## Leaves the logged-in account and goes back to this phone's own account.
func logout() -> void:
	if not is_logged_in():
		return
	if _welcomed:
		_send({"t": "s_logout"})
		# Let the message leave before the connection is dropped.
		_ws.poll()
	_back_to_device()


func _back_to_device() -> void:
	var key: String = data.key
	data = {}
	var f := FileAccess.open(DEVICE_PATH, FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			data = parsed
		f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DEVICE_PATH))
	data.erase("token")
	data.erase("login_uid")
	data.erase("need_sync")
	if not (data.get("key") is String):
		data.key = key
	_load_defaults()
	uid = SocialHub.uid_for_key(data.key)
	_save_now()
	if needs_welcome():
		# Nothing to go back to on this phone: show the welcome screen again.
		hold = true
		if _ws != null:
			_ws.close()
			_ws = null
		_set_state("offline")
		account_switched.emit()
		_touch()
		return
	account_switched.emit()
	_touch()
	_force_reconnect()


## Drops the connection and signs in again as the account now in `data`.
func _force_reconnect() -> void:
	if _ws:
		_ws.close()
		_ws = null
	_welcomed = false
	_backoff = 1.0
	_retry_at = 0
	if state == "elsewhere":
		state = "offline"
	_set_state("offline")
	_open()


func _load_defaults() -> void:
	for k in ["friends", "following", "req_out", "req_in", "chats", "unread", "cards"]:
		if not (data.get(k) is Dictionary):
			data[k] = {}
	for k in ["name", "username", "bio"]:
		if not (data.get(k) is String):
			data[k] = ""
	data.av = SocialHub.clean_av(data.get("av", -1))
	if not (data.get("me") is Dictionary):
		data.me = {}


## Sets (or changes) the password for logging in to this account on another phone.
func set_password(password: String, old_password: String = "") -> bool:
	var m := {"t": "s_setpw", "password": password, "rid": _next_rid()}
	if old_password != "":
		m["old"] = old_password
	return _send(m)


func _merge_chats(chats: Dictionary) -> void:
	for w in chats:
		if not SocialHub.valid_uid(w) or not (chats[w] is Array):
			continue
		var chat: Array = data.chats.get(w, [])
		var have := {}
		for m in chat:
			have[str(m.mid)] = true
		for m in chats[w]:
			if not (m is Dictionary) or have.has(str(m.get("mid", ""))):
				continue
			var mine: bool = str(m.get("from", "")) == uid
			chat.append({"mid": str(m.mid), "from": str(m.from), "text": str(m.get("text", "")),
				"ts": int(m.get("ts", 0)), "state": "delivered" if mine else "in"})
		chat.sort_custom(func(a, b): return int(a.ts) < int(b.ts))
		if chat.size() > MAX_CHAT:
			chat = chat.slice(chat.size() - MAX_CHAT)
		data.chats[w] = chat


# ------------------------------------------------------------------ incoming

func _on_msg(msg: Dictionary) -> void:
	match msg.t:
		"s_cfg":
			if msg.get("cfg") is Dictionary:
				cfg.merge(msg.cfg, true)
				cfg_changed.emit()
		"s_eco_res":
			if msg.get("cfg") is Dictionary:
				cfg.merge(msg.cfg, true)
			if msg.get("eco") is Dictionary:
				eco = msg.eco
			if msg.get("shop") is Array:
				shop = msg.shop
				shop_by_id.clear()
				for it in shop:
					if it is Dictionary:
						shop_by_id[str(it.get("id", ""))] = it
			eco_changed.emit()
		"s_pro":
			if msg.get("pro") is Dictionary:
				eco["pro"] = msg.pro
				if bool(msg.pro.get("active", false)):
					plux_earned.emit(0, "pro")
			eco_changed.emit()
			reply.emit("s_pro_push", msg)
		"s_plux":
			eco.coins = int(msg.get("coins", eco.coins))
			plux_earned.emit(int(msg.get("got", 0)), str(msg.get("why", "")))
			eco_changed.emit()
		"s_look":
			var w := str(msg.get("uid", ""))
			if data.cards.has(w):
				data.cards[w]["eq"] = msg.get("eq", [])
			if data.friends.has(w):
				data.friends[w]["eq"] = msg.get("eq", [])
			_touch()
		"s_playing":
			var w := str(msg.get("uid", ""))
			for d in [data.cards, data.friends]:
				if d.has(w):
					if msg.get("playing") is Dictionary and not msg.playing.is_empty():
						d[w]["playing"] = msg.playing
					else:
						d[w].erase("playing")
			_touch()
		"s_daily_res", "s_buy_res", "s_equip_res", "s_outfits_res", "s_outfit_save_res", "s_outfit_del_res", "s_pro_res", "s_pro_cancel_res", "s_pro_renew_res":
			if msg.has("coins"):
				eco.coins = int(msg.coins)
			if msg.t == "s_buy_res" and bool(msg.get("ok", false)):
				eco.inv.append({"oid": msg.get("oid", ""), "item": msg.get("item", ""), "serial": int(msg.get("serial", 0))})
				if shop_by_id.has(str(msg.get("item", ""))) and shop_by_id[msg.item].has("left"):
					shop_by_id[msg.item].left = maxi(0, int(shop_by_id[msg.item].left) - 1)
			if msg.t == "s_daily_res":
				eco.daily_ready = false
				if bool(msg.get("ok", false)):
					plux_earned.emit(int(msg.get("got", 0)), "daily")
			if msg.t == "s_equip_res" and msg.get("eq") is Array:
				eco.eq = msg.eq
				var me_eq := []
				for id in msg.eq:
					if shop_by_id.has(id):
						me_eq.append({"art": shop_by_id[id].art, "col": shop_by_id[id].col, "slot": shop_by_id[id].slot})
				data.me["eq"] = me_eq
			eco_changed.emit()
			reply.emit(str(msg.t), msg)
		"s_ticket_res":
			pop_ticket = str(msg.get("ticket", ""))
		"s_trades_res":
			if msg.get("trades") is Array:
				trades = msg.trades
			trades_changed.emit()
			reply.emit(str(msg.t), msg)
		"s_trade_new", "s_trade_upd":
			if msg.get("eco") is Dictionary:
				eco = msg.eco
				eco_changed.emit()
			var tr: Dictionary = msg.get("trade", {})
			var found := false
			for i in trades.size():
				if str(trades[i].get("id", "")) == str(tr.get("id", "")):
					trades[i] = tr
					found = true
			if not found and not tr.is_empty():
				trades.push_front(tr)
			trades_changed.emit()
			reply.emit(str(msg.t), msg)
		"s_trade_res":
			if msg.get("eco") is Dictionary:
				eco = msg.eco
				eco_changed.emit()
			if msg.get("trade") is Dictionary:
				var tr2: Dictionary = msg.trade
				var found2 := false
				for i in trades.size():
					if str(trades[i].get("id", "")) == str(tr2.get("id", "")):
						trades[i] = tr2
						found2 = true
				if not found2:
					trades.push_front(tr2)
				trades_changed.emit()
			reply.emit(str(msg.t), msg)
		"s_invite_in":
			if feature("invites"):
				invites.append(msg)
				invite_in.emit(msg)
		"s_pay_res", "s_pay_start_res":
			if msg.get("eco") is Dictionary:
				eco = msg.eco
				eco_changed.emit()
			reply.emit(str(msg.t), msg)
		"s_finish_res":
			if bool(msg.get("ok", false)) and msg.get("me") is Dictionary:
				for k in msg.me:
					data.me[k] = msg.me[k]
				data.username = str(msg.me.get("username", data.username))
				_touch()
			reply.emit(str(msg.t), msg)
		"s_inv_res", "s_packs_res", "s_orders_res", "s_invite_res", "s_invite_code_res", "s_invite_ans", \
				"s_name_res", "s_game_done_res":
			reply.emit(str(msg.t), msg)
		"s_studio_mine_res", "s_game_res", "s_studio_save_res", "s_studio_delete_res", "s_games_res", \
				"s_game_like_res", "s_ai_res", "s_report_res":
			if msg.t == "s_studio_save_res" and msg.has("coins"):
				eco.coins = int(msg.coins)
				plux_earned.emit(int(msg.get("got", 0)), "publish")
				eco_changed.emit()
			reply.emit(str(msg.t), msg)
		"error":
			if str(msg.get("code", "")) == "banned":
				banned.emit(str(msg.get("msg", "This account is banned.")))
		"s_welcome":
			if msg.get("cfg") is Dictionary:
				cfg.merge(msg.cfg, true)
				cfg_changed.emit()
			if msg.get("eco") is Dictionary:
				eco = msg.eco
				eco_changed.emit()
			_welcomed = true
			request({"t": "s_eco"})
			request({"t": "s_ticket"})
			_backoff = 1.0
			var me: Dictionary = msg.get("me", {})
			data.me = me
			if me.get("username", "") is String and me.username != "":
				data.username = me.username
			if is_logged_in():
				for k in ["name", "bio"]:
					if me.get(k) is String:
						data[k] = me[k]
				if me.has("av"):
					data.av = SocialHub.clean_av(me.av)
			if msg.get("chats") is Dictionary:
				_merge_chats(msg.chats)
			data.erase("need_sync")
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
			elif msg.get("code") in ["logged_out", "bad_token"] and is_logged_in():
				# The login ended (logged out on another phone): back to this phone's account.
				_ws.close()
				_ws = null
				_back_to_device()
		"s_setpw_res":
			if bool(msg.get("ok", false)):
				data.me["has_pw"] = true
				_touch()
			password_saved.emit(bool(msg.get("ok", false)), str(msg.get("why", "")))
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
				data.used = true
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
	_send({"t": "s_got", "mid": msg.get("mid")})
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
			if st != "not_friends" and (m.state == "read" or (m.state == "delivered" and st == "queued")):
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

# ------------------------------------------------------------------ Plox (0.6.0)

## Sends any Plox request; the answer comes back on the `reply` signal.
func request(msg: Dictionary) -> bool:
	msg["rid"] = _next_rid()
	return _send(msg)


func feature(name: String) -> bool:
	return bool(cfg.get("f_" + name, true))


func is_pro() -> bool:
	return bool(eco.get("pro", {}).get("active", false)) if eco.get("pro") is Dictionary else false


func owns_item(id: String) -> bool:
	for o in eco.get("inv", []):
		if str(o.get("item", "")) == id:
			return true
	return false


func equipped_cards() -> Array:
	var out := []
	for id in eco.get("eq", []):
		if shop_by_id.has(id):
			var it: Dictionary = shop_by_id[id]
			out.append({"art": it.art, "col": it.col, "slot": it.slot})
	return out


func set_playing(what: String, room := "") -> void:
	_send({"t": "s_playing", "what": what, "room": room})


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


func save_profile(name: String, username: String, bio: String, av: int = -2) -> bool:
	data.name = Protocol.sanitize_name(name)
	if av != -2:
		data.av = SocialHub.clean_av(av)
	data.bio = SocialHub.clean_text(bio, 150)
	var want := SocialHub.clean_username(username)
	_save_now()
	changed.emit()
	return _send({"t": "s_profile", "name": data.name, "username": want, "bio": data.bio, "av": data.av, "rid": _next_rid()})


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
