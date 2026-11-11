class_name BallSim
extends RefCounted
## Server-side simulation of the magnetic neon balls. Only the referee runs
## this; phones just draw what it sends, so every phone sees the same balls.
##
## - Balls hunt players (magnetic pull). A player who has just spawned is
##   hunted by every ball for a few seconds.
## - When a ball catches a player it knocks them and explodes into smaller,
##   faster balls: giant -> 3 medium -> 3 small -> pop.
## - When few are left, fresh giant balls drop in from the ceiling.
##
## 0.6.0 performance rewrite (the stress test showed this was the free server's
## limit): 30 Hz steps instead of 60, packed arrays instead of dictionaries,
## cached block transforms with a cheap bounding-sphere test, and balls far from
## every player only move every third step. Same rules and the same messages.

const START_COUNT := 12
const MAX_BALLS := 48
const REFILL_BELOW := 6
const SPLIT_INTO := 3
const RADII := [1.4, 0.85, 0.5]           # by generation
const SPEED_CAP := [16.0, 22.0, 28.0]
const MAGNET_ACCEL := [7.0, 10.0, 13.0]
const SPLIT_SPEED := [0.0, 13.0, 17.0]    # launch speed of the pieces
const GRAVITY := 18.0
const RESTITUTION := 0.9
const MIN_BOUNCE := 7.0
const AIR_DRAG := 0.08
const PLAYER_RADIUS := 0.5
const HUNT_ON_SPAWN_S := 6.0
const BUMP_COOLDOWN_S := 0.6
const SPLIT_GRACE_S := 0.5     # new pieces can't hit anyone straight away
const STEP := 1.0 / 30.0
## Balls further than this from every player move every third step (3x the time).
const FAR_DIST := 20.0
const FAR_EVERY := 3

var wind := Vector2.ZERO
var gravity_sign := 1.0        # -1 while gravity is flipped
var steps_done := 0

var _id := PackedInt32Array()
var _gen := PackedInt32Array()
var _p := PackedVector3Array()
var _v := PackedVector3Array()
var _born := PackedFloat64Array()
var _far_left := PackedInt32Array()   # steps until a far ball moves again
var _far_dt := PackedFloat64Array()   # time it has saved up

var _solids: Array = []
var _half: Array = []          # Vector3 half sizes
var _brad := PackedFloat32Array()   # bounding radius of each block
var _xf: Array = []            # Transform3D per block
var _inv: Array = []           # inverse per block
var _accum := 0.0
var _time := 0.0
var _next_id := 1
var _hunt_id := -1
var _hunt_until := 0.0
var _bump_ready := {}   # player id -> time
var _rng := RandomNumberGenerator.new()


func _init(seed_value: int = 1) -> void:
	_rng.seed = seed_value
	_solids = WorldBuilder.solids()
	for s in _solids:
		var h: Vector3 = s[1] / 2.0
		_half.append(h)
		# Generous: the fold rotates the block about a hinge on its edge.
		_brad.append(h.length() + 0.6)
	_update_blocks(0.0)
	for i in range(START_COUNT):
		var angle := TAU * i / START_COUNT
		var r := 16.0 + 6.0 * (i % 2)
		_add(0, Vector3(cos(angle) * r, 4.0 + _rng.randf() * 6.0, sin(angle) * r),
			Vector3(_rng.randf_range(-3, 3), 0, _rng.randf_range(-3, 3)))


var balls: Array:
	get:
		var out := []
		for i in _id.size():
			out.append({"id": _id[i], "gen": _gen[i], "p": _p[i], "v": _v[i], "born": _born[i]})
		return out


func count() -> int:
	return _id.size()


func on_player_spawned(player_id: int) -> void:
	_hunt_id = player_id
	_hunt_until = _time + HUNT_ON_SPAWN_S


func forget_player(player_id: int) -> void:
	_bump_ready.erase(player_id)
	if _hunt_id == player_id:
		_hunt_id = -1


func _update_blocks(world_t: float) -> void:
	_xf.resize(_solids.size())
	_inv.resize(_solids.size())
	for i in range(_solids.size()):
		var xf := WorldBuilder.solid_transform(_solids[i], i, world_t)
		_xf[i] = xf
		_inv[i] = xf.affine_inverse()


