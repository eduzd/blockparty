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
	"create table if not exists plox_trades (id text primary key, from_uid text not null, to_uid text not null, give text not null default '', get_oids text not null default '', coins_give bigint not null default 0, coins_get bigint not null default 0, status text not null default 'open', created bigint not null default 0, updated bigint not null default 0, why text not null default '')",
	"create table if not exists plox_orders (id text primary key, uid text not null, pack text not null, plux bigint not null, price text not null default '0', cur text not null default 'USD', provider text not null default '', mode text not null default 'sandbox', status text not null default 'created', created bigint not null default 0, paid bigint not null default 0, pay_ref text unique)",
	"create table if not exists plox_outfits (uid text primary key, data text not null default '[]')",
	"create table if not exists plox_pro (uid text primary key, tier text not null, until_ts bigint not null default 0, source text not null default '', auto_renew boolean not null default false, last_allow bigint not null default 0)",
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
	["trades", "select id, from_uid, to_uid, give, get_oids, coins_give, coins_get, status, created, updated, why from plox_trades where status = 'open' or updated > extract(epoch from now())::bigint - 30 * 86400"],
	["orders", "select id, uid, pack, plux, price, cur, provider, mode, status, created, paid, pay_ref from plox_orders where status in ('created', 'paid') or created > extract(epoch from now())::bigint - 30 * 86400"],
	["outfits", "select uid, data from plox_outfits"],
	["pro", "select uid, tier, until_ts, source, auto_renew, last_allow from plox_pro"],
	["daily", "select day, k, n from plox_daily where day > (extract(epoch from now())::bigint / 86400) - 35"],
]
const ADMIN_LOCK_FAILS := 5
const ADMIN_LOCK_S := 600
const AI_GLOBAL_PER_DAY := 300
const MAX_PROMPT := 1000
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
var playing_room := {}   # uid -> room code friends can join (0.7.0)
var invite_joins := {}  # uid -> how many people signed up with their code (since restart)
var invite_times := {}   # uid -> [unix, ...] recent invites, for the rate limit
var plays_seen := {}     # "uid:gid" -> unix
var tickets := {}        # ticket -> [uid, expires_unix]
var admin_cids := {}     # cid -> true
var _admin_fails: Array = [0, 0]   # count, first fail unix
var admin_pw_hash := ""
var admin_test_hash := ""   # ADMIN_TEST_PASSWORD: a second login used only by the automated checks
var ai_cfg := {"base": "", "model": "", "key_enc": "", "key_tail": ""}
## 0.7.1: AI agents. Each has its own job, rules (added to its prompt on every call),
## model (empty = the shared one), switch and daily limit. The admin creates, edits,
## copies and deletes them in Plux Admin; they live in plox_config under "agents".
const BUILTIN_AGENTS := [
	{"id": "studio_builder", "name": "Studio Builder", "job": "Turns a player's idea into a playable game in Studio.", "on": true, "model": "", "rules": "", "per_day": 0, "status": "live", "builtin": true},
	{"id": "game_editor", "name": "Game Editor", "job": "Changes a Studio game when the player asks in words (\"make it harder\", \"add lava\").", "on": true, "model": "", "rules": "", "per_day": 0, "status": "live", "builtin": true},
	{"id": "chat_moderator", "name": "Chat Moderator", "job": "Checks chat messages and flags unsafe ones.", "on": false, "model": "", "rules": "", "per_day": 0, "status": "planned", "builtin": true},
	{"id": "support_helper", "name": "Support Helper", "job": "Answers players' questions about Plux.", "on": false, "model": "", "rules": "", "per_day": 0, "status": "planned", "builtin": true},
	{"id": "npc", "name": "In-game NPCs", "job": "Characters that talk to players inside games.", "on": false, "model": "", "rules": "", "per_day": 0, "status": "planned", "builtin": true},
]
var agents: Array = []
var _ai_busy := {}
var _ai_secret := PackedByteArray()
var bytes_month := {"month": "", "out": 0, "in": 0}
var _bytes_saved_at := 0
var _cpu_last := [0, 0]   # [process ticks, msec]
var cpu_pct := 0.0
var _cpu_at := 0
var started_unix := 0
var loaded := false
var trade: PloxTrade
var pay: PloxPay
var neon_paid := {}   # uid -> [day, stays paid today]
var goal_paid := {}   # uid:gid -> unix of the last goal reward


