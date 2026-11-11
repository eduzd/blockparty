class_name AdminChart
extends Control
## Sign-ups and AI builds per day as paired rounded bars. Bars grow in when data arrives
## (420 ms ease-out); tap a day to see its numbers.

signal picked(index: int)

var rows: Array = []          # [{day: "YYYY-MM-DD", a: int, b: int}]
var col_a := Color("37B1FF")
var col_b := Color("FF4BB7")
var sel := -1
var _grow := 1.0
var _tw: Tween


func _init() -> void:
	custom_minimum_size = Vector2(0, 168)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS


func set_rows(r: Array, animate := true) -> void:
	var changed := JSON.stringify(r) != JSON.stringify(rows)
	rows = r
	if sel >= rows.size():
		sel = rows.size() - 1
	if changed and animate and is_inside_tree():
		if _tw and _tw.is_valid():
			_tw.kill()
		_grow = 0.0
		_tw = create_tween()
		_tw.tween_method(func(x: float): _grow = x; queue_redraw(), 0.0, 1.0, 0.42).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	else:
		queue_redraw()


func _top() -> int:
	var m := 0
	for r in rows:
		m = maxi(m, maxi(int(r.a), int(r.b)))
	if m <= 4:
		return 4
	var step := 5 if m <= 50 else (10 if m <= 200 else 50)
	return int(ceil(float(m) / step) * step)


func _plot() -> Rect2:
	var f := AdminUi.font(500)
	var lw := f.get_string_size(str(_top()), HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 8.0
	return Rect2(lw, 8.0, maxf(size.x - lw, 10.0), maxf(size.y - 8.0 - 24.0, 10.0))


func _gui_input(e: InputEvent) -> void:
	var pos := Vector2.ZERO
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
		pos = e.position
	elif e is InputEventScreenTouch and not e.pressed:
		pos = e.position
	else:
		return
	if rows.is_empty():
		return
	var p := _plot()
	var i := clampi(int((pos.x - p.position.x) / (p.size.x / rows.size())), 0, rows.size() - 1)
	sel = -1 if sel == i else i
	queue_redraw()
	picked.emit(sel)


func _draw() -> void:
	var C: Dictionary = AdminUi.C
	var f := AdminUi.font(500)
	var p := _plot()
	var top := _top()
	for g in 3:
		var y := p.position.y + p.size.y * (1.0 - float(g) / 2.0)
		draw_line(Vector2(p.position.x, y), Vector2(p.end.x, y), C.line, 1.0)
		var v := str(top * g / 2)
		draw_string(f, Vector2(0, y + 4), v, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C.sub)
	if rows.is_empty():
		return
	var n := rows.size()
	var slot := p.size.x / n
	var bw := clampf(slot * 0.28, 3.0, 14.0)
	var gap := clampf(slot * 0.06, 1.0, 3.0)
	var every := 1 if n <= 7 else 2
	for i in n:
		var r: Dictionary = rows[i]
		var cx := p.position.x + slot * (i + 0.5)
		if i == sel:
			var hl := StyleBoxFlat.new()
			hl.bg_color = Color(C.primary, 0.12)
			hl.set_corner_radius_all(10)
			draw_style_box(hl, Rect2(cx - slot / 2.0 + 1, p.position.y - 4, slot - 2, p.size.y + 4))
		for k in 2:
			var val := float(r.a if k == 0 else r.b)
			var h := p.size.y * (val / top) * _grow
			var x := cx - gap / 2.0 - bw if k == 0 else cx + gap / 2.0
			var col: Color = col_a if k == 0 else col_b
			if sel >= 0 and i != sel:
				col = Color(col, 0.45)
			if val <= 0.0:
				draw_rect(Rect2(x, p.end.y - 2, bw, 2), Color(col, 0.35))
				continue
			h = maxf(h, 3.0)
			var sb := StyleBoxFlat.new()
			sb.bg_color = col
			var rad := int(minf(bw / 2.0, 6.0))
			sb.corner_radius_top_left = rad
			sb.corner_radius_top_right = rad
			sb.corner_detail = 6
			sb.anti_aliasing = true
			draw_style_box(sb, Rect2(x, p.end.y - h, bw, h))
		if i % every == (n - 1) % every:
			var d := _short_day(str(r.day), n <= 7)
			var dw := f.get_string_size(d, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			draw_string(f, Vector2(cx - dw / 2.0, size.y - 6), d, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C.primary if i == sel else C.sub)


static func _short_day(iso: String, weekday: bool) -> String:
	var unix := Time.get_unix_time_from_datetime_string(iso + "T12:00:00")
	var dt := Time.get_datetime_dict_from_unix_time(unix)
	if weekday:
		return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][int(dt.weekday)]
	return str(int(dt.day))


static func long_day(iso: String) -> String:
	var unix := Time.get_unix_time_from_datetime_string(iso + "T12:00:00")
	var dt := Time.get_datetime_dict_from_unix_time(unix)
	var wd: String = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][int(dt.weekday)]
	var mo: String = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][int(dt.month) - 1]
	return "%s %d %s" % [wd, int(dt.day), mo]
