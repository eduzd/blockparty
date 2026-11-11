extends Node
## App entry: menu, game screen, phone hosting, and headless server mode.

## Live Render server (free tier). Players can still change it in the menu.
const DEFAULT_SERVER_URL := "wss://blockparty-server.onrender.com"
const SETTINGS_PATH := "user://settings.cfg"
## UI is laid out in dp (short side = 360 dp) and scaled to the screen; see ScreenUtil.

var net: NetClient
var host_server: RefereeServer
var settings := ConfigFile.new()

# Menu
var menu_layer: CanvasLayer
var menu_root: Control
var menu_status: Label
var social: SocialClient
var shell: AppShell
var shell_state := {"tab": 0, "stack": []}   # survives menu rebuilds (theme, rotation)
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
var mode := ""     # "online", "solo" (practice with bots); "host" only in automated checks
var server_offset_ms := 0.0
var clock_synced := false
var server_gravity := 1.0
var current_room := ""   # the online room code, for invites and "Join" (0.7.0)
var game := "neon"   # which game the next join asks for: "neon" or "pop" (Pop-Up Panic)
var pop: PopGame

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
	_apply_theme()
	social = SocialClient.new()
	add_child(social)
	social.ensure_profile(str(settings.get_value("p", "name", "")))
	social.chat_message.connect(_on_chat_in_game)
	social.notice.connect(_on_notice_in_game)
	social.invite_in.connect(_on_invite_in)
	if autotest == "" or autotest.begins_with("social") or autotest == "welcome":
		social.start(server_url())
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
	# 0.6.0: the server only needs ~60 loops a second (balls step at 30 Hz,
	# snapshots go out at 20 Hz). Uncapped it spun ~145 times a second on a
	# tiny slice of CPU, which left less for the rooms themselves.
	Engine.max_fps = 60
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
	ScreenUtil.configure(get_tree().root)
	_sync_system_bars()
	var vp := get_viewport()
	var k := ScreenUtil.dp(vp)
	var full := vp.get_visible_rect().size
	var ins := ScreenUtil.insets(vp)
	for r in [menu_root, hud_root]:
		if r and is_instance_valid(r):
			r.scale = Vector2(k, k)
			if r == menu_root:
				# The menu's background is full-screen; its content keeps off the cutout and
				# status bar only, so the navigation bar can run edge to edge (each page
				# keeps its own 16dp margins).
				r.position = Vector2(ins.rl, ins.rt)
				r.size = Vector2(full.x - ins.rl - ins.rr, full.y - ins.rt) / k
				if shell and is_instance_valid(shell):
					shell.set_bottom_inset(float(ins.rb) / k)
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
	if not _revealed:
		menu_root.modulate.a = 0.0
	shell = AppShell.new(self, social, shell_state)
	menu_root.add_child(shell)
	_fit_roots()


## The game service address is built in and never shown to players. Automated checks can
## point the app at a local copy with the PLUX_SERVER environment variable.
func server_url() -> String:
	if OS.has_environment("PLUX_SERVER"):
		return OS.get_environment("PLUX_SERVER")
	return DEFAULT_SERVER_URL


## Theme: "system" follows the phone, or "light" / "dark".
func _apply_theme() -> void:
	var t := str(settings.get_value("p", "theme", "system"))
	UiKit.dark = DisplayServer.is_dark_mode() if t == "system" else t == "dark"
	_sync_system_bars()


## The phone's own status and navigation bars stay visible like in any normal app. The
## app draws behind them (edge to edge) and keeps its content inside the safe area; this
## colour tells Android whether their icons should be dark (light page) or light.
var _bar_color := Color(-1, -1, -1)
func _sync_system_bars() -> void:
	var col := UiKit.c("background") if world == null else Color(0.02, 0.02, 0.06)
	if col != _bar_color:
		_bar_color = col
		DisplayServer.window_set_color(col)


func set_theme(t: String) -> void:
	settings.set_value("p", "theme", t)
	settings.save(SETTINGS_PATH)
	var was := UiKit.dark
	_apply_theme()
	if was != UiKit.dark or true:
		_build_menu()


func _save_settings() -> void:
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
	if menu_status == null or not is_instance_valid(menu_status):
		if text != "" and problem and shell and is_instance_valid(shell):
			shell._toast(text)
		return
	menu_status.text = text
	menu_status.visible = text != ""
	menu_status.add_theme_color_override("font_color", UiKit.c("error") if problem else UiKit.c("on_surface_variant"))