func _init(p_hub: SocialHub) -> void:
	hub = p_hub
	trade = PloxTrade.new(self)
	pay = PloxPay.new(self)
	started_unix = int(Time.get_unix_time_from_system())
	_set_default_items()
	var env_pw := OS.get_environment("ADMIN_PASSWORD") if OS.has_environment("ADMIN_PASSWORD") else ""
	if env_pw.length() >= 8:
		admin_pw_hash = SocialHub.hash_pw(env_pw)
		_ai_secret = (env_pw + ":plox-ai-key").sha256_buffer()
	var test_pw := OS.get_environment("ADMIN_TEST_PASSWORD") if OS.has_environment("ADMIN_TEST_PASSWORD") else ""
	if test_pw.length() >= 16:
		admin_test_hash = SocialHub.hash_pw(test_pw)
	# The AI key is locked with its own secret when one is set, so changing the admin
	# password later never loses the saved key.
	var key_secret := OS.get_environment("PLUX_KEY_SECRET") if OS.has_environment("PLUX_KEY_SECRET") else ""
	if key_secret.length() >= 16:
		_ai_secret = (key_secret + ":plox-ai-key").sha256_buffer()


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
			"agents":
				if v is Array:
					_load_agents(v)
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
	trade.load_rows(data.get("trades", []))
	pay.load_rows(data.get("orders", []))
	pay.load_pro(data.get("pro", []))
	for r in data.get("outfits", []):
		var o = JSON.parse_string(str(r.data))
		if o is Array:
			outfits[str(r.uid)] = o
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
		out["playing"] = _playing_full(uid)
	if pay.is_pro(uid):
		out["pro"] = true


func _playing_label(p: String) -> Dictionary:
	if p.begins_with("game:"):
		var gid := p.substr(5)
		if games.has(gid) and games[gid].status == "pub":
			return {"kind": "game", "gid": gid, "title": games[gid].title}
		return {"kind": "game", "gid": "", "title": "a Studio game"}
	return {"kind": p, "title": {"pop": "Pop-Up Panic", "neon": "Neon Bounce", "studio": "Studio"}.get(p, "a game")}


func _playing_full(uid: String) -> Dictionary:
	if not playing.has(uid):
		return {}
	var d := _playing_label(str(playing[uid]))
	if playing_room.has(uid) and d.kind in ["pop", "neon"]:
		d["room"] = playing_room[uid]
	return d


static func clean_room(v) -> String:
	var s := (str(v) if v is String else "").to_upper()
	var out := ""
	for ch in s:
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out.substr(0, 12)


## Stable invite code for a player, e.g. "7F3A9C21".
static func invite_code(uid: String) -> String:
	return ("plux-invite:" + uid).sha256_text().substr(0, 8).to_upper()


func uid_for_invite(code: String) -> String:
	code = code.strip_edges().to_upper()
	if code.length() != 8:
		return ""
	for uid in hub.users:
		if invite_code(uid) == code:
			return uid
	return ""


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
		"daily": cfg.i("coins_daily"), "pro": pay.pro_status(uid)}


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


var outfits := {}   # uid -> [{name, eq}]


func outfit_cap(uid: String) -> int:
	var t := pay.tier_of(uid)
	return maxi(cfg.i("outfits_free"), int(t.get("outfits", 0))) if not t.is_empty() else cfg.i("outfits_free")


func _outfits_res(uid: String) -> Dictionary:
	return {"t": "s_outfits_res", "ok": false, "why": "", "outfits": outfits.get(uid, []), "cap": outfit_cap(uid)}


func ai_cap_for(uid: String) -> int:
	var pd := int(agent("studio_builder").get("per_day", 0))
	return (pd if pd > 0 else cfg.i("ai_per_day")) + int(pay.tier_of(uid).get("ai_extra", 0))


## Pays a player for playing, inside the shared daily cap. Returns the Plux paid.
func earn(uid: String, amount: int, why: String) -> int:
	if amount <= 0 or uid == "" or not hub.users.has(uid) or ban_reason(uid) != "":
		return 0
	var d := today(_now())
	var w := wallet(uid)
	if int(w.earn_day) != d:
		w.earn_day = d
		w.earn_n = 0
	if int(w.earn_n) >= cfg.i("round_rewards_per_day"):
		return 0
	w.earn_n = int(w.earn_n) + 1
	w.coins = int(w.coins) + amount
	_db("update plox_wallet set coins = coins + $2, earn_day = $3, earn_n = $4 where uid = $1", [uid, amount, d, int(w.earn_n)])
	count("plux_earned", amount)
	hub._push(uid, {"t": "s_plux", "coins": int(w.coins), "got": amount, "why": why})
	return amount


