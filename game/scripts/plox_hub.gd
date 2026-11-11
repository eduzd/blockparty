class_name PloxHub
extends Node
## Plox server features added in 0.6.0, next to SocialHub:
##  - Plux wallet, daily reward, round rewards, avatar shop, inventory, equipping
##  - Studio games: save, publish, discover, play counts, likes
##  - AI level building through any OpenAI-compatible API (OmniRoute, OpenRouter...)
##  - Reports, bans, banned words
##  - Live config and the admin app's commands (a_*), with an audit log
## The server is the only authority. Every Plux change is checked in memory first
## and written to Neon as ONE statement, so the database can never end up with an
## item and no payment, or a payment and no item. Rare items are numbered and the
## database refuses a second copy of the same number.

const SCHEMA := [
	"create table if not exists plox_wallet (uid text primary key, coins bigint not null default 0, eq text not null default '', daily_day int not null default 0, earn_day int not null default 0, earn_n int not null default 0)",
	"create table if not exists plox_items (id text primary key, def text not null, pos int not null default 0)",
	"create table if not exists plox_owned (oid text primary key, uid text not null, item text not null, serial int not null default 0, ts bigint not null default 0)",
	"create unique index if not exists plox_owned_serial on plox_owned (item, serial) where serial > 0",
	"create table if not exists plox_games (gid text primary key, owner text not null, title text not null, data text not null, status text not null default 'draft', featured boolean not null default false, plays int not null default 0, likes int not null default 0, created bigint not null default 0, updated bigint not null default 0, paid boolean not null default false)",
	"create table if not exists plox_likes (gid text not null, uid text not null, primary key (gid, uid))",
	"create table if not exists plox_config (k text primary key, v text not null)",
	"create table if not exists plox_bans (uid text primary key, until bigint not null, reason text not null default '')",
	"create table if not exists plox_reports (id bigserial primary key, ts bigint not null, from_uid text not null, target text not null, kind text not null, text text not null default '', status text not null default 'open')",
	"create table if not exists plox_audit (id bigserial primary key, ts bigint not null, who text not null, action text not null, detail text not null default '')",
	"create table if not exists plox_ai_log (id bigserial primary key, ts bigint not null, uid text not null, prompt text not null, ok boolean not null, ms int not null default 0, why text not null default '')",
	"create table if not exists plox_daily (day int not null, k text not null, n bigint not null default 0, primary key (day, k))",
]
const LOADS := [
	["wallets", "select uid, coins, eq, daily_day, earn_day, earn_n from plox_wallet"],
	["items", "select id, def from plox_items order by pos asc, id asc"],
	["owned", "select oid, uid, item, serial from plox_owned"],
	["games", "select gid, owner, title, data, status, featured, plays, likes, created, updated, paid from plox_games where status <> 'deleted'"],
	["likes", "select gid, uid from plox_likes"],
	["config", "select k, v from plox_config"],
	["bans", "select uid, until, reason from plox_bans"],
	["reports", "select id, ts, from_uid, target, kind, text, status from plox_reports order by id desc limit 300"],
	["audit", "select id, ts, who, action, detail from plox_audit order by id desc limit 300"],
	["ai_log", "select id, ts, uid, prompt, ok, ms, why from plox_ai_log order by id desc limit 300"],
	["daily", "select day, k, n from plox_daily where day > (extract(epoch from now())::bigint / 86400) - 35"],
]
const ADMIN_LOCK_FAILS := 5
const ADMIN_LOCK_S := 600
const AI_GLOBAL_PER_DAY := 300
const MAX_PROMPT := 300
const LEVEL_MSG_BYTES := 16000

var hub: SocialHub
var referee: Node
var cfg := LiveConfig.new()
var items := {}          # id -> item
var item_order: Array = []
var sold := {}           # item id -> copies sold (highest serial)
var wallets := {}        # uid -> {coins, eq: [item ids], daily_day, earn_day, earn_n}
var owned := {}          # uid -> {oid: {item, serial}}
var games := {}          # gid -> {gid, owner, title, data, status, featured, plays, likes, created, updated, paid}
var likes := {}          # gid -> {uid: true}
var bans := {}           # uid -> {until, reason}
var reports: Array = []  # newest first
var audit: Array = []
var ai_log: Array = []
var daily := {}          # day -> {k: n}
var playing := {}        # uid -> "pop" | "neon" | "game:<gid>"
var plays_seen := {}     # "uid:gid" -> unix
var tickets := {}        # ticket -> [uid, expires_unix]
var admin_cids := {}     # cid -> true
var _admin_fails: Array = [0, 0]   # count, first fail unix
var admin_pw_hash := ""
var ai_cfg := {"base": "", "model": "", "key_enc": "", "key_tail": ""}
var _ai_busy := {}
var _ai_secret := PackedByteArray()
var bytes_month := {"month": "", "out": 0, "in": 0}
var _bytes_saved_at := 0
var _cpu_last := [0, 0]   # [process ticks, msec]
var cpu_pct := 0.0
var _cpu_at := 0
var started_unix := 0
var loaded := false


func _init(p_hub: SocialHub) -> void:
	hub = p_hub
	started_unix = int(Time.get_unix_time_from_system())
	_set_default_items()
	var env_pw := OS.get_environment("ADMIN_PASSWORD") if OS.has_environment("ADMIN_PASSWORD") else ""
	if env_pw.length() >= 8:
		admin_pw_hash = SocialHub.hash_pw(env_pw)
		_ai_secret = (env_pw + ":plox-ai-key").sha256_buffer()


func _set_default_items() -> void:
	items.clear()
	item_order.clear()
	for d in PloxCatalog.DEFAULT_ITEMS:
		var it := PloxCatalog.clean_item(d)
		items[it.id] = it
		item_order.append(it.id)


func _db(q: String, params: Array = []) -> void:
	if hub.store != null:
		hub.store.exec(q, params)


static func today(now_unix: int) -> int:
	return int(now_unix / 86400)


func _now() -> int:
	return int(Time.get_unix_time_from_system())


func count(k: String, n := 1) -> void:
	var d := today(_now())
	if not daily.has(d):
		daily[d] = {}
	daily[d][k] = int(daily[d].get(k, 0)) + n
	_db("insert into plox_daily (day, k, n) values ($1, $2, $3) on conflict (day, k) do update set n = plox_daily.n + $3", [d, k, n])


# ------------------------------------------------------------------ loading

