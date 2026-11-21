class_name SpecPlay
extends Node3D
## Plux 0.8.0: plays a spec v1 game (PloxSpec). Builds the world with SpecProps,
## runs entity behaviours, the rules (score, countdown, lives, health, reach the
## goal) and a Sky & Ink HUD. Part A: platformer + top-down controls; move,
## rotate, bob, rise, shrink, chase, follow, flee, wander, collect, damage,
## bounce, boost, checkpoint, teleport; basic triggers.
## Part B adds vehicle, shooting, spawn/waves, push, laps (they are ignored here).

signal finished(result: Dictionary)   # same shape as StudioPlay: {won, ms, stars, edit, exit}

const SKY := {
	"day": ["#3F8CFF", "#BFE3FF"], "sunset": ["#5B3B8C", "#FF9E5E"], "night": ["#070B1E", "#26305A"],
	"dawn": ["#6C8BD8", "#FFC9A8"], "candy": ["#FF7EC8", "#FFE3F3"], "storm": ["#2E3640", "#6B7682"],
	"space": ["#000004", "#1A1040"], "spooky": ["#140A24", "#3D2A4F"], "desert": ["#4F9CE8", "#F4D9A0"],
	"snow": ["#8FB6D9", "#EEF5FB"]}
const DARK_SKIES := ["night", "space", "spooky"]
const GRID := 1.0                 # flow-field cell (m) for chasers

var spec: Dictionary
var title := ""
var can_edit := false
var props := SpecProps.new()
var player: LocalPlayer
var camera: Camera3D
var touch: TouchControls
var hud_layer: CanvasLayer
var hud_root: Control
var _top: HBoxContainer
var _pills := {}
var _toast: Label
var _toast_t := 0.0
var _panel: Control
var _world: Node3D               # entities live here; rebuilt on restart
var ents: Array = []             # records, see _spawn()
var _by_id := {}
var _player_name := "You"
var _color := Color("#335FFF")
var _dark := false
var _min_y := -12.0
var _half := 40.0

# game state
var score := 0
var lives := 0
var health := 1
var time_left := 0.0
var elapsed := 0.0
var done := false
var won := false
var result_reason := ""
var _started_ms := 0
var _invuln := 0.0
var _boost_t := 0.0
var _boost := 1.0
var _speed_base := 1.0
var _collect_total := 0
var _fired := {}
var _cam_yaw := 0.0
var _cam_pitch := -0.35
var _t := 0.0
var _start := Vector3.ZERO

# flow field for chasers (mazes)
var _blocked := {}
var _flow := {}
var _flow_t := 0.0
var _flow_from := Vector2i(999999, 999999)

# automated checks: world-space direction and jump, instead of touch
var bot_dir := Vector3.ZERO
var bot_jump := false
var test_move := Vector2.ZERO
var bot_fire := false            # part B: autopilot holds the action button
var bot_action := false          # one press (dash / kick)
var bot_car := false             # autopilot drives: bot_drive = (steer, throttle)
var bot_drive := Vector2.ZERO

# Part B: vehicles, shooting, waves, push, laps
var car: SpecCar                 # the player's car in "vehicle" games (also = player)
var _row2: HBoxContainer         # stat pills drop here on narrow screens
var _stats: Array = []
var projectiles: Array = []      # {node, vel, dmg, side, life}
var _ability := ""               # what the action button does: shoot / dash / kick
var _fire_cd := 0.0
var _ability_cd := 0.0
var _dash_t := 0.0
var wave_i := 0                  # current wave (1-based), 0 before the first
var _wave_left := 0
var _wave_spawn_t := 0.0
var _wave_gap_t := 0.0
var _waves_done := false
var _spawn_n := 0
var _spawn_rr := 0
var defeated := 0
var _enemies_seen := 0
var lap := 0                     # laps the player has finished
var next_cp := 0
var race_place := 1
var _beacon: Node3D
var _rivals_done := 0
var _dj := false
var _car_look := 0.0
var _air_jumps := 0


func setup(p_spec: Dictionary, p_title := "", p_can_edit := false, p_name := "You", p_color := Color("#335FFF")) -> void:
	spec = p_spec if (p_spec.get("v", 0) == PloxSpec.V and p_spec.has("rules")) else PloxSpec.clean(p_spec, 999)
	title = p_title if p_title != "" else str(spec.title)
	can_edit = p_can_edit
	_player_name = p_name
	_color = p_color


func _ready() -> void:
	_build_env()
	_build_player()
	_build_hud()
	_restart()


# ---------------------------------------------------------------- world

func _build_env() -> void:
	var w: Dictionary = spec.world
	_half = float(w.size) / 2.0
	var sky_name := str(w.sky)
	_dark = DARK_SKIES.has(sky_name) or str(w.light) == "dark"
	var cols: Array = SKY.get(sky_name, SKY.day)
	var top := Color(cols[0])
	var hor := Color(cols[1])
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = top
	sm.sky_horizon_color = hor
	sm.ground_horizon_color = hor
	sm.ground_bottom_color = top.darkened(0.3)
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = {"bright": 0.9, "dim": 0.6, "dark": 0.35}.get(str(w.light), 0.9)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	if float(w.fog) > 0.0:
		env.fog_enabled = true
		env.fog_light_color = hor
		env.fog_density = 0.004 + float(w.fog) * 0.03
	if _dark:
		env.glow_enabled = true
		env.glow_intensity = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.35 if _dark else (0.7 if str(w.light) == "dim" else 1.1)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)
	# Floor
	var fl := str(w.floor)
	if fl != "none":
		var size := float(w.size) + 40.0
		var kind := str(w.floor_mat) if fl == "ground" else fl
		var c := Color(str(w.floor_color)) if fl == "ground" else (Color("#FF5722") if fl == "lava" else Color("#1E88E5"))
		var floor_root: Node3D
		if fl == "ground":
			var sb := StaticBody3D.new()
			sb.collision_layer = 1
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = Vector3(size, 1.0, size)
			cs.shape = bs
			cs.position = Vector3(0, -0.5, 0)
			sb.add_child(cs)
			floor_root = sb
		else:
			floor_root = Node3D.new()
		var mi := MeshInstance3D.new()
		mi.mesh = props.box(Vector3(size, 1.0, size))
		mi.material_override = props.mat(c, kind)
		mi.position = Vector3(0, -0.5 if fl == "ground" else -1.3, 0)
		floor_root.add_child(mi)
		add_child(floor_root)
	if bool(w.get("walls", false)):
		for i in 4:
			var wall := StaticBody3D.new()
			var cs2 := CollisionShape3D.new()
			var b2 := BoxShape3D.new()
			b2.size = Vector3(float(w.size) + 2.0, 30.0, 1.0)
			cs2.shape = b2
			wall.add_child(cs2)
			wall.rotation.y = PI / 2.0 * i
			wall.position = Vector3(0, 15, 0) + Vector3(0, 0, _half + 0.5).rotated(Vector3.UP, PI / 2.0 * i)
			add_child(wall)
	var low := 0.0 if fl == "ground" else -1.0
	for e in spec.entities:
		low = minf(low, float(e.pos[1]))
	_min_y = low - 12.0


func _build_player() -> void:
	var p: Dictionary = spec.player
	if str(spec.controls) == "vehicle":
		car = SpecCar.new()
		player = car
		add_child(car)
		car.setup_car(_color, props, _dark)
		car.top_speed = clampf(float(p.speed) * 1.6, 10.0, 34.0) if float(p.speed) < 12.0 else float(p.speed)
	else:
		player = LocalPlayer.new()
		add_child(player)
		player.setup(_player_name, _color)
	player.collision_layer = 2
	player.collision_mask = 1
	player.trampoline = false
	player.min_y = -9999.0          # we handle falling ourselves (lives)
	_speed_base = 1.0 if car else float(p.speed) / Protocol.MOVE_SPEED
	for ab in ["shoot", "dash", "kick"]:
		if (p.abilities as Array).has(ab):
			_ability = ab
			break
	if (p.abilities as Array).has("double_jump") and not car:
		_dj = true
	player.jump_velocity = float(p.jump)
	player.gravity_mult = float(spec.world.gravity)
	_start = Vector3(p.spawn[0], p.spawn[1], p.spawn[2]) + Vector3(0, 0.05, 0)
	camera = Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = 72.0
	add_child(camera)
	camera.make_current()


func _clear_world() -> void:
	if _world and is_instance_valid(_world):
		remove_child(_world)
		_world.free()
	_world = Node3D.new()
	_world.name = "World"
	add_child(_world)
	ents.clear()
	_by_id.clear()
	projectiles.clear()
	_beacon = null


func _build_entities() -> void:
	_clear_world()
	props.light_budget = 4
	_collect_total = 0
	_blocked.clear()
	for e in spec.entities:
		if e.template:
			continue
		_spawn(e)
	for r in ents:
		if r.collect != null:
			_collect_total += 1
	_rebuild_blocked()


func _has_any(e: Dictionary, list: Array) -> bool:
	for b in e.behaviors:
		if list.has(b.type):
			return true
	return false


