class_name PloxLevel
extends RefCounted
## The one format for Studio games (0.6.0): what the editor saves, what the
## server stores and checks, what the AI must answer with, and what the player
## loads. clean() rebuilds a level from anything, keeping only valid parts and
## clamping every number, so a broken save or a bad AI answer can never crash
## the app. Parts are compact arrays to keep messages small:
##   [kind, x, y, z, sx, sy, sz, rot_y_degrees, colour_index]

const VERSION := 1
const KINDS := ["block", "lava", "bounce", "spinner", "mover", "coin", "ice", "checkpoint"]
const KIND_NAMES := {"block": "Block", "lava": "Lava", "bounce": "Jump pad", "spinner": "Hammer",
	"mover": "Mover", "coin": "Star", "ice": "Ice", "checkpoint": "Checkpoint"}
const SKIES := ["Day", "Sunset", "Night", "Candy", "Storm"]
## Sky & Ink friendly colours.
const COLORS := ["#1E88E5", "#64B5F6", "#FFFFFF", "#37474F", "#FF7043", "#FFCA28",
	"#66BB6A", "#AB47BC", "#EC407A", "#26C6DA"]
const HALF := 60.0          # x and z go from -60 to 60
const TOP := 60.0
const MIN_SIZE := 0.5
const MAX_SIZE := 24.0
const MAX_TITLE := 40
const MAX_PARTS_HARD := 400


static func default_size(kind: String) -> Vector3:
	match kind:
		"lava": return Vector3(4, 0.5, 4)
		"bounce": return Vector3(2, 0.4, 2)
		"spinner": return Vector3(8, 0.8, 0.8)
		"mover": return Vector3(3, 0.6, 3)
		"coin": return Vector3(1, 1, 1)
		"checkpoint": return Vector3(2, 0.3, 2)
	return Vector3(4, 1, 4)


static func default_color(kind: String) -> int:
	match kind:
		"lava": return 4
		"bounce": return 8
		"spinner": return 3
		"mover": return 7
		"coin": return 5
		"ice": return 9
		"checkpoint": return 6
	return 0


static func blank(title := "My game") -> Dictionary:
	return {"v": VERSION, "title": title, "sky": 0,
		"spawn": [0.0, 1.0, 0.0], "goal": [0.0, 1.0, -20.0],
		"parts": [["block", 0.0, -0.5, 0.0, 12.0, 1.0, 12.0, 0.0, 6], ["block", 0.0, -0.5, -20.0, 8.0, 1.0, 8.0, 0.0, 0],
			["block", 0.0, -0.5, -10.0, 3.0, 1.0, 8.0, 0.0, 1]]}


static func _num(v, lo: float, hi: float, fallback: float) -> float:
	if v is String and v.is_valid_float():
		v = v.to_float()
	if not (v is float or v is int):
		return fallback
	var f := float(v)
	if is_nan(f) or is_inf(f):
		return fallback
	return snappedf(clampf(f, lo, hi), 0.01)


static func _vec(v, fallback: Array) -> Array:
	if v is Dictionary:
		v = [v.get("x"), v.get("y"), v.get("z")]
	if not (v is Array) or v.size() < 3:
		return fallback
	return [_num(v[0], -HALF, HALF, fallback[0]), _num(v[1], -5.0, TOP, fallback[1]), _num(v[2], -HALF, HALF, fallback[2])]


## One part from an array or from an AI-style object {"kind","pos","size",...}.
static func clean_part(p):
	var kind := ""
	var pos := []
	var size := []
	var rot = 0
	var col = null
	if p is Array and p.size() >= 4:
		kind = str(p[0]).to_lower()
		pos = [p[1], p[2], p[3]]
		if p.size() >= 7:
			size = [p[4], p[5], p[6]]
		if p.size() >= 8:
			rot = p[7]
		if p.size() >= 9:
			col = p[8]
	elif p is Dictionary:
		kind = str(p.get("kind", p.get("type", ""))).to_lower()
		var pp = p.get("pos", p.get("position", [p.get("x"), p.get("y"), p.get("z")]))
		pos = pp if pp is Array else ([pp.get("x"), pp.get("y"), pp.get("z")] if pp is Dictionary else [])
		var ss = p.get("size", null)
		size = ss if ss is Array else ([ss.get("x"), ss.get("y"), ss.get("z")] if ss is Dictionary else [])
		rot = p.get("rot", p.get("rotation", 0))
		col = p.get("color", p.get("colour", null))
	else:
		return null
	match kind:
		"platform", "floor", "wall", "box", "cube": kind = "block"
		"jump", "jumppad", "jump_pad", "trampoline", "pad": kind = "bounce"
		"hammer", "spin", "rotator", "sweeper": kind = "spinner"
		"moving", "moving_platform", "elevator": kind = "mover"
		"star", "collectible": kind = "coin"
		"kill", "hazard", "acid": kind = "lava"
	if not KINDS.has(kind) or pos.size() < 3:
		return null
	var ds := default_size(kind)
	var v := _vec(pos, [0.0, 0.0, 0.0])
	var s := [ds.x, ds.y, ds.z]
	if size.size() >= 3:
		s = [_num(size[0], MIN_SIZE, MAX_SIZE, ds.x), _num(size[1], 0.2, MAX_SIZE, ds.y), _num(size[2], MIN_SIZE, MAX_SIZE, ds.z)]
	var ci := default_color(kind)
	if col is float or col is int:
		ci = clampi(int(col), 0, COLORS.size() - 1)
	elif col is String:
		var idx := COLORS.find(col.to_upper())
		if idx >= 0:
			ci = idx
	return [kind, v[0], v[1], v[2], s[0], s[1], s[2], _num(rot, -360.0, 360.0, 0.0), ci]


