class_name PopRemote
extends Node3D
## Another player (or a bot) in Pop-Up Panic, shown a little in the past and
## smoothed between snapshots, with its velocity worked out for the animation.

const RENDER_DELAY_MS := 110.0

var player_id := -1
var display_name := ""
var is_bot := false
var character := 0
var ch: PopCharacter
var vel := Vector3.ZERO
var _buffer: Array = []   # [[local_ms, Vector3, yaw], ...]
var _last_pos := Vector3.ZERO


func setup(id: int, p_name: String, p_char: int, color: Color, pos: Vector3, yaw: float, bot: bool) -> void:
	player_id = id
	display_name = p_name
	is_bot = bot
	character = p_char
	ch = PopCharacter.new()
	add_child(ch)
	ch.setup(p_name + (" (bot)" if bot else ""), p_char, color, true)
	position = pos
	_last_pos = pos
	ch.facing_yaw = yaw
	ch.rotation.y = yaw


func push_state(pos: Vector3, yaw: float) -> void:
	_buffer.append([float(Time.get_ticks_msec()), pos, yaw])
	if _buffer.size() > 20:
		_buffer.pop_front()


func grounded() -> bool:
	return absf(position.y) < 0.06 and PopRules.on_table(position)


func _process(delta: float) -> void:
	if _buffer.is_empty():
		ch.animate(delta, Vector3.ZERO, true)
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
	var jump := position.distance_to(target_pos) > 6.0
	if jump:
		position = target_pos   # dropped back in from the sky: go straight there
	else:
		position = position.lerp(target_pos, minf(delta * 20.0, 1.0))
	# Hidden while out of play (the referee parks fallen bots far below).
	visible = position.y > -20.0
	ch.facing_yaw = target_yaw
	var v := (position - _last_pos) / maxf(delta, 0.001)
	vel = Vector3.ZERO if jump else vel.lerp(v, minf(delta * 12.0, 1.0))
	ch.animate(delta, vel, grounded())
	_last_pos = position