## One record per live entity:
## {d, node, look, pos (base, bottom-centre), size, alive, actor, moving, beh{type:b}, collect, t, wander_to, vy}
func _spawn(e: Dictionary) -> Dictionary:
	var size := Vector3(e.size[0], e.size[1], e.size[2])
	var pos := Vector3(e.pos[0], e.pos[1], e.pos[2])
	var actor := _has_any(e, PloxSpec.ACTORS)
	var moving := _has_any(e, ["move", "rotate", "bob", "rise", "shrink"])
	var solid: bool = e.solid
	var node: Node3D
	if actor:
		var cb := CharacterBody3D.new()
		cb.collision_layer = 4
		cb.collision_mask = 1
		var cs := CollisionShape3D.new()
		var cap := CylinderShape3D.new()
		cap.radius = clampf(minf(size.x, size.z) * 0.45, 0.2, 2.0)
		cap.height = maxf(size.y * 0.9, 0.4)
		cs.shape = cap
		cs.position = Vector3(0, size.y / 2.0 + 0.05, 0)
		cb.add_child(cs)
		node = cb
	elif _has_any(e, ["push"]):
		var pb: Dictionary = {}
		for b in e.behaviors:
			if b.type == "push":
				pb = b
		var rb := RigidBody3D.new()
		rb.mass = float(pb.get("mass", 1.0))
		rb.physics_material_override = PhysicsMaterial.new()
		rb.physics_material_override.bounce = float(pb.get("bounce", 0.4))
		rb.physics_material_override.friction = 0.6
		rb.collision_layer = 8
		rb.collision_mask = 1 | 8 | 4
		rb.linear_damp = 0.4
		rb.angular_damp = 1.0
		rb.add_child(props.shape_for(e.shape, size))
		node = rb
	elif solid and moving:
		var ab := AnimatableBody3D.new()
		ab.sync_to_physics = false
		ab.add_child(props.shape_for(e.shape, size))
		node = ab
	elif solid:
		var sb := StaticBody3D.new()
		sb.add_child(props.shape_for(e.shape, size))
		node = sb
	else:
		node = Node3D.new()
	node.name = str(e.id)
	node.position = pos
	node.rotation_degrees = Vector3(e.rot[0], e.rot[1], e.rot[2])
	var look := Node3D.new()
	node.add_child(look)
	var parts := props.build(look, e.shape, size, Color(str(e.color)), str(e.mat), _dark)
	_world.add_child(node)
	var beh := {}
	for b in e.behaviors:
		if not beh.has(b.type):
			beh[b.type] = b
	var r := {"d": e, "node": node, "look": look, "parts": parts, "pos": pos, "size": size, "alive": true, "actor": actor,
		"beh": beh, "collect": beh.get("collect"), "t": randf() * 3.0, "wander_to": pos, "vy": 0.0, "rise": 0.0,
		"base_rot": node.rotation, "hidden": bool(e.hidden)}
	r["knock"] = Vector3.ZERO
	r["hit_cd"] = 0.0
	if beh.has("destructible"):
		r["hp"] = int(beh.destructible.hp)
	if beh.has("shoot"):
		r["shoot_t"] = float(beh.shoot.every) * randf_range(0.5, 1.0)
	if beh.has("spawn"):
		r["spawn_t"] = float(beh.spawn.every) * 0.5
		r["kids"] = []
	if beh.has("race"):
		r["cp"] = 0
		r["lap"] = 0
		r["heading"] = 0.0
		r["spd"] = 0.0
		r["lane"] = randf_range(-1.6, 1.6)
		r["finished"] = false
	if (e.tags as Array).has("enemy"):
		_enemies_seen += 1
	if e.get("invisible", false):
		look.visible = false
	if r.hidden:
		_set_shown(r, false)
	ents.append(r)
	if not _by_id.has(e.id):
		_by_id[e.id] = r
	return r


func _set_shown(r: Dictionary, on: bool) -> void:
	r.hidden = not on
	var n: Node3D = r.node
	n.visible = on
	if n is CollisionObject3D:
		var co := n as CollisionObject3D
		if on:
			co.collision_layer = 4 if r.actor else (8 if co is RigidBody3D else 1)
		else:
			co.collision_layer = 0


func _remove(r: Dictionary, fx := true) -> void:
	if not r.alive:
		return
	r.alive = false
	if fx:
		props.burst(_world, (r.node as Node3D).global_position + Vector3(0, float(r.size.y) / 2.0, 0), Color(str(r.d.color)))
	(r.node as Node3D).queue_free()


## Entities whose id is name, or that carry tag name.
func _find(name: String) -> Array:
	var out := []
	if name == "":
		return out
	if _by_id.has(name) and (_by_id[name] as Dictionary).alive:
		return [_by_id[name]]
	for r in ents:
		if r.alive and (r.d.id == name or (r.d.tags as Array).has(name)):
			out.append(r)
	return out


# ---------------------------------------------------------------- maze flow field

func _cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / GRID), floori(p.z / GRID))


func _rebuild_blocked() -> void:
	# Solid, still, wall-like things block chasers. Rough AABB in world space.
	_blocked.clear()
	for r in ents:
		if r.actor or not r.d.solid or r.hidden or not r.alive:
			continue
		if float(r.size.y) < 0.9 or float(r.pos.y) > 2.5:
			continue
		var n: Node3D = r.node
		var s: Vector3 = r.size
		var xf := n.global_transform if n.is_inside_tree() else Transform3D(Basis.from_euler(n.rotation), n.position)
		var aabb := xf * AABB(Vector3(-s.x / 2.0, 0, -s.z / 2.0), s)
		var a := _cell(aabb.position + Vector3(0.05, 0, 0.05))
		var b := _cell(aabb.end - Vector3(0.05, 0, 0.05))
		if (b.x - a.x + 1) * (b.y - a.y + 1) > 4000:
			continue
		for x in range(a.x, b.x + 1):
			for z in range(a.y, b.y + 1):
				_blocked[Vector2i(x, z)] = true


func _update_flow() -> void:
	var from := _cell(player.global_position)
	if from == _flow_from and not _flow.is_empty():
		return
	_flow_from = from
	_flow.clear()
	var lim := int(floor(_half / GRID))      # cells -lim .. lim-1 lie inside the world
	var q: Array[Vector2i] = [from]
	_flow[from] = 0
	var i := 0
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while i < q.size() and i < 40000:
		var c: Vector2i = q[i]
		i += 1
		var dist: int = _flow[c]
		for d in dirs:
			var n: Vector2i = c + d
			if n.x < -lim or n.x >= lim or n.y < -lim or n.y >= lim or _flow.has(n) or _blocked.has(n):
				continue
			_flow[n] = dist + 1
			q.append(n)


## Direction (xz) a chaser at p should walk to get closer to the player around walls.
func _flow_dir(p: Vector3) -> Vector3:
	var c := _cell(p)
	if not _flow.has(c):
		return Vector3.ZERO
	var best: int = _flow[c]
	var to := c
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = c + d
		if _flow.has(n) and int(_flow[n]) < best:
			best = _flow[n]
			to = n
	if to == c:
		return Vector3.ZERO
	var target := Vector3((to.x + 0.5) * GRID, p.y, (to.y + 0.5) * GRID)
	var v := target - p
	v.y = 0
	return v.normalized()


# ---------------------------------------------------------------- HUD

func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	hud_layer.layer = 5
	add_child(hud_layer)
	touch = TouchControls.new()
	hud_layer.add_child(touch)
	touch.show_touch = true
	touch.show_jump = float(spec.player.jump) > 0.0 and not (str(spec.controls) in ["topdown", "vehicle"])
	touch.pedals = car != null
	touch.jump.connect(_on_jump)
	if _ability != "":
		touch.action_label = {"shoot": "FIRE", "dash": "DASH", "kick": "KICK"}[_ability]
		touch.action.connect(_on_action)
	hud_root = Control.new()
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(hud_root)
	_top = UiKit.hbox(8)
	_top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_top.offset_left = 12
	_top.offset_right = -12
	_top.offset_top = 10
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(_top)
	_top.add_child(_hud_btn("arrow-left", func(): _exit(false)))
	var t := UiKit.pill(title)
	t.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	t.clip_text = true
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.custom_minimum_size.x = 60
	_top.add_child(t)
	_pills["title"] = t
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.add_child(sp)
	_stats.clear()
	for k in ["laps", "place", "wave", "enemies", "score", "lives", "health", "timer"]:
		var want := (spec.hud as Array).has(k)
		if k == "place":
			want = (spec.hud as Array).has("laps") and _has_rivals()
		if want:
			var p := UiKit.pill("")
			_top.add_child(p)
			_pills[k] = p
			_stats.append(p)
	if can_edit:
		_top.add_child(_hud_btn("pencil-square", func(): _exit(true)))
	_row2 = UiKit.hbox(6)
	_row2.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_row2.alignment = BoxContainer.ALIGNMENT_END
	_row2.offset_left = 12
	_row2.offset_right = -12
	_row2.offset_top = 60
	_row2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(_row2)
	_toast = UiKit.label("", "title_large", Color.WHITE, true)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_toast.offset_top = 76
	_toast.offset_left = 24
	_toast.offset_right = -24
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_toast.add_theme_constant_override("shadow_offset_y", 2)
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	# Narrow portrait phones: the title gives way first, then the stat pills
	# drop to a second row under the top bar so nothing runs off-screen.
	var two_rows := hud_root.size.x < 44 * (2 if can_edit else 1) + 30 + 78 * _stats.size()
	for pl in _stats:
		var want_parent: Node = _row2 if two_rows else _top
		if (pl as Node).get_parent() != want_parent:
			(pl as Node).get_parent().remove_child(pl)
			want_parent.add_child(pl)
			if want_parent == _top and can_edit:
				_top.move_child(pl, _top.get_child_count() - 2)
	if _pills.has("title"):
		(_pills.title as Control).visible = hud_root.size.x > 300 + (0 if two_rows else 70 * _stats.size())
	var top_h := 92.0 if two_rows and not _stats.is_empty() else 70.0
	_toast.offset_top = top_h + 6.0
	touch.blocked_rects = [Rect2(hud_root.position, Vector2(full.x, top_h * k)), Rect2(Vector2(full.x * 0.15, ins.t + top_h * k), Vector2(full.x * 0.7, 50 * k))]
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