func load_from(data: Dictionary) -> void:
	var rows: Array = data.get("items", [])
	if not rows.is_empty():
		items.clear()
		item_order.clear()
		for r in rows:
			var it := PloxCatalog.clean_item(JSON.parse_string(str(r.def)))
			if not it.is_empty():
				items[it.id] = it
				item_order.append(it.id)
	elif hub.store != null and hub.store.writable:
		var pos := 0
		for id in item_order:
			_db("insert into plox_items (id, def, pos) values ($1, $2, $3) on conflict do nothing", [id, JSON.stringify(items[id]), pos])
			pos += 1
	for r in data.get("wallets", []):
		var eq := []
		for x in str(r.eq).split(",", false):
			eq.append(x)
		wallets[str(r.uid)] = {"coins": int(r.coins), "eq": eq, "daily_day": int(r.daily_day),
			"earn_day": int(r.earn_day), "earn_n": int(r.earn_n)}
	for r in data.get("owned", []):
		var u := str(r.uid)
		if not owned.has(u):
			owned[u] = {}
		owned[u][str(r.oid)] = {"item": str(r.item), "serial": int(r.serial)}
		sold[str(r.item)] = maxi(int(sold.get(str(r.item), 0)) + (0 if int(r.serial) > 0 else 1), int(r.serial))
	for r in data.get("games", []):
		var lv = JSON.parse_string(str(r.data))
		games[str(r.gid)] = {"gid": str(r.gid), "owner": str(r.owner), "title": str(r.title),
			"data": PloxLevel.clean(lv, PloxLevel.MAX_PARTS_HARD), "status": str(r.status), "featured": _truthy(r.featured),
			"plays": int(r.plays), "likes": int(r.likes), "created": int(r.created), "updated": int(r.updated), "paid": _truthy(r.paid)}
	for r in data.get("likes", []):
		if not likes.has(str(r.gid)):
			likes[str(r.gid)] = {}
		likes[str(r.gid)][str(r.uid)] = true
	for r in data.get("config", []):
		var k := str(r.k)
		var v = JSON.parse_string(str(r.v))
		match k:
			"live":
				if v is Dictionary:
					cfg.apply(v)
			"ai":
				if v is Dictionary:
					for kk in ai_cfg:
						ai_cfg[kk] = str(v.get(kk, ""))
			"admin_pw":
				if v is String and v != "":
					admin_pw_hash = v
			"bytes":
				if v is Dictionary:
					bytes_month = {"month": str(v.get("month", "")), "out": int(v.get("out", 0)), "in": int(v.get("in", 0))}
	for r in data.get("bans", []):
		bans[str(r.uid)] = {"until": int(r.until), "reason": str(r.reason)}
	for r in data.get("reports", []):
		reports.append({"id": int(r.id), "ts": int(r.ts), "from": str(r.from_uid), "target": str(r.target),
			"kind": str(r.kind), "text": str(r.text), "status": str(r.status)})
	for r in data.get("audit", []):
		audit.append({"id": int(r.id), "ts": int(r.ts), "who": str(r.who), "action": str(r.action), "detail": str(r.detail)})
	for r in data.get("ai_log", []):
		ai_log.append({"ts": int(r.ts), "uid": str(r.uid), "prompt": str(r.prompt), "ok": _truthy(r.ok), "ms": int(r.ms), "why": str(r.why)})
	for r in data.get("daily", []):
		var d := int(r.day)
		if not daily.has(d):
			daily[d] = {}
		daily[d][str(r.k)] = int(r.n)
	loaded = true


static func _truthy(v) -> bool:
	return v == true or str(v) == "true" or str(v) == "t"


# ------------------------------------------------------------------ hooks from SocialHub / referee

## Refuses banned players. Returns "" or a reason shown to the player.
func ban_reason(uid: String) -> String:
	if not bans.has(uid):
		return ""
	var b: Dictionary = bans[uid]
	if int(b.until) != 0 and int(b.until) < _now():
		bans.erase(uid)
		_db("delete from plox_bans where uid = $1", [uid])
		return ""
	var until := "for good" if int(b.until) == 0 else "until " + Time.get_date_string_from_unix_time(int(b.until))
	return "This account is banned %s.%s" % [until, (" Reason: " + str(b.reason)) if str(b.reason) != "" else ""]


func wallet(uid: String) -> Dictionary:
	if not wallets.has(uid):
		wallets[uid] = {"coins": cfg.i("start_coins"), "eq": [], "daily_day": 0, "earn_day": 0, "earn_n": 0}
		_db("insert into plox_wallet (uid, coins) values ($1, $2) on conflict do nothing", [uid, cfg.i("start_coins")])
	return wallets[uid]


func equipped_cards(uid: String) -> Array:
	var out := []
	if not wallets.has(uid):
		return out
	for id in wallets[uid].eq:
		if items.has(id):
			var it: Dictionary = items[id]
			out.append({"art": it.art, "col": it.col, "slot": it.slot})
	return out


## Extra fields on every profile card.
func card_extra(uid: String, out: Dictionary) -> void:
	var eq := equipped_cards(uid)
	if not eq.is_empty():
		out["eq"] = eq
	if playing.has(uid) and hub._online(uid):
		out["playing"] = _playing_label(str(playing[uid]))


func _playing_label(p: String) -> Dictionary:
	if p.begins_with("game:"):
		var gid := p.substr(5)
		if games.has(gid) and games[gid].status == "pub":
			return {"kind": "game", "gid": gid, "title": games[gid].title}
		return {"kind": "game", "gid": "", "title": "a Studio game"}
	return {"kind": p, "title": {"pop": "Pop-Up Panic", "neon": "Neon Bounce", "studio": "Studio"}.get(p, "a game")}


## Added to the welcome every phone gets.
func welcome_extra(uid: String, is_new: bool, out: Dictionary) -> void:
	if is_new:
		count("signups")
	count("logins")
	out["cfg"] = cfg.public()
	out["eco"] = _eco(uid)


func _eco(uid: String) -> Dictionary:
	var w := wallet(uid)
	var inv := []
	for oid in owned.get(uid, {}):
		var o: Dictionary = owned[uid][oid]
		inv.append({"oid": oid, "item": o.item, "serial": int(o.serial)})
	return {"coins": int(w.coins), "eq": w.eq, "inv": inv, "daily_ready": int(w.daily_day) < today(_now()),
		"daily": cfg.i("coins_daily")}


func _shop() -> Array:
	var out := []
	for id in item_order:
		var it: Dictionary = items[id]
		if bool(it.get("hidden", false)):
			continue
		var c := it.duplicate()
		if int(it.stock) >= 0:
			c["left"] = maxi(0, int(it.stock) - int(sold.get(id, 0)))
		out.append(c)
	return out


