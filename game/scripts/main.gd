extends Node
## App entry: menu, game screen, phone hosting, and headless server mode.

## Filled in after the Render deploy. Players can still change it in the menu.
const DEFAULT_SERVER_URL := "wss://YOUR-SERVICE.onrender.com"
const SETTINGS_PATH := "user://settings.cfg"
## UI is laid out in dp (short side = 360 dp) and scaled to the screen; see ScreenUtil.

var net: NetClient
var host_server: RefereeServer
var settings := ConfigFile.new()

# Menu
var menu_layer: CanvasLayer
var menu_root: Control
var name_edit: LineEdit
var room_edit: LineEdit
var server_edit: LineEdit
var friend_edit: LineEdit
var menu_status: Label
var menu_buttons: Array[Control] = []
var music_on := true
var orientation := "portrait"   # the player's choice; portrait by default
var fader: RotateFader
var voice: VoiceChat
var hud_buttons: Control
var hud_info_col: VBoxContainer
var hud_hosts: Label
var hud_voice: Label
var mic_btn: Button
var voice_btn: Button
var rotate_btn: Button
var hud_toast: Label
var _toast_tween: Tween
var cam_fov_target := 70.0
var cam_dist := 7.5
var cam_dist_target := 7.5

# Game
var world: Node3D
var camera: Camera3D
var player: LocalPlayer
var balls: BallView
var blocks: FoldingBlocks
var walls: PulseWalls
var music: Music
var remotes := {}   # id -> RemotePlayer
var hud_layer: CanvasLayer
var hud_root: Control
var touch: TouchControls
var hud_info: Label
var hud_banner: Label
var hud_drop: Label
var cam_yaw := 0.0
var cam_pitch := -0.35
var send_accum := 0.0
var corrections := 0
var flips_seen := 0
var mode := ""     # "online", "host", "friend"
var server_offset_ms := 0.0
var clock_synced := false
var server_gravity := 1.0

# Self-test (used by the cloud checks, never by players)
var autotest := ""
var autotest_t := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--server" in args:
		_run_dedicated_server()
		return
	for a in args:
		if a.begins_with("--autotest="):
			autotest = a.substr(11)
	get_tree().quit_on_go_back = false
	settings.load(SETTINGS_PATH)
	music_on = bool(settings.get_value("p", "music", true))
	orientation = "landscape" if settings.get_value("p", "orient", "portrait") == "landscape" else "portrait"
	ScreenUtil.apply_orientation(orientation)
	fader = RotateFader.new()
	add_child(fader)
	UiKit.dark = DisplayServer.is_dark_mode()
	net = NetClient.new()
	add_child(net)
	net.joined.connect(_on_joined)
	net.message.connect(_on_message)
	net.status_changed.connect(_on_status)
	net.gave_up.connect(_on_gave_up)
	voice = VoiceChat.new()
	add_child(voice)
	voice.setup(net)
	voice.changed.connect(_refresh_voice_ui)
	voice.notice.connect(_toast)
	get_viewport().size_changed.connect(_fit_roots)
	_build_menu()
	if autotest != "":
		_start_autotest()


# ---------------------------------------------------------------- server mode

func _run_dedicated_server() -> void:
	var port := Protocol.DEFAULT_PORT
	if OS.has_environment("PORT"):
		port = int(OS.get_environment("PORT"))
	host_server = RefereeServer.new()
	add_child(host_server)
	if host_server.start(port, "*") != OK:
		get_tree().quit(1)


# ------------------------------------------------------------- shared clock

## The referee's clock in seconds, estimated from snapshot timestamps.
func world_t() -> float:
	return (Time.get_ticks_msec() + server_offset_ms) / 1000.0


func _sync_clock(ts) -> void:
	if not (ts is float or ts is int):
		return
	var lat := maxf(float(net.latency_ms), 0.0)
	var sample := float(ts) + lat / 2.0 - Time.get_ticks_msec()
	if not clock_synced or absf(sample - server_offset_ms) > 400.0:
		server_offset_ms = sample
		clock_synced = true
	else:
		server_offset_ms = lerpf(server_offset_ms, sample, 0.05)


# ---------------------------------------------------------------------- menu

## A root control sized in dp and scaled up to the screen.
func _scaled_root(layer: CanvasLayer) -> Control:
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	return root


