class_name PloxSpec
extends RefCounted
## Plux 0.8.0 game spec v1: a data-driven description of ANY game the Studio AI can
## compose (racing, shooters, mazes, sports, platformers, survival...). The server
## cleans and checks it, the client's SpecPlay interprets it at runtime. No code is
## ever generated or run from the AI: only these keys, clamped and validated.
## Positions are BOTTOM-CENTRE: pos[1] is where the object's base sits (0 = floor).

const V := 1
const CONTROLS := ["platformer", "topdown", "side", "firstperson", "vehicle"]
const SHAPES := ["box", "sphere", "cylinder", "ramp", "cone", "capsule",
	"tree", "rock", "house", "crate", "barrel", "coin", "gem", "star", "heart", "flag",
	"character", "ghost", "car", "ball", "goal", "ring", "tower", "spike", "lamp", "fence", "mushroom", "turret", "grave"]
const MATS := ["plain", "glow", "metal", "lava", "ice", "grass", "water", "glass", "wood", "stone", "sand", "snow", "asphalt", "candy"]
const SKIES := ["day", "sunset", "night", "dawn", "candy", "storm", "space", "spooky", "desert", "snow"]
const LIGHTS := ["bright", "dim", "dark"]
const MUSIC := ["none", "chill", "action", "spooky", "happy", "epic", "race"]
const FLOORS := ["ground", "none", "water", "lava"]
const ABILITIES := ["shoot", "dash", "double_jump", "kick", "boost"]
const BEHAVIORS := ["move", "rotate", "bob", "rise", "shrink", "chase", "flee", "follow", "wander", "race",
	"shoot", "spawn", "damage", "bounce", "boost", "collect", "push", "destructible", "checkpoint", "teleport"]
const ACTORS := ["chase", "flee", "follow", "wander", "race"]   # these make the entity a moving character
const TRIGGERS := ["touch", "collect", "destroyed", "score", "timer", "start", "lap", "wave"]
const ACTIONS := ["win", "lose", "score", "message", "spawn", "open", "remove", "show", "gravity", "teleport", "reset", "lives", "time", "heal", "speed", "ability"]
const WINS := ["reach", "score", "laps", "survive", "defeat_all", "waves", "collect_all", "trigger"]
const LOSES := ["time_up", "no_lives", "destroyed", "beaten", "enemy_score"]
const HUD := ["score", "timer", "lives", "health", "laps", "wave", "enemies", "message"]
const MAX_HARD := 160      # entities after copies, for phone performance
const MAX_TEMPLATES := 10
const MAX_TRIGGERS := 24
const MAX_WAVES := 10
const COLOR_NAMES := {"red": "#E53935", "blue": "#1E88E5", "green": "#43A047", "yellow": "#FDD835", "orange": "#FB8C00",
	"purple": "#8E24AA", "pink": "#EC407A", "white": "#FFFFFF", "black": "#212121", "grey": "#757575", "gray": "#757575",
	"brown": "#6D4C41", "cyan": "#26C6DA", "gold": "#FFC107", "silver": "#B0BEC5", "lime": "#C0CA33", "teal": "#00897B",
	"navy": "#1A237E", "sky": "#64B5F6", "darkgreen": "#1B5E20", "dark": "#37474F"}


static func is_spec(d) -> bool:
	return d is Dictionary and (int(_n(d.get("v", 0), 0, 9, 0)) == V and d.has("entities"))


# ---------------------------------------------------------------- small helpers

static func _n(v, lo: float, hi: float, fb: float) -> float:
	if v is String and v.strip_edges().is_valid_float():
		v = v.strip_edges().to_float()
	if v is bool:
		return fb
	if not (v is float or v is int):
		return fb
	var f := float(v)
	if is_nan(f) or is_inf(f):
		return fb
	return clampf(f, lo, hi)


static func _r(f: float) -> float:
	return snappedf(f, 0.01)


static func _vec(v, lo: float, hi: float, fb: Array) -> Array:
	var a := []
	if v is Array:
		a = v
	elif v is Dictionary:
		a = [v.get("x", fb[0]), v.get("y", fb[1]), v.get("z", fb[2])]
	elif v is float or v is int:
		a = [v, v, v]
	var out := []
	for i in 3:
		out.append(_r(_n(a[i] if i < a.size() else fb[i], lo, hi, fb[i])))
	return out


