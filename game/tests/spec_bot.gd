extends SceneTree
## Plux 0.8.0 headless autopilot for SpecPlay.
## godot --headless --fixed-fps 60 --path game -s tests/spec_bot.gd [-- name ...]
## Each case loads a sample game, drives the player (or stands still) and must end
## in the expected win or lose within its time limit.

const CASES := [
	# file, how the bot plays, expected result, seconds of game time allowed
	["lava_obby_level.json", "play", "win", 90.0],
	["candy_coins.json", "play", "win", 70.0],
	["candy_coins.json", "idle", "lose", 70.0],
	["ghost_maze.json", "play", "win", 90.0],
	["ghost_maze.json", "idle", "lose", 90.0],
]

var game: SpecPlay
var mode := ""
var path: Array = []        # platform route (entity records) for the obby
var path_i := 0
var stuck_t := 0.0
var last_pos := Vector3.ZERO


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var only: Array = OS.get_cmdline_user_args()
	var fails := 0
	for c in CASES:
		if not only.is_empty() and not only.has(str(c[0]).get_basename()):
			continue
		var ok: bool = await _case(c[0], c[1], c[2], c[3])
		if not ok:
			fails += 1
	print("SPEC_BOT DONE fails=%d" % fails)
	quit(1 if fails > 0 else 0)


func _load(file: String) -> Dictionary:
	var raw = JSON.parse_string(FileAccess.get_file_as_string("res://tests/specs/" + file))
	if raw is Dictionary and raw.has("parts"):
		return PloxSpec.from_level(PloxLevel.clean(raw))   # a 0.7 obby, converted like the server will
	var s := PloxSpec.clean(raw)                 # same limits as an AI game
	s.erase("_notes")
	return s


func _case(file: String, how: String, want: String, limit: float) -> bool:
	var spec := _load(file)
	print("CASE %s (%s) | %s" % [file, how, PloxSpec.summary(spec)])
	game = SpecPlay.new()
	game.setup(spec, "", false, "Bot")
	root.add_child(game)
	mode = how
	path = []
	path_i = 0
	stuck_t = 0.0
	var deaths := 0
	var last_lives := game.lives
	var frames := int(limit * 60.0)
	var notes := []
	for f in frames:
		await physics_frame
		if game.done:
			break
		if how == "play":
			_drive(1.0 / 60.0)
		if OS.get_environment("SPEC_DEBUG") != "" and f % 60 == 0:
			var gh = game._by_id.get("ghost", {})
			print("  ghost=%s" % (str((gh.node as Node3D).global_position.snapped(Vector3(0.1,0.1,0.1))) if not gh.is_empty() and gh.alive else "-"))
			print("  t=%d pos=%s floor=%s path_i=%d/%d dir=%s" % [f / 60, str(game.player.global_position.snapped(Vector3(0.1,0.1,0.1))), game.player.is_on_floor(), path_i, path.size(), str(game.bot_dir.snapped(Vector3(0.1,0.1,0.1)))])
		if game._toast_t > 0.9 and game._toast_t < 0.95 + 1.0 / 60.0 and OS.get_environment("SPEC_DEBUG") != "":
			print("  toast@%.1f %s" % [game.elapsed, game._toast.text])
		if game._toast_t > 1.7 and not notes.has(game._toast.text):
			notes.append(game._toast.text)
	var got := "none"
	if game.done:
		got = "win" if game.won else "lose"
	var ok := got == want
	print("RESULT %s %s: %s (%s) after %.1f s, score %d, lives %d, toasts %s -> %s" % [file, how, got, game.result_reason, game.elapsed, game.score, game.lives, str(notes), "PASS" if ok else "FAIL"])
	root.remove_child(game)
	game.free()
	return ok


# ---------------------------------------------------------------- driving

