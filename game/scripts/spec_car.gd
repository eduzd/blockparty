class_name SpecCar
extends LocalPlayer
## Plux 0.8.0: the player's car in "vehicle" spec games. An arcade car that keeps
## LocalPlayer's interface (move_input, teleport, knock, respawn_at...) so SpecPlay
## treats it like the player. move_input.y = gas (+) / brake and reverse (-),
## move_input.x = steering. Steering is smoothed and eases off at speed, so it
## feels calm on a touch screen.

var heading := 0.0              # yaw; forward is -Z at 0, like LocalPlayer's camera_yaw
var speed := 0.0                # signed forward speed (m/s)
var top_speed := 18.0
var accel := 14.0
var brake_power := 26.0
var steer := 0.0                # smoothed -1..1
var look_root: Node3D
var wheels: Array = []
var size := Vector3(2.0, 1.3, 3.6)
var _props: SpecProps


func setup_car(color: Color, props: SpecProps, dark := false) -> void:
	_props = props
	_shape = CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(size.x * 0.9, size.y * 0.7, size.z * 0.92)
	_shape.shape = bs
	_shape.position = Vector3(0, size.y * 0.35 + 0.12, 0)
	add_child(_shape)
	look_root = Node3D.new()
	add_child(look_root)
	var parts: Dictionary = props.build(look_root, "car", size, color, "metal", dark)
	wheels = parts.get("wheels", [])
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(40)


func setup(_display_name: String, _color: Color) -> void:
	pass   # use setup_car


func set_gravity_sign(_s: float) -> void:
	pass


func facing() -> float:
	return heading


func forward() -> Vector3:
	return Vector3(-sin(heading), 0, -cos(heading))


func teleport(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	speed = 0.0
	_knock = Vector3.ZERO


func _physics_process(delta: float) -> void:
	var inp := move_input
	var gas := clampf(inp.y, -1.0, 1.0)
	var top := top_speed * speed_mult
	# Steering input eases in and out (no twitchy snaps from a thumb).
	steer = move_toward(steer, clampf(inp.x, -1.0, 1.0), delta * 4.5)
	var on_floor := is_on_floor()
	if on_floor:
		if gas > 0.05:
			speed = move_toward(speed, top * gas, accel * delta * (1.0 if speed >= 0.0 else 2.2))
		elif gas < -0.05:
			if speed > 0.5:
				speed = move_toward(speed, 0.0, brake_power * delta)
			else:
				speed = move_toward(speed, -top * 0.4, accel * 0.6 * delta)
		else:
			speed = move_toward(speed, 0.0, 5.0 * delta)
		if speed > top:
			speed = move_toward(speed, top, 10.0 * delta)
		# Turn rate grows with speed, then eases off near top speed.
		var sf := clampf(absf(speed) / 6.0, 0.0, 1.0) * lerpf(1.0, 0.62, clampf(absf(speed) / maxf(top, 1.0), 0.0, 1.0))
		heading -= steer * 2.3 * sf * signf(speed if absf(speed) > 0.1 else 1.0) * delta
	var fwd := forward()
	var vy := velocity.y
	if on_floor:
		vy = minf(vy, 0.0)
	else:
		vy -= Protocol.GRAVITY * gravity_mult * delta
	velocity = fwd * speed + _knock + Vector3(0, vy, 0)
	_knock = _knock.move_toward(Vector3.ZERO, 16.0 * delta)
	var before := global_position
	move_and_slide()
	# Hitting a wall scrubs speed (no sticking at full throttle into a barrier).
	if get_slide_collision_count() > 0 and on_floor:
		var moved := (global_position - before)
		moved.y = 0
		var real := moved.length() / maxf(delta, 0.0001)
		if real < absf(speed) * 0.7:
			speed = signf(speed) * maxf(real, absf(speed) * 0.8)
	look_root.rotation.y = heading
	# Lean into turns and spin the wheels.
	look_root.rotation.z = lerpf(look_root.rotation.z, steer * clampf(speed / maxf(top, 1.0), -1.0, 1.0) * 0.06, minf(delta * 6.0, 1.0))
	for w in wheels:
		if is_instance_valid(w):
			(w as Node3D).rotate_object_local(Vector3.UP, -speed * delta / 0.35)
	if global_position.y < min_y:
		teleport(respawn_at)
