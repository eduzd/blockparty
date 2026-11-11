class_name PopCharacter
extends Node3D
## A Pop-Up Panic character: a big googly-eyed head on a spring, popping out of a
## weird everyday object. Origin is at the base of the object. Everything is built
## from a handful of shared meshes and materials, so eight of them stay cheap.
## Animation is all procedural: hop-walk with squash and stretch, a springy head
## that lags behind your moves, a lunging head-bonk, dizzy spins and blinks.

const HEAD_R := 0.42
const SPRING_REST := 0.42
const RING_COUNT := 6

static var _meshes := {}
static var _mats := {}

var display_name := ""
var obj := "box"
var head_color := Color.WHITE
var top_y := 0.9            # where the spring leaves the object

var body: Node3D            # the object; squashes and stretches
var head_pivot: Node3D      # follows the spring's end
var head: Node3D
var _rings: Array[MeshInstance3D] = []
var _pupils: Array[Node3D] = []
var _eyes: Array[Node3D] = []
var _brows: Array[Node3D] = []
var _mouth: MeshInstance3D
var _label: Label3D
var _shield: MeshInstance3D
var _shadow: MeshInstance3D

# Animation state
var _hop_phase := 0.0
var _sway := Vector3.ZERO
var _sway_v := Vector3.ZERO
var _prev_vel := Vector3.ZERO
var _lunge := 0.0           # 0..1 how far the head is out
var _lunge_t := -1.0
var _dizzy := 0.0
var _blink := 0.0
var _next_blink := 2.0
var _land_squash := 0.0
var _was_grounded := true
var _cheer := 0.0
var _t := 0.0
var facing_yaw := 0.0


# ------------------------------------------------------------------ shared assets

static func mesh(key: String) -> Mesh:
	if _meshes.has(key):
		return _meshes[key]
	var m: Mesh
	match key:
		"sphere":
			var s := SphereMesh.new()
			s.radius = 0.5
			s.height = 1.0
			s.radial_segments = 20
			s.rings = 10
			m = s
		"sphere_lo":
			var s2 := SphereMesh.new()
			s2.radius = 0.5
			s2.height = 1.0
			s2.radial_segments = 10
			s2.rings = 5
			m = s2
		"box":
			var b := BoxMesh.new()
			b.size = Vector3.ONE
			m = b
		"cyl":
			var c := CylinderMesh.new()
			c.top_radius = 0.5
			c.bottom_radius = 0.5
			c.height = 1.0
			c.radial_segments = 18
			c.rings = 1
			m = c
		"cone":
			var c2 := CylinderMesh.new()
			c2.top_radius = 0.4
			c2.bottom_radius = 0.5
			c2.height = 1.0
			c2.radial_segments = 18
			c2.rings = 1
			m = c2
		"capsule":
			var cp := CapsuleMesh.new()
			cp.radius = 0.5
			cp.height = 2.0
			cp.radial_segments = 14
			cp.rings = 4
			m = cp
		"ring":
			var t := TorusMesh.new()
			t.inner_radius = 0.17
			t.outer_radius = 0.24
			t.rings = 14
			t.ring_segments = 6
			m = t
		"torus":
			var t2 := TorusMesh.new()
			t2.inner_radius = 0.38
			t2.outer_radius = 0.5
			t2.rings = 18
			t2.ring_segments = 8
			m = t2
		"quad":
			var q := QuadMesh.new()
			q.size = Vector2.ONE
			q.orientation = PlaneMesh.FACE_Y
			m = q
	_meshes[key] = m
	return m