## A player left a Neon Bounce room after `secs` seconds: one reward per full
## neon_reward_s, at most 5 a visit.
func on_neon_left(uid: String, secs: int) -> void:
	if not cfg.b("f_neon"):
		return
	var stays := mini(5, secs / maxi(15, cfg.i("neon_reward_s")))
	for k in stays:
		if earn(uid, cfg.i("coins_neon"), "neon") == 0:
			break


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
	"s_games", "s_game_get", "s_game_played", "s_game_like", "s_ai_build",
	"s_inv", "s_trades", "s_trade_offer", "s_trade_accept", "s_trade_decline", "s_trade_cancel",
	"s_game_done", "s_packs", "s_pay_start", "s_pay_confirm", "s_orders",
	"s_invite", "s_invite_reply", "s_invite_code", "s_outfits", "s_outfit_save", "s_outfit_del", "s_pro", "s_pro_cancel", "s_pro_renew_test"]


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
				playing_room.erase(me)
			elif p in ["pop", "neon", "studio"] or (p.begins_with("game:") and p.length() < 40):
				playing[me] = p
				var room := clean_room(msg.get("room", ""))
				if room != "":
					playing_room[me] = room
				else:
					playing_room.erase(me)
			for f in hub.friends.get(me, {}):
				hub._push(f, {"t": "s_playing", "uid": me, "playing": _playing_full(me) if p != "" else {}})
		"s_invite":
			var res := {"t": "s_invite_res", "ok": false, "why": "", "sent": 0, "offline": 0}
			var what := str(msg.get("what", ""))
			var room := clean_room(msg.get("room", ""))
			var gid := str(msg.get("gid", "")).substr(0, 40)
			var to = msg.get("to")
			if not cfg.b("f_invites"):
				res.why = "Invites are switched off right now."
			elif not (what in ["pop", "neon", "game"]) or (what != "game" and room == "") or (what == "game" and not (games.has(gid) and games[gid].status == "pub")):
				res.why = "There's no game to invite to."
			elif not (to is Array) or to.is_empty():
				res.why = "Pick a friend."
			else:
				var recent: Array = []
				for t0 in invite_times.get(me, []):
					if now - int(t0) < 60:
						recent.append(t0)
				var title: String = games[gid].title if what == "game" else {"pop": "Pop-Up Panic", "neon": "Neon Bounce"}[what]
				var from := hub._small(me)
				from["av"] = int(hub.users[me].get("av", -1))
				for f in to.slice(0, 20):
					var fu := str(f)
					if not hub.friends.get(me, {}).has(fu):
						continue
					if recent.size() >= 30:
						res.why = "Slow down a little: too many invites."
						break
					recent.append(now)
					if not hub._online(fu):
						res.offline += 1
						continue
					hub._push(fu, {"t": "s_invite_in", "id": Crypto.new().generate_random_bytes(6).hex_encode(), "from": from,
						"what": what, "title": title, "room": room, "gid": gid, "ts": now})
					res.sent += 1
				invite_times[me] = recent
				res.ok = res.sent > 0 or res.offline > 0
				count("invites", res.sent)
			reply.call(res)
		"s_invite_reply":
			var to := str(msg.get("to", ""))
			if hub.friends.get(me, {}).has(to):
				hub._push(to, {"t": "s_invite_ans", "uid": me, "name": str(hub.users[me].get("name", "")), "join": bool(msg.get("join", false))})
			reply.call({"t": "s_invite_reply_res", "ok": true})
		"s_invite_code":
			var code := invite_code(me)
			var url := cfg.s("download_url")
			var text := "Play with me on Plux! My invite code is %s." % code
			if url != "":
				text += " Get the app: " + url
			reply.call({"t": "s_invite_code_res", "code": code, "url": url, "text": text, "joined": int(invite_joins.get(me, 0))})
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
			# 0.7.1: Studio says plainly when the AI builder isn't set up yet.
			reply.call({"t": "s_studio_mine_res", "games": out, "ai": ai_ready() and bool(agent("studio_builder").get("on", true))})
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
		"s_game_done":
			# Reached the goal of a published Studio game. Paid once per game per
			# 10 minutes, never for your own game, and only after a real attempt.
			var gid := str(msg.get("gid", ""))
			var ms = msg.get("ms", 0)
			if not games.has(gid) or games[gid].status != "pub" or games[gid].owner == me:
				reply.call({"t": "s_game_done_res", "gid": gid, "got": 0})
				return ""
			var key := me + ":" + gid
			var first := not goal_paid.has(key)
			var got := 0
			if (ms is int or ms is float) and int(ms) >= 4000 and now - int(goal_paid.get(key, 0)) >= 600:
				goal_paid[key] = now
				got = earn(me, cfg.i("coins_studio_goal") + (cfg.i("coins_studio_first") if first else 0), "goal")
			reply.call({"t": "s_game_done_res", "gid": gid, "got": got})
		"s_packs":
			reply.call(pay.store_info(me))
		"s_outfits":
			reply.call(_outfits_res(me))
		"s_outfit_save":
			var list: Array = outfits.get(me, [])
			var cap := outfit_cap(me)
			var name := str(msg.get("name", "")).strip_edges().substr(0, 20)
			var eq: Array = wallet(me).eq.duplicate()
			var res := _outfits_res(me)
			res.t = "s_outfit_save_res"
			if eq.is_empty():
				res.why = "Put something on first."
			elif list.size() >= cap:
				res.why = "You can save %d outfits.%s" % [cap, " Plux Pro lets you save more." if not pay.is_pro(me) and cfg.b("f_pro") else ""]
			else:
				list.append({"name": name if name != "" else "Outfit %d" % (list.size() + 1), "eq": eq})
				outfits[me] = list
				_db("insert into plox_outfits (uid, data) values ($1, $2) on conflict (uid) do update set data = excluded.data", [me, JSON.stringify(list)])
				res = _outfits_res(me)
				res.t = "s_outfit_save_res"
				res.ok = true
			reply.call(res)
		"s_outfit_del":
			var list: Array = outfits.get(me, [])
			var i = msg.get("i", -1)
			if (i is int or i is float) and int(i) >= 0 and int(i) < list.size():
				list.remove_at(int(i))
				outfits[me] = list
				_db("insert into plox_outfits (uid, data) values ($1, $2) on conflict (uid) do update set data = excluded.data", [me, JSON.stringify(list)])
			var r2 := _outfits_res(me)
			r2.t = "s_outfit_del_res"
			r2.ok = true
			reply.call(r2)
		"s_pro":
			pay.pro_tick(me, now)
			reply.call(pay.pro_info(me))
		"s_pro_cancel":
			reply.call(pay.pro_cancel(me))
		"s_pro_renew_test":
			# Test mode only: acts like the provider reporting a renewal.
			var ok := cfg.s("pay_mode") == "sandbox" and pay.can_buy(me, "f_pro") == "" and pay.pro_renewed(me, "sandbox_renew_%s_%d" % [me, now], now)
			reply.call({"t": "s_pro_renew_res", "ok": ok, "me": pay.pro_status(me)})
		"s_pay_start":
			reply.call(pay.start(me, msg, now))
		"s_pay_confirm":
			reply.call(pay.confirm(me, msg, now))
		"s_orders":
			reply.call({"t": "s_orders_res", "orders": pay.mine(me)})
		"s_inv":
			var w := str(msg.get("w", ""))
			if w != me and not hub.friends.get(me, {}).has(w):
				reply.call({"t": "s_inv_res", "ok": false, "w": w, "why": "You can only see a friend's items."})
				return ""
			reply.call({"t": "s_inv_res", "ok": true, "w": w, "items": trade.inventory(w), "coins": int(wallet(w).coins) if w == me else -1})
		"s_trades":
			reply.call({"t": "s_trades_res", "trades": trade.list_for(me, now)})
		"s_trade_offer":
			reply.call(trade.offer(me, msg, now))
		"s_trade_accept":
			reply.call(trade.accept(me, str(msg.get("id", "")), now))
		"s_trade_decline":
			reply.call(trade.refuse(me, str(msg.get("id", "")), now, "decline"))
		"s_trade_cancel":
			reply.call(trade.refuse(me, str(msg.get("id", "")), now, "cancel"))
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
	if bool(it.get("pro", false)) and not pay.is_pro(me):
		res.why = "This item is for Plux Pro members."
		return res
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

