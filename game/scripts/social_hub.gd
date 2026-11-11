class_name SocialHub
extends RefCounted
## Server side of the social layer: profiles, search, follows, friend requests,
## friends and one-to-one chat. Lives inside the referee (same port, same process).
##
## Storage model: the hub keeps everything in memory and, on the Render server,
## writes every change to the Neon database (NeonStore) and loads it back after
## a restart. Accounts in the database are the truth; phones no longer re-seed
## them. Without a database (a phone hosting a game) it falls back to the old
## model: every phone re-sends its account, friends, follows and sent requests in
## s_hello, and the hub rebuilds the combined picture as people come back online.

const MAX_LIST := 300
const MAX_TEXT := 500
const MAX_QUEUE := 200
const MAX_RESULTS := 30
const MAX_HISTORY := 200
## Bytes of chat history sent to a phone that just logged in.
const SYNC_BUDGET := 40000
const MAX_PW := 64
const MIN_PW := 6
## Rounds of HMAC-SHA256 key stretching for stored passwords.
const PW_ROUNDS := 3000

var users := {}       # uid -> {uid, name, username, bio, cid, last_seen, seeded}
var follows := {}     # uid -> {uid: true}   (who uid follows)
var friends := {}     # uid -> {uid: true}
var requests := {}    # to_uid -> {from_uid: true}
var queue := {}       # to_uid -> [msg]
var inflight := {}    # to_uid -> {mid: msg}  sent to a live socket, not yet confirmed (s_got)
var by_cid := {}      # connection id -> uid
var cid_th := {}      # connection id -> session token hash (logged-in phones)
var sessions := {}    # token hash -> uid
var history := {}     # "uidA:uidB" -> [{mid, from, text, ts}] (latest MAX_HISTORY)
var login_fails := {} # username -> [count, since_unix]
var store: NeonStore = null
var _send: Callable   # (cid, Dictionary) -> void
var plox: PloxHub = null   # 0.6.0: Plux, shop, Studio, AI, moderation, admin
var _log: Callable


func _init(send_cb: Callable, log_cb: Callable) -> void:
	_send = send_cb
	_log = log_cb


static func is_social(t: String) -> bool:
	return t.begins_with("s_")


# ------------------------------------------------------------------ validation

static func uid_for_key(key: String) -> String:
	return key.sha256_text().substr(0, 16)


static func valid_uid(v) -> bool:
	if not (v is String) or v.length() != 16:
		return false
	for ch in v:
		if not ((ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "f")):
			return false
	return true


## Built-in avatar index (0..29), or -1 for initials.
static func clean_av(v) -> int:
	if not (v is float or v is int):
		return -1
	var i := int(v)
	return i if i >= 0 and i < 30 else -1


static func clean_username(v) -> String:
	var raw := (str(v) if v is String else "").to_lower()
	var out := ""
	for ch in raw:
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == ".":
			out += ch
		if out.length() >= 20:
			break
	return out


static func clean_text(v, max_len: int, keep_newlines := false) -> String:
	var raw := str(v) if v is String else ""
	var out := ""
	for ch in raw:
		var code := ch.unicode_at(0)
		if code >= 32 and code != 127:
			out += ch
		elif keep_newlines and code == 10:
			out += ch
		if out.length() >= max_len:
			break
	return out.strip_edges()


func _uids(v) -> Array:
	var out := []
	if v is Array:
		for x in v:
			if valid_uid(x) and not out.has(x):
				out.append(x)
			if out.size() >= MAX_LIST:
				break
	return out


# ------------------------------------------------------------------ helpers

func _bucket(d: Dictionary, uid: String) -> Dictionary:
	if not d.has(uid):
		d[uid] = {}
	return d[uid]


func _online(uid: String) -> bool:
	return users.has(uid) and int(users[uid].cid) >= 0


func _push(uid: String, data: Dictionary) -> void:
	if _online(uid):
		_send.call(int(users[uid].cid), data)


func _followers_of(uid: String) -> int:
	var n := 0
	for other in follows:
		if follows[other].has(uid):
			n += 1
	return n


## Public card for `uid` as `viewer` sees it.
func card(uid: String, viewer: String = "") -> Dictionary:
	var u: Dictionary = users.get(uid, {})
	var out := {
		"uid": uid, "name": u.get("name", "Player"), "username": u.get("username", ""),
		"bio": u.get("bio", ""), "av": int(u.get("av", -1)), "online": _online(uid),
		"seen": int(u.get("last_seen", 0)),
		"followers": _followers_of(uid), "following": follows.get(uid, {}).size(),
		"friends": friends.get(uid, {}).size(),
	}
	if viewer != "" and viewer != uid:
		out["i_follow"] = follows.get(viewer, {}).has(uid)
		out["follows_me"] = follows.get(uid, {}).has(viewer)
		out["friend"] = friends.get(viewer, {}).has(uid)
		out["req_out"] = requests.get(uid, {}).has(viewer)
		out["req_in"] = requests.get(viewer, {}).has(uid)
	if plox != null:
		plox.card_extra(uid, out)
	return out