## Sizes the dp roots to the safe area (clear of camera holes and the gesture bar)
## and re-lays out the HUD. Runs on every resize and orientation change.
func _fit_roots() -> void:
	var vp := get_viewport()
	var k := ScreenUtil.dp(vp)
	var full := vp.get_visible_rect().size
	var ins := ScreenUtil.insets(vp)
	for r in [menu_root, hud_root]:
		if r and is_instance_valid(r):
			r.scale = Vector2(k, k)
			if r == menu_root:
				# The menu's background is full-screen; its content keeps off the cutout.
				r.position = Vector2(ins.l, ins.t)
				r.size = Vector2(full.x - ins.l - ins.r, full.y - ins.t) / k
			else:
				r.position = Vector2(ins.l, ins.t)
				r.size = Vector2(full.x - ins.l - ins.r, full.y - ins.t - ins.b) / k
	_layout_hud()
	if camera:
		_camera_targets(false)


func _set_orientation(mode: String) -> void:
	if mode == orientation or fader.busy:
		return
	orientation = mode
	settings.set_value("p", "orient", mode)
	settings.save(SETTINGS_PATH)
	var bg := UiKit.c("background") if world == null else Color(0.02, 0.02, 0.06)
	if touch:
		touch.release_all()
	fader.switch_to(mode, bg, func():
		_fit_roots()
		if world == null:
			_build_menu()
		_camera_targets(true))


func _build_menu() -> void:
	if menu_layer:
		menu_layer.queue_free()
	menu_buttons.clear()
	menu_layer = CanvasLayer.new()
	add_child(menu_layer)
	var bg := ColorRect.new()
	bg.color = UiKit.c("background")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_layer.add_child(bg)
	menu_root = _scaled_root(menu_layer)
	menu_root.mouse_filter = Control.MOUSE_FILTER_PASS
	var theme_btn := Button.new()
	theme_btn.flat = true
	theme_btn.icon = UiKit.icon_texture("sun" if UiKit.dark else "moon")
	theme_btn.add_theme_constant_override("icon_max_width", 24)
	for st in ["icon_normal_color", "icon_pressed_color", "icon_hover_color"]:
		theme_btn.add_theme_color_override(st, UiKit.c("on_background"))
	theme_btn.custom_minimum_size = Vector2(48, 48)
	theme_btn.focus_mode = Control.FOCUS_NONE
	theme_btn.pressed.connect(func():
		_save_settings()
		UiKit.dark = not UiKit.dark
		_build_menu())
	var page := UiKit.pinned_page("Block Party", Callable(), null, [theme_btn])
	menu_root.add_child(page[0])
	var content: VBoxContainer = page[1]

	var room_now := Protocol.sanitize_room(settings.get_value("p", "room", Protocol.DEFAULT_ROOM))
	var hero := UiKit.hero_card("Play online", "Join room %s on the Block Party server" % room_now, "play", _on_play_online)
	content.add_child(hero)
	menu_buttons.append(hero)
	menu_status = UiKit.label("", "body_medium", UiKit.c("error"))
	content.add_child(UiKit.margin(menu_status, 20, 0, 20, 0))

	content.add_child(UiKit.section_title("Play with friends"))
	var friends: Array = UiKit.card()
	content.add_child(friends[0])
	var host_row := UiKit.setting_row("wifi", "Host on this phone", "Friends on the same Wi-Fi or hotspot join you", "", UiKit.SKY_MEDIUM, _on_host)
	friends[1].add_child(host_row)
	menu_buttons.append(host_row)
	var fr: Array = UiKit.text_field("Friend's IP (192.168...)", settings.get_value("p", "friend", ""), 64, "Shown at the top of your friend's screen")
	friend_edit = fr[1]
	friends[1].add_child(UiKit.vspace(4))
	friends[1].add_child(fr[0])
	var join_btn := UiKit.outline_button("Join friend", "users", _on_join_friend)
	friends[1].add_child(UiKit.margin(join_btn, 16, 12, 16, 16))
	menu_buttons.append(join_btn)

	content.add_child(UiKit.section_title("You"))
	var nm: Array = UiKit.text_field("Your name", settings.get_value("p", "name", ""), 16)
	name_edit = nm[1]
	content.add_child(nm[0])
	content.add_child(UiKit.vspace(12))
	var rm: Array = UiKit.text_field("Room code", room_now, 6, "Everyone with the same code plays together")
	room_edit = rm[1]
	content.add_child(rm[0])

	content.add_child(UiKit.section_title("Sound"))
	var sound: Array = UiKit.card()
	content.add_child(sound[0])
	sound[1].add_child(UiKit.setting_row("sparkles", "Music", "The walls dance to it, and gravity flips on the drop",
		"On" if music_on else "Off", UiKit.PINK, func():
			_save_settings()
			music_on = not music_on
			settings.set_value("p", "music", music_on)
			settings.save(SETTINGS_PATH)
			_build_menu()))

	content.add_child(UiKit.section_title("Screen"))
	var screen_card: Array = UiKit.card()
	content.add_child(screen_card[0])
	var rot_row := HBoxContainer.new()
	rot_row.add_theme_constant_override("separation", 8)
	rot_row.add_child(UiKit.chip("Portrait", orientation == "portrait", func(): _save_settings(); _set_orientation("portrait")))
	rot_row.add_child(UiKit.chip("Landscape", orientation == "landscape", func(): _save_settings(); _set_orientation("landscape")))
	var rot_col := UiKit.vbox(8)
	rot_col.add_child(UiKit.label("Phone orientation", "title_medium", UiKit.c("on_surface")))
	rot_col.add_child(UiKit.label("Portrait is the default. You can also turn the screen from inside a game.", "body_medium", UiKit.c("on_surface_variant")))
	rot_col.add_child(rot_row)
	screen_card[1].add_child(UiKit.margin(rot_col, 16, 14, 16, 16))

	content.add_child(UiKit.section_title("Server"))
	var sv: Array = UiKit.text_field("Server address (wss://...)", settings.get_value("p", "server", DEFAULT_SERVER_URL), 200, "Used by Play online")
	server_edit = sv[1]
	content.add_child(sv[0])
	content.add_child(UiKit.end_padding())
	_fit_roots()