func _load_agents(saved: Array) -> void:
	agents = []
	var seen := {}
	for a in saved:
		var c := _clean_agent(a)
		if not c.is_empty() and not seen.has(c.id):
			seen[c.id] = true
			agents.append(c)
	for b in BUILTIN_AGENTS:
		if not seen.has(b.id):
			agents.append(_clean_agent(b))   # fills in the default rule choices


func _clean_agent(a) -> Dictionary:
	if not (a is Dictionary):
		return {}
	var id := str(a.get("id", "")).to_lower().strip_edges()
	var ok_id := id.length() >= 2 and id.length() <= 32
	for ch in id:
		if not (ch in "abcdefghijklmnopqrstuvwxyz0123456789_"):
			ok_id = false
	if not ok_id:
		return {}
	var builtin := false
	var status := "custom"
	for b in BUILTIN_AGENTS:
		if b.id == id:
			builtin = true
			status = b.status
	var pd = a.get("per_day", 0)
	return {"opts": AgentRules.clean_opts(a.get("opts", {}), id, builtin), "id": id, "name": str(a.get("name", id)).strip_edges().substr(0, 40), "job": str(a.get("job", "")).strip_edges().substr(0, 200),
		"on": a.get("on", false) is bool and a.on, "model": str(a.get("model", "")).strip_edges().substr(0, 120),
		"rules": str(a.get("rules", "")).substr(0, 4000), "per_day": clampi(int(pd) if (pd is int or pd is float) else 0, 0, 1000),
		"status": status, "builtin": builtin}


func agent(id: String) -> Dictionary:
	if agents.is_empty():
		_load_agents([])
	for a in agents:
		if a.id == id:
			return a
	return {}


