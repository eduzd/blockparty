class_name AdminSwitch
extends Control
## Material 3 switch in Sky & Ink colours: checked track = primary with a white thumb and
## no border; unchecked = surfaceContainerHighest track, 2dp outline border, small outline thumb.
## The thumb slides and grows over 180 ms.

signal toggled(on: bool)

var on := false
var _t := 0.0     # 0 = off, 1 = on (animated)
var _tw: Tween


func _init(start_on := false) -> void:
	on = start_on
	_t = 1.0 if on else 0.0
	custom_minimum_size = Vector2(52, 32)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_on(v: bool, animate := true, emit := true) -> void:
	if v == on:
		return
	on = v
	if _tw and _tw.is_valid():
		_tw.kill()
	if animate and is_inside_tree():
		_tw = create_tween()
		_tw.tween_method(func(x: float): _t = x; queue_redraw(), _t, 1.0 if on else 0.0, 0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		_t = 1.0 if on else 0.0
		queue_redraw()
	if emit:
		toggled.emit(on)


func _draw() -> void:
	var C: Dictionary = AdminUi.C
	var w := 52.0
	var h := 32.0
	var o := Vector2(0, (size.y - h) / 2.0)
	var track: Color = (C.highest as Color).lerp(C.primary, _t)
	var sb := StyleBoxFlat.new()
	sb.bg_color = track
	sb.set_corner_radius_all(16)
	sb.corner_detail = 12
	sb.anti_aliasing = true
	var bw := int(round(2.0 * (1.0 - _t)))
	if bw > 0:
		sb.border_color = (C.outline as Color).lerp(C.primary, _t)
		sb.set_border_width_all(bw)
	draw_style_box(sb, Rect2(o, Vector2(w, h)))
	var r := lerpf(8.0, 12.0, _t)
	var cx := lerpf(16.0, w - 16.0, _t)
	var thumb: Color = (C.outline as Color).lerp(Color.WHITE, _t)
	if not AdminUi.dark and _t < 0.5:
		thumb = Color("79747E").lerp(Color.WHITE, _t)
	draw_circle(o + Vector2(cx, h / 2.0), r, thumb, true, -1.0, true)