func _player_name() -> String:
	var n := Protocol.sanitize_name(str(social.data.name))
	if n == "Player":
		n = Protocol.sanitize_name(str(settings.get_value("p", "name", "")))
	if n == "Player":
		n = "Player%d" % (randi() % 900 + 100)
	return n


func _on_play_online() -> void:
	var url := server_url()
	if url == "" or url.contains("YOUR-SERVICE"):
		_status("Can't connect right now. Try again.")
		return
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		url = "wss://" + url.trim_prefix("https://").trim_prefix("http://")
	mode = "online"
	game = "neon"
	_connect(url)


## 0.7.0: Join from an invite or from a friend's "Playing" row.
func join_friend_room(what: String, room: String) -> void:
	room = Protocol.sanitize_room(room)
	if room == "" or not (what in ["pop", "neon"]):
		return
	if net and net.is_in_room():
		_leave_game()
	settings.set_value("p", "room", room)
	if what == "pop":
		_on_pop_online()
	else:
		_on_play_online()


## In a game: pick friends to invite to this room.
func _open_invite_picker() -> void:
	if not social or current_room == "":
		return
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var picker := InvitePicker.new()
	picker.setup(social, game, current_room, "")
	picker.closed.connect(func(): layer.queue_free())
	picker.toast.connect(func(t): _toast(t))
	layer.add_child(picker)


## Pop-Up Panic online: same room code as everyone else, its own rooms on the server.
func _on_pop_online() -> void:
	var url := server_url()
	if url == "" or url.contains("YOUR-SERVICE"):
		_status("Can't connect right now. Try again.")
		return
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		url = "wss://" + url.trim_prefix("https://").trim_prefix("http://")
	mode = "online"
	game = "pop"
	_connect(url)


## Pop-Up Panic against bots, entirely on this phone: no internet or friends needed.
func _on_pop_solo() -> void:
	host_server = RefereeServer.new()
	host_server.balls_enabled = false
	add_child(host_server)
	if host_server.start(Protocol.DEFAULT_PORT + 1, "127.0.0.1") != OK:
		host_server.queue_free()
		host_server = null
		_status("Couldn't start practice mode.")
		return
	mode = "solo"
	game = "pop"
	_connect("ws://127.0.0.1:%d" % (Protocol.DEFAULT_PORT + 1))


## Only the automated checks use this (a game service on this computer). Players have no
## local Wi-Fi play since 0.7.0: everything goes through Plux online.
func _autotest_host() -> void:
	host_server = RefereeServer.new()
	add_child(host_server)
	if host_server.start(Protocol.DEFAULT_PORT, "127.0.0.1") != OK:
		host_server.queue_free()
		host_server = null
		_status("Can't start right now. Try again.")
		return
	mode = "host"
	game = "neon"
	_connect("ws://127.0.0.1:%d" % Protocol.DEFAULT_PORT)


func _connect(url: String) -> void:
	_save_settings()
	_set_menu_busy(true)
	_status("Connecting...", false)
	var room := Protocol.sanitize_room(str(settings.get_value("p", "room", Protocol.DEFAULT_ROOM)))
	var extra := {}
	if game == "pop":
		var bots := int(settings.get_value("p", "pop_bots", 3))
		if mode == "solo":
			room = "SOLO"
			bots = maxi(bots, 1)
		extra = {"g": "pop", "ch": int(settings.get_value("p", "pop_ch", 0)), "bots": bots}
		# 0.6.0: a one-use ticket tells the server which account to pay Plux to.
	# 0.6.0/0.7.0: a one-use ticket tells the server which account to pay Plux to.
	if social and social.pop_ticket != "" and mode == "online":
		extra["tk"] = social.pop_ticket
		social.pop_ticket = ""
	current_room = room if mode == "online" else ""
	if social:
		social.set_playing(game if game in ["pop", "neon"] else "neon", current_room)
	net.join(url, _player_name(), room, extra)


# ---------------------------------------------------------------------- game

