class_name PopRoom
extends RefCounted
## The referee's side of one Pop-Up Panic room: the round clock, scores, who bonked
## whom, knockouts and the bots. Kept deliberately light: no physics engine, just a
## few vectors per bot at 30 steps a second, and hit checks only when someone bonks.

const BOT_HZ := 30.0

var code := ""
var humans := {}        # id -> the referee's client Dictionary (shared reference)
var bots := {}          # id -> Dictionary
var scores := {}        # id -> knockouts this round
var names := {}         # id -> name (for results after someone leaves)
var meta := {}          # id -> {hits, last_by, last_at, shield_until, bonk_at}
var phase := "play"     # play | results
## 0.6.0: round length from the live config (0 = the default), and a hook the
## referee uses to pay Plux when a round ends: (scores {id: kos}, human ids).
var round_len_s := 0.0
var on_round_end: Callable
var phase_end_ms := 0
var round_no := 1
var want_bots := 0      # how many bots the room keeps around (from the host's choice)
var rng := RandomNumberGenerator.new()
var _accum := 0.0
var _used_names := {}

## Callbacks set by the referee.
var broadcast: Callable   # (data: Dictionary)
var send_to: Callable     # (id: int, data: Dictionary)
var respawn_human: Callable   # (id: int, pos: Vector3)
var knock_human: Callable     # (id: int, v: Vector3)
var new_id: Callable          # () -> int


func _init(p_code: String, now_ms: int) -> void:
	code = p_code
	rng.seed = hash(p_code) ^ now_ms
	phase_end_ms = now_ms + int(round_s() * 1000.0)


## Round length; tests can shorten it with POP_ROUND_S.
static func round_s() -> float:
	if OS.has_environment("POP_ROUND_S"):
		return maxf(float(OS.get_environment("POP_ROUND_S")), 10.0)
	return PopRules.ROUND_S


func is_empty() -> bool:
	return humans.is_empty()


func entity_count() -> int:
	return humans.size() + bots.size()


func round_info(now_ms: int) -> Dictionary:
	return {"ph": phase, "end": phase_end_ms, "n": round_no, "now": now_ms}


func score_list() -> Array:
	var out := []
	for id in scores:
		out.append([id, int(scores[id])])
	return out


func _meta_for(id: int) -> Dictionary:
	if not meta.has(id):
		meta[id] = {"hits": 0, "last_by": -1, "last_at": 0, "shield_until": 0, "bonk_at": 0}
	return meta[id]


# ------------------------------------------------------------------ people

func add_human(c: Dictionary, now_ms: int) -> void:
	humans[c.id] = c
	names[c.id] = c.name
	scores[c.id] = int(scores.get(c.id, 0))
	var m := _meta_for(c.id)
	m.shield_until = now_ms + int(PopRules.SHIELD_S * 1000.0)
	# A human takes a bot's seat when the room is full.
	while entity_count() > Protocol.MAX_PLAYERS_PER_ROOM and not bots.is_empty():
		remove_bot(bots.keys()[bots.size() - 1])


func remove_human(id: int) -> void:
	humans.erase(id)
	meta.erase(id)
	scores.erase(id)
	for m in meta.values():
		if int(m.last_by) == id:
			m.last_by = -1
	fill_bots()


## Keeps `want_bots` bots in the room while there is space.
func fill_bots() -> Array:
	var added := []
	if humans.is_empty():
		return added
	while bots.size() < want_bots and entity_count() < Protocol.MAX_PLAYERS_PER_ROOM:
		added.append(add_bot())
	return added


func add_bot() -> Dictionary:
	var id: int = new_id.call()
	var nm := ""
	for n in PopRules.BOT_NAMES:
		if not _used_names.has(n):
			nm = n
			break
	if nm == "":
		nm = "Bot%d" % (id % 100)
	_used_names[nm] = true
	var b := {
		"id": id, "name": nm, "ch": rng.randi_range(0, PopRules.CHARACTERS.size() - 1),
		"pos": PopRules.random_spawn(rng), "vel": Vector3.ZERO, "knock": Vector3.ZERO, "yaw": rng.randf() * TAU,
		"target": -1, "retarget": 0.0, "cd": 1.0, "think": 0.0, "out_until": 0, "grounded": false,
		"arm_immune": 0.0, "skill": rng.randf_range(0.55, 0.9), "wander": rng.randf() * TAU,
	}
	bots[id] = b
	names[id] = nm
	scores[id] = 0
	_meta_for(id).shield_until = Time.get_ticks_msec() + int(PopRules.SHIELD_S * 1000.0)
	if broadcast.is_valid():
		broadcast.call({"t": "join", "p": describe_bot(b)})
	return b


