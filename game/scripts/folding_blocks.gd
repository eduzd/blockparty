class_name FoldingBlocks
extends Node3D
## Moves the origami blocks every physics frame from the shared world clock.
## AnimatableBody3D carries players standing on a block as it folds.

var clock := Callable()   # returns the referee's time in seconds
var _solids: Array = []
var _bodies: Array[AnimatableBody3D] = []


func setup(solids: Array) -> void:
	_solids = solids
	for i in range(solids.size()):
		var s: Array = solids[i]
		var body := AnimatableBody3D.new()
		body.sync_to_physics = true
		body.add_child(WorldBuilder._shape(s[1]))
		body.add_child(WorldBuilder.box_mesh(s[1], s[2]))
		add_child(body)
		body.transform = WorldBuilder.solid_transform(s, i, 0.0)
		_bodies.append(body)


func _physics_process(_delta: float) -> void:
	if not clock.is_valid():
		return
	var t: float = clock.call()
	for i in range(_bodies.size()):
		_bodies[i].transform = WorldBuilder.solid_transform(_solids[i], i, t)