func _enter_game() -> void:
	if world:
		return
	menu_layer.visible = false
	clock_synced = false
	world = Node3D.new()
	add_child(world)
	_sync_system_bars()
	if game == "pop":
		pop = PopGame.new(self)
		world.add_child(pop)
		pop.build()
	else:
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
	if pop:
		touch.action_label = "BONK"
		touch.jump_label = "HOP"
		touch.action.connect(pop.on_bonk)
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
	var row: Array = [mic_btn, voice_btn, rotate_btn, leave]
	if mode == "online" and social and social.feature("invites"):
		row.insert(0, _hud_button("user-plus", func(): _open_invite_picker()))
	for b in row:
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
	if pop:
		pop.build_hud(hud_root)
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
	if pop:
		pop.layout_hud(w, hud_root.size.y, center_top)
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
	if pop:
		pop.on_jump()
	elif player:
		player.jump_pressed = true


func _leave_game() -> void:
	voice.shutdown()
	net.leave()
	if social:
		social.set_playing("")
		social.request({"t": "s_ticket"})   # fresh ticket for the next round
	if host_server:
		host_server.stop()
		host_server.queue_free()
		host_server = null
	if world:
		world.queue_free()
		world = null
		_sync_system_bars()
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
	pop = null
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
	if pop:
		pop.on_welcome(welcome)
		hud_banner.visible = false
		voice.on_joined(welcome)
		return
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
	if pop:
		pop.on_message(msg)
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
		elif shell and is_instance_valid(shell) and shell.back():
			pass
		else:
			get_tree().quit()
	elif what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if social:
			social.reconnect_now()
		if world == null and str(settings.get_value("p", "theme", "system")) == "system" and DisplayServer.is_dark_mode() != UiKit.dark:
			_apply_theme()
			_build_menu()


## Friend messages and requests while playing show as a game toast.
func _on_chat_in_game(uid: String, m: Dictionary) -> void:
	if world:
		var u: Dictionary = social.card_for(uid)
		_toast("%s: %s" % [str(u.get("name", "Friend")), str(m.get("text", "")).replace("\n", " ").left(50)])


func _on_notice_in_game(kind: String, who: Dictionary) -> void:
	if world and kind == "request":
		_toast("%s sent you a friend request" % str(who.get("name", "Someone")))


## Gravity follows the beat clock, so it flips exactly on the drop together
## with the music and the folding blocks. The referee uses the same clock.
func _gravity_now() -> float:
	return BeatClock.gravity_sign(world_t()) if clock_synced else server_gravity


var _last_insets := {}
var _insets_still := 0.0
var _since_start := 0.0
var _revealed := false
func _watch_insets(delta: float) -> void:
	# Android reports the status bar, cutout and navigation bar a moment after start and
	# again when they change: re-fit at once, and keep the menu hidden until they have
	# settled, so nothing visibly jumps when the app opens.
	_since_start += delta
	var ins := ScreenUtil.insets(get_viewport())
	if ins != _last_insets:
		_last_insets = ins
		_insets_still = 0.0
		_fit_roots()
	else:
		_insets_still += delta
	if not _revealed and menu_root and (_insets_still > 0.2 or _since_start > 1.5):
		_revealed = true
		var tw := menu_root.create_tween()
		tw.tween_property(menu_root, "modulate:a", 1.0, 0.2)


func _process(delta: float) -> void:
	_watch_insets(delta)
	if pop and world and camera:
		pop.frame(delta, camera)
		_update_hud_info()
		_autotest_tick(delta)
		return
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
	_update_hud_info()
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


func _update_hud_info() -> void:
	var ping := ("%d ms" % net.latency_ms) if net.latency_ms >= 0 else "..."
	var info := "Room %s  ·  %d players  ·  %s" % [net.room, remotes.size() + 1, ping]
	if mode == "solo":
		info = "Practice  ·  you + %d bots" % remotes.size()
	var hosts := ""   # 0.7.0: local Wi-Fi play is gone, so no addresses are ever shown
	if hud_info.text != info or hud_hosts.text != hosts:
		hud_info.text = info
		hud_hosts.text = hosts
		hud_hosts.visible = hosts != ""
		_layout_hud()
	if voice.is_on():
		_refresh_voice_ui()


