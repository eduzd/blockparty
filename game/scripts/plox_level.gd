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
	return ("You are the level builder for Plux, a mobile 3D obstacle-course (obby) game. "
		+ "Your whole reply must be ONE JSON object: start with { and end with }. No prose, no markdown, no code fences, no explanation, no code in any language.\n"
		+ "Players often paste big ideas: a Roblox game, a horror or racing game, Luau scripts, menus, monsters, shops. You cannot write code or add new systems. "
		+ "Instead, turn the idea into the closest obstacle course you can build from the parts below, and make its theme obvious: "
		+ "pick the matching sky and colours, name it after their idea, and shape the course to tell their story "
		+ "(a horror idea: night or storm sky, dark slate and purple platforms, lava pits as the danger, a chase-like run with hammers; "
		+ "an ice idea: ice platforms and light blue; a space idea: night sky, jump pads between floating islands; a race: a long fast path with movers).\n"
		+ "Schema: {\"title\": string (max 40 chars), \"sky\": 0-4 (0 day, 1 sunset, 2 night, 3 candy, 4 storm), "
		+ "\"spawn\": [x,y,z], \"goal\": [x,y,z], \"parts\": [[kind, x, y, z, sx, sy, sz, rotYdegrees, color], ...]}\n"
		+ "kind is one of: block (solid platform), lava (touch = back to checkpoint), bounce (jump pad, launches up), "
		+ "spinner (a bar that rotates around its centre and knocks players), mover (platform sliding back and forth along its rotation direction), "
		+ "coin (star to collect, size 1), ice (slippery platform), checkpoint (respawn pad). "
		+ "Use several different kinds, and every kind the player asks for.\n"
		+ "Units are metres, y is up, x and z between -60 and 60, y between 0 and 50, sizes 0.5 to 24. color is 0-9: "
		+ "0 blue, 1 light blue, 2 white, 3 slate, 4 orange, 5 yellow, 6 green, 7 purple, 8 pink, 9 cyan. "
		+ "Positions are the CENTRE of each part. The player jumps about 2.2 m high and 5 m far, so gaps between platforms must be under 4.5 m and steps up under 2 m (or use a bounce pad). "
		+ "Spawn must be 1 m above the top of the first platform; goal 1 m above the top of the last platform. "
		+ "Use between 12 and %d parts. Make it fun, fair and beatable in 1 to 3 minutes, with a clear path from spawn to goal.\n"
		+ "Example of the format (a tiny course; yours should be bigger and match the player's idea): "
		+ "{\"title\": \"Lava Hop\", \"sky\": 1, \"spawn\": [0, 2, 0], \"goal\": [0, 4, -24], \"parts\": ["
		+ "[\"block\", 0, 0.5, 0, 6, 1, 6, 0, 6], [\"lava\", 0, 0.2, -6, 6, 0.4, 4, 0, 4], [\"block\", 0, 0.5, -10, 4, 1, 4, 0, 0], "
		+ "[\"bounce\", 0, 1.2, -14, 2, 0.4, 2, 0, 8], [\"coin\", 0, 3, -14, 1, 1, 1, 0, 5], [\"spinner\", 0, 3.6, -20, 8, 0.8, 0.8, 0, 3], "
		+ "[\"block\", 0, 2.5, -20, 5, 1, 5, 0, 1], [\"block\", 0, 2.5, -24, 6, 1, 6, 0, 2]]}") % max_parts


## Sent when the first reply wasn't usable, so the second try is stricter.
const AI_RETRY_NOTE := "Your last reply could not be used because it was not a single valid JSON object in the level format. Reply again with ONLY the JSON object: start with { and end with }, no other text, no code fences, no code. Keep it under 50 parts so it fits."


# ------------------------------------------------------------------ quick builder
## Builds or changes a level from plain words, with no AI. The server uses it when no AI
## service is set up (or the AI fails), so Studio always works. Always returns a level that
## passes check(): a path of platforms from the start to the flag.
static func _has(words: String, keys: Array) -> bool:
	for k in keys:
		if words.contains(k):
			return true
	return false