func filter_text(text: String) -> String:
	var words := cfg.s("banned_words").to_lower().split(",", false)
	if words.is_empty():
		return text
	var low := text.to_lower()
	for w in words:
		w = w.strip_edges()
		if w.length() < 2:
			continue
		var at := low.find(w)
		while at >= 0:
			text = text.substr(0, at) + "*".repeat(w.length()) + text.substr(at + w.length())
			low = text.to_lower()
			at = low.find(w, at + w.length())
	return text


func ticket_uid(t) -> String:
	if not (t is String) or not tickets.has(t):
		return ""
	var e: Array = tickets[t]
	if int(e[1]) < _now():
		tickets.erase(t)
		return ""
	return str(e[0])


## Pop-Up Panic round ended: humans get Plux, capped per day. uids: {client id: uid}.
func on_pop_round(scores: Dictionary, uids: Dictionary) -> void:
	var best := -1
	for id in scores:
		best = maxi(best, int(scores[id]))
	var d := today(_now())
	for id in uids:
		var uid: String = uids[id]
		count("rounds")
		if uid == "" or not hub.users.has(uid):
			continue
		var w := wallet(uid)
		if int(w.earn_day) != d:
			w.earn_day = d
			w.earn_n = 0
		if int(w.earn_n) >= cfg.i("round_rewards_per_day"):
			continue
		w.earn_n = int(w.earn_n) + 1
		var won := best > 0 and int(scores.get(id, 0)) == best
		var amount := cfg.i("coins_round") + (cfg.i("coins_win") if won else 0)
		w.coins = int(w.coins) + amount
		_db("update plox_wallet set coins = coins + $2, earn_day = $3, earn_n = $4 where uid = $1", [uid, amount, d, int(w.earn_n)])
		hub._push(uid, {"t": "s_plux", "coins": int(w.coins), "got": amount, "why": "win" if won else "round"})


# ------------------------------------------------------------------ player messages

const PLAYER_TYPES := ["s_eco", "s_daily", "s_buy", "s_equip", "s_ticket", "s_playing", "s_report",
	"s_studio_mine", "s_studio_get", "s_studio_save", "s_studio_publish", "s_studio_delete",
	"s_games", "s_game_get", "s_game_played", "s_game_like", "s_ai_build"]


func owns(t: String) -> bool:
	return PLAYER_TYPES.has(t)


func handle(cid: int, me: String, msg: Dictionary, rid, now: int) -> String:
	var reply := func(d: Dictionary):
		d["rid"] = rid
		hub._send.call(cid, d)
	match str(msg.t):
		"s_eco":
			reply.call({"t": "s_eco_res", "eco": _eco(me), "shop": _shop(), "cfg": cfg.public()})
		"s_daily":
			var w := wallet(me)
			var d := today(now)
			if int(w.daily_day) >= d:
				reply.call({"t": "s_daily_res", "ok": false, "why": "already", "coins": int(w.coins)})
				return ""
			var amt := cfg.i("coins_daily")
			w.daily_day = d
			w.coins = int(w.coins) + amt
			_db("update plox_wallet set coins = coins + $2, daily_day = $3 where uid = $1 and daily_day < $3", [me, amt, d])
			reply.call({"t": "s_daily_res", "ok": true, "got": amt, "coins": int(w.coins)})
		"s_buy":
			reply.call(_buy(me, str(msg.get("item", "")), now))
		"s_equip":
			var want = msg.get("eq")
			if not (want is Array) or want.size() > 4:
				return "bad_eq"
			var have := {}
			for oid in owned.get(me, {}):
				have[owned[me][oid].item] = true
			var slots := {}
			var eq := []
			for id in want:
				id = str(id)
				if have.has(id) and items.has(id) and not slots.has(items[id].slot):
					slots[items[id].slot] = true
					eq.append(id)
			var w := wallet(me)
			w.eq = eq
			_db("update plox_wallet set eq = $2 where uid = $1", [me, ",".join(PackedStringArray(eq))])
			reply.call({"t": "s_equip_res", "ok": true, "eq": eq})
			# Friends see the new look straight away.
			for f in hub.friends.get(me, {}):
				hub._push(f, {"t": "s_look", "uid": me, "eq": equipped_cards(me)})
		"s_ticket":
			var t := Crypto.new().generate_random_bytes(16).hex_encode()
			tickets[t] = [me, now + 900]
			if tickets.size() > 5000:
				for k in tickets.keys():
					if int(tickets[k][1]) < now:
						tickets.erase(k)
			reply.call({"t": "s_ticket_res", "ticket": t})
		"s_playing":
			var p := str(msg.get("what", ""))
			if p == "":
				playing.erase(me)
			elif p in ["pop", "neon", "studio"] or (p.begins_with("game:") and p.length() < 40):
				playing[me] = p
			for f in hub.friends.get(me, {}):
				hub._push(f, {"t": "s_playing", "uid": me, "playing": _playing_label(p) if p != "" else {}})
		"s_report":
			var target := str(msg.get("target", "")).substr(0, 64)
			var kind := str(msg.get("kind", "user"))
			if not kind in ["user", "chat", "game"] or target == "":
				return "bad_report"
			var text := SocialHub.clean_text(msg.get("text", ""), 500, true)
			var r := {"id": 0, "ts": now, "from": me, "target": target, "kind": kind, "text": text, "status": "open"}
			reports.push_front(r)
			if reports.size() > 300:
				reports.pop_back()
			_db("insert into plox_reports (ts, from_uid, target, kind, text) values ($1, $2, $3, $4, $5)", [now, me, target, kind, text])
			count("reports")
			reply.call({"t": "s_report_res", "ok": true})
		"s_studio_mine":
			var out := []
			for gid in games:
				if games[gid].owner == me and games[gid].status != "removed":
					out.append(_game_card(games[gid], me))
			out.sort_custom(func(a, b): return int(a.updated) > int(b.updated))
			reply.call({"t": "s_studio_mine_res", "games": out})
		"s_studio_get", "s_game_get":
			var gid := str(msg.get("gid", ""))
			if not games.has(gid):
				reply.call({"t": "s_game_res", "ok": false, "why": "missing"})
				return ""
			var g: Dictionary = games[gid]
			if g.owner != me and g.status != "pub":
				reply.call({"t": "s_game_res", "ok": false, "why": "hidden"})
				return ""
			reply.call({"t": "s_game_res", "ok": true, "game": _game_card(g, me), "level": g.data})
		"s_studio_save", "s_studio_publish":
			if not cfg.b("f_studio"):
				reply.call({"t": "s_studio_save_res", "ok": false, "why": "Studio is switched off right now."})
				return ""
			reply.call(_save_game(me, msg, now, msg.t == "s_studio_publish"))
		"s_studio_delete":
			var gid := str(msg.get("gid", ""))
			if games.has(gid) and games[gid].owner == me:
				games.erase(gid)
				_db("update plox_games set status = 'deleted' where gid = $1", [gid])
			reply.call({"t": "s_studio_delete_res", "ok": true, "gid": gid})
		"s_games":
			reply.call({"t": "s_games_res", "sort": str(msg.get("sort", "popular")), "games": _discover(me, str(msg.get("sort", "popular")))})
		"s_game_played":
			var gid := str(msg.get("gid", ""))
			if not games.has(gid) or games[gid].status != "pub":
				return ""
			var key := me + ":" + gid
			if now - int(plays_seen.get(key, 0)) < 600:
				return ""
			plays_seen[key] = now
			var g: Dictionary = games[gid]
			g.plays = int(g.plays) + 1
			_db("update plox_games set plays = plays + 1 where gid = $1", [gid])
			count("game_plays")
			if g.owner != me and cfg.i("coins_play_mine") > 0 and hub.users.has(g.owner):
				var w := wallet(g.owner)
				w.coins = int(w.coins) + cfg.i("coins_play_mine")
				_db("update plox_wallet set coins = coins + $2 where uid = $1", [g.owner, cfg.i("coins_play_mine")])
				hub._push(g.owner, {"t": "s_plux", "coins": int(w.coins), "got": cfg.i("coins_play_mine"), "why": "played"})
		"s_game_like":
			var gid := str(msg.get("gid", ""))
			if not games.has(gid) or games[gid].status != "pub":
				return ""
			var on := bool(msg.get("on", true))
			if not likes.has(gid):
				likes[gid] = {}
			var had: bool = likes[gid].has(me)
			if on and not had:
				likes[gid][me] = true
				games[gid].likes = int(games[gid].likes) + 1
				_db("insert into plox_likes (gid, uid) values ($1, $2) on conflict do nothing", [gid, me])
				_db("update plox_games set likes = likes + 1 where gid = $1", [gid])
			elif not on and had:
				likes[gid].erase(me)
				games[gid].likes = maxi(0, int(games[gid].likes) - 1)
				_db("delete from plox_likes where gid = $1 and uid = $2", [gid, me])
				_db("update plox_games set likes = greatest(likes - 1, 0) where gid = $1", [gid])
			reply.call({"t": "s_game_like_res", "gid": gid, "liked": on, "likes": int(games[gid].likes)})
		"s_ai_build":
			_ai_build(me, msg, reply, now)
	return ""


