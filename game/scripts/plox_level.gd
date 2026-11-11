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


# ------------------------------------------------------------------ 0.7.2 playability
## The real movement numbers in studio_play / LocalPlayer: jump 9 m/s up, gravity 24,
## run 7 m/s (9.5 on ice). A normal jump rises 1.7 m and crosses about 5 m; a jump pad
## launches at 19 m/s (about 7.5 m up, 10 m across). Movers slide 4 m each way.
const JUMP_UP := 1.5          # step up a normal jump can always make
const JUMP_GAP := 4.0         # edge-to-edge gap a normal jump can always make
const PAD_UP := 6.5
const PAD_GAP := 8.5
const MOVER_REACH := 4.0
const STANDABLE := ["block", "ice", "bounce", "checkpoint", "mover"]


## Footprint of a part on the ground: [minx, maxx, minz, maxz, top].
static func _foot(p: Array) -> Array:
	var r := deg_to_rad(float(p[7]))
	var sx := float(p[4])
	var sz := float(p[6])
	var cx := float(p[1])
	var cz := float(p[3])
	var hx: float = absf(cos(r)) * sx / 2.0 + absf(sin(r)) * sz / 2.0
	var hz: float = absf(sin(r)) * sx / 2.0 + absf(cos(r)) * sz / 2.0
	var f := [cx - hx, cx + hx, cz - hz, cz + hz, float(p[2]) + float(p[5]) / 2.0]
	if p[0] == "mover":   # it slides along its rotation direction
		var ax := absf(cos(r)) * MOVER_REACH
		var az := absf(sin(r)) * MOVER_REACH
		f = [f[0] - ax, f[1] + ax, f[2] - az, f[3] + az, f[4]]
	return f


static func _gap(a: Array, b: Array) -> float:
	var dx: float = maxf(0.0, maxf(float(a[0]) - float(b[1]), float(b[0]) - float(a[1])))
	var dz: float = maxf(0.0, maxf(float(a[2]) - float(b[3]), float(b[2]) - float(a[3])))
	return sqrt(dx * dx + dz * dz)


static func _under(pt: Array, parts: Array) -> int:
	var best := -1
	var best_top := -INF
	for i in parts.size():
		var p: Array = parts[i]
		if not STANDABLE.has(p[0]):
			continue
		var f := _foot(p)
		if pt[0] >= f[0] - 0.6 and pt[0] <= f[1] + 0.6 and pt[2] >= f[2] - 0.6 and pt[2] <= f[3] + 0.6 \
				and pt[1] >= f[4] - 0.6 and pt[1] - f[4] < 6.0 and f[4] > best_top:
			best = i
			best_top = f[4]
	return best


## Can a player get from part a to part b?
static func _hop(pa: Array, fa: Array, fb: Array) -> bool:
	var g := _gap(fa, fb)
	var up: float = fb[4] - fa[4]
	if pa[0] == "bounce" and up <= PAD_UP and g <= PAD_GAP:
		return true
	if up <= JUMP_UP:
		var reach := JUMP_GAP + (clampf(-up, 0.0, 8.0) * 0.45)   # dropping down carries you further
		if pa[0] == "ice":
			reach += 1.0
		return g <= reach
	return false