func _save_agents() -> void:
	_db("insert into plox_config (k, v) values ('agents', $1) on conflict (k) do update set v = $1", [JSON.stringify(agents)])


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
	if prompt.length() < 4:
		fail.call("Describe your game in a few words first.")
		return
	var ag := agent("game_editor" if msg.get("base") is Dictionary else "studio_builder")
	if not ai_ready() or not bool(ag.get("on", true)):
		# No AI service set up yet (or the agent is switched off): the built-in word
		# builder makes the game instead, so Studio still works, and Studio says so.
		var base0 = PloxLevel.clean(msg.base, cfg.i("studio_max_parts")) if msg.get("base") is Dictionary else null
		var lv := PloxLevel.clean(PloxLevel.quick_build(prompt, base0), cfg.i("studio_max_parts"))
		lv.title = filter_text(lv.title)
		count("ai_quick")
		reply.call({"t": "s_ai_res", "ok": true, "level": lv, "quick": true, "left": -1, "ai_off": true,
			"why": "The AI builder isn't set up yet, so the quick builder made this one."})
		return
	if _ai_busy.has(me):
		fail.call("Your last game is still being built.")
		return
	var used := _ai_used_today(me)
	var ai_cap := ai_cap_for(me)
	if used >= ai_cap:
		fail.call("You've used all %d AI builds for today. More tomorrow!" % ai_cap)
		return
	if int(daily.get(today(now), {}).get("ai", 0)) >= AI_GLOBAL_PER_DAY:
		fail.call("The AI builder is very busy today. Try again tomorrow.")
		return
	_ai_busy[me] = true
	count("ai")
	count("ai:" + me)
	var started := Time.get_ticks_msec()
	# 0.7.0: "make it harder", "add lava": change the game already on screen.
	var change := {}
	if msg.get("base") is Dictionary:
		change = PloxLevel.clean(msg.base, cfg.i("studio_max_parts"))
	_ai_call(prompt, func(ok: bool, level: Dictionary, why: String):
		_ai_busy.erase(me)
		var ms := Time.get_ticks_msec() - started
		var info := str(level.get("_info", ""))
		level.erase("_info")
		_ai_note(me, ("[edit] " if not change.is_empty() else "") + prompt, ok, ms, info if ok else why)
		if ok:
			level.title = filter_text(str(level.title))
			reply.call({"t": "s_ai_res", "ok": true, "level": level, "source": "ai", "ms": ms,
				"why": "Built by the AI in %.0f seconds." % (ms / 1000.0),
				"left": maxi(0, ai_cap_for(me) - _ai_used_today(me))})
		else:
			# The AI failed: hand back a game from the word builder so the player isn't stuck,
			# and say so plainly.
			var lv2 := PloxLevel.clean(PloxLevel.quick_build(prompt, change if not change.is_empty() else null), cfg.i("studio_max_parts"))
			lv2.title = filter_text(lv2.title)
			reply.call({"t": "s_ai_res", "ok": true, "level": lv2, "quick": true, "source": "quick", "ai_error": why.substr(0, 200),
				"why": "The AI couldn't build this one, so the quick builder made a simpler version. (%s)" % _player_ai_reason(why),
				"left": maxi(0, ai_cap_for(me) - _ai_used_today(me))}), false, {"agent": ag}, change)


## A short, player-friendly reason (never the URL or anything private).
static func _player_ai_reason(why: String) -> String:
	if why.contains("seconds"):
		return "the AI took too long"
	if why.contains("HTTP 401") or why.contains("HTTP 403"):
		return "the AI key was refused"
	if why.contains("HTTP 429"):
		return "the AI is busy"
	if why.contains("could not reach") or why.contains("HTTP 5") or why.contains("web page"):
		return "the AI service is offline"
	if why.contains("HTTP 404"):
		return "the AI address is wrong"
	return "its answer couldn't be used"


func _ai_used_today(uid: String) -> int:
	return int(daily.get(today(_now()), {}).get("ai:" + uid, 0))


func _ai_note(uid: String, prompt: String, ok: bool, ms: int, why: String) -> void:
	ai_log.push_front({"ts": _now(), "uid": uid, "prompt": prompt, "ok": ok, "ms": ms, "why": why})
	if ai_log.size() > 300:
		ai_log.pop_back()
	_db("insert into plox_ai_log (ts, uid, prompt, ok, ms, why) values ($1, $2, $3, $4, $5, $6)", [_now(), uid, prompt, ok, ms, why])


## Calls {base}/chat/completions. done(ok, level, why). A test call uses a small prompt.
## 0.7.2: reads every common reply shape (plain, streamed, split into parts, reasoning
## only, fenced, cut off), repairs and closes broken JSON, and tries a second time with a
## stricter note when the first answer can't be used. Every failure says exactly why,
## with a short preview of what came back, so the usage log and Test connection show
## the real problem. On success level["_info"] says how it went (callers remove it).
func _ai_call(prompt: String, done: Callable, test := false, override := {}, change := {}) -> void:
	var base := str(override.get("base", ai_cfg.base)).strip_edges()
	var ag: Dictionary = override.get("agent", {})
	var model := str(override.get("model", ai_cfg.model)).strip_edges()
	if str(ag.get("model", "")).strip_edges() != "" and not override.has("model"):
		model = str(ag.model).strip_edges()
	var key := str(override.get("key", "")) if str(override.get("key", "")) != "" else _ai_key()
	var url := ai_endpoint(base)
	if url == "":
		done.call(false, {}, "base URL must start with https://")
		return
	if model == "":
		done.call(false, {}, "no model name saved")
		return
	var messages := []
	if test:
		messages = [{"role": "user", "content": "Reply with exactly this JSON and nothing else: {\"ok\": true}"}]
	else:
		var sys := PloxLevel.ai_system_prompt(mini(cfg.i("studio_max_parts"), 90))
		var rules_txt := AgentRules.compose(ag) if not ag.is_empty() else ""
		if rules_txt.strip_edges() != "":
			sys += "\n\nRules from the Plux team for you (%s). Follow them, but always reply in the JSON format above:\n%s" % [str(ag.get("name", "")), rules_txt]
		messages = [{"role": "system", "content": sys},
			{"role": "user", "content": "Build this game: " + prompt + "\n\nReply with the level JSON only."}]
		if not change.is_empty() and change.get("parts", []).size() > 0:
			messages[1].content = "Here is my current game as JSON:\n" + JSON.stringify(change) \
				+ "\n\nChange it like this: " + prompt + "\nKeep everything I didn't ask to change. Reply with the whole updated game in the same JSON format, JSON only."
	var st := {"try": 1, "t0": Time.get_ticks_msec()}
	_ai_try(url, model, key, messages, test, ag, done, st)