func _save_settings() -> void:
	if name_edit == null or not is_instance_valid(name_edit):
		return
	settings.set_value("p", "name", name_edit.text)
	settings.set_value("p", "room", room_edit.text)
	settings.set_value("p", "server", server_edit.text)
	settings.set_value("p", "friend", friend_edit.text)
	settings.set_value("p", "music", music_on)
	settings.save(SETTINGS_PATH)


func _set_menu_busy(busy: bool) -> void:
	for b in menu_buttons:
		if is_instance_valid(b):
			if b is BaseButton:
				b.disabled = busy
			else:
				b.mouse_filter = Control.MOUSE_FILTER_IGNORE if busy else Control.MOUSE_FILTER_PASS
				b.modulate.a = 0.5 if busy else 1.0


func _status(text: String, problem := true) -> void:
	menu_status.text = text
	menu_status.add_theme_color_override("font_color", UiKit.c("error") if problem else UiKit.c("on_surface_variant"))


func _player_name() -> String:
	var n := Protocol.sanitize_name(name_edit.text)
	if n == "Player":
		n = "Player%d" % (randi() % 900 + 100)
		name_edit.text = n
	return n


func _on_play_online() -> void:
	var url := server_edit.text.strip_edges()
	if url == "" or url.contains("YOUR-SERVICE"):
		_status("Type the server address first, under Server.")
		return
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		url = "wss://" + url.trim_prefix("https://").trim_prefix("http://")
		server_edit.text = url
	mode = "online"
	_connect(url)


func _on_host() -> void:
	host_server = RefereeServer.new()
	add_child(host_server)
	if host_server.start(Protocol.DEFAULT_PORT, "*") != OK:
		host_server.queue_free()
		host_server = null
		_status("Couldn't start hosting on port %d." % Protocol.DEFAULT_PORT)
		return
	mode = "host"
	_connect("ws://127.0.0.1:%d" % Protocol.DEFAULT_PORT)


func _on_join_friend() -> void:
	var ip := friend_edit.text.strip_edges()
	if ip == "":
		_status("Type your friend's IP address (shown on their screen).")
		return
	mode = "friend"
	var url := ip if ip.begins_with("ws") else "ws://%s" % ip
	if not ip.begins_with("ws") and not ip.contains(":"):
		url += ":%d" % Protocol.DEFAULT_PORT
	_connect(url)


func _connect(url: String) -> void:
	_save_settings()
	_set_menu_busy(true)
	_status("Connecting...", false)
	net.join(url, _player_name(), Protocol.sanitize_room(room_edit.text))


func _local_ips() -> Array:
	var out := []
	for ip in IP.get_local_addresses():
		if ip.begins_with("192.168.") or ip.begins_with("10.") or ip.begins_with("172."):
			out.append(ip)
	return out


# ---------------------------------------------------------------------- game