func _drive(delta: float) -> void:
	var p := game.player.global_position
	var target := Vector3.ZERO
	var w: Dictionary = game.spec.rules.win
	if str(game.spec.world.floor) == "none":
		_drive_platforms(delta)
		return
	# Ground games: walk the grid around walls to the nearest coin, else the goal.
	var best := INF
	var want_coins: bool = w.type in ["score", "collect_all"]
	for r in game.ents:
		if not r.alive or r.hidden:
			continue
		var is_t: bool = (want_coins and r.collect != null and int(r.collect.score) > 0) or (not want_coins and game._goal_entities().has(r))
		if is_t:
			var d := p.distance_to((r.node as Node3D).global_position)
			if d < best:
				best = d
				target = (r.node as Node3D).global_position
	if best == INF:
		game.bot_dir = Vector3.ZERO
		return
	game.bot_dir = _grid_dir(p, target)
	# Unstick: hop when we have not moved for a second.
	if p.distance_to(last_pos) < 0.02:
		stuck_t += delta
	else:
		stuck_t = 0.0
	last_pos = p
	if stuck_t > 1.0 and float(game.spec.player.jump) > 0.0:
		game.bot_jump = true
		stuck_t = 0.0


## BFS on the SpecPlay wall grid from the target back to us; first step direction.
func _grid_dir(from: Vector3, to: Vector3, avoid := true) -> Vector3:
	var a := game._cell(from)
	var b := game._cell(to)
	if a == b:
		return Vector3(to.x - from.x, 0, to.z - from.z).normalized()
	var blocked: Dictionary = game._blocked
	# Walls already cover every cell they touch (up to 0.6 m extra), so no inflation.
	var danger := {}
	for r in game.ents:
		if avoid and r.alive and r.actor and r.beh.has("damage"):
			var gc := game._cell((r.node as Node3D).global_position)
			for dx in range(-3, 4):
				for dz in range(-3, 4):
					danger[gc + Vector2i(dx, dz)] = true
	var near := func(c: Vector2i) -> bool:
		if blocked.has(c) or (danger.has(c) and c.distance_to(a) > 1.5):
			return true
		return false
	var dist := {b: 0}
	var q: Array[Vector2i] = [b]
	var i := 0
	var lim := int(floor(game._half / game.GRID))
	while i < q.size() and not dist.has(a):
		var c: Vector2i = q[i]
		i += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if dist.has(n) or n.x < -lim or n.x >= lim or n.y < -lim or n.y >= lim:
				continue
			if n != a and near.call(n):
				continue
			dist[n] = int(dist[c]) + 1
			q.append(n)
	if not dist.has(a) and avoid:
		return _grid_dir(from, to, false)     # the ghost sits on the only way: go anyway
	if not dist.has(a):
		if OS.get_environment("SPEC_DEBUG") != "" and Engine.get_physics_frames() % 60 == 0:
			print("  no grid path from ", a, " to ", b, " visited ", dist.size())
			if Engine.get_physics_frames() < 70:
				for z in range(-21, 21):
					var l := ""
					for x in range(-21, 21):
						var c := Vector2i(x, z)
						l += "A" if c == a else ("B" if c == b else ("#" if blocked.has(c) else ("g" if danger.has(c) else ("o" if dist.has(c) else "."))))
					print(l)
		return Vector3(to.x - from.x, 0, to.z - from.z).normalized()
	# Look a few cells ahead along the descent for a smoother line.
	var cur := a
	for step in 2:
		var nxt := cur
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if dist.has(n) and int(dist[n]) < int(dist.get(nxt, 1 << 30)):
				nxt = n
		if nxt == cur:
			break
		cur = nxt
		if step == 0 and dist.get(cur, 0) == 0:
			break
	var tp := Vector3((cur.x + 0.5) * game.GRID, from.y, (cur.y + 0.5) * game.GRID)
	return Vector3(tp.x - from.x, 0, tp.z - from.z).normalized()


# ---------------------------------------------------------------- obby (no floor)

func _top_box(r: Dictionary) -> AABB:
	var n: Node3D = r.node
	var s: Vector3 = r.size
	return n.global_transform * AABB(Vector3(-s.x / 2.0, 0, -s.z / 2.0), s)


func _standable(r: Dictionary) -> bool:
	return r.alive and r.d.solid and not r.actor and str(r.d.mat) != "lava" and not r.beh.has("move") and not r.beh.has("rotate") and float(r.size.x) >= 1.5 and float(r.size.z) >= 1.5


func _gap(a: AABB, b: AABB) -> float:
	var dx := maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dz := maxf(0.0, maxf(a.position.z - b.end.z, b.position.z - a.end.z))
	return Vector2(dx, dz).length()