## The chat/completions address for whatever the admin pasted: the bare host, .../v1,
## .../v1/, or the full .../chat/completions all work.
static func ai_endpoint(base: String) -> String:
	var b := base.strip_edges()
	if not (b.begins_with("https://") or b.begins_with("http://")):
		return ""
	while b.ends_with("/"):
		b = b.trim_suffix("/")
	if b.ends_with("/chat/completions"):
		return b
	if b.ends_with("/completions"):
		b = b.trim_suffix("/completions")
	# Bare host (no path): OpenAI-style routers serve under /v1.
	var after := b.substr(b.find("//") + 2)
	if not after.contains("/"):
		b += "/v1"
	return b + "/chat/completions"


func _ai_try(url: String, model: String, key: String, messages: Array, test: bool, ag: Dictionary, done: Callable, st: Dictionary) -> void:
	var http := HTTPRequest.new()
	http.timeout = float(cfg.i("ai_timeout_s"))
	http.use_threads = true
	http.body_size_limit = 4 * 1024 * 1024
	add_child(http)
	var tokens := 400 if test else cfg.i("ai_max_tokens")
	var body := {"model": model, "messages": messages, "max_tokens": tokens, "temperature": 0.4 if int(st.try) > 1 else 0.7, "stream": false}
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json", "Authorization: Bearer " + key,
		"User-Agent: PluxServer/0.7.2", "ngrok-skip-browser-warning: true",
		"HTTP-Referer: https://github.com/eduzd/blockparty", "X-Title: Plux"])
	var retry := func(why: String, bad_reply: String) -> bool:
		if int(st.try) >= 2 or test:
			return false
		print("[ai] try %d failed (%s), trying again" % [int(st.try), why])
		st.try = 2
		st["first_why"] = why
		var m2: Array = messages.duplicate(true)
		if bad_reply.strip_edges() != "":
			m2.append({"role": "assistant", "content": bad_reply.substr(0, 1200)})
		m2.append({"role": "user", "content": PloxLevel.AI_RETRY_NOTE})
		_ai_try(url, model, key, m2, test, ag, done, st)
		return true
	var fail := func(why: String, bad_reply: String, can_retry: bool):
		if can_retry and retry.call(why, bad_reply):
			return
		var w := why
		if st.has("first_why") and str(st.first_why) != why:
			w = "try 1: %s; try 2: %s" % [str(st.first_why), why]
		elif int(st.try) > 1:
			w = why + " (2 tries)"
		print("[ai] failed after %d ms: %s" % [Time.get_ticks_msec() - int(st.t0), w])
		done.call(false, {}, w.substr(0, 400))
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, raw: PackedByteArray):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS:
			if result == HTTPRequest.RESULT_TIMEOUT:
				fail.call("no answer within %d seconds" % cfg.i("ai_timeout_s"), "", false)
			elif result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
				fail.call("the answer was too big", "", true)
			else:
				fail.call("could not reach %s (network error %d)" % [url.get_slice("/", 2), result], "", false)
			return
		var text := raw.get_string_from_utf8()
		if code < 200 or code >= 300:
			var emsg := PloxAi.preview(text, 200)
			var pj = PloxAi.parse(text)
			if pj is Dictionary and pj.get("error") is Dictionary:
				emsg = str(pj.error.get("message", emsg)).substr(0, 200)
			elif pj is Dictionary and pj.get("error") is String:
				emsg = str(pj.error).substr(0, 200)
			elif pj is Dictionary and pj.get("message") is String:
				emsg = str(pj.message).substr(0, 200)
			if text.contains("<html") or text.contains("<!DOCTYPE"):
				emsg = "the address answered with a web page, not the AI (" + PloxAi.preview(text, 80) + ")"
			if code == 404:
				emsg += ". Check the base URL ends in /v1 (Plux adds /chat/completions)"
			fail.call("HTTP %d: %s" % [code, emsg], "", code == 429 or code >= 500)
			return
		var r := PloxAi.reply_text(text)
		var content: String = r.text
		if content.strip_edges() == "" and str(r.reasoning).strip_edges() != "":
			content = r.reasoning   # some routers put the whole answer in the reasoning field
		if content.strip_edges() == "":
			var detail := "shape %s, finish %s" % [r.shape, r.finish if r.finish != "" else "none"]
			if r.shape == "not JSON":
				detail = "not an AI reply: " + PloxAi.preview(text, 120)
			elif r.finish == "length":
				detail += ": it ran out of tokens before writing anything (raise the token limit or use a non-thinking model)"
			fail.call("empty answer (%s)" % detail, "", true)
			return
		if test:
			var to = PloxAi.find_level(content)
			print("[ai] test ok in %d ms" % (Time.get_ticks_msec() - int(st.t0)))
			done.call(true, {"_info": "model replied: " + PloxAi.preview(content, 60) + ("" if to is Dictionary else " (not JSON)")}, "")
			return
		var obj = PloxAi.find_level(content)
		if not (obj is Dictionary):
			fail.call("answer was not level JSON (finish %s): %s" % [r.finish if r.finish != "" else "none", PloxAi.preview(content, 140)], content, true)
			return
		var raw_n := 0
		var src = obj.get("parts", obj.get("objects", []))
		if src is Array:
			raw_n = src.size()
		var level := PloxLevel.clean(obj, cfg.i("studio_max_parts"))
		if not ag.is_empty():
			level = AgentRules.enforce_level(level, ag)
		if level.parts.size() < 3:
			fail.call("too few usable parts (%d of %d): %s" % [level.parts.size(), raw_n, PloxAi.preview(content, 100)], content, true)
			return
		var info := "AI, %d parts%s%s" % [level.parts.size(), ", 2nd try" if int(st.try) > 1 else "", ", cut off and closed" if r.finish == "length" else ""]
		print("[ai] ok in %d ms: %s, '%s'" % [Time.get_ticks_msec() - int(st.t0), info, str(level.title)])
		level["_info"] = info
		done.call(true, level, ""))
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		fail.call("request failed to start (%d)" % err, "", false)