func _buy(me: String, id: String, now: int) -> Dictionary:
	var res := {"t": "s_buy_res", "ok": false, "item": id, "why": ""}
	if not cfg.b("f_shop"):
		res.why = "The shop is closed right now."
		return res
	if not items.has(id) or bool(items[id].get("hidden", false)):
		res.why = "That item isn't in the shop."
		return res
	var it: Dictionary = items[id]
	var w := wallet(me)
	for oid in owned.get(me, {}):
		if owned[me][oid].item == id:
			res.why = "You already own this."
			return res
	if int(w.coins) < int(it.price):
		res.why = "Not enough Plux."
		return res
	var serial := 0
	if int(it.stock) >= 0:
		if int(sold.get(id, 0)) >= int(it.stock):
			res.why = "Sold out."
			return res
	if bool(it.rare) or int(it.stock) >= 0:
		serial = int(sold.get(id, 0)) + 1
	sold[id] = int(sold.get(id, 0)) + 1
	var oid := Crypto.new().generate_random_bytes(12).hex_encode()
	w.coins = int(w.coins) - int(it.price)
	if not owned.has(me):
		owned[me] = {}
	owned[me][oid] = {"item": id, "serial": serial}
	# One statement: the item exists in the database only if the Plux came off.
	_db("with w as (update plox_wallet set coins = coins - $2 where uid = $1 and coins >= $2 returning uid) "
		+ "insert into plox_owned (oid, uid, item, serial, ts) select $3, $1, $4, $5, $6 from w", [me, int(it.price), oid, id, serial, now])
	count("buys")
	count("plux_spent", int(it.price))
	res.ok = true
	res["coins"] = int(w.coins)
	res["oid"] = oid
	res["serial"] = serial
	return res


func _game_card(g: Dictionary, viewer: String) -> Dictionary:
	var o: Dictionary = hub.users.get(g.owner, {})
	return {"gid": g.gid, "title": g.title, "owner": g.owner, "owner_name": str(o.get("name", "Player")),
		"owner_av": int(o.get("av", -1)), "status": g.status, "featured": g.featured, "plays": int(g.plays),
		"likes": int(g.likes), "liked": likes.get(g.gid, {}).has(viewer), "parts": g.data.parts.size(),
		"sky": int(g.data.sky), "updated": int(g.updated)}


func _discover(me: String, sort: String) -> Array:
	var list := []
	var my_friends: Dictionary = hub.friends.get(me, {})
	for gid in games:
		var g: Dictionary = games[gid]
		if g.status != "pub":
			continue
		if sort == "friends" and not my_friends.has(g.owner):
			continue
		list.append(g)
	match sort:
		"new":
			list.sort_custom(func(a, b): return int(a.created) > int(b.created))
		_:
			list.sort_custom(func(a, b): return (1 if a.featured else 0) > (1 if b.featured else 0) or ((a.featured == b.featured) and int(a.plays) * 2 + int(a.likes) * 5 > int(b.plays) * 2 + int(b.likes) * 5))
	var out := []
	for g in list.slice(0, 40):
		out.append(_game_card(g, me))
	return out