static func quick_build(prompt: String, base = null, seed_val := -1) -> Dictionary:
	var w := " " + prompt.to_lower() + " "
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val if seed_val >= 0 else hash(prompt + str(Time.get_ticks_usec()))
	var lvl: Dictionary
	if base is Dictionary and not (base as Dictionary).is_empty() and (base as Dictionary).has("parts"):
		lvl = clean(base, MAX_PARTS_HARD)
		_quick_change(lvl, w, rng)
	else:
		lvl = _quick_new(w, rng)
	# Sky words work both ways.
	if _has(w, ["night", "dark", "space", "neon", "galaxy"]): lvl.sky = 2
	elif _has(w, ["sunset", "evening", "desert", "volcano"]): lvl.sky = 1
	elif _has(w, ["candy", "sweet", "pink", "cute", "dessert"]): lvl.sky = 3
	elif _has(w, ["storm", "rain", "spooky", "scary", "haunted"]): lvl.sky = 4
	elif _has(w, [" day", "sunny", "morning"]): lvl.sky = 0
	lvl = clean(lvl, MAX_PARTS_HARD)
	if check(lvl) != "":
		lvl = _quick_new(w, rng)   # a change broke the path: start fresh instead
	return lvl


static func _quick_title(w: String) -> String:
	var themes := {"lava": "Lava Run", "volcano": "Volcano Climb", "ice": "Frozen Dash", "snow": "Snowy Peaks",
		"space": "Space Hop", "candy": "Candy Climb", "jump": "Bounce Park", "bounce": "Bounce Park",
		"spin": "Hammer Time", "hammer": "Hammer Time", "star": "Star Hunt", "coin": "Star Hunt",
		"tower": "Sky Tower", "sky": "Sky Tower", "spooky": "Spooky Path", "race": "Speed Race", "obby": "Mega Obby"}
	for k in themes:
		if w.contains(k):
			return themes[k]
	var p := w.strip_edges()
	return p.substr(0, MAX_TITLE).capitalize() if p.length() > 2 and p.length() <= 24 else "My Obby"