static func mat(col: Color, kind := "toon") -> Material:
	var key := "%s:%s" % [kind, str(col)]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	match kind:
		"toon":
			m.roughness = 0.55
			m.metallic_specular = 0.35
		"shiny":
			m.roughness = 0.18
			m.metallic = 0.6
			m.metallic_specular = 0.8
		"glow":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		"rim":
			m.roughness = 0.4
			m.rim_enabled = true
			m.rim = 0.6
			m.rim_tint = 0.3
		"bubble":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.no_depth_test = false
		"shadow":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var g := Gradient.new()
			g.set_color(0, Color(0, 0, 0, 0.55))
			g.set_color(1, Color(0, 0, 0, 0.0))
			var tex := GradientTexture2D.new()
			tex.gradient = g
			tex.fill = GradientTexture2D.FILL_RADIAL
			tex.fill_from = Vector2(0.5, 0.5)
			tex.fill_to = Vector2(0.5, 0.0)
			tex.width = 64
			tex.height = 64
			m.albedo_texture = tex
			m.albedo_color = Color.WHITE
	_mats[key] = m
	return m


func _part(parent: Node3D, mesh_key: String, pos: Vector3, scl: Vector3, col: Color, kind := "toon", rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh(mesh_key)
	mi.material_override = mat(col, kind)
	mi.position = pos
	mi.scale = scl
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


# ------------------------------------------------------------------ build

func setup(p_name: String, character: int, color: Color, show_label := true) -> void:
	display_name = p_name
	obj = str(PopRules.CHARACTERS[posmod(character, PopRules.CHARACTERS.size())].obj)
	head_color = color
	body = Node3D.new()
	add_child(body)
	_build_object()
	# Spring rings
	for i in RING_COUNT:
		var r := _part(self, "ring", Vector3.ZERO, Vector3.ONE, Color("#c9d2dc"), "shiny")
		_rings.append(r)
	head_pivot = Node3D.new()
	add_child(head_pivot)
	head = Node3D.new()
	head_pivot.add_child(head)
	_build_head()
	if show_label:
		_label = Label3D.new()
		_label.text = p_name
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.font_size = 44
		_label.outline_size = 12
		_label.pixel_size = 0.006
		_label.no_depth_test = true
		_label.modulate = Color.WHITE
		_label.outline_modulate = Color(0.08, 0.1, 0.18)
		add_child(_label)
	_shield = _part(self, "sphere_lo", Vector3(0, 1.0, 0), Vector3.ONE * 2.4, Color(0.55, 0.85, 1.0, 0.22), "bubble")
	_shield.visible = false
	_shadow = MeshInstance3D.new()
	_shadow.mesh = mesh("quad")
	_shadow.material_override = mat(Color.WHITE, "shadow")
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shadow.top_level = true
	add_child(_shadow)
	_layout_spring()


func _build_object() -> void:
	match obj:
		"teapot":
			var c := Color("#4fc3c9")
			_part(body, "sphere", Vector3(0, 0.45, 0), Vector3(1.05, 0.85, 1.05), c, "rim")
			_part(body, "cyl", Vector3(0, 0.05, 0), Vector3(0.7, 0.1, 0.7), c.darkened(0.2))
			_part(body, "cone", Vector3(0, 0.62, -0.62), Vector3(0.16, 0.6, 0.16), c, "toon", Vector3(-1.0, 0, 0))
			_part(body, "torus", Vector3(0, 0.5, 0.5), Vector3(0.55, 0.55, 0.55), c.darkened(0.15), "toon", Vector3(0, PI / 2.0, PI / 2.0))
			_part(body, "cyl", Vector3(0, 0.86, 0), Vector3(0.62, 0.08, 0.62), Color("#ffd166"), "shiny")
			_part(body, "sphere", Vector3(0.18, 0.5, -0.47), Vector3(0.2, 0.2, 0.05), Color("#ff7b9c"))
			top_y = 0.88
		"sneaker":
			var c2 := Color("#ff4d6d")
			_part(body, "box", Vector3(0, 0.08, -0.1), Vector3(0.62, 0.16, 1.25), Color.WHITE)
			_part(body, "capsule", Vector3(0, 0.33, -0.25), Vector3(0.58, 0.3, 0.42), c2, "rim", Vector3(PI / 2.0, 0, 0))
			_part(body, "cyl", Vector3(0, 0.5, 0.18), Vector3(0.6, 0.75, 0.6), c2, "rim")
			_part(body, "torus", Vector3(0, 0.86, 0.18), Vector3(0.6, 0.5, 0.6), Color.WHITE)
			for i in 3:
				_part(body, "box", Vector3(0, 0.5 + i * 0.03, -0.25 - i * 0.16), Vector3(0.4, 0.04, 0.05), Color.WHITE)
			_part(body, "box", Vector3(0.31, 0.32, -0.15), Vector3(0.02, 0.12, 0.5), Color("#2b2d42"))
			top_y = 0.88
		"box":
			var c3 := Color("#d4a373")
			_part(body, "box", Vector3(0, 0.42, 0), Vector3(0.95, 0.84, 0.95), c3)
			_part(body, "box", Vector3(0, 0.42, -0.48), Vector3(0.16, 0.84, 0.02), Color("#e9c46a"))
			for s in [Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0)]:
				var flap := Node3D.new()
				flap.position = Vector3(s.x * 0.47, 0.84, s.z * 0.47)
				body.add_child(flap)
				var along_x := absf(s.z) > 0.0
				_part(flap, "box", Vector3(s.x * 0.2, 0.0, s.z * 0.2),
					Vector3(0.95 if along_x else 0.4, 0.03, 0.4 if along_x else 0.95), c3.lightened(0.08))
				if along_x:
					flap.rotation.x = 0.7 * s.z
				else:
					flap.rotation.z = -0.7 * s.x
			_part(body, "box", Vector3(0.2, 0.3, -0.48), Vector3(0.28, 0.2, 0.02), Color("#3d405b"))
			top_y = 0.82
		"fridge":
			var c4 := Color("#e8f1ff")
			_part(body, "box", Vector3(0, 0.6, 0), Vector3(0.8, 1.2, 0.75), c4, "rim")
			_part(body, "box", Vector3(0, 0.82, -0.38), Vector3(0.78, 0.02, 0.02), Color("#9aa5b8"))
			_part(body, "box", Vector3(-0.28, 0.55, -0.4), Vector3(0.05, 0.4, 0.05), Color("#9aa5b8"), "shiny")
			_part(body, "box", Vector3(-0.28, 1.0, -0.4), Vector3(0.05, 0.18, 0.05), Color("#9aa5b8"), "shiny")
			_part(body, "sphere", Vector3(0.18, 0.5, -0.39), Vector3(0.14, 0.14, 0.04), Color("#ffd166"))
			_part(body, "sphere", Vector3(0.12, 0.66, -0.39), Vector3(0.1, 0.1, 0.04), Color("#06d6a0"))
			top_y = 1.18
		"cactus":
			_part(body, "cone", Vector3(0, 0.22, 0), Vector3(0.75, 0.44, 0.75), Color("#e07a5f"))
			_part(body, "cyl", Vector3(0, 0.46, 0), Vector3(0.82, 0.08, 0.82), Color("#c8553d"))
			var g := Color("#52b788")
			_part(body, "capsule", Vector3(0, 0.78, 0), Vector3(0.5, 0.3, 0.5), g, "rim")
			_part(body, "capsule", Vector3(-0.38, 0.85, 0), Vector3(0.2, 0.14, 0.2), g, "rim", Vector3(0, 0, 0.9))
			_part(body, "capsule", Vector3(0.36, 0.95, 0), Vector3(0.18, 0.13, 0.18), g, "rim", Vector3(0, 0, -0.7))
			for i in 5:
				var a := i * 1.3
				_part(body, "sphere_lo", Vector3(cos(a) * 0.25, 0.65 + i * 0.09, sin(a) * 0.25), Vector3.ONE * 0.05, Color("#fefae0"))
			top_y = 1.02
		"mailbox":
			_part(body, "box", Vector3(0, 0.3, 0), Vector3(0.14, 0.6, 0.14), Color("#6c584c"))
			var c5 := Color("#3a86ff")
			_part(body, "box", Vector3(0, 0.75, 0), Vector3(0.6, 0.36, 0.9), c5, "rim")
			_part(body, "cyl", Vector3(0, 0.93, 0), Vector3(0.6, 0.9, 0.6), c5, "rim", Vector3(PI / 2.0, 0, 0))
			_part(body, "box", Vector3(0.33, 0.95, 0.15), Vector3(0.04, 0.4, 0.06), Color("#ef233c"))
			_part(body, "box", Vector3(0.33, 1.12, 0.05), Vector3(0.04, 0.14, 0.22), Color("#ef233c"))
			_part(body, "cyl", Vector3(0, 0.85, -0.46), Vector3(0.5, 0.03, 0.5), c5.darkened(0.25), "toon", Vector3(PI / 2.0, 0, 0))
			top_y = 1.2
		"washer":
			var c6 := Color("#f8f9fa")
			_part(body, "box", Vector3(0, 0.48, 0), Vector3(0.9, 0.96, 0.85), c6, "rim")
			_part(body, "torus", Vector3(0, 0.45, -0.43), Vector3(0.62, 0.62, 0.62), Color("#adb5bd"), "shiny", Vector3(PI / 2.0, 0, 0))
			_part(body, "cyl", Vector3(0, 0.45, -0.42), Vector3(0.48, 0.02, 0.48), Color("#4cc9f0"), "shiny", Vector3(PI / 2.0, 0, 0))
			_part(body, "sphere_lo", Vector3(0.08, 0.4, -0.42), Vector3(0.18, 0.12, 0.04), Color("#f72585"))
			_part(body, "box", Vector3(0, 0.88, -0.43), Vector3(0.88, 0.12, 0.02), Color("#dee2e6"))
			_part(body, "sphere_lo", Vector3(0.3, 0.88, -0.45), Vector3.ONE * 0.07, Color("#06d6a0"), "glow")
			top_y = 0.96
		_:   # jar
			_part(body, "cyl", Vector3(0, 0.42, 0), Vector3(0.78, 0.84, 0.78), Color("#d00000"), "rim")
			_part(body, "cyl", Vector3(0, 0.45, 0), Vector3(0.8, 0.3, 0.8), Color("#fff3b0"))
			_part(body, "cyl", Vector3(0, 0.9, 0), Vector3(0.7, 0.12, 0.7), Color("#e9c46a"), "shiny")
			_part(body, "sphere_lo", Vector3(0, 0.46, -0.4), Vector3(0.16, 0.16, 0.03), Color("#d00000"))
			top_y = 0.95