func _enter_game() -> void:
	if world:
		return
	menu_layer.visible = false
	clock_synced = false
	world = Node3D.new()
	add_child(world)
	blocks = WorldBuilder.build(world)
	blocks.clock = world_t
	balls = BallView.new()
	world.add_child(balls)
	music = Music.new()
	music.clock = world_t
	world.add_child(music)
	walls = PulseWalls.new()
	walls.music = music
	walls.clock = world_t
	world.add_child(walls)
	camera = Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	world.add_child(camera)
	camera.make_current()
	_camera_targets(true)

	hud_layer = CanvasLayer.new()
	add_child(hud_layer)
	touch = TouchControls.new()
	hud_layer.add_child(touch)
	touch.show_touch = DisplayServer.is_touchscreen_available() or autotest != ""
	touch.jump.connect(_on_jump)
	hud_root = _scaled_root(hud_layer)
	# Top-left: room info, host addresses and voice status, stacked.
	hud_info_col = VBoxContainer.new()
	hud_info_col.add_theme_constant_override("separation", 6)
	hud_info_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(hud_info_col)
	hud_info = UiKit.pill("")
	hud_info.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	hud_info_col.add_child(hud_info)
	hud_hosts = UiKit.pill("")
	hud_hosts.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	hud_hosts.visible = false
	hud_info_col.add_child(hud_hosts)
	hud_voice = UiKit.pill("")
	hud_voice.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	hud_voice.visible = false
	hud_info_col.add_child(hud_voice)
	# Top-right: mic, voice, rotate, leave. Round 44 dp targets, 8 dp apart.
	hud_buttons = HBoxContainer.new()
	hud_buttons.add_theme_constant_override("separation", 8)
	hud_root.add_child(hud_buttons)
	mic_btn = _hud_button("microphone", func(): voice.toggle_mic())
	voice_btn = _hud_button("speaker-wave", func(): voice.toggle_voice())
	rotate_btn = _hud_button("device-phone-mobile", func():
		_set_orientation("portrait" if orientation == "landscape" else "landscape"))
	var leave := _hud_button("x-mark", _leave_game)
	for b in [mic_btn, voice_btn, rotate_btn, leave]:
		hud_buttons.add_child(b)
	hud_drop = Label.new()
	hud_drop.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_drop.add_theme_font_override("font", UiKit.font("anton", 400))
	hud_drop.add_theme_font_size_override("font_size", 28)
	hud_drop.add_theme_color_override("font_color", Color.WHITE)
	hud_drop.add_theme_color_override("font_outline_color", UiKit.INK)
	hud_drop.add_theme_constant_override("outline_size", 8)
	hud_drop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(hud_drop)
	hud_banner = UiKit.pill("")
	hud_banner.visible = false
	hud_root.add_child(hud_banner)
	hud_toast = UiKit.pill("")
	hud_toast.modulate.a = 0.0
	hud_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud_root.add_child(hud_toast)
	_refresh_voice_ui()
	_fit_roots()


## A round, translucent HUD button with a Heroicon. 44 dp touch target.
func _hud_button(icon_name: String, cb: Callable) -> Button:
	var b := Button.new()
	b.icon = UiKit.icon_texture(icon_name)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.expand_icon = false
	b.add_theme_constant_override("icon_max_width", 22)
	for st in ["icon_normal_color", "icon_pressed_color", "icon_hover_color", "icon_focus_color"]:
		b.add_theme_color_override(st, Color.WHITE)
	b.add_theme_stylebox_override("normal", UiKit.box(Color(0, 0, 0, 0.45), 22, Color(1, 1, 1, 0.45), 1))
	b.add_theme_stylebox_override("hover", UiKit.box(Color(0, 0, 0, 0.45), 22, Color(1, 1, 1, 0.45), 1))
	b.add_theme_stylebox_override("pressed", UiKit.box(Color(0, 0, 0, 0.65), 22, Color(1, 1, 1, 0.8), 1))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.custom_minimum_size = Vector2(44, 44)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	UiKit.add_press_shrink(b)
	return b