static func _s(v, n: int) -> String:
	return str(v).strip_edges().substr(0, n) if v != null else ""


static func _pick(v, list: Array, fb: String) -> String:
	var s := str(v).to_lower().strip_edges().replace("-", "_").replace(" ", "_") if v != null else ""
	if list.has(s):
		return s
	var alias := {"third_person": "platformer", "thirdperson": "platformer", "third": "platformer", "top_down": "topdown", "top": "topdown",
		"side_view": "side", "sideview": "side", "2d": "side", "side_scroller": "side", "first_person": "firstperson", "fps": "firstperson", "first": "firstperson",
		"driving": "vehicle", "car": "vehicle", "kart": "vehicle", "drive": "vehicle", "racing": "vehicle",
		"patrol": "move", "path": "move", "spin": "rotate", "float": "bob", "hover": "bob", "hazard": "damage", "hurt": "damage", "kill": "damage",
		"collectable": "collect", "collectible": "collect", "pickup": "collect", "pushable": "push", "physics": "push", "breakable": "destructible",
		"health": "destructible", "enemy": "chase", "jump_pad": "bounce", "trampoline": "bounce", "speed": "boost", "spawner": "spawn", "shooter": "shoot",
		"cube": "box", "block": "box", "platform": "box", "wall": "box", "cylinder_": "cylinder", "pillar": "cylinder", "wedge": "ramp", "slope": "ramp",
		"zombie": "character", "person": "character", "npc": "character", "robot": "character", "monster": "character", "humanoid": "character",
		"tombstone": "grave", "gravestone": "grave", "star_": "star", "coin_": "coin", "diamond": "gem", "crystal": "gem", "key": "gem", "stone": "rock", "boulder": "rock",
		"double": "double_jump", "doublejump": "double_jump", "blaster": "shoot", "gun": "shoot", "fire": "shoot",
		"touched": "touch", "enter": "touch", "collected": "collect", "defeated": "destroyed", "killed": "destroyed", "time": "timer",
		"add_score": "score", "points": "score", "show_message": "message", "text": "message", "open_door": "open", "destroy": "remove", "hide": "remove",
		"time_up": "time_up", "timeout": "time_up", "out_of_lives": "no_lives", "lives": "no_lives", "finish": "reach", "goal": "reach",
		"collect": "score", "kill_all": "defeat_all", "defeat": "defeat_all", "lap": "laps", "race": "laps", "wave": "waves", "time_": "timer"}
	if alias.has(s) and list.has(alias[s]):
		return alias[s]
	return fb


static func color(v, fb := "#90A4AE") -> String:
	if v is String:
		var s: String = v.strip_edges().to_lower().replace(" ", "")
		if COLOR_NAMES.has(s):
			return COLOR_NAMES[s]
		if not s.begins_with("#"):
			s = "#" + s
		if (s.length() == 7 or s.length() == 4) and s.substr(1).is_valid_hex_number():
			return Color.html(s).to_html(false).insert(0, "#").to_upper()
	return fb


# ---------------------------------------------------------------- clean