func remove_bot(id: int) -> void:
	if not bots.has(id):
		return
	_used_names.erase(bots[id].name)
	bots.erase(id)
	scores.erase(id)
	meta.erase(id)
	if broadcast.is_valid():
		broadcast.call({"t": "leave", "id": id})


func describe_bot(b: Dictionary) -> Dictionary:
	return {"id": b.id, "name": b.name, "c": int(b.ch), "ch": int(b.ch), "bot": true,
		"p": Protocol.vec_to_array(b.pos), "y": snappedf(b.yaw, 0.01)}


func bot_snapshot_entries() -> Array:
	var out := []
	for b in bots.values():
		var p: Vector3 = b.pos
		out.append([b.id, snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01), snappedf(wrapf(b.yaw, -PI, PI), 0.01)])
	return out


# ------------------------------------------------------------------ positions

func _pos_of(id: int):
	if humans.has(id):
		return humans[id].pos
	if bots.has(id):
		return bots[id].pos
	return null


func _yaw_of(id: int) -> float:
	if humans.has(id):
		return float(humans[id].yaw)
	if bots.has(id):
		return float(bots[id].yaw)
	return 0.0


## The facing direction for a yaw, matching the phone's avatar (yaw 0 faces -Z).
static func yaw_dir(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))


# ------------------------------------------------------------------ bonks

## Someone swung their spring-head. Returns false when it was too soon.
func bonk(attacker: int, yaw: float, now_ms: int) -> bool:
	var am := _meta_for(attacker)
	if now_ms - int(am.bonk_at) < int(PopRules.BONK_COOLDOWN_S * 1000.0) - 80:
		return false
	am.bonk_at = now_ms
	var from = _pos_of(attacker)
	if from == null:
		return false
	if humans.has(attacker):
		humans[attacker].yaw = yaw
	var dir := yaw_dir(yaw)
	var hit := []
	for id in humans.keys() + bots.keys():
		if id == attacker:
			continue
		var p = _pos_of(id)
		var m := _meta_for(id)
		if now_ms < int(m.shield_until):
			continue
		var d: Vector3 = p - from
		if absf(d.y) > 1.9:
			continue
		var flat := Vector2(d.x, d.z)
		# A little extra reach on the server for the network delay.
		if flat.length() > PopRules.BONK_RANGE + 0.45:
			continue
		if flat.length() > 0.35 and flat.normalized().dot(dir) < PopRules.BONK_CONE:
			continue
		var away := flat.normalized() if flat.length() > 0.05 else dir
		var mult := PopRules.wobble_mult(int(m.hits))
		var v := Vector3(away.x, 0.0, away.y) * PopRules.BONK_PUSH * mult + Vector3.UP * PopRules.BONK_UP * minf(mult, 1.6)
		m.hits = int(m.hits) + 1
		m.last_by = attacker
		m.last_at = now_ms
		if bots.has(id):
			bots[id].knock = Vector3(v.x, 0.0, v.z)
			bots[id].vel.y = v.y
			bots[id].grounded = false
			bots[id].think = 0.5   # dazed for a moment
		elif knock_human.is_valid():
			knock_human.call(id, v)
		hit.append(id)
	if broadcast.is_valid():
		broadcast.call({"t": "bonk", "id": attacker, "y": snappedf(yaw, 0.01), "hit": hit})
	return true


## Someone fell off the table. Credits the last bonker if it was recent.
func knocked_out(id: int, now_ms: int) -> void:
	var m := _meta_for(id)
	var by := int(m.last_by)
	if by == id or now_ms - int(m.last_at) > int(PopRules.CREDIT_S * 1000.0) or not scores.has(by):
		by = -1
	if by >= 0 and phase == "play":
		scores[by] = int(scores[by]) + 1
	m.hits = 0
	m.last_by = -1
	m.shield_until = now_ms + int((PopRules.SHIELD_S + 1.2) * 1000.0)
	if broadcast.is_valid():
		broadcast.call({"t": "ko", "id": id, "by": by, "s": int(scores.get(by, 0)) if by >= 0 else 0})


