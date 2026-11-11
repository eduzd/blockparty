class_name WorldBuilder
extends RefCounted
## The shared arena: trampoline floor, glass ceiling, and coloured blocks that
## fold like origami. The blocks fold (or unfold) on every beat drop, at the
## same instant gravity flips (see BeatClock). Pure function of the referee's
## clock, so every phone and the referee compute exactly the same shapes.

const FOLD_MAX_ANGLE := 0.45    # radians (about 26 degrees)
const FOLD_LIFT := 0.4          # metres of slow rise and fall between drops


## Blocks: [center, size, color, hinge side (-1 or 1), hinge axis ("x" or "z")]
static func solids() -> Array:
	var list := []
	var step_colors := [Color("#ff5a5f"), Color("#ff8c42"), Color("#ffd23f"), Color("#3ddc97"), Color("#2b6cff"), Color("#a259ff")]
	for i in range(6):   # staircase, every step is jumpable
		var h := 0.8 * (i + 1)
		list.append([Vector3(-8 + i * 3.2, h / 2.0, -6 - i * 1.5), Vector3(3, h, 3), step_colors[i], 1 if i % 2 == 0 else -1, "z" if i % 3 else "x"])
	list.append([Vector3(12, 2.4, -16), Vector3(6, 4.8, 6), Color("#00c2d1"), 1, "x"])
	list.append([Vector3(10, 0.5, 8), Vector3(2, 1, 2), Color("#f15bb5"), -1, "z"])
	list.append([Vector3(-12, 0.75, 10), Vector3(4, 1.5, 2), Color("#ffd23f"), 1, "z"])
	list.append([Vector3(-18, 1.0, -2), Vector3(3, 2, 3), Color("#2b6cff"), -1, "x"])
	list.append([Vector3(18, 0.6, 2), Vector3(5, 1.2, 5), Color("#ff8c42"), 1, "x"])
	return list


## Where block i is at world time t (seconds on the referee's clock).
static func solid_transform(solid: Array, index: int, t: float) -> Transform3D:
	var center: Vector3 = solid[0]
	var size: Vector3 = solid[1]
	var side := float(solid[3])
	var phase := float(index) * 0.9
	var fold := BeatClock.fold_amount(t)                                # snaps on the drop
	var lift := sin(TAU * t / (BeatClock.BAR * 4.0) + phase) * FOLD_LIFT
	var axis := Vector3.FORWARD if solid[4] == "z" else Vector3.RIGHT
	# Hinge along the bottom edge on one side, like a paper flap.
	var hinge := Vector3(side * size.x / 2.0, -size.y / 2.0, 0) if solid[4] == "z" else Vector3(0, -size.y / 2.0, side * size.z / 2.0)
	var angle := fold * FOLD_MAX_ANGLE * (side if solid[4] == "z" else -side)
	var rot := Basis(axis, angle)
	var origin := center + Vector3(0, lift, 0) + hinge - rot * hinge
	return Transform3D(rot, origin)


static func build(parent: Node3D) -> FoldingBlocks:
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#3a7bd5")
	sky_mat.sky_horizon_color = Color("#bfe3ff")
	sky_mat.ground_horizon_color = Color("#bfe3ff")
	sky.sky_material = sky_mat
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.8
	env.environment = environment
	parent.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	parent.add_child(sun)

	# Trampoline floor (springy look: dark mat with a lighter border)
	_static_box(parent, Vector3(0, -0.5, 0), Vector3(80, 1, 80), Color("#1f2a44"))
	_static_box(parent, Vector3(0, 0.01, 0), Vector3(76, 0.02, 76), Color("#26335a"))
	# Safe spawn pad (solid, does not bounce)
	_static_box(parent, Vector3(0, 0.25, 6), Vector3(6, 0.5, 6), Color("#f2f2f2"))
	# Glass ceiling
	var ceiling := _static_box(parent, Vector3(0, Protocol.CEILING_Y + 0.5, 0), Vector3(80, 1, 80), Color(0.75, 0.9, 1.0, 0.18))
	var mat: StandardMaterial3D = (ceiling.get_child(1) as MeshInstance3D).material_override
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	(ceiling.get_child(1) as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Invisible walls up to the ceiling
	var half := Protocol.WORLD_HALF + 0.5
	var h := Protocol.CEILING_Y + 1.0
	for wall in [
		[Vector3(0, h / 2, -half), Vector3(80, h, 1)], [Vector3(0, h / 2, half), Vector3(80, h, 1)],
		[Vector3(-half, h / 2, 0), Vector3(1, h, 80)], [Vector3(half, h / 2, 0), Vector3(1, h, 80)]]:
		var body := StaticBody3D.new()
		body.position = wall[0]
		body.add_child(_shape(wall[1]))
		parent.add_child(body)

	var blocks := FoldingBlocks.new()
	parent.add_child(blocks)
	blocks.setup(solids())
	return blocks


static func _shape(size: Vector3) -> CollisionShape3D:
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	return shape


static func box_mesh(size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	mesh.material_override = mat
	return mesh


static func _static_box(parent: Node3D, center: Vector3, size: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = center
	body.add_child(_shape(size))
	body.add_child(box_mesh(size, color))
	parent.add_child(body)
	return body
