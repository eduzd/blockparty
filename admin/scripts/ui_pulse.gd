class_name AdminPulse
extends Control
## The live dot: a red radial glow that breathes between 92% and 106% over 1.4 s (reverse
## repeat, like the file's orb glow) around a solid record-red dot. Grey and still when offline.

var live := true:
	set(v):
		live = v
		set_process(v)
		queue_redraw()
var _ph := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(22, 22)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


func _process(delta: float) -> void:
	_ph = fmod(_ph + delta / 1.4, 2.0)
	queue_redraw()


func _draw() -> void:
	var c := size / 2.0
	if not live:
		draw_circle(c, 4.5, Color(AdminUi.ACC.ink, 0.45), true, -1.0, true)
		return
	var k := _ph if _ph <= 1.0 else 2.0 - _ph
	k = k * k * (3.0 - 2.0 * k)
	var s := lerpf(0.92, 1.06, k)
	var red: Color = AdminUi.ACC.red
	var glow := 11.0 * s
	for i in 6:
		var f := 1.0 - float(i) / 6.0
		draw_circle(c, glow * f, Color(red, 0.35 * 0.7 * (1.0 - f) + 0.04), true, -1.0, true)
	draw_circle(c, 4.5, Color("FF5A5A").lerp(red, 0.5), true, -1.0, true)