## A human landed safely on the table: their wobble meter resets.
func landed(id: int) -> void:
	var m := _meta_for(id)
	if int(m.hits) > 0 and Time.get_ticks_msec() - int(m.last_at) > 1500:
		m.hits = 0


# ------------------------------------------------------------------ clock

func tick(delta: float, now_ms: int) -> void:
	if humans.is_empty():
		return
	if now_ms >= phase_end_ms:
		if phase == "play":
			phase = "results"
			phase_end_ms = now_ms + int(PopRules.RESULTS_S * 1000.0)
			if on_round_end.is_valid():
				on_round_end.call(scores.duplicate(), humans.keys())
			broadcast.call({"t": "round", "r": round_info(now_ms), "sc": score_list(), "names": _names_for_scores()})
		else:
			phase = "play"
			round_no += 1
			phase_end_ms = now_ms + int((round_len_s if round_len_s >= 10.0 and not OS.has_environment("POP_ROUND_S") else round_s()) * 1000.0)
			for id in scores:
				scores[id] = 0
			for id in meta:
				meta[id].hits = 0
				meta[id].last_by = -1
				meta[id].shield_until = now_ms + int(PopRules.SHIELD_S * 1000.0)
			for id in humans:
				if respawn_human.is_valid():
					respawn_human.call(id, PopRules.random_spawn(rng))
			for b in bots.values():
				b.pos = PopRules.random_spawn(rng)
				b.vel = Vector3.ZERO
				b.knock = Vector3.ZERO
			broadcast.call({"t": "round", "r": round_info(now_ms), "sc": score_list()})
	_accum += delta
	var step := 1.0 / BOT_HZ
	var n := 0
	while _accum >= step and n < 4:
		_accum -= step
		n += 1
		for b in bots.values():
			_step_bot(b, step, now_ms)
	if n == 4:
		_accum = 0.0


func _names_for_scores() -> Dictionary:
	var out := {}
	for id in scores:
		out[str(id)] = str(names.get(id, "Player"))
	return out


# ------------------------------------------------------------------ bots

func _frenzy(now_ms: int) -> float:
	return PopRules.frenzy_amount(float(phase_end_ms - now_ms) / 1000.0, phase == "play")


