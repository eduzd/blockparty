class_name PloxSpecCheck
extends RefCounted
## Plux 0.8.0: checks a cleaned PloxSpec. problems() finds what would make the game
## broken or impossible (missing targets, an unreachable goal, too few coins, enemies
## nobody can beat). mechanics() checks the spec really uses what the player's prompt
## asked for (a race has a car and laps, a shooter has shooting and enemies...).
## Every problem is written as an instruction the AI can act on.


static func _foot(e: Dictionary, pad := 0.0) -> Array:
	var hx: float = e.size[0] / 2.0
	var hz: float = e.size[2] / 2.0
	var a := deg_to_rad(float(e.rot[1]))
	var ex: float = absf(cos(a)) * hx + absf(sin(a)) * hz + pad
	var ez: float = absf(sin(a)) * hx + absf(cos(a)) * hz + pad
	var r := [e.pos[0] - ex, e.pos[0] + ex, e.pos[2] - ez, e.pos[2] + ez]
	var mv = PloxSpec.beh(e, "move")
	if mv != null:
		for p in mv.path:
			r = [minf(r[0], p[0] - ex), maxf(r[1], p[0] + ex), minf(r[2], p[2] - ez), maxf(r[3], p[2] + ez)]
		if mv.has("offset"):
			var o: Array = mv.offset
			r = [minf(r[0], e.pos[0] + o[0] - ex), maxf(r[1], e.pos[0] + o[0] + ex), minf(r[2], e.pos[2] + o[2] - ez), maxf(r[3], e.pos[2] + o[2] + ez)]
	return r


static func _gap(a: Array, b: Array) -> float:
	var dx := maxf(0.0, maxf(a[0] - b[1], b[0] - a[1]))
	var dz := maxf(0.0, maxf(a[2] - b[3], b[2] - a[3]))
	return sqrt(dx * dx + dz * dz)


static func _deadly(e: Dictionary) -> bool:
	var d = PloxSpec.beh(e, "damage")
	return e.mat == "lava" or (d != null and d.kill)


static func _placed(s: Dictionary) -> Array:
	return s.entities.filter(func(e): return not e.template)