func _build_head() -> void:
	_part(head, "sphere", Vector3.ZERO, Vector3(1.0, 0.92, 1.0) * HEAD_R * 2.0, head_color, "rim")
	for side in [-1.0, 1.0]:
		var eye := Node3D.new()
		eye.position = Vector3(0.15 * side, 0.09, -0.33)
		head.add_child(eye)
		_part(eye, "sphere", Vector3.ZERO, Vector3.ONE * 0.26, Color.WHITE)
		var pupil := Node3D.new()
		eye.add_child(pupil)
		_part(pupil, "sphere_lo", Vector3(0, 0, -0.1), Vector3.ONE * 0.12, Color("#141824"))
		_part(pupil, "sphere_lo", Vector3(0.02, 0.03, -0.155), Vector3.ONE * 0.035, Color.WHITE, "glow")
		_eyes.append(eye)
		_pupils.append(pupil)
		var brow := Node3D.new()
		brow.position = Vector3(0.15 * side, 0.27, -0.33)
		head.add_child(brow)
		_part(brow, "box", Vector3.ZERO, Vector3(0.18, 0.04, 0.04), Color("#141824"))
		_brows.append(brow)
	_mouth = _part(head, "sphere_lo", Vector3(0, -0.15, -0.36), Vector3(0.22, 0.08, 0.08), Color("#5a1a2a"))
	# A little tuft on top so heads read from far away.
	_part(head, "capsule", Vector3(0.04, 0.42, 0), Vector3(0.07, 0.08, 0.07), head_color.darkened(0.25), "toon", Vector3(0, 0, -0.3))