func _save_game(me: String, msg: Dictionary, now: int, publish: bool) -> Dictionary:
	var res := {"t": "s_studio_save_res", "ok": false, "why": "", "published": false}
	var gid := str(msg.get("gid", ""))
	var level := PloxLevel.clean(msg.get("level"), cfg.i("studio_max_parts"))
	level.title = filter_text(level.title)
	if gid != "" and (not games.has(gid) or games[gid].owner != me):
		res.why = "That game isn't yours."
		return res
	if gid == "":
		var mine := 0
		for g in games.values():
			if g.owner == me:
				mine += 1
		if mine >= cfg.i("studio_max_games_per_player"):
			res.why = "You've reached the limit of %d games. Delete one to make room." % cfg.i("studio_max_games_per_player")
			return res
		gid = Crypto.new().generate_random_bytes(6).hex_encode()
		games[gid] = {"gid": gid, "owner": me, "title": level.title, "data": level, "status": "draft", "featured": false,
			"plays": 0, "likes": 0, "created": now, "updated": now, "paid": false}
		count("studio_new")
	var g: Dictionary = games[gid]
	if g.status == "removed":
		res.why = "This game was removed by a moderator."
		return res
	g.data = level
	g.title = level.title
	g.updated = now
	if publish:
		var problem := PloxLevel.check(level)
		if problem != "":
			res.why = problem
			res["gid"] = gid
			_store_game(g)
			return res
		if g.status != "hidden":
			g.status = "pub"
		res.published = true
		count("publishes")
		if not g.paid and cfg.i("coins_publish") > 0:
			g.paid = true
			var w := wallet(me)
			w.coins = int(w.coins) + cfg.i("coins_publish")
			_db("update plox_wallet set coins = coins + $2 where uid = $1", [me, cfg.i("coins_publish")])
			res["got"] = cfg.i("coins_publish")
			res["coins"] = int(w.coins)
	_store_game(g)
	res.ok = true
	res["gid"] = gid
	res["game"] = _game_card(g, me)
	return res


func _store_game(g: Dictionary) -> void:
	_db("insert into plox_games (gid, owner, title, data, status, featured, plays, likes, created, updated, paid) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) "
		+ "on conflict (gid) do update set title = $3, data = $4, status = $5, featured = $6, updated = $10, paid = $11",
		[g.gid, g.owner, g.title, JSON.stringify(g.data), g.status, g.featured, int(g.plays), int(g.likes), int(g.created), int(g.updated), g.paid])


# ------------------------------------------------------------------ AI level building

func ai_ready() -> bool:
	return ai_cfg.base != "" and ai_cfg.model != "" and ai_cfg.key_enc != "" and not _ai_secret.is_empty()


func _ai_key() -> String:
	if ai_cfg.key_enc == "" or _ai_secret.is_empty():
		return ""
	var raw := Marshalls.base64_to_raw(ai_cfg.key_enc)
	if raw.size() < 32:
		return ""
	var iv := raw.slice(0, 16)
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, _ai_secret, iv)
	var plain := aes.update(raw.slice(16))
	aes.finish()
	var n := plain.size()
	if n == 0:
		return ""
	var pad := plain[n - 1]
	if pad < 1 or pad > 16:
		return ""
	return plain.slice(0, n - pad).get_string_from_utf8()


func _enc_key(key: String) -> String:
	var data := key.to_utf8_buffer()
	var pad := 16 - data.size() % 16
	for k in pad:
		data.append(pad)
	var iv := Crypto.new().generate_random_bytes(16)
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, _ai_secret, iv)
	var enc := aes.update(data)
	aes.finish()
	return Marshalls.raw_to_base64(iv + enc)


func _ai_build(me: String, msg: Dictionary, reply: Callable, now: int) -> void:
	var prompt := SocialHub.clean_text(msg.get("prompt", ""), MAX_PROMPT, false)
	var fail := func(why: String):
		reply.call({"t": "s_ai_res", "ok": false, "why": why})
	if not cfg.b("f_ai") or not cfg.b("f_studio"):
		fail.call("AI building is switched off right now.")
		return
	if not ai_ready():
		fail.call("AI building isn't set up on the server yet.")
		return
	if prompt.length() < 4:
		fail.call("Describe your game in a few words first.")
		return
	if _ai_busy.has(me):
		fail.call("Your last game is still being built.")
		return
	var used := _ai_used_today(me)
	if used >= cfg.i("ai_per_day"):
		fail.call("You've used all %d AI builds for today. More tomorrow!" % cfg.i("ai_per_day"))
		return
	if int(daily.get(today(now), {}).get("ai", 0)) >= AI_GLOBAL_PER_DAY:
		fail.call("The AI builder is very busy today. Try again tomorrow.")
		return
	_ai_busy[me] = true
	count("ai")
	count("ai:" + me)
	var started := Time.get_ticks_msec()
	_ai_call(prompt, func(ok: bool, level: Dictionary, why: String):
		_ai_busy.erase(me)
		var ms := Time.get_ticks_msec() - started
		_ai_note(me, prompt, ok, ms, why)
		if ok:
			reply.call({"t": "s_ai_res", "ok": true, "level": level, "left": maxi(0, cfg.i("ai_per_day") - _ai_used_today(me))})
		else:
			reply.call({"t": "s_ai_res", "ok": false, "why": "The AI couldn't build that one (%s). Try describing it differently." % why}))


func _ai_used_today(uid: String) -> int:
	return int(daily.get(today(_now()), {}).get("ai:" + uid, 0))


func _ai_note(uid: String, prompt: String, ok: bool, ms: int, why: String) -> void:
	ai_log.push_front({"ts": _now(), "uid": uid, "prompt": prompt, "ok": ok, "ms": ms, "why": why})
	if ai_log.size() > 300:
		ai_log.pop_back()
	_db("insert into plox_ai_log (ts, uid, prompt, ok, ms, why) values ($1, $2, $3, $4, $5, $6)", [_now(), uid, prompt, ok, ms, why])