func _score_target() -> int:
	var w: Dictionary = spec.rules.win
	if w.type == "score":
		return int(w.value)
	if w.type == "collect_all":
		return _collect_total
	return 0


func _update_hud() -> void:
	if _pills.has("score"):
		var tg := _score_target()
		(_pills.score as Label).text = ("Score %d/%d" % [score, tg]) if tg > 0 else ("Score %d" % score)
	if _pills.has("lives"):
		(_pills.lives as Label).text = "Lives %d" % lives
	if _pills.has("laps"):
		(_pills.laps as Label).text = "Lap %d/%d" % [mini(lap + 1, int(spec.rules.laps)), int(spec.rules.laps)]
	if _pills.has("place"):
		var n := _rival_count() + 1
		(_pills.place as Label).text = "%s of %d" % [_ordinal(race_place), n]
	if _pills.has("wave"):
		(_pills.wave as Label).text = "Wave %d/%d" % [maxi(wave_i, 1), (spec.rules.waves as Array).size()]
	if _pills.has("enemies"):
		(_pills.enemies as Label).text = "Enemies %d" % _alive_enemies()
	if _pills.has("health"):
		(_pills.health as Label).text = "Health %d" % health
	if _pills.has("timer"):
		var sec := ceili(time_left) if int(spec.rules.timer) > 0 else int(elapsed)
		var lb := _pills.timer as Label
		lb.text = "%d:%02d" % [sec / 60, sec % 60]
		lb.modulate = Color("#FF8A80") if int(spec.rules.timer) > 0 and time_left < 10.0 and not done else Color.WHITE


func say(text: String, secs := 1.8) -> void:
	_toast.text = text
	_toast_t = secs
	_toast.modulate.a = 1.0


# ---------------------------------------------------------------- game flow

func _restart() -> void:
	done = false
	won = false
	result_reason = ""
	score = 0
	lives = int(spec.player.lives)
	health = int(spec.player.health)
	time_left = float(spec.rules.timer)
	elapsed = 0.0
	_invuln = 0.0
	_boost_t = 0.0
	_boost = 1.0
	_fired.clear()
	_flow.clear()
	_flow_from = Vector2i(999999, 999999)
	player.gravity_mult = float(spec.world.gravity)
	_fire_cd = 0.0
	_ability_cd = 0.0
	_dash_t = 0.0
	wave_i = 0
	_wave_left = 0
	_wave_spawn_t = 0.0
	_wave_gap_t = 2.5
	_waves_done = false
	_spawn_n = 0
	defeated = 0
	_enemies_seen = 0
	lap = 0
	next_cp = 0
	race_place = 1
	_rivals_done = 0
	_build_entities()
	player.respawn_at = _start
	player.teleport(_start)
	_face_goal()
	if car:
		car.heading = _cam_yaw
		car.steer = 0.0
		car.look_root.rotation.y = car.heading
		_place_rivals()
	if not (spec.rules.checkpoints as Array).is_empty():
		_beacon = props.build_beacon(_world, Color("#FFD54F"))
	_started_ms = Time.get_ticks_msec()
	if _panel and is_instance_valid(_panel):
		_panel.queue_free()
		_panel = null
	say(str(spec.intro) if str(spec.intro) != "" else title, 2.6)
	_run_triggers("start", "", 0.0)


func _face_goal() -> void:
	var target := Vector3.ZERO
	var g := _goal_entities()
	var cps := _cp_ents()
	if not cps.is_empty():
		target = (cps[0].node as Node3D).position
	elif not g.is_empty():
		target = (g[0].node as Node3D).position
	var d := target - _start
	_cam_yaw = atan2(d.x, d.z) + PI if Vector2(d.x, d.z).length() > 0.5 else 0.0


func _goal_entities() -> Array:
	var w: Dictionary = spec.rules.win
	if w.type == "reach":
		var list := _find(str(w.target))
		if list.is_empty():
			for r in ents:
				if r.alive and r.d.shape in ["flag", "goal"]:
					list.append(r)
		return list
	return []


## The player got hit, fell, or touched a killer. Uses a life when the game has lives.
func player_died(why: String) -> void:
	if done:
		return
	_invuln = 1.2
	health = int(spec.player.health)
	if int(spec.player.lives) > 0:
		lives -= 1
		if lives <= 0:
			lives = 0
			_lose(why if why != "" else "Out of lives")
			return
		say("%s  ·  %d left" % [why, lives])
	else:
		say(why)
	player.call_deferred("teleport", player.respawn_at)
	if car:
		var nx := _cp_pos(next_cp) if not _cp_ents().is_empty() else player.respawn_at + car.forward()
		var dd := nx - player.respawn_at
		if Vector2(dd.x, dd.z).length() > 0.5:
			car.heading = atan2(-dd.x, -dd.z)
	# Chasers go back to where they started, so a respawn is not an instant catch.
	for r in ents:
		if r.alive and r.actor and (r.beh.has("chase") or r.beh.has("follow")):
			var cb: CharacterBody3D = r.node
			cb.velocity = Vector3.ZERO
			cb.position = r.pos
	_invuln = 2.0


func _hurt(amount: int, why: String, kill: bool) -> void:
	if done or _invuln > 0.0:
		return
	if kill or int(spec.player.health) <= 1:
		player_died(why)
		return
	health -= amount
	_invuln = 0.9
	if health <= 0:
		player_died(why)
	else:
		say("Ouch!", 0.8)


func add_score(n: int) -> void:
	if n == 0:
		return
	score += n
	_run_triggers("score", "", float(score))


func _check_win() -> void:
	if done:
		return
	var w: Dictionary = spec.rules.win
	match str(w.type):
		"score":
			if w.value > 0 and score >= int(w.value):
				_win("You scored %d!" % score)
		"collect_all":
			if _collect_total > 0:
				var left := 0
				for r in ents:
					if r.alive and r.collect != null:
						left += 1
				if left == 0:
					_win("You got them all!")
		"survive":
			if elapsed >= float(w.value):
				_win("You survived!")
		"defeat_all":
			var wv := (spec.rules.waves as Array)
			if (wv.is_empty() or _waves_done) and _enemies_seen > 0 and _alive_enemies() == 0:
				_win("You beat them all!")
		"waves":
			if _waves_done and _alive_enemies() == 0:
				_win("You survived every wave!")


func _win(why: String) -> void:
	if done:
		return
	done = true
	won = true
	result_reason = why
	_end_panel("You win!", why)


func _lose(why: String) -> void:
	if done:
		return
	done = true
	won = false
	result_reason = why
	_end_panel("Game over", why)


func _end_panel(head: String, why: String) -> void:
	var ms := Time.get_ticks_msec() - _started_ms
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiKit.pad(UiKit.box(UiKit.c("surface_container_high"), 28), 22, 20))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(280, 0)
	var v := UiKit.vbox(10)
	panel.add_child(v)
	v.add_child(UiKit.label(head, "headline_small", UiKit.c("primary") if won else UiKit.c("error"), false))
	var line := why + "\nTime %s" % _fmt_time(int(elapsed * 1000.0))
	if _pills.has("score"):
		line += "  ·  Score %d" % score
	v.add_child(UiKit.label(line, "body_large", UiKit.c("on_surface_variant"), true))
	v.add_child(UiKit.primary_button("Play again", "arrow-path", _restart))
	if can_edit:
		v.add_child(UiKit.outline_button("Back to Studio", "pencil-square", func(): _exit(true)))
	else:
		v.add_child(UiKit.outline_button("Done", "check", func(): _exit(false)))
	hud_root.add_child(panel)
	_panel = panel
	touch.release_all()
	finished.emit({"won": won, "ms": ms, "stars": score, "partial": true, "reason": why})


func _exit(edit: bool) -> void:
	finished.emit({"won": won, "ms": Time.get_ticks_msec() - _started_ms, "stars": score, "edit": edit, "exit": true})


static func _fmt_time(ms: int) -> String:
	var s := ms / 1000
	return "%d:%02d" % [s / 60, s % 60]


# ---------------------------------------------------------------- triggers

func _run_triggers(on: String, target: String, value: float, by := "player") -> void:
	for i in (spec.triggers as Array).size():
		var t: Dictionary = spec.triggers[i]
		if t.on != on or done:
			continue
		if on == "touch":
			var tb := str(t.get("by", "player"))
			if (tb == "player") != (by == "player"):
				continue
			if by != "player" and tb != "" and tb != "any":
				var br: Dictionary = _by_id.get(by, {})
				if by != tb and not (not br.is_empty() and (br.d.tags as Array).has(tb)):
					continue
		if on in ["lap", "wave", "destroyed"] and str(t.target) != "" and on == "destroyed":
			var dr: Dictionary = _by_id.get(target, {})
			if target != str(t.target) and not (not dr.is_empty() and (dr.d.tags as Array).has(str(t.target))):
				continue
		if on in ["lap", "wave"] and float(t.value) > 0 and value < float(t.value):
			continue
		if t.once and _fired.has(i):
			continue
		if on in ["touch", "collect"] and str(t.target) != "":
			var r: Dictionary = _by_id.get(target, {})
			if target != str(t.target) and not (not r.is_empty() and (r.d.tags as Array).has(str(t.target))):
				continue
		if on in ["score", "timer"] and value < float(t.value):
			continue
		_fired[i] = true
		for a in t.do:
			_act(a)


