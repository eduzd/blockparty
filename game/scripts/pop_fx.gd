class_name PopFx
extends Node3D
## Pop-Up Panic's effects: one shared pool of particle bursts (stars, puffs,
## confetti) reused round-robin, so a busy moment never spawns new nodes.

const POOL := 10
var _bursts: Array[CPUParticles3D] = []
var _next := 0
var _rings: Array[MeshInstance3D] = []
var _ring_t: Array[float] = []
var _next_ring := 0
static var _grad: Gradient


static func party_gradient() -> Gradient:
	if _grad:
		return _grad
	_grad = Gradient.new()
	_grad.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
	_grad.colors = PackedColorArray([Color("#ff5d8f"), Color("#ffd166"), Color("#06d6a0"), Color("#4cc9f0"), Color("#b388ff")])
	return _grad


func _ready() -> void:
	var star := PrismMesh.new()
	star.size = Vector3(0.3, 0.3, 0.06)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	star.material = m
	for i in POOL:
		var p := CPUParticles3D.new()
		p.emitting = false
		p.one_shot = true
		p.explosiveness = 0.95
		p.amount = 18
		p.lifetime = 0.8
		p.mesh = star
		p.direction = Vector3.UP
		p.spread = 180.0
		p.gravity = Vector3(0, -9, 0)
		p.initial_velocity_min = 3.0
		p.initial_velocity_max = 7.0
		p.angular_velocity_min = -400.0
		p.angular_velocity_max = 400.0
		p.scale_amount_min = 0.6
		p.scale_amount_max = 1.4
		var curve := Curve.new()
		curve.add_point(Vector2(0, 1))
		curve.add_point(Vector2(0.7, 0.8))
		curve.add_point(Vector2(1, 0))
		p.scale_amount_curve = curve
		p.color_initial_ramp = party_gradient()
		add_child(p)
		_bursts.append(p)
	# Shock rings for landings and bonks.
	var tm := TorusMesh.new()
	tm.inner_radius = 0.9
	tm.outer_radius = 1.0
	tm.rings = 32
	tm.ring_segments = 4
	for i in 4:
		var r := MeshInstance3D.new()
		r.mesh = tm
		var rm := StandardMaterial3D.new()
		rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		rm.albedo_color = Color(1, 1, 1, 0.0)
		r.material_override = rm
		r.visible = false
		r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(r)
		_rings.append(r)
		_ring_t.append(-1.0)


func _burst(at: Vector3, amount: int, speed: float, life: float, grav: float, scale_k: float, tint := Color.WHITE) -> void:
	var p := _bursts[_next]
	_next = (_next + 1) % POOL
	p.emitting = false
	p.global_position = at
	p.amount = amount
	p.lifetime = life
	p.initial_velocity_min = speed * 0.5
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -grav, 0)
	p.scale_amount_min = 0.6 * scale_k
	p.scale_amount_max = 1.4 * scale_k
	p.color = tint
	p.restart()
	p.emitting = true


## A head-bonk landed: a starburst.
func stars(at: Vector3) -> void:
	_burst(at, 16, 7.0, 0.7, 6.0, 1.2)
	ring(at, Color(1, 0.9, 0.4), 2.6)


## A soft puff of dust (landing, hop).
func puff(at: Vector3, k := 1.0) -> void:
	_burst(at + Vector3(0, 0.1, 0), int(8 + 6 * k), 2.5 * k, 0.45, -1.0, 0.7, Color(1, 1, 1, 0.9))
	if k > 0.5:
		ring(at + Vector3(0, 0.05, 0), Color(1, 1, 1), 1.6 * k)


## Somebody got knocked out: a big confetti pop where they fell.
func confetti_pop(at: Vector3) -> void:
	_burst(at, 40, 13.0, 1.6, 7.0, 1.5)


func ring(at: Vector3, col: Color, size: float) -> void:
	var r := _rings[_next_ring]
	_ring_t[_next_ring] = 0.0
	_next_ring = (_next_ring + 1) % _rings.size()
	r.global_position = at
	r.set_meta("size", size)
	(r.material_override as StandardMaterial3D).albedo_color = Color(col.r, col.g, col.b, 0.8)
	r.visible = true


func _process(delta: float) -> void:
	for i in _rings.size():
		if _ring_t[i] < 0.0:
			continue
		_ring_t[i] += delta / 0.35
		var r := _rings[i]
		if _ring_t[i] >= 1.0:
			_ring_t[i] = -1.0
			r.visible = false
			continue
		var s: float = float(r.get_meta("size", 2.0)) * ease(_ring_t[i], 0.4)
		r.scale = Vector3(s, 1.0, s)
		var m := r.material_override as StandardMaterial3D
		m.albedo_color.a = 0.8 * (1.0 - _ring_t[i])