## Rebuilds a spec from anything the AI sent, keeping only valid keys and clamping
## every number. Copies (repeat / circle) are expanded here. spec["_notes"] lists
## what was dropped (callers remove it before saving).
static func clean(raw, max_entries := 90) -> Dictionary:
	var d: Dictionary = raw if raw is Dictionary else {}
	for k in ["game", "spec", "level"]:
		if d.get(k) is Dictionary and (d[k] as Dictionary).has("entities"):
			var inner: Dictionary = d[k]
			if not inner.has("plan") and d.has("plan"):
				inner["plan"] = d.plan
			d = inner
	var notes := []
	var s := {"v": V}
	s.title = _s(d.get("title", "My game"), 40)
	if s.title == "":
		s.title = "My game"
	s.intro = _s(d.get("intro", d.get("goal_text", d.get("description", ""))), 140)
	var plan: Dictionary = d.get("plan", {}) if d.get("plan") is Dictionary else {}
	s.plan = {}
	for k in ["genre", "loop", "controls", "win", "theme"]:
		if plan.has(k):
			s.plan[k] = _s(plan[k] if not (plan[k] is Array) else ", ".join(PackedStringArray(plan[k].map(func(x): return str(x)))), 160)
	var w: Dictionary = d.get("world", {}) if d.get("world") is Dictionary else {}
	var size := _n(w.get("size", 80), 30, 200, 80)
	s.world = {"size": _r(size), "floor": _pick(w.get("floor", "ground"), FLOORS, "ground"),
		"floor_color": color(w.get("floor_color", w.get("color", "")), "#7CB342"), "floor_mat": _pick(w.get("floor_mat", "grass"), MATS, "plain"),
		"sky": _pick(w.get("sky", "day"), SKIES, "day"), "fog": _r(_n(w.get("fog", 0), 0, 1, 0)),
		"light": _pick(w.get("light", "bright"), LIGHTS, "bright"), "music": _pick(w.get("music", "chill"), MUSIC, "chill"),
		"gravity": _r(_n(w.get("gravity", 1), 0.2, 2.5, 1)), "walls": bool(w.get("walls", false)) if w.get("walls") is bool else false}
	var half: float = size / 2.0
	s.controls = _pick(d.get("controls", d.get("camera", plan.get("controls", "platformer"))), CONTROLS, "platformer")
	var p: Dictionary = d.get("player", {}) if d.get("player") is Dictionary else {}
	var ab := []
	for a in (p.get("abilities", []) if p.get("abilities") is Array else []):
		var x := _pick(a, ABILITIES, "")
		if x != "" and not ab.has(x):
			ab.append(x)
	s.player = {"spawn": _vec(p.get("spawn", d.get("spawn", [0, 0, 0])), -half, half, [0, 0, 0]),
		"speed": _r(_n(p.get("speed", 7 if s.controls != "vehicle" else 16), 2, 30, 7)), "jump": _r(_n(p.get("jump", 9), 0, 20, 9)),
		"lives": int(_n(p.get("lives", 0), 0, 9, 0)), "health": int(_n(p.get("health", 1), 1, 20, 1)), "abilities": ab,
		"color": color(p.get("color", "#1E88E5"), "#1E88E5")}
	var sh: Dictionary = p.get("shot", {}) if p.get("shot") is Dictionary else {}
	s.player.shot = {"rate": _r(_n(sh.get("rate", 0.3), 0.1, 3, 0.3)), "damage": int(_n(sh.get("damage", 1), 1, 20, 1)),
		"speed": _r(_n(sh.get("speed", 26), 6, 60, 26)), "color": color(sh.get("color", "#FFEE58"), "#FFEE58")}
	s.player.spawn[1] = maxf(s.player.spawn[1], -5)
	# Entities, copies expanded
	var src = d.get("entities", d.get("objects", []))
	var ents := []
	var ids := {}
	var entries := 0
	var templates := 0
	if src is Array:
		for e in src:
			if not (e is Dictionary):
				continue
			entries += 1
			if entries > max_entries:
				notes.append("dropped entities after the first %d" % max_entries)
				break
			var c := _clean_entity(e, half, ids.size())
			if c.template:
				templates += 1
				if templates > MAX_TEMPLATES:
					continue
			for x in _copies(c, e, half):
				if ents.size() >= MAX_HARD:
					notes.append("stopped at %d entities" % MAX_HARD)
					break
				var id: String = x.id
				while ids.has(id):
					id = "%s_%d" % [x.id, ids.size()]
				x.id = id
				ids[id] = true
				ents.append(x)
	s.entities = ents
	# Triggers
	s.triggers = []
	for t in (d.get("triggers", []) if d.get("triggers") is Array else []):
		if t is Dictionary and s.triggers.size() < MAX_TRIGGERS:
			var ct := _clean_trigger(t, half)
			if not ct.is_empty():
				s.triggers.append(ct)
	# Rules
	var r: Dictionary = d.get("rules", {}) if d.get("rules") is Dictionary else {}
	var win = r.get("win", {})
	if win is String:
		win = {"type": win}
	if win is Array and not win.is_empty() and win[0] is Dictionary:
		win = win[0]
	if not (win is Dictionary):
		win = {}
	s.rules = {"win": {"type": _pick(win.get("type", "reach"), WINS, "reach"), "value": _r(_n(win.get("value", win.get("count", win.get("seconds", 0))), 0, 9999, 0)),
		"target": _s(win.get("target", ""), 40)},
		"lose": [], "timer": int(_n(r.get("timer", r.get("countdown", r.get("time_limit", 0))), 0, 900, 0)),
		"laps": int(_n(r.get("laps", 0), 0, 20, 0)), "checkpoints": [], "waves": [], "wave_gap": _r(_n(r.get("wave_gap", 4), 0, 60, 4))}
	var lose = r.get("lose", [])
	if lose is String or lose is Dictionary:
		lose = [lose]
	for l in (lose if lose is Array else []):
		var ld: Dictionary = {"type": l} if l is String else (l if l is Dictionary else {})
		var lt := _pick(ld.get("type", ""), LOSES, "")
		if lt != "":
			s.rules.lose.append({"type": lt, "value": _r(_n(ld.get("value", 0), 0, 999, 0)), "target": _s(ld.get("target", ""), 40)})
	var cps = r.get("checkpoints", [])
	if cps is String:
		cps = [cps]
	for c in (cps if cps is Array else []):
		var list := find(s, str(c))   # a tag expands to every entity that has it, in order
		for e in list:
			if not s.rules.checkpoints.has(e.id) and s.rules.checkpoints.size() < 24:
				s.rules.checkpoints.append(e.id)
	var wv = r.get("waves", [])
	for x in (wv if wv is Array else []):
		if x is Dictionary and s.rules.waves.size() < MAX_WAVES:
			var at = x.get("at", "")
			s.rules.waves.append({"template": _s(x.get("template", x.get("enemy", "")), 40), "count": int(_n(x.get("count", 5), 1, 30, 5)),
				"every": _r(_n(x.get("every", 1.5), 0.2, 20, 1.5)), "at": _vec(at, -half, half, [0, 0, 0]) if at is Array else _s(at, 40)})
	if s.rules.win.type == "laps" and s.rules.laps <= 0:
		s.rules.laps = maxi(1, int(s.rules.win.value))
	if s.rules.win.type == "survive" and s.rules.win.value <= 0:
		s.rules.win.value = s.rules.timer if s.rules.timer > 0 else 60
	if s.player.lives == 0 and _has_lose(s, "no_lives"):
		s.player.lives = 3
	# HUD
	var hud := []
	for h in (d.get("hud", []) if d.get("hud") is Array else []):
		var x := _pick(h, HUD, "")
		if x != "" and not hud.has(x):
			hud.append(x)
	var need := {"score": s.rules.win.type in ["score", "collect_all"] or _any_beh(s, "collect"), "timer": s.rules.timer > 0 or s.rules.win.type == "survive",
		"lives": s.player.lives > 0, "laps": s.rules.laps > 0, "wave": not s.rules.waves.is_empty(), "health": s.player.health > 1,
		"enemies": s.rules.win.type == "defeat_all"}
	for k in need:
		if need[k] and not hud.has(k):
			hud.append(k)
	s.hud = hud
	s["_notes"] = notes
	return s