## Returns a list of problems, empty when the course can be finished.
static func playability(d: Dictionary) -> Array:
	var probs := []
	var parts: Array = d.get("parts", [])
	var si := _under(d.spawn, parts)
	var gi := _under(d.goal, parts)
	if si < 0:
		probs.append("There is no platform right under the spawn point %s. Put spawn 1 m above the top of the first platform." % str(d.spawn))
	if gi < 0:
		probs.append("There is no platform right under the goal %s. Put the goal 1 m above the top of the last platform." % str(d.goal))
	if si < 0 or gi < 0:
		return probs
	var feet := []
	for p in parts:
		feet.append(_foot(p) if STANDABLE.has(p[0]) else [])
	var seen := {si: true}
	var queue := [si]
	while not queue.is_empty():
		var i: int = queue.pop_front()
		if i == gi:
			return probs
		for j in parts.size():
			if seen.has(j) or feet[j].is_empty():
				continue
			if _hop(parts[i], feet[i], feet[j]):
				seen[j] = true
				queue.append(j)
	# Not reachable: say where the path breaks, so the AI can fix that spot.
	var best_d := INF
	var from := -1
	var to := -1
	for i in seen.keys():
		for j in parts.size():
			if seen.has(j) or feet[j].is_empty():
				continue
			var dd := _gap(feet[i], feet[j]) + maxf(0.0, feet[j][4] - feet[i][4]) * 2.0
			if dd < best_d:
				best_d = dd
				from = i
				to = j
	if from >= 0:
		var fa: Array = feet[from]
		var fb: Array = feet[to]
		probs.append("The goal can't be reached from the spawn. The path breaks between part #%d (%s, top at y=%.1f) and part #%d (%s, top at y=%.1f): the gap is %.1f m and the step up is %.1f m. A normal jump crosses at most %.1f m and climbs at most %.1f m; a bounce pad climbs up to %.1f m. Add or move platforms there."
			% [from, parts[from][0], fa[4], to, parts[to][0], fb[4], _gap(fa, fb), fb[4] - fa[4], JUMP_GAP, JUMP_UP, PAD_UP])
	else:
		probs.append("The goal can't be reached from the spawn.")
	return probs