## Places the HUD for the current shape. Landscape: info left, buttons right on
## one row. Portrait (narrow): buttons on the first row, info stacked under them.
## Everything stays inside the safe area, and the touch zones skip the buttons.
func _layout_hud() -> void:
	if hud_root == null or not is_instance_valid(hud_root) or hud_buttons == null:
		return
	var w := hud_root.size.x
	var bw := hud_buttons.get_combined_minimum_size().x
	var bh := 44.0
	hud_buttons.size = Vector2(bw, bh)
	hud_buttons.position = Vector2(w - bw - 4.0, 4.0)
	var info_w := hud_info_col.get_combined_minimum_size().x
	var narrow := w - bw - 16.0 < maxf(info_w, 260.0)
	if narrow:
		hud_info_col.position = Vector2(4.0, 4.0 + bh + 8.0)
	else:
		hud_info_col.position = Vector2(4.0, 4.0)
	var max_pill := w - 8.0 if narrow else w - bw - 20.0
	for p in [hud_info, hud_hosts, hud_voice]:
		p.custom_minimum_size.x = 0
		p.autowrap_mode = TextServer.AUTOWRAP_OFF
		if p.get_combined_minimum_size().x > max_pill:
			p.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			p.custom_minimum_size.x = max_pill
	hud_info_col.size = Vector2.ZERO
	var below := hud_info_col.position.y + hud_info_col.get_combined_minimum_size().y + 10.0
	var center_top := maxf(below, bh + 16.0) if narrow else bh + 24.0
	hud_drop.size = Vector2(w, 40)
	hud_drop.position = Vector2(0, center_top + 6.0)
	for p in [hud_banner, hud_toast]:
		p.custom_minimum_size.x = 0
		p.autowrap_mode = TextServer.AUTOWRAP_OFF
		if p.get_combined_minimum_size().x > w - 32.0:
			p.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			p.custom_minimum_size.x = w - 32.0
		p.size = Vector2.ZERO
	hud_banner.position = Vector2((w - hud_banner.get_combined_minimum_size().x) / 2.0, center_top + 52.0)
	hud_toast.position = Vector2((w - hud_toast.get_combined_minimum_size().x) / 2.0, center_top + 96.0)
	if touch:
		var rects: Array[Rect2] = []
		var k := ScreenUtil.dp(get_viewport())
		rects.append(Rect2(hud_root.position + hud_buttons.position * k - Vector2(6, 6) * k,
			(hud_buttons.size + Vector2(12, 12)) * k))
		touch.blocked_rects = rects
		touch.relayout()


func _toast(text: String) -> void:
	if hud_toast == null or not is_instance_valid(hud_toast):
		_status(text, false)
		return
	hud_toast.text = text
	_layout_hud()
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(hud_toast, "modulate:a", 1.0, 0.18)
	_toast_tween.tween_interval(2.6)
	_toast_tween.tween_property(hud_toast, "modulate:a", 0.0, 0.4)


func _refresh_voice_ui() -> void:
	if voice_btn == null or not is_instance_valid(voice_btn):
		return
	var on := voice.is_on()
	var busy := voice.state == VoiceChat.State.ASKING or voice.state == VoiceChat.State.STARTING
	voice_btn.icon = UiKit.icon_texture("speaker-wave")
	voice_btn.modulate = Color(1, 1, 1, 0.45) if voice.state == VoiceChat.State.UNAVAILABLE else Color.WHITE
	var on_box := UiKit.box(UiKit.SKY_MEDIUM if on else Color(0, 0, 0, 0.45), 22, Color(1, 1, 1, 0.8 if on else 0.45), 1)
	voice_btn.add_theme_stylebox_override("normal", on_box)
	voice_btn.add_theme_stylebox_override("hover", on_box)
	mic_btn.visible = on
	var lvl := float(voice.levels.get("me", 0.0))
	var mic_col := Color(0.85, 0.2, 0.25, 0.85) if not voice.mic_on else Color(0.15, 0.7, 0.4, 0.55 + clampf(lvl * 3.0, 0.0, 0.4))
	var mic_box := UiKit.box(mic_col, 22, Color(1, 1, 1, 0.8), 1)
	mic_btn.add_theme_stylebox_override("normal", mic_box)
	mic_btn.add_theme_stylebox_override("hover", mic_box)
	var txt := ""
	if busy:
		txt = "Starting voice..."
	elif on:
		var talking := []
		for id in voice.levels:
			if typeof(id) == TYPE_INT and float(voice.levels[id]) > 0.04 and remotes.has(id):
				talking.append(remotes[id].display_name if "display_name" in remotes[id] else "Player")
		txt = "Voice: %d of %d connected  ·  mic %s" % [voice.connected_count(), voice.talkers.size(), "on" if voice.mic_on else "muted"]
		if not talking.is_empty():
			txt += "  ·  talking: " + ", ".join(talking)
	elif voice.talkers.size() > 0:
		txt = "%d in voice. Tap the speaker to join" % voice.talkers.size()
	if hud_voice.text != txt:
		hud_voice.text = txt
		hud_voice.visible = txt != ""
		_layout_hud()


