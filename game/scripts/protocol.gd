class_name Protocol
extends RefCounted
## Shared rules for the client and the referee server.
## The server only trusts what passes these checks.

const VERSION := 1
const DEFAULT_PORT := 8910
const DEFAULT_ROOM := "PLAY"

const MAX_PLAYERS_PER_ROOM := 8
const MAX_ROOMS := 50
const MAX_CONNECTIONS := 200
const MAX_MESSAGE_BYTES := 1024
const MAX_SIGNAL_BYTES := 8192       # voice offers/answers (SDP) are a few KB
const MAX_SIGNALS_PER_SEC := 80      # ICE candidates arrive in bursts
const MAX_SDP_CHARS := 7000
const MAX_ICE_CHARS := 600
const MAX_MSGS_PER_SEC := 40
const MAX_BAD_MESSAGES := 20
const HELLO_TIMEOUT_MS := 5000
const IDLE_TIMEOUT_MS := 15000
const SNAPSHOT_HZ := 20
const SEND_HZ := 20

const MOVE_SPEED := 7.0
const JUMP_VELOCITY := 9.0
const GRAVITY := 24.0
const WORLD_HALF := 39.0
const MIN_Y := -10.0
const MAX_Y := 16.0                 # feet can't go above the ceiling (16 when hanging upside down)
const SPAWN := Vector3(0.0, 1.5, 6.0)

## Trampoline floor: touching the ground (y = 0) launches you into the ceiling.
## The spawn pad and the coloured blocks are solid and safe to stand on.
const CEILING_Y := 16.0
const TRAMPOLINE_VELOCITY := 30.0
const TRAMPOLINE_UP_BUDGET := 17.0
const TRAMPOLINE_ZONE_Y := 2.0

## Wind gusts (sent by the referee, applied by phones only while airborne).
const WIND_MAX := 6.0

## Magnetic balls knock players around when they catch them.
const BUMP_SPEED := 10.0
const BUMP_UP := 8.0
const BUMP_BUDGET := 6.0

## Gravity flip: on every beat drop of the music (BeatClock, every 32 s),
## together with the origami fold. Grace covers the flip and the fold.
const FLIP_GRACE_MS := 2200

## Movement budget the referee allows (metres). Refills over time,
## so lag bursts are fine but speed hacks and teleports are not.
const H_BUDGET_RATE := MOVE_SPEED * 1.35
const H_BUDGET_MAX := 3.0
const UP_BUDGET_RATE := JUMP_VELOCITY * 1.2
const UP_BUDGET_MAX := 3.0

const COLORS := [
	Color("#ff5a5f"), Color("#2b6cff"), Color("#ffd23f"), Color("#3ddc97"),
	Color("#a259ff"), Color("#ff8c42"), Color("#00c2d1"), Color("#f15bb5"),
]


static func color_for(index: int) -> Color:
	return COLORS[posmod(index, COLORS.size())]


static func sanitize_name(value) -> String:
	var raw := str(value) if value is String else ""
	var out := ""
	for ch in raw.strip_edges():
		var code := ch.unicode_at(0)
		if code >= 32 and code != 127 and ch != "<" and ch != ">":
			out += ch
		if out.length() >= 16:
			break
	out = out.strip_edges()
	return out if out != "" else "Player"


static func sanitize_room(value) -> String:
	var raw := (str(value) if value is String else "").to_upper()
	var out := ""
	for ch in raw:
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
		if out.length() >= 6:
			break
	return out if out != "" else DEFAULT_ROOM


## Returns a Vector3 from [x, y, z] or null when anything is off.
static func parse_vec3(value):
	if not (value is Array) or value.size() != 3:
		return null
	for n in value:
		if not (n is float or n is int):
			return null
		if not is_finite(float(n)):
			return null
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


static func parse_number(value):
	if not (value is float or value is int):
		return null
	var f := float(value)
	return f if is_finite(f) else null


static func vec_to_array(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]


static func encode(data: Dictionary) -> String:
	return JSON.stringify(data)


## Returns a Dictionary with a String "t" field, or null.
static func decode(text: String, max_bytes: int = MAX_MESSAGE_BYTES):
	if text.length() > max_bytes:
		return null
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return null
	if not parsed.has("t") or not (parsed["t"] is String):
		return null
	return parsed
