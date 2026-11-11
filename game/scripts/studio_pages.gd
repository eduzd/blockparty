class_name StudioPages
extends RefCounted
## 0.7.0 Studio: describe a game in words, the AI (or the built-in quick builder) makes
## it, you play it at once, change it in words or by hand, and publish it for friends.
## Plus the community games list on the Games tab.

var s: AppShell
var level := {}          # the level open in the editor
var gid := ""            # its id once saved
var status := "draft"
var sel := -1            # selected part in the map
var undo := []
var busy := ""           # "ai", "save", "publish", "load"
var mine := []
var mine_loaded := false
var games := []
var games_sort := "popular"
var games_loaded := false
var prompt_text := ""
var change_text := ""
var note := ""          # last message from the builder
var ai_left := -1
var _open_after_ai := false
var _play_after_load := false
var _map: StudioMap
var _games_asked := -10000

const EXAMPLES := ["A lava obby with jump pads", "An ice tower up to the sky", "A candy course full of stars",
	"Spinning hammers at night", "An easy course for little kids", "A long, hard parkour race"]
const CHANGES := ["Make it harder", "Add lava", "Add stars", "Add jump pads", "Make it night",
	"Add moving platforms", "Add checkpoints", "Make it easier", "Add hammers", "Make it icy"]


func _init(shell: AppShell) -> void:
	s = shell
	s.social.reply.connect(_on_reply)


func _on_reply(t: String, msg: Dictionary) -> void:
	match t:
		"s_ai_res":
			if busy != "ai":
				return
			busy = ""
			if msg.get("ok", false):
				_remember()
				level = PloxLevel.clean(msg.get("level"), PloxLevel.MAX_PARTS_HARD)
				sel = -1
				ai_left = int(msg.get("left", -1))
				note = str(msg.get("why", ""))
				if note == "":
					note = "Built by the quick builder." if msg.get("quick", false) else "Built by the AI."
				change_text = ""
				if _open_after_ai:
					_open_after_ai = false
					gid = ""
					status = "draft"
					undo.clear()
					s.push({"k": "studio_edit"})
					# Play it right away, like the user asked.
					play_current()
					return
			else:
				_open_after_ai = false
				s._toast(str(msg.get("why", "Couldn't build that.")))
			s._mark_dirty()
		"s_studio_mine_res":
			mine = msg.get("games", [])
			mine_loaded = true
			s._mark_dirty()
		"s_games_res":
			games = msg.get("games", [])
			games_loaded = true
			s._mark_dirty()
		"s_studio_save_res":
			var was := busy
			busy = ""
			if msg.has("gid"):
				gid = str(msg.gid)
			if msg.get("ok", false):
				if msg.get("game") is Dictionary:
					status = str(msg.game.get("status", status))
				if was == "publish":
					var got := int(msg.get("got", 0))
					s._toast("Published! Friends can play it now." + (" +%d Plux" % got if got > 0 else ""))
				else:
					s._toast("Saved")
				s.social.request({"t": "s_studio_mine"})
			else:
				s._toast(str(msg.get("why", "Couldn't save.")))
			s._mark_dirty()
		"s_studio_delete_res":
			s.social.request({"t": "s_studio_mine"})
		"s_game_res":
			if busy != "load":
				return
			busy = ""
			if not msg.get("ok", false):
				s._toast("That game isn't available.")
				s._mark_dirty()
				return
			var card: Dictionary = msg.get("game", {})
			var lv := PloxLevel.clean(msg.get("level"), PloxLevel.MAX_PARTS_HARD)
			if str(card.get("owner", "")) == s.social.uid and not _play_after_load:
				level = lv
				gid = str(card.gid)
				status = str(card.get("status", "draft"))
				sel = -1
				undo.clear()
				note = ""
				s.push({"k": "studio_edit"})
			else:
				_play_after_load = false
				s.social.request({"t": "s_game_played", "gid": str(card.gid)})
				s.main.play_studio(lv, str(card.get("title", "Game")), false, str(card.gid))
		"s_game_like_res":
			for g in games:
				if str(g.gid) == str(msg.gid):
					g["liked"] = msg.get("liked", false)
					g["likes"] = int(msg.get("likes", 0))
			s._mark_dirty()
		"s_game_done_res":
			if int(msg.get("got", 0)) > 0:
				s._toast("+%d Plux for finishing!" % int(msg.got))


