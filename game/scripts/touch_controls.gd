class_name TouchControls
extends Control
## On-screen joystick (left), jump button (right) and drag-to-look.
## Also maps keyboard/mouse for desktop testing.

signal jump
signal action

## Optional second button (Pop-Up Panic's BONK). Empty label = only the jump button.
var action_label := ""
var jump_label := "JUMP"
var action_ready := 1.0     # 0..1, drawn as a ring while the action recharges
var action_flash := 0.0

var move := Vector2.ZERO        # x = right, y = forward
var look_delta := Vector2.ZERO  # pixels since last read
var show_touch := true

# Sizes in dp; turned into pixels with ScreenUtil.dp so they match in both orientations.
const STICK_RADIUS_DP := 54.0
const KNOB_RADIUS_DP := 24.0
const JUMP_RADIUS_DP := 40.0
const ACTION_RADIUS_DP := 46.0
const SMALL_JUMP_RADIUS_DP := 34.0
const EDGE_GAP_DP := 20.0
const TOP_BAR_DP := 64.0        # the HUD row: no look-drags start up there
## Set by the HUD: rectangles (viewport pixels) where touches belong to buttons.
var blocked_rects: Array[Rect2] = []

var _stick_finger := -1
var _stick_origin := Vector2.ZERO
var _stick_pos := Vector2.ZERO
var _look_finger := -1
var _look_last := Vector2.ZERO
var _mouse_looking := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Full screen in viewport pixels (this control's own size is not used, because it
## sits straight under a CanvasLayer).
func _vs() -> Vector2:
	return get_viewport().get_visible_rect().size


func _k() -> float:
	return ScreenUtil.dp(get_viewport())


func stick_radius() -> float:
	return STICK_RADIUS_DP * _k()


func jump_radius() -> float:
	return (SMALL_JUMP_RADIUS_DP if action_label != "" else JUMP_RADIUS_DP) * _k()


func action_radius() -> float:
	return ACTION_RADIUS_DP * _k()


## With two buttons: the big action button sits where the jump button was, and the
## jump button rests up and to the left of it, like on a game pad.
func _action_center() -> Vector2:
	var ins := ScreenUtil.insets(get_viewport())
	var r := action_radius()
	var gap := EDGE_GAP_DP * _k()
	return Vector2(_vs().x - ins.r - gap - r - 4.0 * _k(), _vs().y - ins.b - gap - r)


func _stick_home() -> Vector2:
	var ins := ScreenUtil.insets(get_viewport())
	var r := stick_radius()
	var gap := EDGE_GAP_DP * _k()
	return Vector2(ins.l + gap + r, _vs().y - ins.b - gap - r)


func _jump_center() -> Vector2:
	var ins := ScreenUtil.insets(get_viewport())
	var r := jump_radius()
	var gap := EDGE_GAP_DP * _k()
	if action_label != "":
		var ac := _action_center()
		var dist := action_radius() + r + 22.0 * _k()
		return ac + Vector2(-0.82, -0.57).normalized() * dist
	# Line its centre up with the stick's so thumbs rest at the same height.
	return Vector2(_vs().x - ins.r - gap - r - 8.0 * _k(), _stick_home().y)


func _top_limit() -> float:
	return ScreenUtil.insets(get_viewport()).t + TOP_BAR_DP * _k()


func _blocked(p: Vector2) -> bool:
	for r in blocked_rects:
		if r.has_point(p):
			return true
	return false


## Called by the HUD after a resize or turn.
func relayout() -> void:
	release_all()
	queue_redraw()


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
	elif event is InputEventKey and event.pressed and not event.echo and action_label != "" \
			and (event.physical_keycode == KEY_F or event.physical_keycode == KEY_E):
		_fire_action()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouse_looking = event.pressed
	elif event is InputEventMouseMotion and _mouse_looking:
		look_delta += event.relative


func _on_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		if _blocked(e.position):
			return
		if action_label != "" and e.position.distance_to(_action_center()) <= action_radius() * 1.2:
			_fire_action()
		elif e.position.distance_to(_jump_center()) <= jump_radius() * 1.3:
			jump.emit()
		elif e.position.x < _vs().x * 0.5 and e.position.y > maxf(_vs().y * 0.4, _top_limit()) and _stick_finger == -1:
			_stick_finger = e.index
			_stick_origin = e.position
			_stick_pos = e.position
			_update_stick()
		elif _look_finger == -1 and e.position.y > _top_limit():
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


func _fire_action() -> void:
	action_flash = 1.0
	action.emit()
	queue_redraw()


func _process(delta: float) -> void:
	if action_label != "" and (action_flash > 0.0 or action_ready < 1.0):
		action_flash = maxf(action_flash - delta * 5.0, 0.0)
		queue_redraw()


## The two button circles in viewport pixels (for the layout self-check).
func button_rects() -> Array:
	var out := [Rect2(_jump_center() - Vector2.ONE * jump_radius(), Vector2.ONE * jump_radius() * 2.0)]
	if action_label != "":
		out.append(Rect2(_action_center() - Vector2.ONE * action_radius(), Vector2.ONE * action_radius() * 2.0))
	return out


func _update_stick() -> void:
	var offset := (_stick_pos - _stick_origin).limit_length(stick_radius())
	var v := offset / stick_radius()
	if v.length() < 0.12:
		v = Vector2.ZERO
	move = Vector2(v.x, -v.y)


func _draw() -> void:
	if not show_touch:
		return
	var k := _k()
	var sr := stick_radius()
	var jr := jump_radius()
	var base := _stick_origin if _stick_finger != -1 else _stick_home()
	draw_circle(base, sr, Color(1, 1, 1, 0.16))
	draw_arc(base, sr, 0, TAU, 48, Color(1, 1, 1, 0.5), 2.0 * k, true)
	var knob := base + Vector2(move.x, -move.y) * sr
	draw_circle(knob, KNOB_RADIUS_DP * k, Color(1, 1, 1, 0.55))
	var jc := _jump_center()
	draw_circle(jc, jr, Color(1, 1, 1, 0.22))
	draw_arc(jc, jr, 0, TAU, 48, Color(1, 1, 1, 0.6), 2.0 * k, true)
	var font := UiKit.font("anton", 400)
	var fs := int((13 if action_label != "" else 15) * k)
	var text_size := font.get_string_size(jump_label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	draw_string(font, jc + Vector2(-text_size.x / 2.0, fs * 0.35), jump_label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color.WHITE)
	if action_label != "":
		var ac := _action_center()
		var ar := action_radius() * (1.0 + 0.08 * action_flash)
		var ready := action_ready >= 1.0
		var fill := Color(1.0, 0.55, 0.2, 0.55) if ready else Color(1, 1, 1, 0.16)
		draw_circle(ac, ar, fill.lerp(Color(1, 0.9, 0.5, 0.85), action_flash))
		draw_arc(ac, ar, 0, TAU, 56, Color(1, 1, 1, 0.75 if ready else 0.35), 2.5 * k, true)
		if not ready:
			draw_arc(ac, ar - 4.0 * k, -PI / 2.0, -PI / 2.0 + TAU * action_ready, 48, Color(1, 0.75, 0.3, 0.95), 5.0 * k, true)
		var afs := int(19 * k)
		var asz := font.get_string_size(action_label, HORIZONTAL_ALIGNMENT_CENTER, -1, afs)
		draw_string(font, ac + Vector2(-asz.x / 2.0, afs * 0.35), action_label, HORIZONTAL_ALIGNMENT_CENTER, -1, afs, Color.WHITE)