func _small(uid: String) -> Dictionary:
	var u: Dictionary = users.get(uid, {})
	return {"uid": uid, "name": u.get("name", "Player"), "username": u.get("username", ""), "online": _online(uid)}


func _unique_username(want: String, uid: String) -> String:
	var base := want if want.length() >= 3 else "player"
	var name := base
	var n := 0
	while true:
		var taken := false
		for other in users:
			if other != uid and users[other].get("username", "") == name:
				taken = true
				break
		if not taken:
			return name
		n += 1
		name = base.substr(0, 16) + str(randi_range(10, 9999))
		if n > 50:
			return base.substr(0, 10) + uid.substr(0, 8)
	return name


func _notify_friends_presence(uid: String) -> void:
	var msg := {"t": "s_presence", "uid": uid, "online": _online(uid)}
	for f in friends.get(uid, {}):
		_push(f, msg)


# ------------------------------------------------------------------ connection

## Returns an error code or "" when the hello was accepted.
## Returns an error code or "" when the hello was accepted.
## A phone signs in with its device key (the account made on that phone) or with a
## session token it got from s_login (an account it logged in to with a password).
func on_hello(cid: int, msg: Dictionary, now_unix: int) -> String:
	var uid := ""
	var th := ""
	var token = msg.get("token")
	if token is String and token != "":
		if token.length() < 32 or token.length() > 128:
			return "bad_token"
		th = token.sha256_text()
		if not sessions.has(th):
			return "logged_out"
		uid = sessions[th]
	else:
		var key = msg.get("key")
		if not (key is String) or key.length() < 32 or key.length() > 128:
			return "bad_key"
		uid = uid_for_key(key)
	if plox != null:
		var banned := plox.ban_reason(uid)
		if banned != "":
			_send.call(cid, {"t": "error", "code": "banned", "msg": banned, "fatal": true})
			return "banned"
	var is_new_account := not users.has(uid)
	# One live connection per account: the newest wins.
	if _online(uid):
		var old := int(users[uid].cid)
		by_cid.erase(old)
		cid_th.erase(old)
		_requeue_inflight(uid)
		_send.call(old, {"t": "error", "code": "signed_in_elsewhere", "msg": "Signed in on another phone", "fatal": true})
	var persisted: bool = bool(users.get(uid, {}).get("persisted", false))
	var u: Dictionary = users.get(uid, {"uid": uid})
	# The phone sends its profile when it has changes the server has not seen (older
	# app versions always send it). A phone that just logged in sends none and gets
	# the profile from the welcome.
	if msg.has("name") or not u.has("name"):
		u.name = Protocol.sanitize_name(msg.get("name"))
		u.bio = clean_text(msg.get("bio"), 150)
		u.av = clean_av(msg.get("av"))
		var want := clean_username(msg.get("username"))
		if want != str(u.get("username", "")) or want == "":
			u.username = _unique_username(want, uid)
	u.cid = cid
	u.last_seen = now_unix
	u.seeded = true
	users[uid] = u
	by_cid[cid] = uid
	if th != "":
		cid_th[cid] = th

	var mine := _bucket(friends, uid)
	var my_follows := _bucket(follows, uid)
	if not persisted and th == "":
		# Re-seed from the phone: who I follow, who my friends are, who I asked.
		# Accounts already in the database skip this: the server's copy is the truth.
		var new_follows := {}
		for x in _uids(msg.get("follows")):
			if x != uid:
				new_follows[x] = true
				_ensure_stub(x)
		for x in my_follows:
			if not new_follows.has(x):
				_db("delete from bp_follows where a = $1 and b = $2", [uid, x])
		for x in new_follows:
			if not my_follows.has(x):
				_db("insert into bp_follows (a, b) values ($1, $2) on conflict do nothing", [uid, x])
		follows[uid] = new_follows
		my_follows = new_follows
		var claimed := _uids(msg.get("friends"))
		for x in mine.keys():
			if not claimed.has(x):
				# I removed them while the server wasn't looking.
				mine.erase(x)
				if friends.has(x):
					friends[x].erase(uid)
				_db_friend(uid, x, false)
		for x in claimed:
			if x == uid:
				continue
			_ensure_stub(x)
			# Trust the claim unless the other side has told us otherwise since the restart.
			if bool(users[x].get("seeded", false)) and not friends.get(x, {}).has(uid):
				continue
			if not mine.has(x):
				_db_friend(uid, x, true)
			mine[x] = true
			_bucket(friends, x)[uid] = true
		for x in _uids(msg.get("req_out")):
			if x != uid and not mine.has(x):
				_ensure_stub(x)
				if not requests.get(x, {}).has(uid):
					_db("insert into bp_requests (to_uid, from_uid) values ($1, $2) on conflict do nothing", [x, uid])
				_bucket(requests, x)[uid] = true
		# Requests addressed to me that I no longer list as pending are kept: the
		# requester's phone re-sends them, and I answer them in the app.
	_save_user(uid)

	var in_req := []
	for from in requests.get(uid, {}):
		if not mine.has(from):
			in_req.append(card(from, uid))
	var out_req := []
	for to in requests:
		if requests[to].has(uid) and not mine.has(to):
			out_req.append(_small(to))
	var friend_cards := []
	for f in mine:
		friend_cards.append(card(f, uid))
	var following_cards := []
	for f in my_follows:
		following_cards.append(_small(f))
	var me := card(uid)
	me["av"] = int(u.get("av", -1))
	me["has_pw"] = str(u.get("pw", "")) != ""
	me["has_bday"] = str(u.get("birthday", "")) != ""
	me["email"] = str(u.get("email", ""))
	var welcome := {"t": "s_welcome", "me": me, "req_in": in_req, "req_out": out_req, "friends": friend_cards,
		"following": following_cards, "server_time": now_unix, "stored": store != null and store.writable}
	if plox != null:
		plox.welcome_extra(uid, is_new_account, welcome)
	if bool(msg.get("sync", false)):
		# A phone that just logged in gets its recent chats back.
		# Newest chats first, within a size budget so the welcome stays one small message.
		var pairs := []
		for pair in history:
			var ab: PackedStringArray = pair.split(":")
			if ab.size() == 2 and (ab[0] == uid or ab[1] == uid) and not history[pair].is_empty():
				pairs.append(pair)
		pairs.sort_custom(func(a, b): return int(history[a][-1].ts) > int(history[b][-1].ts))
		var chats := {}
		var budget := SYNC_BUDGET
		for pair in pairs:
			var ab: PackedStringArray = pair.split(":")
			var other: String = ab[1] if ab[0] == uid else ab[0]
			var msgs := _history_out(pair, 30)
			var keep := []
			for i in range(msgs.size() - 1, -1, -1):
				var cost: int = str(msgs[i].text).to_utf8_buffer().size() + 90
				if cost > budget:
					break
				budget -= cost
				keep.push_front(msgs[i])
			if keep.is_empty():
				break
			chats[other] = keep
		welcome["chats"] = chats
	_send.call(cid, welcome)
	# Messages that waited for me.
	var waiting: Array = queue.get(uid, [])
	queue.erase(uid)
	for m in waiting:
		_deliver(uid, m)
	_notify_friends_presence(uid)
	_log.call("social: @%s online (%d friends, %d following)%s" % [u.username, mine.size(), my_follows.size(), " [login]" if th != "" else ""])
	return ""