func _physics_process(delta: float) -> void:
	if pop:
		pop.physics(delta)
		return
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
	var problems := []
	if hud_buttons:
		items["buttons"] = hud_buttons.get_global_rect()
		var pills := [["info", hud_info], ["hosts", hud_hosts], ["voice", hud_voice]]
		if pop and pop.leader_pill:
			pills.append(["leader", pop.leader_pill])
		for p in pills:
			if p[1].visible and p[1].text != "":
				items[p[0]] = p[1].get_global_rect()
		if touch and touch.show_touch:
			var sr := touch.stick_radius()
			var sh := touch._stick_home()
			items["stick"] = Rect2(sh - Vector2(sr, sr), Vector2(sr, sr) * 2.0)
			var br: Array = touch.button_rects()
			items["jump"] = br[0]
			if br.size() > 1:
				items["bonk"] = br[1]
		if pop:
			items.merge(pop.layout_items())
	elif menu_root:
		# The tabs run edge to edge, so the menu is checked against the real insets
		# (camera cutout, status bar) without the 8dp minimum the HUD uses.
		var m := menu_root.get_global_rect()
		var real := Rect2(ins.rl, ins.rt, size.x - ins.rl - ins.rr, size.y - ins.rt)
		if not real.grow(0.5).encloses(m):
			problems.append("menu outside the screen's safe area %s" % str(m))
	var safe_grown := safe.grow(0.5)
	for n in items:
		if not safe_grown.encloses(items[n]):
			problems.append("%s outside safe area %s" % [n, str(items[n])])
	var names := items.keys()
	for i in names.size():
		for j in range(i + 1, names.size()):
			var ri: Rect2 = items[names[i]]
			var rj: Rect2 = items[names[j]]
			if [names[i], names[j]].has("jump") and [names[i], names[j]].has("bonk"):
				# Two round buttons: compare their circles (and the touch zones around them).
				var gap := ri.get_center().distance_to(rj.get_center()) - ri.size.x * 0.5 * 1.3 - rj.size.x * 0.5 * 1.2
				if gap < 0.0:
					problems.append("jump touch zone overlaps bonk by %.1f px" % -gap)
			elif ri.grow(-0.5).intersects(rj.grow(-0.5)):
				problems.append("%s overlaps %s" % [names[i], names[j]])
	var parts := []
	for n in items:
		var r: Rect2 = items[n]
		parts.append("%s=(%d,%d %dx%d)" % [n, r.position.x, r.position.y, r.size.x, r.size.y])
	return "viewport=%dx%d dp=%.2f orient=%s fov=%.1f problems=%s  %s" % [size.x, size.y, ScreenUtil.dp(vp),
		orientation, camera.fov if camera else 0.0, str(problems) if not problems.is_empty() else "none", " ".join(parts)]


func _start_autotest() -> void:
	if not autotest.begins_with("social") and autotest != "menu":
		social.data.name = "Bot%d" % (OS.get_process_id() % 1000)
	if autotest == "host" or autotest == "host_rotate":
		_autotest_host()
	elif autotest.begins_with("pop_solo"):
		settings.set_value("p", "pop_bots", int(OS.get_environment("POP_BOTS")) if OS.has_environment("POP_BOTS") else 4)
		settings.set_value("p", "pop_ch", OS.get_process_id() % 8)
		_on_pop_solo()
	elif autotest.begins_with("popjoin:"):
		settings.set_value("p", "pop_bots", int(OS.get_environment("POP_BOTS")) if OS.has_environment("POP_BOTS") else 0)
		settings.set_value("p", "pop_ch", OS.get_process_id() % 8)
		if OS.has_environment("POP_ROOM"):
			settings.set_value("p", "room", OS.get_environment("POP_ROOM"))
		mode = "online"
		game = "pop"
		_connect(autotest.substr(8))
	elif autotest == "studio" or autotest == "studio_rotate":
		pass   # driven from _autotest_tick once the menu is up
	elif autotest == "welcome":
		_autotest_welcome()
	elif autotest == "menu" or autotest.begins_with("social"):
		_autotest_social_setup()
	elif autotest.begins_with("join:"):
		mode = "online"
		_connect(autotest.substr(5))