## Portrait shows less side-to-side, so the camera widens its view and pulls back
## a little; landscape goes back to the classic framing. Eased, never snapped,
## unless `snap` (first frame or under the rotate fade).
func _camera_targets(snap: bool) -> void:
	if camera == null:
		return
	var s := get_viewport().get_visible_rect().size
	var aspect := s.x / maxf(s.y, 1.0)
	if aspect >= 1.0:
		cam_fov_target = 70.0
		cam_dist_target = 7.5
	else:
		# Keep roughly a 52 degree horizontal view on tall screens.
		var h := deg_to_rad(52.0)
		cam_fov_target = clampf(rad_to_deg(2.0 * atan(tan(h / 2.0) / aspect)), 70.0, 92.0)
		cam_dist_target = 9.0
	if snap:
		camera.fov = cam_fov_target
		cam_dist = cam_dist_target


func _on_jump() -> void:
	if player:
		player.jump_pressed = true


func _leave_game() -> void:
	voice.shutdown()
	net.leave()
	if host_server:
		host_server.stop()
		host_server.queue_free()
		host_server = null
	if world:
		world.queue_free()
		world = null
	if hud_layer:
		hud_layer.queue_free()
		hud_layer = null
		hud_root = null
		hud_buttons = null
		voice_btn = null
		mic_btn = null
		hud_toast = null
	touch = null
	camera = null
	player = null
	music = null
	remotes.clear()
	menu_layer.visible = true
	_set_menu_busy(false)
	_status("", false)


func _on_joined(welcome: Dictionary) -> void:
	_enter_game()
	for id in remotes.keys():
		remotes[id].queue_free()
	remotes.clear()
	_sync_clock(welcome.get("ts"))
	var spawn = Protocol.parse_vec3(welcome.get("spawn"))
	if spawn == null:
		spawn = Protocol.SPAWN
	if player == null:
		player = LocalPlayer.new()
		world.add_child(player)
		player.setup(str(welcome.get("name", "You")), Protocol.color_for(int(welcome.get("c", 0))))
	player.teleport(spawn)
	var radii = welcome.get("ball_radii", [])
	if radii is Array:
		balls.setup(radii)
	for p in welcome.get("players", []):
		if p is Dictionary:
			_add_remote(p)
	hud_banner.visible = false
	voice.on_joined(welcome)
	if music_on and music and not music.playing:
		music.start()


func _add_remote(p: Dictionary) -> void:
	var id := int(p.get("id", -1))
	if id < 0 or id == net.my_id or remotes.has(id):
		return
	var pos = Protocol.parse_vec3(p.get("p"))
	var r := RemotePlayer.new()
	world.add_child(r)
	r.setup(id, Protocol.sanitize_name(p.get("name")), Protocol.color_for(int(p.get("c", 0))),
		pos if pos != null else Protocol.SPAWN, float(p.get("y", 0.0)))
	remotes[id] = r


func _on_message(msg: Dictionary) -> void:
	if world == null:
		return
	if voice.on_message(msg):
		return
	match msg.t:
		"snap":
			_sync_clock(msg.get("ts"))
			for entry in msg.get("pl", []):
				if not (entry is Array) or entry.size() != 5:
					continue
				var id := int(entry[0])
				if id == net.my_id:
					continue
				if not remotes.has(id):
					_add_remote({"id": id, "name": "Player", "p": [entry[1], entry[2], entry[3]]})
				var pos = Protocol.parse_vec3([entry[1], entry[2], entry[3]])
				var yaw = Protocol.parse_number(entry[4])
				if pos != null and yaw != null:
					remotes[id].push_state(pos, yaw)
			if msg.has("b") and msg.b is Array:
				balls.push_state(msg.b)
			if msg.get("w") is Array and msg.w.size() == 2 and player:
				player.wind = Vector2(float(msg.w[0]), float(msg.w[1])).limit_length(Protocol.WIND_MAX)
			if msg.has("g"):
				server_gravity = 1.0 if float(msg.g) >= 0.0 else -1.0
		"gravity":
			server_gravity = 1.0 if float(msg.get("g", 1.0)) >= 0.0 else -1.0
		"bump":
			var v = Protocol.parse_vec3(msg.get("v"))
			if v != null and player:
				player.knock((v as Vector3).limit_length(20.0))
		"join":
			if msg.get("p") is Dictionary:
				var p: Dictionary = msg.p
				if remotes.has(int(p.get("id", -1))):
					remotes[int(p.id)].queue_free()
					remotes.erase(int(p.id))
				_add_remote(p)
		"leave":
			var id := int(msg.get("id", -1))
			if remotes.has(id):
				remotes[id].queue_free()
				remotes.erase(id)
		"correct":
			var pos = Protocol.parse_vec3(msg.get("p"))
			if pos != null and player:
				player.teleport(pos)
				corrections += 1