func _remember() -> void:
	if not level.is_empty():
		undo.append(level.duplicate(true))
		if undo.size() > 20:
			undo.pop_front()


func _ask(msg: Dictionary, what: String) -> bool:
	if not s.social.request(msg):
		s._offline_toast()
		return false
	busy = what
	s._mark_dirty()
	return true


func build_from_words(text: String) -> void:
	text = text.strip_edges()
	if text.length() < 4:
		s._toast("Describe your game in a few words first.")
		return
	prompt_text = text
	if not s.social.is_online():
		# Offline: the phone builds it with the quick builder.
		level = PloxLevel.quick_build(text)
		gid = ""
		status = "draft"
		undo.clear()
		note = "Built on your phone (offline)."
		s.push({"k": "studio_edit"})
		play_current()
		return
	_open_after_ai = true
	_ask({"t": "s_ai_build", "prompt": text}, "ai")


func change_with_words(text: String) -> void:
	text = text.strip_edges()
	if text.length() < 3:
		return
	change_text = text
	if not s.social.is_online():
		_remember()
		level = PloxLevel.quick_build(text, level)
		note = "Changed on your phone (offline)."
		change_text = ""
		s._mark_dirty()
		return
	_ask({"t": "s_ai_build", "prompt": text, "base": level}, "ai")


func play_current() -> void:
	var problem := PloxLevel.check(level)
	if problem != "":
		s._toast(problem)
		return
	s.main.play_studio(level, str(level.title), true, "")


func _save(publish: bool) -> void:
	var m := {"t": "s_studio_publish" if publish else "s_studio_save", "level": level}
	if gid != "":
		m["gid"] = gid
	_ask(m, "publish" if publish else "save")


# ---------------------------------------------------------------- Studio start
func studio_screen() -> Control:
	var page := UiKit.pinned_page("Studio", s.pop)
	var content: VBoxContainer = page[1]
	s.social.request({"t": "s_studio_mine"})
	content.add_child(UiKit.margin(UiKit.label("Make a game", "headline_small", UiKit.c("on_surface"), false), 20, 12, 20, 0))
	content.add_child(UiKit.margin(UiKit.label("Say what you want. Studio builds it, then you play it straight away.",
		"body_medium", UiKit.c("on_surface_variant")), 20, 4, 20, 12))
	var f: Array = UiKit.text_field("A lava obby with jump pads...", prompt_text, 300)
	var e: LineEdit = f[1]
	e.text_changed.connect(func(t): prompt_text = t)
	e.text_submitted.connect(func(t): build_from_words(t))
	content.add_child(f[0])
	var live := UiKit.vbox()
	content.add_child(live)
	s._live(live, func(box: VBoxContainer):
		var go := UiKit.primary_button("Building your game..." if busy == "ai" else "Build my game", "sparkles", func(): build_from_words(e.text))
		go.disabled = busy != ""
		box.add_child(UiKit.margin(go, 16, 12, 16, 0))
		box.add_child(UiKit.margin(UiKit.label("Try one of these", "title_small", UiKit.c("on_surface"), false), 20, 16, 20, 6))
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 8)
		flow.add_theme_constant_override("v_separation", 8)
		for ex in EXAMPLES:
			var t: String = ex
			flow.add_child(UiKit.chip(t, false, func():
				e.text = t
				prompt_text = t))
		box.add_child(UiKit.margin(flow, 16, 0, 16, 0))
		box.add_child(UiKit.margin(UiKit.outline_button("Start from a blank level", "pencil-square", func():
			level = PloxLevel.blank("My game")
			gid = ""
			status = "draft"
			undo.clear()
			note = ""
			s.push({"k": "studio_edit"})), 16, 16, 16, 0))
		box.add_child(UiKit.section_title("Your games"))
		if not mine_loaded:
			box.add_child(UiKit.margin(UiKit.label("Loading...", "body_medium", UiKit.c("on_surface_variant")), 20, 0, 20, 0))
		elif mine.is_empty():
			box.add_child(UiKit.margin(UiKit.empty_state("cube", "No games yet", "Your saved and published games show up here."), 16, 0, 16, 0))
		else:
			var card: Array = UiKit.card()
			box.add_child(card[0])
			for g in mine:
				var id := str(g.gid)
				var st: String = {"pub": "Published", "hidden": "Hidden by a moderator", "removed": "Removed"}.get(str(g.status), "Draft")
				card[1].add_child(UiKit.setting_row("cube", str(g.title), "%s  ·  %d plays  ·  %d likes" % [st, int(g.plays), int(g.likes)], "",
					UiKit.SKY_MEDIUM, func(): _ask({"t": "s_studio_get", "gid": id}, "load")))
		box.add_child(UiKit.end_padding()))
	return page[0]


