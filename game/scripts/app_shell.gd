class_name AppShell
extends Control
## The app outside a game: four tabs (Home, Games, Chat, Profile) on a bottom bar
## (side rail at 600dp and wider), plus the screens pushed over them: find people,
## someone's profile, friends/followers lists, friend requests, a chat, edit profile
## and settings. Built from the Sky & Ink pieces in UiKit.

const TABS := [
	{"icon": "home", "label": "Home"},
	{"icon": "puzzle-piece", "label": "Games"},
	{"icon": "chat-bubble-oval-left", "label": "Chat"},
	{"icon": "user-circle", "label": "Profile"},
]
const RAIL_DP := 600.0

var main: Node
var social: SocialClient
var state: Dictionary       # {"tab": int, "stack": Array} kept by main across rebuilds
var wide := false
var bottom_inset := 0.0
var _built_width := -1.0

var _frame: Control         # nav + page
var _page_holder: Control
var _nav: Control
var _screen_holder: Control # pushed screen, above everything
var _snack_holder: Control
var _refresh := Callable()  # re-renders the live part of what is on screen
var _dirty := false
var _kb_spacer: Control     # grows with the on-screen keyboard on screens with fields
var _snack_tween: Tween

# chat screen
var _chat_uid := ""
var _chat_scroll: ScrollContainer
var _chat_list: VBoxContainer
var _chat_sub: Label
var _typing_until := 0
var _last_typing_sent := 0

# search screen
var _search_results: Array = []
var _search_q := ""
var _search_timer: Timer
var _search_waiting := false

# list screen
var _list_users: Array = []
var _list_loaded := false


var plux: PluxPages


func _init(p_main: Node, p_social: SocialClient, p_state: Dictionary) -> void:
	main = p_main
	social = p_social
	state = p_state
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS


func _ready() -> void:
	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.25
	_search_timer.timeout.connect(func(): social.search(_search_q); _search_waiting = true)
	add_child(_search_timer)
	social.changed.connect(_mark_dirty)
	social.state_changed.connect(func(_s): _mark_dirty())
	social.notice.connect(_on_notice)
	social.chat_message.connect(_on_chat_message)
	social.chat_updated.connect(_on_chat_updated)
	social.user_loaded.connect(func(_u, _d): _mark_dirty())
	social.search_done.connect(_on_search_done)
	social.list_done.connect(_on_list_done)
	social.profile_saved.connect(_on_profile_saved)
	social.typing.connect(_on_typing)
	social.login_done.connect(_on_login_done)
	social.password_saved.connect(_on_password_saved)
	social.account_switched.connect(func(): _mark_dirty())
	_wire_eco()
	plux = PluxPages.new(self)
	social.trades_changed.connect(_mark_dirty)
	resized.connect(_on_resized)
	call_deferred("_rebuild")


func _exit_tree() -> void:
	social.close_chat()


func _on_resized() -> void:
	if size.x <= 1.0:
		return
	var want_wide := size.x >= RAIL_DP
	if want_wide != wide:
		_rebuild()


# ------------------------------------------------------------------ frame

func _rebuild() -> void:
	if size.x <= 1.0:
		return
	wide = size.x >= RAIL_DP
	_built_width = size.x
	var vp := get_viewport()
	bottom_inset = float(ScreenUtil.insets(vp).rb) / ScreenUtil.dp(vp)
	for ch in get_children():
		if ch != _search_timer:
			ch.queue_free()
	_frame = HBoxContainer.new() if wide else VBoxContainer.new()
	_frame.add_theme_constant_override("separation", 0)
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_frame)
	_page_holder = Control.new()
	_page_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_holder.mouse_filter = Control.MOUSE_FILTER_PASS
	_page_holder.clip_contents = true
	_screen_holder = Control.new()
	_screen_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_screen_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if wide:
		_nav = _make_nav()
		_frame.add_child(_nav)
		_frame.add_child(_page_holder)
	else:
		_frame.add_child(_page_holder)
		_nav = _make_nav()
		_frame.add_child(_nav)
	add_child(_screen_holder)
	_snack_holder = Control.new()
	_snack_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_snack_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_snack_holder)
	_show_current(false)


func _nav_items() -> Array:
	var items := []
	for t in TABS:
		items.append(t.duplicate())
	items[2]["badge"] = social.unread_total()
	items[3]["badge"] = social.data.req_in.size()
	return items


func _make_nav() -> Control:
	var cb := func(i: int): select_tab(i)
	if wide:
		return UiKit.nav_rail(_nav_items(), int(state.tab), cb)
	return UiKit.nav_bar(_nav_items(), int(state.tab), cb, bottom_inset)


func _refresh_nav() -> void:
	if _nav == null or not is_instance_valid(_nav):
		return
	# Restyled in place: the bar itself is never rebuilt, so it never moves.
	UiKit.nav_update(_nav, _nav_items(), int(state.tab), bottom_inset)


func select_tab(i: int) -> void:
	if i == int(state.tab) and state.stack.is_empty():
		return
	state.tab = i
	state.stack.clear()
	_refresh_nav()
	_show_current(true)


func push(screen: Dictionary) -> void:
	state.stack.append(screen)
	_show_current(true, 1)


func pop() -> void:
	if state.stack.is_empty():
		return
	state.stack.pop_back()
	_show_current(true, -1)


## Android back: closes a pushed screen, then goes to Home. False when on Home.
func back() -> bool:
	if not state.stack.is_empty():
		pop()
		return true
	if int(state.tab) != 0:
		select_tab(0)
		return true
	return false


func _show_current(animate: bool, direction := 0) -> void:
	social.close_chat()
	_chat_uid = ""
	_kb_spacer = null
	_pill_holder = null
	_refresh = Callable()
	main.menu_buttons.clear()
	for ch in _page_holder.get_children():
		ch.queue_free()
	for ch in _screen_holder.get_children():
		ch.queue_free()
	var node: Control
	if state.stack.is_empty():
		_screen_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		match int(state.tab):
			0: node = _home()
			1: node = _games()
			2: node = _chats()
			_: node = _profile()
		node.set_anchors_preset(Control.PRESET_FULL_RECT)
		_page_holder.add_child(node)
	else:
		_screen_holder.mouse_filter = Control.MOUSE_FILTER_STOP
		var bg := Panel.new()
		bg.add_theme_stylebox_override("panel", UiKit.box(UiKit.c("background"), 0))
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		var top: Dictionary = state.stack[state.stack.size() - 1]
		match str(top.k):
			"search": node = _search_screen()
			"user": node = _user_screen(str(top.uid))
			"list": node = _list_screen(str(top.uid), str(top.kind))
			"requests": node = _requests_screen()
			"chat": node = _chat_screen(str(top.uid))
			"edit": node = _edit_screen()
			"settings": node = _settings_screen()
			"password": node = _password_screen()
			"login": node = _login_screen()
			"shop": node = _shop_screen()
			"item": node = _item_screen(str(top.id))
			"store": node = plux.store_screen()
			"pro": node = plux.pro_screen()
			"outfits": node = plux.outfits_screen()
			"trades": node = plux.trades_screen()
			"trade": node = plux.new_trade_screen(str(top.uid))
			_: node = UiKit.vbox()
		node.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.add_child(node)
		# Screens with a text field lift themselves over the keyboard and the gesture
		# bar (_kb_spacer); the rest simply stop above the phone's navigation bar.
		if _kb_spacer == null:
			node.offset_bottom = -bottom_inset
		_screen_holder.add_child(bg)
		node = bg
	if animate:
		# A short fade only: the page never slides, so its top bar stays exactly where
		# it is, and the bottom bar is outside the page altogether.
		node.modulate.a = 0.0
		var tw := node.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(node, "modulate:a", 1.0, 0.22)


func _mark_dirty() -> void:
	if not _dirty:
		_dirty = true
		call_deferred("_do_refresh")


func _do_refresh() -> void:
	_dirty = false
	if not is_inside_tree() or not is_visible_in_tree():
		return
	_refresh_nav()
	_refresh_pill()
	if _refresh.is_valid():
		_refresh.call()


## Fills `box` now and again on every change, keeping the scroll position.
func _live(box: VBoxContainer, fill: Callable) -> void:
	fill.call(box)
	_refresh = func():
		if not is_instance_valid(box):
			return
		for ch in box.get_children():
			box.remove_child(ch)
			ch.queue_free()
		fill.call(box)


## Called by main whenever the phone's navigation bar inset changes (gesture bar vs
## buttons, rotation): the bottom bar keeps its place and its items stay above it.
func set_bottom_inset(v: float) -> void:
	if absf(v - bottom_inset) > 0.5:
		bottom_inset = v
		UiKit.nav_update(_nav, _nav_items(), int(state.tab), bottom_inset)
		if not state.stack.is_empty() and _kb_spacer == null:
			for bg in _screen_holder.get_children():
				if bg.get_child_count() > 0:
					(bg.get_child(0) as Control).offset_bottom = -bottom_inset


func _process(_delta: float) -> void:
	_process_pop_preview(_delta)
	if _kb_spacer and is_instance_valid(_kb_spacer):
		var vp := get_viewport()
		var kb := ScreenUtil.keyboard_height(vp) / ScreenUtil.dp(vp)
		var want := maxf(kb, bottom_inset)
		if absf(_kb_spacer.custom_minimum_size.y - want) > 0.5:
			var grew := want > _kb_spacer.custom_minimum_size.y
			_kb_spacer.custom_minimum_size.y = want
			if grew and _chat_scroll:
				_scroll_chat_to_end()
	if _chat_sub and is_instance_valid(_chat_sub) and _typing_until != 0 and Time.get_ticks_msec() > _typing_until:
		_typing_until = 0
		_chat_sub.text = _presence_text(social.card_for(_chat_uid))


# ------------------------------------------------------------------ small helpers

func _first_name() -> String:
	var n := str(social.data.name).strip_edges()
	var parts := n.split(" ", false)
	return parts[0] if parts.size() > 0 else n


func _toast(text: String) -> void:
	if main.world:
		main._toast(text)
		return
	if _snack_holder == null or not is_instance_valid(_snack_holder):
		return
	for ch in _snack_holder.get_children():
		ch.queue_free()
	var sb: Array = UiKit.snackbar(text)
	var m := UiKit.margin(sb[0], 12, 0, 12, 0)
	var lift := 12.0
	if state.stack.is_empty() and not wide and _nav:
		lift += _nav.size.y
	else:
		lift += bottom_inset
	m.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	m.grow_vertical = Control.GROW_DIRECTION_BEGIN
	m.offset_bottom = -lift
	m.offset_left = 0
	m.offset_right = 0
	if wide:
		m.offset_left = 92
	_snack_holder.add_child(m)
	m.modulate.a = 0.0
	if _snack_tween:
		_snack_tween.kill()
	_snack_tween = m.create_tween()
	_snack_tween.tween_property(m, "modulate:a", 1.0, 0.18)
	_snack_tween.tween_interval(2.8)
	_snack_tween.tween_property(m, "modulate:a", 0.0, 0.3)
	_snack_tween.tween_callback(m.queue_free)


