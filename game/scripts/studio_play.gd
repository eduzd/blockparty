class_name StudioPlay
extends Node3D
## Plays a Studio level (PloxLevel) on this phone: blocks, lava, jump pads, hammers,
## movers, stars, ice and checkpoints, from the start point to the finish flag.
## Built only from a cleaned level, so whatever the AI sent can't break it.

signal finished(result: Dictionary)   # {"won": bool, "ms": int, "stars": int, "edit": bool}

const SKY_COLORS := [
	[Color("#7EC8FF"), Color("#E6F4FF")],   # Day
	[Color("#FF8A65"), Color("#FFE0B2")],   # Sunset
	[Color("#0B1030"), Color("#29306B")],   # Night
	[Color("#F8BBD9"), Color("#E1F5FE")],   # Candy
	[Color("#37474F"), Color("#90A4AE")],   # Storm
]

var level: Dictionary
var title := ""
var can_edit := false
var player: LocalPlayer
var camera: Camera3D
var touch: TouchControls
var hud_layer: CanvasLayer
var hud_root: Control
var _stars_label: Label
var _time_label: Label
var _toast: Label
var _toast_t := 0.0
var _win_panel: Control
var _movers: Array = []      # [body, origin, axis, phase]
var _spinners: Array = []    # [body, speed]
var _stars_total := 0
var _stars := 0
var _started_ms := 0
var _done := false
var _cam_yaw := 0.0
var _cam_pitch := -0.35
var _t := 0.0
var _start := Vector3.ZERO
var _on_ice := false
var _player_name := "You"
var _color := Color("#335FFF")
var test_move := Vector2.ZERO   # automated checks walk with this


func setup(p_level: Dictionary, p_title: String, p_can_edit: bool, p_name := "You", p_color := Color("#335FFF")) -> void:
	level = PloxLevel.clean(p_level, PloxLevel.MAX_PARTS_HARD)
	title = p_title if p_title != "" else str(level.title)
	can_edit = p_can_edit
	_player_name = p_name
	_color = p_color


func _ready() -> void:
	_build_world()
	_build_hud()
	_restart()


static func _col(i: int) -> Color:
	return Color(PloxLevel.COLORS[clampi(i, 0, PloxLevel.COLORS.size() - 1)])


