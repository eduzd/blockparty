class_name ItemArt
extends Control
## Draws avatar shop items (0.6.0) on top of a round avatar, or one item alone
## as a shop tile. Also draws the Plux coin. Pure vector drawing, no images,
## so it stays sharp and light.

var items: Array = []    # [{art, col, slot}]
var side := 64.0
var _t := 0.0
var _animated := false


static func over(size: float, list: Array) -> ItemArt:
	var a := ItemArt.new()
	a.side = size
	a.items = list
	a.custom_minimum_size = Vector2(size, size)
	a.size = Vector2(size, size)
	a.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for it in list:
		if str(it.get("slot", "")) == "effect" or str(it.get("art", "")) == "propeller":
			a._animated = true
	return a


## The Plux coin: a round gold coin with a P, in the Sky & Ink style.
static func plux(size: float) -> ItemArt:
	return over(size, [{"art": "plux", "col": "#FFC107", "slot": "coin"}])


## An avatar (UiKit) with its equipped items drawn over it.
static func dressed(size: float, name: String, av: int, eq: Array) -> Control:
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(size, size)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var back := []
	var front := []
	for it in eq:
		if it is Dictionary:
			(back if str(it.get("slot", "")) == "back" else front).append(it)
	if not back.is_empty():
		wrap.add_child(over(size, back))
	var art := UiKit.avatar(size, name, av)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(art)
	if not front.is_empty():
		wrap.add_child(over(size, front))
	return wrap


func _process(delta: float) -> void:
	if _animated and is_visible_in_tree():
		_t += delta
		queue_redraw()


func _draw() -> void:
	var s := side
	var fc := Vector2(s * 0.5, s * 0.52)
	var fr := s * 0.36
	for it in items:
		var col := Color.html(str(it.get("col", "#1E88E5"))) if Color.html_is_valid(str(it.get("col", ""))) else Color("#1E88E5")
		_item(str(it.get("art", "")), col, fc, fr, s)


func _ink() -> Color:
	return Color("#1A2433")