static func _has_lose(s: Dictionary, t: String) -> bool:
	for l in s.rules.lose:
		if l.type == t:
			return true
	return false


static func _any_beh(s: Dictionary, t: String) -> bool:
	for e in s.entities:
		if beh(e, t) != null:
			return true
	return false


static func beh(e: Dictionary, t: String):
	for b in e.get("behaviors", []):
		if b.type == t:
			return b
	return null


static func _clean_entity(e: Dictionary, half: float, n: int) -> Dictionary:
	var shape := _pick(e.get("shape", e.get("type", e.get("prop", "box"))), SHAPES, "box")
	var id := _s(e.get("id", e.get("name", "")), 32).to_lower().replace(" ", "_")
	if id == "":
		id = "%s%d" % [shape, n]
	var defsize := {"box": [4, 1, 4], "sphere": [1, 1, 1], "cylinder": [1, 2, 1], "ramp": [4, 2, 6], "coin": [1, 1, 0.3], "gem": [0.8, 1, 0.8],
		"star": [1, 1, 0.3], "heart": [1, 1, 0.3], "flag": [1, 3, 1], "character": [1, 2, 1], "ghost": [1.2, 1.8, 1.2], "car": [2, 1.4, 3.6], "ball": [1.4, 1.4, 1.4],
		"goal": [6, 3, 2], "ring": [3, 3, 0.4], "tree": [2, 5, 2], "house": [6, 5, 6], "tower": [4, 10, 4], "turret": [1.4, 1.8, 1.4]}
	var sz := _vec(e.get("size", e.get("scale", defsize.get(shape, [1.5, 1.5, 1.5]))), 0.2, 200, defsize.get(shape, [1.5, 1.5, 1.5]))
	var rot = e.get("rot", e.get("rotation", 0))
	var rv := _vec(rot, -360, 360, [0, 0, 0]) if rot is Array or rot is Dictionary else [0.0, _r(_n(rot, -360, 360, 0)), 0.0]
	var tags := []
	for t in (e.get("tags", []) if e.get("tags") is Array else ([e.tags] if e.get("tags") is String else [])):
		var ts := _s(t, 24).to_lower()
		if ts != "" and tags.size() < 6:
			tags.append(ts)
	if e.get("tag") is String and not tags.has(e.tag.to_lower()):
		tags.append(_s(e.tag, 24).to_lower())
	var out := {"id": id, "shape": shape, "pos": _vec(e.get("pos", e.get("position", [0, 0, 0])), -half - 20, half + 20, [0, 0, 0]),
		"size": sz, "rot": rv, "color": color(e.get("color", e.get("colour", "")), _shape_color(shape)), "mat": _pick(e.get("mat", e.get("material", "plain")), MATS, "plain"),
		"solid": bool(e.solid) if e.get("solid") is bool else not (shape in ["coin", "gem", "star", "heart", "ring", "ghost"]),
		"hidden": e.get("hidden", false) is bool and e.hidden, "invisible": (e.get("invisible", false) is bool and e.invisible) or (e.get("visible", true) is bool and not e.visible),
		"template": e.get("template", false) is bool and e.template, "tags": tags, "behaviors": []}
	out.pos[1] = clampf(out.pos[1], -10, 120)
	var bs = e.get("behaviors", e.get("behaviours", e.get("behavior", [])))
	if bs is Dictionary or bs is String:
		bs = [bs]
	for b in (bs if bs is Array else []):
		var cb := _clean_beh({"type": b} if b is String else b, half)
		if not cb.is_empty() and out.behaviors.size() < 5:
			out.behaviors.append(cb)
	# Characters that hunt or shoot at the player are enemies.
	for b in out.behaviors:
		if (b.type in ["chase", "shoot"] and str(b.get("target", b.get("at", "player"))) == "player") and not tags.has("enemy"):
			tags.append("enemy")
	if out.mat == "lava" and beh(out, "damage") == null:
		out.behaviors.append({"type": "damage", "amount": 1, "kill": true, "knock": 0.0, "target": "player", "die": false})
	return out


