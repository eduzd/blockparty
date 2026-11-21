extends SceneTree
## Plux 0.8.0: SpecPlay HUD and touch controls fit in portrait and landscape.
## godot --headless --path game -s tests/spec_layout.gd
## Checks every HUD control and every touch button lies inside the screen minus the
## simulated system bars, and that the buttons do not overlap the top HUD row.

const SIZES := [Vector2i(360, 800), Vector2i(412, 915), Vector2i(800, 360), Vector2i(915, 412), Vector2i(600, 960)]
const FILES := ["candy_coins.json", "ghost_maze.json"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var fails := 0
	for f in FILES:
		var raw = JSON.parse_string(FileAccess.get_file_as_string("res://tests/specs/" + f))
		var spec := PloxSpec.clean(raw)
		for sz in SIZES:
			root.size = sz
			OS.set_environment("FAKE_INSETS", "0,24,0,48" if sz.y > sz.x else "0,24,48,0")
			var g := SpecPlay.new()
			g.setup(spec, "A really quite long game title for testing", true)
			root.add_child(g)
			for i in 4:
				await process_frame
			g._fit()
			await process_frame
			var bad := _check(g, Vector2(sz))
			print("LAYOUT %s %dx%d: %s" % [f, sz.x, sz.y, "PASS" if bad.is_empty() else "FAIL " + str(bad)])
			if not bad.is_empty():
				fails += 1
			root.remove_child(g)
			g.free()
	OS.unset_environment("FAKE_INSETS")
	print("SPEC_LAYOUT DONE fails=%d" % fails)
	quit(1 if fails > 0 else 0)


func _check(g: SpecPlay, full: Vector2) -> Array:
	var bad := []
	var ins := ScreenUtil.insets(g.get_viewport())
	var safe := Rect2(Vector2(ins.l, ins.t), full - Vector2(ins.l + ins.r, ins.t + ins.b)).grow(0.5)
	var hud_rects := []
	for c in g._top.get_children():
		var ctl := c as Control
		if not ctl.visible or ctl.mouse_filter == Control.MOUSE_FILTER_IGNORE and not (ctl is Label):
			continue
		var r := ctl.get_global_rect()
		hud_rects.append(r)
		if not safe.encloses(r):
			bad.append("hud %s %s outside %s" % [ctl.get_class(), str(r), str(safe)])
	for b in g.touch.button_rects():
		var br: Rect2 = b
		if not safe.encloses(br):
			bad.append("button %s outside" % str(br))
		for hr in hud_rects:
			if br.intersects(hr):
				bad.append("button %s overlaps hud %s" % [str(br), str(hr)])
	return bad