func _act(a: Dictionary) -> void:
	var v := float(a.get("value", 0))
	match str(a.act):
		"win": _win(str(a.get("text", "You did it!")))
		"lose": _lose(str(a.get("text", "Game over")))
		"score": add_score(int(v) if v != 0 else 1)
		"message": say(str(a.get("text", "")), 2.4)
		"remove", "open":
			for r in _find(str(a.get("target", ""))):
				_remove(r)
			_rebuild_blocked()
			_flow.clear()
		"show":
			for r in _find(str(a.get("target", ""))):
				_set_shown(r, true)
			_rebuild_blocked()
			_flow.clear()
		"lives":
			lives = maxi(0, lives + (int(v) if v != 0 else 1))
		"time":
			time_left = maxf(0.0, time_left + v)
		"heal":
			health = mini(int(spec.player.health), health + (int(v) if v != 0 else 1))
		"speed":
			_boost = clampf(v if v > 0 else 1.5, 0.3, 3.0)
			_boost_t = 4.0
		"gravity":
			player.gravity_mult = clampf(v if v > 0 else 1.0, 0.2, 2.5)
		"teleport":
			if a.has("at"):
				player.call_deferred("teleport", Vector3(a.at[0], a.at[1], a.at[2]))
		"spawn":
			var tpl := str(a.get("template", a.get("target", "")))
			for i in int(a.get("count", 1)):
				var at = null
				if a.has("at"):
					at = Vector3(a.at[0], a.at[1], a.at[2])
				_spawn_template(tpl, at, false)
		"reset":
			var tg := str(a.get("target", ""))
			if tg == "" or tg == "player":
				player.call_deferred("teleport", player.respawn_at)
			for r in _find(tg):
				_reset_ent(r)
		"ability":
			var ab := str(a.get("text", a.get("target", "")))
			if ab in ["shoot", "dash", "kick"]:
				_set_ability(ab)
			elif ab == "double_jump":
				_dj = true
		_:
			pass


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	_t += delta
	_update_hud()
	if _toast_t > 0.0:
		_toast_t -= delta
		_toast.modulate.a = clampf(_toast_t / 0.4, 0.0, 1.0)
	# Collectables spin and float a little, whatever the AI said.
	for r in ents:
		if r.alive and r.collect != null and not r.beh.has("rotate"):
			(r.look as Node3D).rotation.y += delta * 2.2
			(r.look as Node3D).position.y = 0.15 + sin(_t * 3.0 + float(r.t)) * 0.12
	_update_camera(delta)


func _update_camera(delta: float) -> void:
	var look := touch.consume_look() / ScreenUtil.dp(get_viewport())
	if spec.controls == "topdown":
		_cam_yaw = 0.0
		player.camera_yaw = 0.0
		var landscape := ScreenUtil.is_landscape(get_viewport())
		var h := 15.0 if landscape else 19.0
		var target := player.global_position + Vector3(0, h, h * 0.42)
		camera.global_position = camera.global_position.lerp(target, 1.0 - exp(-delta * 8.0)) if _t > 0.1 else target
		camera.look_at(player.global_position + Vector3(0, 0.5, 0), Vector3.UP)
		return
	if car:
		# Chase camera: swings in behind the car, a little slower than the car
		# turns so steering reads clearly; dragging looks around and springs back.
		_car_look = clampf(_car_look - look.x * 0.01, -2.6, 2.6)
		if look == Vector2.ZERO:
			_car_look = move_toward(_car_look, 0.0, delta * 1.6)
		_cam_yaw = lerp_angle(_cam_yaw, car.heading, 1.0 - exp(-delta * 4.0)) if _t > 0.1 else car.heading
		player.camera_yaw = _cam_yaw
		var yaw := _cam_yaw + _car_look
		var landscape2 := ScreenUtil.is_landscape(get_viewport())
		var back := 8.5 + clampf(car.speed, 0.0, 30.0) * 0.08
		var up := 3.6 if landscape2 else 4.4
		var tgt := car.global_position + Vector3(sin(yaw) * back, up, cos(yaw) * back)
		camera.global_position = camera.global_position.lerp(tgt, 1.0 - exp(-delta * 10.0)) if _t > 0.1 else tgt
		camera.look_at(car.global_position + Vector3(0, 1.3, 0) - Vector3(sin(yaw), 0, cos(yaw)) * 3.0, Vector3.UP)
		camera.fov = lerpf(camera.fov, 70.0 + clampf(car.speed / maxf(car.top_speed, 1.0), 0.0, 1.0) * 10.0, minf(delta * 3.0, 1.0))
		return
	_cam_yaw -= look.x * 0.012
	_cam_pitch = clampf(_cam_pitch - look.y * 0.008, -1.1, 0.25)
	player.camera_yaw = _cam_yaw
	var pivot := player.global_position + Vector3.UP * 1.6
	var offset := Vector3(0, 0, 8.0).rotated(Vector3.RIGHT, _cam_pitch).rotated(Vector3.UP, _cam_yaw)
	camera.global_position = camera.global_position.lerp(pivot + offset, 1.0 - exp(-delta * 12.0)) if _t > 0.1 else pivot + offset
	camera.look_at(pivot, Vector3.UP)


func _physics_process(delta: float) -> void:
	# Input
	if bot_dir != Vector3.ZERO or bot_jump:
		var fwd := Vector3(-sin(player.camera_yaw), 0, -cos(player.camera_yaw))
		var right := Vector3(cos(player.camera_yaw), 0, -sin(player.camera_yaw))
		player.move_input = Vector2(bot_dir.dot(right), bot_dir.dot(fwd))
		if bot_jump:
			player.jump_pressed = true
			bot_jump = false
	else:
		player.move_input = test_move if test_move != Vector2.ZERO else (touch.current_move() if not done else Vector2.ZERO)
	if car:
		if bot_car:
			player.move_input = bot_drive
		elif test_move == Vector2.ZERO:
			player.move_input = Vector2(touch.current_move().x, touch.throttle())
	if done:
		player.move_input = Vector2.ZERO
	if player.is_on_floor():
		_air_jumps = 1 if _dj else 0
	if _boost_t > 0.0:
		_boost_t -= delta
		if _boost_t <= 0.0:
			_boost = 1.0
	var ice := false
	if player.is_on_floor():
		for i in player.get_slide_collision_count():
			var col := player.get_slide_collision(i).get_collider()
			if col is Node3D and _by_id.has(str((col as Node3D).name)) and str(_by_id[str((col as Node3D).name)].d.mat) == "ice":
				ice = true
	player.speed_mult = _speed_base * _boost * (1.35 if ice and not car else 1.0)
	if done:
		_move_entities(delta)
		_update_projectiles(delta)
		return
	_fire_cd = maxf(0.0, _fire_cd - delta)
	_ability_cd = maxf(0.0, _ability_cd - delta)
	if _dash_t > 0.0:
		_dash_t -= delta
	if _ability == "shoot" and (touch.action_down or bot_fire) and _fire_cd <= 0.0:
		_player_fire()
	if bot_action:
		bot_action = false
		_on_action()
	elapsed += delta
	_invuln = maxf(0.0, _invuln - delta)
	if int(spec.rules.timer) > 0:
		time_left -= delta
		if time_left <= 0.0:
			time_left = 0.0
			if spec.rules.win.type == "survive":
				_win("You survived!")
			else:
				_lose("Time's up!")
			return
	_run_triggers("timer", "", elapsed)
	# Falling
	var pp := player.global_position
	var fl := str(spec.world.floor)
	if pp.y < _min_y or (fl in ["lava", "water"] and pp.y < -0.6):
		player_died("Splash!" if fl == "water" else ("Burned!" if fl == "lava" else "You fell!"))
		return
	_move_entities(delta)
	_update_waves(delta)
	_update_projectiles(delta)
	if done:
		return
	_update_race(delta)
	if done:
		return
	_touches()
	_entity_touches()
	_check_win()