func _mat(c: Color, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.7
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	return m


func _box_mesh(size: Vector3, c: Color, glow := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(c, glow)
	return mi


func _box_shape(size: Vector3) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	return cs


func _area(pos: Vector3, size: Vector3, cb: Callable) -> Area3D:
	var a := Area3D.new()
	a.position = pos
	a.add_child(_box_shape(size))
	a.monitoring = true
	a.body_entered.connect(func(b):
		if b == player:
			cb.call(a))
	add_child(a)
	return a


func _build_world() -> void:
	var sky_i := clampi(int(level.get("sky", 0)), 0, SKY_COLORS.size() - 1)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = SKY_COLORS[sky_i][0]
	sm.sky_horizon_color = SKY_COLORS[sky_i][1]
	sm.ground_horizon_color = SKY_COLORS[sky_i][1]
	sm.ground_bottom_color = SKY_COLORS[sky_i][0].darkened(0.3)
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.4 if sky_i == 2 else 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)

	var low := 0.0
	for p in level.parts:
		var kind := str(p[0])
		var pos := Vector3(p[1], p[2], p[3])
		var size := Vector3(p[4], p[5], p[6])
		var rot := deg_to_rad(float(p[7]))
		var col := _col(int(p[8]))
		low = minf(low, pos.y - size.y)
		match kind:
			"block", "ice":
				var sb := StaticBody3D.new()
				sb.position = pos
				sb.rotation.y = rot
				sb.add_child(_box_shape(size))
				sb.add_child(_box_mesh(size, col.lightened(0.25) if kind == "ice" else col))
				if kind == "ice":
					sb.set_meta("ice", true)
				add_child(sb)
			"lava":
				var mi := _box_mesh(size, Color("#FF5722"), 1.6)
				mi.position = pos
				mi.rotation.y = rot
				add_child(mi)
				var sb2 := StaticBody3D.new()   # you stand on it for a moment, then burn
				sb2.position = pos
				sb2.rotation.y = rot
				sb2.add_child(_box_shape(size))
				add_child(sb2)
				var a := _area(pos + Vector3(0, 0.3, 0), size + Vector3(0.2, 0.6, 0.2), func(_a): _die("Ouch, lava!"))
				a.rotation.y = rot
			"bounce":
				var sb3 := StaticBody3D.new()
				sb3.position = pos
				sb3.rotation.y = rot
				sb3.add_child(_box_shape(size))
				sb3.add_child(_box_mesh(size, Color("#EC407A"), 0.8))
				add_child(sb3)
				var a2 := _area(pos + Vector3(0, size.y / 2.0 + 0.3, 0), Vector3(size.x, 0.6, size.z), func(_a):
					player.velocity.y = 19.0)
				a2.rotation.y = rot
			"spinner":
				var ab := AnimatableBody3D.new()
				ab.position = pos
				ab.rotation.y = rot
				ab.sync_to_physics = true
				ab.add_child(_box_shape(size))
				ab.add_child(_box_mesh(size, col, 0.2))
				var hub := _box_mesh(Vector3(0.8, size.y + 0.6, 0.8), Color("#37474F"))
				ab.add_child(hub)
				add_child(ab)
				var a3 := Area3D.new()
				a3.add_child(_box_shape(size + Vector3(0.3, 0.3, 0.3)))
				a3.body_entered.connect(func(b):
					if b == player:
						var away := (player.global_position - ab.global_position)
						away.y = 0
						player.knock(away.normalized() * 14.0 + Vector3.UP * 7.0))
				ab.add_child(a3)
				_spinners.append([ab, 1.6 if _spinners.size() % 2 == 0 else -1.9])
			"mover":
				var ab2 := AnimatableBody3D.new()
				ab2.position = pos
				ab2.rotation.y = rot
				ab2.sync_to_physics = true
				ab2.add_child(_box_shape(size))
				ab2.add_child(_box_mesh(size, col, 0.15))
				add_child(ab2)
				var axis := Vector3(cos(rot), 0, -sin(rot))
				_movers.append([ab2, pos, axis, float(_movers.size()) * 1.3])
			"coin":
				var star := MeshInstance3D.new()
				var sp := SphereMesh.new()
				sp.radius = 0.45
				sp.height = 0.9
				star.mesh = sp
				star.material_override = _mat(Color("#FFCA28"), 1.2)
				star.position = pos
				star.set_meta("spin", true)
				add_child(star)
				_stars_total += 1
				_area(pos, Vector3(1.4, 1.4, 1.4), func(a):
					if star.visible:
						star.visible = false
						a.set_deferred("monitoring", false)
						_stars += 1
						_say("Star %d of %d!" % [_stars, _stars_total]))
			"checkpoint":
				var sb4 := StaticBody3D.new()
				sb4.position = pos
				sb4.add_child(_box_shape(size))
				sb4.add_child(_box_mesh(size, Color("#26C6DA"), 0.6))
				add_child(sb4)
				var cp := pos + Vector3(0, size.y / 2.0 + 1.0, 0)
				_area(cp, Vector3(size.x, 2.0, size.z), func(_a):
					if player.respawn_at.distance_to(cp) > 0.5:
						player.respawn_at = cp
						_say("Checkpoint!"))
	# Finish flag
	var g: Array = level.goal
	var gpos := Vector3(g[0], g[1], g[2])
	var pole := _box_mesh(Vector3(0.15, 3.0, 0.15), Color.WHITE)
	pole.position = gpos + Vector3(0, 0.5, 0)
	add_child(pole)
	var flag := _box_mesh(Vector3(1.2, 0.8, 0.05), Color("#66BB6A"), 0.7)
	flag.position = gpos + Vector3(0.6, 1.6, 0)
	flag.set_meta("wave", true)
	add_child(flag)
	_area(gpos + Vector3(0, 0.5, 0), Vector3(2.0, 3.0, 2.0), func(_a): _win())
	var s: Array = level.spawn
	_start = Vector3(s[0], s[1], s[2])
	player = LocalPlayer.new()
	add_child(player)
	player.setup(_player_name, _color)
	player.trampoline = false
	player.min_y = low - 12.0
	camera = Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = 72.0
	add_child(camera)
	camera.make_current()
	# Face from the start towards the finish.
	var d := gpos - _start
	_cam_yaw = atan2(-d.x, -d.z) + PI if Vector2(d.x, d.z).length() > 0.5 else 0.0
	_cam_yaw = atan2(d.x, d.z) + PI


func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	hud_layer.layer = 5
	add_child(hud_layer)
	touch = TouchControls.new()
	hud_layer.add_child(touch)
	touch.show_touch = true
	touch.jump.connect(func(): player.jump_pressed = true)
	hud_root = Control.new()
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(hud_root)
	var top := UiKit.hbox(8)
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 12
	top.offset_right = -12
	top.offset_top = 10
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(top)
	top.add_child(_hud_btn("arrow-left", func(): _exit(false)))
	var t := UiKit.pill(title)
	t.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	top.add_child(t)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(sp)
	_stars_label = UiKit.pill("")
	top.add_child(_stars_label)
	_time_label = UiKit.pill("0:00")
	top.add_child(_time_label)
	if can_edit:
		top.add_child(_hud_btn("pencil-square", func(): _exit(true)))
	_toast = UiKit.label("", "title_large", Color.WHITE, false)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_top = 80
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_toast.add_theme_constant_override("shadow_offset_y", 2)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hud_root.add_child(_toast)
	get_viewport().size_changed.connect(_fit)
	_fit()


func _fit() -> void:
	if not is_instance_valid(hud_root):
		return
	var vp := get_viewport()
	var k := ScreenUtil.dp(vp)
	var full := vp.get_visible_rect().size
	var ins := ScreenUtil.insets(vp)
	hud_root.scale = Vector2(k, k)
	hud_root.position = Vector2(ins.l, ins.t)
	hud_root.size = Vector2(full.x - ins.l - ins.r, full.y - ins.t - ins.b) / k
	var r := Rect2(hud_root.position, Vector2(full.x, 70 * k))
	touch.blocked_rects = [r]
	touch.relayout()


func _hud_btn(icon_name: String, cb: Callable) -> Button:
	var b := Button.new()
	b.icon = UiKit.icon_texture(icon_name)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_constant_override("icon_max_width", 22)
	for st in ["icon_normal_color", "icon_pressed_color", "icon_hover_color", "icon_focus_color"]:
		b.add_theme_color_override(st, Color.WHITE)
	for st in ["normal", "hover"]:
		b.add_theme_stylebox_override(st, UiKit.box(Color(0, 0, 0, 0.45), 22, Color(1, 1, 1, 0.45), 1))
	b.add_theme_stylebox_override("pressed", UiKit.box(Color(0, 0, 0, 0.65), 22, Color(1, 1, 1, 0.8), 1))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.custom_minimum_size = Vector2(44, 44)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _say(text: String) -> void:
	_toast.text = text
	_toast_t = 1.6
	_toast.modulate.a = 1.0


func _restart() -> void:
	_done = false
	_stars = 0
	for ch in get_children():
		if ch is MeshInstance3D and ch.has_meta("spin"):
			ch.visible = true
		if ch is Area3D:
			ch.set_deferred("monitoring", true)
	player.respawn_at = _start
	player.teleport(_start)
	_started_ms = Time.get_ticks_msec()
	if _win_panel and is_instance_valid(_win_panel):
		_win_panel.queue_free()
		_win_panel = null


func _die(why: String) -> void:
	if _done:
		return
	_say(why)
	player.call_deferred("teleport", player.respawn_at)


func _win() -> void:
	if _done:
		return
	_done = true
	var ms := Time.get_ticks_msec() - _started_ms
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiKit.pad(UiKit.box(UiKit.c("surface_container_high"), 28), 22, 20))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(280, 0)
	var v := UiKit.vbox(10)
	panel.add_child(v)
	v.add_child(UiKit.label("You made it!", "headline_small", UiKit.c("on_surface"), false))
	var line := "Time %s" % _fmt_time(ms)
	if _stars_total > 0:
		line += "  ·  Stars %d/%d" % [_stars, _stars_total]
	v.add_child(UiKit.label(line, "body_large", UiKit.c("on_surface_variant"), false))
	v.add_child(UiKit.primary_button("Play again", "arrow-path", _restart))
	if can_edit:
		v.add_child(UiKit.outline_button("Back to Studio", "pencil-square", func(): _exit(true)))
	else:
		v.add_child(UiKit.outline_button("Done", "check", func(): _exit(false)))
	hud_root.add_child(panel)
	_win_panel = panel
	finished.emit({"won": true, "ms": ms, "stars": _stars, "partial": true})