func _autotest_tick(delta: float) -> void:
	if autotest == "" or autotest == "welcome":
		return
	autotest_t += delta
	if autotest.ends_with("_rotate") and autotest_t > 3.0 and not has_meta("rotated"):
		set_meta("rotated", true)
		_set_orientation("portrait" if orientation == "landscape" else "landscape")
	if pop and pop.me:
		_autotest_pop(delta)
	if player:
		# Walk in a slow circle and hop, like a player would.
		player.move_input = Vector2(sin(autotest_t * 0.8), cos(autotest_t * 0.8))
		if fmod(autotest_t, 2.0) < delta:
			player.jump_pressed = true
	var limit := float(OS.get_environment("AUTOTEST_SECONDS")) if OS.has_environment("AUTOTEST_SECONDS") else 12.0
	if autotest.begins_with("studio"):
		_autotest_studio(limit)
		return
	if autotest.begins_with("social") or autotest == "menu":
		_autotest_social_tick()
	if autotest == "menu" and OS.has_environment("AUTOTEST_TAB") and shell and autotest_t > 1.0 and not has_meta("tab_done"):
		set_meta("tab_done", true)
		shell.select_tab(int(OS.get_environment("AUTOTEST_TAB")))
	if autotest == "menu" and OS.has_environment("AUTOTEST_TAP_SOLO") and autotest_t > 3.0 and not has_meta("solo_done"):
		set_meta("solo_done", true)
		autotest = "pop_solo_from_menu"
		_on_pop_solo()
	if (autotest == "menu" or autotest.begins_with("social")) and autotest_t > limit:
		_dump_ui()
		print("AUTOTEST LAYOUT ", _layout_report())
		if OS.has_environment("AUTOTEST_SHOT"):
			get_viewport().get_texture().get_image().save_png(OS.get_environment("AUTOTEST_SHOT"))
		get_tree().quit()
		return
	if autotest_t > limit and pop:
		print("AUTOTEST POP in_room=%s id=%d others=%d phase=%s round=%d left=%.1f frenzy=%.2f pos=%s out=%s stats=%s scores=%s" % [
			net.is_in_room(), net.my_id, remotes.size(), pop.phase, pop.round_no, pop.time_left(), pop.frenzy(),
			str(pop.me.position) if pop.me else "none", str(pop.me.out) if pop.me else "-", str(pop.stats), str(pop.scores)])
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


## Plays Pop-Up Panic like a (slightly aimless) person: chase the nearest
## character, bonk when close, hop now and then; turn the screen if asked.
func _autotest_pop(_delta: float) -> void:
	var me: PopPlayer = pop.me
	var target := Vector3.ZERO
	var best := INF
	for r in remotes.values():
		var d: float = r.position.distance_to(me.position)
		if r.visible and d < best and PopRules.on_table(r.position):
			best = d
			target = r.position
	var to := Vector3(target.x - me.position.x, 0, target.z - me.position.z)
	var r_me := Vector2(me.position.x, me.position.z).length()
	if r_me > PopRules.ARENA_R - 2.0:
		to = -Vector3(me.position.x, 0, me.position.z)
	# Turn world direction into stick input relative to the camera.
	var fwd := Vector3(-sin(pop.cam_yaw), 0, -cos(pop.cam_yaw))
	var right := Vector3(cos(pop.cam_yaw), 0, -sin(pop.cam_yaw))
	var dn := to.normalized() if to.length() > 0.01 else Vector3.ZERO
	me.move_input = Vector2(dn.dot(right), dn.dot(fwd)) * (0.9 if best > 1.6 else 0.3)
	if best < PopRules.BONK_RANGE and fmod(autotest_t, 0.7) < 0.02:
		pop.on_bonk()
	if fmod(autotest_t, 3.1) < 0.02:
		me.jump_pressed = true
	if OS.has_environment("POP_LOOK") and fmod(autotest_t, 5.0) < 2.5:
		touch.look_delta += Vector2(3.0, 0.0)


# ------------------------------------------------------------- UI autotest
# AUTOTEST_SCREEN picks what to show: home, games, chat, profile, search,
# user:<uid>, chat:<uid>, requests, edit, settings, list. AUTOTEST_TAPS is a list of
# "x,y@seconds" taps in viewport pixels, to drive the real buttons.

func _autotest_social_setup() -> void:
	var scr := OS.get_environment("AUTOTEST_SCREEN") if OS.has_environment("AUTOTEST_SCREEN") else "home"
	await get_tree().create_timer(0.3).timeout
	if not shell or not is_instance_valid(shell):
		return
	match scr.get_slice(":", 0):
		"home": shell.select_tab(0)
		"games": shell.select_tab(1)
		"chat": shell.select_tab(2)
		"profile": shell.select_tab(3)
		"search": shell.push({"k": "search"})
		"requests": shell.push({"k": "requests"})
		"edit": shell.select_tab(3); shell.push({"k": "edit"})
		"settings": shell.select_tab(3); shell.push({"k": "settings"})
		"password": shell.select_tab(3); shell.push({"k": "settings"}); shell.push({"k": "password"})
		"login": shell.select_tab(3); shell.push({"k": "settings"}); shell.push({"k": "login"})
		"list": shell.push({"k": "list", "uid": social.uid, "kind": "friends"})
		"shop": shell.push({"k": "shop"})
		"item": shell.push({"k": "item", "id": scr.get_slice(":", 1)})
		"user": shell.push({"k": "user", "uid": scr.get_slice(":", 1)})
		"chat_with": shell.select_tab(2); shell.push({"k": "chat", "uid": scr.get_slice(":", 1)})
		"firstfriend":
			await get_tree().create_timer(4.0).timeout
			if not social.data.friends.is_empty():
				shell.select_tab(2)
				shell.push({"k": "chat", "uid": social.data.friends.keys()[0]})


