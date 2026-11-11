class_name LiveConfig
extends RefCounted
## Settings the server owns and the admin app edits live (0.6.0). The phone gets
## them in the welcome and again whenever an admin changes something, so none
## of these need a new app build. Values sent by an admin are only accepted when
## they have the same type as the default here, and numbers are clamped.

const DEFAULTS := {
	# Feature switches
	"f_games": true, "f_pop": true, "f_neon": true, "f_studio": true, "f_ai": true,
	"f_shop": true, "f_trading": false, "f_voice": true, "f_chat": true,
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


## What phones get. The banned-word list stays on the server.
func public() -> Dictionary:
	var out := values.duplicate()
	out.erase("banned_words")
	return out