## players: {id: feet Vector3}. world_t: referee clock in seconds (folds the blocks).
## Returns knocks to apply: [[id, Vector3 velocity], ...]
func advance(delta: float, players: Dictionary, world_t: float = 0.0) -> Array:
	var knocks := []
	_accum = minf(_accum + delta, 0.25)
	if _accum < STEP:
		return knocks
	_update_blocks(world_t)
	var ids := players.keys()
	var feet := PackedVector3Array()
	for id in ids:
		feet.append(players[id])
	while _accum >= STEP:
		_accum -= STEP
		_time += STEP
		_step(STEP, ids, feet, knocks)
		steps_done += 1
	return knocks


func _add(gen: int, p: Vector3, v: Vector3) -> void:
	_id.append(_next_id)
	_gen.append(gen)
	_p.append(p)
	_v.append(v)
	_born.append(_time)
	_far_left.append(0)
	_far_dt.append(0.0)
	_next_id += 1


func _remove(i: int) -> void:
	_id.remove_at(i)
	_gen.remove_at(i)
	_p.remove_at(i)
	_v.remove_at(i)
	_born.remove_at(i)
	_far_left.remove_at(i)
	_far_dt.remove_at(i)


func _step(dt: float, ids: Array, feet: PackedVector3Array, knocks: Array) -> void:
	var exploded := PackedInt32Array()
	var n := _id.size()
	var np := feet.size()
	var hunt := -1
	if _hunt_id != -1 and _time < _hunt_until:
		hunt = ids.find(_hunt_id)
	var gdrop := GRAVITY * gravity_sign
	var drag_keep := 1.0 - AIR_DRAG * dt
	var ns := _solids.size()
	for i in range(n):
		var gen: int = _gen[i]
		var r: float = RADII[gen]
		var p: Vector3 = _p[i]
		# Nearest player (also the magnet target unless someone just spawned)
		var best := -1
		var best_d := INF
		for k in range(np):
			var d2 := (feet[k] - p).length_squared()
			if d2 < best_d:
				best_d = d2
				best = k
		var sdt := dt
		if best_d > FAR_DIST * FAR_DIST and hunt == -1:
			# Nobody near: move this ball less often, with the time saved up.
			_far_dt[i] += dt
			if _far_left[i] > 0:
				_far_left[i] -= 1
				continue
			_far_left[i] = FAR_EVERY - 1
			sdt = _far_dt[i]
			_far_dt[i] = 0.0
		else:
			if _far_dt[i] > 0.0:
				sdt += _far_dt[i]
				_far_dt[i] = 0.0
			_far_left[i] = 0
		var target := hunt if hunt != -1 else best
		var v: Vector3 = _v[i]
		if target != -1:
			var to: Vector3 = feet[target] - p
			var fl := Vector2(to.x, to.z)
			if fl.length_squared() > 0.0001:
				fl = fl.normalized() * (MAGNET_ACCEL[gen] * sdt)
				v.x += fl.x
				v.z += fl.y
		var keep := 1.0 - AIR_DRAG * sdt if sdt != dt else drag_keep
		v.x = (v.x + wind.x * 0.5 * sdt) * keep
		v.z = (v.z + wind.y * 0.5 * sdt) * keep
		v.y -= gdrop * sdt
		v = v.limit_length(SPEED_CAP[gen])
		p += v * sdt
		var limit := Protocol.WORLD_HALF - r
		var top := Protocol.CEILING_Y - r
		if p.y < r:
			p.y = r
			v.y = maxf(absf(v.y) * RESTITUTION, MIN_BOUNCE if gravity_sign > 0.0 else 0.0)
		if p.y > top:
			p.y = top
			v.y = -maxf(absf(v.y) * RESTITUTION, MIN_BOUNCE if gravity_sign < 0.0 else 0.0)
		if absf(p.x) > limit:
			p.x = signf(p.x) * limit
			v.x = -v.x * RESTITUTION
		if absf(p.z) > limit:
			p.z = signf(p.z) * limit
			v.z = -v.z * RESTITUTION
		for si in range(ns):
			var xf: Transform3D = _xf[si]
			var reach: float = _brad[si] + r
			if (p - xf.origin).length_squared() > reach * reach:
				continue
			# Sphere vs folded (rotated) block, done in the block's own space
			var half: Vector3 = _half[si]
			var local: Vector3 = _inv[si] * p
			var closest := local.clamp(-half, half)
			var d := local - closest
			var dist := d.length()
			if dist < r:
				var nl := d / dist if dist > 0.0001 else Vector3.UP
				p = xf * (closest + nl * r)
				var nrm := (xf.basis * nl).normalized()
				var vn := v.dot(nrm)
				if vn < 0.0:
					v -= nrm * vn * (1.0 + RESTITUTION)
					if nrm.y * gravity_sign > 0.7:
						v.y = gravity_sign * maxf(absf(v.y), MIN_BOUNCE)
		# Catching a player: knock them and explode
		if best_d < 36.0 and _time - _born[i] > SPLIT_GRACE_S:
			var reach_h := r + PLAYER_RADIUS
			for k in range(np):
				var dp: Vector3 = p - feet[k] - Vector3(0, 1.0, 0)
				if dp.x * dp.x + dp.z * dp.z < reach_h * reach_h and absf(dp.y) < r + 1.0:
					var pid = ids[k]
					if _time >= float(_bump_ready.get(pid, 0.0)):
						_bump_ready[pid] = _time + BUMP_COOLDOWN_S
						var push := Vector2(-dp.x, -dp.z)
						push = push.normalized() if push.length() > 0.001 else Vector2(1, 0)
						knocks.append([pid, Vector3(push.x * Protocol.BUMP_SPEED, Protocol.BUMP_UP, push.y * Protocol.BUMP_SPEED)])
					exploded.append(i)
					break
		p.x = clampf(p.x, -limit, limit)
		p.z = clampf(p.z, -limit, limit)
		p.y = clampf(p.y, r, top)
		_p[i] = p
		_v[i] = v
	# Explosions (go backwards so indices stay valid)
	for k in range(exploded.size() - 1, -1, -1):
		var i := exploded[k]
		var gen: int = _gen[i] + 1
		var at: Vector3 = _p[i]
		_remove(i)
		if gen >= RADII.size():
			continue   # smallest ones just pop
		for m in range(SPLIT_INTO):
			if _id.size() >= MAX_BALLS:
				break
			var a := TAU * m / SPLIT_INTO + _rng.randf() * 0.6
			var dir := Vector3(cos(a), 0.9, sin(a)).normalized()
			_add(gen, at + Vector3(cos(a), 0.4, sin(a)) * RADII[gen], dir * SPLIT_SPEED[gen])
	# Ball vs ball (cheap x-gap test first)
	n = _id.size()
	for i in range(n):
		var pi: Vector3 = _p[i]
		var ri: float = RADII[_gen[i]]
		for j in range(i + 1, n):
			var pj: Vector3 = _p[j]
			var min_d: float = ri + RADII[_gen[j]]
			var dx := pj.x - pi.x
			if dx >= min_d or dx <= -min_d:
				continue
			var d := pj - pi
			var d2 := d.length_squared()
			if d2 >= min_d * min_d or d2 < 0.00000001:
				continue
			var dist := sqrt(d2)
			var nrm := d / dist
			var overlap := min_d - dist
			pi -= nrm * overlap * 0.5
			pj += nrm * overlap * 0.5
			_p[j] = pj
			var vi: Vector3 = _v[i]
			var vj: Vector3 = _v[j]
			var rel := (vj - vi).dot(nrm)
			if rel < 0.0:
				var impulse := nrm * rel * (1.0 + RESTITUTION) * 0.5
				_v[i] = vi + impulse
				_v[j] = vj - impulse
		# Keep everything inside the arena after pushes
		var lim := Protocol.WORLD_HALF - ri
		_p[i] = Vector3(clampf(pi.x, -lim, lim), clampf(pi.y, ri, Protocol.CEILING_Y - ri), clampf(pi.z, -lim, lim))
	# Refill with fresh giants dropping from the ceiling
	if _id.size() < REFILL_BELOW:
		while _id.size() < START_COUNT:
			var a := _rng.randf() * TAU
			var rr := _rng.randf_range(12.0, 30.0)
			_add(0, Vector3(cos(a) * rr, Protocol.CEILING_Y - 2.0, sin(a) * rr), Vector3.ZERO)


## Flat [id, x, y, z, gen, ...] rounded to centimetres.
func to_array() -> Array:
	var out := []
	out.resize(_id.size() * 5)
	for i in _id.size():
		var p: Vector3 = _p[i]
		var k := i * 5
		out[k] = _id[i]
		out[k + 1] = snappedf(p.x, 0.01)
		out[k + 2] = snappedf(p.y, 0.01)
		out[k + 3] = snappedf(p.z, 0.01)
		out[k + 4] = _gen[i]
	return out
