class_name RemotePlayer
extends Node3D
## Another player, shown slightly in the past and smoothed between snapshots.

const RENDER_DELAY_MS := 120.0

var player_id := -1
var avatar: Avatar
var _buffer: Array = []   # [[local_ms, Vector3, yaw], ...]
var _last_pos := Vector3.ZERO


var display_name := ""


func setup(id: int, p_name: String, color: Color, pos: Vector3, yaw: float) -> void:
	display_name = p_name
	player_id = id
	avatar = Avatar.new()
	add_child(avatar)
	avatar.setup(p_name, color)
	position = pos
	_last_pos = pos
	avatar.rotation.y = yaw


func set_gravity_sign(s: float) -> void:
	avatar.rotation.z = 0.0 if s > 0.0 else PI


func push_state(pos: Vector3, yaw: float) -> void:
	_buffer.append([float(Time.get_ticks_msec()), pos, yaw])
	if _buffer.size() > 20:
		_buffer.pop_front()


func _process(delta: float) -> void:
	if _buffer.is_empty():
		return
	var render_t := float(Time.get_ticks_msec()) - RENDER_DELAY_MS
	while _buffer.size() > 2 and _buffer[1][0] <= render_t:
		_buffer.pop_front()
	var a: Array = _buffer[0]
	var target_pos: Vector3 = a[1]
	var target_yaw: float = a[2]
	if _buffer.size() >= 2:
		var b: Array = _buffer[1]
		var span := maxf(b[0] - a[0], 1.0)
		var w := clampf((render_t - a[0]) / span, 0.0, 1.0)
		target_pos = (a[1] as Vector3).lerp(b[1], w)
		target_yaw = lerp_angle(a[2], b[2], w)
	if position.distance_to(target_pos) > 6.0:
		position = target_pos   # respawn or correction: jump straight there
	else:
		position = position.lerp(target_pos, minf(delta * 20.0, 1.0))
	avatar.rotation.y = lerp_angle(avatar.rotation.y, target_yaw, minf(delta * 15.0, 1.0))
	var moved := Vector2(position.x - _last_pos.x, position.z - _last_pos.z).length()
	var grounded := absf(position.y - _last_pos.y) < 0.02
	avatar.animate(delta, (moved / maxf(delta, 0.001)) if grounded else 0.0)
	_last_pos = position