func _ensure_stub(uid: String) -> void:
	if not users.has(uid):
		users[uid] = {"uid": uid, "name": "Player", "username": "", "bio": "", "cid": -1, "last_seen": 0, "seeded": false}


func on_disconnect(cid: int, now_unix: int) -> void:
	if not by_cid.has(cid):
		return
	var uid: String = by_cid[cid]
	by_cid.erase(cid)
	cid_th.erase(cid)
	if users.has(uid) and int(users[uid].cid) == cid:
		_requeue_inflight(uid)
		users[uid].cid = -1
		users[uid].last_seen = now_unix
		if bool(users[uid].get("persisted", false)):
			_db("update bp_users set last_seen = $2 where uid = $1", [uid, now_unix])
		_notify_friends_presence(uid)


# ------------------------------------------------------------------ storage

## Hands the hub a database to write to (see NeonStore). Without one, the hub
## works in memory only, as it does when a phone hosts the game.
func attach_store(s: NeonStore) -> void:
	store = s


func _db(query: String, params: Array) -> void:
	if store != null:
		store.exec(query, params)


func _save_user(uid: String) -> void:
	if store == null or not store.writable or not users.has(uid):
		return
	var u: Dictionary = users[uid]
	if int(u.get("created", 0)) == 0:
		u.created = int(Time.get_unix_time_from_system())
	_db("insert into bp_users (uid, name, username, bio, av, last_seen, pw, created, birthday, email) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) on conflict (uid) do update set name = excluded.name, username = excluded.username, bio = excluded.bio, av = excluded.av, last_seen = excluded.last_seen, pw = excluded.pw, birthday = excluded.birthday, email = excluded.email",
		[uid, str(u.get("name", "Player")), str(u.get("username", "")), str(u.get("bio", "")), int(u.get("av", -1)),
		int(u.get("last_seen", 0)), u.get("pw") if str(u.get("pw", "")) != "" else null, int(u.created), str(u.get("birthday", "")), str(u.get("email", ""))])
	u.persisted = true


func _db_friend(a: String, b: String, on: bool) -> void:
	if on:
		_db("insert into bp_friends (a, b) values ($1, $2), ($2, $1) on conflict do nothing", [a, b])
	else:
		_db("delete from bp_friends where (a = $1 and b = $2) or (a = $2 and b = $1)", [a, b])


static func pair_key(a: String, b: String) -> String:
	return a + ":" + b if a < b else b + ":" + a