func _move_entities(delta: float) -> void:
	var chasers := false
	for r in ents:
		if r.alive and r.actor and (r.beh.has("chase") or r.beh.has("follow")):
			chasers = true
	if chasers and not _blocked.is_empty():
		_flow_t -= delta
		if _flow_t <= 0.0:
			_flow_t = 0.3
			_update_flow()
	for r in ents:
		if not r.alive or r.hidden:
			continue
		r.t = float(r.t) + delta
		var n: Node3D = r.node
		var b: Dictionary = r.beh
		if r.actor:
			_move_actor(r, delta)
		else:
			var p: Vector3 = r.pos
			if b.has("move"):
				p = _path_pos(r, b.move)
			if b.has("rise"):
				var rb: Dictionary = b.rise
				if elapsed > float(rb.delay):
					r.rise = minf(float(r.rise) + float(rb.speed) * delta, float(rb.max))
				p.y += float(r.rise)
			if b.has("bob"):
				p.y += sin(float(r.t) * float(b.bob.speed)) * float(b.bob.height)
			if b.has("move") or b.has("rise") or b.has("bob"):
				n.position = p
		if b.has("rotate"):
			var ax: String = b.rotate.axis
			var sp := deg_to_rad(float(b.rotate.speed)) * delta
			if r.actor or r.collect != null:
				var lk: Node3D = r.look
				if ax == "x": lk.rotation.x += sp
				elif ax == "z": lk.rotation.z += sp
				else: lk.rotation.y += sp
			else:
				if ax == "x": n.rotation.x += sp
				elif ax == "z": n.rotation.z += sp
				else: n.rotation.y += sp
		if b.has("shoot") and not done:
			_entity_shoot(r, delta)
		if b.has("spawn") and not done:
			_entity_spawn(r, delta)
		if b.has("shrink"):
			var sb: Dictionary = b.shrink
			var k := clampf((elapsed - float(sb.delay)) / float(sb.time), 0.0, 1.0)
			var s := lerpf(1.0, float(sb.to), k)
			n.scale = Vector3(s, 1.0, s)


## Position along a move path (pingpong eases at the ends like 0.7 movers).
func _path_pos(r: Dictionary, mb: Dictionary) -> Vector3:
	var pts: Array = []
	if (mb.path as Array).size() >= 2:
		for q in mb.path:
			pts.append(Vector3(q[0], q[1], q[2]))
	elif (mb.path as Array).size() == 1:
		pts = [r.pos, Vector3(mb.path[0][0], mb.path[0][1], mb.path[0][2])]
	else:
		var o: Array = mb.get("offset", [0, 0, 6])
		pts = [r.pos, (r.pos as Vector3) + Vector3(o[0], o[1], o[2])]
	if str(mb.loop) == "loop":
		pts.append(pts[0])
	var total := 0.0
	for i in range(1, pts.size()):
		total += (pts[i] as Vector3).distance_to(pts[i - 1])
	if total < 0.01:
		return pts[0]
	var dur := total / float(mb.speed)
	var u := elapsed / dur
	match str(mb.loop):
		"loop": u = fposmod(u, 1.0)
		"once": u = clampf(u, 0.0, 1.0)
		_:
			u = fposmod(u, 2.0)
			if u > 1.0:
				u = 2.0 - u
			u = (1.0 - cos(PI * u)) / 2.0
	var want := u * total
	for i in range(1, pts.size()):
		var seg := (pts[i] as Vector3).distance_to(pts[i - 1])
		if want <= seg or i == pts.size() - 1:
			return (pts[i - 1] as Vector3).lerp(pts[i], clampf(want / maxf(seg, 0.001), 0.0, 1.0))
		want -= seg
	return pts[pts.size() - 1]


func _move_actor(r: Dictionary, delta: float) -> void:
	var cb: CharacterBody3D = r.node
	var b: Dictionary = r.beh
	var me := cb.global_position
	var to_p := player.global_position - me
	var dist := Vector2(to_p.x, to_p.z).length()
	var dir := Vector3.ZERO
	var speed := 0.0
	var fly := false
	r.hit_cd = maxf(0.0, float(r.hit_cd) - delta)
	var kn: Vector3 = r.knock
	if b.has("race"):
		_drive_rival(r, delta)
		return
	if kn.length() > 2.0:
		pass   # knocked back: no steering until it settles
	elif b.has("chase") or b.has("follow"):
		var cbeh: Dictionary = b.chase if b.has("chase") else b.follow
		var rng := float(cbeh.range)
		fly = bool(cbeh.get("fly", false))
		var tgt := str(cbeh.get("target", "player"))
		var on_player := tgt in ["player", ""]
		if not on_player:
			var tr := _nearest(me, tgt, r)
			if tr.is_empty():
				on_player = true
			else:
				to_p = (tr.node as Node3D).global_position - me
				dist = Vector2(to_p.x, to_p.z).length()
		if elapsed < 1.5:
			pass   # a moment to get ready before anything chases you
		elif (rng <= 0.0 or dist < rng or not on_player) and dist > float(cbeh.distance) + 0.3:
			speed = float(cbeh.speed)
			dir = _flow_dir(me) if on_player and not _blocked.is_empty() and not fly else Vector3.ZERO
			if dir == Vector3.ZERO:
				dir = Vector3(to_p.x, 0, to_p.z).normalized()
			if fly:
				dir = to_p.normalized()
	elif b.has("flee"):
		if dist < float(b.flee.range):
			speed = float(b.flee.speed)
			dir = -Vector3(to_p.x, 0, to_p.z).normalized()
	elif b.has("wander"):
		var wt: Vector3 = r.wander_to
		if Vector2(wt.x - me.x, wt.z - me.z).length() < 0.6 or fmod(float(r.t), 4.0) < delta:
			var rad := float(b.wander.radius)
			r.wander_to = (r.pos as Vector3) + Vector3(randf_range(-rad, rad), 0, randf_range(-rad, rad))
			wt = r.wander_to
		speed = float(b.wander.speed)
		dir = Vector3(wt.x - me.x, 0, wt.z - me.z).normalized()
	# Walkers don't step off ledges on their own (only a shove sends them over).
	if not fly and speed > 0.0 and dir.length() > 0.05 and cb.is_on_floor():
		var ahead := me + dir.normalized() * (0.6 + speed * 0.12) + Vector3(0, 0.6, 0)
		var q := PhysicsRayQueryParameters3D.create(ahead, ahead + Vector3(0, -3.5, 0), 1)
		q.exclude = [cb.get_rid()]
		if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			speed = 0.0
	var v := dir * speed + Vector3(kn.x, 0, kn.z)
	r.knock = kn.move_toward(Vector3.ZERO, 12.0 * delta)
	if fly:
		cb.velocity = v
	else:
		var vy := cb.velocity.y
		if kn.y > 0.0:
			vy = kn.y
			r.knock = Vector3(r.knock.x, 0, r.knock.z)
		elif cb.is_on_floor():
			vy = 0.0
		else:
			vy -= Protocol.GRAVITY * float(spec.world.gravity) * delta
		cb.velocity = Vector3(v.x, vy, v.z)
	cb.move_and_slide()
	if cb.global_position.y < minf(_min_y, (r.pos as Vector3).y - 6.0) or (not fly and cb.global_position.y < (r.pos as Vector3).y - 6.0):
		_knocked_out(r)
		return
	# Damage aimed at something other than the player (zombies hitting a base).
	if b.has("damage") and not (str(b.damage.target) in ["player", ""]):
		var tr2 := _nearest(cb.global_position, str(b.damage.target), r)
		if not tr2.is_empty() and float(r.hit_cd) <= 0.0 and _near_ent(tr2, cb.global_position + Vector3(0, 0.5, 0), 0.8):
			r.hit_cd = 1.0
			_damage_ent(tr2, maxi(1, int(b.damage.amount)), false)
			if b.damage.die:
				_remove(r)
				return
	if dir.length() > 0.05:
		var lk: Node3D = r.look
		lk.rotation.y = lerp_angle(lk.rotation.y, atan2(-dir.x, -dir.z) - cb.rotation.y, minf(delta * 8.0, 1.0))


## Player-vs-entity contact by the entity's local box (handles rotation and shrink).
func _touching(r: Dictionary, pad := 0.35) -> bool:
	var n: Node3D = r.node
	if not n.is_inside_tree():
		return false
	var s: Vector3 = r.size
	var xf := n.global_transform
	var centre := xf * Vector3(0, s.y / 2.0, 0)
	if centre.distance_to(player.global_position) > s.length() + 3.0:
		return false
	var sc := n.scale
	for h in [0.2, 1.0, 1.8]:
		var lp := xf.affine_inverse() * (player.global_position + Vector3(0, h, 0))
		var px := pad / maxf(sc.x, 0.05)
		var pz := pad / maxf(sc.z, 0.05)
		if absf(lp.x) <= s.x / 2.0 + px and absf(lp.z) <= s.z / 2.0 + pz and lp.y >= -0.3 and lp.y <= s.y + 0.3:
			return true
	return false


