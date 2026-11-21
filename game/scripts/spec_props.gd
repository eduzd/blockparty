class_name SpecProps
extends RefCounted
## Plux 0.8.0: builds the look of every spec shape (primitives and props) from a few
## cheap meshes, with shared materials. Everything is BOTTOM-CENTRE: the node's
## origin is where the object's base sits, and the mesh fills `size` exactly.

var _mats := {}
var _meshes := {}
var light_budget := 4          # lamps that get a real light (phones)


## Shared material for a colour and surface type.
func mat(c: Color, kind := "plain", glow := 0.0) -> StandardMaterial3D:
	var key := "%s|%s|%.2f" % [c.to_html(), kind, glow]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.75
	match kind:
		"glow":
			m.emission_enabled = true
			m.emission = c
			m.emission_energy_multiplier = 1.4
		"lava":
			m.albedo_color = Color("#FF5722")
			m.emission_enabled = true
			m.emission = Color("#FF6D00")
			m.emission_energy_multiplier = 1.8
		"metal":
			m.metallic = 0.85
			m.roughness = 0.3
		"ice":
			m.albedo_color = c.lerp(Color("#B3E5FC"), 0.6)
			m.roughness = 0.12
			m.metallic = 0.2
			m.emission_enabled = true
			m.emission = Color("#81D4FA")
			m.emission_energy_multiplier = 0.15
		"glass":
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_color = Color(c.r, c.g, c.b, 0.35)
			m.roughness = 0.05
		"water":
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_color = Color(0.16, 0.5, 0.9, 0.75)
			m.roughness = 0.08
			m.metallic = 0.3
		"ghost":
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_color = Color(c.r, c.g, c.b, 0.7)
			m.emission_enabled = true
			m.emission = c
			m.emission_energy_multiplier = 0.5
		"grass":
			m.roughness = 0.95
		"sand", "snow", "stone", "asphalt":
			m.roughness = 0.9
		"wood":
			m.roughness = 0.8
		"candy":
			m.roughness = 0.25
			m.metallic = 0.05
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	_mats[key] = m
	return m


