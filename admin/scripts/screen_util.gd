class_name ScreenUtil
extends RefCounted
## Screen helpers shared by the menu, the HUD and the touch controls.
## - One dp scale for both orientations (short side = 360 dp).
## - Safe-area insets (camera holes, rounded corners, gesture bars) in pixels.
## - User-controlled orientation: portrait by default, landscape on request.

const SHORT_SIDE_DP := 360.0    # desktop test windows; phones use their real density
const MIN_EDGE_DP := 8.0         # breathing room even on screens with no cutout
const MIN_BOTTOM_DP := 16.0      # keep thumbs off the gesture bar

static var _short_dp := 0.0


## Lays the whole canvas out in real dp, like a native app: the root viewport's short
## side is set to the phone's width in dp (pixels / density), so text and icons are
## rasterised at full screen resolution (no Control scaling, nothing blurry) and every
## size matches the phone's other apps. Call once at start and on every resize.
static func configure(root: Window) -> void:
	var win := Vector2(DisplayServer.window_get_size())
	if win.x <= 0.0 or win.y <= 0.0:
		return
	var short_px := minf(win.x, win.y)
	var want := SHORT_SIDE_DP
	if OS.has_feature("mobile"):
		var dpi := float(DisplayServer.screen_get_dpi())
		if dpi >= 100.0:
			want = clampf(short_px / (dpi / 160.0), 320.0, 1000.0)
	want = roundf(want)
	if absf(want - _short_dp) > 0.5 or root.content_scale_size != Vector2i(int(want), int(want)):
		_short_dp = want
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		root.content_scale_size = Vector2i(int(want), int(want))
		print("[screen] window %s px, short side %d dp" % [Vector2i(win), int(want)])


## Viewport pixels per dp. The root viewport is already laid out in dp (see configure),
## so this is 1.0; kept as a function so every size still goes through one place.
static func dp(vp: Viewport) -> float:
	return 1.0


static func is_landscape(vp: Viewport) -> bool:
	var s := vp.get_visible_rect().size
	return s.x > s.y


## Insets in viewport pixels: left, top, right, bottom. Reads the display's safe area
## (it excludes the camera cutout) and converts it from screen to viewport pixels.
static func insets(vp: Viewport) -> Dictionary:
	var visible := vp.get_visible_rect().size
	var k := dp(vp)
	var l := 0.0
	var t := 0.0
	var r := 0.0
	var b := 0.0
	if OS.has_feature("mobile"):
		var win := Vector2(DisplayServer.window_get_size())
		var safe := DisplayServer.get_display_safe_area()
		if win.x > 0.0 and win.y > 0.0 and safe.size.x > 0 and safe.size.y > 0:
			var sx := visible.x / win.x
			var sy := visible.y / win.y
			l = maxf(float(safe.position.x), 0.0) * sx
			t = maxf(float(safe.position.y), 0.0) * sy
			r = maxf(win.x - float(safe.end.x), 0.0) * sx
			b = maxf(win.y - float(safe.end.y), 0.0) * sy
	elif OS.get_environment("FAKE_INSETS") != "":
		# Desktop test runs: pretend to have a status bar and a navigation bar (in dp).
		var f := OS.get_environment("FAKE_INSETS").split(",")
		if f.size() == 4:
			l = float(f[0]); t = float(f[1]); r = float(f[2]); b = float(f[3])
	return {
		"rb": b,   # the real insets, with no minimum (for edge-to-edge bars)
		"rl": l,
		"rt": t,
		"rr": r,
		"l": maxf(l, MIN_EDGE_DP * k),
		"t": maxf(t, MIN_EDGE_DP * k),
		"r": maxf(r, MIN_EDGE_DP * k),
		"b": maxf(b, MIN_BOTTOM_DP * k),
	}


## "portrait" (default) or "landscape". Landscape follows the sensor, so the phone
## can be turned either way round.
static func apply_orientation(mode: String) -> void:
	if OS.has_feature("mobile"):
		DisplayServer.screen_set_orientation(
			DisplayServer.SCREEN_SENSOR_LANDSCAPE if mode == "landscape" else DisplayServer.SCREEN_PORTRAIT)
	elif DisplayServer.get_name() != "headless":
		# Desktop test runs: turn the window instead.
		var s := DisplayServer.window_get_size()
		var want_wide := mode == "landscape"
		if (s.x > s.y) != want_wide:
			var w := (Engine.get_main_loop() as SceneTree).root
			w.size = Vector2i(s.y, s.x)
			print("[screen] window turned to ", Vector2i(s.y, s.x))


## Height of the on-screen keyboard in viewport pixels (0 when hidden or on desktop).
static func keyboard_height(vp: Viewport) -> float:
	if not OS.has_feature("mobile"):
		return 0.0
	var kb := float(DisplayServer.virtual_keyboard_get_height())
	var win := Vector2(DisplayServer.window_get_size())
	if kb <= 0.0 or win.y <= 0.0:
		return 0.0
	# Edge-to-edge windows keep their size and the keyboard covers them; on older
	# Androids the window shrinks instead, and that part is already out of the way.
	var screen_h := float(DisplayServer.screen_get_size().y)
	var shrunk := maxf(screen_h - win.y, 0.0) if screen_h > win.y + 1.0 else 0.0
	return maxf(kb - shrunk, 0.0) * vp.get_visible_rect().size.y / win.y