func _offline_toast() -> void:
	if social.state == "elsewhere":
		_toast("Your account is open on another phone.")
	else:
		_toast("You're offline. Try again once you're connected.")


func _act(ok: bool) -> void:
	if not ok:
		_offline_toast()


func _ago(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := int(Time.get_unix_time_from_system()) - unix
	if d < 60:
		return "just now"
	if d < 3600:
		return "%d min ago" % (d / 60)
	if d < 86400:
		return "%d h ago" % (d / 3600)
	return "%d days ago" % (d / 86400)


func _presence_text(u: Dictionary) -> String:
	if bool(u.get("online", false)):
		return "Online"
	var s := _ago(int(u.get("seen", 0)))
	return ("Last seen " + s) if s != "" else "Offline"


func _handle(u: Dictionary) -> String:
	var un := str(u.get("username", ""))
	return "@" + un if un != "" else ""


static func _local_dt(unix: int) -> Dictionary:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	return Time.get_datetime_dict_from_unix_time(unix + bias * 60)


static func _clock(unix: int) -> String:
	var d := _local_dt(unix)
	var h := int(d.hour)
	var ap := "AM" if h < 12 else "PM"
	h = h % 12
	if h == 0:
		h = 12
	return "%d:%02d %s" % [h, int(d.minute), ap]


static func _day_key(unix: int) -> String:
	var d := _local_dt(unix)
	return "%04d-%02d-%02d" % [d.year, d.month, d.day]


func _day_label(unix: int) -> String:
	var now := int(Time.get_unix_time_from_system())
	var k := _day_key(unix)
	if k == _day_key(now):
		return "Today"
	if k == _day_key(now - 86400):
		return "Yesterday"
	var d := _local_dt(unix)
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d" % [months[int(d.month) - 1], int(d.day)]


func _short_time(unix: int) -> String:
	if unix <= 0:
		return ""
	var now := int(Time.get_unix_time_from_system())
	if _day_key(unix) == _day_key(now):
		return _clock(unix)
	return _day_label(unix)


## A connection banner when friends and chat can't reach the server.
func _connection_card() -> Control:
	if social.is_online():
		return null
	var title := "Connecting..."
	var sub := "Friends and chat need the Plux server. The free server can take about a minute to wake up."
	var tint := UiKit.AMBER
	if social.state == "elsewhere":
		title = "Open on another phone"
		sub = "Your account was opened somewhere else. Tap to use it here again."
		tint = UiKit.c("error")
	elif social.state == "offline":
		title = "Offline"
		sub = "Add a server address in Settings to use friends and chat."
		tint = UiKit.c("error")
	var card: Array = UiKit.card()
	card[1].add_child(UiKit.setting_row("signal", title, sub, "", tint, func():
		if social.state == "elsewhere":
			social.start(social.url if social.url != "" else main.server_url())
		else:
			social.reconnect_now()))
	return UiKit.margin(card[0], 0, 6, 0, 6)


# ------------------------------------------------------------------ tab: Home

func _home() -> Control:
	var av := UiKit.avatar(44, str(social.data.name), int(social.data.get("av", -1)))
	var av_btn := UiKit.TapRow.new()
	av_btn.on_tap = func(): select_tab(3)
	av_btn.add_child(av)
	av.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bell := UiKit.icon_button("bell", func(): push({"k": "requests"}), Color(0, 0, 0, 0), social.data.req_in.size())
	var title := ("Hi, " + _first_name()) if _first_name() != "" else "Plux"
	var page := UiKit.pinned_page(title, Callable(), av_btn, [_plux_pill_live(), bell])
	var content: VBoxContainer = page[1]
	var room_now := Protocol.sanitize_room(main.settings.get_value("p", "room", Protocol.DEFAULT_ROOM))
	var hero := UiKit.hero_card("Play online", "Jump into room %s on the Plux server" % room_now, "play", main._on_play_online)
	content.add_child(hero)
	main.menu_buttons.append(hero)
	main.menu_status = UiKit.label("", "body_medium", UiKit.c("error"))
	main.menu_status.visible = false
	content.add_child(UiKit.margin(main.menu_status, 20, 0, 20, 0))
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	_live(live, func(box: VBoxContainer):
		var cc := _connection_card()
		if cc:
			box.add_child(cc)
		var grid := HBoxContainer.new()
		grid.add_theme_constant_override("separation", 0)
		grid.add_child(UiKit.quick_cell("magnifying-glass", "Search", func(): push({"k": "search"})))
		grid.add_child(UiKit.quick_cell("users", "Friends", func(): push({"k": "list", "uid": social.uid, "kind": "friends"})))
		grid.add_child(UiKit.quick_cell("user-plus", "Requests", func(): push({"k": "requests"}), social.data.req_in.size()))
		grid.add_child(UiKit.quick_cell("chat-bubble-left-right", "Chats", func(): select_tab(2), social.unread_total()))
		box.add_child(UiKit.margin(grid, 12, 6, 12, 0))
		box.add_child(UiKit.margin(_wallet_card(), 0, 14, 0, 0))

		var online := []
		for w in social.data.friends:
			if bool(social.data.friends[w].get("online", false)):
				online.append(social.data.friends[w])
		box.add_child(UiKit.section_title("Friends online"))
		var card: Array = UiKit.card()
		box.add_child(card[0])
		if online.is_empty():
			var msg := "Add friends to see who's around." if social.data.friends.is_empty() else "None of your friends are on right now."
			card[1].add_child(UiKit.empty_state("users", "Nobody online", msg,
				UiKit.small_button("Find people", true, func(): push({"k": "search"}), "magnifying-glass") if social.data.friends.is_empty() else null))
		else:
			for u in online:
				var w := str(u.uid)
				card[1].add_child(UiKit.person_row(str(u.get("name", "Player")), "Online", true,
					func(): push({"k": "user", "uid": w}),
					[UiKit.icon_button("chat-bubble-oval-left", func(): push({"k": "chat", "uid": w}), UiKit.c("primary"))],
					UiKit.SUCCESS, int(u.get("av", -1))))

		var convos := _conversations()
		if not convos.is_empty():
			box.add_child(UiKit.section_title("Recent chats"))
			var c2: Array = UiKit.card()
			box.add_child(c2[0])
			for cv in convos.slice(0, 3):
				c2[1].add_child(_convo_row(cv))
	)
	return page[0]


# ------------------------------------------------------------------ tab: Games

var _pop_preview_char: PopCharacter
var _pop_preview_root: Node3D


func _fill_pop_chars(flow: HFlowContainer) -> void:
	for c in flow.get_children():
		c.queue_free()
	var cur := int(main.settings.get_value("p", "pop_ch", 0))
	for i in PopRules.CHARACTERS.size():
		var idx := i
		flow.add_child(UiKit.chip(PopRules.character_name(i), i == cur, func():
			main.settings.set_value("p", "pop_ch", idx)
			main.settings.save(main.SETTINGS_PATH)
			_fill_pop_chars(flow)
			_set_preview_char(idx)))


func _fill_pop_bots(flow: HFlowContainer) -> void:
	for c in flow.get_children():
		c.queue_free()
	var cur := int(main.settings.get_value("p", "pop_bots", 3))
	for n in PopRules.MAX_BOTS + 1:
		var k := n
		flow.add_child(UiKit.chip("None" if n == 0 else str(n), n == cur, func():
			main.settings.set_value("p", "pop_bots", k)
			main.settings.save(main.SETTINGS_PATH)
			_fill_pop_bots(flow)))


## A little 3D stage with your chosen character bouncing on it.
func _pop_preview() -> Control:
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.custom_minimum_size = Vector2(0, 170)
	svc.mouse_filter = Control.MOUSE_FILTER_PASS
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_2X
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	svc.add_child(vp)
	_pop_preview_root = Node3D.new()
	vp.add_child(_pop_preview_root)
	var cam := Camera3D.new()
	cam.fov = 40
	cam.transform = Transform3D(Basis.looking_at(Vector3(0, 0.95, 0) - Vector3(0, 1.35, 3.4)), Vector3(0, 1.35, 3.4))
	_pop_preview_root.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -35, 0)
	_pop_preview_root.add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("#dfefff")
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	_pop_preview_root.add_child(env)
	var disc := MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.top_radius = 0.95
	dm.bottom_radius = 1.0
	dm.height = 0.12
	disc.mesh = dm
	disc.material_override = PopCharacter.mat(UiKit.SKY_LIGHT)
	disc.position.y = -0.06
	_pop_preview_root.add_child(disc)
	_set_preview_char(int(main.settings.get_value("p", "pop_ch", 0)))
	return svc


func _set_preview_char(i: int) -> void:
	if _pop_preview_root == null or not is_instance_valid(_pop_preview_root):
		return
	if _pop_preview_char and is_instance_valid(_pop_preview_char):
		_pop_preview_char.queue_free()
	_pop_preview_char = PopCharacter.new()
	_pop_preview_root.add_child(_pop_preview_char)
	_pop_preview_char.setup(PopRules.character_name(i), i, Protocol.color_for(i), false)
	_pop_preview_char.rotation.y = 0.5
	_pop_preview_char.lunge()


func _process_pop_preview(delta: float) -> void:
	if _pop_preview_char == null or not is_instance_valid(_pop_preview_char) or not _pop_preview_char.is_visible_in_tree():
		return
	_pop_preview_char.facing_yaw = _pop_preview_char.facing_yaw + delta * 0.6
	_pop_preview_char.animate(delta, Vector3.ZERO, true)

