class_name LiveConfig
extends RefCounted
## Settings the server owns and the admin app edits live (0.6.0). The phone gets
## them in the welcome and again whenever an admin changes something, so none
## of these need a new app build. Values sent by an admin are only accepted when
## they have the same type as the default here, and numbers are clamped.

const DEFAULTS := {
	# Feature switches
	"f_games": true, "f_pop": true, "f_neon": true, "f_studio": true, "f_ai": true,
	"f_shop": true, "f_trading": true, "f_invites": true, "f_voice": true, "f_chat": true,
	# Maintenance and updates
	"maintenance": false,
	"maintenance_msg": "Plux is getting an upgrade. Back soon!",
	"min_version": 0,            # app version code; older apps are asked to update
	"update_url": "",
	"update_msg": "A new version of Plux is out. Please update to keep playing.",
	# Announcement shown on Home (empty = none)
	"announce": "",
	"announce_id": 0,
	# Game settings
	"pop_round_s": 120, "pop_max_bots": 7, "room_size": 8,
	# Economy
	"coins_daily": 50, "coins_round": 5, "coins_win": 25, "coins_publish": 20,
	"coins_play_mine": 2, "round_rewards_per_day": 40, "start_coins": 100,
	# 0.7.0: every game pays. Neon Bounce pays per stay of neon_reward_s seconds (up to 5
	# stays a visit); a Studio game pays when you reach its goal.
	"coins_neon": 5, "neon_reward_s": 60, "coins_studio_goal": 5, "coins_studio_first": 10,
	# 0.7.0: buying Plux. Off until a payment provider is set up. In "sandbox" mode only the
	# usernames in pay_testers can buy, nothing is charged, and orders are marked as tests.
	"download_url": "",   # shared in invite messages: where people get the app
	"f_buy_plux": false, "pay_mode": "sandbox", "pay_provider": "none", "pay_testers": "",
	"plux_packs": "[{\"id\":\"p80\",\"plux\":80,\"price\":0.99,\"cur\":\"USD\"},{\"id\":\"p400\",\"plux\":400,\"bonus\":40,\"price\":4.99,\"cur\":\"USD\"},{\"id\":\"p800\",\"plux\":800,\"bonus\":100,\"price\":9.99,\"cur\":\"USD\",\"tag\":\"Popular\"},{\"id\":\"p1700\",\"plux\":1700,\"bonus\":300,\"price\":19.99,\"cur\":\"USD\",\"tag\":\"Best value\"}]",
	# Studio and AI (the key itself is never here: see AdminHub)
	"ai_per_day": 5, "ai_max_tokens": 1800, "ai_timeout_s": 45,
	"studio_max_parts": 160, "studio_max_games_per_player": 10,
	# Home and Games tab
	"home_featured": "",          # game id shown as a hero card on Home
	"home_order": "announce,daily,featured,play,community,friends",
	"games_order": "pop,community,studio,neon",
	"banned_words": "",
}

## Limits for numbers [min, max].
const RANGES := {
	"min_version": [0, 100000], "pop_round_s": [30, 600], "pop_max_bots": [0, 7], "room_size": [2, 16],
	"coins_daily": [0, 100000], "coins_round": [0, 10000], "coins_win": [0, 100000], "coins_publish": [0, 100000],
	"coins_play_mine": [0, 1000], "round_rewards_per_day": [0, 1000], "start_coins": [0, 100000],
	"coins_neon": [0, 10000], "neon_reward_s": [15, 3600], "coins_studio_goal": [0, 10000], "coins_studio_first": [0, 10000],
	"ai_per_day": [0, 100], "ai_max_tokens": [300, 6000], "ai_timeout_s": [10, 120],
	"studio_max_parts": [20, 400], "studio_max_games_per_player": [1, 100], "announce_id": [0, 1000000000],
}

var values := DEFAULTS.duplicate(true)


func get_v(k: String):
	return values.get(k, DEFAULTS.get(k))


func i(k: String) -> int:
	return int(get_v(k))


func b(k: String) -> bool:
	return bool(get_v(k))


func s(k: String) -> String:
	return str(get_v(k))


## Checks one value. Returns [ok, cleaned value].
static func clean(k: String, v) -> Array:
	if not DEFAULTS.has(k):
		return [false, null]
	var d = DEFAULTS[k]
	if d is bool:
		if v is bool:
			return [true, v]
		return [false, null]
	if d is int:
		if not (v is int or v is float) or is_nan(float(v)) or is_inf(float(v)):
			return [false, null]
		var r: Array = RANGES.get(k, [-1000000000, 1000000000])
		return [true, clampi(int(v), int(r[0]), int(r[1]))]
	if d is String:
		if not (v is String):
			return [false, null]
		if k == "pay_mode":
			return [v in ["sandbox", "live"], v]
		if k == "pay_provider":
			return [v in ["none", "play", "razorpay", "stripe"], v]
		if k == "plux_packs":
			var packs := clean_packs(v)
			return [not packs.is_empty() or v == "[]", JSON.stringify(packs)]
		return [true, (v as String).substr(0, 2000)]
	return [false, null]


## Applies a stored or admin-sent dictionary. Returns the keys that changed.
func apply(d: Dictionary) -> Array:
	var changed := []
	for k in d:
		var r := clean(str(k), d[k])
		if r[0] and values.get(k) != r[1]:
			values[k] = r[1]
			changed.append(k)
	return changed


## What phones get. The banned-word list and tester list stay on the server.
func public() -> Dictionary:
	var out := values.duplicate()
	out.erase("banned_words")
	out.erase("pay_testers")
	return out


## Plux packs: [{id, plux, bonus, price, cur, tag}]. Bad entries are dropped.
static func clean_packs(v) -> Array:
	var data = JSON.parse_string(v) if v is String else v
	var out := []
	var seen := {}
	if not (data is Array):
		return out
	for p in data:
		if not (p is Dictionary) or out.size() >= 8:
			continue
		var id := SocialHub.clean_username(str(p.get("id", "")))
		var plux = p.get("plux", 0)
		var price = p.get("price", 0)
		if id == "" or seen.has(id) or not (plux is int or plux is float) or not (price is int or price is float):
			continue
		if int(plux) < 1 or int(plux) > 1000000 or float(price) <= 0.0 or float(price) > 1000.0:
			continue
		var bonus = p.get("bonus", 0)
		var cur := str(p.get("cur", "USD")).to_upper().substr(0, 3)
		seen[id] = true
		out.append({"id": id, "plux": int(plux), "bonus": clampi(int(bonus) if (bonus is int or bonus is float) else 0, 0, 1000000),
			"price": snappedf(float(price), 0.01), "cur": cur if cur.length() == 3 else "USD", "tag": str(p.get("tag", "")).substr(0, 20)})
	return out