func _mi(parent: Node3D, mesh: Mesh, m: Material, pos: Vector3, rot := Vector3.ZERO, shadow := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.position = pos
	mi.rotation = rot
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func box(s: Vector3) -> BoxMesh:
	var k := "b%s" % s
	if not _meshes.has(k):
		var m := BoxMesh.new()
		m.size = s
		_meshes[k] = m
	return _meshes[k]


func cyl(top: float, bottom: float, h: float, seg := 16) -> CylinderMesh:
	var k := "c%.2f|%.2f|%.2f|%d" % [top, bottom, h, seg]
	if not _meshes.has(k):
		var m := CylinderMesh.new()
		m.top_radius = top
		m.bottom_radius = bottom
		m.height = h
		m.radial_segments = seg
		m.rings = 1
		_meshes[k] = m
	return _meshes[k]


func sphere(r: float, h: float, seg := 16, rings := 8, hemi := false) -> SphereMesh:
	var k := "s%.2f|%.2f|%d|%d|%s" % [r, h, seg, rings, hemi]
	if not _meshes.has(k):
		var m := SphereMesh.new()
		m.radius = r
		m.height = h
		m.radial_segments = seg
		m.rings = rings
		m.is_hemisphere = hemi
		_meshes[k] = m
	return _meshes[k]


func prism(s: Vector3, ltr := 0.5) -> PrismMesh:
	var k := "p%s|%.2f" % [s, ltr]
	if not _meshes.has(k):
		var m := PrismMesh.new()
		m.size = s
		m.left_to_right = ltr
		_meshes[k] = m
	return _meshes[k]


## Ramp: high end towards local -z, low end at +z, full size.
func ramp_mesh(s: Vector3) -> PrismMesh:
	return prism(Vector3(s.z, s.y, s.x), 0.0)


const RAMP_ROT := Vector3(0, -PI / 2.0, 0)


## Builds the look of one entity under `root`. Returns nodes that animate:
## {"spin": Node3D or null, "wheels": [], "head": Node3D or null, "cloth": Node3D or null}
func build(root: Node3D, shape: String, s: Vector3, c: Color, kind: String, dark_world := false) -> Dictionary:
	var out := {"spin": null, "wheels": [], "head": null, "cloth": null}
	var m := mat(c, kind)
	var small := s.length() < 1.2
	match shape:
		"box", "crate":
			if shape == "crate" and kind == "plain":
				m = mat(c if c != Color("#90A4AE") else Color("#A1887F"), "wood")
			_mi(root, box(s), m, Vector3(0, s.y / 2.0, 0))
			if shape == "crate":
				var edge := mat(c.darkened(0.35), "wood")
				_mi(root, box(Vector3(s.x * 1.02, s.y * 0.12, s.z * 1.02)), edge, Vector3(0, s.y * 0.94, 0), Vector3.ZERO, false)
				_mi(root, box(Vector3(s.x * 1.02, s.y * 0.12, s.z * 1.02)), edge, Vector3(0, s.y * 0.06, 0), Vector3.ZERO, false)
		"sphere", "ball":
			var r := minf(s.x, s.z) / 2.0
			var sp := _mi(root, sphere(r, s.y, 20, 10), m, Vector3(0, s.y / 2.0, 0))
			if shape == "ball":
				_mi(sp, sphere(r * 1.01, s.y * 1.01, 6, 3), mat(Color("#263238")), Vector3.ZERO, Vector3(0.4, 0.3, 0), false).transparency = 0.6
			out.spin = sp
		"cylinder", "barrel":
			_mi(root, cyl(s.x / 2.0, s.x / 2.0, s.y), m, Vector3(0, s.y / 2.0, 0))
			if shape == "barrel":
				var band := mat(c.darkened(0.4), "metal")
				for f in [0.2, 0.8]:
					_mi(root, cyl(s.x * 0.52, s.x * 0.52, s.y * 0.07), band, Vector3(0, s.y * f, 0), Vector3.ZERO, false)
		"cone", "spike":
			_mi(root, cyl(0.0, s.x / 2.0, s.y, 12 if shape == "cone" else 8), m if shape == "cone" else mat(c if kind != "plain" else Color("#B0BEC5"), "metal"), Vector3(0, s.y / 2.0, 0))
		"capsule":
			var cm := CapsuleMesh.new()
			cm.radius = minf(s.x, s.z) / 2.0
			cm.height = maxf(s.y, cm.radius * 2.0)
			_mi(root, cm, m, Vector3(0, s.y / 2.0, 0))
		"ramp":
			_mi(root, ramp_mesh(s), m, Vector3(0, s.y / 2.0, 0), RAMP_ROT)
		"tree":
			var trunk := mat(Color("#6D4C41"), "wood")
			_mi(root, cyl(s.x * 0.09, s.x * 0.13, s.y * 0.42, 8), trunk, Vector3(0, s.y * 0.21, 0))
			var leaf := mat(c, "grass")
			_mi(root, cyl(0.0, s.x * 0.5, s.y * 0.5, 10), leaf, Vector3(0, s.y * 0.5, 0))
			_mi(root, cyl(0.0, s.x * 0.38, s.y * 0.42, 10), mat(c.lightened(0.12), "grass"), Vector3(0, s.y * 0.76, 0))
		"rock":
			var rm := mat(c, "stone")
			_mi(root, sphere(0.5, 1.0, 7, 4), rm, Vector3(0, s.y * 0.45, 0), Vector3(0.2, 0.7, 0.1)).scale = Vector3(s.x, s.y * 0.95, s.z)
		"house":
			var wall := mat(Color("#FFF3E0") if c != Color("#FFF3E0") else Color.WHITE)
			_mi(root, box(Vector3(s.x, s.y * 0.6, s.z)), wall, Vector3(0, s.y * 0.3, 0))
			_mi(root, prism(Vector3(s.x * 1.12, s.y * 0.4, s.z * 1.08)), m, Vector3(0, s.y * 0.8, 0))
			_mi(root, box(Vector3(s.x * 0.2, s.y * 0.34, 0.08)), mat(Color("#5D4037"), "wood"), Vector3(0, s.y * 0.17, s.z / 2.0 + 0.03), Vector3.ZERO, false)
			var win := mat(Color("#FFE082"), "plain", 0.8 if dark_world else 0.0)
			for sx in [-0.3, 0.3]:
				_mi(root, box(Vector3(s.x * 0.16, s.y * 0.14, 0.08)), win, Vector3(s.x * sx, s.y * 0.38, s.z / 2.0 + 0.03), Vector3.ZERO, false)
		"coin":
			var d := _mi(root, cyl(s.x / 2.0, s.x / 2.0, maxf(0.12, s.z * 0.5), 20), mat(c, "metal", 0.9), Vector3(0, s.y / 2.0, 0), Vector3(PI / 2.0, 0, 0), false)
			out.spin = d
		"gem":
			var g := _mi(root, sphere(s.x / 2.0, s.y, 4, 2), mat(c, "glass", 1.2), Vector3(0, s.y / 2.0, 0), Vector3.ZERO, false)
			g.material_override = mat(c, "plain", 1.2)
			out.spin = g
		"star":
			var pivot := Node3D.new()
			pivot.position = Vector3(0, s.y / 2.0, 0)
			root.add_child(pivot)
			var sm := mat(c, "plain", 1.3)
			for i in 5:
				var a := TAU * i / 5.0
				_mi(pivot, cyl(0.0, s.x * 0.17, s.y * 0.5, 4), sm, Vector3(sin(a), cos(a), 0) * s.y * 0.25, Vector3(0, 0, -a), false)
			_mi(pivot, cyl(s.x * 0.2, s.x * 0.2, maxf(0.12, s.z * 0.5), 10), sm, Vector3.ZERO, Vector3(PI / 2.0, 0, 0), false)
			out.spin = pivot
		"heart":
			var hp := Node3D.new()
			hp.position = Vector3(0, s.y / 2.0, 0)
			root.add_child(hp)
			var hm := mat(c, "plain", 1.0)
			_mi(hp, sphere(s.x * 0.28, s.x * 0.56, 12, 6), hm, Vector3(-s.x * 0.2, s.y * 0.12, 0), Vector3.ZERO, false)
			_mi(hp, sphere(s.x * 0.28, s.x * 0.56, 12, 6), hm, Vector3(s.x * 0.2, s.y * 0.12, 0), Vector3.ZERO, false)
			_mi(hp, cyl(0.0, s.x * 0.42, s.y * 0.6, 12), hm, Vector3(0, -s.y * 0.14, 0), Vector3(PI, 0, 0), false)
			out.spin = hp
		"flag":
			_mi(root, cyl(0.06, 0.06, s.y, 8), mat(Color.WHITE, "metal"), Vector3(0, s.y / 2.0, 0))
			var cloth := _mi(root, box(Vector3(maxf(0.9, s.x), 0.62, 0.05)), mat(c, "plain", 0.6), Vector3(maxf(0.9, s.x) / 2.0, s.y - 0.4, 0))
			_mi(root, cyl(maxf(0.6, s.x * 0.6), maxf(0.7, s.x * 0.7), 0.15, 16), mat(c, "plain", 0.9), Vector3(0, 0.08, 0), Vector3.ZERO, false)
			out.cloth = cloth
		"character":
			var body := mat(c)
			var dk := mat(c.darkened(0.45))
			var h := s.y
			for lx in [-0.22, 0.22]:
				_mi(root, box(Vector3(s.x * 0.28, h * 0.38, s.z * 0.3)), dk, Vector3(s.x * lx, h * 0.19, 0), Vector3.ZERO, false)
			_mi(root, box(Vector3(s.x * 0.8, h * 0.34, s.z * 0.45)), body, Vector3(0, h * 0.55, 0))
			for ax in [-0.52, 0.52]:
				_mi(root, box(Vector3(s.x * 0.22, h * 0.3, s.z * 0.24)), body, Vector3(s.x * ax, h * 0.58, -s.z * 0.12), Vector3(-0.9 if c.g > c.r and c.g > c.b else 0.0, 0, 0), false)
			var head := _mi(root, box(Vector3(s.x * 0.56, h * 0.26, s.z * 0.5)), body, Vector3(0, h * 0.85, 0))
			var eye := mat(Color("#FFF59D") if dark_world else Color("#212121"), "plain", 1.5 if dark_world else 0.0)
			for ex in [-0.13, 0.13]:
				_mi(head, box(Vector3(s.x * 0.1, h * 0.05, 0.04)), eye, Vector3(s.x * ex, h * 0.02, -s.z * 0.26), Vector3.ZERO, false)
			out.head = head
		"ghost":
			var gm := mat(c, "ghost")
			var gp := Node3D.new()
			root.add_child(gp)
			_mi(gp, sphere(s.x / 2.0, s.x, 14, 7, true), gm, Vector3(0, s.y * 0.68, 0), Vector3.ZERO, false)
			_mi(gp, cyl(s.x / 2.0, s.x * 0.56, s.y * 0.6, 14), gm, Vector3(0, s.y * 0.38, 0), Vector3.ZERO, false)
			var ge := mat(Color("#1A1A2E"))
			for ex in [-0.16, 0.16]:
				_mi(gp, sphere(s.x * 0.09, s.x * 0.16, 8, 4), ge, Vector3(s.x * ex, s.y * 0.72, -s.x * 0.44), Vector3.ZERO, false)
			out.head = gp
		"car":
			var cb := mat(c, "metal" if kind == "plain" else kind)
			cb.metallic = 0.5
			_mi(root, box(Vector3(s.x, s.y * 0.38, s.z)), cb, Vector3(0, s.y * 0.38, 0))
			_mi(root, box(Vector3(s.x * 0.82, s.y * 0.34, s.z * 0.46)), mat(Color("#263238"), "glass"), Vector3(0, s.y * 0.72, s.z * 0.06))
			_mi(root, box(Vector3(s.x * 0.9, s.y * 0.06, s.z * 0.2)), cb, Vector3(0, s.y * 0.62, s.z * 0.46), Vector3.ZERO, false)
			var wm := mat(Color("#212121"))
			var wr := s.y * 0.27
			for wx in [-0.5, 0.5]:
				for wz in [-0.32, 0.32]:
					var w := _mi(root, cyl(wr, wr, s.x * 0.16, 12), wm, Vector3(s.x * wx, wr, s.z * wz), Vector3(0, 0, PI / 2.0), false)
					out.wheels.append(w)
			var hl := mat(Color("#FFF9C4"), "plain", 2.0)
			var tl := mat(Color("#FF1744"), "plain", 1.6)
			for lx in [-0.32, 0.32]:
				_mi(root, box(Vector3(s.x * 0.18, s.y * 0.08, 0.05)), hl, Vector3(s.x * lx, s.y * 0.45, -s.z / 2.0 - 0.02), Vector3.ZERO, false)
				_mi(root, box(Vector3(s.x * 0.18, s.y * 0.08, 0.05)), tl, Vector3(s.x * lx, s.y * 0.45, s.z / 2.0 + 0.02), Vector3.ZERO, false)
		"goal":
			var pm := mat(Color.WHITE, "metal")
			var pr := clampf(s.x * 0.03, 0.08, 0.2)
			for gx in [-0.5, 0.5]:
				_mi(root, cyl(pr, pr, s.y, 8), pm, Vector3(s.x * gx, s.y / 2.0, 0))
			_mi(root, cyl(pr, pr, s.x, 8), pm, Vector3(0, s.y, 0), Vector3(0, 0, PI / 2.0))
			var net := mat(c, "glass")
			_mi(root, box(Vector3(s.x, s.y, 0.05)), net, Vector3(0, s.y / 2.0, s.z / 2.0), Vector3.ZERO, false)
			_mi(root, box(Vector3(s.x, s.y * 0.04, s.z)), mat(c, "plain", 0.6), Vector3(0, 0.02, 0), Vector3.ZERO, false)
		"ring":
			var tm := TorusMesh.new()
			tm.outer_radius = maxf(s.x, s.y) / 2.0
			tm.inner_radius = tm.outer_radius * 0.82
			tm.rings = 24
			tm.ring_segments = 8
			out.spin = _mi(root, tm, mat(c, "plain", 1.3), Vector3(0, s.y / 2.0, 0), Vector3(PI / 2.0, 0, 0), false)
		"tower":
			_mi(root, cyl(s.x * 0.45, s.x * 0.5, s.y * 0.82, 12), mat(c, "stone" if kind == "plain" else kind), Vector3(0, s.y * 0.41, 0))
			_mi(root, cyl(0.0, s.x * 0.58, s.y * 0.2, 12), mat(Color("#C62828")), Vector3(0, s.y * 0.9, 0))
		"lamp":
			_mi(root, cyl(0.07, 0.1, s.y, 8), mat(Color("#37474F"), "metal"), Vector3(0, s.y / 2.0, 0))
			var bulb := c if c != Color("#90A4AE") else Color("#FFE082")
			_mi(root, sphere(maxf(0.22, s.x * 0.3), maxf(0.44, s.x * 0.6), 12, 6), mat(bulb, "plain", 2.2), Vector3(0, s.y, 0), Vector3.ZERO, false)
			if dark_world and light_budget > 0:
				light_budget -= 1
				var ol := OmniLight3D.new()
				ol.light_color = bulb
				ol.omni_range = 9.0
				ol.light_energy = 1.4
				ol.position = Vector3(0, s.y - 0.3, 0)
				root.add_child(ol)
		"fence":
			var fm := mat(c if c != Color("#90A4AE") else Color("#8D6E63"), "wood")
			var n := maxi(2, int(s.x / 1.6) + 1)
			for i in n:
				_mi(root, box(Vector3(0.14, s.y, 0.14)), fm, Vector3(-s.x / 2.0 + s.x * i / float(n - 1), s.y / 2.0, 0), Vector3.ZERO, false)
			for f in [0.35, 0.8]:
				_mi(root, box(Vector3(s.x, 0.12, 0.08)), fm, Vector3(0, s.y * f, 0), Vector3.ZERO, false)
		"mushroom":
			_mi(root, cyl(s.x * 0.16, s.x * 0.2, s.y * 0.6, 10), mat(Color("#FFF8E1")), Vector3(0, s.y * 0.3, 0))
			var cap := c if c != Color("#90A4AE") else Color("#E53935")
			_mi(root, sphere(s.x / 2.0, s.y * 0.9, 16, 8, true), mat(cap, "candy"), Vector3(0, s.y * 0.55, 0))
			var dot := mat(Color.WHITE)
			for i in 4:
				var a := TAU * i / 4.0 + 0.4
				_mi(root, sphere(s.x * 0.07, s.x * 0.1, 6, 3), dot, Vector3(sin(a) * s.x * 0.3, s.y * 0.8, cos(a) * s.x * 0.3), Vector3.ZERO, false)
		"turret":
			var tb := mat(c, "metal")
			_mi(root, cyl(s.x * 0.45, s.x * 0.5, s.y * 0.45, 12), tb, Vector3(0, s.y * 0.22, 0))
			var head2 := Node3D.new()
			head2.position = Vector3(0, s.y * 0.65, 0)
			root.add_child(head2)
			_mi(head2, sphere(s.x * 0.36, s.y * 0.4, 12, 6), mat(c.lightened(0.2), "metal"), Vector3.ZERO)
			_mi(head2, cyl(s.x * 0.08, s.x * 0.08, s.x * 0.7, 8), mat(Color("#263238"), "metal"), Vector3(0, 0, -s.x * 0.4), Vector3(PI / 2.0, 0, 0), false)
			_mi(head2, sphere(s.x * 0.06, s.x * 0.12, 6, 3), mat(Color("#FF1744"), "plain", 2.0), Vector3(0, s.y * 0.08, -s.x * 0.3), Vector3.ZERO, false)
			out.head = head2
		"grave":
			var st := mat(c, "stone")
			_mi(root, box(Vector3(s.x, s.y * 0.75, s.z * 0.35)), st, Vector3(0, s.y * 0.375, 0))
			_mi(root, cyl(s.x / 2.0, s.x / 2.0, s.z * 0.35, 12), st, Vector3(0, s.y * 0.75, 0), Vector3(PI / 2.0, 0, 0))
			_mi(root, box(Vector3(s.x * 1.1, 0.08, s.z)), mat(Color("#5D4037")), Vector3(0, 0.04, s.z * 0.2), Vector3.ZERO, false)
		_:
			_mi(root, box(s), m, Vector3(0, s.y / 2.0, 0))
	if small:
		for ch in root.get_children():
			if ch is GeometryInstance3D:
				(ch as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return out


## Collision for a solid entity, BOTTOM-CENTRE like the look.
func shape_for(shape: String, s: Vector3) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	match shape:
		"sphere", "ball", "rock":
			var sp := SphereShape3D.new()
			sp.radius = minf(minf(s.x, s.z), s.y) / 2.0
			cs.shape = sp
			cs.position = Vector3(0, s.y / 2.0, 0)
		"cylinder", "barrel", "tower", "turret", "cone", "capsule":
			var cy := CylinderShape3D.new()
			cy.radius = minf(s.x, s.z) / 2.0
			cy.height = s.y
			cs.shape = cy
			cs.position = Vector3(0, s.y / 2.0, 0)
		"tree", "lamp":
			var tr := CylinderShape3D.new()
			tr.radius = maxf(0.15, s.x * 0.14)
			tr.height = s.y
			cs.shape = tr
			cs.position = Vector3(0, s.y / 2.0, 0)
		"ramp":
			cs.shape = ramp_mesh(s).create_convex_shape()
			cs.position = Vector3(0, s.y / 2.0, 0)
			cs.rotation = RAMP_ROT
		"house":
			var hb := BoxShape3D.new()
			hb.size = Vector3(s.x, s.y * 0.75, s.z)
			cs.shape = hb
			cs.position = Vector3(0, s.y * 0.375, 0)
		"grave":
			var gb := BoxShape3D.new()
			gb.size = Vector3(s.x, s.y, s.z * 0.4)
			cs.shape = gb
			cs.position = Vector3(0, s.y / 2.0, 0)
		"fence":
			var fb := BoxShape3D.new()
			fb.size = Vector3(s.x, s.y, 0.3)
			cs.shape = fb
			cs.position = Vector3(0, s.y / 2.0, 0)
		_:
			var b := BoxShape3D.new()
			b.size = s
			cs.shape = b
			cs.position = Vector3(0, s.y / 2.0, 0)
	return cs


## Little burst of glowing bits (collect, hit, pop). Frees itself.
func burst(parent: Node, pos: Vector3, c: Color, amount := 22, power := 6.0) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = 0.75
	p.mesh = sphere(0.09, 0.18, 6, 3)
	p.material_override = mat(c, "plain", 2.0)
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = power * 0.5
	p.initial_velocity_max = power
	p.gravity = Vector3(0, -12, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var curve := Curve.new()
	curve.add_point(Vector2(0, 1))
	curve.add_point(Vector2(1, 0))
	p.scale_amount_curve = curve
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	p.finished.connect(p.queue_free)