func _games() -> Control:
	var page := UiKit.pinned_page("Games", Callable())
	var content: VBoxContainer = page[1]
	var room_now := Protocol.sanitize_room(main.settings.get_value("p", "room", Protocol.DEFAULT_ROOM))
	# Pop-Up Panic: the new party game, first.
	var pop_hero := UiKit.hero_card("Pop-Up Panic", "New! Bonk weird heads off a sky picnic table. Play online in room %s" % room_now, "sparkles", main._on_pop_online)
	content.add_child(pop_hero)
	main.menu_buttons.append(pop_hero)
	main.menu_status = UiKit.label("", "body_medium", UiKit.c("error"))
	main.menu_status.visible = false
	content.add_child(UiKit.margin(main.menu_status, 20, 0, 20, 0))
	var pc: Array = UiKit.card()
	content.add_child(pc[0])
	var solo_row := UiKit.setting_row("bolt", "Practice with bots",
		"No friends around? Play right now on this phone, no internet needed", "", UiKit.PINK, main._on_pop_solo)
	pc[1].add_child(solo_row)
	main.menu_buttons.append(solo_row)
	pc[1].add_child(UiKit.margin(UiKit.label("Your character", "title_small", UiKit.c("on_surface"), false), 16, 12, 16, 4))
	pc[1].add_child(_pop_preview())
	var ch_flow := HFlowContainer.new()
	ch_flow.add_theme_constant_override("h_separation", 8)
	ch_flow.add_theme_constant_override("v_separation", 8)
	pc[1].add_child(UiKit.margin(ch_flow, 16, 8, 16, 4))
	_fill_pop_chars(ch_flow)
	pc[1].add_child(UiKit.margin(UiKit.label("Bots in your room", "title_small", UiKit.c("on_surface"), false), 16, 12, 16, 4))
	var bot_flow := HFlowContainer.new()
	bot_flow.add_theme_constant_override("h_separation", 8)
	bot_flow.add_theme_constant_override("v_separation", 8)
	pc[1].add_child(UiKit.margin(bot_flow, 16, 4, 16, 4))
	_fill_pop_bots(bot_flow)
	pc[1].add_child(UiKit.margin(UiKit.label("Online, bots fill the room until friends join. Practice always has at least one.",
		"body_small", UiKit.c("on_surface_variant")), 16, 4, 16, 16))

	var hero := UiKit.hero_card("Neon Bounce", "Gravity flips on the drop. Play online in room %s" % room_now, "play", main._on_play_online)
	content.add_child(UiKit.vspace(8))
	content.add_child(hero)
	main.menu_buttons.append(hero)

	content.add_child(UiKit.section_title("Room"))
	var rm: Array = UiKit.text_field("Room code", room_now, 6, "Everyone with the same code plays together")
	var room_edit: LineEdit = rm[1]
	room_edit.text_changed.connect(func(t: String):
		main.settings.set_value("p", "room", t)
		main.settings.save(main.SETTINGS_PATH))
	content.add_child(rm[0])

	content.add_child(UiKit.section_title("Play on the same Wi-Fi"))
	var friends: Array = UiKit.card()
	content.add_child(friends[0])
	var host_row := UiKit.setting_row("wifi", "Host on this phone", "Friends on the same Wi-Fi or hotspot join you", "", UiKit.SKY_MEDIUM, main._on_host)
	friends[1].add_child(host_row)
	main.menu_buttons.append(host_row)
	var fr: Array = UiKit.text_field("Friend's IP (192.168...)", main.settings.get_value("p", "friend", ""), 64, "Shown at the top of your friend's screen")
	var friend_edit: LineEdit = fr[1]
	friend_edit.text_changed.connect(func(t: String):
		main.settings.set_value("p", "friend", t)
		main.settings.save(main.SETTINGS_PATH))
	friends[1].add_child(UiKit.vspace(4))
	friends[1].add_child(fr[0])
	var join_btn := UiKit.outline_button("Join friend", "users", main._on_join_friend)
	friends[1].add_child(UiKit.margin(join_btn, 16, 12, 16, 16))
	main.menu_buttons.append(join_btn)

	content.add_child(UiKit.section_title("More games"))
	content.add_child(UiKit.margin(UiKit.label("Making and sharing your own games comes in a later update. For now there are two: Pop-Up Panic and Neon Bounce.",
		"body_medium", UiKit.c("on_surface_variant")), 20, 0, 20, 0))
	_kb_spacer = UiKit.vspace(bottom_inset)
	content.add_child(_kb_spacer)
	content.add_child(UiKit.end_padding())
	return page[0]


# ------------------------------------------------------------------ tab: Chat

## Friends as conversations, newest message first; friends with no messages last.
func _conversations() -> Array:
	var out := []
	for w in social.data.friends:
		var chat: Array = social.data.chats.get(w, [])
		var last: Dictionary = chat[chat.size() - 1] if chat.size() > 0 else {}
		out.append({"uid": w, "u": social.data.friends[w], "last": last, "ts": int(last.get("ts", 0))})
	out.sort_custom(func(a, b):
		if a.ts != b.ts:
			return a.ts > b.ts
		return str(a.u.get("name", "")).naturalnocasecmp_to(str(b.u.get("name", ""))) < 0)
	return out


func _convo_row(cv: Dictionary) -> Control:
	var w := str(cv.uid)
	var u: Dictionary = cv.u
	var last: Dictionary = cv.last
	var unread := int(social.data.unread.get(w, 0))
	var sub := "Say hi"
	if not last.is_empty():
		sub = ("You: " if last.from == social.uid else "") + str(last.text).replace("\n", " ")
	var trailing := []
	var meta := UiKit.vbox(4)
	var t := UiKit.label(_short_time(int(cv.ts)), "label_medium", UiKit.c("primary") if unread > 0 else UiKit.c("on_surface_variant"), false)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	meta.add_child(t)
	if unread > 0:
		var b := UiKit.badge(unread)
		b.size_flags_horizontal = Control.SIZE_SHRINK_END
		meta.add_child(b)
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trailing.append(meta)
	return UiKit.person_row(str(u.get("name", "Player")), sub, bool(u.get("online", false)),
		func(): push({"k": "chat", "uid": w}), trailing, UiKit.c("on_surface") if unread > 0 else Color(0, 0, 0, 0), int(u.get("av", -1)), _eq(u))


func _chats() -> Control:
	var page := UiKit.pinned_page("Chat", Callable(), null,
		[UiKit.icon_button("user-plus", func(): push({"k": "search"}))])
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	_live(live, func(box: VBoxContainer):
		var cc := _connection_card()
		if cc:
			box.add_child(cc)
		var n: int = social.data.req_in.size()
		if n > 0:
			var rc: Array = UiKit.card()
			rc[1].add_child(UiKit.setting_row("user-plus", "Friend requests", "%d waiting for you" % n, "", UiKit.PINK, func(): push({"k": "requests"})))
			box.add_child(UiKit.margin(rc[0], 0, 8, 0, 0))
		var convos := _conversations()
		if convos.is_empty():
			box.add_child(UiKit.empty_state("chat-bubble-left-right", "No chats yet",
				"Add friends to start talking. Only friends can message each other.",
				UiKit.small_button("Find people", true, func(): push({"k": "search"}), "magnifying-glass")))
			return
		box.add_child(UiKit.section_title("Friends"))
		var card: Array = UiKit.card()
		box.add_child(card[0])
		for cv in convos:
			card[1].add_child(_convo_row(cv))
	)
	return page[0]


# ------------------------------------------------------------------ tab: Profile

func _profile() -> Control:
	var page := UiKit.pinned_page("Profile", Callable(), null,
		[UiKit.icon_button("cog-6-tooth", func(): push({"k": "settings"}))])
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	_live(live, func(box: VBoxContainer):
		var me: Dictionary = social.data.me
		var edit := UiKit.outline_button("Edit profile", "pencil", func(): push({"k": "edit"}))
		box.add_child(UiKit.profile_header(str(social.data.name), str(social.data.username), str(social.data.bio),
			social.is_online(), [edit], "", int(social.data.get("av", -1)), social.equipped_cards(), social.is_pro()))
		var stats := UiKit.hbox(10)
		stats.add_child(UiKit.stat_tile(social.data.friends.size(), "Friends", func(): push({"k": "list", "uid": social.uid, "kind": "friends"})))
		stats.add_child(UiKit.stat_tile(int(me.get("followers", 0)), "Followers", func(): push({"k": "list", "uid": social.uid, "kind": "followers"})))
		stats.add_child(UiKit.stat_tile(social.data.following.size(), "Following", func(): push({"k": "list", "uid": social.uid, "kind": "following"})))
		box.add_child(UiKit.margin(stats, 16, 2, 16, 0))
		var cc := _connection_card()
		if cc:
			box.add_child(UiKit.margin(cc, 0, 8, 0, 0))
		box.add_child(UiKit.margin(_wallet_card(), 0, 12, 0, 0))
		box.add_child(UiKit.section_title("Avatar"))
		var ac: Array = UiKit.card()
		box.add_child(ac[0])
		ac[1].add_child(UiKit.setting_row("tag", "Avatar shop", "Hats, faces, backs and effects", "", UiKit.SKY_MEDIUM, func(): _shop_slot = ""; push({"k": "shop"})))
		ac[1].add_child(UiKit.setting_row("cube", "My items", "Wear what you own", str(social.eco.get("inv", []).size()) if social.eco.get("inv", []).size() > 0 else "", UiKit.PINK, func(): _shop_slot = "mine"; push({"k": "shop"})))
		ac[1].add_child(UiKit.setting_row("user-circle", "Outfits", "Save looks and switch in one tap", "", UiKit.SKY_MEDIUM, func(): push({"k": "outfits"})))
		if social.feature("trading"):
			var open_in := social.trades.filter(func(t): return str(t.get("status", "")) == "open" and not bool(t.get("mine", false))).size()
			ac[1].add_child(UiKit.setting_row("arrows-right-left", "Trades", "Swap limited items with friends", str(open_in) if open_in > 0 else "", UiKit.PINK, func(): push({"k": "trades"})))
		box.add_child(UiKit.section_title("Plux"))
		var pc: Array = UiKit.card()
		box.add_child(pc[0])
		pc[1].add_child(UiKit.setting_row("sparkles", "Get Plux", "Plux packs", "", UiKit.SKY_MEDIUM, func(): push({"k": "store"})))
		var pro_sub := "You're a member" if social.is_pro() else "Monthly Plux, a Pro badge and more"
		pc[1].add_child(UiKit.setting_row("star", "Plux Pro", pro_sub, "", PluxPages.PRO_GOLD, func(): push({"k": "pro"})))
		box.add_child(UiKit.section_title("People"))
		var card: Array = UiKit.card()
		box.add_child(card[0])
		card[1].add_child(UiKit.setting_row("magnifying-glass", "Find people", "Search by name or @username", "", UiKit.SKY_MEDIUM, func(): push({"k": "search"})))
		var n: int = social.data.req_in.size()
		card[1].add_child(UiKit.setting_row("user-plus", "Friend requests", "Received and sent", str(n) if n > 0 else "", UiKit.PINK, func(): push({"k": "requests"})))
		card[1].add_child(UiKit.setting_row("cog-6-tooth", "Settings", "Account, password, theme, sound and screen", "", UiKit.INK if not UiKit.dark else UiKit.SKY, func(): push({"k": "settings"})))
		var note := "Your account is saved on the server. You can log in on any phone with @%s and your password." % str(social.data.username)
		if not social.has_password():
			note = "Your account is saved on the server. Set a password in Settings so you can log in again after reinstalling or on a new phone."
		box.add_child(UiKit.margin(UiKit.label(note, "body_small", UiKit.c("on_surface_variant")), 20, 14, 20, 0))
	)
	return page[0]


