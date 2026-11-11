class_name PopPlayer
extends Node3D
## Your own character in Pop-Up Panic. Moves on the phone at once (no waiting for
## the server), with its own tiny physics: the round table, the centre post, the
## jelly pads, the spinning spoon and soft bumps against the others.

signal hopped
signal landed(strength: float)
signal padded(index: int)
signal spooned
signal fell

var ch: PopCharacter
var vel := Vector3.ZERO
var knock_v := Vector3.ZERO
var grounded := false
var out := false              # fell off; waiting for the referee to drop us back in
var move_input := Vector2.ZERO
var jump_pressed := false
var camera_yaw := 0.0
var facing_yaw := 0.0
var _coyote := 0.0
var _jump_buf := 0.0
var _arm_immune := 0.0
var _pad_cool := 0.0
var _air_time := 0.0


func setup(p_name: String, character: int, color: Color) -> void:
	ch = PopCharacter.new()
	add_child(ch)
	ch.setup(p_name, character, color, false)


func teleport(p: Vector3) -> void:
	position = p
	vel = Vector3.ZERO
	knock_v = Vector3.ZERO
	grounded = false
	out = false
	visible = true


func knock(v: Vector3) -> void:
	knock_v = Vector3(v.x, 0.0, v.z)
	vel.y = maxf(vel.y, v.y)
	grounded = false
	ch.hit()


## Turns to face `yaw` straight away (used when bonking with aim help).
func face(yaw: float) -> void:
	facing_yaw = yaw
	ch.facing_yaw = yaw
	ch.rotation.y = yaw


func step(dt: float, t: float, frenzy: float, others: Array) -> void:
	if out:
		ch.animate(dt, Vector3.ZERO, false)
		return
	_arm_immune = maxf(_arm_immune - dt, 0.0)
	_pad_cool = maxf(_pad_cool - dt, 0.0)
	var input := move_input.limit_length(1.0)
	var forward := Vector3(-sin(camera_yaw), 0, -cos(camera_yaw))
	var right := Vector3(cos(camera_yaw), 0, -sin(camera_yaw))
	var want := (right * input.x + forward * input.y) * PopRules.MOVE_SPEED
	# Less grip in the air, so a knock really sends you flying.
	var accel := PopRules.ACCEL * (1.0 if grounded else 0.45)
	var hv := Vector2(vel.x, vel.z).move_toward(Vector2(want.x, want.z), accel * dt)
	vel.x = hv.x
	vel.z = hv.y
	knock_v *= exp(-PopRules.KNOCK_DECAY * dt)
	if knock_v.length() < 0.05:
		knock_v = Vector3.ZERO

	# Jump: buffered a moment before landing and allowed a moment after leaving the edge.
	if jump_pressed:
		_jump_buf = PopRules.JUMP_BUFFER_S
		jump_pressed = false
	_jump_buf = maxf(_jump_buf - dt, 0.0)
	_coyote = PopRules.COYOTE_S if grounded else maxf(_coyote - dt, 0.0)
	if _jump_buf > 0.0 and _coyote > 0.0:
		vel.y = PopRules.HOP_VELOCITY
		grounded = false
		_coyote = 0.0
		_jump_buf = 0.0
		hopped.emit()

	if not grounded:
		vel.y -= PopRules.GRAVITY * dt
		_air_time += dt
	var p := position + (vel + knock_v) * dt

	# Centre post (solid up to the spoon's height and a little more).
	var f2 := Vector2(p.x, p.z)
	var hub := PopRules.HUB_R + PopRules.BODY_R
	if f2.length() < hub and p.y < 2.2 and p.y > -1.0:
		f2 = f2.normalized() * hub if f2.length() > 0.01 else Vector2(hub, 0)
		p.x = f2.x
		p.z = f2.y
		knock_v = knock_v.slide(Vector3(f2.x, 0, f2.y).normalized())

	# Soft bumps against other characters.
	for q in others:
		var d := Vector2(p.x - q.x, p.z - q.z)
		var min_d := PopRules.BODY_R * 2.0
		if absf(p.y - q.y) < 1.2 and d.length() < min_d and d.length() > 0.001:
			var push := d.normalized() * (min_d - d.length())
			p.x += push.x * 0.6
			p.z += push.y * 0.6

	# Table top.
	var was := grounded
	if PopRules.on_table(p) and p.y <= 0.0 and p.y > -0.7 and vel.y <= 0.0:
		var impact := -vel.y
		p.y = 0.0
		vel.y = 0.0
		grounded = true
		if not was:
			if _air_time > 0.12:
				landed.emit(clampf(impact / 16.0, 0.0, 1.0))
			_air_time = 0.0
		# Jelly pads fling you up.
		if _pad_cool <= 0.0:
			for i in PopRules.PAD_ANGLES.size():
				var c := PopRules.pad_center(i)
				if Vector2(p.x - c.x, p.z - c.z).length() < PopRules.PAD_R:
					vel.y = PopRules.PAD_VELOCITY
					grounded = false
					_pad_cool = 0.4
					padded.emit(i)
					break
	else:
		grounded = false

	# The spoon (and the fork in the frenzy). The arm's position comes from the shared
	# clock, so this matches what everyone else sees.
	if _arm_immune <= 0.0:
		var push := PopRules.arms_push(p, t, frenzy)
		if push != Vector3.ZERO:
			knock_v = Vector3(push.x, 0, push.z)
			vel.y = push.y
			grounded = false
			_arm_immune = 0.9
			ch.hit()
			spooned.emit()

	position = p
	var mv := Vector2(vel.x, vel.z)
	if input.length() > 0.15 and mv.length() > 0.5:
		facing_yaw = atan2(-mv.x, -mv.y)
	ch.facing_yaw = facing_yaw - rotation.y
	ch.animate(dt, vel + knock_v, grounded)
	if p.y < PopRules.FALL_Y:
		out = true
		fell.emit()