func _remember(m: Dictionary, to: String) -> bool:
	var pair := pair_key(str(m.from), to)
	var h: Array = history.get(pair, [])
	for x in h:
		if x.mid == m.mid:
			return false
	h.append({"mid": m.mid, "from": m.from, "text": m.text, "ts": int(m.ts)})
	if h.size() > MAX_HISTORY:
		h = h.slice(h.size() - MAX_HISTORY)
	history[pair] = h
	return true


func _history_out(pair: String, n: int) -> Array:
	var h: Array = history.get(pair, [])
	return h.slice(maxi(0, h.size() - n))


## Fills the hub from the database at start-up (rows from NeonStore.loaded).
func load_from(data: Dictionary) -> void:
	for r in data.get("users", []):
		var uid := str(r.get("uid", ""))
		if not valid_uid(uid):
			continue
		var u: Dictionary = users.get(uid, {"uid": uid, "cid": -1})
		u.name = str(r.get("name", "Player"))
		u.username = str(r.get("username", ""))
		u.bio = str(r.get("bio", ""))
		u.av = clean_av(r.get("av"))
		u.last_seen = int(str(r.get("last_seen", "0")))
		u.pw = str(r.get("pw")) if r.get("pw") != null else ""
		u.created = int(str(r.get("created", "0")))
		u.birthday = str(r.get("birthday", "")) if r.get("birthday") != null else ""
		u.email = str(r.get("email", "")) if r.get("email") != null else ""
		u.seeded = true
		u.persisted = true
		if not u.has("cid"):
			u.cid = -1
		users[uid] = u
	for r in data.get("follows", []):
		_bucket(follows, str(r.a))[str(r.b)] = true
	for r in data.get("friends", []):
		_bucket(friends, str(r.a))[str(r.b)] = true
	for r in data.get("requests", []):
		_bucket(requests, str(r.to_uid))[str(r.from_uid)] = true
	for r in data.get("msgs", []):
		var from := str(r.from_uid)
		var to := str(r.to_uid)
		var m := {"mid": str(r.mid), "from": from, "text": str(r.text), "ts": int(str(r.ts))}
		_remember(m, to)
		var delivered = r.get("delivered")
		if delivered == false or str(delivered) == "false" or str(delivered) == "f":
			var out := {"t": "s_msg", "from": from, "mid": m.mid, "text": m.text, "ts": m.ts,
				"name": users.get(from, {}).get("name", "Player")}
			_enqueue(to, out)
	for r in data.get("sessions", []):
		sessions[str(r.th)] = str(r.uid)
	for uid in users:
		if not users[uid].has("cid"):
			users[uid].cid = -1


# ------------------------------------------------------------------ passwords and login

static func hash_pw(pw: String, salt_hex := "", rounds := PW_ROUNDS) -> String:
	var c := Crypto.new()
	if salt_hex == "":
		salt_hex = c.generate_random_bytes(16).hex_encode()
	var key := pw.to_utf8_buffer()
	var h := c.hmac_digest(HashingContext.HASH_SHA256, key, salt_hex.hex_decode())
	for i in rounds:
		h = c.hmac_digest(HashingContext.HASH_SHA256, key, h)
	return "h1$%d$%s$%s" % [rounds, salt_hex, h.hex_encode()]


static func check_pw(pw: String, stored: String) -> bool:
	var parts := stored.split("$")
	if parts.size() != 4 or parts[0] != "h1" or int(parts[1]) < 1:
		return false
	return hash_pw(pw, parts[2], int(parts[1])) == stored


## Logs in with @username and password. Works before s_hello, on the same
## connection; the phone then says s_hello with the token it gets back.
func on_login(msg: Dictionary, now_unix: int) -> Dictionary:
	var un := clean_username(str(msg.get("username", "")).strip_edges().trim_prefix("@"))
	var pw = msg.get("password")
	if un.length() < 3 or not (pw is String) or pw.length() < 1 or pw.length() > MAX_PW:
		return {"t": "s_login_res", "ok": false, "why": "wrong"}
	var f: Array = login_fails.get(un, [0, now_unix])
	if now_unix - int(f[1]) > 300:
		f = [0, now_unix]
	if int(f[0]) >= 6:
		return {"t": "s_login_res", "ok": false, "why": "slow"}
	var uid := ""
	for x in users:
		if str(users[x].get("username", "")) == un:
			uid = x
			break
	if uid == "" or str(users[uid].get("pw", "")) == "" or not check_pw(pw, str(users[uid].pw)):
		f[0] = int(f[0]) + 1
		login_fails[un] = f
		return {"t": "s_login_res", "ok": false, "why": "wrong"}
	login_fails.erase(un)
	var token := Crypto.new().generate_random_bytes(24).hex_encode()
	var th := token.sha256_text()
	sessions[th] = uid
	_db("insert into bp_sessions (th, uid, created) values ($1, $2, $3) on conflict do nothing", [th, uid, now_unix])
	_log.call("social: @%s logged in" % un)
	var me := card(uid)
	me["av"] = int(users[uid].get("av", -1))
	return {"t": "s_login_res", "ok": true, "token": token, "uid": uid, "me": me}