# ------------------------------------------------------------------ relationship buttons

func _rel(u: Dictionary) -> Dictionary:
	var w := str(u.get("uid", ""))
	return {
		"friend": social.data.friends.has(w),
		"req_in": social.data.req_in.has(w),
		"req_out": social.data.req_out.has(w),
		"follow": social.data.following.has(w),
		"follows_me": bool(u.get("follows_me", false)),
	}


## The one button a person row shows: Message, Accept, Requested or Add.
func _row_action(u: Dictionary) -> Control:
	var w := str(u.get("uid", ""))
	var r := _rel(u)
	if w == social.uid:
		return UiKit.label("You", "label_large", UiKit.c("on_surface_variant"), false)
	if r.friend:
		return UiKit.small_button("Message", false, func(): push({"k": "chat", "uid": w}))
	if r.req_in:
		var b := UiKit.small_button("Accept", true, Callable())
		b.pressed.connect(func(): b.disabled = true; _act(social.accept(w)))
		return b
	if r.req_out:
		var b2 := UiKit.small_button("Requested", false, Callable())
		b2.pressed.connect(func(): b2.disabled = true; _act(social.cancel_request(w)))
		return b2
	var b3 := UiKit.small_button("Add", true, Callable(), "user-plus")
	b3.pressed.connect(func(): b3.disabled = true; _act(social.add_friend(w)))
	return b3


func _person(u: Dictionary, with_action := true) -> Control:
	var w := str(u.get("uid", ""))
	var sub := _handle(u)
	var online: bool = bool(u.get("online", false)) or (social.data.friends.has(w) and bool(social.data.friends[w].get("online", false)))
	if online:
		sub = (sub + "  ·  Online") if sub != "" else "Online"
	var tr := [_row_action(u)] if with_action else []
	var sub_col := Color(0, 0, 0, 0)
	if online and u.get("playing") is Dictionary and not u.playing.is_empty():
		sub = "Playing " + str(u.playing.get("title", "a game"))
		sub_col = UiKit.c("primary")
	return UiKit.person_row(str(u.get("name", "Player")), sub, online,
		func(): if w != social.uid: push({"k": "user", "uid": w}), tr, sub_col, int(u.get("av", -1)), _eq(u))


# ------------------------------------------------------------------ screen: find people

func _search_screen() -> Control:
	var page := UiKit.pinned_page("Find people", pop)
	var root: VBoxContainer = page[0]
	var sf: Array = UiKit.search_field("Search by name or @username", _search_q)
	root.add_child(sf[0])
	root.move_child(sf[0], 1)
	var e: LineEdit = sf[1]
	e.text_changed.connect(func(t: String):
		_search_q = t.strip_edges()
		_search_timer.start())
	e.text_submitted.connect(func(_t): DisplayServer.virtual_keyboard_hide(); e.release_focus())
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	_kb_spacer = UiKit.vspace(bottom_inset)
	content.add_child(_kb_spacer)
	content.add_child(UiKit.end_padding())
	_search_results = []
	_search_waiting = true
	social.search(_search_q)
	_live(live, func(box: VBoxContainer):
		var cc := _connection_card()
		if cc:
			box.add_child(cc)
			return
		if _search_results.is_empty():
			if _search_waiting:
				box.add_child(UiKit.margin(UiKit.label("Searching...", "body_medium", UiKit.c("on_surface_variant")), 20, 16, 20, 0))
			elif _search_q == "":
				box.add_child(UiKit.empty_state("users", "No one else yet", "When your friends install Plux, they'll show up here. Ask them for their @username."))
			else:
				box.add_child(UiKit.empty_state("magnifying-glass", "No one found", "Check the spelling, or ask your friend for their @username."))
			return
		box.add_child(UiKit.section_title("Recently active" if _search_q == "" else "Results"))
		var card: Array = UiKit.card()
		box.add_child(card[0])
		for u in _search_results:
			card[1].add_child(_person(u))
	)
	if _search_q == "":
		e.call_deferred("grab_focus")
	return root


func _on_search_done(_q: String, users: Array) -> void:
	_search_results = users
	for u in users:
		if u is Dictionary and SocialHub.valid_uid(u.get("uid")):
			social.data.cards[u.uid] = u
	_search_waiting = false
	_mark_dirty()


# ------------------------------------------------------------------ screen: someone's profile

func _user_screen(w: String) -> Control:
	social.get_user(w)
	var first: Dictionary = social.card_for(w)
	var page := UiKit.pinned_page(str(first.get("name", "Profile")) if str(first.get("name", "Player")) != "Player" else "Profile", pop)
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	var confirm_remove := [false]
	_live(live, func(box: VBoxContainer):
		var u: Dictionary = social.card_for(w)
		var r := _rel(u)
		var actions := []
		var follow_btn: Button
		if r.follow:
			follow_btn = UiKit.outline_button("Following", "check", Callable())
		else:
			follow_btn = UiKit.primary_button("Follow back" if r.follows_me else "Follow", "heart", Callable())
		var on: bool = not r.follow
		follow_btn.pressed.connect(func(): follow_btn.disabled = true; _act(social.follow(w, on)))
		actions.append(follow_btn)
		var fb: Button
		if r.friend:
			fb = UiKit.primary_button("Message", "chat-bubble-oval-left", func(): push({"k": "chat", "uid": w}))
		elif r.req_in:
			fb = UiKit.primary_button("Accept", "check", Callable())
			fb.pressed.connect(func(): fb.disabled = true; _act(social.accept(w)))
		elif r.req_out:
			fb = UiKit.outline_button("Requested", "clock", Callable())
			fb.pressed.connect(func(): fb.disabled = true; _act(social.cancel_request(w)))
		else:
			fb = UiKit.outline_button("Add friend", "user-plus", Callable())
			fb.pressed.connect(func(): fb.disabled = true; _act(social.add_friend(w)))
		actions.append(fb)
		var note := _presence_text(u)
		if r.follows_me:
			note += "  ·  Follows you"
		if r.friend:
			note += "  ·  Friends"
		box.add_child(UiKit.profile_header(str(u.get("name", "Player")), str(u.get("username", "")), str(u.get("bio", "")),
			bool(u.get("online", false)), actions, note, int(u.get("av", -1)), _eq(u), bool(u.get("pro", false))))
		if r.friend and social.feature("trading"):
			var tb := UiKit.outline_button("Trade", "arrows-right-left", func(): plux.pick_give.clear(); plux.pick_get.clear(); plux.give_plux = 0; push({"k": "trade", "uid": w}))
			box.add_child(UiKit.margin(tb, 16, 0, 16, 4))
		if r.req_in:
			var dec := UiKit.text_button("Decline request", UiKit.c("on_surface_variant"), func(): _act(social.decline(w)))
			dec.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			box.add_child(dec)
		var stats := UiKit.hbox(10)
		stats.add_child(UiKit.stat_tile(int(u.get("friends", 0)), "Friends", func(): push({"k": "list", "uid": w, "kind": "friends"})))
		stats.add_child(UiKit.stat_tile(int(u.get("followers", 0)), "Followers", func(): push({"k": "list", "uid": w, "kind": "followers"})))
		stats.add_child(UiKit.stat_tile(int(u.get("following", 0)), "Following", func(): push({"k": "list", "uid": w, "kind": "following"})))
		box.add_child(UiKit.margin(stats, 16, 2, 16, 0))
		if r.friend:
			box.add_child(UiKit.vspace(16))
			var label := "Tap again to remove" if confirm_remove[0] else "Remove friend"
			var rm := UiKit.text_button(label, UiKit.c("error"), func():
				if confirm_remove[0]:
					confirm_remove[0] = false
					_act(social.unfriend(w))
				else:
					confirm_remove[0] = true
					_mark_dirty())
			rm.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			box.add_child(rm)
		if not social.is_online():
			var cc := _connection_card()
			if cc:
				box.add_child(UiKit.margin(cc, 0, 10, 0, 0))
	)
	return page[0]


# ------------------------------------------------------------------ screen: people lists

func _list_screen(w: String, kind: String) -> Control:
	var who := "Your" if w == social.uid else ""
	var title: String = {"friends": "Friends", "followers": "Followers", "following": "Following"}.get(kind, "People")
	var page := UiKit.pinned_page(title, pop)
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	_list_users = []
	_list_loaded = false
	if w == social.uid and kind == "friends":
		_list_users = social.data.friends.values()
		_list_loaded = true
	social.get_list(w, kind)
	_live(live, func(box: VBoxContainer):
		var users := _list_users
		if w == social.uid and kind == "friends":
			users = social.data.friends.values()
		if users.is_empty():
			if not _list_loaded:
				if social.is_online():
					box.add_child(UiKit.margin(UiKit.label("Loading...", "body_medium", UiKit.c("on_surface_variant")), 20, 16, 20, 0))
				else:
					var cc := _connection_card()
					if cc:
						box.add_child(cc)
				return
			var msgs := {
				"friends": ["No friends yet", "Find people and send them a friend request." if who != "" else "Nobody here yet."],
				"followers": ["No followers yet", "When someone follows, they show up here."],
				"following": ["Not following anyone", "Follow people to keep up with them." if who != "" else "Nobody here yet."],
			}
			var m: Array = msgs.get(kind, ["Nobody here", ""])
			box.add_child(UiKit.empty_state("users", m[0], m[1],
				UiKit.small_button("Find people", true, func(): push({"k": "search"}), "magnifying-glass") if who != "" and kind != "followers" else null))
			return
		box.add_child(UiKit.section_title("%d %s" % [users.size(), "people" if users.size() != 1 else "person"]))
		var card: Array = UiKit.card()
		box.add_child(card[0])
		for u in users:
			card[1].add_child(_person(u))
	)
	return page[0]


func _on_list_done(_w: String, _kind: String, users: Array) -> void:
	_list_users = users
	_list_loaded = true
	_mark_dirty()


# ------------------------------------------------------------------ screen: friend requests