static func _shape_color(shape: String) -> String:
	match shape:
		"coin", "star": return "#FFC107"
		"gem": return "#26C6DA"
		"heart": return "#EC407A"
		"tree": return "#43A047"
		"rock", "grave": return "#78909C"
		"ghost": return "#ECEFF1"
		"character": return "#7CB342"
		"flag": return "#E53935"
		"ball": return "#FFFFFF"
	return "#90A4AE"


static func _copies(c: Dictionary, e: Dictionary, half: float) -> Array:
	var rep = e.get("repeat", null)
	var cir = e.get("circle", null)
	if rep is Dictionary:
		var n := int(_n(rep.get("count", 1), 1, 40, 1))
		var st := _vec(rep.get("step", [2, 0, 0]), -60, 60, [2, 0, 0])
		var out := []
		for i in n:
			var x: Dictionary = c.duplicate(true)
			x.id = "%s_%d" % [c.id, i]
			for k in 3:
				x.pos[k] = _r(clampf(c.pos[k] + st[k] * i, -half - 20, half + 20))
			_shift_paths(x, [st[0] * i, st[1] * i, st[2] * i])
			if not x.tags.has(c.id):
				x.tags.append(c.id)
			out.append(x)
		return out
	if cir is Dictionary:
		var n := int(_n(cir.get("count", 8), 2, 48, 8))
		var rad := _n(cir.get("radius", 10), 1, half + 10, 10)
		var a0 := deg_to_rad(_n(cir.get("start", 0), -360, 360, 0))
		var out := []
		for i in n:
			var x: Dictionary = c.duplicate(true)
			var a := a0 + TAU * i / n
			x.id = "%s_%d" % [c.id, i]
			x.pos[0] = _r(c.pos[0] + sin(a) * rad)
			x.pos[2] = _r(c.pos[2] + cos(a) * rad)
			if cir.get("face", true):
				x.rot[1] = _r(fposmod(c.rot[1] + rad_to_deg(a) + 90.0, 360.0))   # long side along the circle
			_shift_paths(x, [x.pos[0] - c.pos[0], 0, x.pos[2] - c.pos[2]])
			if not x.tags.has(c.id):
				x.tags.append(c.id)
			out.append(x)
		return out
	return [c]