func _touches() -> void:
	var goals := _goal_entities()
	for r in goals:
		if _touching(r, 0.6):
			_win("You reached the goal!")
			return
	for r in ents:
		if not r.alive or r.hidden or done:
			continue
		var b: Dictionary = r.beh
		if b.is_empty() and spec.triggers.is_empty():
			continue
		if not _touching(r):
			r.erase("in")
			continue
		var first: bool = not r.has("in")
		r["in"] = true
		var id := str(r.d.id)
		if first:
			_run_triggers("touch", id, 0.0)
		if b.has("collect"):
			var c: Dictionary = b.collect
			_remove(r)
			if int(c.heal) > 0:
				health = mini(int(spec.player.health), health + int(c.heal))
			if int(c.time) > 0:
				time_left += float(c.time)
			add_score(int(c.score))
			_run_triggers("collect", id, 0.0)
			continue
		if b.has("push"):
			_push_body(r, 1.0)
			continue
		if r.actor and _dash_t > 0.0 and (r.beh.has("damage") or (r.d.tags as Array).has("enemy")):
			_shove(r, 1.0)
			continue
		if b.has("damage") and str(b.damage.target) in ["player", ""]:
			var dm: Dictionary = b.damage
			if float(dm.knock) > 0.0 and int(dm.amount) == 0 and not dm.kill:
				if float(r.hit_cd) <= 0.0:
					r.hit_cd = 0.45
					var away := player.global_position - (r.node as Node3D).global_position
					away.y = 0
					if away.length() < 0.05:
						away = Vector3(randf() - 0.5, 0, randf() - 0.5)
					player.knock(away.normalized() * float(dm.knock) + Vector3(0, 6, 0))
					if r.actor:   # both bounce off, like sumo
						r.knock = -away.normalized() * float(dm.knock) * 0.35
			else:
				var what := "Burned!" if str(r.d.mat) == "lava" else ("Caught!" if r.actor else "Ouch!")
				if float(dm.knock) > 0.0:
					var away2 := player.global_position - (r.node as Node3D).global_position
					away2.y = 0
					player.knock(away2.normalized() * float(dm.knock) + Vector3(0, 5, 0))
				_hurt(maxi(1, int(dm.amount)), what, bool(dm.kill))
				if dm.die:
					_remove(r)
			if done:
				return
		if b.has("bounce") and player.velocity.y <= 0.5:
			player.velocity.y = float(b.bounce.power) * player.gravity_sign
		if b.has("boost") and first:
			_boost = float(b.boost.power)
			_boost_t = float(b.boost.time)
		if b.has("checkpoint") and first:
			var top := (r.node as Node3D).global_position + Vector3(0, float(r.size.y) + 0.1, 0)
			if player.respawn_at.distance_to(top) > 0.5:
				player.respawn_at = top
				say("Checkpoint!", 1.0)
		if b.has("teleport") and first:
			var to: Array = b.teleport.to
			player.call_deferred("teleport", Vector3(to[0], to[1], to[2]))


# ================================================================ part B
# Vehicles, shooting, spawners and waves, push / knockback, laps and rivals.

func _on_jump() -> void:
	if done:
		return
	if player.is_on_floor() or _air_jumps <= 0:
		player.jump_pressed = true
	else:
		_air_jumps -= 1
		player.velocity.y = player.jump_velocity * player.gravity_sign
		props.burst(_world, player.global_position, Color.WHITE, 8, 3.0)


func _set_ability(ab: String) -> void:
	var first := _ability == ""
	_ability = ab
	touch.action_label = {"shoot": "FIRE", "dash": "DASH", "kick": "KICK"}[ab]
	if first:
		touch.action.connect(_on_action)
	touch.relayout()
	touch.queue_redraw()


func _on_action() -> void:
	if done or _ability_cd > 0.0:
		return
	match _ability:
		"shoot":
			if _fire_cd <= 0.0:
				_player_fire()
		"dash":
			_ability_cd = 0.9
			_dash_t = 0.4
			var d := _aim_flat()
			player.knock(d * 14.0 + Vector3(0, 2.0, 0))
			props.burst(_world, player.global_position + Vector3(0, 0.8, 0), _color, 10, 3.0)
		"kick":
			_ability_cd = 0.5
			var pos := player.global_position
			var hit := false
			for r in ents:
				if not r.alive or r.hidden:
					continue
				var c := (r.node as Node3D).global_position
				if Vector2(c.x - pos.x, c.z - pos.z).length() < 2.4 + maxf(float(r.size.x), float(r.size.z)) * 0.5:
					if r.beh.has("push"):
						_push_body(r, 2.5)
						hit = true
					elif r.actor and not r.beh.has("race"):
						_shove(r, 1.4)
						hit = true
			if hit:
				props.burst(_world, pos + _aim_flat() * 1.2 + Vector3(0, 0.8, 0), Color.WHITE, 10, 4.0)


## Flat direction the player faces (car nose, avatar facing).
func _aim_flat() -> Vector3:
	var f := player.facing()
	var d := Vector3(-sin(f), 0, -cos(f))
	if not car and player.move_input.length() > 0.2 and str(spec.controls) != "topdown":
		var fwd := Vector3(-sin(player.camera_yaw), 0, -cos(player.camera_yaw))
		var right := Vector3(cos(player.camera_yaw), 0, -sin(player.camera_yaw))
		d = (right * player.move_input.x + fwd * player.move_input.y).normalized()
	return d


func _has_rivals() -> bool:
	for e in spec.entities:
		if not e.template:
			for b in e.behaviors:
				if b.type == "race":
					return true
	return false


func _rival_count() -> int:
	var n := 0
	for r in ents:
		if r.alive and r.beh.has("race"):
			n += 1
	return n


static func _ordinal(n: int) -> String:
	if n % 100 in [11, 12, 13]:
		return "%dth" % n
	match n % 10:
		1: return "%dst" % n
		2: return "%dnd" % n
		3: return "%drd" % n
	return "%dth" % n


func _is_enemy(r: Dictionary) -> bool:
	return (r.d.tags as Array).has("enemy")


func _alive_enemies() -> int:
	var n := 0
	for r in ents:
		if r.alive and not r.hidden and _is_enemy(r):
			n += 1
	return n


func _cp_ents() -> Array:
	var out := []
	for id in spec.rules.checkpoints:
		if _by_id.has(id):
			out.append(_by_id[id])
	return out


func _has_tag(r: Dictionary, name: String) -> bool:
	return str(r.d.id) == name or (r.d.tags as Array).has(name)


func _nearest(from: Vector3, name: String, exclude: Dictionary = {}) -> Dictionary:
	var best := {}
	var bd := INF
	for r in ents:
		if not r.alive or r.hidden or r == exclude or not _has_tag(r, name):
			continue
		var d := (r.node as Node3D).global_position.distance_squared_to(from)
		if d < bd:
			bd = d
			best = r
	return best


## Is a world point inside the entity's (rotated, scaled) box, grown by pad?
func _near_ent(r: Dictionary, point: Vector3, pad: float) -> bool:
	var n: Node3D = r.node
	if not is_instance_valid(n) or not n.is_inside_tree():
		return false
	var s: Vector3 = r.size
	var xf := n.global_transform
	if (xf * Vector3(0, s.y / 2.0, 0)).distance_to(point) > s.length() + pad + 1.0:
		return false
	var lp := xf.affine_inverse() * point
	var sc := n.scale
	return absf(lp.x) <= s.x / 2.0 + pad / maxf(sc.x, 0.05) and absf(lp.z) <= s.z / 2.0 + pad / maxf(sc.z, 0.05) \
		and lp.y >= -pad and lp.y <= s.y + pad


func _ent_centre(r: Dictionary) -> Vector3:
	return (r.node as Node3D).global_transform * Vector3(0, float(r.size.y) * 0.55, 0)


# ---------------------------------------------------------------- shooting

func _player_fire() -> void:
	_fire_cd = 0.28
	var from := player.global_position + (Vector3(0, 0.9, 0) + car.forward() * 2.2 if car else Vector3(0, 1.15, 0))
	var aim := _aim_flat()
	if not car and str(spec.controls) != "topdown":
		aim = Vector3(-sin(player.camera_yaw), 0, -cos(player.camera_yaw)) if player.move_input.length() < 0.2 else aim
	# Aim assist: lock onto the closest target near where you point (any
	# direction in top-down games, where the stick is also the aim).
	var cone := -1.0 if str(spec.controls) == "topdown" else 0.55
	var best := {}
	var bd := 32.0
	for r in ents:
		if not r.alive or r.hidden or not r.has("hp"):
			continue
		var to := _ent_centre(r) - from
		var dist := to.length()
		if dist > bd or dist < 0.3:
			continue
		if Vector3(to.x, 0, to.z).normalized().dot(aim) < cone:
			continue
		if not _clear_line(from, _ent_centre(r), r):
			continue
		bd = dist
		best = r
	var dir := aim
	if not best.is_empty():
		dir = (_ent_centre(best) - from).normalized()
	if not car:
		player.avatar.rotation.y = atan2(-dir.x, -dir.z)
	var sh: Dictionary = spec.player.shot
	_fire_cd = float(sh.rate)
	_fire(from, dir, float(sh.speed) + (car.speed if car else 0.0), int(sh.damage), "player", Color(str(sh.color)), 40.0, "")