var _taps_done := {}

func _autotest_social_tick() -> void:
	if not OS.has_environment("AUTOTEST_TAPS"):
		return
	var taps := OS.get_environment("AUTOTEST_TAPS").split(";", false)
	for i in taps.size():
		if _taps_done.has(i):
			continue
		var parts := taps[i].split("@")
		if parts.size() != 2 or autotest_t < float(parts[1]):
			continue
		_taps_done[i] = true
		if parts[0].begins_with("type:"):
			var txt := parts[0].substr(5)
			var f := get_viewport().gui_get_focus_owner()
			if f is LineEdit:
				f.insert_text_at_caret(txt)
				f.text_changed.emit(f.text)
			print("AUTOTEST TYPE ", txt, " into ", f)
			continue
		if parts[0] == "enter":
			var f2 := get_viewport().gui_get_focus_owner()
			if f2 is LineEdit:
				f2.text_submitted.emit(f2.text)
			continue
		if parts[0] == "dump":
			_dump_ui()
			continue
		if parts[0] == "shot":
			if OS.has_environment("AUTOTEST_SHOT"):
				get_viewport().get_texture().get_image().save_png(OS.get_environment("AUTOTEST_SHOT").replace(".png", "_%.0f.png" % autotest_t))
			continue
		var xy := parts[0].split(",")
		var pos := Vector2(float(xy[0]), float(xy[1]))
		for pressed in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = pressed
			ev.position = pos
			ev.global_position = pos
			Input.parse_input_event(ev)
		print("AUTOTEST TAP ", pos)