## Reachability model shared by every check. Returns {"surf": [...], "reached": {i: true}, "cells": {}, "grid": {...}}.
static func reach_model(s: Dictionary) -> Dictionary:
	var g := 24.0 * float(s.world.gravity)
	var ab: Array = s.player.abilities
	var vehicle: bool = s.controls == "vehicle"
	var v: float = s.player.jump if not vehicle else 0.0
	var speed: float = s.player.speed * (1.0 if not vehicle else 0.8)
	if ab.has("dash"):
		speed *= 1.25
	var up_max := v * v / (2.0 * g) * 0.92 * (1.85 if ab.has("double_jump") else 1.0)
	var step := maxf(0.55, up_max)
	var surf := []
	for e in _placed(s):
		if e.hidden or not e.solid or _deadly(e) or PloxSpec.beh(e, "chase") != null or PloxSpec.beh(e, "push") != null:
			continue
		if e.shape in ["coin", "gem", "star", "heart", "flag", "ghost", "character", "ring"]:
			continue
		var b = PloxSpec.beh(e, "bounce")
		surf.append({"e": e, "r": _foot(e), "top": e.pos[1] + e.size[1], "low": e.pos[1] if e.shape == "ramp" else e.pos[1] + e.size[1],
			"jv": maxf(v, b.power) if b != null else v})
	var half: float = s.world.size / 2.0
	var floor_ok: bool = s.world.floor == "ground"
	# Floor grid (walls block it), then surfaces, repeated until nothing new is reached.
	var cs := maxf(1.0, s.world.size / 80.0)
	var n := int(ceil(s.world.size / cs))
	var blocked := PackedByteArray()
	blocked.resize(n * n)
	if floor_ok:
		for e in _placed(s):
			if e.hidden or not e.solid or e.shape == "ramp" or PloxSpec.ACTORS.any(func(t): return PloxSpec.beh(e, t) != null) or PloxSpec.beh(e, "push") != null:
				if not (_deadly(e) and e.pos[1] < 0.6):
					continue
			if e.pos[1] > 0.9:
				continue
			var top: float = e.pos[1] + e.size[1]
			if top <= step and not _deadly(e):
				continue
			var r := _foot(e, 0.25)
			var a := deg_to_rad(float(e.rot[1]))
			var ca := cos(a)
			var sa := sin(a)
			for ix in range(maxi(0, int((r[0] + half) / cs)), mini(n, int((r[1] + half) / cs) + 1)):
				for iz in range(maxi(0, int((r[2] + half) / cs)), mini(n, int((r[3] + half) / cs) + 1)):
					var px := -half + (ix + 0.5) * cs - e.pos[0]
					var pz := -half + (iz + 0.5) * cs - e.pos[2]
					var lx := px * ca - pz * sa
					var lz := px * sa + pz * ca
					if e.shape in ["sphere", "cylinder", "tree", "rock", "tower", "barrel", "turret", "cone"]:
						if Vector2(lx, lz).length() <= maxf(e.size[0], e.size[2]) / 2.0 + 0.2:
							blocked[ix * n + iz] = 1
					elif absf(lx) <= e.size[0] / 2.0 + 0.2 and absf(lz) <= e.size[2] / 2.0 + 0.2:
						blocked[ix * n + iz] = 1
	var cells := {}
	var reached := {}
	var sp: Array = s.player.spawn
	var seeds := []
	var spawn_ok := false
	for i in surf.size():
		var r: Array = surf[i].r
		if sp[0] >= r[0] - 0.3 and sp[0] <= r[1] + 0.3 and sp[2] >= r[2] - 0.3 and sp[2] <= r[3] + 0.3 and sp[1] >= surf[i].top - 1.5 and sp[1] <= surf[i].top + 4.0:
			reached[i] = true
			spawn_ok = true
	if floor_ok and sp[1] < 4.0:
		spawn_ok = true
		seeds.append(Vector2i(clampi(int((sp[0] + half) / cs), 0, n - 1), clampi(int((sp[2] + half) / cs), 0, n - 1)))
	var queue := reached.keys()
	for round in 6:
		# floor flood
		var fq := seeds.duplicate()
		seeds.clear()
		while not fq.is_empty():
			var c: Vector2i = fq.pop_back()
			if c.x < 0 or c.y < 0 or c.x >= n or c.y >= n or cells.has(c) or blocked[c.x * n + c.y] == 1:
				continue
			cells[c] = true
			fq.append(c + Vector2i(1, 0)); fq.append(c + Vector2i(-1, 0)); fq.append(c + Vector2i(0, 1)); fq.append(c + Vector2i(0, -1))
		# floor -> surfaces
		if not cells.is_empty():
			for j in surf.size():
				if reached.has(j) or surf[j].low > step + 0.1:
					continue
				var r: Array = surf[j].r
				var hit := false
				for ix in range(maxi(0, int((r[0] - 1.5 + half) / cs)), mini(n, int((r[1] + 1.5 + half) / cs) + 1)):
					for iz in range(maxi(0, int((r[2] - 1.5 + half) / cs)), mini(n, int((r[3] + 1.5 + half) / cs) + 1)):
						if cells.has(Vector2i(ix, iz)):
							hit = true
							break
					if hit:
						break
				if hit:
					reached[j] = true
					queue.append(j)
		# surfaces -> surfaces
		while not queue.is_empty():
			var i: int = queue.pop_back()
			var a: Dictionary = surf[i]
			for j in surf.size():
				if reached.has(j):
					continue
				var b: Dictionary = surf[j]
				var rise: float = b.low - a.top
				var jv: float = a.jv
				var um: float = jv * jv / (2.0 * g) * 0.92 * (1.85 if ab.has("double_jump") else 1.0)
				if vehicle and b.low <= a.top + 0.6 and _gap(a.r, b.r) <= 1.2:
					reached[j] = true
					queue.append(j)
					continue
				if rise > maxf(um, 0.55):
					continue
				var disc := jv * jv - 2.0 * g * maxf(rise, -60.0)
				var t := (jv + sqrt(maxf(0.0, disc))) / g
				if _gap(a.r, b.r) <= maxf(0.6, speed * t * 0.85):
					reached[j] = true
					queue.append(j)
			# surface -> floor
			if floor_ok:
				var r: Array = a.r
				for ix in range(maxi(0, int((r[0] - 1.0 + half) / cs)), mini(n, int((r[1] + 1.0 + half) / cs) + 1)):
					for iz in [maxi(0, int((r[2] - 1.0 + half) / cs)), mini(n - 1, int((r[3] + 1.0 + half) / cs))]:
						if not cells.has(Vector2i(ix, iz)):
							seeds.append(Vector2i(ix, iz))
				for iz in range(maxi(0, int((r[2] - 1.0 + half) / cs)), mini(n, int((r[3] + 1.0 + half) / cs) + 1)):
					for ix in [maxi(0, int((r[0] - 1.0 + half) / cs)), mini(n - 1, int((r[1] + 1.0 + half) / cs))]:
						if not cells.has(Vector2i(ix, iz)):
							seeds.append(Vector2i(ix, iz))
		if seeds.is_empty():
			break
	return {"surf": surf, "reached": reached, "cells": cells, "cs": cs, "n": n, "half": half, "up": up_max, "spawn_ok": spawn_ok, "floor": floor_ok}


