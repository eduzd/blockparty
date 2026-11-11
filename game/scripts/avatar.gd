class_name Avatar
extends Node3D
## Blocky character model with a floating name tag. Origin is at the feet.

var _legs: Array[Node3D] = []
var _arms: Array[Node3D] = []
var _walk_phase := 0.0
var _label: Label3D


func setup(display_name: String, color: Color) -> void:
	var skin := Color("#ffd9b3")
	var pants := Color("#33415c")
	_part(Vector3(0, 1.15, 0), Vector3(0.8, 0.8, 0.45), color)          # torso
	_part(Vector3(0, 1.82, 0), Vector3(0.5, 0.5, 0.5), skin)            # head
	_part(Vector3(-0.1, 1.86, -0.26), Vector3(0.08, 0.08, 0.02), Color.BLACK)  # eyes
	_part(Vector3(0.1, 1.86, -0.26), Vector3(0.08, 0.08, 0.02), Color.BLACK)
	for side in [-1.0, 1.0]:
		var leg := Node3D.new()
		leg.position = Vector3(0.2 * side, 0.75, 0)
		add_child(leg)
		_part(Vector3(0, -0.375, 0), Vector3(0.36, 0.75, 0.4), pants, leg)
		_legs.append(leg)
		var arm := Node3D.new()
		arm.position = Vector3(0.55 * side, 1.5, 0)
		add_child(arm)
		_part(Vector3(0, -0.35, 0), Vector3(0.28, 0.75, 0.35), color.lightened(0.15), arm)
		_arms.append(arm)
	_label = Label3D.new()
	_label.text = display_name
	_label.position = Vector3(0, 2.45, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 48
	_label.outline_size = 12
	_label.pixel_size = 0.006
	_label.no_depth_test = true
	add_child(_label)


## speed: horizontal speed in m/s, used for the walk swing.
func animate(delta: float, speed: float) -> void:
	var amount := clampf(speed / Protocol.MOVE_SPEED, 0.0, 1.0)
	if amount > 0.05:
		_walk_phase += delta * 10.0
	else:
		_walk_phase = lerpf(_walk_phase, roundf(_walk_phase / PI) * PI, delta * 10.0)
	var swing := sin(_walk_phase) * 0.7 * amount
	for i in range(2):
		var s := swing if i == 0 else -swing
		_legs[i].rotation.x = s
		_arms[i].rotation.x = -s


func _part(pos: Vector3, size: Vector3, color: Color, parent: Node3D = null) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.8
	mesh.material_override = mat
	mesh.position = pos
	(parent if parent else self).add_child(mesh)
