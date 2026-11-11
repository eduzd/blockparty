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
const STEP := 1.0 / 60.0

var balls: Array = []   # [{id, gen, p, v, born}]
var wind := Vector2.ZERO
var gravity_sign := 1.0        # -1 while gravity is flipped
var _solids: Array = []
var _xforms: Array = []
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
	_update_blocks(0.0)
	for i in range(START_COUNT):
		var angle := TAU * i / START_COUNT
		var r := 16.0 + 6.0 * (i % 2)
		_add(0, Vector3(cos(angle) * r, 4.0 + _rng.randf() * 6.0, sin(angle) * r),
			Vector3(_rng.randf_range(-3, 3), 0, _rng.randf_range(-3, 3)))


func on_player_spawned(player_id: int) -> void:
	_hunt_id = player_id
	_hunt_until = _time + HUNT_ON_SPAWN_S


func forget_player(player_id: int) -> void:
	_bump_ready.erase(player_id)
	if _hunt_id == player_id:
		_hunt_id = -1


func _update_blocks(world_t: float) -> void:
	_xforms.clear()
	for i in range(_solids.size()):
		_xforms.append(WorldBuilder.solid_transform(_solids[i], i, world_t))


## players: {id: feet Vector3}. world_t: referee clock in seconds (folds the blocks).
## Returns knocks to apply: [[id, Vector3 velocity], ...]
func advance(delta: float, players: Dictionary, world_t: float = 0.0) -> Array:
	var knocks := []
	_update_blocks(world_t)
	_accum = minf(_accum + delta, 0.25)
	while _accum >= STEP:
		_accum -= STEP
		_time += STEP
		_step(STEP, players, knocks)
	return knocks


func _add(gen: int, p: Vector3, v: Vector3) -> void:
	balls.append({"id": _next_id, "gen": gen, "p": p, "v": v, "born": _time})
	_next_id += 1


func _target_for(p: Vector3, players: Dictionary):
	if _hunt_id != -1 and _time < _hunt_until and players.has(_hunt_id):
		return players[_hunt_id]
	var best = null
	var best_d := INF
	for id in players:
		var d: float = (players[id] - p).length_squared()
		if d < best_d:
			best_d = d
			best = players[id]
	return best


func _step(dt: float, players: Dictionary, knocks: Array) -> void:
	var exploded := []   # indices
	for i in range(balls.size()):
		var b: Dictionary = balls[i]
		var gen: int = b.gen
		var r: float = RADII[gen]
		var limit := Protocol.WORLD_HALF - r
		var top := Protocol.CEILING_Y - r
		var v: Vector3 = b.v
		var p: Vector3 = b.p
		# Magnetic hunt (horizontal pull towards the target's body)
		var target = _target_for(p, players)
		if target != null:
			var to: Vector3 = target + Vector3(0, 1.0, 0) - p
			var flat := Vector2(to.x, to.z)
			if flat.length() > 0.01:
				flat = flat.normalized() * MAGNET_ACCEL[gen] * dt
				v.x += flat.x
				v.z += flat.y
		v.x += wind.x * 0.5 * dt
		v.z += wind.y * 0.5 * dt
		v.y -= GRAVITY * gravity_sign * dt
		v.x *= 1.0 - AIR_DRAG * dt
		v.z *= 1.0 - AIR_DRAG * dt
		v = v.limit_length(SPEED_CAP[gen])
		p += v * dt
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
		for si in range(_solids.size()):
			# Sphere vs folded (rotated) block, done in the block's own space
			var xf: Transform3D = _xforms[si]
			var half: Vector3 = _solids[si][1] / 2.0
			var local := xf.affine_inverse() * p
			var closest := local.clamp(-half, half)
			var d := local - closest
			var dist := d.length()
			if dist < r:
				var nl := d / dist if dist > 0.0001 else Vector3.UP
				p = xf * (closest + nl * r)
				var n := (xf.basis * nl).normalized()
				var vn := v.dot(n)
				if vn < 0.0:
					v -= n * vn * (1.0 + RESTITUTION)
					if n.y * gravity_sign > 0.7:
						v.y = gravity_sign * maxf(absf(v.y), MIN_BOUNCE)
		# Catching a player: knock them and explode
		if _time - float(b.born) > SPLIT_GRACE_S:
			for id in players:
				var body: Vector3 = players[id] + Vector3(0, 1.0, 0)
				var dp := p - body
				if Vector2(dp.x, dp.z).length() < r + PLAYER_RADIUS and absf(dp.y) < r + 1.0:
					if _time >= float(_bump_ready.get(id, 0.0)):
						_bump_ready[id] = _time + BUMP_COOLDOWN_S
						var push := Vector2(-dp.x, -dp.z)
						push = push.normalized() if push.length() > 0.001 else Vector2(1, 0)
						knocks.append([id, Vector3(push.x * Protocol.BUMP_SPEED, Protocol.BUMP_UP, push.y * Protocol.BUMP_SPEED)])
					exploded.append(i)
					break
		p.x = clampf(p.x, -limit, limit)
		p.z = clampf(p.z, -limit, limit)
		p.y = clampf(p.y, r, top)
		b.p = p
		b.v = v
	# Explosions (go backwards so indices stay valid)
	for k in range(exploded.size() - 1, -1, -1):
		var b: Dictionary = balls[exploded[k]]
		balls.remove_at(exploded[k])
		var gen: int = b.gen + 1
		if gen >= RADII.size():
			continue   # smallest ones just pop
		for n in range(SPLIT_INTO):
			if balls.size() >= MAX_BALLS:
				break
			var a := TAU * n / SPLIT_INTO + _rng.randf() * 0.6
			var dir := Vector3(cos(a), 0.9, sin(a)).normalized()
			_add(gen, b.p + Vector3(cos(a), 0.4, sin(a)) * RADII[gen], dir * SPLIT_SPEED[gen])
	# Ball vs ball
	for i in range(balls.size()):
		for j in range(i + 1, balls.size()):
			var bi: Dictionary = balls[i]
			var bj: Dictionary = balls[j]
			var min_d: float = RADII[bi.gen] + RADII[bj.gen]
			var d: Vector3 = bj.p - bi.p
			var dist := d.length()
			if dist < min_d and dist > 0.0001:
				var n := d / dist
				var overlap := min_d - dist
				bi.p -= n * overlap * 0.5
				bj.p += n * overlap * 0.5
				var rel: float = (bj.v - bi.v).dot(n)
				if rel < 0.0:
					var impulse: Vector3 = n * rel * (1.0 + RESTITUTION) * 0.5
					bi.v += impulse
					bj.v -= impulse
	# Keep everything inside the arena after pushes
	for b in balls:
		var r: float = RADII[b.gen]
		var limit := Protocol.WORLD_HALF - r
		var p: Vector3 = b.p
		b.p = Vector3(clampf(p.x, -limit, limit), clampf(p.y, r, Protocol.CEILING_Y - r), clampf(p.z, -limit, limit))
	# Refill with fresh giants dropping from the ceiling
	if balls.size() < REFILL_BELOW:
		while balls.size() < START_COUNT:
			var a := _rng.randf() * TAU
			var rr := _rng.randf_range(12.0, 30.0)
			_add(0, Vector3(cos(a) * rr, Protocol.CEILING_Y - 2.0, sin(a) * rr), Vector3.ZERO)


## Flat [id, x, y, z, gen, ...] rounded to centimetres.
func to_array() -> Array:
	var out := []
	for b in balls:
		var p: Vector3 = b.p
		out.append_array([b.id, snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01), b.gen])
	return out