# ------------------------------------------------------------------ sign up (0.7.0)

var signup_times: Array = []   # unix times of recent sign-ups, server-wide


static func clean_birthday(v) -> String:
	var s := str(v) if v is String else ""
	var parts := s.split("-")
	if parts.size() != 3 or parts[0].length() != 4 or not parts[0].is_valid_int() or not parts[1].is_valid_int() or not parts[2].is_valid_int():
		return ""
	var y := int(parts[0])
	var m := int(parts[1])
	var d := int(parts[2])
	var now := Time.get_date_dict_from_system()
	if y < 1900 or y > int(now.year) or m < 1 or m > 12 or d < 1 or d > 31:
		return ""
	var t := Time.get_unix_time_from_datetime_dict({"year": y, "month": m, "day": d, "hour": 12})
	var back := Time.get_date_dict_from_unix_time(t)
	if int(back.day) != d or t > Time.get_unix_time_from_system():
		return ""
	return "%04d-%02d-%02d" % [y, m, d]


static func age_from(bday: String) -> int:
	if bday == "":
		return -1
	var p := bday.split("-")
	var now := Time.get_date_dict_from_system()
	var age := int(now.year) - int(p[0])
	if int(now.month) < int(p[1]) or (int(now.month) == int(p[1]) and int(now.day) < int(p[2])):
		age -= 1
	return age


static func clean_email(v) -> String:
	var s := (str(v) if v is String else "").strip_edges().to_lower()
	if s == "":
		return ""
	if s.length() > 120 or s.count("@") != 1 or s.contains(" "):
		return "!"
	var parts := s.split("@")
	if parts[0] == "" or not parts[1].contains(".") or parts[1].begins_with(".") or parts[1].ends_with("."):
		return "!"
	return s


## Why a username can't be taken, or "" when it is free. Same rules as sign-up.
func name_problem(raw, for_uid := "") -> String:
	var want := str(raw) if raw is String else ""
	var un := clean_username(want.strip_edges().trim_prefix("@"))
	if un != want.strip_edges().trim_prefix("@").to_lower():
		return "Use only letters, numbers, _ and ."
	if un.length() < 3:
		return "At least 3 characters."
	if un.length() > 20:
		return "20 characters at most."
	if plox != null and plox.filter_text(un) != un:
		return "That name isn't allowed."
	for w in ["admin", "moderator", "plux_staff", "official"]:
		if un.contains(w):
			return "That name isn't allowed."
	for x in users:
		if x != for_uid and str(users[x].get("username", "")) == un:
			return "That username is taken."
	return ""


func on_name_check(msg: Dictionary) -> Dictionary:
	var why := name_problem(msg.get("username"))
	return {"t": "s_name_res", "username": str(msg.get("username", "")).substr(0, 24), "ok": why == "", "why": why}


## Makes a new account with a username and password. Works before s_hello, like
## s_login; the phone then says s_hello with the token it gets back.
func on_signup(msg: Dictionary, now_unix: int) -> Dictionary:
	var res := {"t": "s_signup_res", "ok": false, "why": "", "field": ""}
	if plox != null and plox.cfg.b("maintenance"):
		res.why = "Plux is under maintenance. Try again soon."
		return res
	var why := name_problem(msg.get("username"))
	if why != "":
		res.why = why
		res.field = "username"
		return res
	var pw = msg.get("password")
	if not (pw is String) or pw.length() < MIN_PW or pw.length() > MAX_PW:
		res.why = "Password must be %d to %d characters." % [MIN_PW, MAX_PW]
		res.field = "password"
		return res
	var un := clean_username(str(msg.get("username")).strip_edges().trim_prefix("@"))
	if pw.to_lower() == un:
		res.why = "Pick a password that isn't your username."
		res.field = "password"
		return res
	var bday := clean_birthday(msg.get("birthday"))
	if bday == "" or age_from(bday) > 120:
		res.why = "Enter a real birthday."
		res.field = "birthday"
		return res
	var email := clean_email(msg.get("email"))
	if email == "!":
		res.why = "That email doesn't look right."
		res.field = "email"
		return res
	# Server-wide brake on account farming.
	var recent: Array = []
	for t in signup_times:
		if now_unix - int(t) < 60:
			recent.append(t)
	signup_times = recent
	if signup_times.size() >= 20:
		res.why = "Lots of people are signing up. Try again in a minute."
		return res
	signup_times.append(now_unix)
	var uid := Crypto.new().generate_random_bytes(8).hex_encode()
	var name := Protocol.sanitize_name(msg.get("name", un))
	if name == "Player" or name.strip_edges() == "":
		name = un
	users[uid] = {"uid": uid, "cid": -1, "name": name, "username": un, "bio": "", "av": clean_av(msg.get("av")),
		"last_seen": now_unix, "pw": hash_pw(pw), "created": now_unix, "birthday": bday, "email": email, "seeded": true}
	_save_user(uid)
	if plox != null:
		plox.count("signups")
		# Signed up with a friend's invite code: they become friends straight away.
		var inviter := plox.uid_for_invite(str(msg.get("invite", ""))) if str(msg.get("invite", "")) != "" else ""
		if inviter != "" and inviter != uid:
			_bucket(friends, uid)[inviter] = true
			_bucket(friends, inviter)[uid] = true
			_db_friend(uid, inviter, true)
			plox.invite_joins[inviter] = int(plox.invite_joins.get(inviter, 0)) + 1
			plox.count("invite_signups")
			_push(inviter, {"t": "s_notice", "kind": "friends", "from": card(uid, inviter), "invite": true})
			res["invited_by"] = str(users[inviter].get("name", ""))
	var token := Crypto.new().generate_random_bytes(24).hex_encode()
	var th := token.sha256_text()
	sessions[th] = uid
	_db("insert into bp_sessions (th, uid, created) values ($1, $2, $3) on conflict do nothing", [th, uid, now_unix])
	_log.call("social: @%s signed up" % un)
	var me := card(uid)
	me["av"] = int(users[uid].av)
	res.ok = true
	res["token"] = token
	res["uid"] = uid
	res["me"] = me
	return res


