extends Node
## App entry: menu, game screen, phone hosting, and headless server mode.

## Live Render server (free tier). Players can still change it in the menu.
const DEFAULT_SERVER_URL := "wss://blockparty-server.onrender.com"
const SETTINGS_PATH := "user://settings.cfg"
const DP := 2.0   # 1280x720 viewport = 640x360 dp

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
	UiKit.dark = DisplayServer.is_dark_mode()
	net = NetClient.new()
	add_child(net)
	net.joined.connect(_on_joined)
	net.message.connect(_on_message)
	net.status_changed.connect(_on_status)
	net.gave_up.connect(_on_gave_up)
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
	root.scale = Vector2(DP, DP)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	return root


func _fit_roots() -> void:
	var s := get_viewport().get_visible_rect().size / DP
	for r in [menu_root, hud_root]:
		if r and is_instance_valid(r):
			r.size = s


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
	camera.fov = 70
	world.add_child(camera)
	camera.make_current()

	hud_layer = CanvasLayer.new()
	add_child(hud_layer)
	touch = TouchControls.new()
	hud_layer.add_child(touch)
	touch.show_touch = DisplayServer.is_touchscreen_available() or autotest != ""
	touch.jump.connect(_on_jump)
	hud_root = _scaled_root(hud_layer)
	hud_info = UiKit.pill("")
	hud_info.position = Vector2(12, 10)
	hud_root.add_child(hud_info)
	hud_drop = Label.new()
	hud_drop.set_anchors_preset(Control.PRESET_CENTER_TOP)
	hud_drop.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hud_drop.position.y = 44
	hud_drop.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_drop.add_theme_font_override("font", UiKit.font("anton", 400))
	hud_drop.add_theme_font_size_override("font_size", 28)
	hud_drop.add_theme_color_override("font_color", Color.WHITE)
	hud_drop.add_theme_color_override("font_outline_color", UiKit.INK)
	hud_drop.add_theme_constant_override("outline_size", 8)
	hud_drop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(hud_drop)
	hud_banner = UiKit.pill("")
	hud_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	hud_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hud_banner.position.y = 90
	hud_banner.visible = false
	hud_root.add_child(hud_banner)
	var leave := UiKit.outline_button("Leave", "x-mark", _leave_game)
	leave.add_theme_color_override("font_color", Color.WHITE)
	leave.add_theme_color_override("icon_normal_color", Color.WHITE)
	for st in ["normal", "hover"]:
		leave.add_theme_stylebox_override(st, UiKit.pad(UiKit.box(Color(0, 0, 0, 0.45), 12, Color(1, 1, 1, 0.5), 1), 14, 6))
	leave.custom_minimum_size = Vector2(0, 40)
	leave.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	leave.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	leave.position = Vector2(-12, 10)
	hud_root.add_child(leave)
	_fit_roots()


func _on_jump() -> void:
	if player:
		player.jump_pressed = true


func _leave_game() -> void:
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
	var look := touch.consume_look()
	cam_yaw -= look.x * 0.006
	cam_pitch = clampf(cam_pitch - look.y * 0.004, -1.1, 0.25)
	player.camera_yaw = cam_yaw
	var up := Vector3.UP * player.gravity_sign
	var pivot := player.global_position + up * 1.6
	var offset := Vector3(0, 0, 7.5).rotated(Vector3.RIGHT, cam_pitch * player.gravity_sign).rotated(Vector3.UP, cam_yaw)
	camera.global_position = pivot + offset
	camera.look_at(pivot, up)
	# HUD
	var where := ""
	if mode == "host":
		var ips := _local_ips()
		where = "  ·  Friends join: %s" % (", ".join(ips) if not ips.is_empty() else "turn on Wi-Fi or hotspot")
	var ping := ("%d ms" % net.latency_ms) if net.latency_ms >= 0 else "..."
	hud_info.text = "Room %s  ·  %d players  ·  %s%s" % [net.room, remotes.size() + 1, ping, where]
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

func _start_autotest() -> void:
	name_edit.text = "Bot%d" % (OS.get_process_id() % 1000)
	if autotest == "host":
		_on_host()
	elif autotest.begins_with("join:"):
		server_edit.text = autotest.substr(5)
		mode = "online"
		_connect(server_edit.text)


func _autotest_tick(delta: float) -> void:
	if autotest == "":
		return
	autotest_t += delta
	if player:
		# Walk in a slow circle and hop, like a player would.
		player.move_input = Vector2(sin(autotest_t * 0.8), cos(autotest_t * 0.8))
		if fmod(autotest_t, 2.0) < delta:
			player.jump_pressed = true
	var limit := float(OS.get_environment("AUTOTEST_SECONDS")) if OS.has_environment("AUTOTEST_SECONDS") else 12.0
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
		if OS.has_environment("AUTOTEST_SHOT"):
			get_viewport().get_texture().get_image().save_png(OS.get_environment("AUTOTEST_SHOT"))
		get_tree().quit()
