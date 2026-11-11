class_name PopArena
extends Node3D
## The Pop-Up Panic world: a giant picnic table floating above a sea of candy
## clouds at sunset. A silver spoon sweeps round from the pepper-mill in the
## middle; in the last 30 seconds a fork rises opposite it. Four jelly puddings
## fling you skyward. Everything here is visual: the rules live in PopRules.

const CLOTH_SHADER := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
uniform vec4 col_a : source_color = vec4(0.94, 0.27, 0.36, 1.0);
uniform vec4 col_b : source_color = vec4(1.0, 0.97, 0.93, 1.0);
uniform vec4 rim : source_color = vec4(1.0, 0.8, 0.32, 1.0);
uniform float radius = 12.0;
uniform float danger = 0.0;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 c = floor(wp.xz / 1.5);
	float k = mod(c.x + c.y, 2.0);
	vec3 col = mix(col_a.rgb, col_b.rgb, k);
	// soft weave lines
	vec2 f = fract(wp.xz / 1.5);
	float line = smoothstep(0.0, 0.04, f.x) * smoothstep(0.0, 0.04, f.y);
	col *= mix(0.9, 1.0, line);
	float r = length(wp.xz);
	// pulsing warning band near the edge
	float band = smoothstep(radius - 1.6, radius - 1.1, r) * (1.0 - smoothstep(radius - 0.55, radius - 0.45, r));
	col = mix(col, vec3(1.0, 0.25, 0.3), band * (0.25 + 0.25 * danger));
	col = mix(col, rim.rgb, smoothstep(radius - 0.45, radius - 0.4, r));
	ALBEDO = col;
	ROUGHNESS = 0.8;
}
"""

var spoon: Node3D
var fork: Node3D
var pads: Array[Node3D] = []
var _pad_jiggle: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _decor: Array = []       # [node, spin speed, bob phase, base y]
var _cloth: ShaderMaterial
var _sun_glow: MeshInstance3D
var _t := 0.0
var confetti: CPUParticles3D


func build() -> void:
	_environment()
	_table()
	_hub_and_arms()
	_pads()
	_sky_decor()


func _environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color("#5aa9ff")
	sm.sky_horizon_color = Color("#ffc7dd")
	sm.ground_horizon_color = Color("#ffc7dd")
	sm.ground_bottom_color = Color("#ffe6f0")
	sm.sky_curve = 0.12
	sm.sun_angle_max = 18.0
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.0
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_white = 1.4
	e.glow_enabled = true
	e.glow_intensity = 0.55
	e.glow_bloom = 0.04
	e.glow_hdr_threshold = 1.0
	e.fog_enabled = true
	e.fog_light_color = Color("#ffd9e8")
	e.fog_density = 0.0035
	e.fog_sky_affect = 0.0
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -30, 0)
	sun.light_energy = 1.15
	sun.light_color = Color("#fff1dc")
	sun.shadow_enabled = false   # blob shadows instead: much cheaper on phones
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 150, 0)
	fill.light_energy = 0.35
	fill.light_color = Color("#b9d7ff")
	add_child(fill)


func _mi(parent: Node3D, mesh_key: String, pos: Vector3, scl: Vector3, col: Color, kind := "toon", rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = PopCharacter.mesh(mesh_key)
	mi.material_override = PopCharacter.mat(col, kind)
	mi.position = pos
	mi.scale = scl
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _table() -> void:
	var R := PopRules.ARENA_R
	# Table top with the checked cloth.
	var top := CylinderMesh.new()
	top.top_radius = R
	top.bottom_radius = R
	top.height = 0.6
	top.radial_segments = 64
	top.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = top
	_cloth = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = CLOTH_SHADER
	_cloth.shader = sh
	_cloth.set_shader_parameter("radius", R)
	mi.material_override = _cloth
	mi.position = Vector3(0, -0.3, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	# Cloth overhang with a scalloped hem.
	var hang := CylinderMesh.new()
	hang.top_radius = R + 0.05
	hang.bottom_radius = R + 0.35
	hang.height = 0.9
	hang.radial_segments = 64
	hang.rings = 1
	var hm := MeshInstance3D.new()
	hm.mesh = hang
	hm.material_override = PopCharacter.mat(Color("#ff6b7a"))
	hm.position = Vector3(0, -0.75, 0)
	add_child(hm)
	for i in 48:
		var a := TAU * i / 48.0
		_mi(self, "sphere_lo", Vector3(cos(a) * (R + 0.35), -1.2, sin(a) * (R + 0.35)), Vector3(0.9, 0.5, 0.9),
			Color("#fff4e6") if i % 2 == 0 else Color("#ffd166"))
	# One fat pedestal leg disappearing into the clouds.
	_mi(self, "cone", Vector3(0, -6.0, 0), Vector3(3.0, 9.5, 3.0), Color("#b5835a"))
	_mi(self, "cyl", Vector3(0, -1.35, 0), Vector3(5.0, 0.3, 5.0), Color("#9c6b45"))


func _hub_and_arms() -> void:
	# The pepper mill in the middle.
	var hub := Node3D.new()
	add_child(hub)
	_mi(hub, "cyl", Vector3(0, 0.9, 0), Vector3(PopRules.HUB_R * 2.0, 1.8, PopRules.HUB_R * 2.0), Color("#6b3e26"), "rim")
	_mi(hub, "torus", Vector3(0, 0.25, 0), Vector3.ONE * PopRules.HUB_R * 2.1, Color("#e9c46a"), "shiny")
	_mi(hub, "torus", Vector3(0, 1.75, 0), Vector3.ONE * PopRules.HUB_R * 2.1, Color("#e9c46a"), "shiny")
	_mi(hub, "sphere", Vector3(0, 2.3, 0), Vector3(2.6, 1.6, 2.6), Color("#7f4a2f"), "rim")
	_mi(hub, "sphere", Vector3(0, 3.2, 0), Vector3.ONE * 0.6, Color("#ffd166"), "shiny")
	# A silly face on the mill, because why not.
	for s in [-1.0, 1.0]:
		_mi(hub, "sphere", Vector3(0.45 * s, 1.25, -PopRules.HUB_R + 0.02), Vector3(0.55, 0.6, 0.2), Color.WHITE)
		_mi(hub, "sphere_lo", Vector3(0.45 * s, 1.22, -PopRules.HUB_R - 0.08), Vector3(0.25, 0.25, 0.1), Color("#141824"))
	_mi(hub, "sphere_lo", Vector3(0, 0.75, -PopRules.HUB_R + 0.02), Vector3(0.7, 0.25, 0.15), Color("#5a1a2a"))

	# The spoon: a pivot at the centre; the arm points along local +X.
	spoon = Node3D.new()
	spoon.position = Vector3(0, PopRules.SPOON_Y, 0)
	add_child(spoon)
	var arm_len := PopRules.ARENA_R + 0.3 - PopRules.HUB_R
	var cx := PopRules.HUB_R + arm_len / 2.0
	_mi(spoon, "capsule", Vector3(cx - 0.8, 0, 0), Vector3(PopRules.SPOON_R * 2.0, arm_len / 2.0 - 0.4, PopRules.SPOON_R * 2.0),
		Color("#dfe6ee"), "shiny", Vector3(0, 0, PI / 2.0))
	_mi(spoon, "sphere", Vector3(PopRules.ARENA_R - 0.2, 0.05, 0), Vector3(2.4, 0.5, 1.5), Color("#e8eef5"), "shiny")
	_mi(spoon, "sphere", Vector3(PopRules.ARENA_R - 0.2, 0.2, 0), Vector3(2.0, 0.25, 1.2), Color("#b8c4d2"), "shiny")
	_mi(spoon, "torus", Vector3(PopRules.HUB_R + 0.5, 0, 0), Vector3(1.2, 1.2, 1.2), Color("#ffd166"), "shiny", Vector3(0, 0, PI / 2.0))
	# Glow streak along the arm so it reads from far away.
	_mi(spoon, "box", Vector3(cx, PopRules.SPOON_R * 0.95, 0), Vector3(arm_len - 1.0, 0.04, 0.12), Color(1.6, 1.4, 0.9), "glow")

	# The fork rises opposite the spoon for the frenzy.
	fork = Node3D.new()
	fork.position = Vector3(0, -2.0, 0)
	fork.visible = false
	add_child(fork)
	_mi(fork, "capsule", Vector3(cx - 1.0, 0, 0), Vector3(PopRules.SPOON_R * 2.0, arm_len / 2.0 - 0.6, PopRules.SPOON_R * 2.0),
		Color("#ffcf5c"), "shiny", Vector3(0, 0, PI / 2.0))
	_mi(fork, "box", Vector3(PopRules.ARENA_R - 1.4, 0, 0), Vector3(0.5, 0.4, 1.3), Color("#ffcf5c"), "shiny")
	for i in 4:
		_mi(fork, "box", Vector3(PopRules.ARENA_R - 0.4, 0, -0.5 + i * 0.333), Vector3(1.6, 0.18, 0.14), Color("#ffcf5c"), "shiny")
	_mi(fork, "box", Vector3(cx, PopRules.SPOON_R * 0.95, 0), Vector3(arm_len - 1.0, 0.04, 0.12), Color(1.8, 0.6, 0.4), "glow")


func _pads() -> void:
	var cols := [Color("#ff5d8f"), Color("#7bdff2"), Color("#b2f7a1"), Color("#ffd166")]
	for i in PopRules.PAD_ANGLES.size():
		var p := Node3D.new()
		p.position = PopRules.pad_center(i)
		add_child(p)
		_mi(p, "cone", Vector3(0, 0.12, 0), Vector3(PopRules.PAD_R * 2.0, 0.26, PopRules.PAD_R * 2.0), cols[i], "rim")
		_mi(p, "cyl", Vector3(0, 0.02, 0), Vector3(PopRules.PAD_R * 2.3, 0.04, PopRules.PAD_R * 2.3), Color("#ffffff"))
		_mi(p, "sphere_lo", Vector3(0, 0.3, 0), Vector3(0.32, 0.3, 0.32), Color("#e63946"), "shiny")
		# a glowing ring so you can spot the pads
		_mi(p, "torus", Vector3(0, 0.05, 0), Vector3.ONE * PopRules.PAD_R * 2.1, Color(cols[i] * 1.6), "glow")
		pads.append(p)


func _sky_decor() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	# A sea of clouds below the table.
	for i in 34:
		var a := rng.randf() * TAU
		var r := rng.randf_range(6.0, 60.0)
		var c := Node3D.new()
		c.position = Vector3(cos(a) * r, rng.randf_range(-16.0, -9.0), sin(a) * r)
		add_child(c)
		var tint := Color("#ffffff").lerp(Color("#ffd1e3"), rng.randf() * 0.6)
		for j in 4:
			_mi(c, "sphere_lo", Vector3(rng.randf_range(-3, 3), rng.randf_range(-0.5, 0.8), rng.randf_range(-3, 3)),
				Vector3.ONE * rng.randf_range(3.0, 6.0), tint)
		_decor.append([c, 0.0, rng.randf() * TAU, c.position.y, rng.randf_range(0.3, 0.7)])
	# Giant floating donuts and candy around the horizon.
	var icing := [Color("#ff8fab"), Color("#9bf6ff"), Color("#caffbf"), Color("#fdffb6"), Color("#bdb2ff")]
	for i in 7:
		var a2 := TAU * i / 7.0 + 0.3
		var d := Node3D.new()
		d.position = Vector3(cos(a2) * 34.0, rng.randf_range(-2.0, 10.0), sin(a2) * 34.0)
		d.rotation = Vector3(rng.randf_range(-0.8, 0.8), rng.randf() * TAU, rng.randf_range(-0.6, 0.6))
		add_child(d)
		if i % 2 == 0:
			_mi(d, "torus", Vector3.ZERO, Vector3.ONE * 6.0, Color("#e0a96d"))
			_mi(d, "torus", Vector3(0, 0.35, 0), Vector3(6.1, 3.0, 6.1), icing[i % icing.size()], "rim")
		else:
			# a wrapped sweet
			_mi(d, "sphere", Vector3.ZERO, Vector3(3.0, 2.4, 2.4), icing[i % icing.size()], "shiny")
			_mi(d, "cone", Vector3(2.1, 0, 0), Vector3(1.6, 1.2, 1.6), icing[(i + 2) % icing.size()], "toon", Vector3(0, 0, PI / 2.0))
			_mi(d, "cone", Vector3(-2.1, 0, 0), Vector3(1.6, 1.2, 1.6), icing[(i + 2) % icing.size()], "toon", Vector3(0, 0, -PI / 2.0))
		_decor.append([d, rng.randf_range(0.1, 0.25) * (1 if i % 2 else -1), rng.randf() * TAU, d.position.y, 1.2])
	# Balloons drifting up behind the table.
	for i in 10:
		var a3 := rng.randf() * TAU
		var b := Node3D.new()
		b.position = Vector3(cos(a3) * rng.randf_range(18.0, 28.0), rng.randf_range(-8.0, 14.0), sin(a3) * rng.randf_range(18.0, 28.0))
		add_child(b)
		_mi(b, "sphere", Vector3.ZERO, Vector3(1.4, 1.7, 1.4), icing[i % icing.size()].lightened(0.1), "shiny")
		_mi(b, "box", Vector3(0, -1.6, 0), Vector3(0.03, 1.6, 0.03), Color("#ffffff"))
		_decor.append([b, 0.0, rng.randf() * TAU, b.position.y, -1.0])   # -1: rises and wraps
	# A big soft sun.
	_sun_glow = _mi(self, "sphere_lo", Vector3(-60, 26, -70), Vector3.ONE * 14.0, Color(1.7, 1.3, 1.0), "glow")
	# Gentle confetti always drifting over the table.
	confetti = CPUParticles3D.new()
	confetti.amount = 40
	confetti.lifetime = 7.0
	confetti.preprocess = 7.0
	confetti.position = Vector3(0, 12, 0)
	confetti.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	confetti.emission_box_extents = Vector3(14, 0.5, 14)
	confetti.direction = Vector3.DOWN
	confetti.spread = 20.0
	confetti.gravity = Vector3(0, -1.2, 0)
	confetti.initial_velocity_min = 0.3
	confetti.initial_velocity_max = 0.8
	confetti.angular_velocity_min = -180.0
	confetti.angular_velocity_max = 180.0
	confetti.scale_amount_min = 0.08
	confetti.scale_amount_max = 0.14
	confetti.color_initial_ramp = PopFx.party_gradient()
	var q := QuadMesh.new()
	q.size = Vector2(1.0, 0.6)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.vertex_color_use_as_albedo = true
	qm.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material = qm
	confetti.mesh = q
	add_child(confetti)


## Pad `i` just flung someone: wobble it.
func jiggle_pad(i: int) -> void:
	if i >= 0 and i < _pad_jiggle.size():
		_pad_jiggle[i] = 1.0


func update(delta: float, t: float, frenzy: float, edge_danger: float) -> void:
	_t += delta
	spoon.rotation.y = -PopRules.spoon_angle(t)
	fork.visible = frenzy > 0.0
	if fork.visible:
		fork.rotation.y = -(PopRules.spoon_angle(t) + PI)
		fork.position.y = lerpf(-2.0, PopRules.SPOON_Y, ease(frenzy, 0.5))
	for i in pads.size():
		_pad_jiggle[i] = maxf(_pad_jiggle[i] - delta * 1.6, 0.0)
		var j := _pad_jiggle[i]
		var w := sin(_t * 26.0) * j * 0.35
		var idle := sin(_t * 3.0 + i) * 0.03
		pads[i].scale = Vector3(1.0 + w * 0.5 - idle, 1.0 - w + idle * 2.0, 1.0 + w * 0.5 - idle)
	for d in _decor:
		var n: Node3D = d[0]
		if float(d[4]) < 0.0:
			n.position.y += delta * 0.8
			if n.position.y > 22.0:
				n.position.y = -14.0
			n.position.x += sin(_t * 0.4 + float(d[2])) * delta * 0.3
		else:
			n.rotation.y += float(d[1]) * delta
			n.position.y = float(d[3]) + sin(_t * 0.5 + float(d[2])) * float(d[4])
	_cloth.set_shader_parameter("danger", edge_danger * (0.5 + 0.5 * sin(_t * 8.0)))