# ------------------------------------------------------------------ admin

func is_admin_type(t: String) -> bool:
	return t.begins_with("a_")


func admin_drop(cid: int) -> void:
	admin_cids.erase(cid)


var _cur_who := "admin"

func _audit(action: String, detail: String) -> void:
	_audit_as(_cur_who, action, detail)


func _audit_as(who: String, action: String, detail: String) -> void:
	var e := {"id": 0, "ts": _now(), "who": who, "action": action, "detail": detail.substr(0, 500)}
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
		"banned": ban_reason(uid) != "", "ban": bans.get(uid, {}), "created": int(u.get("created", 0)),
		"age": SocialHub.age_from(str(u.get("birthday", ""))), "email": str(u.get("email", ""))}


## Admin messages. Returns "" or an error code for the referee.
func admin_handle(cid: int, msg: Dictionary, send: Callable) -> String:
	var t := str(msg.t)
	var rid = msg.get("rid", 0)
	var reply := func(d: Dictionary):
		d["rid"] = rid
		send.call(d)
	var now := _now()
	if t == "a_login":
		if admin_pw_hash == "" and admin_test_hash == "":
			reply.call({"t": "a_login_res", "ok": false, "why": "The admin password isn't set on the server (ADMIN_PASSWORD)."})
			return ""
		if int(_admin_fails[0]) >= ADMIN_LOCK_FAILS and now - int(_admin_fails[1]) < ADMIN_LOCK_S:
			reply.call({"t": "a_login_res", "ok": false, "why": "Too many wrong passwords. Try again in 10 minutes."})
			return ""
		var pw = msg.get("pw")
		var is_owner: bool = pw is String and pw.length() <= 128 and admin_pw_hash != "" and SocialHub.check_pw(pw, admin_pw_hash)
		var is_test: bool = not is_owner and pw is String and pw.length() <= 128 and admin_test_hash != "" and SocialHub.check_pw(pw, admin_test_hash)
		if is_owner or is_test:
			_admin_fails = [0, 0]
			admin_cids[cid] = "admin" if is_owner else "checks"
			_audit_as("admin" if is_owner else "checks", "login", "admin signed in" if is_owner else "automated checks signed in")
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
	_cur_who = str(admin_cids[cid]) if admin_cids[cid] is String else "admin"
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
			if str(msg.get("sort", "")) == "new":
				rows.sort_custom(func(a, b): return int(a.created) > int(b.created))
			else:
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
			# With "password": sets a temporary password the admin passes on to the player.
			# Without: clears the password. Either way every phone is signed out.
			var tmp = msg.get("password", "")
			if tmp is String and tmp != "":
				if tmp.length() < SocialHub.MIN_PW or tmp.length() > SocialHub.MAX_PW:
					reply.call({"t": "a_ok", "ok": false, "why": "Use %d to %d characters." % [SocialHub.MIN_PW, SocialHub.MAX_PW]})
					return ""
				hub.users[uid].pw = SocialHub.hash_pw(tmp)
				hub._save_user(uid)
			else:
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
				var info := str(level.get("_info", ""))
				_ai_note("admin", "(test)" if not full else "(test build)", ok, ms, info if ok else why)
				reply.call({"t": "a_ai_test_res", "ok": ok, "why": why, "info": info, "ms": ms, "parts": level.get("parts", []).size(), "title": level.get("title", ""),
					"endpoint": ai_endpoint(ai_cfg.base), "model": ai_cfg.model}), not full)
		"a_pro_set":
			var uid := str(msg.get("uid", ""))
			var days = msg.get("days", 0)
			if not hub.users.has(uid) or not (days is int or days is float):
				reply.call({"t": "a_ok", "ok": false, "why": "No such player."})
				return ""
			if int(days) <= 0:
				pay.remove_pro(uid)
				_audit("pro_remove", str(hub.users[uid].get("username", uid)))
			else:
				var tier := str(msg.get("tier", ""))
				var all := pay.tiers()
				if all.is_empty():
					reply.call({"t": "a_ok", "ok": false, "why": "Add a Pro tier first."})
					return ""
				if not all.any(func(t): return t.id == tier):
					tier = all[0].id
				pay.grant_pro(uid, tier, clampi(int(days), 1, 3650), "admin", now)
				_audit("pro_grant", "%s: %s for %d days" % [str(hub.users[uid].get("username", uid)), tier, int(days)])
			reply.call({"t": "a_ok", "ok": true, "pro": pay.pro_status(uid)})
		"a_orders":
			var r := pay.admin_list()
			r["t"] = "a_orders_res"
			reply.call(r)
		"a_trades":
			reply.call({"t": "a_trades_res", "trades": trade.admin_list(str(msg.get("q", "")).strip_edges().to_lower().substr(0, 40))})
		"a_user":
			var uid := str(msg.get("uid", ""))
			if not hub.users.has(uid):
				reply.call({"t": "a_user_res", "ok": false, "why": "No such player."})
				return ""
			var inv := []
			for oid in owned.get(uid, {}):
				var o: Dictionary = owned[uid][oid]
				var it: Dictionary = items.get(o.item, {})
				inv.append({"oid": oid, "item": o.item, "name": str(it.get("name", o.item)), "serial": int(o.serial), "rare": bool(it.get("rare", false))})
			var mine := []
			for g in games.values():
				if g.owner == uid:
					mine.append({"gid": g.gid, "title": g.title, "status": g.status, "plays": int(g.plays)})
			var ai_n := 0
			for e in ai_log:
				if e.uid == uid and int(e.ts) > now - 86400:
					ai_n += 1
			var u: Dictionary = hub.users[uid]
			reply.call({"t": "a_user_res", "ok": true, "user": _user_row(uid), "items": inv, "games": mine,
				"pro": pay.pro_status(uid), "ai_today": ai_n, "bio": str(u.get("bio", "")),
				"follows": hub.follows.get(uid, {}).size()})
		"a_item_delete":
			var id := str(msg.get("id", ""))
			if not items.has(id):
				reply.call({"t": "a_ok", "ok": false, "why": "No such item."})
				return ""
			if int(sold.get(id, 0)) > 0:
				reply.call({"t": "a_ok", "ok": false, "why": "Players already own this item, so it can only be hidden."})
				return ""
			items.erase(id)
			item_order.erase(id)
			_db("delete from plox_items where id = $1", [id])
			_audit("item deleted", id)
			reply.call({"t": "a_ok", "ok": true})
		"a_agents":
			if agents.is_empty():
				_load_agents([])
			reply.call({"t": "a_agents_res", "agents": agents, "shared_model": ai_cfg.model, "ready": ai_ready(), "schema": AgentRules.SCHEMA})
		"a_agent_preview":
			var c := _clean_agent(msg.get("agent"))
			reply.call({"t": "a_agent_preview_res", "text": AgentRules.compose(c) if not c.is_empty() else ""})
		"a_agent_save":
			var c := _clean_agent(msg.get("agent"))
			if c.is_empty() or c.name == "":
				reply.call({"t": "a_ok", "ok": false, "why": "Give the agent a name and an id (letters, numbers, _)."})
				return ""
			if agents.is_empty():
				_load_agents([])
			var found := false
			for i in agents.size():
				if agents[i].id == c.id:
					agents[i] = c
					found = true
			if not found:
				if agents.size() >= 40:
					reply.call({"t": "a_ok", "ok": false, "why": "That's the most agents for now (40)."})
					return ""
				agents.append(c)
			_save_agents()
			_audit("agent saved", "%s (%s)%s" % [c.name, "on" if c.on else "off", ", new" if not found else ""])
			reply.call({"t": "a_ok", "ok": true, "agent": c})
		"a_agent_delete":
			var id := str(msg.get("id", ""))
			var a := agent(id)
			if a.is_empty():
				reply.call({"t": "a_ok", "ok": false, "why": "No such agent."})
				return ""
			if bool(a.get("builtin", false)):
				reply.call({"t": "a_ok", "ok": false, "why": "Built-in agents can be switched off but not deleted."})
				return ""
			agents.erase(a)
			_save_agents()
			_audit("agent deleted", str(a.name))
			reply.call({"t": "a_ok", "ok": true})
		"a_agent_test":
			var a := agent(str(msg.get("id", "")))
			if a.is_empty():
				reply.call({"t": "a_ai_test_res", "ok": false, "why": "No such agent.", "ms": 0, "parts": 0, "title": ""})
				return ""
			var t0 := Time.get_ticks_msec()
			var tp := str(msg.get("prompt", "")).strip_edges().substr(0, 200)
			if tp == "":
				tp = "a short obstacle course with a jump pad"
			_ai_call(tp, func(ok: bool, level: Dictionary, why: String):
				var ms := Time.get_ticks_msec() - t0
				var info := str(level.get("_info", ""))
				_ai_note("admin", "(test %s) %s" % [a.name, tp], ok, ms, info if ok else why)
				reply.call({"t": "a_ai_test_res", "ok": ok, "why": why, "info": info, "ms": ms, "parts": level.get("parts", []).size(), "title": level.get("title", "")}), false, {"agent": a})
		"a_cfg":
			reply.call({"t": "a_cfg_res", "cfg": cfg.values, "defaults": LiveConfig.DEFAULTS})
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