func _exit(edit: bool) -> void:
	finished.emit({"won": _done, "ms": Time.get_ticks_msec() - _started_ms, "stars": _stars, "edit": edit, "exit": true})


static func _fmt_time(ms: int) -> String:
	var s := ms / 1000
	return "%d:%02d" % [s / 60, s % 60]


func _process(delta: float) -> void:
	_t += delta
	if not _done:
		_time_label.text = _fmt_time(Time.get_ticks_msec() - _started_ms)
	_stars_label.visible = _stars_total > 0
	_stars_label.text = "Stars %d/%d" % [_stars, _stars_total]
	if _toast_t > 0.0:
		_toast_t -= delta
		_toast.modulate.a = clampf(_toast_t / 0.4, 0.0, 1.0)
	for ch in get_children():
		if ch is MeshInstance3D and ch.has_meta("spin"):
			ch.rotation.y += delta * 2.5
			ch.position.y += sin(_t * 3.0) * delta * 0.3
		elif ch is MeshInstance3D and ch.has_meta("wave"):
			ch.rotation.y = sin(_t * 2.0) * 0.25
	var look := touch.consume_look() / ScreenUtil.dp(get_viewport())
	_cam_yaw -= look.x * 0.012
	_cam_pitch = clampf(_cam_pitch - look.y * 0.008, -1.1, 0.25)
	player.camera_yaw = _cam_yaw
	var pivot := player.global_position + Vector3.UP * 1.6
	var offset := Vector3(0, 0, 8.0).rotated(Vector3.RIGHT, _cam_pitch).rotated(Vector3.UP, _cam_yaw)
	camera.global_position = camera.global_position.lerp(pivot + offset, 1.0 - exp(-delta * 12.0)) if _t > 0.1 else pivot + offset
	camera.look_at(pivot, Vector3.UP)


func _physics_process(delta: float) -> void:
	for m in _movers:
		var body: AnimatableBody3D = m[0]
		body.position = (m[1] as Vector3) + (m[2] as Vector3) * sin(_t * 1.1 + float(m[3])) * 4.0
	for s in _spinners:
		(s[0] as AnimatableBody3D).rotation.y += float(s[1]) * delta
	player.move_input = test_move if test_move != Vector2.ZERO else touch.current_move()
	# Ice: you keep sliding a little and run faster.
	var ice := false
	if player.is_on_floor():
		for i in player.get_slide_collision_count():
			var col := player.get_slide_collision(i).get_collider()
			if col is Node and (col as Node).has_meta("ice"):
				ice = true
	player.speed_mult = 1.35 if ice else 1.0