func _on_status(text: String, is_problem: bool) -> void:
	if world and hud_banner:
		hud_banner.text = text
		hud_banner.visible = is_problem
	else:
		_status(text, is_problem)


func _on_gave_up(reason: String) -> void:
	if world:
		_leave_game()
	elif host_server:
		host_server.stop()
		host_server.queue_free()
		host_server = null
	_set_menu_busy(false)
	_status(reason)
	if autotest != "":
		print("AUTOTEST GAVE_UP ", reason)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if world:
			_leave_game()
		else:
			get_tree().quit()


## Gravity follows the beat clock, so it flips exactly on the drop together
## with the music and the folding blocks. The referee uses the same clock.
func _gravity_now() -> float:
	return BeatClock.gravity_sign(world_t()) if clock_synced else server_gravity


func _process(delta: float) -> void:
	if world == null or player == null:
		_autotest_tick(delta)
		return
	var g := _gravity_now()
	if g != player.gravity_sign:
		player.set_gravity_sign(g)
		flips_seen += 1
	# Camera look (flips with gravity so "down" stays under your feet)
	# Look speed per dp, so it feels the same on every screen and orientation.
	var look := touch.consume_look() / ScreenUtil.dp(get_viewport())
	cam_yaw -= look.x * 0.012
	cam_pitch = clampf(cam_pitch - look.y * 0.008, -1.1, 0.25)
	var ease_k := 1.0 - exp(-delta * 6.0)
	camera.fov = lerpf(camera.fov, cam_fov_target, ease_k)
	cam_dist = lerpf(cam_dist, cam_dist_target, ease_k)
	player.camera_yaw = cam_yaw
	var up := Vector3.UP * player.gravity_sign
	var pivot := player.global_position + up * 1.6
	var offset := Vector3(0, 0, cam_dist).rotated(Vector3.RIGHT, cam_pitch * player.gravity_sign).rotated(Vector3.UP, cam_yaw)
	camera.global_position = pivot + offset
	camera.look_at(pivot, up)
	# HUD
	var ping := ("%d ms" % net.latency_ms) if net.latency_ms >= 0 else "..."
	var info := "Room %s  ·  %d players  ·  %s" % [net.room, remotes.size() + 1, ping]
	var hosts := ""
	if mode == "host":
		var ips := _local_ips()
		hosts = "Friends join: %s" % (", ".join(ips) if not ips.is_empty() else "turn on Wi-Fi or hotspot")
	if hud_info.text != info or hud_hosts.text != hosts:
		hud_info.text = info
		hud_hosts.text = hosts
		hud_hosts.visible = hosts != ""
		_layout_hud()
	if voice.is_on():
		_refresh_voice_ui()
	var t := world_t()
	var until := BeatClock.until_drop(t)
	var since := BeatClock.since_drop(t)
	if clock_synced and until <= 3.0:
		hud_drop.text = "DROP IN %d" % ceili(until)
	elif clock_synced and since < 1.6:
		hud_drop.text = "GRAVITY FLIP!" if g < 0.0 else "GRAVITY BACK!"
	else:
		hud_drop.text = ""
	_autotest_tick(delta)


func _physics_process(delta: float) -> void:
	if player == null:
		return
	if autotest == "":
		player.move_input = touch.current_move()
	send_accum += delta
	if send_accum >= 1.0 / Protocol.SEND_HZ:
		send_accum = 0.0
		net.send({"t": "state", "p": Protocol.vec_to_array(player.global_position), "y": snappedf(player.facing(), 0.01)})


# ------------------------------------------------------------------ self-test

