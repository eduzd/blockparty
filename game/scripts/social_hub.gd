class_name SocialHub
extends RefCounted
## Server side of the social layer: profiles, search, follows, friend requests,
## friends and one-to-one chat. Lives inside the referee (same port, same process).
##
## Storage model (free Render instances lose their disk when they sleep):
## every phone keeps its own account, friends, follows, sent requests and chat
## history, and re-sends them in s_hello each time it connects. The hub keeps the
## combined picture in memory, so after a server restart it rebuilds itself as
## people come back online. Only things that live on nobody's phone are lost on
## a restart: messages still waiting for an offline friend whose sender has not
## reconnected, and counts from people who have not opened the app since.

const MAX_LIST := 300
const MAX_TEXT := 500
const MAX_QUEUE := 200
const MAX_RESULTS := 30

var users := {}       # uid -> {uid, name, username, bio, cid, last_seen, seeded}
var follows := {}     # uid -> {uid: true}   (who uid follows)
var friends := {}     # uid -> {uid: true}
var requests := {}    # to_uid -> {from_uid: true}
var queue := {}       # to_uid -> [msg]
var inflight := {}    # to_uid -> {mid: msg}  sent to a live socket, not yet confirmed (s_got)
var by_cid := {}      # connection id -> uid
var _send: Callable   # (cid, Dictionary) -> void
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
func on_hello(cid: int, msg: Dictionary, now_unix: int) -> String:
	var key = msg.get("key")
	if not (key is String) or key.length() < 32 or key.length() > 128:
		return "bad_key"
	var uid := uid_for_key(key)
	# One live connection per account: the newest wins.
	if _online(uid):
		var old := int(users[uid].cid)
		by_cid.erase(old)
		_requeue_inflight(uid)
		_send.call(old, {"t": "error", "code": "signed_in_elsewhere", "msg": "Signed in on another phone", "fatal": true})
	var u: Dictionary = users.get(uid, {"uid": uid})
	u.name = Protocol.sanitize_name(msg.get("name"))
	u.bio = clean_text(msg.get("bio"), 150)
	u.av = clean_av(msg.get("av"))
	var want := clean_username(msg.get("username"))
	u.username = _unique_username(want, uid)
	u.cid = cid
	u.last_seen = now_unix
	u.seeded = true
	users[uid] = u
	by_cid[cid] = uid

	# Re-seed from the phone: who I follow, who my friends are, who I asked.
	var my_follows := {}
	for x in _uids(msg.get("follows")):
		if x != uid:
			my_follows[x] = true
			_ensure_stub(x)
	follows[uid] = my_follows
	var claimed := _uids(msg.get("friends"))
	var mine := _bucket(friends, uid)
	for x in mine.keys():
		if not claimed.has(x):
			# I removed them while the server wasn't looking.
			mine.erase(x)
			if friends.has(x):
				friends[x].erase(uid)
	for x in claimed:
		if x == uid:
			continue
		_ensure_stub(x)
		# Trust the claim unless the other side has told us otherwise since the restart.
		if bool(users[x].get("seeded", false)) and not friends.get(x, {}).has(uid):
			continue
		mine[x] = true
		_bucket(friends, x)[uid] = true
	for x in _uids(msg.get("req_out")):
		if x != uid and not mine.has(x):
			_ensure_stub(x)
			_bucket(requests, x)[uid] = true
	# Requests addressed to me that I no longer list as pending are kept: the
	# requester's phone re-sends them, and I answer them in the app.

	var in_req := []
	for from in requests.get(uid, {}):
		if not mine.has(from):
			in_req.append(card(from, uid))
	var friend_cards := []
	for f in mine:
		friend_cards.append(card(f, uid))
	var following_cards := []
	for f in my_follows:
		following_cards.append(_small(f))
	_send.call(cid, {"t": "s_welcome", "me": card(uid), "req_in": in_req, "friends": friend_cards,
		"following": following_cards, "server_time": now_unix})
	# Messages that waited for me.
	var waiting: Array = queue.get(uid, [])
	queue.erase(uid)
	for m in waiting:
		_deliver(uid, m)
	_notify_friends_presence(uid)
	_log.call("social: @%s online (%d friends, %d following)" % [u.username, mine.size(), my_follows.size()])
	return ""


func _ensure_stub(uid: String) -> void:
	if not users.has(uid):
		users[uid] = {"uid": uid, "name": "Player", "username": "", "bio": "", "cid": -1, "last_seen": 0, "seeded": false}


func on_disconnect(cid: int, now_unix: int) -> void:
	if not by_cid.has(cid):
		return
	var uid: String = by_cid[cid]
	by_cid.erase(cid)
	if users.has(uid) and int(users[uid].cid) == cid:
		_requeue_inflight(uid)
		users[uid].cid = -1
		users[uid].last_seen = now_unix
		_notify_friends_presence(uid)


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
	match msg.t:
		"s_profile":
			var u: Dictionary = users[me]
			u.name = Protocol.sanitize_name(msg.get("name"))
			u.bio = clean_text(msg.get("bio"), 150)
			u.av = clean_av(msg.get("av"))
			var want := clean_username(msg.get("username"))
			if want.length() < 3:
				_send.call(cid, {"t": "s_profile_res", "rid": rid, "ok": false, "why": "short", "me": card(me)})
				return ""
			var got := _unique_username(want, me)
			var ok := got == want
			if ok:
				u.username = want
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
			else:
				mine.erase(uid)
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
				_push(uid, {"t": "s_notice", "kind": "declined", "from": _small(me)})
			else:
				if requests.has(uid):
					requests[uid].erase(me)
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
			_push(uid, {"t": "s_notice", "kind": "unfriended", "from": _small(me)})
			_send.call(cid, {"t": "s_user", "rid": rid, "uid": uid, "user": card(uid, me)})
		"s_msg":
			var to = msg.get("to")
			var mid = msg.get("mid")
			var text := clean_text(msg.get("text"), MAX_TEXT, true)
			if not valid_uid(to) or not (mid is String) or mid.length() < 8 or mid.length() > 40 or text == "":
				return "bad_msg"
			if not friends.get(me, {}).has(to):
				_send.call(cid, {"t": "s_ack", "mid": mid, "to": to, "state": "not_friends"})
				return ""
			var ts = msg.get("ts")
			var out := {"t": "s_msg", "from": me, "mid": mid, "text": text,
				"ts": int(ts) if (ts is float or ts is int) else now_unix, "name": users[me].name}
			# "queued" = the server has it. "delivered" comes when the friend's phone
			# confirms it (s_got); until then it is resent if their connection drops.
			_send.call(cid, {"t": "s_ack", "mid": mid, "to": to, "state": "queued"})
			if _online(to):
				_deliver(to, out)
			else:
				_enqueue(to, out)
		"s_got":
			var mid = msg.get("mid")
			if mid is String and inflight.has(me) and inflight[me].has(mid):
				var m: Dictionary = inflight[me][mid]
				inflight[me].erase(mid)
				_push(str(m.from), {"t": "s_ack", "mid": mid, "to": me, "state": "delivered"})
		"s_typing":
			var to = msg.get("to")
			if valid_uid(to) and friends.get(me, {}).has(to):
				_push(to, {"t": "s_typing", "from": me})
		"s_read":
			var to = msg.get("to")
			if valid_uid(to) and friends.get(me, {}).has(to):
				_push(to, {"t": "s_read", "from": me, "ts": now_unix})
		_:
			return "unknown_type"
	return ""


func _make_friends(a: String, b: String) -> void:
	_bucket(friends, a)[b] = true
	_bucket(friends, b)[a] = true
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