## Prints what is on screen: each visible label, button and field with its rect, and
## any visible control that sticks out of the screen sideways or overlaps the nav bar.
func _dump_ui() -> void:
	var vp := get_viewport().get_visible_rect()
	var lines := []
	var nav_rect := Rect2()
	if shell and shell._nav and is_instance_valid(shell._nav) and shell.state.stack.is_empty():
		nav_rect = shell._nav.get_global_rect()
	var stack := [menu_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		if not (n is Control) or not n.is_visible_in_tree():
			continue
		var r: Rect2 = n.get_global_rect()
		if r.size.x < 1 or r.size.y < 1:
			continue
		var on_screen := r.intersects(vp)
		if not on_screen:
			continue
		var txt := ""
		if n is Label:
			txt = "L:" + n.text
		elif n is Button:
			txt = "B:" + n.text + (" (icon)" if n.icon else "") + (" [disabled]" if n.disabled else "")
		elif n is LineEdit:
			txt = "F:" + (n.text if n.text != "" else "(" + n.placeholder_text + ")")
		if txt == "":
			continue
		var flags := ""
		if r.position.x < -0.5 or r.end.x > vp.end.x + 0.5:
			flags += " !SIDE"
		if nav_rect.size.y > 0 and not shell._nav.is_ancestor_of(n) and r.end.y > nav_rect.position.y + 1 and r.position.y < nav_rect.position.y - 1:
			# partly under the nav bar: fine for scrolled content, flagged for reference
			flags += " ~undernav"
		if n is Label and n.clip_text and n.get_minimum_size().x > 0:
			var f: Font = n.get_theme_font("font")
			var fs: int = n.get_theme_font_size("font_size")
			if f and f.get_string_size(n.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > n.size.x + 1:
				flags += " ...TRUNC"
		lines.append([r.position.y, r.position.x, "%s @(%d,%d %dx%d)%s" % [txt.replace("\n", "/").left(70), r.position.x, r.position.y, r.size.x, r.size.y, flags]])
	lines.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	print("AUTOTEST UI BEGIN nav=", nav_rect)
	for l in lines:
		print("  ", l[2])
	print("AUTOTEST UI END")


# ------------------------------------------------------------------ 0.7.0 invites
var _invite_layer: CanvasLayer

## A friend invited you: a card slides in with Join and Decline, in the app or in a game.
func _on_invite_in(inv: Dictionary) -> void:
	if _invite_layer and is_instance_valid(_invite_layer):
		_invite_layer.queue_free()
	var layer := CanvasLayer.new()
	layer.layer = 60
	add_child(layer)
	_invite_layer = layer
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var vp := get_viewport()
	var k := ScreenUtil.dp(vp)
	var ins := ScreenUtil.insets(vp)
	var full := vp.get_visible_rect().size
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiKit.pad(UiKit.box(UiKit.c("surface_container_high"), 24, UiKit.c("outline_variant"), 1), 16, 14))
	var w := minf(full.x / k - 24.0, 420.0)
	panel.custom_minimum_size = Vector2(w, 0)
	panel.scale = Vector2(k, k)
	panel.position = Vector2((full.x - w * k) / 2.0, ins.t + 10.0 * k)
	root.add_child(panel)
	var v := UiKit.vbox(10)
	panel.add_child(v)
	var from: Dictionary = inv.get("from", {})
	var h := UiKit.hbox(12)
	h.add_child(UiKit.avatar(40, str(from.get("name", "?")), int(from.get("av", -1))))
	var col := UiKit.vbox(0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UiKit.label("%s invited you" % str(from.get("name", "A friend")), "title_medium", UiKit.c("on_surface"), false))
	col.add_child(UiKit.label("to play " + str(inv.get("title", "a game")), "body_medium", UiKit.c("on_surface_variant"), false))
	h.add_child(col)
	v.add_child(h)
	var row := UiKit.hbox(10)
	var close := func(join: bool):
		social.request({"t": "s_invite_reply", "to": str(from.get("uid", "")), "join": join})
		social.invites.erase(inv)
		if is_instance_valid(layer):
			layer.queue_free()
	var no := UiKit.outline_button("Decline", "x-mark", func(): close.call(false))
	no.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(no)
	var yes := UiKit.primary_button("Join", "play", func():
		close.call(true)
		var what := str(inv.get("what", ""))
		if what == "game":
			if shell:
				shell.join_playing({"kind": "game", "gid": str(inv.get("gid", ""))})
		else:
			join_friend_room(what, str(inv.get("room", ""))))
	yes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(yes)
	v.add_child(row)
	panel.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, 0.18)
	# It goes away by itself after 30 seconds (counts as no answer).
	get_tree().create_timer(30.0).timeout.connect(func():
		if is_instance_valid(layer):
			layer.queue_free())


# ------------------------------------------------------------------ 0.7.0 Studio play
var studio_play: StudioPlay
var _studio_gid := ""

## Plays a Studio level on this phone. From the editor (can_edit) the pencil goes back to it.
func play_studio(level: Dictionary, title: String, can_edit: bool, gid: String) -> void:
	if studio_play and is_instance_valid(studio_play):
		studio_play.queue_free()
	_studio_gid = gid
	if menu_root and is_instance_valid(menu_root):
		menu_root.visible = false
	studio_play = StudioPlay.new()
	var col := Color("#335FFF")
	studio_play.setup(level, title, can_edit, str(social.data.get("name", "You")), col)
	studio_play.finished.connect(_on_studio_finished)
	add_child(studio_play)
	social.set_playing("game:" + gid if gid != "" else "studio")


func _on_studio_finished(r: Dictionary) -> void:
	if r.get("won", false) and r.get("partial", false) and _studio_gid != "":
		social.request({"t": "s_game_done", "gid": _studio_gid, "ms": int(r.get("ms", 0)), "stars": int(r.get("stars", 0))})
	if not r.get("exit", false):
		return
	if studio_play and is_instance_valid(studio_play):
		studio_play.queue_free()
	studio_play = null
	social.set_playing("")
	if menu_root and is_instance_valid(menu_root):
		menu_root.visible = true
	_sync_system_bars()


