class_name RotateFader
extends CanvasLayer
## Smooth orientation switch: fade to the background colour, turn the screen,
## wait for the new size (or a short timeout), lay out, then fade back in.
## The layout callback runs while the screen is covered, so the user never sees
## controls jump.

signal finished

const FADE_OUT := 0.14
const FADE_IN := 0.24
const MAX_WAIT := 0.9

var busy := false
var _veil: ColorRect


func _ready() -> void:
	layer = 100
	_veil = ColorRect.new()
	_veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_veil.modulate.a = 0.0
	add_child(_veil)


## Turns to `mode` and calls relayout once the new size is known.
func switch_to(mode: String, color: Color, relayout: Callable) -> void:
	if busy:
		return
	busy = true
	_veil.color = color
	_veil.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow taps mid-turn
	var out := create_tween()
	out.tween_property(_veil, "modulate:a", 1.0, FADE_OUT).set_trans(Tween.TRANS_SINE)
	await out.finished
	var before := get_viewport().get_visible_rect().size
	ScreenUtil.apply_orientation(mode)
	var waited := 0.0
	while waited < MAX_WAIT:
		await get_tree().process_frame
		waited += get_process_delta_time()
		var now := get_viewport().get_visible_rect().size
		if now != before:
			# Let the size settle for two frames (Android can report it in steps).
			await get_tree().process_frame
			await get_tree().process_frame
			break
	if OS.is_debug_build():
		print("[rotate] %s -> %s after %.2fs" % [before, get_viewport().get_visible_rect().size, waited])
	if relayout.is_valid():
		relayout.call()
	await get_tree().process_frame
	var back := create_tween()
	back.tween_property(_veil, "modulate:a", 0.0, FADE_IN).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await back.finished
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	busy = false
	finished.emit()