func _requests_screen() -> Control:
	var page := UiKit.pinned_page("Friend requests", pop)
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	_live(live, func(box: VBoxContainer):
		var cc := _connection_card()
		if cc:
			box.add_child(cc)
		box.add_child(UiKit.section_title("Received"))
		if social.data.req_in.is_empty():
			box.add_child(UiKit.margin(UiKit.label("No requests right now.", "body_medium", UiKit.c("on_surface_variant")), 20, 0, 20, 0))
		else:
			var card: Array = UiKit.card()
			box.add_child(card[0])
			for w in social.data.req_in:
				var u: Dictionary = social.data.req_in[w]
				var uid_w := str(w)
				var acc := UiKit.small_button("Accept", true, Callable())
				acc.pressed.connect(func(): acc.disabled = true; _act(social.accept(uid_w)))
				var dec := UiKit.icon_button("x-mark", func(): _act(social.decline(uid_w)), UiKit.c("on_surface_variant"))
				card[1].add_child(UiKit.person_row(str(u.get("name", "Player")), _handle(u), bool(u.get("online", false)),
					func(): push({"k": "user", "uid": uid_w}), [acc, dec], Color(0, 0, 0, 0), int(u.get("av", -1))))
		box.add_child(UiKit.section_title("Sent"))
		if social.data.req_out.is_empty():
			box.add_child(UiKit.margin(UiKit.label("You haven't sent any requests.", "body_medium", UiKit.c("on_surface_variant")), 20, 0, 20, 0))
		else:
			var card2: Array = UiKit.card()
			box.add_child(card2[0])
			for w in social.data.req_out:
				var u: Dictionary = social.card_for(w)
				if str(u.get("name", "Player")) == "Player":
					u = social.data.req_out[w]
				var uid_w := str(w)
				var cancel := UiKit.small_button("Cancel", false, Callable())
				cancel.pressed.connect(func(): cancel.disabled = true; _act(social.cancel_request(uid_w)))
				card2[1].add_child(UiKit.person_row(str(u.get("name", "Player")), _handle(u), false,
					func(): push({"k": "user", "uid": uid_w}), [cancel], Color(0, 0, 0, 0), int(u.get("av", -1))))
		box.add_child(UiKit.margin(UiKit.label("Friends can message each other. Following someone doesn't need their OK.",
			"body_small", UiKit.c("on_surface_variant")), 20, 16, 20, 0))
	)
	return page[0]


# ------------------------------------------------------------------ screen: chat

func _chat_screen(w: String) -> Control:
	_chat_uid = w
	social.open_chat(w)
	var u: Dictionary = social.card_for(w)
	var root := UiKit.vbox(0)
	# Header: back, avatar, name and presence. Tapping the name opens the profile.
	var head := UiKit.hbox(0)
	var back_btn := UiKit.icon_button("arrow-left", pop)
	head.add_child(back_btn)
	var who := UiKit.TapRow.new()
	who.on_tap = func(): push({"k": "user", "uid": w})
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var wh := UiKit.hbox(12)
	wh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wh.add_child(UiKit.avatar_presence(40, str(u.get("name", "Player")), bool(u.get("online", false)), int(u.get("av", -1))))
	var tc := UiKit.vbox(0)
	tc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := UiKit.label(str(u.get("name", "Player")), "title_medium", UiKit.c("on_background"), false)
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.clip_text = true
	if bool(u.get("pro", false)):
		var nrow := UiKit.hbox(6)
		nrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nrow.add_child(nm)
		nrow.add_child(PluxPages.pro_badge(true))
		tc.add_child(nrow)
	else:
		tc.add_child(nm)
	_chat_sub = UiKit.label(_presence_text(u), "body_small", UiKit.c("on_surface_variant"), false)
	tc.add_child(_chat_sub)
	wh.add_child(tc)
	for ch in wh.get_children():
		ch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	who.add_child(UiKit.margin(wh, 4, 6, 8, 6))
	who.get_child(0).mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(who)
	for ch in head.get_children():
		ch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	root.add_child(UiKit.margin(head, 4, 8, 8, 4))
	var divider := ColorRect.new()
	divider.color = UiKit.c("outline_variant")
	divider.custom_minimum_size = Vector2(0, 1)
	root.add_child(divider)
	# Messages
	_chat_scroll = ScrollContainer.new()
	_chat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_scroll.get_v_scroll_bar().modulate.a = 0.0
	var limiter := UiKit.WidthLimiter.new()
	limiter.max_width = 760
	limiter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_scroll.add_child(limiter)
	_chat_list = UiKit.vbox(2)
	limiter.add_child(_chat_list)
	root.add_child(_chat_scroll)
	_fill_chat()
	# Composer
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", UiKit.box(UiKit.c("surface_container_low"), 0))
	var bar_col := UiKit.vbox(0)
	var line := ColorRect.new()
	line.color = UiKit.c("outline_variant")
	line.custom_minimum_size = Vector2(0, 1)
	bar_col.add_child(line)
	if social.data.friends.has(w):
		var h := UiKit.hbox(8)
		var e := LineEdit.new()
		e.placeholder_text = "Message"
		e.max_length = SocialHub.MAX_TEXT
		e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		e.custom_minimum_size = Vector2(0, 48)
		e.add_theme_font_override("font", UiKit.font("dm", 400))
		e.add_theme_font_size_override("font_size", 16)
		e.add_theme_color_override("font_color", UiKit.c("on_surface"))
		e.add_theme_color_override("font_placeholder_color", UiKit.c("on_surface_variant"))
		e.add_theme_color_override("caret_color", UiKit.c("primary"))
		e.add_theme_color_override("selection_color", Color(UiKit.c("primary"), 0.3))
		e.add_theme_stylebox_override("normal", UiKit.pad(UiKit.box(UiKit.c("surface_container_high"), 24), 18, 10))
		e.add_theme_stylebox_override("focus", UiKit.pad(UiKit.box(UiKit.c("surface_container_high"), 24, UiKit.c("primary"), 2), 16, 8))
		h.add_child(e)
		var send := Button.new()
		send.custom_minimum_size = Vector2(48, 48)
		send.focus_mode = Control.FOCUS_NONE
		send.icon = UiKit.icon_texture("paper-airplane")
		send.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		send.add_theme_constant_override("icon_max_width", 22)
		for st in ["icon_normal_color", "icon_pressed_color", "icon_hover_color", "icon_hover_pressed_color", "icon_disabled_color"]:
			send.add_theme_color_override(st, UiKit.c("on_primary"))
		var sb := UiKit.box(UiKit.c("primary"), 24)
		for st in ["normal", "hover", "pressed", "hover_pressed"]:
			send.add_theme_stylebox_override(st, sb)
		send.add_theme_stylebox_override("disabled", UiKit.box(Color(UiKit.c("primary"), 0.4), 24))
		send.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		send.disabled = true
		UiKit.add_press_shrink(send)
		h.add_child(send)
		var do_send := func():
			var t := e.text.strip_edges()
			if t == "":
				return
			social.send_text(w, t)
			e.text = ""
			send.disabled = true
			e.grab_focus()
		send.pressed.connect(do_send)
		e.text_submitted.connect(func(_t): do_send.call())
		e.text_changed.connect(func(t: String):
			send.disabled = t.strip_edges() == ""
			var now := Time.get_ticks_msec()
			if t != "" and now - _last_typing_sent > 2500:
				_last_typing_sent = now
				social.send_typing(w))
		bar_col.add_child(UiKit.margin(h, 12, 8, 12, 8))
	else:
		bar_col.add_child(UiKit.margin(UiKit.label("You can only message friends. Add %s as a friend to chat." % str(u.get("name", "them")),
			"body_medium", UiKit.c("on_surface_variant")), 20, 14, 20, 14))
	_kb_spacer = UiKit.vspace(bottom_inset)
	bar_col.add_child(_kb_spacer)
	bar.add_child(bar_col)
	root.add_child(bar)
	_refresh = func():
		if is_instance_valid(_chat_sub) and _typing_until == 0:
			_chat_sub.text = _presence_text(social.card_for(w))
	return root


func _fill_chat() -> void:
	if _chat_list == null or not is_instance_valid(_chat_list):
		return
	for ch in _chat_list.get_children():
		_chat_list.remove_child(ch)
		ch.queue_free()
	var chat: Array = social.data.chats.get(_chat_uid, [])
	_chat_list.add_child(UiKit.vspace(8))
	if chat.is_empty():
		var u: Dictionary = social.card_for(_chat_uid)
		_chat_list.add_child(UiKit.empty_state("chat-bubble-left-right", "Say hi to %s" % str(u.get("name", "your friend")),
			"Messages are saved on your phones. If your friend is offline, they get them next time they open Plux."))
		return
	var last_day := ""
	var start := maxi(chat.size() - 150, 0)
	for i in range(start, chat.size()):
		var m: Dictionary = chat[i]
		var dk := _day_key(int(m.ts))
		if dk != last_day:
			last_day = dk
			var dl := UiKit.label(_day_label(int(m.ts)), "label_medium", UiKit.c("on_surface_variant"), false)
			dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_chat_list.add_child(UiKit.margin(dl, 0, 12, 0, 6))
		var next_same: bool = i + 1 < chat.size() and chat[i + 1].from == m.from
		_chat_list.add_child(_bubble(m, next_same))
	_chat_list.add_child(UiKit.vspace(8))
	_scroll_chat_to_end()