static func _shift_paths(x: Dictionary, d: Array) -> void:
	for b in x.behaviors:
		if b.type == "move" and b.get("relative", false) == false:
			for p in b.path:
				for k in 3:
					p[k] = _r(p[k] + d[k])


static func _clean_beh(b, half: float) -> Dictionary:
	if not (b is Dictionary):
		return {}
	var t := _pick(b.get("type", b.get("name", "")), BEHAVIORS, "")
	if t == "":
		return {}
	var o := {"type": t}
	var tgt := _s(b.get("target", b.get("at", "player")), 40).to_lower()
	if tgt == "":
		tgt = "player"
	match t:
		"move":
			var path := []
			for p in (b.get("path", b.get("points", [])) if b.get("path", b.get("points", [])) is Array else []):
				if path.size() < 10 and (p is Array or p is Dictionary):
					path.append(_vec(p, -half - 20, half + 60, [0, 0, 0]))
			if path.is_empty():
				var ax := _vec(b.get("offset", b.get("by", [0, 0, 6])), -60, 60, [0, 0, 6])
				o.offset = ax
			o.path = path
			o.speed = _r(_n(b.get("speed", 3), 0.3, 25, 3))
			o.loop = _pick(b.get("loop", "pingpong"), ["pingpong", "loop", "once"], "pingpong")
		"rotate":
			o.speed = _r(_n(b.get("speed", 90), -400, 400, 90))
			o.axis = _pick(b.get("axis", "y"), ["x", "y", "z"], "y")
		"bob":
			o.height = _r(_n(b.get("height", 0.5), 0, 8, 0.5))
			o.speed = _r(_n(b.get("speed", 2), 0.1, 10, 2))
		"rise":
			o.speed = _r(_n(b.get("speed", 0.4), 0.02, 6, 0.4))
			o.max = _r(_n(b.get("max", b.get("height", 40)), 1, 150, 40))
			o.delay = _r(_n(b.get("delay", 3), 0, 60, 3))
		"shrink":
			o.to = _r(_n(b.get("to", 0.3), 0.05, 4, 0.3))
			o.time = _r(_n(b.get("time", 60), 2, 600, 60))
			o.delay = _r(_n(b.get("delay", 3), 0, 60, 3))
		"chase", "follow":
			o.target = tgt
			o.speed = _r(_n(b.get("speed", 3), 0.3, 20, 3))
			o.range = _r(_n(b.get("range", 0), 0, 300, 0))
			o.fly = b.get("fly", false) is bool and b.fly
			o.distance = _r(_n(b.get("distance", 0 if t == "chase" else 3), 0, 30, 0))
		"flee":
			o.target = tgt
			o.speed = _r(_n(b.get("speed", 3), 0.3, 20, 3))
			o.range = _r(_n(b.get("range", 10), 1, 100, 10))
		"wander":
			o.speed = _r(_n(b.get("speed", 2), 0.3, 15, 2))
			o.radius = _r(_n(b.get("radius", 8), 1, 100, 8))
		"race":
			o.speed = _r(_n(b.get("speed", 11), 1, 40, 11))
		"shoot":
			o.target = tgt
			o.every = _r(_n(b.get("every", b.get("rate", 2)), 0.25, 15, 2))
			o.speed = _r(_n(b.get("speed", 14), 3, 50, 14))
			o.damage = int(_n(b.get("damage", 1), 1, 20, 1))
			o.range = _r(_n(b.get("range", 25), 2, 200, 25))
			o.color = color(b.get("color", "#FF5252"), "#FF5252")
		"spawn":
			o.template = _s(b.get("template", b.get("what", "")), 40)
			o.every = _r(_n(b.get("every", 5), 0.5, 120, 5))
			o.max = int(_n(b.get("max", 6), 1, 30, 6))
			o.count = int(_n(b.get("count", 1), 1, 6, 1))
		"damage":
			o.amount = int(_n(b.get("amount", b.get("damage", 1)), 0, 20, 1))
			o.kill = b.get("kill", false) is bool and b.kill
			o.knock = _r(_n(b.get("knock", b.get("push", 0)), 0, 40, 0))
			o.target = tgt
			o.die = b.get("die", false) is bool and b.die
		"bounce":
			o.power = _r(_n(b.get("power", 18), 5, 45, 18))
		"boost":
			o.power = _r(_n(b.get("power", 1.6), 1.1, 3, 1.6))
			o.time = _r(_n(b.get("time", 2), 0.3, 10, 2))
		"collect":
			o.score = int(_n(b.get("score", b.get("points", 1)), 0, 1000, 1))
			o.heal = int(_n(b.get("heal", 0), 0, 20, 0))
			o.time = int(_n(b.get("time", 0), 0, 120, 0))
			o.ability = _pick(b.get("ability", ""), ABILITIES, "")
		"push":
			o.mass = _r(_n(b.get("mass", 1), 0.1, 30, 1))
			o.bounce = _r(_n(b.get("bounce", 0.4), 0, 1, 0.4))
		"destructible":
			o.hp = int(_n(b.get("hp", b.get("health", 1)), 1, 200, 1))
			o.score = int(_n(b.get("score", 1), 0, 1000, 1))
		"teleport":
			o.to = _vec(b.get("to", [0, 1, 0]), -half, half + 60, [0, 1, 0])
	return o