# ------------------------------------------------------------------ controls

## Head-bonk: the spring fires the head forward and snaps it back.
func lunge() -> void:
	_lunge_t = 0.0


func hit() -> void:
	_dizzy = 1.0
	_land_squash = 1.0


func cheer(on: bool) -> void:
	_cheer = 1.0 if on else 0.0


func set_shield(on: bool) -> void:
	if _shield.visible != on:
		_shield.visible = on


func set_label_visible(on: bool) -> void:
	if _label:
		_label.visible = on


## Call every frame with the character's world velocity and whether it stands.
func animate(delta: float, vel: Vector3, grounded: bool) -> void:
	_t += delta
	var hspeed := Vector2(vel.x, vel.z).length()
	# Turn toward the facing yaw.
	rotation.y = lerp_angle(rotation.y, facing_yaw, minf(delta * 14.0, 1.0))

	# Hop-walk: objects don't have legs, so they bounce along.
	var hop := 0.0
	var squash := 0.0
	if grounded and hspeed > 0.6:
		_hop_phase += delta * (9.0 + hspeed * 0.9)
		hop = absf(sin(_hop_phase)) * 0.16 * clampf(hspeed / PopRules.MOVE_SPEED, 0.3, 1.0)
		squash = (1.0 - absf(sin(_hop_phase))) * 0.12
	else:
		_hop_phase = 0.0
	if grounded and not _was_grounded:
		_land_squash = maxf(_land_squash, clampf(-_prev_vel.y / 14.0, 0.25, 1.0))
	_was_grounded = grounded
	_land_squash = maxf(_land_squash - delta * 4.0, 0.0)
	var ls := sin(_land_squash * PI) * 0.28 * _land_squash
	var air_stretch := 0.0 if grounded else clampf(absf(vel.y) / 20.0, 0.0, 0.18)
	var sy := 1.0 - squash - ls + air_stretch
	var sxz := 1.0 + (squash + ls) * 0.6 - air_stretch * 0.5
	if _cheer > 0.0:
		hop = absf(sin(_t * 7.0)) * 0.5
		body.rotation.y += delta * 6.0
	else:
		body.rotation.y = lerp_angle(body.rotation.y, 0.0, minf(delta * 8.0, 1.0))
	body.position.y = hop
	body.scale = Vector3(sxz, sy, sxz)

	# Springy head: lags behind changes in velocity (in local space), then wobbles.
	var accel := (vel - _prev_vel) / maxf(delta, 0.001)
	_prev_vel = vel
	var local_acc := global_transform.basis.inverse() * accel
	var target := Vector3(-local_acc.x, 0.0, -local_acc.z) * 0.012
	target.y = clampf(-local_acc.y * 0.006, -0.25, 0.25)
	target = target.limit_length(0.5)
	_sway_v += ((target - _sway) * 140.0 - _sway_v * 9.0) * delta
	_sway += _sway_v * delta
	_sway = _sway.limit_length(0.65)

	# Lunge: out fast (0.09 s), hold, back with a wobble (0.3 s).
	if _lunge_t >= 0.0:
		_lunge_t += delta
		if _lunge_t < 0.09:
			_lunge = ease(_lunge_t / 0.09, 0.4)
		elif _lunge_t < 0.16:
			_lunge = 1.0
		elif _lunge_t < 0.46:
			_lunge = 1.0 - ease((_lunge_t - 0.16) / 0.3, 2.0)
		else:
			_lunge = 0.0
			_lunge_t = -1.0
			_sway_v += Vector3(0, 0, 3.0)
	_dizzy = maxf(_dizzy - delta * 0.9, 0.0)

	# Blink every few seconds.
	_next_blink -= delta
	if _next_blink <= 0.0:
		_blink = 1.0
		_next_blink = randf_range(1.8, 4.5)
	_blink = maxf(_blink - delta * 9.0, 0.0)
	_layout_spring(hop)
	_face(delta)

	# Blob shadow on the table.
	if _shadow:
		var gp := global_position
		var on := PopRules.on_table(gp) and gp.y > -0.6 and gp.y < 14.0
		_shadow.visible = on
		if on:
			var k := clampf(1.0 - gp.y / 10.0, 0.35, 1.0)
			_shadow.global_position = Vector3(gp.x, 0.02, gp.z)
			_shadow.scale = Vector3.ONE * 1.5 * k
			_shadow.global_rotation = Vector3.ZERO


