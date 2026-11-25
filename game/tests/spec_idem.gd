extends SceneTree
## 0.8.0 step 2: a saved spec game must come back the same when the server or the
## phone cleans it again (save, load from the database, open in Studio).

func _initialize() -> void:
	var fails := 0
	for f in ["candy_coins.json", "ghost_maze.json", "volcano_race.json", "zombie_graveyard.json", "sumo_shrink.json"]:
		var raw = JSON.parse_string(FileAccess.get_file_as_string("res://tests/specs/" + f))
		var a := PloxSpec.clean(raw, 90)
		a.erase("_notes")
		var b := PloxSpec.clean(JSON.parse_string(JSON.stringify(a)), PloxSpec.MAX_HARD)
		b.erase("_notes")
		var same := JSON.stringify(a) == JSON.stringify(b)
		var probs := PloxSpecCheck.problems(b)
		print("%s: %d entities, %d bytes, re-clean same=%s, problems=%s" % [f, a.entities.size(), JSON.stringify(a).length(), same, str(probs)])
		if not same:
			fails += 1
			var ja := JSON.stringify(a)
			var jb := JSON.stringify(b)
			for i in mini(ja.length(), jb.length()):
				if ja[i] != jb[i]:
					print("  differs at %d: %s | %s" % [i, ja.substr(maxi(0, i - 80), 160), jb.substr(maxi(0, i - 80), 160)])
					break
	print("IDEM DONE fails=%d" % fails)
	quit(1 if fails > 0 else 0)