func _item(art: String, col: Color, fc: Vector2, fr: float, s: float) -> void:
	var ink := _ink()
	var w := maxf(1.0, s * 0.025)
	match art:
		"plux":
			var c := Vector2(s / 2, s / 2)
			draw_circle(c, s * 0.48, Color("#E0A000"))
			draw_circle(c, s * 0.40, col)
			draw_arc(c, s * 0.40, 0, TAU, 32, Color(1, 1, 1, 0.5), maxf(1.0, s * 0.05))
			# A bold P
			var x0 := s * 0.40
			var lw := maxf(1.5, s * 0.10)
			draw_line(Vector2(x0, s * 0.27), Vector2(x0, s * 0.74), Color("#7A4F00"), lw)
			draw_arc(Vector2(x0 + s * 0.06, s * 0.40), s * 0.13, -PI / 2, PI / 2, 16, Color("#7A4F00"), lw)
			draw_line(Vector2(x0, s * 0.27), Vector2(x0 + s * 0.06, s * 0.27), Color("#7A4F00"), lw)
			draw_line(Vector2(x0, s * 0.53), Vector2(x0 + s * 0.06, s * 0.53), Color("#7A4F00"), lw)
		"cap":
			var top := fc.y - fr * 0.78
			draw_circle(Vector2(fc.x, top + fr * 0.18), fr * 0.62, col)
			draw_rect(Rect2(fc.x - fr * 0.7, top + fr * 0.18, fr * 1.4, fr * 0.3), col)
			draw_rect(Rect2(fc.x - fr * 0.1, top + fr * 0.36, fr * 1.05, fr * 0.16), col.darkened(0.25))
		"beanie":
			var top := fc.y - fr * 0.7
			draw_circle(Vector2(fc.x, top + fr * 0.2), fr * 0.66, col)
			draw_rect(Rect2(fc.x - fr * 0.74, top + fr * 0.2, fr * 1.48, fr * 0.3), col.darkened(0.2))
			draw_circle(Vector2(fc.x, top - fr * 0.5), fr * 0.18, Color.WHITE)
		"party":
			var base := fc.y - fr * 0.55
			var pts := PackedVector2Array([Vector2(fc.x - fr * 0.45, base), Vector2(fc.x + fr * 0.45, base), Vector2(fc.x + fr * 0.1, base - fr * 1.1)])
			draw_colored_polygon(pts, col)
			draw_line(Vector2(fc.x - fr * 0.3, base - fr * 0.3), Vector2(fc.x + fr * 0.3, base - fr * 0.25), Color("#EC407A"), w * 2)
			draw_circle(Vector2(fc.x + fr * 0.1, base - fr * 1.12), fr * 0.14, Color("#EC407A"))
		"bow":
			var c := Vector2(fc.x + fr * 0.45, fc.y - fr * 0.78)
			draw_colored_polygon(PackedVector2Array([c, c + Vector2(-fr * 0.45, -fr * 0.3), c + Vector2(-fr * 0.45, fr * 0.3)]), col)
			draw_colored_polygon(PackedVector2Array([c, c + Vector2(fr * 0.45, -fr * 0.3), c + Vector2(fr * 0.45, fr * 0.3)]), col)
			draw_circle(c, fr * 0.12, col.darkened(0.3))
		"chef":
			var top := fc.y - fr * 0.8
			draw_rect(Rect2(fc.x - fr * 0.5, top - fr * 0.1, fr * 1.0, fr * 0.4), col)
			for k in 3:
				draw_circle(Vector2(fc.x + (k - 1) * fr * 0.38, top - fr * 0.35), fr * 0.32, col)
			draw_rect(Rect2(fc.x - fr * 0.5, top - fr * 0.1, fr * 1.0, fr * 0.4), Color(0, 0, 0, 0.12), false, w)
		"propeller":
			var top := fc.y - fr * 0.75
			draw_circle(Vector2(fc.x, top + fr * 0.15), fr * 0.6, col)
			draw_rect(Rect2(fc.x - fr * 0.65, top + fr * 0.15, fr * 1.3, fr * 0.25), col)
			draw_line(Vector2(fc.x, top - fr * 0.45), Vector2(fc.x, top - fr * 0.1), ink, w * 1.5)
			var a := _t * 14.0
			var half := fr * 0.55 * absf(cos(a))
			draw_line(Vector2(fc.x - half, top - fr * 0.48), Vector2(fc.x + half, top - fr * 0.48), Color("#FFCA28"), w * 2.5)
		"tophat":
			var top := fc.y - fr * 0.7
			draw_rect(Rect2(fc.x - fr * 0.75, top, fr * 1.5, fr * 0.16), col)
			draw_rect(Rect2(fc.x - fr * 0.45, top - fr * 0.8, fr * 0.9, fr * 0.82), col)
			draw_rect(Rect2(fc.x - fr * 0.45, top - fr * 0.2, fr * 0.9, fr * 0.14), Color("#E53935"))
		"horns":
			for sgn in [-1.0, 1.0]:
				var b := Vector2(fc.x + sgn * fr * 0.45, fc.y - fr * 0.78)
				draw_colored_polygon(PackedVector2Array([b + Vector2(-fr * 0.15, 0), b + Vector2(fr * 0.15, 0), b + Vector2(sgn * fr * 0.22, -fr * 0.45)]), col)
		"halo":
			var c := Vector2(fc.x, fc.y - fr * 1.05 + sin(_t * 2.0) * 1.5)
			draw_arc(c, fr * 0.45, 0, TAU, 32, col, w * 2.4)
		"crown":
			var base := fc.y - fr * 0.62
			var pts := PackedVector2Array([Vector2(fc.x - fr * 0.55, base), Vector2(fc.x + fr * 0.55, base), Vector2(fc.x + fr * 0.6, base - fr * 0.55),
				Vector2(fc.x + fr * 0.3, base - fr * 0.28), Vector2(fc.x, base - fr * 0.65), Vector2(fc.x - fr * 0.3, base - fr * 0.28), Vector2(fc.x - fr * 0.6, base - fr * 0.55)])
			draw_colored_polygon(pts, col)
			draw_circle(Vector2(fc.x, base - fr * 0.18), fr * 0.09, Color("#E53935"))
			draw_circle(Vector2(fc.x - fr * 0.32, base - fr * 0.12), fr * 0.06, Color("#1E88E5"))
			draw_circle(Vector2(fc.x + fr * 0.32, base - fr * 0.12), fr * 0.06, Color("#66BB6A"))
		"shades":
			var y := fc.y - fr * 0.08
			draw_rect(Rect2(fc.x - fr * 0.68, y - fr * 0.14, fr * 0.6, fr * 0.3), col)
			draw_rect(Rect2(fc.x + fr * 0.08, y - fr * 0.14, fr * 0.6, fr * 0.3), col)
			draw_line(Vector2(fc.x - fr * 0.1, y - fr * 0.06), Vector2(fc.x + fr * 0.1, y - fr * 0.06), col, w * 1.5)
			draw_line(Vector2(fc.x - fr * 0.6, y - fr * 0.08), Vector2(fc.x - fr * 0.4, y - fr * 0.08), Color(1, 1, 1, 0.5), w)
		"glasses":
			var y := fc.y - fr * 0.08
			draw_arc(Vector2(fc.x - fr * 0.36, y), fr * 0.24, 0, TAU, 24, col, w * 1.4)
			draw_arc(Vector2(fc.x + fr * 0.36, y), fr * 0.24, 0, TAU, 24, col, w * 1.4)
			draw_line(Vector2(fc.x - fr * 0.12, y), Vector2(fc.x + fr * 0.12, y), col, w * 1.4)
		"monocle":
			var c := Vector2(fc.x + fr * 0.36, fc.y - fr * 0.08)
			draw_arc(c, fr * 0.26, 0, TAU, 24, col, w * 1.6)
			draw_line(c + Vector2(fr * 0.18, fr * 0.2), c + Vector2(fr * 0.3, fr * 0.8), col, w)
		"mask":
			draw_rect(Rect2(fc.x - fr * 0.8, fc.y - fr * 0.28, fr * 1.6, fr * 0.36), col)
			draw_circle(Vector2(fc.x - fr * 0.3, fc.y - fr * 0.1), fr * 0.09, Color.WHITE)
			draw_circle(Vector2(fc.x + fr * 0.3, fc.y - fr * 0.1), fr * 0.09, Color.WHITE)
		"blush":
			var c2 := col
			c2.a = 0.7
			draw_circle(Vector2(fc.x - fr * 0.52, fc.y + fr * 0.22), fr * 0.15, c2)
			draw_circle(Vector2(fc.x + fr * 0.52, fc.y + fr * 0.22), fr * 0.15, c2)
		"wings":
			for sgn in [-1.0, 1.0]:
				var b := Vector2(fc.x + sgn * fr * 0.7, fc.y + fr * 0.1)
				var flap := sin(_t * 3.0) * fr * 0.06
				draw_colored_polygon(PackedVector2Array([b, b + Vector2(sgn * fr * 0.75, -fr * 0.75 - flap), b + Vector2(sgn * fr * 0.85, -fr * 0.1), b + Vector2(sgn * fr * 0.5, fr * 0.4)]), col)
				draw_polyline(PackedVector2Array([b, b + Vector2(sgn * fr * 0.75, -fr * 0.75 - flap), b + Vector2(sgn * fr * 0.85, -fr * 0.1), b + Vector2(sgn * fr * 0.5, fr * 0.4), b]), Color("#B0BEC5"), w)
		"cape":
			draw_colored_polygon(PackedVector2Array([Vector2(fc.x - fr * 0.7, fc.y + fr * 0.5), Vector2(fc.x + fr * 0.7, fc.y + fr * 0.5),
				Vector2(fc.x + fr * 1.15, s * 0.98), Vector2(fc.x - fr * 1.15, s * 0.98)]), col)
		"jetpack":
			for sgn in [-1.0, 1.0]:
				draw_rect(Rect2(fc.x + sgn * fr * 0.95 - fr * 0.22, fc.y - fr * 0.1, fr * 0.44, fr * 0.9), col)
				var fl := fr * (0.3 + 0.12 * sin(_t * 20.0 + sgn))
				draw_colored_polygon(PackedVector2Array([Vector2(fc.x + sgn * fr * 0.95 - fr * 0.18, fc.y + fr * 0.8),
					Vector2(fc.x + sgn * fr * 0.95 + fr * 0.18, fc.y + fr * 0.8), Vector2(fc.x + sgn * fr * 0.95, fc.y + fr * 0.8 + fl)]), Color("#FF7043"))
		"backpack":
			draw_rect(Rect2(fc.x + fr * 0.6, fc.y - fr * 0.1, fr * 0.55, fr * 0.95), col)
			draw_rect(Rect2(fc.x + fr * 0.65, fc.y + fr * 0.3, fr * 0.45, fr * 0.3), col.darkened(0.25))
		"guitar":
			var a := Vector2(fc.x - fr * 1.1, fc.y + fr * 0.9)
			var b := Vector2(fc.x + fr * 1.0, fc.y - fr * 0.9)
			draw_line(a, b, Color("#5D4037"), w * 2.5)
			draw_circle(a + (b - a) * 0.12, fr * 0.32, col)
		"sparkle", "hearts", "bubbles", "snow", "fire":
			for k in 6:
				var ph := fmod(_t * 0.5 + k / 6.0, 1.0)
				var ang := k * TAU / 6.0 + _t * 0.4
				var p := fc + Vector2(cos(ang), sin(ang)) * fr * (1.05 + 0.1 * sin(_t * 2 + k))
				if art in ["bubbles", "fire", "hearts"]:
					p = Vector2(fc.x + (k - 2.5) * fr * 0.38, s * (0.95 - ph * 0.9))
				var alpha := 1.0 - ph if art != "sparkle" else 0.6 + 0.4 * sin(_t * 5 + k)
				var c := col
				c.a = clampf(alpha, 0.0, 1.0)
				match art:
					"sparkle": _star(p, fr * 0.12, c)
					"hearts": _heart(p, fr * 0.11, c)
					"bubbles": draw_arc(p, fr * 0.1, 0, TAU, 12, c, w)
					"snow": draw_circle(p, fr * 0.06, c)
					"fire": draw_circle(p, fr * (0.12 * (1.0 - ph) + 0.03), c)
		"rainbow":
			var cols := [Color("#EF5350"), Color("#FFA726"), Color("#FFEE58"), Color("#66BB6A"), Color("#42A5F5"), Color("#AB47BC")]
			for k in cols.size():
				var c: Color = cols[k]
				c.a = 0.75
				draw_arc(fc, fr * (1.08 + k * 0.05), _t + k * 0.3, _t + k * 0.3 + PI * 1.2, 24, c, w)


func _star(p: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for k in 8:
		var a := k * TAU / 8.0
		pts.append(p + Vector2(cos(a), sin(a)) * (r if k % 2 == 0 else r * 0.4))
	draw_colored_polygon(pts, col)


func _heart(p: Vector2, r: float, col: Color) -> void:
	draw_circle(p + Vector2(-r * 0.5, 0), r * 0.55, col)
	draw_circle(p + Vector2(r * 0.5, 0), r * 0.55, col)
	draw_colored_polygon(PackedVector2Array([p + Vector2(-r * 1.02, r * 0.15), p + Vector2(r * 1.02, r * 0.15), p + Vector2(0, r * 1.2)]), col)