func is_signed_in(cid: int) -> bool:
	return by_cid.has(cid)


# ------------------------------------------------------------------ requests

## Handles one social message. Returns an error code for a bad message, else "".
func handle(cid: int, msg: Dictionary, now_unix: int) -> String:
	if not by_cid.has(cid):
		return "not_signed_in"
	var me: String = by_cid[cid]
	var rid = msg.get("rid", 0)
	if not (rid is float or rid is int):
		rid = 0
	if plox != null and plox.owns(str(msg.t)):
		return plox.handle(cid, me, msg, rid, now_unix)
	match msg.t:
		"s_profile":
			var u: Dictionary = users[me]
			u.name = Protocol.sanitize_name(msg.get("name"))
			u.bio = clean_text(msg.get("bio"), 150)
			u.av = clean_av(msg.get("av"))
			var want := clean_username(msg.get("username"))
			if want.length() < 3:
				_save_user(me)
				_send.call(cid, {"t": "s_profile_res", "rid": rid, "ok": false, "why": "short", "me": card(me)})
				return ""
			var got := _unique_username(want, me)
			var ok := got == want
			if ok:
				u.username = want
			_save_user(me)
			_send.call(cid, {"t": "s_profile_res", "rid": rid, "ok": ok, "why": "" if ok else "taken", "me": card(me)})
		"s_search":
			var q := clean_text(msg.get("q"), 30).to_lower().trim_prefix("@")
			var hits := []
			for uid in users:
				var u: Dictionary = users[uid]
				if uid == me or str(u.get("username", "")) == "" or not bool(u.get("seeded", false)):
					continue
				var score := -1
				if q == "":
					score = 2 if _online(uid) else 1
				else:
					var un := str(u.username)
					var nm := str(u.name).to_lower()
					if un == q:
						score = 5
					elif un.begins_with(q) or nm.begins_with(q):
						score = 4
					elif un.contains(q) or nm.contains(q):
						score = 3
				if score >= 0:
					hits.append([score, int(u.get("last_seen", 0)), uid])
			hits.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] > b[1]))
			var res := []
			for h in hits.slice(0, MAX_RESULTS):
				res.append(card(h[2], me))
			_send.call(cid, {"t": "s_search_res", "rid": rid, "q": q, "users": res})
		"s_get":
			var uid = msg.get("uid")
			if not valid_uid(uid):
				return "bad_uid"
			if not users.has(uid):
				_send.call(cid, {"t": "s_user", "rid": rid, "uid": uid, "missing": true})
			else:
				_send.call(cid, {"t": "s_user", "rid": rid, "uid": uid, "user": card(uid, me)})
		"s_list":
			var uid = msg.get("uid")
			var kind = msg.get("kind")
			if not valid_uid(uid) or not (kind in ["friends", "followers", "following"]):
				return "bad_list"
			var ids := []
			if kind == "friends":
				ids = friends.get(uid, {}).keys()
			elif kind == "following":
				ids = follows.get(uid, {}).keys()
			else:
				for other in follows:
					if follows[other].has(uid):
						ids.append(other)
			var res := []
			for x in ids.slice(0, MAX_LIST):
				res.append(card(x, me))
			_send.call(cid, {"t": "s_list_res", "rid": rid, "uid": uid, "kind": kind, "users": res})
		"s_follow":
			var uid = msg.get("uid")
			if not valid_uid(uid) or uid == me or not users.has(uid):
				return "bad_uid"
			var on := bool(msg.get("on", true))
			var mine := _bucket(follows, me)
			var was: bool = mine.has(uid)
			if on:
				mine[uid] = true
				if not was:
					_db("insert into bp_follows (a, b) values ($1, $2) on conflict do nothing", [me, uid])
			else:
				mine.erase(uid)
				if was:
					_db("delete from bp_follows where a = $1 and b = $2", [me, uid])
			_send.call(cid, {"t": "s_user", "rid": rid, "uid": uid, "user": card(uid, me)})
			if on and not was:
				_push(uid, {"t": "s_notice", "kind": "follow", "from": card(me, uid)})
		"s_freq":
			var uid = msg.get("uid")
			if not valid_uid(uid) or uid == me or not users.has(uid):
				return "bad_uid"
			if friends.get(me, {}).has(uid):
				pass
			elif requests.get(me, {}).has(uid):
				_make_friends(me, uid)   # they had already asked me
			else:
				var was: bool = requests.get(uid, {}).has(me)
				_bucket(requests, uid)[me] = true
				if not was:
					_db("insert into bp_requests (to_uid, from_uid) values ($1, $2) on conflict do nothing", [uid, me])
					_push(uid, {"t": "s_notice", "kind": "request", "from": card(me, uid)})
			_send.call(cid, {"t": "s_user", "rid": rid, "uid": uid, "user": card(uid, me)})
		"s_faccept":
			var uid = msg.get("uid")
			if not valid_uid(uid) or uid == me:
				return "bad_uid"
			if requests.get(me, {}).has(uid):
				_make_friends(me, uid)
			_send.call(cid, {"t": "s_user", "rid": rid, "uid": uid, "user": card(uid, me)})
		"s_fdecline", "s_fcancel":
			var uid = msg.get("uid")
			if not valid_uid(uid) or uid == me:
				return "bad_uid"
			if msg.t == "s_fdecline":
				if requests.has(me):
					requests[me].erase(uid)
				_db("delete from bp_requests where to_uid = $1 and from_uid = $2", [me, uid])
				_push(uid, {"t": "s_notice", "kind": "declined", "from": _small(me)})
			else:
				if requests.has(uid):
					requests[uid].erase(me)
				_db("delete from bp_requests where to_uid = $1 and from_uid = $2", [uid, me])
				_push(uid, {"t": "s_notice", "kind": "cancelled", "from": _small(me)})
			_send.call(cid, {"t": "s_user", "rid": rid, "uid": uid, "user": card(uid, me)})
		"s_funfriend":
			var uid = msg.get("uid")
			if not valid_uid(uid) or uid == me:
				return "bad_uid"
			if friends.has(me):
				friends[me].erase(uid)
			if friends.has(uid):
				friends[uid].erase(me)
			_db_friend(me, uid, false)
			_push(uid, {"t": "s_notice", "kind": "unfriended", "from": _small(me)})
			_send.call(cid, {"t": "s_user", "rid": rid, "uid": uid, "user": card(uid, me)})
		"s_msg":
			var to = msg.get("to")
			var mid = msg.get("mid")
			var text := clean_text(msg.get("text"), MAX_TEXT, true)
			if not valid_uid(to) or not (mid is String) or mid.length() < 8 or mid.length() > 40 or text == "":
				return "bad_msg"
			if plox != null:
				if not plox.cfg.b("f_chat"):
					_send.call(cid, {"t": "s_ack", "mid": mid, "to": to, "state": "chat_off"})
					return ""
				text = plox.filter_text(text)
			if not friends.get(me, {}).has(to):
				_send.call(cid, {"t": "s_ack", "mid": mid, "to": to, "state": "not_friends"})
				return ""
			var ts = msg.get("ts")
			var out := {"t": "s_msg", "from": me, "mid": mid, "text": text,
				"ts": int(ts) if (ts is float or ts is int) else now_unix, "name": users[me].name}
			# "queued" = the server has it. "delivered" comes when the friend's phone
			# confirms it (s_got); until then it is resent if their connection drops.
			_send.call(cid, {"t": "s_ack", "mid": mid, "to": to, "state": "queued"})
			if _remember(out, to):
				_db("insert into bp_msgs (mid, from_uid, to_uid, text, ts) values ($1, $2, $3, $4, $5) on conflict do nothing",
					[mid, me, to, text, int(out.ts)])
			if _online(to):
				_deliver(to, out)
			else:
				_enqueue(to, out)
		"s_got":
			var mid = msg.get("mid")
			if mid is String and inflight.has(me) and inflight[me].has(mid):
				var m: Dictionary = inflight[me][mid]
				inflight[me].erase(mid)
				_db("update bp_msgs set delivered = true where mid = $1", [mid])
				_push(str(m.from), {"t": "s_ack", "mid": mid, "to": me, "state": "delivered"})
		"s_typing":
			var to = msg.get("to")
			if valid_uid(to) and friends.get(me, {}).has(to):
				_push(to, {"t": "s_typing", "from": me})
		"s_read":
			var to = msg.get("to")
			if valid_uid(to) and friends.get(me, {}).has(to):
				_push(to, {"t": "s_read", "from": me, "ts": now_unix})
		"s_setpw":
			# Sets or changes the password that lets this account log in on another phone.
			var u: Dictionary = users[me]
			var pw = msg.get("password")
			var old_pw = msg.get("old")
			var res := {"t": "s_setpw_res", "rid": rid, "ok": false, "why": ""}
			if str(u.get("pw", "")) != "" and not (old_pw is String and check_pw(old_pw, str(u.pw))):
				res.why = "old_wrong"
			elif not (pw is String) or pw.length() < MIN_PW or pw.length() > MAX_PW:
				res.why = "short"
			elif str(u.get("username", "")).length() < 3:
				res.why = "no_username"
			else:
				u.pw = hash_pw(pw)
				_save_user(me)
				res.ok = true
				res["stored"] = store != null and store.writable
				_log.call("social: @%s set a password" % u.username)
			_send.call(cid, res)
		"s_finish":
			# 0.7.0: an account made on a phone before sign-up existed picks its
			# username, password and birthday, keeping friends, Plux and items.
			var u: Dictionary = users[me]
			var res := {"t": "s_finish_res", "rid": rid, "ok": false, "why": "", "field": ""}
			var want := str(msg.get("username", u.get("username", "")))
			var un := clean_username(want.strip_edges().trim_prefix("@"))
			var why := "" if un == str(u.get("username", "")) and un.length() >= 3 else name_problem(want, me)
			var pw = msg.get("password")
			var bday := clean_birthday(msg.get("birthday"))
			var email := clean_email(msg.get("email"))
			if why != "":
				res.why = why
				res.field = "username"
			elif str(u.get("pw", "")) != "" and not (msg.get("old") is String and check_pw(str(msg.get("old")), str(u.pw))):
				res.why = "Your current password is wrong."
				res.field = "old"
			elif not (pw is String) or pw.length() < MIN_PW or pw.length() > MAX_PW:
				res.why = "Password must be %d to %d characters." % [MIN_PW, MAX_PW]
				res.field = "password"
			elif bday == "" or age_from(bday) > 120:
				res.why = "Enter a real birthday."
				res.field = "birthday"
			elif email == "!":
				res.why = "That email doesn't look right."
				res.field = "email"
			else:
				u.username = un
				u.pw = hash_pw(pw)
				u.birthday = bday
				u.email = email
				_save_user(me)
				res.ok = true
				res["me"] = card(me)
				res.me["av"] = int(u.get("av", -1))
				res.me["has_pw"] = true
				res.me["has_bday"] = true
				res.me["email"] = email
				_log.call("social: @%s finished setting up the account" % un)
			_send.call(cid, res)
		"s_name_check":
			var r := on_name_check(msg)
			r["rid"] = rid
			var w0 := clean_username(str(msg.get("username", "")).strip_edges().trim_prefix("@"))
			if w0 == str(users[me].get("username", "")):
				r.ok = true
				r.why = ""
			_send.call(cid, r)
		"s_history":
			var w = msg.get("with")
			if not valid_uid(w) or w == me:
				return "bad_uid"
			_send.call(cid, {"t": "s_history_res", "rid": rid, "with": w, "msgs": _history_out(pair_key(me, w), 100)})
		"s_logout":
			if cid_th.has(cid):
				var th: String = cid_th[cid]
				sessions.erase(th)
				cid_th.erase(cid)
				_db("delete from bp_sessions where th = $1", [th])
			_send.call(cid, {"t": "s_logout_res", "rid": rid})
		_:
			return "unknown_type"
	return ""