# ---------------------------------------------------------------- editor
func edit_screen() -> Control:
	if level.is_empty():
		level = PloxLevel.blank()
	var page := UiKit.pinned_page("Edit game", s.pop)
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	s._live(live, func(box: VBoxContainer): _fill_editor(box))
	return page[0]


func _flow() -> HFlowContainer:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 8)
	return flow


func _fill_editor(box: VBoxContainer) -> void:
	var head := UiKit.hbox(8)
	var tf: Array = UiKit.text_field("Game name", str(level.title), PloxLevel.MAX_TITLE)
	var te: LineEdit = tf[1]
	te.text_changed.connect(func(t): level.title = PloxLevel.clean_title(t))
	tf[0].size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(tf[0])
	box.add_child(UiKit.margin(head, 0, 8, 0, 0))
	var play := UiKit.primary_button("Play it now", "play", play_current)
	box.add_child(UiKit.margin(play, 16, 12, 16, 0))
	if note != "":
		box.add_child(UiKit.margin(UiKit.label(note, "body_small", UiKit.c("on_surface_variant")), 20, 6, 20, 0))

	# Change it in words
	box.add_child(UiKit.section_title("Change it with words"))
	var cf: Array = UiKit.text_field("Make it harder, add lava...", change_text, 300)
	var ce: LineEdit = cf[1]
	ce.text_changed.connect(func(t): change_text = t)
	ce.text_submitted.connect(func(t): change_with_words(t))
	box.add_child(cf[0])
	var apply := UiKit.primary_button("Changing it..." if busy == "ai" else "Change it", "sparkles", func(): change_with_words(ce.text))
	apply.disabled = busy != ""
	box.add_child(UiKit.margin(apply, 16, 10, 16, 0))
	var flow := _flow()
	for c in CHANGES:
		var t: String = c
		var chip := UiKit.chip(t, false, func(): change_with_words(t))
		chip.disabled = busy != ""
		flow.add_child(chip)
	box.add_child(UiKit.margin(flow, 16, 10, 16, 0))
	if ai_left >= 0:
		box.add_child(UiKit.margin(UiKit.label("%d AI builds left today" % ai_left, "body_small", UiKit.c("on_surface_variant")), 20, 6, 20, 0))

	# By hand
	box.add_child(UiKit.section_title("Change it by hand"))
	box.add_child(UiKit.margin(UiKit.label("Tap a part to pick it, drag to move it. Green is the start, gold is the finish.",
		"body_small", UiKit.c("on_surface_variant")), 20, 0, 20, 8))
	_map = StudioMap.new()
	box.add_child(UiKit.margin(_map, 16, 0, 16, 0))
	_map.set_level(level, sel)
	_map.picked.connect(func(i):
		sel = i
		s._mark_dirty())
	_map.changed.connect(func():
		_settle_markers()
		s._mark_dirty())
	var tools := _flow()
	if sel >= 0 and sel < level.parts.size():
		var p: Array = level.parts[sel]
		box.add_child(UiKit.margin(UiKit.label("Picked: %s" % PloxLevel.KIND_NAMES.get(str(p[0]), str(p[0])), "title_small", UiKit.c("on_surface"), false), 20, 10, 20, 4))
		for b in [["Bigger", func(): _edit(func(q): q[4] = minf(PloxLevel.MAX_SIZE, q[4] * 1.25); q[6] = minf(PloxLevel.MAX_SIZE, q[6] * 1.25))],
				["Smaller", func(): _edit(func(q): q[4] = maxf(PloxLevel.MIN_SIZE, q[4] * 0.8); q[6] = maxf(PloxLevel.MIN_SIZE, q[6] * 0.8))],
				["Raise", func(): _edit(func(q): q[2] = minf(PloxLevel.TOP, q[2] + 1.0))],
				["Lower", func(): _edit(func(q): q[2] = maxf(-10.0, q[2] - 1.0))],
				["Turn", func(): _edit(func(q): q[7] = fmod(q[7] + 45.0, 360.0))],
				["Colour", func(): _edit(func(q): q[8] = (int(q[8]) + 1) % PloxLevel.COLORS.size())],
				["Type", func(): _edit(func(q):
					var k := PloxLevel.KINDS.find(str(q[0]))
					q[0] = PloxLevel.KINDS[(k + 1) % PloxLevel.KINDS.size()])],
				["Copy", func(): _duplicate()],
				["Delete", func(): _delete()]]:
			tools.add_child(UiKit.chip(b[0], false, b[1]))
		box.add_child(UiKit.margin(tools, 16, 0, 16, 0))
	else:
		box.add_child(UiKit.margin(UiKit.label("Add a part", "title_small", UiKit.c("on_surface"), false), 20, 10, 20, 4))
		for k in PloxLevel.KINDS:
			var kind: String = k
			tools.add_child(UiKit.chip("+ " + str(PloxLevel.KIND_NAMES[kind]), false, func(): _add(kind)))
		box.add_child(UiKit.margin(tools, 16, 0, 16, 0))
	var row := _flow()
	var undo_chip := UiKit.chip("Undo", false, func():
		if not undo.is_empty():
			level = undo.pop_back()
			sel = -1
			s._mark_dirty())
	undo_chip.disabled = undo.is_empty()
	row.add_child(undo_chip)
	for i in PloxLevel.SKIES.size():
		var si := i
		row.add_child(UiKit.chip(PloxLevel.SKIES[i], int(level.sky) == i, func():
			level.sky = si
			s._mark_dirty()))
	box.add_child(UiKit.margin(row, 16, 12, 16, 0))
	box.add_child(UiKit.margin(UiKit.label("%d of %d parts" % [level.parts.size(), int(s.social.cfg.get("studio_max_parts", 160))],
		"body_small", UiKit.c("on_surface_variant")), 20, 6, 20, 0))

	# Save and publish
	box.add_child(UiKit.section_title("Share"))
	var st := "Published: friends and everyone on Plux can play it." if status == "pub" else ("Hidden by a moderator." if status == "hidden" else "Not published yet.")
	box.add_child(UiKit.margin(UiKit.label(st, "body_medium", UiKit.c("on_surface_variant")), 20, 0, 20, 8))
	var save := UiKit.outline_button("Saving..." if busy == "save" else "Save", "check", func(): _save(false))
	save.disabled = busy != ""
	box.add_child(UiKit.margin(save, 16, 4, 16, 0))
	var pub := UiKit.primary_button("Publishing..." if busy == "publish" else ("Update published game" if status == "pub" else "Publish for friends"), "globe-alt", func(): _save(true))
	pub.disabled = busy != ""
	box.add_child(UiKit.margin(pub, 16, 10, 16, 0))
	if gid != "":
		var id := gid
		box.add_child(UiKit.margin(UiKit.outline_button("Delete game", "trash", func():
			s.social.request({"t": "s_studio_delete", "gid": id})
			gid = ""
			s._toast("Game deleted")
			s.pop()), 16, 10, 16, 0))
	box.add_child(UiKit.end_padding())


