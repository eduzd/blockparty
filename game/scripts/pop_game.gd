class_name PopGame
extends Node3D
## Pop-Up Panic on the phone: builds the sky-picnic arena, your character, the
## others, the effects, sounds and the game's own HUD pieces, and handles the
## referee's messages. main.gd keeps the shared parts (connection, camera node,
## touch controls, HUD buttons, voice, rotation) and hands the game over to this.

const CAM_PITCH_MIN := -1.15
const CAM_PITCH_MAX := -0.22

var main: Node
var arena: PopArena
var fx: PopFx
var me: PopPlayer
var my_name := "You"
var my_ch := 0
var scores := {}            # id -> knockouts
var phase := "play"
var phase_end := 0.0        # referee ms
var round_no := 1
var bonk_cd := 0.0
var cam_yaw := 0.0
var cam_pitch := -0.62
var shake := 0.0
var fov_kick := 0.0
var _cam_pos := Vector3.ZERO
var _cam_ready := false
var _send_accum := 0.0
var _out_t := 0.0
var _last_safe := Vector3.ZERO
var _predicted := {}        # victim id -> ms when we showed our own guess of a hit
var _shield_until := {}     # id -> local ms (bubble shown after dropping back in)
var _frenzy_announced := false
var _last_tick_s := -1

# HUD
var splash: Label
var _splash_tw: Tween
var leader_pill: Label
var results: PanelContainer
var _results_list: VBoxContainer
var _results_title: Label
var _results_sub: Label

# Sound
var _sfx := {}
var _voices: Array[AudioStreamPlayer] = []
var _next_voice := 0
var music_player: AudioStreamPlayer

# Stats for the self-test
var stats := {"bonks": 0, "hits_confirmed": 0, "kos_seen": 0, "my_falls": 0, "pads": 0, "spooned": 0,
	"bumps": 0, "rounds": 0, "respawns": 0, "hops": 0}


func _init(p_main: Node) -> void:
	main = p_main


func build() -> void:
	arena = PopArena.new()
	add_child(arena)
	arena.build()
	fx = PopFx.new()
	add_child(fx)
	for n in ["boing", "bonk", "pop", "hop", "pad", "ko", "whoosh", "honk", "tick", "go", "fanfare"]:
		var s = load("res://sfx/%s.wav" % n)
		if s:
			_sfx[n] = s
	for i in 8:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_voices.append(p)
	music_player = AudioStreamPlayer.new()
	var m = load("res://sfx/pop_music.wav")
	if m is AudioStreamWAV:
		var w: AudioStreamWAV = m
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(round(w.get_length() * w.mix_rate))
		music_player.stream = w
	music_player.volume_db = -9.0
	add_child(music_player)


## The game's own HUD: a big splash word in the middle, the leader pill (under
## the room info) and the end-of-round results card.
func build_hud(hud_root: Control) -> void:
	leader_pill = UiKit.pill("")
	leader_pill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	leader_pill.visible = false
	main.hud_info_col.add_child(leader_pill)
	splash = Label.new()
	splash.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	splash.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	splash.add_theme_font_override("font", UiKit.font("anton", 400))
	splash.add_theme_font_size_override("font_size", 56)
	splash.add_theme_color_override("font_color", Color.WHITE)
	splash.add_theme_color_override("font_outline_color", UiKit.INK)
	splash.add_theme_constant_override("outline_size", 14)
	splash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	splash.modulate.a = 0.0
	hud_root.add_child(splash)
	# Results card (Sky & Ink card look). Touches pass straight through it.
	results = PanelContainer.new()
	results.mouse_filter = Control.MOUSE_FILTER_IGNORE
	results.add_theme_stylebox_override("panel", UiKit.box(Color(1, 1, 1, 0.94), 20, UiKit.SKY_LIGHT, 1))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	results.add_child(v)
	_results_title = UiKit.label("", "title_large", UiKit.INK, false)
	_results_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_results_title)
	_results_sub = UiKit.label("", "body_medium", Color("#5b6675"), false)
	_results_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_results_sub)
	_results_list = VBoxContainer.new()
	_results_list.add_theme_constant_override("separation", 2)
	_results_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_results_list)
	results.visible = false
	hud_root.add_child(results)