## Can the player touch entity e?
static func can_reach(m: Dictionary, e: Dictionary) -> bool:
	var r := _foot(e, 0.0)
	var bottom: float = e.pos[1]
	if m.floor and bottom <= m.up + 1.6:
		var half: float = m.half
		var cs: float = m.cs
		for ix in range(maxi(0, int((r[0] - 1.2 + half) / cs)), mini(m.n, int((r[1] + 1.2 + half) / cs) + 1)):
			for iz in range(maxi(0, int((r[2] - 1.2 + half) / cs)), mini(m.n, int((r[3] + 1.2 + half) / cs) + 1)):
				if m.cells.has(Vector2i(ix, iz)):
					return true
	for i in m.reached:
		var sf: Dictionary = m.surf[i]
		if sf.e == e:
			return true
		if _gap(sf.r, r) <= 1.2 and bottom <= sf.top + m.up + 1.6 and bottom + e.size[1] >= sf.top - 1.0:
			return true
	return false


static func _txt(e: Dictionary) -> String:
	return "'%s' at [%s, %s, %s]" % [e.id, e.pos[0], e.pos[1], e.pos[2]]


## Everything that makes the game broken or impossible, as instructions for the AI.
static func problems(s: Dictionary) -> Array:
	var p := []
	var placed := _placed(s)
	if placed.size() < 3:
		return ["The game has almost nothing in it. Add the entities the game needs (at least 10)."]
	var m := reach_model(s)
	if not m.spawn_ok:
		p.append("Nothing is under the player's spawn %s: the player falls into the void. Put the spawn on the ground (world.floor 'ground', spawn y 0) or right on top of a solid platform." % str(s.player.spawn))
	# references
	for e in s.entities:
		for b in e.behaviors:
			if b.type == "spawn" and PloxSpec.find(s, b.template).is_empty():
				p.append("%s spawns template '%s', but no entity has that id. Add it with \"template\": true." % [_txt(e), b.template])
	for w in s.rules.waves:
		if PloxSpec.find(s, w.template).is_empty():
			p.append("Wave template '%s' does not exist. Add an entity with id '%s' and \"template\": true (with chase and destructible behaviours)." % [w.template, w.template])
	for t in s.triggers:
		if t.on in ["touch", "collect", "destroyed"] and t.target != "" and PloxSpec.find(s, t.target).is_empty():
			p.append("Trigger on '%s' points at '%s', which no entity has as id or tag." % [t.on, t.target])
		if t.on == "touch" and t.target == "":
			p.append("A touch trigger has no target. Give it the id or tag of the entity to touch.")
		for a in t.do:
			if a.act in ["open", "remove", "show", "reset"] and PloxSpec.find(s, str(a.get("target", ""))).is_empty():
				p.append("Action '%s' targets '%s', which does not exist." % [a.act, str(a.get("target", ""))])
			if a.act == "spawn" and PloxSpec.find(s, str(a.get("template", ""))).is_empty():
				p.append("Action spawn uses template '%s', which does not exist." % str(a.get("template", "")))
	# win condition
	var w: Dictionary = s.rules.win
	var enemies := s.entities.filter(func(e): return e.tags.has("enemy"))
	match w.type:
		"reach":
			var t := PloxSpec.find(s, w.target)
			if t.is_empty():
				p.append("rules.win is 'reach' but target '%s' is not an entity id. Set win.target to the id of the finish (for example a 'flag')." % w.target)
			elif not t.any(func(e): return can_reach(m, e)):
				p.append("The player can't reach the finish %s from the spawn: %s Fix the route so every jump is possible (max rise %.1f m per jump, gaps under 4 m)." % [_txt(t[0]), _where(s, m), m.up])
		"laps":
			var cps: Array = s.rules.checkpoints
			if cps.size() < 2:
				p.append("A lap race needs rules.checkpoints: 3 to 8 entity ids placed in order around the loop (the last one is the start/finish line), each a wide invisible gate or arch the car drives through.")
			else:
				for id in cps:
					var ce := PloxSpec.find(s, id)
					if not ce.is_empty() and not can_reach(m, ce[0]):
						p.append("Checkpoint %s can't be reached from the start. Put every checkpoint on the drivable ground with nothing blocking the way." % _txt(ce[0]))
						break
				var a := PloxSpec.find(s, cps[0])
				var b := PloxSpec.find(s, cps[cps.size() - 1])
				if not a.is_empty() and not b.is_empty() and Vector2(a[0].pos[0] - b[0].pos[0], a[0].pos[2] - b[0].pos[2]).length() < 8.0:
					p.append("The checkpoints are bunched together. Spread them out around a long loop track (at least 12 m apart).")
		"score":
			var avail := _score_available(s, m)
			if avail >= 0 and avail < w.value:
				p.append("The win needs %d points but the player can only get %d (collectables they can reach + enemies/targets worth points). Add more reachable collectables (use \"repeat\" or \"circle\") or lower win.value." % [int(w.value), avail])
			if w.value <= 0:
				p.append("rules.win is 'score' but win.value is 0. Set it to the points needed.")
		"survive":
			if w.value <= 0:
				p.append("Set win.value to the seconds the player must survive.")
		"defeat_all", "waves":
			if enemies.is_empty() and s.rules.waves.is_empty():
				p.append("The win is '%s' but there are no enemies. Add enemies (chase + destructible) or rules.waves with an enemy template." % w.type)
			if w.type == "waves" and s.rules.waves.is_empty():
				p.append("The win is 'waves' but rules.waves is empty. Add 3 to 6 waves that grow in size.")
			var beatable := s.player.abilities.has("shoot") or s.world.floor != "ground" or s.entities.any(func(e): var sb = PloxSpec.beh(e, "shoot"); return sb != null and sb.target != "player")
			if not beatable:
				p.append("The player has no way to defeat the enemies. Give the player the 'shoot' ability (and the enemies 'destructible'), or make it a push-off over a void.")
			for e in enemies:
				if s.player.abilities.has("shoot") and PloxSpec.beh(e, "destructible") == null and s.world.floor == "ground":
					p.append("Enemy %s can't be defeated. Give it a 'destructible' behaviour." % _txt(e))
					break
		"collect_all":
			var cs := placed.filter(func(e): return PloxSpec.beh(e, "collect") != null)
			if cs.is_empty():
				p.append("The win is 'collect_all' but nothing has a 'collect' behaviour.")
			for e in cs:
				if not can_reach(m, e):
					p.append("Collectable %s can't be reached. Move it to where the player can get it." % _txt(e))
					break
		"trigger":
			if not s.triggers.any(func(t): return t.do.any(func(a): return a.act == "win")):
				p.append("The win is 'trigger' but no trigger has a {\"act\": \"win\"} action.")
	for l in s.rules.lose:
		if l.type == "time_up" and s.rules.timer <= 0:
			p.append("lose 'time_up' needs rules.timer (countdown seconds).")
		if l.type == "destroyed" and PloxSpec.find(s, l.target).is_empty():
			p.append("lose 'destroyed' needs target: the id of the thing to protect (give it 'destructible').")
		if l.type == "beaten" and not s.entities.any(func(e): return PloxSpec.beh(e, "race") != null):
			p.append("lose 'beaten' needs rival racers (entities with a 'race' behaviour).")
	if s.rules.timer > 0 and not s.rules.lose.any(func(l): return l.type == "time_up") and w.type != "survive":
		pass   # a stopwatch-style timer is fine
	return p