static func _quick_new(w: String, rng: RandomNumberGenerator) -> Dictionary:
	var hard := _has(w, ["hard", "difficult", "insane", "extreme", "pro "])
	var easy := _has(w, ["easy", "kid", "simple", "beginner"])
	var long := _has(w, ["long", "big", "huge", "mega", "tower"])
	var n := 14 if long else 10
	if _has(w, ["short", "quick", "tiny"]): n = 7
	var tower := _has(w, ["tower", "climb", "up", "sky"])
	var lava := _has(w, ["lava", "volcano", "fire", "hot"])
	var ice := _has(w, ["ice", "snow", "frozen", "slip", "winter"])
	var bounce := _has(w, ["jump", "bounce", "trampoline", "pad", "spring"])
	var spin := _has(w, ["spin", "hammer", "swing", "knock"])
	var mover := _has(w, ["move", "moving", "slide", "elevator"])
	var stars := _has(w, ["star", "coin", "collect", "treasure"]) or not hard
	var lvl := {"v": VERSION, "title": _quick_title(w), "sky": 0, "spawn": [0.0, 1.0, 0.0], "goal": [0.0, 1.0, 0.0], "parts": []}
	var parts: Array = lvl.parts
	var palette := [0, 1, 6, 7, 9, 8]
	parts.append(["block", 0.0, -0.5, 0.0, 8.0, 1.0, 8.0, 0.0, 6])
	var pos := Vector3(0, 0, 0)   # top centre of the last platform
	var last := 8.0
	var dir := 0.0
	for i in n:
		var size := rng.randf_range(2.6, 3.6) if hard else (rng.randf_range(4.5, 6.0) if easy else rng.randf_range(3.4, 4.6))
		var gap := rng.randf_range(2.6, 3.6) if hard else (rng.randf_range(1.2, 2.0) if easy else rng.randf_range(1.8, 2.8))
		dir = clampf(dir + rng.randf_range(-0.6, 0.6), -0.9, 0.9)
		var step := last / 2.0 + gap + size / 2.0
		var rise := rng.randf_range(0.6, 1.4) if tower else rng.randf_range(-0.4, 0.8)
		var kind := "block"
		var r := rng.randf()
		if bounce and i % 4 == 2:
			# A jump pad then a tall step only the pad can reach.
			parts.append(["bounce", pos.x, pos.y + 0.2, pos.z, 1.8, 0.4, 1.8, 0.0, 8])
			rise = rng.randf_range(3.0, 4.5)
		elif mover and i % 4 == 1:
			kind = "mover"
		elif ice and r < 0.45:
			kind = "ice"
		var nxt := pos + Vector3(sin(dir) * step, rise, -cos(dir) * step)
		nxt.y = clampf(nxt.y, 0.0, 48.0)
		nxt.x = clampf(nxt.x, -56.0, 56.0)
		if nxt.z < -56.0:
			break
		var col: int = 9 if kind == "ice" else palette[i % palette.size()]
		if kind == "mover":
			# Movers slide sideways across the path; make them wide enough to land on.
			parts.append(["mover", nxt.x, nxt.y - 0.3, nxt.z, size + 1.0, 0.6, size + 1.0, rad_to_deg(dir) + 90.0, 7])
			parts.append(["block", nxt.x, nxt.y - 0.5, nxt.z, 1.5, 1.0, 1.5, 0.0, 3])   # a safe post in the middle
		else:
			parts.append([kind, nxt.x, nxt.y - 0.5, nxt.z, size, 1.0, size, rad_to_deg(dir), col])
		if lava and i % 2 == 1:
			var mid := (pos + nxt) / 2.0
			parts.append(["lava", mid.x, minf(pos.y, nxt.y) - 3.0, mid.z, gap + 3.0, 0.5, size + 2.0, rad_to_deg(dir), 4])
			if size > 3.4 and rng.randf() < 0.5:
				parts.append(["lava", nxt.x, nxt.y + 0.05, nxt.z, size * 0.35, 0.2, size * 0.35, 0.0, 4])
		if spin and i % 3 == 1 and kind == "block":
			parts.append(["spinner", nxt.x, nxt.y + 0.5, nxt.z, size + 2.0, 0.6, 0.6, 0.0, 3])
		if stars and rng.randf() < 0.45:
			parts.append(["coin", nxt.x + rng.randf_range(-1, 1), nxt.y + 1.4, nxt.z, 1.0, 1.0, 1.0, 0.0, 5])
		if i > 0 and i % 5 == 4:
			parts.append(["checkpoint", nxt.x, nxt.y + 0.15, nxt.z, 1.8, 0.3, 1.8, 0.0, 6])
		pos = nxt
		last = size
	# Finish platform
	var step2 := last / 2.0 + 2.0 + 3.0
	var fin := pos + Vector3(sin(dir) * step2, 0.5, -cos(dir) * step2)
	fin.z = maxf(fin.z, -57.0)
	parts.append(["block", fin.x, fin.y - 0.5, fin.z, 6.0, 1.0, 6.0, 0.0, 5])
	lvl.goal = [fin.x, fin.y + 1.0, fin.z]
	if lava:
		lvl.sky = 1
	elif ice:
		lvl.sky = 0
	return lvl


