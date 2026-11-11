class_name InvitePicker
extends Control
## A bottom sheet over the game or the app: tick friends, tap Invite. Online friends
## first. The server only sends invites to friends, and to online ones right away.

signal closed
signal toast(text: String)

var social: SocialClient
var what := ""
var room := ""
var gid := ""
var _picked := {}
var _list: VBoxContainer
var _send_btn: Button
var _sheet: PanelContainer
var _rid := -1


func setup(p_social: SocialClient, p_what: String, p_room: String, p_gid: String) -> void:
	social = p_social
	what = p_what
	room = p_room
	gid = p_gid


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			_close())
	add_child(dim)
	_sheet = PanelContainer.new()
	var sb := UiKit.box(UiKit.c("surface_container"), 28)
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	_sheet.add_theme_stylebox_override("panel", sb)
	_sheet.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_sheet.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(_sheet)
	var col := UiKit.vbox(0)
	var title: String = {"pop": "Pop-Up Panic", "neon": "Neon Bounce"}.get(what, "this game")
	col.add_child(UiKit.margin(UiKit.label("Invite friends", "title_large", UiKit.c("on_surface")), 20, 18, 20, 0))
	col.add_child(UiKit.margin(UiKit.label("They'll get a tap-to-join invite to %s." % title, "body_medium", UiKit.c("on_surface_variant")), 20, 4, 20, 8))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var h := get_viewport_rect().size.y
	scroll.custom_minimum_size = Vector2(0, clampf(h * 0.42, 160, 520))
	_list = UiKit.vbox()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	col.add_child(scroll)
	_send_btn = UiKit.primary_button("Invite", "paper-airplane", _send)
	col.add_child(UiKit.margin(_send_btn, 16, 10, 16, 0))
	col.add_child(UiKit.margin(UiKit.text_button("Close", UiKit.c("primary"), _close), 16, 4, 16, 0))
	var inset := DisplayServer.get_display_safe_area()
	var bottom := maxf(0.0, DisplayServer.screen_get_size().y - inset.end.y) / maxf(get_viewport().get_final_transform().get_scale().y, 0.01)
	col.add_child(UiKit.vspace(maxf(12.0, bottom + 8.0)))
	_sheet.add_child(col)
	_fill()
	social.reply.connect(_on_reply)
	_sheet.position.y += 400
	var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_sheet, "position:y", _sheet.position.y - 400, 0.22)


func _fill() -> void:
	for ch in _list.get_children():
		ch.queue_free()
	var fr: Array = social.data.friends.values()
	fr.sort_custom(func(a, b):
		if bool(a.get("online", false)) != bool(b.get("online", false)):
			return bool(a.get("online", false))
		return str(a.get("name", "")).nocasecmp_to(str(b.get("name", ""))) < 0)
	if fr.is_empty():
		_list.add_child(UiKit.margin(UiKit.empty_state("user-plus", "No friends yet", "Add friends from Home, then invite them here."), 16, 8, 16, 8))
		_send_btn.disabled = true
		return
	for f in fr:
		var u: Dictionary = f
		var w := str(u.get("uid", ""))
		var on := bool(u.get("online", false))
		var tick := CheckBox.new()
		tick.button_pressed = _picked.has(w)
		tick.focus_mode = Control.FOCUS_NONE
		tick.toggled.connect(func(v): _toggle(w, v))
		var row := UiKit.person_row(str(u.get("name", "Player")), "Online" if on else "Offline: they'll miss it", on,
			func(): tick.button_pressed = not tick.button_pressed, [tick], UiKit.SUCCESS if on else Color(0, 0, 0, 0), int(u.get("av", -1)), u.get("eq", []) if u.get("eq") is Array else [])
		_list.add_child(row)
	_update_btn()


func _toggle(w: String, v: bool) -> void:
	if v:
		_picked[w] = true
	else:
		_picked.erase(w)
	_update_btn()


func _update_btn() -> void:
	_send_btn.disabled = _picked.is_empty() or _rid != -1
	_send_btn.text = "Invite" if _picked.size() <= 1 else "Invite %d friends" % _picked.size()


func _send() -> void:
	if _picked.is_empty():
		return
	var msg := {"t": "s_invite", "to": _picked.keys(), "what": what, "room": room, "gid": gid}
	if not social.request(msg):
		toast.emit("You're offline. Try again in a moment.")
		return
	_rid = int(msg.rid)
	_send_btn.text = "Sending..."
	_send_btn.disabled = true


func _on_reply(t: String, msg: Dictionary) -> void:
	if t != "s_invite_res" or int(msg.get("rid", -2)) != _rid:
		return
	_rid = -1
	if bool(msg.get("ok", false)):
		var sent := int(msg.get("sent", 0))
		var off := int(msg.get("offline", 0))
		var text := "Invite sent" if sent == 1 else "%d invites sent" % sent
		if off > 0:
			text = (text + ". " if sent > 0 else "") + ("%d friend%s offline" % [off, "" if off == 1 else "s"] + (" didn't get it" if sent == 0 else ""))
		toast.emit(text)
		_close()
	else:
		toast.emit(str(msg.get("why", "Couldn't send the invite.")))
		_update_btn()


func _close() -> void:
	if social.reply.is_connected(_on_reply):
		social.reply.disconnect(_on_reply)
	closed.emit()
	queue_free()