## Calls {base}/chat/completions. done(ok, level, why). A test call uses a tiny prompt.
func _ai_call(prompt: String, done: Callable, test := false, override := {}) -> void:
	var base := str(override.get("base", ai_cfg.base)).strip_edges().trim_suffix("/")
	var model := str(override.get("model", ai_cfg.model)).strip_edges()
	var key := str(override.get("key", "")) if str(override.get("key", "")) != "" else _ai_key()
	if not (base.begins_with("https://") or base.begins_with("http://")):
		done.call(false, {}, "base URL must start with https://")
		return
	if base.ends_with("/chat/completions"):
		base = base.trim_suffix("/chat/completions")
	var http := HTTPRequest.new()
	http.timeout = float(cfg.i("ai_timeout_s"))
	http.use_threads = true
	add_child(http)
	var messages := []
	if test:
		messages = [{"role": "user", "content": "Reply with exactly this JSON and nothing else: {\"ok\": true}"}]
	else:
		messages = [{"role": "system", "content": PloxLevel.ai_system_prompt(mini(cfg.i("studio_max_parts"), 90))},
			{"role": "user", "content": "Build this game: " + prompt}]
	var body := {"model": model, "messages": messages, "max_tokens": 40 if test else cfg.i("ai_max_tokens"), "temperature": 0.7}
	var headers := PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + key,
		"HTTP-Referer: https://github.com/eduzd/blockparty", "X-Title: Plox"])
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, raw: PackedByteArray):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS:
			done.call(false, {}, "timed out" if result == HTTPRequest.RESULT_TIMEOUT else "could not reach the AI (%d)" % result)
			return
		var text := raw.get_string_from_utf8()
		if code < 200 or code >= 300:
			var emsg := text.substr(0, 160)
			var pj = JSON.parse_string(text)
			if pj is Dictionary and pj.get("error") is Dictionary:
				emsg = str(pj.error.get("message", emsg)).substr(0, 160)
			done.call(false, {}, "HTTP %d: %s" % [code, emsg])
			return
		var content := _content_of(text)
		if content == "":
			done.call(false, {}, "empty answer")
			return
		var obj = _json_in(content)
		if not (obj is Dictionary):
			done.call(false, {}, "answer was not JSON")
			return
		if test:
			done.call(true, {}, "")
			return
		var level := PloxLevel.clean(obj, cfg.i("studio_max_parts"))
		if level.parts.size() < 3:
			done.call(false, {}, "too few parts")
			return
		done.call(true, level, ""))
	var err := http.request(base + "/chat/completions", headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		done.call(false, {}, "request failed (%d)" % err)


static func _content_of(text: String) -> String:
	var j = JSON.parse_string(text)
	if not (j is Dictionary):
		return ""
	var ch = j.get("choices")
	if not (ch is Array) or ch.is_empty() or not (ch[0] is Dictionary):
		return ""
	var m = ch[0].get("message")
	if m is Dictionary and m.get("content") is String:
		return m.content
	return ""


## Finds the first {...} JSON object in a reply, even inside code fences or prose.
static func _json_in(s: String):
	var a := s.find("{")
	var b := s.rfind("}")
	if a < 0 or b <= a:
		return null
	return JSON.parse_string(s.substr(a, b - a + 1))


# ------------------------------------------------------------------ admin

func is_admin_type(t: String) -> bool:
	return t.begins_with("a_")


func admin_drop(cid: int) -> void:
	admin_cids.erase(cid)


func _audit(action: String, detail: String) -> void:
	var e := {"id": 0, "ts": _now(), "who": "admin", "action": action, "detail": detail.substr(0, 500)}
	audit.push_front(e)
	if audit.size() > 300:
		audit.pop_back()
	_db("insert into plox_audit (ts, who, action, detail) values ($1, $2, $3, $4)", [e.ts, e.who, action, e.detail])


func _save_cfg() -> void:
	_db("insert into plox_config (k, v) values ('live', $1) on conflict (k) do update set v = $1", [JSON.stringify(cfg.values)])


func _save_ai() -> void:
	_db("insert into plox_config (k, v) values ('ai', $1) on conflict (k) do update set v = $1", [JSON.stringify(ai_cfg)])


func broadcast_cfg() -> void:
	var m := {"t": "s_cfg", "cfg": cfg.public()}
	for cid in hub.by_cid:
		hub._send.call(cid, m)


func note_bytes(out_n: int, in_n: int) -> void:
	var month := Time.get_date_string_from_system(true).substr(0, 7)
	if bytes_month.month != month:
		bytes_month = {"month": month, "out": 0, "in": 0}
	bytes_month.out = int(bytes_month.out) + out_n
	bytes_month["in"] = int(bytes_month["in"]) + in_n


func _process(_d: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _bytes_saved_at > 300000:
		_bytes_saved_at = now
		_db("insert into plox_config (k, v) values ('bytes', $1) on conflict (k) do update set v = $1", [JSON.stringify(bytes_month)])
	if now - _cpu_at > 5000:
		_cpu_at = now
		var f := FileAccess.open("/proc/self/stat", FileAccess.READ)
		if f:
			var parts := f.get_as_text().split(" ")
			if parts.size() > 15:
				var ticks := int(parts[13]) + int(parts[14])
				if _cpu_last[1] > 0:
					cpu_pct = float(ticks - _cpu_last[0]) * 10.0 / float(now - _cpu_last[1]) * 100.0
				_cpu_last = [ticks, now]


func _mem_mb() -> float:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f:
		for line in f.get_as_text().split("\n"):
			if line.begins_with("VmRSS:"):
				return float(line.split(":")[1].strip_edges().split(" ")[0]) / 1024.0
	return float(OS.get_static_memory_usage()) / 1048576.0


func _stats() -> Dictionary:
	var d := today(_now())
	var days := []
	for k in range(13, -1, -1):
		var row: Dictionary = daily.get(d - k, {})
		days.append({"day": Time.get_date_string_from_unix_time((d - k) * 86400), "signups": int(row.get("signups", 0)),
			"logins": int(row.get("logins", 0)), "rounds": int(row.get("rounds", 0)), "game_plays": int(row.get("game_plays", 0)),
			"buys": int(row.get("buys", 0)), "ai": int(row.get("ai", 0)), "publishes": int(row.get("publishes", 0))})
	var pub := 0
	for g in games.values():
		if g.status == "pub":
			pub += 1
	var plux := 0
	for w in wallets.values():
		plux += int(w.coins)
	var rs: Dictionary = referee.room_stats() if referee and referee.has_method("room_stats") else {}
	var open_reports := 0
	for r in reports:
		if r.status == "open":
			open_reports += 1
	return {"online": hub.by_cid.size(), "connections": rs.get("connections", 0), "rooms": rs.get("rooms", 0), "pop_rooms": rs.get("pop_rooms", 0),
		"in_games": rs.get("in_games", 0), "accounts": hub.users.size(), "games_published": pub, "games_total": games.size(),
		"plux_total": plux, "open_reports": open_reports, "days": days,
		"cpu": snappedf(cpu_pct, 0.1), "mem_mb": snappedf(_mem_mb(), 0.1), "uptime_s": _now() - started_unix,
		"bytes_out": int(bytes_month.out), "bytes_in": int(bytes_month["in"]), "month": bytes_month.month,
		"storage": hub.store != null and hub.store.writable, "storage_pending": hub.store.pending() if hub.store else 0,
		"ai_ready": ai_ready(), "version": Protocol.SERVER_VERSION}


func _user_row(uid: String) -> Dictionary:
	var u: Dictionary = hub.users.get(uid, {})
	var w: Dictionary = wallets.get(uid, {})
	return {"uid": uid, "name": str(u.get("name", "Player")), "username": str(u.get("username", "")), "online": hub._online(uid),
		"seen": int(u.get("last_seen", 0)), "plux": int(w.get("coins", 0)), "items": owned.get(uid, {}).size(),
		"friends": hub.friends.get(uid, {}).size(), "has_pw": str(u.get("pw", "")) != "", "av": int(u.get("av", -1)),
		"banned": ban_reason(uid) != "", "ban": bans.get(uid, {})}


## Admin messages. Returns "" or an error code for the referee.
func admin_handle(cid: int, msg: Dictionary, send: Callable) -> String:
	var t := str(msg.t)
	var rid = msg.get("rid", 0)
	var reply := func(d: Dictionary):
		d["rid"] = rid
		send.call(d)
	var now := _now()
	if t == "a_login":
		if admin_pw_hash == "":
			reply.call({"t": "a_login_res", "ok": false, "why": "The admin password isn't set on the server (ADMIN_PASSWORD)."})
			return ""
		if int(_admin_fails[0]) >= ADMIN_LOCK_FAILS and now - int(_admin_fails[1]) < ADMIN_LOCK_S:
			reply.call({"t": "a_login_res", "ok": false, "why": "Too many wrong passwords. Try again in 10 minutes."})
			return ""
		var pw = msg.get("pw")
		if pw is String and pw.length() <= 128 and SocialHub.check_pw(pw, admin_pw_hash):
			_admin_fails = [0, 0]
			admin_cids[cid] = true
			_audit("login", "admin signed in")
			reply.call({"t": "a_login_res", "ok": true, "stats": _stats(), "cfg": cfg.values, "defaults": LiveConfig.DEFAULTS})
		else:
			if now - int(_admin_fails[1]) >= ADMIN_LOCK_S:
				_admin_fails = [0, now]
			_admin_fails[0] = int(_admin_fails[0]) + 1
			reply.call({"t": "a_login_res", "ok": false, "why": "Wrong password."})
		return ""
	if not admin_cids.has(cid):
		reply.call({"t": "a_err", "why": "not_admin"})
		return "not_admin"
	match t:
		"a_stats":
			reply.call({"t": "a_stats_res", "stats": _stats()})
		"a_users":
			var q := str(msg.get("q", "")).to_lower().strip_edges()
			var rows := []
			for uid in hub.users:
				var u: Dictionary = hub.users[uid]
				if str(u.get("username", "")) == "" and not wallets.has(uid):
					continue
				if q == "" or str(u.get("username", "")).to_lower().contains(q) or str(u.get("name", "")).to_lower().contains(q) or uid.begins_with(q):
					rows.append(_user_row(uid))
			rows.sort_custom(func(a, b): return (1 if a.online else 0) > (1 if b.online else 0) or (a.online == b.online and int(a.seen) > int(b.seen)))
			reply.call({"t": "a_users_res", "users": rows.slice(0, 60), "total": rows.size()})
		"a_ban":
			var uid := str(msg.get("uid", ""))
			if not hub.users.has(uid):
				reply.call({"t": "a_ok", "ok": false, "why": "No such player."})
				return ""
			var days := clampi(int(msg.get("days", 0)) if (msg.get("days", 0) is int or msg.get("days", 0) is float) else 0, 0, 3650)
			var reason := SocialHub.clean_text(msg.get("reason", ""), 200, false)
			var until := 0 if days == 0 else now + days * 86400
			bans[uid] = {"until": until, "reason": reason}
			_db("insert into plox_bans (uid, until, reason) values ($1, $2, $3) on conflict (uid) do update set until = $2, reason = $3", [uid, until, reason])
			_audit("ban", "@%s for %s: %s" % [hub.users[uid].get("username", uid), ("%d days" % days) if days > 0 else "good", reason])
			if hub._online(uid):
				var ucid := int(hub.users[uid].cid)
				hub._send.call(ucid, {"t": "error", "code": "banned", "msg": ban_reason(uid), "fatal": true})
				if referee and referee.has_method("drop_client"):
					referee.drop_client(ucid)
			reply.call({"t": "a_ok", "ok": true, "user": _user_row(uid)})
		"a_unban":
			var uid := str(msg.get("uid", ""))
			bans.erase(uid)
			_db("delete from plox_bans where uid = $1", [uid])
			_audit("unban", "@%s" % hub.users.get(uid, {}).get("username", uid))
			reply.call({"t": "a_ok", "ok": true, "user": _user_row(uid)})
		"a_resetpw":
			var uid := str(msg.get("uid", ""))
			if not hub.users.has(uid):
				reply.call({"t": "a_ok", "ok": false, "why": "No such player."})
				return ""
			# Clears the password and signs out other phones; the player sets a new one in Settings.
			hub.users[uid].pw = ""
			_db("update bp_users set pw = null where uid = $1", [uid])
			for th in hub.sessions.keys():
				if hub.sessions[th] == uid:
					hub.sessions.erase(th)
			_db("delete from bp_sessions where uid = $1", [uid])
			_audit("reset password", "@%s" % hub.users[uid].get("username", uid))
			reply.call({"t": "a_ok", "ok": true, "user": _user_row(uid)})
		"a_plux":
			var uid := str(msg.get("uid", ""))
			var delta = msg.get("delta", 0)
			if not hub.users.has(uid) or not (delta is int or delta is float):
				reply.call({"t": "a_ok", "ok": false, "why": "No such player."})
				return ""
			var w := wallet(uid)
			var dd := clampi(int(delta), -int(w.coins), 10000000)
			w.coins = int(w.coins) + dd
			_db("update plox_wallet set coins = greatest(coins + $2, 0) where uid = $1", [uid, dd])
			_audit("plux", "%+d Plux to @%s: %s" % [dd, hub.users[uid].get("username", uid), SocialHub.clean_text(msg.get("reason", ""), 120, false)])
			hub._push(uid, {"t": "s_plux", "coins": int(w.coins), "got": dd, "why": "admin"})
			reply.call({"t": "a_ok", "ok": true, "user": _user_row(uid)})
		"a_items":
			var list := []
			for id in item_order:
				var c: Dictionary = items[id].duplicate()
				c["sold"] = int(sold.get(id, 0))
				list.append(c)
			reply.call({"t": "a_items_res", "items": list, "arts": PloxCatalog.ARTS, "slots": PloxCatalog.SLOTS})
		"a_item_save":
			var it := PloxCatalog.clean_item(msg.get("item"))
			if it.is_empty():
				reply.call({"t": "a_ok", "ok": false, "why": "Check the id (letters, numbers, _), slot and look."})
				return ""
			if int(it.stock) >= 0 and int(it.stock) < int(sold.get(it.id, 0)):
				it.stock = int(sold.get(it.id, 0))
			var is_new := not items.has(it.id)
			items[it.id] = it
			if is_new:
				item_order.append(it.id)
			_db("insert into plox_items (id, def, pos) values ($1, $2, $3) on conflict (id) do update set def = $2", [it.id, JSON.stringify(it), item_order.find(it.id)])
			_audit("item " + ("added" if is_new else "edited"), "%s (%s): %d Plux, stock %s%s" % [it.name, it.id, it.price, "unlimited" if it.stock < 0 else str(it.stock), ", hidden" if it.hidden else ""])
			reply.call({"t": "a_ok", "ok": true, "item": it})
		"a_games":
			var list := []
			var q := str(msg.get("q", "")).to_lower()
			for g in games.values():
				if q == "" or str(g.title).to_lower().contains(q):
					var c := _game_card(g, "")
					c["owner_username"] = str(hub.users.get(g.owner, {}).get("username", ""))
					list.append(c)
			list.sort_custom(func(a, b): return int(a.updated) > int(b.updated))
			reply.call({"t": "a_games_res", "games": list.slice(0, 80)})
		"a_game_set":
			var gid := str(msg.get("gid", ""))
			if not games.has(gid):
				reply.call({"t": "a_ok", "ok": false, "why": "No such game."})
				return ""
			var g: Dictionary = games[gid]
			if msg.get("featured") is bool:
				g.featured = msg.featured
			var st := str(msg.get("status", ""))
			if st in ["pub", "hidden", "removed", "draft"]:
				g.status = st
			_store_game(g)
			_audit("game", "%s: %s%s" % [g.title, g.status, ", featured" if g.featured else ""])
			reply.call({"t": "a_ok", "ok": true, "game": _game_card(g, "")})
		"a_reports":
			var list := []
			for r in reports:
				var c: Dictionary = r.duplicate()
				c["from_name"] = str(hub.users.get(r.from, {}).get("username", ""))
				if r.kind == "game":
					c["target_name"] = str(games.get(r.target, {}).get("title", r.target))
				else:
					c["target_name"] = "@" + str(hub.users.get(r.target, {}).get("username", r.target))
				list.append(c)
			reply.call({"t": "a_reports_res", "reports": list.slice(0, 100)})
		"a_report_set":
			var ts = msg.get("ts")
			var st := str(msg.get("status", "done"))
			for r in reports:
				if int(r.ts) == int(ts if (ts is int or ts is float) else -1) and r.from == str(msg.get("from", "")):
					r.status = st
					_db("update plox_reports set status = $3 where ts = $1 and from_uid = $2", [int(r.ts), r.from, st])
			_audit("report", "marked " + st)
			reply.call({"t": "a_ok", "ok": true})
		"a_cfg_set":
			var vals = msg.get("values")
			if not (vals is Dictionary):
				return "bad_cfg"
			if vals.has("announce") and str(vals.get("announce", "")) != cfg.s("announce"):
				vals["announce_id"] = now
			var changed := cfg.apply(vals)
			if not changed.is_empty():
				_save_cfg()
				var parts := []
				for k in changed:
					parts.append("%s = %s" % [k, str(cfg.values[k]).substr(0, 60)])
				_audit("settings", ", ".join(PackedStringArray(parts)))
				broadcast_cfg()
			reply.call({"t": "a_ok", "ok": true, "changed": changed, "cfg": cfg.values})
		"a_ai_get":
			reply.call({"t": "a_ai_res", "base": ai_cfg.base, "model": ai_cfg.model, "key": ("••••••••" + ai_cfg.key_tail) if ai_cfg.key_enc != "" else "",
				"ready": ai_ready(), "log": ai_log.slice(0, 60), "today": int(daily.get(today(now), {}).get("ai", 0))})
		"a_ai_set":
			var base := str(msg.get("base", ai_cfg.base)).strip_edges().substr(0, 300)
			var model := str(msg.get("model", ai_cfg.model)).strip_edges().substr(0, 120)
			var key := str(msg.get("key", "")).strip_edges()
			if base != "" and not (base.begins_with("https://") or base.begins_with("http://")):
				reply.call({"t": "a_ok", "ok": false, "why": "The base URL must start with https://"})
				return ""
			if _ai_secret.is_empty():
				reply.call({"t": "a_ok", "ok": false, "why": "The server has no ADMIN_PASSWORD, so it can't lock the key."})
				return ""
			ai_cfg.base = base
			ai_cfg.model = model
			if key != "" and key.length() <= 400:
				ai_cfg.key_enc = _enc_key(key)
				ai_cfg.key_tail = key.substr(maxi(0, key.length() - 4))
			elif bool(msg.get("clear_key", false)):
				ai_cfg.key_enc = ""
				ai_cfg.key_tail = ""
			_save_ai()
			_audit("ai settings", "base %s, model %s%s" % [base, model, ", new key" if key != "" else ""])
			reply.call({"t": "a_ok", "ok": true, "key": ("••••••••" + ai_cfg.key_tail) if ai_cfg.key_enc != "" else "", "ready": ai_ready()})
		"a_ai_test":
			var started := Time.get_ticks_msec()
			var full := bool(msg.get("full", false))
			_ai_call("a short obstacle course with a jump pad" if full else "", func(ok: bool, level: Dictionary, why: String):
				var ms := Time.get_ticks_msec() - started
				_ai_note("admin", "(test)" if not full else "(test build)", ok, ms, why)
				reply.call({"t": "a_ai_test_res", "ok": ok, "why": why, "ms": ms, "parts": level.get("parts", []).size(), "title": level.get("title", "")}), not full)
		"a_audit":
			reply.call({"t": "a_audit_res", "audit": audit.slice(0, 150)})
		"a_admin_pw":
			var old = msg.get("old")
			var nw = msg.get("new")
			if not (old is String) or not SocialHub.check_pw(old, admin_pw_hash):
				reply.call({"t": "a_ok", "ok": false, "why": "The current password is wrong."})
			elif not (nw is String) or nw.length() < 10 or nw.length() > 128:
				reply.call({"t": "a_ok", "ok": false, "why": "Use at least 10 characters."})
			else:
				admin_pw_hash = SocialHub.hash_pw(nw)
				_db("insert into plox_config (k, v) values ('admin_pw', $1) on conflict (k) do update set v = $1", [JSON.stringify(admin_pw_hash)])
				_audit("admin password", "changed")
				reply.call({"t": "a_ok", "ok": true})
		"a_logout":
			admin_cids.erase(cid)
			reply.call({"t": "a_ok", "ok": true})
		_:
			return "unknown_type"
	return ""