func _edit(fn: Callable) -> void:
	if sel < 0 or sel >= level.parts.size():
		return
	_remember()
	fn.call(level.parts[sel])
	level.parts[sel] = PloxLevel.clean_part(level.parts[sel])
	_settle_markers()
	s._mark_dirty()


func _duplicate() -> void:
	if sel < 0 or level.parts.size() >= PloxLevel.MAX_PARTS_HARD:
		return
	_remember()
	var p: Array = level.parts[sel].duplicate()
	p[3] = clampf(p[3] - (p[6] + 2.0), -PloxLevel.HALF, PloxLevel.HALF)
	level.parts.append(p)
	sel = level.parts.size() - 1
	s._mark_dirty()


func _delete() -> void:
	if sel < 0:
		return
	_remember()
	level.parts.remove_at(sel)
	sel = -1
	s._mark_dirty()


func _add(kind: String) -> void:
	if level.parts.size() >= PloxLevel.MAX_PARTS_HARD:
		s._toast("That's the most parts a game can have.")
		return
	_remember()
	# New parts go just past the finish, so the course grows forward.
	var g: Array = level.goal
	var sz := PloxLevel.default_size(kind)
	var y: float = g[1] - 1.0 - sz.y / 2.0
	if kind == "coin":
		y = g[1] + 0.5
	var p := [kind, g[0], y, clampf(g[2] - 5.0, -PloxLevel.HALF, PloxLevel.HALF), sz.x, sz.y, sz.z, 0.0, PloxLevel.default_color(kind)]
	level.parts.append(PloxLevel.clean_part(p))
	sel = level.parts.size() - 1
	s._mark_dirty()