## Studio check: build from words on the phone, play it, walk around, go back to the
## editor, change it in words and by hand, check the level stays valid at every step.
func _autotest_studio(limit: float) -> void:
	if shell == null:
		return
	var st := shell.studio
	var step := int(get_meta("st_step", 0))
	if step == 0 and autotest_t > 1.0:
		shell.select_tab(1)
		shell.push({"k": "studio"})
		set_meta("st_step", 1)
	elif step == 1 and autotest_t > 2.0:
		st.build_from_words(OS.get_environment("STUDIO_PROMPT") if OS.has_environment("STUDIO_PROMPT") else "A hard lava obby with jump pads and stars at night")
		print("AUTOTEST STUDIO built parts=%d check='%s' title=%s sky=%d playing=%s" % [st.level.parts.size(), PloxLevel.check(st.level), st.level.title, st.level.sky, str(studio_play != null)])
		set_meta("st_step", 2)
	elif step == 2:
		if studio_play and studio_play.player:
			studio_play.test_move = Vector2(sin(autotest_t) * 0.3, -1.0)
			if fmod(autotest_t, 1.5) < 0.02:
				studio_play.player.jump_pressed = true
		if autotest_t > limit * 0.5:
			print("AUTOTEST STUDIO play pos=%s stars=%d/%d" % [str(studio_play.player.global_position), studio_play._stars, studio_play._stars_total])
			studio_play._exit(true)
			set_meta("st_step", 3)
	elif step == 3:
		for w in ["Make it harder", "Add lava", "Add jump pads", "Add moving platforms", "Make it easier", "Add stars", "Make it icy", "Add checkpoints", "Call it Test Run"]:
			st.change_with_words(w)
			var c := PloxLevel.check(st.level)
			print("AUTOTEST STUDIO change '%s' parts=%d check='%s'" % [w, st.level.parts.size(), c])
		st.sel = 1
		st._edit(func(q): q[4] = q[4] * 1.25)
		st._add("bounce")
		st._duplicate()
		st._delete()
		print("AUTOTEST STUDIO hand parts=%d check='%s' title=%s undo=%d" % [st.level.parts.size(), PloxLevel.check(st.level), st.level.title, st.undo.size()])
		set_meta("st_step", 4)
		if autotest.ends_with("_rotate"):
			_set_orientation("landscape")
	elif step == 4 and autotest_t > limit:
		# Fuzz the quick builder with many prompts: every level must pass the checker.
		var bad := 0
		var prompts := ["lava", "ice tower", "candy stars", "hard spinning hammers", "easy kids", "long hard parkour race", "space jump", "x", "a b c d", "moving platforms with lava and stars and jump pads"]
		for i in 200:
			var lv := PloxLevel.quick_build(prompts[i % prompts.size()], null, i)
			if PloxLevel.check(lv) != "":
				bad += 1
				print("AUTOTEST STUDIO bad level for '%s': %s" % [prompts[i % prompts.size()], PloxLevel.check(lv)])
		print("AUTOTEST STUDIO fuzz 200 levels, bad=%d" % bad)
		_dump_ui()
		print("AUTOTEST LAYOUT ", _layout_report())
		if OS.has_environment("AUTOTEST_SHOT"):
			get_viewport().get_texture().get_image().save_png(OS.get_environment("AUTOTEST_SHOT"))
		get_tree().quit()


## Welcome check: a phone with no account sees Sign up / Log in, signs up for real against
## the game service, and lands in the app with the new account.
func _autotest_welcome() -> void:
	await get_tree().create_timer(0.5).timeout
	social.data.me = {}
	social.data.name = ""
	social.data.username = ""
	social.data.friends = {}
	social.data.chats = {}
	social.data.used = false
	social.data.erase("token")
	social.data.erase("uid")
	social.hold = social.needs_welcome()
	shell._rebuild()
	await get_tree().create_timer(0.5).timeout
	var w = shell._welcome
	print("AUTOTEST WELCOME shown=%s hold=%s url=%s" % [str(w != null), str(social.hold), social.url])
	if w == null:
		get_tree().quit()
		return
	w._go("signup")
	var un := "wel_" + str(Time.get_ticks_msec() % 100000)
	w._vals.username = un
	w._name_timer.start()
	await get_tree().create_timer(3.0).timeout
	print("AUTOTEST WELCOME name_state='%s'" % w._name_state)
	w._vals.password = "goodpass123"
	w._vals.y = 2000
	w._vals.m = 5
	w._vals.d = 17
	w._do_signup()
	var t := 0.0
	while t < 40.0 and is_instance_valid(w) and shell._welcome != null:
		await get_tree().create_timer(0.5).timeout
		t += 0.5
	print("AUTOTEST WELCOME signed_up=%s username=%s logged_in=%s err='%s'" % [str(shell._welcome == null), str(social.data.get("username", "")), str(social.is_logged_in()), str(w._err) if is_instance_valid(w) else ""])
	await get_tree().create_timer(1.0).timeout
	_dump_ui()
	print("AUTOTEST LAYOUT ", _layout_report())
	get_tree().quit()
