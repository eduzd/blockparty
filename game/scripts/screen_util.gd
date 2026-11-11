class_name ScreenUtil
extends RefCounted
## Screen helpers shared by the menu, the HUD and the touch controls.
## - One dp scale for both orientations (short side = 360 dp).
## - Safe-area insets (camera holes, rounded corners, gesture bars) in pixels.
## - User-controlled orientation: portrait by default, landscape on request.

const SHORT_SIDE_DP := 360.0
const MIN_EDGE_DP := 8.0         # breathing room even on screens with no cutout
const MIN_BOTTOM_DP := 16.0      # keep thumbs off the gesture bar


## Pixels per dp for this viewport. Stays the same when the phone turns.
static func dp(vp: Viewport) -> float:
	var s := vp.get_visible_rect().size
	return maxf(minf(s.x, s.y) / SHORT_SIDE_DP, 0.5)


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
	return {
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
			DisplayServer.window_set_size(Vector2i(s.y, s.x))
			print("[screen] window turned to ", Vector2i(s.y, s.x))