## Rebuilds a level from anything. Always returns a playable level.
static func clean(d, max_parts := 160) -> Dictionary:
	var out := blank()
	if not (d is Dictionary):
		return out
	var t = d.get("title", d.get("name", "My game"))
	out.title = clean_title(t)
	out.sky = clampi(int(_num(d.get("sky", 0), 0, SKIES.size() - 1, 0)), 0, SKIES.size() - 1)
	var parts := []
	var src = d.get("parts", d.get("objects", []))
	if src is Array:
		for p in src:
			if parts.size() >= mini(max_parts, MAX_PARTS_HARD):
				break
			var c = clean_part(p)
			if c != null:
				parts.append(c)
	if parts.is_empty():
		return out
	out.parts = parts
	out.spawn = _vec(d.get("spawn"), [parts[0][1], parts[0][2] + parts[0][5] / 2.0 + 1.0, parts[0][3]])
	var last: Array = parts[parts.size() - 1]
	out.goal = _vec(d.get("goal"), [last[1], last[2] + last[5] / 2.0 + 1.0, last[3]])
	return out


static func clean_title(t) -> String:
	var s := str(t if t != null else "").strip_edges().replace("\n", " ")
	if s.length() > MAX_TITLE:
		s = s.substr(0, MAX_TITLE)
	return s if s != "" else "My game"


## Is there something to stand on under the spawn? Used by the publish check.
static func check(d: Dictionary) -> String:
	var sp: Array = d.spawn
	var ok_spawn := false
	var ok_goal := false
	for p in d.parts:
		if p[0] in ["lava", "coin", "spinner"]:
			continue
		var top: float = p[2] + p[5] / 2.0
		var r: float = maxf(p[4], p[6]) / 2.0 + 0.5
		if absf(sp[0] - p[1]) <= r and absf(sp[2] - p[3]) <= r and sp[1] >= top - 0.5 and sp[1] - top < 6.0:
			ok_spawn = true
		var g: Array = d.goal
		if absf(g[0] - p[1]) <= r and absf(g[2] - p[3]) <= r and g[1] >= top - 0.5 and g[1] - top < 6.0:
			ok_goal = true
	if not ok_spawn:
		return "Put a block under the start point."
	if not ok_goal:
		return "Put a block under the finish flag."
	return ""


## The instructions the server gives the AI. It must answer with JSON only.
static func ai_system_prompt(max_parts: int) -> String:
	return ("You design levels for Plux, a mobile 3D obstacle-course game. Reply with ONE JSON object only, no prose, no code fences. "
		+ "Schema: {\"title\": string (max 40 chars), \"sky\": 0-4 (0 day,1 sunset,2 night,3 candy,4 storm), "
		+ "\"spawn\": [x,y,z], \"goal\": [x,y,z], \"parts\": [[kind, x, y, z, sx, sy, sz, rotYdegrees, color], ...]}. "
		+ "kind is one of: block (solid platform), lava (touch = back to checkpoint), bounce (jump pad, launches up), "
		+ "spinner (a bar that rotates around its centre and knocks players), mover (platform sliding back and forth along its rotation direction), "
		+ "coin (star to collect, size 1), ice (slippery platform), checkpoint (respawn pad). "
		+ "Units are metres, y is up, x and z between -60 and 60, y between 0 and 50, sizes 0.5 to 24. color is 0-9: "
		+ "0 blue,1 light blue,2 white,3 slate,4 orange,5 yellow,6 green,7 purple,8 pink,9 cyan. "
		+ "Positions are the CENTRE of each part. The player jumps about 2.2 m high and 5 m far, so gaps between platforms must be under 4.5 m and steps up under 2 m (or use a bounce pad). "
		+ "Spawn must be 1 m above the top of the first platform; goal 1 m above the top of the last platform. "
		+ "Use at most %d parts. Make it fun, fair and beatable in 1 to 3 minutes, with a clear path from spawn to goal." % max_parts)