func _bubble(m: Dictionary, tight: bool) -> Control:
	var mine: bool = m.from == social.uid
	var maxw := minf(_built_width * 0.78, 520.0)
	var text := str(m.text)
	var f := UiKit.font("dm", 400)
	var natural := 0.0
	for ln in text.split("\n"):
		natural = maxf(natural, f.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x)
	var st := ""
	if mine:
		st = {"sending": "Sending", "delivered": "Delivered", "queued": "Sent", "read": "Read", "failed": "Not sent"}.get(str(m.state), "")
	var meta_text := _clock(int(m.ts)) + (("  ·  " + st) if st != "" else "")
	var meta_w := UiKit.font("dm", 500).get_string_size(meta_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var inner_w := clampf(maxf(natural, meta_w) + 2.0, 24.0, maxw - 28.0)
	var p := PanelContainer.new()
	var fill := UiKit.c("primary") if mine else UiKit.c("surface_container_high")
	var fg := UiKit.c("on_primary") if mine else UiKit.c("on_surface")
	var sb := UiKit.box(fill, 18)
	if mine:
		sb.corner_radius_bottom_right = 6 if not tight else 18
	else:
		sb.corner_radius_bottom_left = 6 if not tight else 18
	p.add_theme_stylebox_override("panel", UiKit.pad(sb, 14, 8))
	var col := UiKit.vbox(2)
	var l := UiKit.label(text, "body_large", fg)
	l.custom_minimum_size.x = inner_w
	col.add_child(l)
	var meta := UiKit.label(meta_text, "label_small", Color(fg, 0.7), false)
	meta.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if mine and str(m.state) == "failed":
		meta.add_theme_color_override("font_color", UiKit.ERROR if not mine else Color(fg, 0.9))
	col.add_child(meta)
	p.add_child(col)
	var row := UiKit.hbox(0)
	if mine:
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(sp)
		row.add_child(p)
	else:
		row.add_child(p)
	return UiKit.margin(row, 12, 0, 12, 4 if not tight else 0)


func _scroll_chat_to_end() -> void:
	if _chat_scroll == null or not is_instance_valid(_chat_scroll):
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(_chat_scroll):
		_chat_scroll.scroll_vertical = int(_chat_scroll.get_v_scroll_bar().max_value)


func _on_chat_message(w: String, _m: Dictionary) -> void:
	if w == _chat_uid and _chat_list and is_instance_valid(_chat_list):
		_typing_until = 0
		_fill_chat()
	elif not main.world or true:
		var u: Dictionary = social.card_for(w)
		if w != _chat_uid:
			_toast("%s: %s" % [str(u.get("name", "Friend")), str(_m.get("text", "")).replace("\n", " ").left(60)])


func _on_chat_updated(w: String) -> void:
	if w == _chat_uid:
		_fill_chat()


func _on_typing(w: String) -> void:
	if w == _chat_uid and _chat_sub and is_instance_valid(_chat_sub):
		_chat_sub.text = "Typing..."
		_typing_until = Time.get_ticks_msec() + 3500


# ------------------------------------------------------------------ screen: edit profile

var _edit_error: Label

func _edit_screen() -> Control:
	var name_f: LineEdit
	var user_f: LineEdit
	var bio_f: LineEdit
	var save := UiKit.text_button("Save", UiKit.c("primary"), Callable())
	var page := UiKit.pinned_page("Edit profile", pop, null, [save])
	var content: VBoxContainer = page[1]
	# 112dp avatar with a 3dp primary ring and a 5dp gap. It previews the pick live.
	var chosen := [int(social.data.get("av", -1))]
	var ring := PanelContainer.new()
	ring.add_theme_stylebox_override("panel", UiKit.pad(UiKit.box(Color.TRANSPARENT, 64, UiKit.c("primary"), 3), 8, 8))
	ring.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ring.add_child(UiKit.avatar(112, str(social.data.name), chosen[0]))
	content.add_child(UiKit.margin(ring, 0, 16, 0, 4))
	var hint := UiKit.label("", "body_small", UiKit.c("on_surface_variant"))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(hint)
	# Avatar picker: your initials or one of the 30 buddies. The grid wraps to the
	# screen width, so it fills portrait and landscape alike.
	content.add_child(UiKit.section_title("Avatar"))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 10)
	flow.add_theme_constant_override("v_separation", 10)
	flow.alignment = FlowContainer.ALIGNMENT_CENTER
	var cells := []
	var refresh := func():
		for cell in cells:
			var on: bool = int(cell.get_meta("av")) == chosen[0]
			cell.get_child(0).add_theme_stylebox_override("panel",
				UiKit.pad(UiKit.box(Color(UiKit.c("primary"), 0.14) if on else Color.TRANSPARENT, 34,
					UiKit.c("primary") if on else Color.TRANSPARENT, 3), 4, 4))
		var old_av := ring.get_child(0)
		ring.remove_child(old_av)
		old_av.queue_free()
		ring.add_child(UiKit.avatar(112, str(social.data.name), chosen[0]))
		hint.text = "Your initials" if chosen[0] < 0 else AvatarArt.NAMES[chosen[0]]
	for i in range(-1, AvatarArt.COUNT):
		var cell := UiKit.TapRow.new()
		cell.set_meta("av", i)
		cell.custom_minimum_size = Vector2(64, 64)
		var frame := PanelContainer.new()
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.set_anchors_preset(Control.PRESET_FULL_RECT)
		var art := UiKit.avatar(56, str(social.data.name), i)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		art.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		frame.add_child(art)
		cell.add_child(frame)
		var pick := i
		cell.on_tap = func():
			chosen[0] = pick
			refresh.call()
		cells.append(cell)
		flow.add_child(cell)
	content.add_child(UiKit.margin(flow, 16, 4, 16, 4))
	refresh.call()
	content.add_child(UiKit.section_title("Name"))
	var nf: Array = UiKit.text_field("Your name", str(social.data.name), 16, "Shown to friends and above your player in games")
	name_f = nf[1]
	content.add_child(nf[0])
	content.add_child(UiKit.section_title("Username"))
	var uf: Array = UiKit.text_field("username", str(social.data.username), 20, "3 to 20 letters, numbers, _ or . People find you by @username")
	user_f = uf[1]
	user_f.text_changed.connect(func(t: String):
		var clean := SocialHub.clean_username(t)
		if clean != t:
			var col := user_f.caret_column
			user_f.text = clean
			user_f.caret_column = mini(col, clean.length()))
	content.add_child(uf[0])
	content.add_child(UiKit.section_title("Bio"))
	var bf: Array = UiKit.text_field("Say something about yourself", str(social.data.bio), 150, "")
	bio_f = bf[1]
	var counter := UiKit.label("%d/150" % bio_f.text.length(), "body_small", UiKit.c("on_surface_variant"), false)
	bio_f.text_changed.connect(func(t: String): counter.text = "%d/150" % t.length())
	content.add_child(bf[0])
	content.add_child(UiKit.margin(counter, 32, 4, 32, 0))
	_edit_error = UiKit.label("", "body_medium", UiKit.c("error"))
	var err_box := UiKit.margin(_edit_error, 20, 12, 20, 0)
	err_box.visible = false
	content.add_child(err_box)
	var save_big := UiKit.primary_button("Save", "check", Callable())
	content.add_child(UiKit.margin(save_big, 16, 12, 16, 0))
	var do_save := func():
		var un := SocialHub.clean_username(user_f.text)
		if un.length() < 3:
			_set_edit_error("Your username needs at least 3 characters.")
			return
		_set_edit_error("")
		main.settings.set_value("p", "name", name_f.text)
		main.settings.save(main.SETTINGS_PATH)
		if social.save_profile(name_f.text, un, bio_f.text, chosen[0]):
			save_big.disabled = true
		else:
			social.data.username = un
			pop()
			_toast("Saved on this phone. It updates for others when you're back online.")
	save.pressed.connect(do_save)
	save_big.pressed.connect(do_save)
	_kb_spacer = UiKit.vspace(bottom_inset)
	content.add_child(_kb_spacer)
	content.add_child(UiKit.end_padding())
	return page[0]


func _on_profile_saved(ok: bool, why: String) -> void:
	var top: Dictionary = state.stack[state.stack.size() - 1] if not state.stack.is_empty() else {}
	if str(top.get("k", "")) != "edit":
		return
	if ok:
		pop()
		_toast("Profile saved")
	else:
		_show_current(false)
		call_deferred("_set_edit_error", "That username is taken. Try another one." if why == "taken" else "Your username needs at least 3 characters.")


func _set_edit_error(t: String) -> void:
	if _edit_error and is_instance_valid(_edit_error):
		_edit_error.text = t
		_edit_error.get_parent().visible = t != ""


# ------------------------------------------------------------------ screen: settings

func _settings_screen() -> Control:
	var page := UiKit.pinned_page("Settings", pop)
	var content: VBoxContainer = page[1]
	content.add_child(UiKit.section_title("Account"))
	var acc: Array = UiKit.card()
	content.add_child(acc[0])
	var un := "@" + str(social.data.get("username", ""))
	var where := "Logged in with your password" if social.is_logged_in() else "This phone's account"
	acc[1].add_child(UiKit.setting_row("user-circle", un, where, "", UiKit.SKY_MEDIUM, func(): pass))
	acc[1].add_child(UiKit.setting_row("lock-closed", "Change password" if social.has_password() else "Set a password",
		"Log in on any phone and keep your account", "", UiKit.INK if not UiKit.dark else UiKit.SKY,
		func(): push({"k": "password"})))
	acc[1].add_child(UiKit.setting_row("device-phone-mobile", "Log in to another account", "Use an @username and password", "", UiKit.SKY_MEDIUM,
		func(): push({"k": "login"})))
	if social.is_logged_in():
		acc[1].add_child(UiKit.setting_row("arrow-uturn-left", "Log out", "Go back to this phone's own account", "", UiKit.PINK, func():
			social.logout()
			_toast("Logged out")
			_show_current(false)))
	content.add_child(UiKit.section_title("Appearance"))
	var th: Array = UiKit.card()
	content.add_child(th[0])
	var theme_row := HBoxContainer.new()
	theme_row.add_theme_constant_override("separation", 8)
	var cur := str(main.settings.get_value("p", "theme", "system"))
	for opt in [["system", "System"], ["light", "Light"], ["dark", "Dark"]]:
		var v: String = opt[0]
		theme_row.add_child(UiKit.chip(opt[1], cur == v, func(): main.set_theme(v)))
	var tcol := UiKit.vbox(8)
	tcol.add_child(UiKit.label("Theme", "title_medium", UiKit.c("on_surface")))
	tcol.add_child(theme_row)
	th[1].add_child(UiKit.margin(tcol, 16, 14, 16, 16))

	content.add_child(UiKit.section_title("Sound"))
	var sound: Array = UiKit.card()
	content.add_child(sound[0])
	sound[1].add_child(UiKit.setting_row("sparkles", "Music", "The walls dance to it, and gravity flips on the drop",
		"On" if main.music_on else "Off", UiKit.PINK, func():
			main.music_on = not main.music_on
			main.settings.set_value("p", "music", main.music_on)
			main.settings.save(main.SETTINGS_PATH)
			_show_current(false)))

	content.add_child(UiKit.section_title("Screen"))
	var screen_card: Array = UiKit.card()
	content.add_child(screen_card[0])
	var rot_row := HBoxContainer.new()
	rot_row.add_theme_constant_override("separation", 8)
	rot_row.add_child(UiKit.chip("Portrait", main.orientation == "portrait", func(): main._set_orientation("portrait")))
	rot_row.add_child(UiKit.chip("Landscape", main.orientation == "landscape", func(): main._set_orientation("landscape")))
	var rot_col := UiKit.vbox(8)
	rot_col.add_child(UiKit.label("Phone orientation", "title_medium", UiKit.c("on_surface")))
	rot_col.add_child(UiKit.label("Portrait is the default. You can also turn the screen from inside a game.", "body_medium", UiKit.c("on_surface_variant")))
	rot_col.add_child(rot_row)
	screen_card[1].add_child(UiKit.margin(rot_col, 16, 14, 16, 16))

	content.add_child(UiKit.section_title("Server"))
	var sv: Array = UiKit.text_field("Server address (wss://...)", main.server_url(), 200, "Used for online games, friends and chat")
	var server_edit: LineEdit = sv[1]
	server_edit.text_submitted.connect(func(t: String): main.set_server(t))
	server_edit.focus_exited.connect(func(): main.set_server(server_edit.text))
	content.add_child(sv[0])

	content.add_child(UiKit.section_title("About"))
	var ab: Array = UiKit.card()
	content.add_child(ab[0])
	ab[1].add_child(UiKit.setting_row("information-circle", "Plux", "Version %s" % str(ProjectSettings.get_setting("application/config/version", "")), "", UiKit.SKY_MEDIUM, func(): pass))
	_kb_spacer = UiKit.vspace(bottom_inset)
	content.add_child(_kb_spacer)
	content.add_child(UiKit.end_padding())
	return page[0]