## Positions the game's HUD pieces; called from main's _layout_hud.
func layout_hud(w: float, h: float, center_top: float) -> void:
	if splash:
		splash.size = Vector2(w, 90)
		splash.position = Vector2(0, maxf(center_top + 70.0, h * 0.30))
	if results and results.visible:
		var rw := minf(320.0, w - 32.0)
		results.custom_minimum_size = Vector2(rw, 0)
		results.size = Vector2(rw, 0)
		var rh := results.get_combined_minimum_size().y
		results.position = Vector2((w - rw) / 2.0, clampf(center_top + 52.0, 0.0, maxf(h - rh - 150.0, 0.0)))


# ------------------------------------------------------------------ sound

func play(name: String, pitch_var := 0.08, vol_db := 0.0, at = null) -> void:
	if not _sfx.has(name):
		return
	if at != null and me:
		var d: float = (at as Vector3).distance_to(me.position)
		vol_db -= clampf((d - 4.0) * 0.6, 0.0, 14.0)
	var p := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	p.stream = _sfx[name]
	p.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	p.volume_db = vol_db
	p.play()


func set_music(on: bool) -> void:
	if music_player.stream == null:
		return
	if on and not music_player.playing:
		music_player.play()
	elif not on and music_player.playing:
		music_player.stop()


# ------------------------------------------------------------------ messages

func on_welcome(w: Dictionary) -> void:
	my_name = str(w.get("name", "You"))
	my_ch = int(w.get("ch", 0))
	if me == null:
		me = PopPlayer.new()
		add_child(me)
		me.setup(my_name, my_ch, Protocol.color_for(int(w.get("c", 0))))
		me.hopped.connect(func():
			stats.hops += 1
			play("hop", 0.1, -4.0)
			fx.puff(me.position, 0.4))
		me.landed.connect(func(k: float):
			fx.puff(me.position, k)
			if k > 0.5:
				play("bonk", 0.2, -10.0)
				shake = maxf(shake, 0.12 * k))
		me.padded.connect(func(i: int):
			stats.pads += 1
			arena.jiggle_pad(i)
			play("pad", 0.1, -2.0)
			fov_kick = 8.0
			fx.puff(me.position, 1.0))
		me.spooned.connect(func():
			stats.spooned += 1
			play("boing", 0.15)
			shake = 0.35
			fx.stars(me.position + Vector3(0, 1.4, 0))
			say("SPOONED!", Color("#ffd166")))
		me.fell.connect(_on_fell)
	var spawn = Protocol.parse_vec3(w.get("spawn"))
	me.teleport(spawn if spawn != null else Vector3(0, PopRules.SPAWN_Y, 6))
	_shield_until[-1] = Time.get_ticks_msec() + int(PopRules.SHIELD_S * 1000.0)
	cam_yaw = atan2(me.position.x, me.position.z)   # start looking toward the middle
	_cam_ready = false
	for p in w.get("players", []):
		if p is Dictionary:
			add_remote(p)
	_read_round(w.get("r"))
	_read_scores(w.get("sc"))
	set_music(main.music_on)
	play("go", 0.0, -2.0)
	say("POP-UP PANIC!", Color("#ff5d8f"))
	main._toast("Bonk others off the table. Hop over the spoon!")


func add_remote(p: Dictionary) -> void:
	var id := int(p.get("id", -1))
	if id < 0 or id == main.net.my_id or main.remotes.has(id):
		return
	var pos = Protocol.parse_vec3(p.get("p"))
	var r := PopRemote.new()
	add_child(r)
	r.setup(id, Protocol.sanitize_name(p.get("name")), int(p.get("ch", p.get("c", 0))), Protocol.color_for(int(p.get("c", 0))),
		pos if pos != null else Vector3(0, PopRules.SPAWN_Y, 0), float(p.get("y", 0.0)), bool(p.get("bot", false)))
	main.remotes[id] = r
	scores[id] = int(scores.get(id, 0))


