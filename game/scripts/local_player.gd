class_name LocalPlayer
extends CharacterBody3D
## The player you control. Moves instantly on your phone (client prediction);
## the referee checks every update and can snap you back.
## World rules applied here: trampoline floor, wind gusts while airborne,
## knocks from the magnetic balls, and room-wide gravity flips.

var move_input := Vector2.ZERO   # x = right, y = forward
var jump_pressed := false
var camera_yaw := 0.0
var wind := Vector2.ZERO
var gravity_sign := 1.0
var avatar: Avatar
var bounces := 0
var _knock := Vector3.ZERO
var trampoline := true             # Neon world floor; Studio games switch it off
var respawn_at := Protocol.SPAWN
var min_y := Protocol.MIN_Y
var speed_mult := 1.0
var jump_velocity := Protocol.JUMP_VELOCITY
var _shape: CollisionShape3D


func setup(display_name: String, color: Color) -> void:
	_shape = CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 2.0
	_shape.shape = capsule
	_shape.position = Vector3(0, 1.0, 0)
	add_child(_shape)
	avatar = Avatar.new()
	add_child(avatar)
	avatar.setup(display_name, color)
	floor_snap_length = 0.3


func set_gravity_sign(s: float) -> void:
	if s == gravity_sign:
		return
	gravity_sign = s
	up_direction = Vector3.UP * s
	_shape.position = Vector3(0, 1.0 * s, 0)
	avatar.rotation.z = 0.0 if s > 0.0 else PI   # hang upside down from the feet


func knock(v: Vector3) -> void:
	_knock = Vector3(v.x, 0, v.z)
	velocity.y = v.y * gravity_sign


func _physics_process(delta: float) -> void:
	var input := move_input
	if input.length() > 1.0:
		input = input.normalized()
	var forward := Vector3(-sin(camera_yaw), 0, -cos(camera_yaw))
	var right := Vector3(cos(camera_yaw), 0, -sin(camera_yaw))
	var dir := right * input.x + forward * input.y
	var on_floor := is_on_floor()
	var drift := Vector3.ZERO if on_floor else Vector3(wind.x, 0, wind.y)
	velocity.x = dir.x * Protocol.MOVE_SPEED * speed_mult + drift.x + _knock.x
	velocity.z = dir.z * Protocol.MOVE_SPEED * speed_mult + drift.z + _knock.z
	_knock = _knock.move_toward(Vector3.ZERO, 14.0 * delta)
	if on_floor:
		if jump_pressed:
			velocity.y = jump_velocity * gravity_sign
	else:
		velocity.y -= Protocol.GRAVITY * gravity_sign * delta
	jump_pressed = false
	move_and_slide()
	# Trampoline floor: the ground (not the pad or blocks) launches you upward.
	if trampoline and gravity_sign > 0.0 and is_on_floor() and global_position.y < 0.1:
		velocity.y = Protocol.TRAMPOLINE_VELOCITY
		bounces += 1
	if dir.length() > 0.05:
		var target_yaw := atan2(-dir.x, -dir.z)
		avatar.rotation.y = lerp_angle(avatar.rotation.y, target_yaw, minf(delta * 12.0, 1.0))
	avatar.animate(delta, Vector2(dir.x, dir.z).length() * Protocol.MOVE_SPEED if is_on_floor() else 0.0)
	if global_position.y < min_y:
		teleport(respawn_at)


func teleport(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	_knock = Vector3.ZERO


func facing() -> float:
	return avatar.rotation.y
