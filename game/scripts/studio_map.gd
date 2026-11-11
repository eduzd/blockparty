class_name StudioMap
extends Control
## Studio's hand editor: the level seen from above. Tap a part to pick it, drag to move
## it. The start point (green) and the finish flag (gold) can be dragged too.

signal changed()          # a drag finished and moved something
signal picked(index: int) # -1 = nothing, -2 = start, -3 = finish

var level: Dictionary
var selected := -1
var _drag := false
var _drag_from := Vector2.ZERO
var _orig := []
var _moved := false
var _scale := 4.0
var _center := Vector2.ZERO


func _init() -> void:
	custom_minimum_size = Vector2(0, 300)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func set_level(l: Dictionary, sel := -1) -> void:
	level = l
	selected = sel
	_fit()
	queue_redraw()


func _fit() -> void:
	if level.is_empty():
		return
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for p in level.parts:
		lo = lo.min(Vector2(p[1] - p[4] / 2.0, p[3] - p[6] / 2.0))
		hi = hi.max(Vector2(p[1] + p[4] / 2.0, p[3] + p[6] / 2.0))
	for q in [level.spawn, level.goal]:
		lo = lo.min(Vector2(q[0], q[2]))
		hi = hi.max(Vector2(q[0], q[2]))
	lo -= Vector2(6, 6)
	hi += Vector2(6, 6)
	_center = (lo + hi) / 2.0
	var sz := size if size.x > 10 else Vector2(360, 300)
	_scale = clampf(minf(sz.x / (hi.x - lo.x), sz.y / (hi.y - lo.y)), 1.5, 30.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_fit()
		queue_redraw()


func to_screen(x: float, z: float) -> Vector2:
	return size / 2.0 + (Vector2(x, z) - _center) * _scale


func to_world(p: Vector2) -> Vector2:
	return (p - size / 2.0) / _scale + _center


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UiKit.c("surface_container_high"))
	# 5 m grid
	var grid := Color(UiKit.c("outline_variant"), 0.5)
	var a := to_world(Vector2.ZERO)
	var b := to_world(size)
	var gx := floorf(a.x / 5.0) * 5.0
	while gx < b.x:
		var sx := to_screen(gx, 0).x
		draw_line(Vector2(sx, 0), Vector2(sx, size.y), grid, 1.0)
		gx += 5.0
	var gz := floorf(a.y / 5.0) * 5.0
	while gz < b.y:
		var sy := to_screen(0, gz).y
		draw_line(Vector2(0, sy), Vector2(size.x, sy), grid, 1.0)
		gz += 5.0
	if level.is_empty():
		return
	# Lower parts first so the path on top stays readable.
	var order := range(level.parts.size())
	order.sort_custom(func(i, j): return level.parts[i][2] < level.parts[j][2])
	for i in order:
		var p: Array = level.parts[i]
		var c := Color(PloxLevel.COLORS[clampi(int(p[8]), 0, 9)])
		match str(p[0]):
			"lava": c = Color("#FF5722")
			"bounce": c = Color("#EC407A")
			"coin": c = Color("#FFCA28")
		var xf := Transform2D(deg_to_rad(-float(p[7])), to_screen(p[1], p[3]))
		draw_set_transform_matrix(xf)
		var r := Rect2(Vector2(-p[4], -p[6]) * _scale / 2.0, Vector2(p[4], p[6]) * _scale)
		if str(p[0]) == "coin":
			draw_circle(Vector2.ZERO, maxf(4.0, _scale * 0.6), c)
		else:
			draw_rect(r, Color(c, 0.55 if str(p[0]) == "lava" else 0.9))
			if str(p[0]) in ["spinner", "mover"]:
				draw_rect(r, Color.WHITE, false, 2.0)
		if i == selected:
			draw_rect(r.grow(3), UiKit.c("primary"), false, 3.0)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	var s := to_screen(level.spawn[0], level.spawn[2])
	draw_circle(s, 9.0, Color("#2E7D32"))
	draw_circle(s, 4.0, Color.WHITE)
	var g := to_screen(level.goal[0], level.goal[2])
	draw_circle(g, 10.0, Color("#F5B700"))
	draw_line(g + Vector2(-3, 5), g + Vector2(-3, -7), Color.BLACK, 2.0)
	draw_rect(Rect2(g + Vector2(-3, -7), Vector2(8, 5)), Color.BLACK)
	if selected == -2:
		draw_arc(s, 13.0, 0, TAU, 24, UiKit.c("primary"), 3.0)
	if selected == -3:
		draw_arc(g, 14.0, 0, TAU, 24, UiKit.c("primary"), 3.0)


func _hit(pos: Vector2) -> int:
	if pos.distance_to(to_screen(level.goal[0], level.goal[2])) < 16:
		return -3
	if pos.distance_to(to_screen(level.spawn[0], level.spawn[2])) < 16:
		return -2
	var w := to_world(pos)
	var best := -1
	var best_y := -1e9
	for i in level.parts.size():
		var p: Array = level.parts[i]
		var local := (w - Vector2(p[1], p[3])).rotated(deg_to_rad(float(p[7])))
		var half := Vector2(maxf(p[4], 1.2), maxf(p[6], 1.2)) / 2.0
		if absf(local.x) <= half.x and absf(local.y) <= half.y and p[2] > best_y:
			best = i
			best_y = p[2]
	return best


func _gui_input(ev: InputEvent) -> void:
	if level.is_empty():
		return
	if (ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT) or ev is InputEventScreenTouch:
		if ev.pressed:
			selected = _hit(ev.position)
			picked.emit(selected)
			_drag = selected != -1
			_moved = false
			_drag_from = ev.position
			if selected >= 0:
				_orig = [level.parts[selected][1], level.parts[selected][3]]
			elif selected == -2:
				_orig = [level.spawn[0], level.spawn[2]]
			elif selected == -3:
				_orig = [level.goal[0], level.goal[2]]
			queue_redraw()
			accept_event()
		else:
			if _drag and _moved:
				changed.emit()
			_drag = false
	elif (ev is InputEventMouseMotion or ev is InputEventScreenDrag) and _drag:
		var d: Vector2 = (ev.position - _drag_from) / _scale
		if d.length() * _scale < 6.0 and not _moved:
			return
		_moved = true
		# Snap to half a metre so parts line up neatly.
		var nx := clampf(snappedf(_orig[0] + d.x, 0.5), -PloxLevel.HALF, PloxLevel.HALF)
		var nz := clampf(snappedf(_orig[1] + d.y, 0.5), -PloxLevel.HALF, PloxLevel.HALF)
		if selected >= 0:
			level.parts[selected][1] = nx
			level.parts[selected][3] = nz
		elif selected == -2:
			level.spawn[0] = nx
			level.spawn[2] = nz
		elif selected == -3:
			level.goal[0] = nx
			level.goal[2] = nz
		queue_redraw()
		accept_event()