func _clear_line(a: Vector3, b: Vector3, target: Dictionary = {}) -> bool:
	var q := PhysicsRayQueryParameters3D.create(a, b, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return true
	var col = hit.get("collider")
	return not target.is_empty() and col == target.node


func _fire(from: Vector3, dir: Vector3, speed: float, dmg: int, side: String, c: Color, rng: float, hits: String) -> void:
	if projectiles.size() > 80:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = props.sphere(0.17 if side == "player" else 0.22, 0.34 if side == "player" else 0.44, 8, 4)
	mi.material_override = props.mat(c, "plain", 2.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(mi)
	mi.global_position = from
	projectiles.append({"node": mi, "vel": dir.normalized() * speed, "dmg": dmg, "side": side, "life": rng / speed, "hits": hits, "c": c})


func _update_projectiles(delta: float) -> void:
	if projectiles.is_empty():
		return
	var space := get_world_3d().direct_space_state
	var keep := []
	for pr in projectiles:
		var mi: MeshInstance3D = pr.node
		if not is_instance_valid(mi):
			continue
		pr.life = float(pr.life) - delta
		var a := mi.global_position
		var b: Vector3 = a + (pr.vel as Vector3) * delta
		var gone: bool = pr.life <= 0.0 or b.y < -2.0
		if not gone and not done:
			gone = _projectile_hits(pr, a, b)
		if not gone:
			var q := PhysicsRayQueryParameters3D.create(a, b, 1)
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				gone = true
				var col = hit.get("collider")
				if col is Node3D and pr.side != "enemy" and not done:
					for r in ents:
						if r.alive and r.node == col and r.has("hp"):
							_damage_ent(r, int(pr.dmg), pr.side == "player")
							break
				props.burst(_world, hit.position, pr.c, 6, 2.5)
		if gone:
			mi.queue_free()
		else:
			mi.global_position = b
			keep.append(pr)
	projectiles = keep


func _projectile_hits(pr: Dictionary, a: Vector3, b: Vector3) -> bool:
	var mid := (a + b) * 0.5
	if pr.side == "enemy":
		var pp := player.global_position
		var hit := false
		if car:
			hit = (mid - (pp + Vector3(0, 0.7, 0))).length() < 1.6
		else:
			var lo := pp + Vector3(0, 0.3, 0)
			var hi := pp + Vector3(0, 1.6, 0)
			var t := clampf((mid - lo).dot(hi - lo) / (hi - lo).length_squared(), 0.0, 1.0)
			hit = mid.distance_to(lo.lerp(hi, t)) < 0.6
		if hit:
			props.burst(_world, mid, pr.c, 8, 3.0)
			_hurt(int(pr.dmg), "Hit!", false)
			return true
		return false
	for r in ents:
		if not r.alive or r.hidden or not r.has("hp"):
			continue
		if pr.side == "ally" and not (_is_enemy(r) or (str(pr.hits) != "" and _has_tag(r, str(pr.hits)))):
			continue
		if pr.side == "ally" and r.beh.has("shoot") and str(r.beh.shoot.target) != "player":
			continue
		if _near_ent(r, b, 0.3) or _near_ent(r, mid, 0.3):
			props.burst(_world, b, pr.c, 6, 2.5)
			_damage_ent(r, int(pr.dmg), pr.side == "player")
			return true
	return false


func _damage_ent(r: Dictionary, amount: int, by_player: bool) -> void:
	if not r.alive or not r.has("hp"):
		return
	r.hp = int(r.hp) - amount
	var lk: Node3D = r.look
	lk.scale = Vector3.ONE * 1.18
	create_tween().tween_property(lk, "scale", Vector3.ONE, 0.15)
	if int(r.hp) <= 0:
		_destroy(r, by_player)


func _destroy(r: Dictionary, by_player: bool) -> void:
	if not r.alive:
		return
	var solid: bool = r.d.solid and not r.actor
	_remove(r)
	if _is_enemy(r):
		defeated += 1
	if r.beh.has("destructible") and (by_player or _is_enemy(r)):
		add_score(int(r.beh.destructible.score))
	_run_triggers("destroyed", str(r.d.id), 0.0)
	for l in spec.rules.lose:
		if l.type == "destroyed" and str(l.target) != "" and _has_tag(r, str(l.target)):
			_lose("The %s was destroyed!" % str(l.target).replace("_", " "))
			return
	if solid:
		_rebuild_blocked()
		_flow.clear()


## An actor fell off the world (sumo): it is out.
func _knocked_out(r: Dictionary) -> void:
	_remove(r, false)
	if _is_enemy(r):
		defeated += 1
		if r.beh.has("destructible"):
			add_score(int(r.beh.destructible.score))
		say("Knocked out!", 1.0)
	_run_triggers("destroyed", str(r.d.id), 0.0)


func _entity_shoot(r: Dictionary, delta: float) -> void:
	r.shoot_t = float(r.shoot_t) - delta
	if float(r.shoot_t) > 0.0:
		return
	var sb: Dictionary = r.beh.shoot
	var n: Node3D = r.node
	var from := n.global_transform * Vector3(0, float(r.size.y) * 0.75, 0)
	var tgt := str(sb.target)
	var aim_at := Vector3.ZERO
	var side := "enemy"
	if tgt in ["player", ""]:
		aim_at = player.global_position + Vector3(0, 0.6 if car else 1.0, 0)
		aim_at += Vector3(player.velocity.x, 0, player.velocity.z) * (from.distance_to(aim_at) / float(sb.speed)) * 0.5
	else:
		var tr := _nearest(from, tgt, r)
		if tr.is_empty():
			r.shoot_t = 0.5
			return
		aim_at = _ent_centre(tr)
		side = "ally"
	if from.distance_to(aim_at) > float(sb.range) or not _clear_line(from, aim_at, {}):
		r.shoot_t = 0.4
		return
	r.shoot_t = float(sb.every)
	var d := aim_at - from
	var lk: Node3D = r.look
	lk.rotation.y = atan2(-d.x, -d.z) - n.rotation.y
	_fire(from + d.normalized() * 0.6, d, float(sb.speed), int(sb.damage), side, Color(str(sb.color)), float(sb.range) + 4.0, tgt if side == "ally" else "")


# ---------------------------------------------------------------- spawners and waves

func _template(name: String) -> Dictionary:
	for e in spec.entities:
		if e.id == name and e.template:
			return e
	for e in spec.entities:
		if e.id == name or (e.tags as Array).has(name):
			return e
	return {}


func _spawn_template(name: String, at, wave: bool) -> Dictionary:
	var e := _template(name)
	if e.is_empty():
		return {}
	var live := 0
	for r in ents:
		if r.alive and r.get("spawned", false):
			live += 1
	if live >= 40:
		return {}
	var c: Dictionary = e.duplicate(true)
	c.template = false
	c.hidden = false
	_spawn_n += 1
	c.id = "%s_%d" % [str(e.id), _spawn_n]
	if not (c.tags as Array).has(str(e.id)):
		(c.tags as Array).append(str(e.id))
	if wave and not (c.tags as Array).has("wave"):
		(c.tags as Array).append("wave")
	if at is Vector3:
		var j := Vector3(randf_range(-1.2, 1.2), 0, randf_range(-1.2, 1.2))
		c.pos = [at.x + j.x, at.y, at.z + j.z]
	var r := _spawn(c)
	r["spawned"] = true
	if _is_enemy(r):
		_flow_t = 0.0
	props.burst(_world, (r.node as Node3D).global_position + Vector3(0, 0.6, 0), Color(str(c.color)), 10, 3.0)
	return r


## Where a wave enemy appears: a tagged spawn point, a fixed spot, or the edge.
func _spawn_point(at) -> Vector3:
	if at is Array and (at as Array).size() == 3:
		return Vector3(at[0], at[1], at[2])
	var name := str(at)
	if name != "":
		var pts := []
		for r in ents:
			if r.alive and _has_tag(r, name):
				pts.append(r)
		if not pts.is_empty():
			_spawn_rr += 1
			var pr: Dictionary = pts[_spawn_rr % pts.size()]
			return (pr.node as Node3D).global_position
	var a := randf() * TAU
	var rad := _half - 3.0
	var p := Vector3(cos(a) * rad, 0.2, sin(a) * rad)
	if p.distance_to(player.global_position) < 10.0:
		p = -p
	return p


func _update_waves(delta: float) -> void:
	var W: Array = spec.rules.waves
	if W.is_empty() or _waves_done or done:
		return
	var alive := 0
	for r in ents:
		if r.alive and (r.d.tags as Array).has("wave"):
			alive += 1
	if _wave_left <= 0 and alive == 0:
		if wave_i >= W.size():
			_waves_done = true
			return
		_wave_gap_t -= delta
		if _wave_gap_t > 0.0:
			return
		wave_i += 1
		var w: Dictionary = W[wave_i - 1]
		_wave_left = int(w.count)
		_wave_spawn_t = 0.0
		_wave_gap_t = float(spec.rules.wave_gap)
		say("Wave %d of %d" % [wave_i, W.size()] if wave_i < W.size() else "Final wave!", 1.8)
		_run_triggers("wave", "", float(wave_i))
		if wave_i > 1:
			lives = lives   # (kept for clarity: lives carry over between waves)
	if _wave_left > 0:
		_wave_spawn_t -= delta
		if _wave_spawn_t <= 0.0:
			var w2: Dictionary = W[wave_i - 1]
			_wave_spawn_t = float(w2.every)
			var r := _spawn_template(str(w2.template), _spawn_point(w2.at), true)
			_wave_left -= 1
			if r.is_empty() and _template(str(w2.template)).is_empty():
				_wave_left = 0   # nothing to spawn: don't hang the game


func _entity_spawn(r: Dictionary, delta: float) -> void:
	r.spawn_t = float(r.spawn_t) - delta
	if float(r.spawn_t) > 0.0:
		return
	var sp: Dictionary = r.beh.spawn
	r.spawn_t = float(sp.every)
	var kids: Array = (r.kids as Array).filter(func(k): return k.alive)
	r.kids = kids
	for i in int(sp.count):
		if kids.size() >= int(sp.max):
			break
		var k := _spawn_template(str(sp.template), (r.node as Node3D).global_position + Vector3(0, 0.1, 0), false)
		if not k.is_empty():
			kids.append(k)


func _reset_ent(r: Dictionary) -> void:
	if not r.alive:
		return
	var n: Node3D = r.node
	if n is RigidBody3D:
		var rb := n as RigidBody3D
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
		rb.global_transform = Transform3D(Basis.from_euler(r.base_rot), r.pos)
	elif n is CharacterBody3D:
		(n as CharacterBody3D).velocity = Vector3.ZERO
		n.position = r.pos
	else:
		n.position = r.pos


# ---------------------------------------------------------------- push and knockback

func _push_body(r: Dictionary, k: float) -> void:
	var rb := r.node as RigidBody3D
	if rb == null or float(r.hit_cd) > _t:
		return
	r.hit_cd = _t + 0.12
	var away := rb.global_position - player.global_position
	away.y = 0
	var pv := Vector3(player.velocity.x, 0, player.velocity.z)
	var dir := (away.normalized() * 0.6 + pv.normalized() * 0.4).normalized() if pv.length() > 0.5 else away.normalized()
	var power := (4.0 + pv.length() * 0.8) * k * clampf(rb.mass, 0.5, 4.0)
	rb.apply_central_impulse(dir * power + Vector3(0, 1.2 * k * clampf(rb.mass, 0.5, 4.0), 0))


func _shove(r: Dictionary, k: float) -> void:
	if float(r.hit_cd) > 0.0:
		return
	r.hit_cd = 0.35
	var away := (r.node as Node3D).global_position - player.global_position
	away.y = 0
	if away.length() < 0.05:
		away = _aim_flat()
	r.knock = away.normalized() * 16.0 * k + Vector3(0, 4.5, 0)
	player.knock(-away.normalized() * 3.0 + Vector3(0, 2.0, 0))
	props.burst(_world, (r.node as Node3D).global_position + Vector3(0, 1.0, 0), Color.WHITE, 8, 3.0)


## Entity-on-entity touch triggers ("when the ball touches the goal").
func _entity_touches() -> void:
	for i in (spec.triggers as Array).size():
		var t: Dictionary = spec.triggers[i]
		if t.on != "touch" or str(t.get("by", "player")) == "player" or done:
			continue
		var by := str(t.by)
		for zr in _find(str(t.target)):
			if not zr.alive or zr.hidden:
				continue
			var inside := false
			var who := ""
			for r in ents:
				if r == zr or not r.alive or r.hidden or not (by in ["any", ""] or _has_tag(r, by)):
					continue
				if _near_ent(zr, _ent_centre(r), 0.2):
					inside = true
					who = str(r.d.id)
					break
			var key := "in_" + by
			if inside and not zr.has(key):
				zr[key] = true
				_run_triggers("touch", str(zr.d.id), 0.0, who)
			elif not inside:
				zr.erase(key)


# ---------------------------------------------------------------- racing

## Rivals line up beside and behind the player on the grid.
func _place_rivals() -> void:
	var fwd := car.forward()
	var right := Vector3(-fwd.z, 0, fwd.x)
	var i := 0
	for r in ents:
		if not r.alive or not r.beh.has("race"):
			continue
		var cb: CharacterBody3D = r.node
		var row := (i + 1) / 2
		var col := (1 if i % 2 == 0 else -1) * 3.4
		var p := _start + right * col - fwd * (row * 5.0 + (0.0 if i == 0 else 0.0))
		p.y = (r.pos as Vector3).y
		cb.global_position = p
		cb.velocity = Vector3.ZERO
		r.heading = car.heading
		r.spd = 0.0
		r.pos = p
		(r.look as Node3D).rotation.y = car.heading - cb.rotation.y
		i += 1


func _cp_pos(i: int) -> Vector3:
	var cps := _cp_ents()
	if cps.is_empty():
		return Vector3.ZERO
	var r: Dictionary = cps[posmod(i, cps.size())]
	return (r.node as Node3D).global_position


## Race progress: laps done, gates passed, and how far along to the next gate.
func _progress(lp: int, cp: int, pos: Vector3) -> float:
	var n := _cp_ents().size()
	if n == 0:
		return 0.0
	var a := _cp_pos(cp - 1)
	var b := _cp_pos(cp)
	var seg := maxf(Vector2(b.x - a.x, b.z - a.z).length(), 1.0)
	var left := Vector2(b.x - pos.x, b.z - pos.z).length()
	return float(lp * n + cp) + clampf(1.0 - left / seg, 0.0, 0.999)


func _gate_hit(r: Dictionary, pos: Vector3) -> bool:
	if _near_ent(r, pos + Vector3(0, 0.8, 0), 1.0):
		return true
	var c := (r.node as Node3D).global_position
	var reach := maxf(float(r.size.x), float(r.size.z)) * 0.5 + 1.5
	return Vector2(c.x - pos.x, c.z - pos.z).length() < reach and absf(c.y - pos.y) < float(r.size.y) + 3.0


func _drive_rival(r: Dictionary, delta: float) -> void:
	var cb: CharacterBody3D = r.node
	var cps := _cp_ents()
	if cps.is_empty():
		return
	var me := cb.global_position
	var n := cps.size()
	var gate: Dictionary = cps[int(r.cp) % n]
	if _gate_hit(gate, me):
		r.cp = int(r.cp) + 1
		if int(r.cp) >= n:
			r.cp = 0
			r.lap = int(r.lap) + 1
			if int(r.lap) >= int(spec.rules.laps) and not r.finished:
				r.finished = true
				_rivals_done += 1
				_rival_finished(r)
				if done:
					return
		gate = cps[int(r.cp) % n]
	# Aim a little past the gate centre on this rival's lane.
	var gp := (gate.node as Node3D).global_position
	var nxt := _cp_pos(int(r.cp) + 1)
	var along := Vector3(nxt.x - gp.x, 0, nxt.z - gp.z).normalized()
	var side := Vector3(-along.z, 0, along.x)
	var aim := gp + side * float(r.lane)
	var want := atan2(-(aim.x - me.x), -(aim.z - me.z))
	var diff := wrapf(want - float(r.heading), -PI, PI)
	r.heading = float(r.heading) + clampf(diff, -2.4 * delta, 2.4 * delta)
	var top := float(r.beh.race.speed)
	if absf(diff) > 0.6:
		top *= 0.6   # brake for the corner
	var my_prog := _progress(int(r.lap), int(r.cp), me)
	var pl_prog := _progress(lap, next_cp, player.global_position)
	if my_prog > pl_prog + 1.5:
		top *= 0.94   # a light rubber band keeps races close
	elif my_prog < pl_prog - 1.5:
		top *= 1.06
	if r.finished:
		top *= 0.5
	r.spd = move_toward(float(r.spd), top, (9.0 if float(r.spd) < top else 18.0) * delta)
	var fwd := Vector3(-sin(float(r.heading)), 0, -cos(float(r.heading)))
	var kn: Vector3 = r.knock
	var vy := cb.velocity.y
	if cb.is_on_floor():
		vy = 0.0
	else:
		vy -= Protocol.GRAVITY * float(spec.world.gravity) * delta
	cb.velocity = fwd * float(r.spd) + Vector3(kn.x, vy, kn.z)
	r.knock = kn.move_toward(Vector3.ZERO, 12.0 * delta)
	cb.move_and_slide()
	(r.look as Node3D).rotation.y = float(r.heading) - cb.rotation.y
	var wh: Array = (r.parts as Dictionary).get("wheels", [])
	for w in wh:
		if is_instance_valid(w):
			(w as Node3D).rotate_object_local(Vector3.UP, -float(r.spd) * delta / 0.35)
	if cb.global_position.y < minf(_min_y, (r.pos as Vector3).y - 8.0):
		cb.global_position = _cp_pos(int(r.cp) - 1) + Vector3(0, 0.5, 0)
		cb.velocity = Vector3.ZERO
		r.spd = 0.0
	# Bumping the player's car pushes both apart.
	if car and float(r.hit_cd) <= 0.0:
		var d := cb.global_position - car.global_position
		d.y = 0
		if d.length() < 2.6:
			r.hit_cd = 0.3
			r.knock = d.normalized() * 5.0
			car.knock(-d.normalized() * 5.0)
			car.speed *= 0.85
	r.hit_cd = maxf(0.0, float(r.hit_cd) - delta)


func _rival_finished(r: Dictionary) -> void:
	for l in spec.rules.lose:
		if l.type == "beaten":
			_lose("A rival won the race!")
			return
	say("%s finished!" % str(r.d.id).replace("_", " ").capitalize(), 1.4)


func _update_race(delta: float) -> void:
	var cps := _cp_ents()
	if cps.is_empty():
		return
	var n := cps.size()
	var pp := player.global_position
	var gate: Dictionary = cps[next_cp % n]
	if _gate_hit(gate, pp):
		next_cp += 1
		if next_cp >= n:
			next_cp = 0
			lap += 1
			_run_triggers("lap", "", float(lap))
			if spec.rules.win.type == "laps" and lap >= int(spec.rules.laps):
				_update_place()
				_win("You finished %s!" % _ordinal(race_place) if race_place > 1 else "You won the race!")
				return
			say("Final lap!" if lap == int(spec.rules.laps) - 1 else "Lap %d" % (lap + 1), 1.4)
		elif next_cp > 0:
			var gtop := (gate.node as Node3D).global_position + Vector3(0, 0.3, 0)
			player.respawn_at = gtop
		gate = cps[next_cp % n]
	_update_place()
	if _beacon and is_instance_valid(_beacon):
		var gp := (gate.node as Node3D).global_position
		_beacon.global_position = gp + Vector3(0, float(gate.size.y) + 3.5 + sin(_t * 3.0) * 0.3, 0)
		_beacon.rotation.y += delta * 1.5


func _update_place() -> void:
	var mine := _progress(lap, next_cp, player.global_position)
	var place := 1
	for r in ents:
		if r.alive and r.beh.has("race"):
			if r.finished or _progress(int(r.lap), int(r.cp), (r.node as Node3D).global_position) > mine:
				place += 1
	race_place = place