func _layout_spring(hop := 0.0) -> void:
	var base := Vector3(0, top_y * body.scale.y + hop, 0)
	var bob := sin(_t * 2.2) * 0.03
	var out := Vector3(0, SPRING_REST + bob, 0) + _sway
	# The lunge throws the head forward (-Z) and a bit down.
	out += Vector3(0, -0.1, -1.55) * _lunge
	if _cheer > 0.0:
		out.y += absf(sin(_t * 7.0)) * 0.35
	var end := base + out
	head_pivot.position = end + Vector3(0, HEAD_R * 0.8, 0)
	var dir := out.normalized() if out.length() > 0.01 else Vector3.UP
	var slen := out.length()
	# Rings lie across the spring line: rotate them so their hole faces along it.
	var ring_basis := Basis(Quaternion(Vector3.UP, dir)) if dir.cross(Vector3.UP).length() > 0.001 else Basis()
	for i in RING_COUNT:
		var f := (i + 0.5) / RING_COUNT
		var r := _rings[i]
		r.position = base + out * f
		r.basis = ring_basis * Basis.from_scale(Vector3(0.9 - f * 0.15, clampf(slen / (SPRING_REST * 1.6), 0.6, 2.4), 0.9 - f * 0.15))
		r.rotate_object_local(Vector3.UP, f * 2.0)
	# Head tilts with the sway; lunge pitches it forward a little.
	var tilt := Vector3(_sway.z * 1.2 - _lunge * 0.35, 0.0, -_sway.x * 1.2)
	if _dizzy > 0.0:
		tilt.y = sin(_t * 18.0) * 0.6 * _dizzy
	head.rotation = tilt
	var hs := 1.0 + _lunge * 0.12
	head.scale = Vector3(hs, 2.0 - hs, hs)
	if _label:
		_label.position = end + Vector3(0, HEAD_R * 2.0 + 0.45, 0)


func _face(delta: float) -> void:
	var blink_s := 1.0 - _blink * 0.9
	for i in 2:
		var eye: Node3D = _eyes[i]
		eye.scale = Vector3(1.0, blink_s, 1.0)
		var pupil: Node3D = _pupils[i]
		if _dizzy > 0.0:
			var a := _t * 14.0 + i * PI
			pupil.position = Vector3(cos(a), sin(a), 0) * 0.045
		else:
			# Googly: pupils lag behind the head's motion.
			var want := Vector3(-_sway.x, -_sway.y - 0.01, 0) * 0.12
			pupil.position = pupil.position.lerp(want.limit_length(0.05), minf(delta * 10.0, 1.0))
		var brow: Node3D = _brows[i]
		var side := -1.0 if i == 0 else 1.0
		var angry := _lunge if _lunge > 0.0 else 0.0
		brow.rotation.z = side * (-0.45 * angry + 0.3 * _dizzy)
		brow.position.y = 0.27 + 0.05 * _dizzy - 0.03 * angry
	# Mouth: grin normally, a big O when dizzy or lunging.
	var o := maxf(_dizzy, _lunge)
	_mouth.scale = Vector3(lerpf(0.22, 0.14, o), lerpf(0.08, 0.16, o), 0.08)