func on_message(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"snap":
			main._sync_clock(msg.get("ts"))
			for entry in msg.get("pl", []):
				if not (entry is Array) or entry.size() != 5:
					continue
				var id := int(entry[0])
				if id == main.net.my_id:
					continue
				if not main.remotes.has(id):
					add_remote({"id": id, "name": "Player", "p": [entry[1], entry[2], entry[3]]})
				var pos = Protocol.parse_vec3([entry[1], entry[2], entry[3]])
				var yaw = Protocol.parse_number(entry[4])
				if pos != null and yaw != null:
					var r: PopRemote = main.remotes[id]
					# Dropped back in from the sky: show the safety bubble.
					if r.position.distance_to(pos) > 6.0 and pos.y > 3.0:
						_shield_until[id] = Time.get_ticks_msec() + int(PopRules.SHIELD_S * 1000.0)
					r.push_state(pos, yaw)
			if msg.has("sc"):
				_read_scores(msg.sc)
		"join":
			if msg.get("p") is Dictionary:
				var p: Dictionary = msg.p
				var id := int(p.get("id", -1))
				if main.remotes.has(id):
					main.remotes[id].queue_free()
					main.remotes.erase(id)
				add_remote(p)
				if not bool(p.get("bot", false)):
					main._toast("%s popped in!" % Protocol.sanitize_name(p.get("name")))
					play("pop", 0.05, -3.0)
		"leave":
			var id := int(msg.get("id", -1))
			if main.remotes.has(id):
				main.remotes[id].queue_free()
				main.remotes.erase(id)
			scores.erase(id)
		"bonk":
			_on_bonk_msg(msg)
		"bump":
			var v = Protocol.parse_vec3(msg.get("v"))
			if v != null and me and not me.out:
				stats.bumps += 1
				me.knock((v as Vector3).limit_length(32.0))
				shake = 0.4
				play("boing", 0.12)
				fx.stars(me.position + Vector3(0, 1.4, 0))
		"ko":
			_on_ko_msg(msg)
		"correct":
			var pos = Protocol.parse_vec3(msg.get("p"))
			if pos != null and me:
				var was_out := me.out
				me.teleport(pos)
				_out_t = 0.0
				_shield_until[-1] = Time.get_ticks_msec() + int(PopRules.SHIELD_S * 1000.0)
				if was_out:
					stats.respawns += 1
					play("whoosh", 0.05, -4.0)
					cam_yaw = atan2(pos.x, pos.z)
		"round":
			_read_round(msg.get("r"))
			if msg.has("sc"):
				_read_scores(msg.sc)
			if phase == "results":
				_show_results(msg.get("names", {}))
			else:
				stats.rounds += 1
				_hide_results()
				for id in scores:
					scores[id] = 0
				_frenzy_announced = false
				play("go", 0.0, -2.0)
				say("ROUND %d. GO!" % round_no, Color("#06d6a0"))


func _read_round(r) -> void:
	if not (r is Dictionary):
		return
	phase = str(r.get("ph", "play"))
	phase_end = float(r.get("end", 0))
	round_no = int(r.get("n", 1))
	if r.has("now"):
		main._sync_clock(r.now)


func _read_scores(sc) -> void:
	if not (sc is Array):
		return
	for e in sc:
		if e is Array and e.size() == 2:
			scores[int(e[0])] = int(e[1])


func _name_of(id: int) -> String:
	if id == main.net.my_id:
		return "You"
	if main.remotes.has(id):
		return main.remotes[id].display_name
	return "Someone"


func _pos_of(id: int):
	if id == main.net.my_id and me:
		return me.position
	if main.remotes.has(id):
		return main.remotes[id].position
	return null


func _on_bonk_msg(msg: Dictionary) -> void:
	var id := int(msg.get("id", -1))
	var now := Time.get_ticks_msec()
	if id != main.net.my_id and main.remotes.has(id):
		var r: PopRemote = main.remotes[id]
		r.ch.facing_yaw = float(msg.get("y", r.ch.facing_yaw))
		r.ch.rotation.y = r.ch.facing_yaw
		r.ch.lunge()
		if (msg.get("hit", []) as Array).is_empty():
			play("hop", 0.2, -12.0, r.position)
	for h in msg.get("hit", []):
		var hid := int(h)
		if id == main.net.my_id:
			stats.hits_confirmed += 1
		if hid == main.net.my_id:
			continue   # the bump message does our own reaction
		if now - int(_predicted.get(hid, 0)) < 600:
			continue   # we already showed it the moment you tapped
		var p = _pos_of(hid)
		if p != null:
			fx.stars(p + Vector3(0, 1.4, 0))
			play("bonk", 0.15, -2.0, p)
			if main.remotes.has(hid):
				main.remotes[hid].ch.hit()


func _on_ko_msg(msg: Dictionary) -> void:
	stats.kos_seen += 1
	var id := int(msg.get("id", -1))
	var by := int(msg.get("by", -1))
	if by >= 0:
		scores[by] = int(msg.get("s", int(scores.get(by, 0)) + 1))
	if id != main.net.my_id:
		var p = _pos_of(id)
		if p != null:
			fx.confetti_pop(Vector3(p.x, maxf(p.y, -3.0), p.z))
			play("ko", 0.1, -6.0, p)
	var text := ""
	if by == main.net.my_id:
		text = "You bonked %s off!" % _name_of(id)
		say("KNOCKOUT!", Color("#ffd166"))
		play("fanfare", 0.0, -8.0)
	elif id == main.net.my_id:
		text = ("%s bonked you off!" % _name_of(by)) if by >= 0 else "You fell off!"
	elif by >= 0:
		text = "%s bonked %s off!" % [_name_of(by), _name_of(id)]
	else:
		text = "%s fell off!" % _name_of(id)
	main._toast(text)


func _on_fell() -> void:
	stats.my_falls += 1
	_out_t = 0.0
	fx.confetti_pop(me.position + Vector3(0, 2.0, 0))
	play("ko", 0.05)
	shake = 0.5
	say("OOPS!", Color("#ff5d8f"))
	# Tell the referee straight away; it drops us back in shortly.
	main.net.send({"t": "state", "p": Protocol.vec_to_array(me.position), "y": snappedf(me.facing_yaw, 0.01)})


# ------------------------------------------------------------------ actions

func on_jump() -> void:
	if me:
		me.jump_pressed = true


## BONK: the head springs out. Aim help turns you to the nearest player in reach.
func on_bonk() -> void:
	if me == null or me.out or bonk_cd > 0.0:
		return
	bonk_cd = PopRules.BONK_COOLDOWN_S
	stats.bonks += 1
	var yaw := me.facing_yaw
	var dir := PopRoom.yaw_dir(yaw)
	var best := -1
	var best_d := INF
	for id in main.remotes:
		var r: PopRemote = main.remotes[id]
		var d := Vector2(r.position.x - me.position.x, r.position.z - me.position.z)
		if absf(r.position.y - me.position.y) > 1.8 or d.length() > PopRules.BONK_RANGE + 0.3:
			continue
		# Prefer whoever is in front, but anyone close enough counts.
		var score := d.length() - (d.normalized().dot(dir) * 1.2 if d.length() > 0.01 else 0.0)
		if score < best_d:
			best_d = score
			best = id
	if best >= 0:
		var tr: PopRemote = main.remotes[best]
		var to := Vector2(tr.position.x - me.position.x, tr.position.z - me.position.z)
		yaw = atan2(-to.x, -to.y)
		me.face(yaw)
		var shielded := Time.get_ticks_msec() < int(_shield_until.get(best, 0))
		if not shielded:
			# Show the hit right away; the referee confirms it a moment later.
			_predicted[best] = Time.get_ticks_msec()
			fx.stars(tr.position + Vector3(0, 1.4, 0))
			tr.ch.hit()
			play("bonk", 0.12)
			shake = maxf(shake, 0.18)
	if best < 0:
		play("boing", 0.2, -8.0)
	me.ch.lunge()
	main.net.send({"t": "bonk", "y": snappedf(wrapf(yaw, -PI, PI), 0.01)})


# ------------------------------------------------------------------ per frame

func time_left() -> float:
	return (phase_end - main.world_t() * 1000.0) / 1000.0


func frenzy() -> float:
	return PopRules.frenzy_amount(time_left(), phase == "play")


func physics(delta: float) -> void:
	if me == null:
		return
	if main.autotest == "":
		me.move_input = main.touch.current_move()
	var others := []
	for r in main.remotes.values():
		if r.visible:
			others.append(r.position)
	me.camera_yaw = cam_yaw
	me.step(delta, main.world_t(), frenzy(), others)
	if not me.out and me.grounded:
		_last_safe = me.position
	if me.out:
		_out_t += delta
		# If the referee's "drop back in" got lost, remind it.
		if _out_t > 4.0:
			_out_t = 2.0
			main.net.send({"t": "state", "p": Protocol.vec_to_array(me.position), "y": 0.0})
		return
	_send_accum += delta
	if _send_accum >= 1.0 / Protocol.SEND_HZ:
		_send_accum = 0.0
		main.net.send({"t": "state", "p": Protocol.vec_to_array(me.position), "y": snappedf(wrapf(me.facing_yaw, -PI, PI), 0.01)})


func frame(delta: float, camera: Camera3D) -> void:
	if me == null:
		return
	var t: float = main.world_t()
	var fz := frenzy()
	bonk_cd = maxf(bonk_cd - delta, 0.0)
	if main.touch:
		main.touch.action_ready = 1.0 - bonk_cd / PopRules.BONK_COOLDOWN_S
	var r_me := Vector2(me.position.x, me.position.z).length()
	arena.update(delta, t, fz, clampf((r_me - (PopRules.ARENA_R - 2.5)) / 2.0, 0.0, 1.0) if not me.out else 0.0)
	# Safety bubbles
	var now := Time.get_ticks_msec()
	me.ch.set_shield(now < int(_shield_until.get(-1, 0)))
	for id in main.remotes:
		main.remotes[id].ch.set_shield(now < int(_shield_until.get(id, 0)))

	# Camera: drag anywhere off the controls to look around.
	var look: Vector2 = main.touch.consume_look() / ScreenUtil.dp(get_viewport())
	cam_yaw -= look.x * 0.012
	cam_pitch = clampf(cam_pitch - look.y * 0.008, CAM_PITCH_MIN, CAM_PITCH_MAX)
	var ease_k := 1.0 - exp(-delta * 6.0)
	fov_kick = lerpf(fov_kick, 0.0, 1.0 - exp(-delta * 3.0))
	camera.fov = lerpf(camera.fov, main.cam_fov_target + fov_kick, ease_k)
	var dist: float = main.cam_dist_target * 1.18
	var focus := me.position
	if me.out:
		focus = Vector3(_last_safe.x * 0.7, 0.0, _last_safe.z * 0.7)
	var pivot := focus + Vector3(0, 1.3, 0)
	var offset := Vector3(0, 0, dist).rotated(Vector3.RIGHT, cam_pitch).rotated(Vector3.UP, cam_yaw)
	var want := pivot + offset
	if not _cam_ready:
		_cam_pos = want
		_cam_ready = true
	_cam_pos = _cam_pos.lerp(want, 1.0 - exp(-delta * 12.0))
	shake = maxf(shake - delta * 1.6, 0.0)
	var jitter := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * shake * shake * 0.6
	camera.global_position = _cam_pos + jitter
	camera.look_at(pivot + jitter * 0.5, Vector3.UP)

	# Timer, countdown beeps, frenzy announcement.
	var left := time_left()
	var txt := ""
	if phase == "play":
		var s := maxi(ceili(left), 0)
		txt = "%d:%02d   ★ %d" % [s / 60, s % 60, int(scores.get(main.net.my_id, 0))]
		if s <= 5 and s >= 1 and s != _last_tick_s:
			play("tick", 0.0, -4.0)
		_last_tick_s = s
		if fz > 0.0 and not _frenzy_announced:
			_frenzy_announced = true
			play("honk", 0.0)
			say("FORK FRENZY!", Color("#ff8f3d"))
			shake = 0.3
	else:
		txt = "Next round in %d" % maxi(ceili(left), 0)
		if _results_sub:
			_results_sub.text = "Next round in %d s" % maxi(ceili(left), 0)
	if main.hud_drop.text != txt:
		main.hud_drop.text = txt
	# Leader pill: who's winning.
	var best_id := -1
	var best_s := 0
	for id in scores:
		if int(scores[id]) > best_s:
			best_s = int(scores[id])
			best_id = id
	var lt := ("Leader: %s  ·  %d" % [_name_of(best_id), best_s]) if best_id >= 0 else ""
	if leader_pill.text != lt:
		leader_pill.text = lt
		leader_pill.visible = lt != ""
		main._layout_hud()


# ------------------------------------------------------------------ HUD bits

## A big word that pops in the middle of the screen and fades.
func say(text: String, col: Color) -> void:
	if splash == null:
		return
	splash.text = text
	splash.add_theme_color_override("font_color", col)
	splash.pivot_offset = splash.size / 2.0
	if _splash_tw:
		_splash_tw.kill()
	splash.scale = Vector2(0.4, 0.4)
	splash.modulate.a = 1.0
	splash.rotation = randf_range(-0.08, 0.08)
	_splash_tw = splash.create_tween()
	_splash_tw.tween_property(splash, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_splash_tw.tween_interval(0.7)
	_splash_tw.tween_property(splash, "modulate:a", 0.0, 0.35)


func _show_results(names) -> void:
	var rows := []
	for id in scores:
		var nm := _name_of(id)
		if nm == "Someone" and names is Dictionary and names.has(str(id)):
			nm = str(names[str(id)])
		rows.append([int(scores[id]), nm, id])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	for c in _results_list.get_children():
		c.queue_free()
	var winner_id: int = rows[0][2] if not rows.is_empty() else -1
	var tie: bool = rows.size() > 1 and rows[0][0] == rows[1][0]
	if rows.is_empty() or rows[0][0] == 0:
		_results_title.text = "No knockouts!"
	elif tie:
		_results_title.text = "It's a tie!"
	elif winner_id == main.net.my_id:
		_results_title.text = "You win!"
	else:
		_results_title.text = "%s wins!" % rows[0][1]
	var medals := [Color("#f4b400"), Color("#9aa5b1"), Color("#c77b30")]
	for i in mini(rows.size(), 6):
		var h := HBoxContainer.new()
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var place := UiKit.label("%d" % (i + 1), "title_medium", medals[i] if i < 3 else Color("#5b6675"), false)
		place.custom_minimum_size.x = 26
		h.add_child(place)
		var nm := UiKit.label(str(rows[i][1]), "body_large", UiKit.INK, false)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.clip_text = true
		h.add_child(nm)
		h.add_child(UiKit.label("%d KO" % rows[i][0], "title_medium", UiKit.SKY_MEDIUM, false))
		_results_list.add_child(h)
	results.visible = true
	results.modulate.a = 0.0
	results.create_tween().tween_property(results, "modulate:a", 1.0, 0.25)
	main._layout_hud()
	play("fanfare", 0.0, -3.0)
	# The winner (if it's not a tie) dances.
	if not tie and winner_id >= 0 and rows[0][0] > 0:
		if winner_id == main.net.my_id and me:
			me.ch.cheer(true)
		elif main.remotes.has(winner_id):
			main.remotes[winner_id].ch.cheer(true)
		var wp = _pos_of(winner_id)
		if wp != null:
			fx.confetti_pop(wp + Vector3(0, 2.5, 0))


func _hide_results() -> void:
	if results:
		results.visible = false
	if me:
		me.ch.cheer(false)
	for r in main.remotes.values():
		r.ch.cheer(false)


## Pieces for main's layout self-check.
func layout_items() -> Dictionary:
	var out := {}
	if leader_pill and leader_pill.visible:
		pass   # inside hud_info_col; checked through it
	if results and results.visible:
		out["results"] = results.get_global_rect()
	return out
