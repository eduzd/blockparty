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
	player = LocalPlayer.new()
	add_child(player)
	player.setup(_player_name, _color)
	player.collision_layer = 2
	player.collision_mask = 1
	player.trampoline = false
	player.min_y = -9999.0          # we handle falling ourselves (lives)
	_speed_base = float(p.speed) / Protocol.MOVE_SPEED
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
			co.collision_layer = 4 if r.actor else 1
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
	touch.show_jump = float(spec.player.jump) > 0.0 and spec.controls != "topdown"
	touch.jump.connect(func(): player.jump_pressed = true)
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
	for k in ["score", "lives", "health", "timer"]:
		if (spec.hud as Array).has(k):
			var p := UiKit.pill("")
			_top.add_child(p)
			_pills[k] = p
	if can_edit:
		_top.add_child(_hud_btn("pencil-square", func(): _exit(true)))
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
	# Narrow portrait phones: the title gives way first so the stat pills fit.
	if _pills.has("title"):
		(_pills.title as Control).visible = hud_root.size.x > 300 + 70 * (_pills.size() - 1)
	touch.blocked_rects = [Rect2(hud_root.position, Vector2(full.x, 70 * k)), Rect2(Vector2(full.x * 0.15, ins.t + 70 * k), Vector2(full.x * 0.7, 50 * k))]
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
	_build_entities()
	player.respawn_at = _start
	player.teleport(_start)
	_face_goal()
	_started_ms = Time.get_ticks_msec()
	if _panel and is_instance_valid(_panel):
		_panel.queue_free()
		_panel = null
	say(str(spec.intro) if str(spec.intro) != "" else title, 2.6)
	_run_triggers("start", "", 0.0)


func _face_goal() -> void:
	var target := Vector3.ZERO
	var g := _goal_entities()
	if not g.is_empty():
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

func _run_triggers(on: String, target: String, value: float) -> void:
	for i in (spec.triggers as Array).size():
		var t: Dictionary = spec.triggers[i]
		if t.on != on or done:
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
		_:
			pass   # spawn / reset / ability: part B


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
	if done:
		player.move_input = Vector2.ZERO
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
	player.speed_mult = _speed_base * _boost * (1.35 if ice else 1.0)
	if done:
		_move_entities(delta)
		return
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
	_touches()
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
	if b.has("chase") or b.has("follow"):
		var cbeh: Dictionary = b.chase if b.has("chase") else b.follow
		var rng := float(cbeh.range)
		fly = bool(cbeh.get("fly", false))
		if (rng <= 0.0 or dist < rng) and dist > float(cbeh.distance) + 0.3:
			speed = float(cbeh.speed)
			dir = _flow_dir(me) if not _blocked.is_empty() and not fly else Vector3.ZERO
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
	var v := dir * speed
	if fly:
		cb.velocity = v
	else:
		var vy := cb.velocity.y
		if cb.is_on_floor():
			vy = 0.0
		else:
			vy -= Protocol.GRAVITY * float(spec.world.gravity) * delta
		cb.velocity = Vector3(v.x, vy, v.z)
	cb.move_and_slide()
	if cb.global_position.y < _min_y:
		_remove(r, false)
		return
	if dir.length() > 0.05:
		var lk: Node3D = r.look
		lk.rotation.y = lerp_angle(lk.rotation.y, atan2(dir.x, dir.z) - cb.rotation.y, minf(delta * 8.0, 1.0))


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
		if b.has("damage") and str(b.damage.target) in ["player", ""]:
			var dm: Dictionary = b.damage
			if float(dm.knock) > 0.0 and int(dm.amount) == 0 and not dm.kill:
				var away := player.global_position - (r.node as Node3D).global_position
				away.y = 0
				player.knock(away.normalized() * float(dm.knock) + Vector3(0, 6, 0))
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
