class_name PulseWalls
extends MultiMeshInstance3D
## Arena walls made of tall panels that pulse and bend with the music.
## Shape and height react to the spectrum; colours stay steady (no flashing).

const PER_SIDE := 20
const PANEL_W := 3.7

var music: Music
var clock := Callable()
var _levels := PackedFloat32Array()
var _bases: Array[Transform3D] = []


func _ready() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(PANEL_W, 1.0, 0.4)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.6
	box.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box
	mm.instance_count = PER_SIDE * 4
	multimesh = mm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_levels.resize(PER_SIDE)
	var edge := Protocol.WORLD_HALF + 0.9
	var palette := [UiKit.SKY, UiKit.SKY_MEDIUM, UiKit.SKY_LIGHT, UiKit.PINK]
	for side in range(4):
		for i in range(PER_SIDE):
			var along := -Protocol.WORLD_HALF + (i + 0.5) * (Protocol.WORLD_HALF * 2.0 / PER_SIDE)
			var basis := Basis(Vector3.UP, side * PI / 2.0)
			var pos := basis * Vector3(along, 0, -edge)
			_bases.append(Transform3D(basis, pos))
			var col: Color = palette[(i + side) % palette.size()]
			mm.set_instance_color(side * PER_SIDE + i, col)


func _process(delta: float) -> void:
	var t: float = clock.call() if clock.is_valid() else Time.get_ticks_msec() / 1000.0
	var bass := music.band_energy(30.0, 160.0) if music else 0.0
	for i in range(PER_SIDE):
		# Log-spaced bands, mirrored so both ends of a wall answer the bass
		var k := absf(float(i) - (PER_SIDE - 1) / 2.0) / ((PER_SIDE - 1) / 2.0)
		var lo := 40.0 * pow(150.0, k)
		var target := music.band_energy(lo, lo * 1.6) if music else 0.0
		var speed := 18.0 if target > _levels[i] else 4.0   # fast rise, slow fall
		_levels[i] = lerpf(_levels[i], target, minf(delta * speed, 1.0))
	var beat := BeatClock.beat_phase(t)
	for side in range(4):
		for i in range(PER_SIDE):
			var lvl := _levels[i]
			var h := 2.0 + lvl * 11.0
			var lean := sin(i * 0.55 + side + beat * TAU) * 0.22 * bass
			var twist := sin(i * 0.9 - beat * TAU) * 0.15 * lvl
			var base: Transform3D = _bases[side * PER_SIDE + i]
			var b := base.basis * Basis(Vector3.RIGHT, lean) * Basis(Vector3.UP, twist)
			b = b.scaled_local(Vector3(1.0 - lvl * 0.25, h, 1.0 + lvl * 1.5))
			multimesh.set_instance_transform(side * PER_SIDE + i, Transform3D(b, base.origin + base.basis * Vector3(0, h / 2.0, 0)))


func max_level() -> float:
	var m := 0.0
	for v in _levels:
		m = maxf(m, v)
	return m