# ------------------------------------------------------------------ screens: password and login

var _form_error: Label
var _form_button: Button


func _secret_field(placeholder: String, hint: String = "") -> Array:
	var f: Array = UiKit.text_field(placeholder, "", SocialHub.MAX_PW, hint)
	var e: LineEdit = f[1]
	e.secret = true
	e.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	return f


func _form_tail(content: VBoxContainer, button_text: String, icon_name: String) -> Button:
	_form_error = UiKit.label("", "body_medium", UiKit.c("error"))
	var err_box := UiKit.margin(_form_error, 20, 12, 20, 0)
	err_box.visible = false
	content.add_child(err_box)
	_form_button = UiKit.primary_button(button_text, icon_name, Callable())
	content.add_child(UiKit.margin(_form_button, 16, 16, 16, 0))
	_kb_spacer = UiKit.vspace(bottom_inset)
	content.add_child(_kb_spacer)
	content.add_child(UiKit.end_padding())
	return _form_button


func _set_form_error(t: String) -> void:
	if _form_error and is_instance_valid(_form_error):
		_form_error.text = t
		_form_error.get_parent().visible = t != ""
	if _form_button and is_instance_valid(_form_button):
		_form_button.disabled = false


func _password_screen() -> Control:
	var changing := social.has_password()
	var page := UiKit.pinned_page("Change password" if changing else "Set a password", pop)
	var content: VBoxContainer = page[1]
	var intro := UiKit.label("With a password you can log in as @%s on another phone, or after reinstalling the app. Your friends, follows and chats come with you." % str(social.data.username),
		"body_medium", UiKit.c("on_surface_variant"))
	content.add_child(UiKit.margin(intro, 20, 16, 20, 8))
	var old_f: LineEdit = null
	if changing:
		content.add_child(UiKit.section_title("Current password"))
		var of: Array = _secret_field("Current password")
		old_f = of[1]
		content.add_child(of[0])
	content.add_child(UiKit.section_title("New password"))
	var nf: Array = _secret_field("New password", "At least %d characters" % SocialHub.MIN_PW)
	var new_f: LineEdit = nf[1]
	content.add_child(nf[0])
	content.add_child(UiKit.section_title("Type it again"))
	var rf: Array = _secret_field("New password again")
	var rep_f: LineEdit = rf[1]
	content.add_child(rf[0])
	var btn := _form_tail(content, "Save password", "lock-closed")
	btn.pressed.connect(func():
		if new_f.text.length() < SocialHub.MIN_PW:
			_set_form_error("Your password needs at least %d characters." % SocialHub.MIN_PW)
			return
		if new_f.text != rep_f.text:
			_set_form_error("The two passwords don't match.")
			return
		_set_form_error("")
		if not social.set_password(new_f.text, old_f.text if old_f else ""):
			_set_form_error("You're offline. Try again when you're connected.")
			return
		btn.disabled = true)
	return page[0]


func _on_password_saved(ok: bool, why: String) -> void:
	var top: Dictionary = state.stack[state.stack.size() - 1] if not state.stack.is_empty() else {}
	if str(top.get("k", "")) != "password":
		return
	if ok:
		pop()
		_toast("Password saved. Log in as @%s on any phone." % str(social.data.username))
		return
	match why:
		"old_wrong": _set_form_error("Your current password is wrong.")
		"no_username": _set_form_error("Pick a username first, in Edit profile.")
		_: _set_form_error("Your password needs at least %d characters." % SocialHub.MIN_PW)


func _login_screen() -> Control:
	var page := UiKit.pinned_page("Log in", pop)
	var content: VBoxContainer = page[1]
	var intro := UiKit.label("Log in to an account that has a password. This phone's own account stays saved, and Log out in Settings brings it back.",
		"body_medium", UiKit.c("on_surface_variant"))
	content.add_child(UiKit.margin(intro, 20, 16, 20, 8))
	content.add_child(UiKit.section_title("Username"))
	var uf: Array = UiKit.text_field("username", "", 21, "")
	var user_f: LineEdit = uf[1]
	user_f.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
	content.add_child(uf[0])
	content.add_child(UiKit.section_title("Password"))
	var pf: Array = _secret_field("Password")
	var pw_f: LineEdit = pf[1]
	content.add_child(pf[0])
	var btn := _form_tail(content, "Log in", "check")
	var go := func():
		var un := SocialHub.clean_username(user_f.text.strip_edges().trim_prefix("@"))
		if un.length() < 3 or pw_f.text == "":
			_set_form_error("Type the username and the password.")
			return
		_set_form_error("")
		btn.disabled = true
		btn.text = "Logging in..."
		social.login(un, pw_f.text)
	btn.pressed.connect(go)
	pw_f.text_submitted.connect(func(_t): go.call())
	return page[0]


func _on_login_done(ok: bool, why: String) -> void:
	var top: Dictionary = state.stack[state.stack.size() - 1] if not state.stack.is_empty() else {}
	if str(top.get("k", "")) != "login":
		return
	if ok:
		select_tab(3)
		_toast("Logged in as @%s" % str(social.data.username))
		return
	if _form_button and is_instance_valid(_form_button):
		_form_button.text = "Log in"
	match why:
		"slow": _set_form_error("Too many tries. Wait a few minutes and try again.")
		"offline": _set_form_error("Couldn't reach the server. The free server may be waking up, so try again in a minute.")
		_: _set_form_error("That username and password don't match.")


# ------------------------------------------------------------------ notices

func _on_notice(kind: String, who: Dictionary) -> void:
	var n := str(who.get("name", "Someone"))
	var top: Dictionary = state.stack[state.stack.size() - 1] if not state.stack.is_empty() else {}
	if str(top.get("k", "")) == "user" and str(top.get("uid", "")) == str(who.get("uid", "")):
		social.get_user(str(top.uid))   # their counts changed
	match kind:
		"request": _toast("%s sent you a friend request" % n)
		"friends": _toast("You and %s are now friends" % n)
		"follow": _toast("%s started following you" % n)


# ------------------------------------------------------------------ Plux and the avatar shop (0.6.0)

var _shop_slot := ""      # "" shows every slot
var _shop_busy := ""      # item id waiting for the server
var _item_status: Label