## The instructions the server gives the AI. It must answer with JSON only.
static func ai_system_prompt(max_parts: int) -> String:
	return ("You are the Studio Builder for Plux, a mobile 3D game platform. Players describe a game and you design it as a level for the Plux obstacle-course engine. "
		+ "Your whole reply is ONE JSON object: it starts with { and ends with }. No prose, no markdown, no code fences, no code in any language.\n\n"
		+ "THE ENGINE. A level is a list of parts in a 3D world. Units are metres, y is up. The player runs at 7 m/s, a normal jump rises 1.7 m and lasts 0.75 s. "
		+ "Rules for a fair course: an edge-to-edge gap between platforms at the same height must be at most 3.5 m; a step up must be at most 1.2 m; "
		+ "to climb higher use a bounce pad (it launches the player about 7 m up and up to 8 m across). Dropping down is always fine.\n"
		+ "Parts: [kind, x, y, z, sx, sy, sz, rotY, color]. x y z is the CENTRE of the part (so its top is y + sy/2). sx sy sz are its size (0.5 to 24). rotY is degrees around the vertical axis. color is 0-9.\n"
		+ "Kinds:\n"
		+ "- block: solid platform, floor, wall, bridge, stair step or tower. Typical 4x1x4; a narrow beam is 1.2x0.6x8.\n"
		+ "- ice: slippery platform, the player slides and runs faster. Same sizes as block.\n"
		+ "- lava: deadly surface, touching it sends the player back to the last checkpoint. Use it as pits beside or between platforms, or as a floor under jumps. Typical 4x0.5x4, keep its top below the platforms around it.\n"
		+ "- bounce: jump pad, launches the player high. 2x0.4x2. Put the higher platform within 8 m.\n"
		+ "- spinner: a hammer bar that spins around its centre and knocks players off. 8x0.8x0.8, centre it about 1 m above the platform it sweeps. The platform under it should be wide (5 m or more).\n"
		+ "- mover: a moving platform that slides 4 m back and forth along its rotY direction (0 = along x, 90 = along z). 3x0.6x3. Great for crossing big gaps or lava.\n"
		+ "- coin: a star to collect, 1x1x1, float it 1 to 2 m above a platform. Put 3 to 10 along the route and as rewards on risky side paths.\n"
		+ "- checkpoint: a respawn pad, 2x0.3x2, laid on top of a platform (y = platform top + 0.15). Put one every 5 to 8 platforms and after every hard section.\n"
		+ "Colors: 0 blue, 1 light blue, 2 white, 3 slate grey, 4 orange, 5 yellow, 6 green, 7 purple, 8 pink, 9 cyan. Pick a palette that fits the theme and use it consistently.\n"
		+ "Sky: 0 day, 1 sunset, 2 night, 3 candy (pastel pink), 4 storm.\n"
		+ "World limits: x and z between -60 and 60, y between 0 and 50. Use the space: courses can wind, climb, zig-zag and spiral, not only go straight.\n\n"
		+ "HOW TO WORK. First think about the player's idea and write a short plan inside the JSON, then build the level from that plan:\n"
		+ "{\"plan\": {\"theme\": \"what it looks and feels like\", \"palette\": [colors], \"sky\": 0-4, \"sections\": [\"section 1: ...\", \"section 2: ...\", ...], \"pieces\": [\"which kinds and why\"]}, "
		+ "\"title\": \"short name, max 40 chars\", \"sky\": 0-4, \"spawn\": [x,y,z], \"goal\": [x,y,z], \"parts\": [[kind,x,y,z,sx,sy,sz,rotY,color], ...]}\n"
		+ "Plan 3 to 6 sections, each with its own idea (for example: a warm-up path, a lava bridge, a hammer gauntlet, a mover crossing, a jump-pad climb, a final tower). "
		+ "spawn is 1 m above the top of the first platform, goal is 1 m above the top of the last platform. Every platform on the route must be reachable from the one before it.\n"
		+ "Use between 20 and %d parts. Make it fun, fair and beatable in 1 to 3 minutes.\n\n"
		+ "FOLLOW THE PLAYER'S IDEA. The game must clearly match what they asked for: its title, sky, colours, which pieces you use and the shape of the course should all tell their story. "
		+ "If they name pieces (lava, hammers, ice, jump pads, moving platforms, stars, checkpoints), use them prominently. "
		+ "If they ask for something the engine can't do (cars, guns, monsters, shops, scripts, menus), keep their theme and build the closest obstacle course: "
		+ "a horror or ghost idea becomes a night or storm course in slate, purple and white with lava pits and hammers; a space idea becomes floating islands linked by jump pads under a night sky; "
		+ "a race becomes a long winding path with movers and ice; a candy idea uses the candy sky with pink and yellow. Never refuse and never explain, just build.\n\n"
		+ "Small example of the format (yours is bigger and follows the player's idea): "
		+ "{\"plan\": {\"theme\": \"sunset lava hop\", \"palette\": [4, 5, 2], \"sky\": 1, \"sections\": [\"start pad\", \"lava gap\", \"jump pad climb\", \"hammer finish\"], \"pieces\": [\"lava\", \"bounce\", \"spinner\", \"coin\"]}, "
		+ "\"title\": \"Lava Hop\", \"sky\": 1, \"spawn\": [0, 2, 0], \"goal\": [0, 6.5, -26], \"parts\": ["
		+ "[\"block\", 0, 0.5, 0, 6, 1, 6, 0, 2], [\"lava\", 0, 0.1, -6, 6, 0.4, 5, 0, 4], [\"block\", 0, 0.5, -10, 4, 1, 4, 0, 5], "
		+ "[\"bounce\", 0, 1.2, -10, 2, 0.4, 2, 0, 8], [\"coin\", 0, 4, -13, 1, 1, 1, 0, 5], [\"block\", 0, 4.5, -17, 6, 1, 6, 0, 4], "
		+ "[\"checkpoint\", 0, 5.15, -17, 2, 0.3, 2, 0, 6], [\"spinner\", 0, 6, -17, 8, 0.8, 0.8, 0, 3], [\"block\", 0, 4.5, -22, 4, 1, 4, 0, 5], [\"block\", 0, 5, -26, 6, 1, 6, 0, 2]]}") % max_parts


## Sent when the first reply wasn't usable, so the second try is stricter.
const AI_RETRY_NOTE := "Your last reply could not be used because it was not a single valid JSON object in the level format. Reply again with ONLY the JSON object: start with { and end with }, no other text, no code fences, no code. Keep the plan short and use at most 60 parts so it fits."


## Sent when the level parsed but can't be finished.
static func ai_repair_note(problems: Array) -> String:
	return "I checked your level in the engine and it can't be finished yet:\n- " + "\n- ".join(problems) \
		+ "\nFix only those spots (add, move or resize platforms, or add a bounce pad) and keep the rest of the level and its theme the same. Reply with the whole fixed level as ONE JSON object in the same format, JSON only."



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