static func _clean_trigger(t: Dictionary, half: float) -> Dictionary:
	var on := _pick(t.get("on", t.get("when", t.get("event", ""))), TRIGGERS, "")
	if on == "":
		return {}
	var acts := []
	var src = t.get("do", t.get("actions", t.get("then", [])))
	if src is Dictionary or src is String:
		src = [src]
	for a in (src if src is Array else []):
		var ad: Dictionary = {"act": a} if a is String else (a if a is Dictionary else {})
		var act := _pick(ad.get("act", ad.get("action", ad.get("type", ""))), ACTIONS, "")
		if act == "" or acts.size() >= 6:
			continue
		var o := {"act": act}
		if ad.has("value") or ad.has("amount"):
			o.value = _r(_n(ad.get("value", ad.get("amount", 0)), -1000, 1000, 0))
		for k in ["text", "target", "template", "team"]:
			if ad.has(k):
				o[k] = _s(ad[k], 120 if k == "text" else 40)
		if ad.get("at") is Array or ad.get("to") is Array:
			o.at = _vec(ad.get("at", ad.get("to")), -half, half + 60, [0, 1, 0])
		if ad.has("count"):
			o.count = int(_n(ad.count, 1, 10, 1))
		acts.append(o)
	if acts.is_empty():
		return {}
	return {"on": on, "target": _s(t.get("target", t.get("id", "")), 40), "by": _s(t.get("by", "player"), 40).to_lower(),
		"value": _r(_n(t.get("value", t.get("count", t.get("seconds", 0))), 0, 9999, 0)), "once": not (t.get("once", true) is bool and not t.once), "do": acts}


## Entities whose id is name, or that carry tag name, in spec order (templates included).
static func find(s: Dictionary, name: String) -> Array:
	var out := []
	if name == "":
		return out
	for e in s.entities:
		if e.id == name:
			return [e]
	for e in s.entities:
		if e.tags.has(name):
			out.append(e)
	return out


# ---------------------------------------------------------------- old obby levels