static func _score_available(s: Dictionary, m: Dictionary) -> int:
	var total := 0
	for e in _placed(s):
		var c = PloxSpec.beh(e, "collect")
		if c != null and can_reach(m, e):
			total += int(c.score)
		var d = PloxSpec.beh(e, "destructible")
		if d != null:
			total += int(d.score)
		if PloxSpec.beh(e, "spawn") != null:
			return -1
	if not s.rules.waves.is_empty():
		return -1
	for t in s.triggers:
		for a in t.do:
			if a.act == "score" and str(a.get("team", "")) != "enemy":
				if not t.once:
					return -1
				total += int(a.get("value", 1))
	return total


## Where the route breaks: the reachable surface closest to the finish.
static func _where(s: Dictionary, m: Dictionary) -> String:
	var t := PloxSpec.find(s, s.rules.win.target)
	if t.is_empty():
		return ""
	var best := INF
	var bi := -1
	var tr := _foot(t[0])
	for i in m.reached:
		var d := _gap(m.surf[i].r, tr)
		if d < best:
			best = d
			bi = i
	if bi < 0:
		return "nothing reachable is near it."
	var e: Dictionary = m.surf[bi].e
	return "the closest the player gets is %s (top at %.1f m), %.1f m away from it." % [_txt(e), m.surf[bi].top, best]