func _step_bot(b: Dictionary, dt: float, now_ms: int) -> void:
	var p: Vector3 = b.pos
	if now_ms < int(b.out_until):
		return
	if int(b.out_until) > 0:
		b.out_until = 0
		p = PopRules.random_spawn(rng)
		b.vel = Vector3.ZERO
		b.knock = Vector3.ZERO
	b.cd = maxf(float(b.cd) - dt, 0.0)
	b.think = maxf(float(b.think) - dt, 0.0)
	b.arm_immune = maxf(float(b.arm_immune) - dt, 0.0)
	b.retarget = float(b.retarget) - dt
	var t := now_ms / 1000.0
	var flat := Vector2(p.x, p.z)
	var dist_c := flat.length()

	# Pick someone to chase: humans a bit more often, so solo play is lively.
	if b.retarget <= 0.0 or not (humans.has(int(b.target)) or bots.has(int(b.target))):
		b.retarget = rng.randf_range(2.5, 5.0)
		var best := -1
		var best_score := INF
		for id in humans.keys() + bots.keys():
			if id == b.id:
				continue
			var q = _pos_of(id)
			if q.y < -1.0 or not PopRules.on_table(q):
				continue
			var s: float = (q - p).length() * (0.6 if humans.has(id) else 1.0) + rng.randf() * 4.0
			if s < best_score:
				best_score = s
				best = id
		b.target = best

	var want := Vector2.ZERO
	if b.think <= 0.0:
		var tp = _pos_of(int(b.target))
		if tp != null:
			var to := Vector2(tp.x - p.x, tp.z - p.z)
			if to.length() > 1.6:
				want = to.normalized()
			else:
				want = to.normalized() * 0.3
			# Swing when close and roughly facing them.
			if to.length() < PopRules.BONK_RANGE - 0.3 and b.cd <= 0.0 and absf(tp.y - p.y) < 1.5 and rng.randf() < 0.18 * float(b.skill):
				b.yaw = atan2(-to.x, -to.y)
				b.cd = PopRules.BONK_COOLDOWN_S + rng.randf_range(0.2, 0.9)
				bonk(b.id, b.yaw, now_ms)
		else:
			b.wander = float(b.wander) + rng.randf_range(-1.0, 1.0) * dt
			want = Vector2.from_angle(b.wander) * 0.6
		# Stay away from the edge.
		if dist_c > PopRules.ARENA_R - 2.6:
			var inward := -flat.normalized()
			if want.dot(-inward) > 0.0:
				want = want - (-inward) * want.dot(-inward) * 1.2
			want += inward * (dist_c - (PopRules.ARENA_R - 2.6)) * 0.8
		want = want.limit_length(1.0)

	# Hop over the spoon when it's coming.
	if b.grounded:
		var a := PopRules.spoon_angle(t)
		var arms := [a]
		if _frenzy(now_ms) >= 0.99:
			arms.append(a + PI)
		var my_a := atan2(p.z, p.x)
		for arm in arms:
			var ahead := fposmod(my_a - arm, TAU)   # how far the arm still has to turn to reach me
			var arc := ahead * maxf(dist_c, 1.0)
			var speed := PopRules.SPOON_SPEED * maxf(dist_c, 1.0)
			if dist_c > PopRules.HUB_R and arc / speed < 0.22 + (1.0 - float(b.skill)) * 0.25 and arc / speed > 0.05:
				if rng.randf() < 0.55 + 0.4 * float(b.skill):
					b.vel.y = PopRules.HOP_VELOCITY
					b.grounded = false
				break

	# Move.
	var speed_k := 0.78 if b.think <= 0.0 else 0.25
	var target_v := want * PopRules.MOVE_SPEED * speed_k
	var hv := Vector2(b.vel.x, b.vel.z).move_toward(target_v, PopRules.ACCEL * 0.7 * dt)
	var kn: Vector3 = b.knock
	kn = kn * exp(-PopRules.KNOCK_DECAY * dt)
	b.knock = kn
	b.vel = Vector3(hv.x, float(b.vel.y), hv.y)
	if not b.grounded:
		b.vel.y -= PopRules.GRAVITY * dt
	p += (b.vel + kn) * dt
	# Table top, hub post, bounce pads.
	var f2 := Vector2(p.x, p.z)
	if f2.length() < PopRules.HUB_R + PopRules.BODY_R and p.y < 2.0:
		f2 = f2.normalized() * (PopRules.HUB_R + PopRules.BODY_R) if f2.length() > 0.01 else Vector2(PopRules.HUB_R + PopRules.BODY_R, 0)
		p.x = f2.x
		p.z = f2.y
	if PopRules.on_table(p) and p.y <= 0.0 and p.y > -0.7 and b.vel.y <= 0.0:
		p.y = 0.0
		b.vel.y = 0.0
		if not b.grounded:
			b.grounded = true
			if Time.get_ticks_msec() - int(_meta_for(b.id).last_at) > 1500:
				_meta_for(b.id).hits = 0
		for i in PopRules.PAD_ANGLES.size():
			if Vector2(p.x, p.z).distance_to(Vector2(PopRules.pad_center(i).x, PopRules.pad_center(i).z)) < PopRules.PAD_R:
				b.vel.y = PopRules.PAD_VELOCITY
				b.grounded = false
	elif not PopRules.on_table(p) or p.y > 0.0:
		b.grounded = false
	# The spoon.
	if b.arm_immune <= 0.0:
		var push := PopRules.arms_push(p, t, _frenzy(now_ms))
		if push != Vector3.ZERO:
			b.knock = Vector3(push.x, 0.0, push.z)
			b.vel.y = push.y
			b.grounded = false
			b.arm_immune = 0.9
	var mv := Vector2(b.vel.x + kn.x, b.vel.z + kn.z)
	if mv.length() > 0.8 and b.think <= 0.0:
		b.yaw = lerp_angle(float(b.yaw), atan2(-mv.x, -mv.y), minf(dt * 10.0, 1.0))
	b.pos = p
	if p.y < PopRules.FALL_Y:
		knocked_out(b.id, now_ms)
		b.out_until = now_ms + 1600
		b.pos = Vector3(0, -30, 0)