func _make_friends(a: String, b: String) -> void:
	_bucket(friends, a)[b] = true
	_bucket(friends, b)[a] = true
	_db_friend(a, b, true)
	_db("delete from bp_requests where (to_uid = $1 and from_uid = $2) or (to_uid = $2 and from_uid = $1)", [a, b])
	if requests.has(a):
		requests[a].erase(b)
	if requests.has(b):
		requests[b].erase(a)
	_push(a, {"t": "s_notice", "kind": "friends", "from": card(b, a)})
	_push(b, {"t": "s_notice", "kind": "friends", "from": card(a, b)})


func _deliver(to: String, m: Dictionary) -> void:
	_bucket(inflight, to)[m.mid] = m
	if inflight[to].size() > MAX_QUEUE:
		inflight[to].erase(inflight[to].keys()[0])
	_push(to, m)


func _enqueue(to: String, m: Dictionary) -> void:
	var q: Array = queue.get(to, [])
	for x in q:
		if x.mid == m.mid:
			return
	q.append(m)
	if q.size() > MAX_QUEUE:
		q.pop_front()
	queue[to] = q


## Messages sent to a connection that went away unconfirmed go back in the queue.
func _requeue_inflight(uid: String) -> void:
	if not inflight.has(uid):
		return
	var msgs: Array = inflight[uid].values()
	inflight.erase(uid)
	msgs.sort_custom(func(a, b): return int(a.ts) < int(b.ts))
	var q: Array = queue.get(uid, [])
	var merged := msgs.duplicate()
	for x in q:
		var dup := false
		for y in msgs:
			if y.mid == x.mid:
				dup = true
		if not dup:
			merged.append(x)
	queue[uid] = merged
