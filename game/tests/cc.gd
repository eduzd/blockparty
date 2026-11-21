extends SceneTree
func _init():
	for p in ["res://scripts/plox_spec.gd","res://scripts/plox_spec_check.gd","res://scripts/plox_spec_ai.gd","res://scripts/spec_props.gd","res://scripts/local_player.gd","res://scripts/touch_controls.gd","res://scripts/spec_play.gd"]:
		var s = load(p)
		print("LOAD ", p, " -> ", s != null and s.can_instantiate())
	var lv = {"title":"t","sky":1,"parts":[["block",0,0,0,6,1,6,0,0],["coin",0,2,-5,1,1,1,0,0],["mover",0,2,-8,3,1,3,0,0]],"spawn":[0,1.5,0],"goal":[0,1,-20]}
	var s = PloxSpec.from_level(lv)
	print("SUMMARY ", PloxSpec.summary(s))
	var pr = SpecProps.new()
	var n = Node3D.new()
	for sh in PloxSpec.SHAPES:
		pr.build(n, sh, Vector3(2,2,2), Color.RED, "plain", true)
		pr.shape_for(sh, Vector3(2,2,2))
	print("PROPS ", n.get_child_count())
	n.free()
	quit()