static func _fmt_plux(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## The coin and a number, side by side.
func _plux_amount(n: int, token := "title_small", coin := 18.0, col: Color = Color(0, 0, 0, 0)) -> Control:
	var h := UiKit.hbox(5)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var c := ItemArt.plux(coin)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(c)
	var l := UiKit.label(_fmt_plux(n), token, col if col.a > 0 else UiKit.c("on_surface"), false)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(l)
	return h


## Balance pill for top bars; tapping it opens the shop.
func _plux_pill() -> Control:
	var row := UiKit.TapRow.new()
	row.on_tap = func(): push({"k": "shop"})
	row.add_theme_stylebox_override("panel", UiKit.pad(UiKit.box(UiKit.c("surface_container_high"), 50), 10, 6))
	row.add_child(_plux_amount(int(social.eco.get("coins", 0)), "label_large", 18))
	row.get_child(0).mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return row


func _wire_eco() -> void:
	if social.eco_changed.is_connected(_mark_dirty):
		return
	social.eco_changed.connect(_mark_dirty)
	social.plux_earned.connect(_on_plux_earned)
	social.reply.connect(_on_reply)
	social.banned.connect(func(text: String): _toast(text))


func _on_plux_earned(amount: int, why: String) -> void:
	if amount <= 0:
		return
	var words := {"daily": "daily reward", "round": "playing a round", "win": "winning", "publish": "publishing"}
	_toast("+%s Plux for %s" % [_fmt_plux(amount), words.get(why, why)] if words.has(why) else "+%s Plux" % _fmt_plux(amount))


func _on_reply(t: String, msg: Dictionary) -> void:
	match t:
		"s_buy_res":
			_shop_busy = ""
			if bool(msg.get("ok", false)):
				var it: Dictionary = social.shop_by_id.get(str(msg.get("item", "")), {})
				var serial := int(msg.get("serial", 0))
				_toast("You got %s%s. Tap Wear to put it on." % [str(it.get("name", "it")), (" #%d" % serial) if serial > 0 else ""])
			else:
				_set_item_status(str(msg.get("why", "Couldn't buy that. Try again.")))
			_mark_dirty()
		"s_daily_res":
			if not bool(msg.get("ok", false)):
				_toast("You already got today's reward. Come back tomorrow.")
			_mark_dirty()
		"s_equip_res":
			_shop_busy = ""
			_mark_dirty()


func _set_item_status(t: String) -> void:
	if _item_status and is_instance_valid(_item_status):
		_item_status.text = t
		_item_status.visible = t != ""


func _claim_daily() -> void:
	_act(social.request({"t": "s_daily"}))


## Home and Profile: balance, today's reward and a way into the shop.
func _wallet_card() -> Control:
	var card: Array = UiKit.card()
	var h := UiKit.hbox(12)
	var coin := ItemArt.plux(40)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(coin)
	var col := UiKit.vbox(0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UiKit.label(_fmt_plux(int(social.eco.get("coins", 0))) + " Plux", "title_large", UiKit.c("on_surface"), false))
	var sub := ("Daily reward ready" if bool(social.eco.get("daily_ready", false)) else "Play to earn more") if social.is_online() else "Offline"
	var sl := UiKit.label(sub, "body_small", UiKit.c("on_surface_variant"), false)
	sl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sl.clip_text = true
	col.add_child(sl)
	h.add_child(col)
	var actions := UiKit.hbox(8)
	actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if bool(social.eco.get("daily_ready", false)) and social.is_online():
		actions.add_child(UiKit.small_button("Get %d" % int(social.eco.get("daily", 0)), true, _claim_daily, "sparkles"))
	elif social.feature("shop"):
		actions.add_child(UiKit.small_button("Shop", false, func(): push({"k": "shop"}), "tag"))
	if social.feature("buy_plux") or social.feature("pro"):
		actions.add_child(UiKit.icon_button("plus", func(): push({"k": "store"})))
	h.add_child(actions)
	card[1].add_child(UiKit.margin(h, 16, 14, 14, 14))
	return card[0]


func _slot_of(id: String) -> String:
	return str(social.shop_by_id.get(id, {}).get("slot", ""))


func _is_worn(id: String) -> bool:
	return id in social.eco.get("eq", [])


## Puts an item on (replacing whatever is in its slot) or takes it off.
func _toggle_wear(id: String) -> void:
	var eq: Array = social.eco.get("eq", []).duplicate()
	if id in eq:
		eq.erase(id)
	else:
		var slot := _slot_of(id)
		for other in eq.duplicate():
			if _slot_of(str(other)) == slot:
				eq.erase(other)
		eq.append(id)
	_shop_busy = id
	if not social.request({"t": "s_equip", "eq": eq}):
		_shop_busy = ""
		_offline_toast()
	_mark_dirty()


func _buy(id: String) -> void:
	_set_item_status("")
	_shop_busy = id
	if not social.request({"t": "s_buy", "item": id}):
		_shop_busy = ""
		_offline_toast()
	_mark_dirty()


## One shop tile: the item drawn alone, its name and price (or Owned / Wearing).
func _item_tile(it: Dictionary, w: float) -> Control:
	var id := str(it.get("id", ""))
	var row := UiKit.TapRow.new()
	row.on_tap = func(): push({"k": "item", "id": id})
	row.custom_minimum_size = Vector2(w, 0)
	row.add_theme_stylebox_override("panel", UiKit.box(UiKit.c("surface_container"), 20, UiKit.c("outline_variant"), 1))
	var col := UiKit.vbox(4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var art_bg := PanelContainer.new()
	art_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_bg.add_theme_stylebox_override("panel", UiKit.box(UiKit.c("surface_container_high"), 14))
	var art := ItemArt.over(minf(w - 36, 84), [{"art": it.get("art", ""), "col": it.get("col", "#FFFFFF"), "slot": it.get("slot", "")}])
	art.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	art_bg.add_child(UiKit.margin(art, 4, 6, 4, 6))
	col.add_child(art_bg)
	var nm := UiKit.label(str(it.get("name", "")), "title_small", UiKit.c("on_surface"), false)
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.clip_text = true
	col.add_child(nm)
	if social.owns_item(id):
		var t := "Wearing" if _is_worn(id) else "Owned"
		col.add_child(UiKit.label(t, "label_medium", UiKit.c("tertiary") if _is_worn(id) else UiKit.c("on_surface_variant"), false))
	elif it.has("left") and int(it.left) <= 0:
		col.add_child(UiKit.label("Sold out", "label_medium", UiKit.c("error"), false))
	else:
		col.add_child(_plux_amount(int(it.get("price", 0)), "label_large", 16))
	if bool(it.get("rare", false)):
		var rare := UiKit.label("LIMITED" if not it.has("left") else "LIMITED · %d left" % int(it.left), "label_small", UiKit.PINK, false)
		col.add_child(rare)
	row.add_child(UiKit.margin(col, 8, 8, 8, 10))
	row.get_child(0).mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.add_press_shrink_row(row)
	return row


func _tile_grid(list: Array) -> Control:
	var avail := minf(maxf(size.x - (92.0 if wide else 0.0), 320.0), 760.0) - 32.0
	var cols := clampi(int(avail / 150.0), 2, 5)
	var gap := 10.0
	var w := floorf((avail - gap * (cols - 1)) / cols)
	var grid := GridContainer.new()
	grid.columns = cols
	grid.add_theme_constant_override("h_separation", int(gap))
	grid.add_theme_constant_override("v_separation", int(gap))
	for it in list:
		grid.add_child(_item_tile(it, w))
	return UiKit.margin(grid, 16, 0, 16, 0)


func _shop_screen() -> Control:
	var page := UiKit.pinned_page("Shop", pop, null, [_plux_pill_live()])
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	if social.shop.is_empty():
		social.request({"t": "s_eco"})
	_live(live, func(box: VBoxContainer):
		var cc := _connection_card()
		if cc:
			box.add_child(cc)
		box.add_child(UiKit.margin(_wallet_card(), 0, 8, 0, 0))
		if not social.feature("shop"):
			box.add_child(UiKit.margin(UiKit.empty_state("tag", "The shop is closed", "It'll be back soon."), 16, 16, 16, 0))
			return
		var chips := HFlowContainer.new()
		chips.add_theme_constant_override("h_separation", 8)
		chips.add_theme_constant_override("v_separation", 8)
		chips.add_child(UiKit.chip("All", _shop_slot == "", func(): _shop_slot = ""; _mark_dirty()))
		for s in PloxCatalog.SLOTS:
			var slot: String = s
			chips.add_child(UiKit.chip(PloxCatalog.SLOT_NAMES[slot], _shop_slot == slot, func(): _shop_slot = slot; _mark_dirty()))
		var mine := UiKit.chip("My items", _shop_slot == "mine", func(): _shop_slot = "mine"; _mark_dirty())
		chips.add_child(mine)
		box.add_child(UiKit.margin(chips, 16, 16, 16, 4))
		var list := []
		for it in social.shop:
			var id := str(it.get("id", ""))
			if _shop_slot == "mine":
				if social.owns_item(id):
					list.append(it)
			elif _shop_slot == "" or str(it.get("slot", "")) == _shop_slot:
				list.append(it)
		if social.shop.is_empty():
			var msg := "Loading the shop..." if social.is_online() else "Connect to the internet to see the shop."
			box.add_child(UiKit.margin(UiKit.empty_state("tag", "Nothing here yet", msg), 16, 16, 16, 0))
		elif list.is_empty():
			box.add_child(UiKit.margin(UiKit.empty_state("cube", "No items yet", "Things you buy show up here. Tap an item to wear it."), 16, 16, 16, 0))
		else:
			if _shop_slot == "":
				var rare := []
				var rest := []
				for it in list:
					(rare if bool(it.get("rare", false)) else rest).append(it)
				if not rare.is_empty():
					box.add_child(UiKit.section_title("Limited"))
					box.add_child(_tile_grid(rare))
				box.add_child(UiKit.section_title("Everything"))
				box.add_child(_tile_grid(rest))
			else:
				box.add_child(UiKit.vspace(8))
				box.add_child(_tile_grid(list))
		box.add_child(UiKit.margin(UiKit.label("Plux are earned by playing and from the daily reward. You can't buy them with real money.",
			"body_small", UiKit.c("on_surface_variant")), 20, 16, 20, 0))
	)
	return page[0]


## The balance in a top bar; _do_refresh redraws it when the Plux change.
var _pill_holder: MarginContainer


func _plux_pill_live() -> Control:
	_pill_holder = MarginContainer.new()
	_pill_holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_pill_holder.add_child(_plux_pill())
	return _pill_holder


func _refresh_pill() -> void:
	if _pill_holder and is_instance_valid(_pill_holder):
		for ch in _pill_holder.get_children():
			ch.queue_free()
		_pill_holder.add_child(_plux_pill())


func _item_screen(id: String) -> Control:
	var it: Dictionary = social.shop_by_id.get(id, {})
	var page := UiKit.pinned_page(str(it.get("name", "Item")), pop, null, [_plux_pill_live()])
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	_item_status = null
	_live(live, func(box: VBoxContainer):
		it = social.shop_by_id.get(id, {})
		if it.is_empty():
			box.add_child(UiKit.margin(UiKit.empty_state("tag", "Item not found", "It may have left the shop."), 16, 16, 16, 0))
			return
		var owns := social.owns_item(id)
		var worn := _is_worn(id)
		# Preview: you, wearing what you have on now plus this item in its slot.
		var eq := []
		for e in social.eco.get("eq", []):
			if social.shop_by_id.has(e) and _slot_of(str(e)) != str(it.slot):
				var s: Dictionary = social.shop_by_id[e]
				eq.append({"art": s.art, "col": s.col, "slot": s.slot})
		eq.append({"art": it.art, "col": it.col, "slot": it.slot})
		var stage := PanelContainer.new()
		stage.add_theme_stylebox_override("panel", UiKit.box(UiKit.c("surface_container"), 24, UiKit.c("outline_variant"), 1))
		var dressed := ItemArt.dressed(168, str(social.data.name), int(social.data.get("av", -1)), eq)
		dressed.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		stage.add_child(UiKit.margin(dressed, 16, 22, 16, 22))
		box.add_child(UiKit.margin(stage, 16, 8, 16, 0))
		var info := UiKit.vbox(6)
		var tags := UiKit.hbox(8)
		tags.add_child(UiKit.label(str(PloxCatalog.SLOT_NAMES.get(str(it.slot), "Item")).to_upper(), "section", UiKit.c("primary"), false))
		if bool(it.get("rare", false)):
			tags.add_child(UiKit.label("LIMITED", "section", UiKit.PINK, false))
		info.add_child(tags)
		info.add_child(UiKit.label(str(it.name), "headline_small", UiKit.c("on_surface")))
		if owns:
			var serial := 0
			for o in social.eco.get("inv", []):
				if str(o.get("item", "")) == id:
					serial = int(o.get("serial", 0))
			info.add_child(UiKit.label("You own this%s." % ((" (#%d)" % serial) if serial > 0 else ""), "body_medium", UiKit.c("on_surface_variant")))
		else:
			info.add_child(_plux_amount(int(it.price), "title_large", 26))
			if it.has("left"):
				info.add_child(UiKit.label("%d of %d left" % [int(it.left), int(it.get("stock", 0))] if int(it.get("stock", 0)) > 0 else "%d left" % int(it.left),
					"body_medium", UiKit.c("on_surface_variant")))
		box.add_child(UiKit.margin(info, 20, 16, 20, 0))
		var btn: Button
		var busy := _shop_busy == id
		if owns:
			btn = UiKit.primary_button("Take off" if worn else "Wear", "check" if not worn else "x-mark", func(): _toggle_wear(id))
		else:
			var coins := int(social.eco.get("coins", 0))
			var sold_out := it.has("left") and int(it.left) <= 0
			var btext := "Sold out" if sold_out else ("Buy for %s Plux" % _fmt_plux(int(it.price)) if coins >= int(it.price) else "Need %s more Plux" % _fmt_plux(int(it.price) - coins))
			btn = UiKit.primary_button(btext, "tag", func(): _buy(id))
			btn.disabled = sold_out or coins < int(it.price) or not social.is_online()
		if busy:
			btn.disabled = true
			btn.text = "One moment..."
		box.add_child(UiKit.margin(btn, 16, 18, 16, 0))
		_item_status = UiKit.label("", "body_medium", UiKit.c("error"))
		_item_status.visible = false
		box.add_child(UiKit.margin(_item_status, 20, 10, 20, 0))
		if not social.is_online():
			box.add_child(UiKit.margin(UiKit.label("You're offline. Connect to buy or wear items.", "body_small", UiKit.c("on_surface_variant")), 20, 10, 20, 0))
		elif bool(it.get("rare", false)) and not owns:
			box.add_child(UiKit.margin(UiKit.label("Limited items are numbered and won't come back once they sell out.", "body_small", UiKit.c("on_surface_variant")), 20, 10, 20, 0))
	)
	return page[0]


## The items a person has on, as the cards ItemArt draws.
func _eq(u: Dictionary) -> Array:
	var e = u.get("eq", [])
	if u.get("uid", "") == social.uid:
		return social.equipped_cards()
	return e if e is Array else []
