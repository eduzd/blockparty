class_name TouchControls
extends Control
## On-screen joystick (left), jump button (right) and drag-to-look.
## Also maps keyboard/mouse for desktop testing.

signal jump

var move := Vector2.ZERO        # x = right, y = forward
var look_delta := Vector2.ZERO  # pixels since last read
var show_touch := true

const STICK_RADIUS := 110.0
const JUMP_RADIUS := 85.0

var _stick_finger := -1
var _stick_origin := Vector2.ZERO
var _stick_pos := Vector2.ZERO
var _look_finger := -1
var _look_last := Vector2.ZERO
var _mouse_looking := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _stick_home() -> Vector2:
	return Vector2(190, size.y - 190)


func _jump_center() -> Vector2:
	return Vector2(size.x - 170, size.y - 170)


func consume_look() -> Vector2:
	var d := look_delta
	look_delta = Vector2.ZERO
	return d


func keyboard_move() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): v.y += 1
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): v.y -= 1
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): v.x += 1
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): v.x -= 1
	return v


func current_move() -> Vector2:
	var k := keyboard_move()
	return k if k != Vector2.ZERO else move


func release_all() -> void:
	_stick_finger = -1
	_look_finger = -1
	_mouse_looking = false
	move = Vector2.ZERO
	queue_redraw()


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_SPACE:
		jump.emit()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouse_looking = event.pressed
	elif event is InputEventMouseMotion and _mouse_looking:
		look_delta += event.relative


func _on_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		if e.position.distance_to(_jump_center()) <= JUMP_RADIUS * 1.3:
			jump.emit()
		elif e.position.x < size.x * 0.45 and e.position.y > size.y * 0.3 and _stick_finger == -1:
			_stick_finger = e.index
			_stick_origin = e.position
			_stick_pos = e.position
			_update_stick()
		elif _look_finger == -1 and e.position.y > 110:
			_look_finger = e.index
			_look_last = e.position
	else:
		if e.index == _stick_finger:
			_stick_finger = -1
			move = Vector2.ZERO
		elif e.index == _look_finger:
			_look_finger = -1
	queue_redraw()


func _on_drag(e: InputEventScreenDrag) -> void:
	if e.index == _stick_finger:
		_stick_pos = e.position
		_update_stick()
		queue_redraw()
	elif e.index == _look_finger:
		look_delta += e.position - _look_last
		_look_last = e.position


func _update_stick() -> void:
	var offset := (_stick_pos - _stick_origin).limit_length(STICK_RADIUS)
	var v := offset / STICK_RADIUS
	if v.length() < 0.12:
		v = Vector2.ZERO
	move = Vector2(v.x, -v.y)


func _draw() -> void:
	if not show_touch:
		return
	var base := _stick_origin if _stick_finger != -1 else _stick_home()
	draw_circle(base, STICK_RADIUS, Color(1, 1, 1, 0.16))
	draw_arc(base, STICK_RADIUS, 0, TAU, 48, Color(1, 1, 1, 0.5), 4.0, true)
	var knob := base + Vector2(move.x, -move.y) * STICK_RADIUS
	draw_circle(knob, 48, Color(1, 1, 1, 0.55))
	var jc := _jump_center()
	draw_circle(jc, JUMP_RADIUS, Color(1, 1, 1, 0.22))
	draw_arc(jc, JUMP_RADIUS, 0, TAU, 48, Color(1, 1, 1, 0.6), 4.0, true)
	var font := get_theme_default_font()
	var fs := 30
	var text_size := font.get_string_size("JUMP", HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	draw_string(font, jc + Vector2(-text_size.x / 2.0, fs * 0.35), "JUMP", HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color.WHITE)