## After a drag, the start and finish sit on top of whatever is under them.
func _settle_markers() -> void:
	for key in ["spawn", "goal"]:
		var m: Array = level[key]
		var best := -1e9
		for p in level.parts:
			if str(p[0]) in ["lava", "coin", "spinner"]:
				continue
			var local := (Vector2(m[0], m[2]) - Vector2(p[1], p[3])).rotated(deg_to_rad(float(p[7])))
			if absf(local.x) <= p[4] / 2.0 and absf(local.y) <= p[6] / 2.0:
				best = maxf(best, p[2] + p[5] / 2.0)
		if best > -1e8:
			m[1] = best + 1.0


# ---------------------------------------------------------------- Games tab
## Community games, for the Games tab: Popular, New, Friends, with Play and Like.
func discover_section(content: VBoxContainer) -> void:
	content.add_child(UiKit.section_title("Made on Plux"))
	if not games_loaded and Time.get_ticks_msec() - _games_asked > 5000:
		_games_asked = Time.get_ticks_msec()
		s.social.request({"t": "s_games", "sort": games_sort})
	var sorts := _flow()
	for pair in [["popular", "Popular"], ["new", "New"], ["friends", "Friends"]]:
		var key: String = pair[0]
		sorts.add_child(UiKit.chip(pair[1], games_sort == key, func():
			games_sort = key
			games_loaded = false
			games = []
			s.social.request({"t": "s_games", "sort": key})
			s._mark_dirty()))
	content.add_child(UiKit.margin(sorts, 16, 0, 16, 8))
	if games.is_empty():
		var sub := "Loading..." if not games_loaded else ("Nothing from friends yet. Make the first one!" if games_sort == "friends" else "No games yet. Be the first to make one!")
		content.add_child(UiKit.margin(UiKit.empty_state("cube", "Community games", sub, UiKit.small_button("Create", true, func(): s.push({"k": "studio"}), "plus")), 16, 0, 16, 0))
		return
	var card: Array = UiKit.card()
	content.add_child(card[0])
	for g in games.slice(0, 30):
		var id := str(g.gid)
		var h := UiKit.hbox(10)
		var col := UiKit.vbox(0)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var title := str(g.title) + ("  ★" if g.get("featured", false) else "")
		col.add_child(UiKit.label(title, "title_small", UiKit.c("on_surface"), false))
		col.add_child(UiKit.label("by %s  ·  %d plays  ·  %d likes" % [str(g.get("owner_name", "")), int(g.plays), int(g.likes)], "body_small", UiKit.c("on_surface_variant"), false))
		h.add_child(col)
		var liked := bool(g.get("liked", false))
		var like := UiKit.small_button("Liked" if liked else "Like", liked, func(): s.social.request({"t": "s_game_like", "gid": id, "on": not liked}), "heart")
		like.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(like)
		var play := UiKit.small_button("Play", true, func():
			_play_after_load = true
			_ask({"t": "s_game_get", "gid": id}, "load"), "play")
		play.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(play)
		card[1].add_child(UiKit.margin(h, 16, 10, 16, 10))