static func _quick_change(lvl: Dictionary, w: String, rng: RandomNumberGenerator) -> void:
	var parts: Array = lvl.parts
	var plats := []
	for p in parts:
		if p[0] in ["block", "ice", "mover"]:
			plats.append(p)
	var sp: Array = lvl.spawn
	var g: Array = lvl.goal
	var is_end := func(p) -> bool:
		return (absf(p[1] - sp[0]) < p[4] / 2.0 + 0.5 and absf(p[3] - sp[2]) < p[6] / 2.0 + 0.5) \
			or (absf(p[1] - g[0]) < p[4] / 2.0 + 0.5 and absf(p[3] - g[2]) < p[6] / 2.0 + 0.5)
	if _has(w, ["harder", "hard", "difficult", "tricky", "challenge"]):
		for p in plats:
			if not is_end.call(p):
				p[4] = maxf(1.8, p[4] * 0.72)
				p[6] = maxf(1.8, p[6] * 0.72)
		var k := 0
		for p in plats:
			if not is_end.call(p) and p[0] == "block" and k < 3 and rng.randf() < 0.5:
				parts.append(["spinner", p[1], p[2] + 1.0, p[3], p[4] + 2.0, 0.6, 0.6, 0.0, 3])
				k += 1
	if _has(w, ["easier", "easy", "simpler"]):
		for p in plats:
			p[4] = minf(MAX_SIZE, p[4] * 1.35)
			p[6] = minf(MAX_SIZE, p[6] * 1.35)
		for i in range(parts.size() - 1, -1, -1):
			if parts[i][0] in ["lava", "spinner"]:
				parts.remove_at(i)
	if _has(w, ["lava", "fire", "volcano"]) and not _has(w, ["no lava", "remove lava"]):
		var low := 999.0
		var xs := Vector2(999, -999)
		var zs := Vector2(999, -999)
		for p in plats:
			low = minf(low, p[2] - p[5] / 2.0)
			xs = Vector2(minf(xs.x, p[1]), maxf(xs.y, p[1]))
			zs = Vector2(minf(zs.x, p[3]), maxf(zs.y, p[3]))
		parts.append(["lava", (xs.x + xs.y) / 2.0, low - 2.0, (zs.x + zs.y) / 2.0,
			minf(MAX_SIZE, xs.y - xs.x + 12.0), 0.5, minf(MAX_SIZE, zs.y - zs.x + 12.0), 0.0, 4])
		for p in plats:
			if not is_end.call(p) and p[4] >= 3.5 and rng.randf() < 0.35:
				parts.append(["lava", p[1], p[2] + p[5] / 2.0 + 0.1, p[3], p[4] * 0.3, 0.2, p[6] * 0.3, 0.0, 4])
	if _has(w, ["no lava", "remove lava", "without lava"]):
		for i in range(parts.size() - 1, -1, -1):
			if parts[i][0] == "lava":
				parts.remove_at(i)
	if _has(w, ["ice", "slippery", "frozen", "snow"]):
		for p in plats:
			if p[0] == "block" and not is_end.call(p) and rng.randf() < 0.6:
				p[0] = "ice"
				p[8] = 9
	if _has(w, ["star", "coin", "collect"]):
		for p in plats:
			if rng.randf() < 0.6:
				parts.append(["coin", p[1], p[2] + p[5] / 2.0 + 1.4, p[3], 1.0, 1.0, 1.0, 0.0, 5])
	if _has(w, ["jump", "bounce", "trampoline", "pad"]):
		var k2 := 0
		for p in plats:
			if not is_end.call(p) and k2 < 4 and rng.randf() < 0.5:
				parts.append(["bounce", p[1], p[2] + p[5] / 2.0 + 0.2, p[3], 1.6, 0.4, 1.6, 0.0, 8])
				k2 += 1
	if _has(w, ["spin", "hammer", "spinner"]):
		var k3 := 0
		for p in plats:
			if not is_end.call(p) and p[0] != "mover" and k3 < 4 and rng.randf() < 0.5:
				parts.append(["spinner", p[1], p[2] + 1.0, p[3], p[4] + 2.0, 0.6, 0.6, 0.0, 3])
				k3 += 1
	if _has(w, ["moving", "move", "mover"]):
		var k4 := 0
		for p in plats:
			if not is_end.call(p) and p[0] == "block" and k4 < 3 and rng.randf() < 0.5:
				p[0] = "mover"
				p[8] = 7
				k4 += 1
	if _has(w, ["checkpoint", "save point"]):
		var i2 := 0
		for p in plats:
			i2 += 1
			if i2 % 4 == 0 and not is_end.call(p):
				parts.append(["checkpoint", p[1], p[2] + p[5] / 2.0 + 0.15, p[3], 1.8, 0.3, 1.8, 0.0, 6])
	if _has(w, ["bigger", "wider"]):
		for p in plats:
			p[4] = minf(MAX_SIZE, p[4] * 1.3)
			p[6] = minf(MAX_SIZE, p[6] * 1.3)
	if _has(w, ["colour", "color", "colorful", "colourful", "rainbow"]):
		var ci := 0
		for p in plats:
			p[8] = ci % 10
			ci += 1
	var rename := w.find("call it ")
	if rename < 0:
		rename = w.find("name it ")
	if rename >= 0:
		lvl.title = clean_title(w.substr(rename + 8).strip_edges().capitalize())