## A 0.6/0.7 PloxLevel obby becomes a platformer spec that plays the same way.
static func from_level(lv: Dictionary) -> Dictionary:
	var ents := []
	var i := 0
	var skies := ["day", "sunset", "night", "candy", "storm"]
	var has_coin := false
	for p in lv.get("parts", []):
		if not (p is Array) or p.size() < 9:
			continue
		i += 1
		var k := str(p[0])
		var sz := [float(p[4]), float(p[5]), float(p[6])]
		var pos := [float(p[1]), float(p[2]) - sz[1] / 2.0, float(p[3])]
		var col: String = PloxLevel.COLORS[clampi(int(p[8]), 0, PloxLevel.COLORS.size() - 1)]
		var e := {"id": "p%d" % i, "shape": "box", "pos": pos, "size": sz, "rot": [0, float(p[7]), 0], "color": col, "mat": "plain", "behaviors": []}
		match k:
			"lava": e.mat = "lava"
			"ice": e.mat = "ice"
			"bounce":
				e.mat = "glow"
				e.behaviors.append({"type": "bounce", "power": 19})
			"spinner":
				e.behaviors.append({"type": "rotate", "speed": 92})
				e.behaviors.append({"type": "damage", "amount": 0, "knock": 14})
			"mover":
				e.behaviors.append({"type": "move", "path": [pos, [pos[0] + 4.0 * sin(deg_to_rad(float(p[7]))), pos[1], pos[2] + 4.0 * cos(deg_to_rad(float(p[7])))]], "speed": 3})
			"coin":
				e.shape = "star"
				e.solid = false
				e.behaviors.append({"type": "collect", "score": 1})
				e.behaviors.append({"type": "rotate", "speed": 120})
				has_coin = true
			"checkpoint":
				e.mat = "glow"
				e.behaviors.append({"type": "checkpoint"})
		ents.append(e)
	var g: Array = lv.get("goal", [0, 1, -20])
	ents.append({"id": "finish", "shape": "flag", "pos": [float(g[0]), float(g[1]) - 1.0, float(g[2])], "size": [1.2, 3, 1.2], "color": "#FFCA28", "solid": false})
	var sp: Array = lv.get("spawn", [0, 1, 0])
	var raw := {"v": V, "title": lv.get("title", "My game"), "intro": "Reach the golden flag!", "controls": "platformer",
		"world": {"size": 140, "floor": "none", "sky": skies[clampi(int(lv.get("sky", 0)), 0, 4)], "music": "happy"},
		"player": {"spawn": [float(sp[0]), float(sp[1]) - 1.0, float(sp[2])], "lives": 0}, "entities": ents,
		"rules": {"win": {"type": "reach", "target": "finish"}}, "hud": ["score"] if has_coin else []}
	var s := clean(raw, 999)
	s.erase("_notes")
	return s


## Game card info for old clients and lists.
static func card_parts(s: Dictionary) -> int:
	return s.get("entities", []).size()


static func card_sky(s: Dictionary) -> int:
	var i := ["day", "sunset", "night", "candy", "storm"].find(str(s.get("world", {}).get("sky", "day")))
	if i < 0:
		i = 2 if str(s.get("world", {}).get("sky", "")) in ["space", "spooky"] else 0
	return i


## One line for logs and tests.
static func summary(s: Dictionary) -> String:
	var shapes := {}
	var behs := {}
	for e in s.entities:
		shapes[e.shape] = int(shapes.get(e.shape, 0)) + 1
		for b in e.behaviors:
			behs[b.type] = int(behs.get(b.type, 0)) + 1
	return "%s | %s | win %s %s | lose %s | timer %d laps %d waves %d | abilities %s | sky %s floor %s | %d entities | behaviours %s | triggers %d" % [
		s.title, s.controls, s.rules.win.type, str(s.rules.win.value if s.rules.win.value > 0 else s.rules.win.target),
		",".join(PackedStringArray(s.rules.lose.map(func(l): return l.type))), s.rules.timer, s.rules.laps, s.rules.waves.size(),
		",".join(PackedStringArray(s.player.abilities)), s.world.sky, s.world.floor, s.entities.size(), JSON.stringify(behs), s.triggers.size()]