# ---------------------------------------------------------------- the prompt's mechanics

static func _has(w: String, words: Array) -> bool:
	for x in words:
		if w.contains(x):
			return true
	return false


static func _number_before(w: String, words: Array) -> int:
	var rx := RegEx.new()
	rx.compile("(\\d+)\\s*(" + "|".join(PackedStringArray(words)) + ")")
	var m := rx.search(w)
	return int(m.get_string(1)) if m != null else 0


## What the prompt asks for that the spec doesn't have, as fix instructions.
static func mechanics(s: Dictionary, prompt: String) -> Array:
	var w := " " + prompt.to_lower() + " "
	var p := []
	var ents: Array = _placed(s)
	var ab: Array = s.player.abilities
	var enemies := s.entities.filter(func(e): return e.tags.has("enemy"))
	var any_beh := func(t: String) -> bool: return s.entities.any(func(e): return PloxSpec.beh(e, t) != null)
	var car := _has(w, [" car", "kart", "drive", "driving", "vehicle", "truck", "racing car", "race car", "motorbike", "bike race"])
	var race := _has(w, ["race", "racing", " lap", "laps"]) and not _has(w, ["obby race", "parkour race", "foot race", "running race"])
	if car or (race and not _has(w, ["obby", "parkour", "run", "platform", "boat"])):
		if s.controls != "vehicle":
			p.append("The player asked for a driving/racing game: set \"controls\": \"vehicle\" so the player drives a car.")
	if race or _has(w, [" lap"]):
		var laps := _number_before(w, ["laps", "lap"])
		if s.rules.win.type != "laps" or s.rules.checkpoints.size() < 2:
			p.append("A race needs laps: rules.win {\"type\": \"laps\"}, rules.laps = %d, and rules.checkpoints listing 3-8 gate ids in order around a loop track." % maxi(laps, 3 if laps == 0 else laps))
		elif laps > 0 and s.rules.laps != laps:
			p.append("The player asked for %d laps: set rules.laps to %d." % [laps, laps])
		if s.rules.timer <= 0 and not any_beh.call("race"):
			p.append("A race needs pressure: add rival racers (entities with {\"type\": \"race\"} and lose {\"type\": \"beaten\"}) or a countdown rules.timer with lose time_up.")
	if _has(w, ["shoot", "shooter", "blaster", "gun", "laser", "fps"]):
		if not ab.has("shoot"):
			p.append("It's a shooter: add \"shoot\" to player.abilities.")
		if enemies.is_empty() and s.rules.waves.is_empty() and not ents.any(func(e): return PloxSpec.beh(e, "destructible") != null):
			p.append("A shooter needs things to shoot: enemies with chase + destructible, or rules.waves.")
	if _has(w, ["zombie", "monster", "enemies", "enemy", "alien", "robot army", "invader"]):
		if enemies.is_empty() and s.rules.waves.is_empty():
			p.append("The prompt has enemies: add enemy characters (shape 'character' or 'ghost') with a 'chase' behaviour targeting the player.")
	if _has(w, [" wave", "waves", "horde", "tower defense", "tower defence"]):
		if s.rules.waves.size() < 2:
			p.append("Add rules.waves: 3 to 6 waves of enemies that grow in count, spawning at the map edges.")
	if _has(w, ["tower defense", "tower defence", "defend", "protect"]):
		if not s.rules.lose.any(func(l): return l.type == "destroyed"):
			p.append("A defend game needs something to protect: an entity (e.g. id 'core', tag 'core') with 'destructible' hp 20, and rules.lose {\"type\": \"destroyed\", \"target\": \"core\"}. Enemies chase target 'core' with damage target 'core', die true.")
		if not ents.any(func(e): var sb = PloxSpec.beh(e, "shoot"); return sb != null and sb.target != "player") and not ab.has("shoot"):
			p.append("Add defence towers: shape 'turret' entities with {\"type\": \"shoot\", \"target\": \"enemy\"}, and/or give the player 'shoot'.")
	var ncoins := _number_before(w, ["coins", "coin", "stars", "gems", "diamonds", "candies", "apples", "items"])
	if _has(w, ["collect", "coins", "gems", "stars", "treasure"]):
		var have := 0
		for e in ents:
			if PloxSpec.beh(e, "collect") != null:
				have += 1
		if have == 0:
			p.append("The prompt is about collecting: add collectables (shape 'coin'/'gem'/'star' with a 'collect' behaviour).")
		if ncoins > 0 and (s.rules.win.type != "score" or int(s.rules.win.value) != ncoins):
			p.append("The player must collect %d: set rules.win {\"type\": \"score\", \"value\": %d} with each collectable worth 1." % [ncoins, ncoins])
		if ncoins > 0 and have < ncoins:
			p.append("Place at least %d collectables (now %d); add 20%% extra. Use \"repeat\" or \"circle\" copies." % [ncoins, have])
	if _has(w, ["time runs out", "timer", "countdown", "before time", "seconds", "time limit", "against the clock"]):
		if s.rules.timer <= 0:
			p.append("Add a countdown: rules.timer (seconds) and rules.lose [{\"type\": \"time_up\"}].")
		elif s.rules.win.type != "survive" and not s.rules.lose.any(func(l): return l.type == "time_up"):
			p.append("Add rules.lose {\"type\": \"time_up\"} so running out of time loses.")
	if _has(w, ["maze", "labyrinth"]):
		var walls := ents.filter(func(e): return e.shape == "box" and e.solid and e.size[1] >= 1.5 and e.pos[1] < 1.0)
		if walls.size() < 12:
			p.append("A maze needs walls: at least 15 tall box walls (height 3) forming corridors on the ground (use \"repeat\" for long walls).")
		if s.rules.win.type != "reach":
			p.append("A maze escape needs an exit: rules.win {\"type\": \"reach\", \"target\": the exit id}.")
	if _has(w, ["chasing", "chase", "chased", "hunted", "escaping", "escape from", "run from", "runs after"]):
		if not ents.any(func(e): var c = PloxSpec.beh(e, "chase"); return c != null and c.target == "player"):
			p.append("Something must chase the player: give the chaser {\"type\": \"chase\", \"target\": \"player\"} and {\"type\": \"damage\", \"amount\": 1}.")
	if _has(w, ["top-down", "top down", "topdown", "bird's eye", "birds eye"]) and s.controls != "topdown":
		p.append("The player asked for top-down: set \"controls\": \"topdown\".")
	if _has(w, ["side-view", "side view", "sideview", "side scroll", "side-scroll", "2d", "2-d", "mario"]) and s.controls != "side":
		p.append("The player asked for a side-view 2D-style game: set \"controls\": \"side\" and lay the level out along the X axis (z = 0).")
	if _has(w, ["first-person", "first person", "fps"]) and s.controls != "firstperson":
		p.append("The player asked for first person: set \"controls\": \"firstperson\".")
	if _has(w, ["sumo", "push-off", "push off", "knock off", "push each other", "push them off"]):
		if s.world.floor == "ground":
			p.append("A push-off needs a void: world.floor 'none' and one round arena platform (cylinder) the fighters can fall off.")
		if not ents.any(func(e): var d = PloxSpec.beh(e, "damage"); return d != null and d.knock > 0 and e.tags.has("enemy")):
			p.append("Add 3-5 sumo rivals: characters with chase target player and {\"type\": \"damage\", \"amount\": 0, \"knock\": 14}; the player needs the 'dash' ability to shove them; win defeat_all.")
	if _has(w, ["shrinking", "shrinks", "getting smaller"]) and not any_beh.call("shrink"):
		p.append("The platform must shrink: add {\"type\": \"shrink\", \"to\": 0.3, \"time\": 60} to it.")
	if _has(w, ["soccer", "football", "goal", "basketball", "hockey"]) and not _has(w, ["goal is", "the goal of"]):
		var ball := ents.any(func(e): return PloxSpec.beh(e, "push") != null)
		if not ball:
			p.append("A ball game needs a ball: a 'ball' entity (id 'ball', tag 'ball') with {\"type\": \"push\", \"mass\": 0.6, \"bounce\": 0.6}, and the player gets the 'kick' ability.")
		if not s.triggers.any(func(t): return t.on == "touch" and t.by != "player"):
			p.append("Scoring needs a goal trigger: an invisible box inside the goal and {\"on\": \"touch\", \"target\": goal zone id, \"by\": \"ball\", \"do\": [score 1, message GOAL!, reset ball]}.")
	if _has(w, ["rising lava", "lava rises", "rising floor", "floor rises", "rising water", "water rises", "flood"]):
		if not any_beh.call("rise"):
			p.append("The lava/water must rise: a huge flat box covering the map with mat 'lava' (or 'water' + damage kill) and {\"type\": \"rise\", \"speed\": 0.35}. Give the player platforms to climb.")
	if _has(w, ["obby", "parkour", "obstacle course"]):
		if not (s.controls in ["platformer", "side", "firstperson"]):
			p.append("An obby needs jumping: set \"controls\": \"platformer\".")
		if s.rules.win.type != "reach":
			p.append("An obby is won at a finish: rules.win {\"type\": \"reach\", \"target\": the finish flag id}.")
	if _has(w, ["double jump"]) and not ab.has("double_jump"):
		p.append("Add 'double_jump' to player.abilities.")
	return p


## Applies the admin's AI Agents object switches and object cap to a spec.
static func enforce_agent(s: Dictionary, agent: Dictionary) -> Dictionary:
	if agent.is_empty():
		return s
	var banned := AgentRules.banned_kinds(agent)
	for e in s.entities:
		if banned.has("lava") and e.mat == "lava":
			e.mat = "plain"
			e.color = "#8E24AA"
		if banned.has("ice") and e.mat == "ice":
			e.mat = "plain"
		if banned.has("coin") and e.shape == "star":
			e.shape = "gem"
		var keep := []
		for b in e.behaviors:
			if banned.has("bounce") and b.type == "bounce":
				continue
			if banned.has("spinner") and b.type == "rotate" and PloxSpec.beh(e, "damage") != null:
				continue
			if banned.has("mover") and b.type == "move" and e.solid and PloxSpec.beh(e, "damage") == null:
				continue
			keep.append(b)
		e.behaviors = keep
	return s