func _support() -> Dictionary:
	var p := game.player.global_position
	var space := game.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 0.5, 0), p + Vector3(0, -1.5, 0), 1)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	return game._by_id.get(str((hit.collider as Node).name), {})


func _plan_route(start: Dictionary) -> void:
	var goals := game._goal_entities()
	if goals.is_empty():
		return
	var gpos: Vector3 = (goals[0].node as Node3D).global_position
	var nodes := []
	for r in game.ents:
		if _standable(r) or (r.alive and r.beh.has("bounce")):
			nodes.append(r)
	var prev := {}
	var seen := {start.d.id: true}
	var q := [start]
	var end := {}
	while not q.is_empty():
		var c: Dictionary = q.pop_front()
		var cb := _top_box(c)
		if cb.grow(1.0).has_point(Vector3(gpos.x, cb.end.y, gpos.z)):
			end = c
			break
		var up_max := 7.0 if c.beh.has("bounce") else 1.4
		for n in nodes:
			if seen.has(n.d.id):
				continue
			var nb := _top_box(n)
			if _gap(cb, nb) <= 3.6 and nb.end.y - cb.end.y <= up_max:
				seen[n.d.id] = true
				prev[n.d.id] = c
				q.append(n)
	path = []
	if end.is_empty():
		return
	var cur: Dictionary = end
	while true:
		path.push_front(cur)
		if not prev.has(cur.d.id):
			break
		cur = prev[cur.d.id]
	path_i = 0
	if OS.get_environment("SPEC_DEBUG") != "":
		print("  route ", path.map(func(r): return "%s@%s" % [r.d.id, str(_top_box(r).get_center())]))


func _safe_below(at: Vector3) -> bool:
	var space := game.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(at + Vector3(0, 1.0, 0), at + Vector3(0, -2.5, 0), 1)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return false
	var r: Dictionary = game._by_id.get(str((hit.collider as Node).name), {})
	return r.is_empty() or str(r.d.mat) != "lava"


func _drive_platforms(_delta: float) -> void:
	var pl := game.player
	var p := pl.global_position
	var sup := _support() if pl.is_on_floor() else {}
	if not sup.is_empty():
		var idx := -1
		for i in path.size():
			if path[i].d.id == sup.d.id:
				idx = i
		if idx < 0:
			_plan_route(sup)       # first frame, or knocked/respawned somewhere new
			idx = 0
		path_i = idx
	# Over the next platform already (e.g. bouncing on a jump pad): aim past it.
	if path_i + 1 < path.size():
		var nb0 := _top_box(path[path_i + 1])
		if nb0.grow(0.3).has_point(Vector3(p.x, nb0.get_center().y, p.z)) and p.y >= nb0.end.y - 0.3:
			if path[path_i + 1].beh.has("bounce"):
				path_i += 1
			elif not pl.is_on_floor():
				# Coming down onto it: brake over its middle so we do not overshoot.
				var c0 := nb0.get_center()
				var v0 := Vector3(c0.x - p.x, 0, c0.z - p.z)
				game.bot_dir = v0.normalized() if v0.length() > 0.8 else Vector3.ZERO
				return
	var goal := game._goal_entities()
	var target: Vector3
	var next_top := p.y
	if path_i + 1 < path.size():
		var nb := _top_box(path[path_i + 1])
		target = nb.get_center()
		next_top = nb.end.y
	elif not goal.is_empty():
		target = (goal[0].node as Node3D).global_position
	else:
		game.bot_dir = Vector3.ZERO
		return
	var dir := Vector3(target.x - p.x, 0, target.z - p.z)
	var flat := dir.length()
	dir = dir.normalized()
	# Line up with the next platform's centre line first (avoid falling off sides).
	if not sup.is_empty() and path_i + 1 < path.size():
		var cb := _top_box(sup)
		var ahead := p + dir * 1.0
		if not _safe_below(ahead) and pl.is_on_floor():
			game.bot_jump = true
		elif next_top - p.y > 0.6 and flat < 3.0 and pl.is_on_floor():
			game.bot_jump = true
		if cb.size.x < 0.1:
			pass
	game.bot_dir = dir