## Self-check for tests: every HUD piece inside the screen's safe area, and no two
## pieces (buttons, info pills, joystick, jump button) overlapping.
func _layout_report() -> String:
	var vp := get_viewport()
	var size := vp.get_visible_rect().size
	var ins := ScreenUtil.insets(vp)
	var safe := Rect2(ins.l, ins.t, size.x - ins.l - ins.r, size.y - ins.t - ins.b)
	var items := {}
	if hud_buttons:
		items["buttons"] = hud_buttons.get_global_rect()
		for p in [["info", hud_info], ["hosts", hud_hosts], ["voice", hud_voice]]:
			if p[1].visible and p[1].text != "":
				items[p[0]] = p[1].get_global_rect()
		if touch and touch.show_touch:
			var sr := touch.stick_radius()
			var jr := touch.jump_radius()
			var sh := touch._stick_home()
			var jc := touch._jump_center()
			items["stick"] = Rect2(sh - Vector2(sr, sr), Vector2(sr, sr) * 2.0)
			items["jump"] = Rect2(jc - Vector2(jr, jr), Vector2(jr, jr) * 2.0)
	elif menu_root:
		# The menu scrolls under the gesture bar like any app list; check sides and top only.
		var m := menu_root.get_global_rect()
		items["menu"] = Rect2(m.position, Vector2(m.size.x, minf(m.size.y, safe.end.y - m.position.y)))
	var problems := []
	var safe_grown := safe.grow(0.5)
	for n in items:
		if not safe_grown.encloses(items[n]):
			problems.append("%s outside safe area %s" % [n, str(items[n])])
	var names := items.keys()
	for i in names.size():
		for j in range(i + 1, names.size()):
			if items[names[i]].grow(-0.5).intersects(items[names[j]].grow(-0.5)):
				problems.append("%s overlaps %s" % [names[i], names[j]])
	var parts := []
	for n in items:
		var r: Rect2 = items[n]
		parts.append("%s=(%d,%d %dx%d)" % [n, r.position.x, r.position.y, r.size.x, r.size.y])
	return "viewport=%dx%d dp=%.2f orient=%s fov=%.1f problems=%s  %s" % [size.x, size.y, ScreenUtil.dp(vp),
		orientation, camera.fov if camera else 0.0, str(problems) if not problems.is_empty() else "none", " ".join(parts)]


func _start_autotest() -> void:
	name_edit.text = "Bot%d" % (OS.get_process_id() % 1000)
	if autotest == "host" or autotest == "host_rotate":
		_on_host()
	elif autotest == "menu":
		pass
	elif autotest.begins_with("join:"):
		server_edit.text = autotest.substr(5)
		mode = "online"
		_connect(server_edit.text)


func _autotest_tick(delta: float) -> void:
	if autotest == "":
		return
	autotest_t += delta
	if autotest.ends_with("_rotate") and autotest_t > 3.0 and not has_meta("rotated"):
		set_meta("rotated", true)
		_set_orientation("portrait" if orientation == "landscape" else "landscape")
	if player:
		# Walk in a slow circle and hop, like a player would.
		player.move_input = Vector2(sin(autotest_t * 0.8), cos(autotest_t * 0.8))
		if fmod(autotest_t, 2.0) < delta:
			player.jump_pressed = true
	var limit := float(OS.get_environment("AUTOTEST_SECONDS")) if OS.has_environment("AUTOTEST_SECONDS") else 12.0
	if autotest == "menu" and autotest_t > limit:
		print("AUTOTEST LAYOUT ", _layout_report())
		if OS.has_environment("AUTOTEST_SHOT"):
			get_viewport().get_texture().get_image().save_png(OS.get_environment("AUTOTEST_SHOT"))
		get_tree().quit()
		return
	if autotest_t > limit:
		var ball_info := "none"
		if balls and balls.snapshots_received > 0:
			var ps := balls.current_positions()
			ball_info = "%d balls, %d snapshots, first at %s" % [ps.size(), balls.snapshots_received, str(ps[0]) if ps.size() > 0 else "-"]
		var t := world_t()
		print("AUTOTEST RESULT in_room=%s id=%d remotes=%d corrections=%d ping=%d pos=%s balls=[%s] world_t=%.2f until_drop=%.2f g=%.0f server_g=%.0f flips=%d fold=%.2f music=%s bass=%.2f wall_max=%.2f" % [
			net.is_in_room(), net.my_id, remotes.size(), corrections, net.latency_ms,
			str(player.global_position) if player else "none", ball_info, t, BeatClock.until_drop(t),
			_gravity_now(), server_gravity, flips_seen, BeatClock.fold_amount(t), str(music.playing) if music else "none",
			music.band_energy(30.0, 160.0) if music else 0.0, walls.max_level() if walls else 0.0])
		print("AUTOTEST LAYOUT ", _layout_report())
		if OS.has_environment("AUTOTEST_SHOT"):
			get_viewport().get_texture().get_image().save_png(OS.get_environment("AUTOTEST_SHOT"))
		get_tree().quit()
