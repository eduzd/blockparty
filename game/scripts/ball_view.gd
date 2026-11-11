class_name BallView
extends Node3D
## Draws the referee's magnetic neon balls. No physics runs on the phone:
## positions come only from server snapshots, smoothed between them.
## Balls that explode shrink away quickly (no flashing).

const RENDER_DELAY_MS := 120.0
const NEON := ["#39ff14", "#ff2bd6", "#00e5ff", "#fff200", "#ff6b00", "#b026ff"]

var radii: Array = [1.4, 0.85, 0.5]
var snapshots_received := 0
var _balls := {}        # id -> {node, buf: [[ms, Vector3]]}
var _dying: Array = []  # [{node, t}]
var _meshes := {}       # gen -> SphereMesh
var _mats: Array[StandardMaterial3D] = []


func setup(p_radii: Array) -> void:
	clear()
	if not p_radii.is_empty():
		radii = p_radii
		_meshes.clear()
	if _mats.is_empty():
		for hex in NEON:
			var mat := StandardMaterial3D.new()
			var color := Color(hex)
			mat.albedo_color = color
			mat.emission_enabled = true
			mat.emission = color
			mat.emission_energy_multiplier = 1.2   # steady glow, never flashes
			mat.roughness = 0.35
			_mats.append(mat)


func clear() -> void:
	for id in _balls:
		_balls[id].node.queue_free()
	_balls.clear()


func count() -> int:
	return _balls.size()


func _mesh_for(gen: int) -> SphereMesh:
	if not _meshes.has(gen):
		var r := float(radii[clampi(gen, 0, radii.size() - 1)])
		var sphere := SphereMesh.new()
		sphere.radius = r
		sphere.height = r * 2.0
		sphere.radial_segments = 20 if gen == 0 else 14
		sphere.rings = 10 if gen == 0 else 7
		_meshes[gen] = sphere
	return _meshes[gen]


## flat: [id, x, y, z, gen, ...]
func push_state(flat: Array) -> void:
	if flat.size() % 5 != 0 or flat.size() > 5 * 64:
		return
	var now := float(Time.get_ticks_msec())
	var seen := {}
	for k in range(0, flat.size(), 5):
		var id = Protocol.parse_number(flat[k])
		var pos = Protocol.parse_vec3([flat[k + 1], flat[k + 2], flat[k + 3]])
		var gen = Protocol.parse_number(flat[k + 4])
		if id == null or pos == null or gen == null:
			continue
		var key := int(id)
		seen[key] = true
		if not _balls.has(key):
			var node := MeshInstance3D.new()
			node.mesh = _mesh_for(int(gen))
			node.material_override = _mats[posmod(key, _mats.size())]
			node.position = pos
			add_child(node)
			_balls[key] = {"node": node, "buf": []}
		var buf: Array = _balls[key].buf
		buf.append([now, pos])
		if buf.size() > 12:
			buf.pop_front()
	for key in _balls.keys():
		if not seen.has(key):
			_dying.append({"node": _balls[key].node, "t": 0.0})
			_balls.erase(key)
	snapshots_received += 1


func _process(delta: float) -> void:
	var render_t := float(Time.get_ticks_msec()) - RENDER_DELAY_MS
	for key in _balls:
		var buf: Array = _balls[key].buf
		while buf.size() > 2 and buf[1][0] <= render_t:
			buf.pop_front()
		var node: MeshInstance3D = _balls[key].node
		if buf.size() >= 2:
			var w := clampf((render_t - buf[0][0]) / maxf(buf[1][0] - buf[0][0], 1.0), 0.0, 1.0)
			node.position = (buf[0][1] as Vector3).lerp(buf[1][1], w)
		elif buf.size() == 1:
			node.position = buf[0][1]
	for i in range(_dying.size() - 1, -1, -1):
		var d: Dictionary = _dying[i]
		d.t += delta
		var s: float = 1.0 - d.t / 0.18
		if s <= 0.0:
			d.node.queue_free()
			_dying.remove_at(i)
		else:
			d.node.scale = Vector3.ONE * s


func current_positions() -> Array:
	var out := []
	for key in _balls:
		out.append(_balls[key].node.position)
	return out
