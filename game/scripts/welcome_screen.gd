class_name WelcomeScreen
extends Control
## 0.7.0: first screen on a phone with no account. Sign up (username checked live,
## password, birthday, optional email and invite code) or Log in.

var social: SocialClient
var mode := "start"     # start, signup, login
var _busy := false
var _name_state := ""   # "", "checking", "ok", or the problem
var _name_timer: Timer
var _vals := {"username": "", "password": "", "email": "", "invite": "", "y": 0, "m": 0, "d": 0}
var _err := ""
var _err_field := ""
var _scroll: ScrollContainer
var _box: VBoxContainer
var _name_hint: Label
var _waking_at := 0


func _init(p_social: SocialClient) -> void:
	social = p_social
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	_name_timer = Timer.new()
	_name_timer.one_shot = true
	_name_timer.wait_time = 0.45
	_name_timer.timeout.connect(func():
		if _vals.username.length() >= 3:
			_name_state = "checking"
			_update_name_hint()
			social.pre_send({"t": "s_name_check", "username": _vals.username}))
	add_child(_name_timer)
	social.pre_reply.connect(_on_reply)
	var bg := ColorRect.new()
	bg.color = UiKit.c("surface")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_render()


func _on_reply(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"s_name_res", "s_name_check_res":
			if str(msg.get("username", "")) != _vals.username and msg.has("username"):
				return
			if msg.get("ok", false):
				_name_state = "ok"
			else:
				var why := str(msg.get("why", ""))
				_name_state = "" if why in ["offline", "slow"] else why
			_update_name_hint()
		"s_signup_res", "s_login_res":
			_busy = false
			_waking_at = 0
			if msg.get("ok", false):
				return   # the shell swaps this screen for the app
			var why := str(msg.get("why", ""))
			_err_field = str(msg.get("field", ""))
			match why:
				"wrong": _err = "That username and password don't match."
				"slow": _err = "Too many tries. Wait a few minutes, then try again."
				"offline": _err = "Couldn't reach Plux. Check your internet and try again."
				_: _err = why if why != "" else "Something went wrong. Try again."
			_render()


func _update_name_hint() -> void:
	if _name_hint == null or not is_instance_valid(_name_hint):
		return
	match _name_state:
		"":
			_name_hint.text = "3 to 20 letters, numbers or _"
			_name_hint.add_theme_color_override("font_color", UiKit.c("on_surface_variant"))
		"checking":
			_name_hint.text = "Checking..."
			_name_hint.add_theme_color_override("font_color", UiKit.c("on_surface_variant"))
		"ok":
			_name_hint.text = "@%s is free" % _vals.username
			_name_hint.add_theme_color_override("font_color", Color("#2E9E5B"))
		_:
			_name_hint.text = _name_state
			_name_hint.add_theme_color_override("font_color", UiKit.c("error"))


func _render() -> void:
	if _box and is_instance_valid(_box):
		_box.queue_free()
	_box = UiKit.vbox(0)
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var inner := UiKit.vbox(0)
	inner.custom_minimum_size = Vector2(minf(440.0, maxf(280.0, size.x - 8.0)), 0)
	center.add_child(inner)
	_box.add_child(center)
	_scroll.add_child(_box)
	match mode:
		"start": _start(inner)
		"signup": _signup(inner)
		"login": _login(inner)
	inner.add_child(UiKit.vspace(320))   # room for the keyboard


func _logo(box: VBoxContainer, big: bool) -> void:
	var holder := CenterContainer.new()
	var tile := PanelContainer.new()
	var sz := 88.0 if big else 56.0
	tile.custom_minimum_size = Vector2(sz, sz)
	tile.add_theme_stylebox_override("panel", UiKit.box(UiKit.c("primary"), sz * 0.28))
	var p := UiKit.label("P", "display_small" if big else "headline_large", Color.WHITE, false)
	p.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tile.add_child(p)
	holder.add_child(tile)
	box.add_child(UiKit.margin(holder, 0, 48 if big else 24, 0, 16))


func _center_label(text: String, style: String, col: Color) -> Label:
	var l := UiKit.label(text, style, col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _start(box: VBoxContainer) -> void:
	_logo(box, true)
	box.add_child(UiKit.margin(_center_label("Welcome to Plux", "headline_large", UiKit.c("on_surface")), 24, 0, 24, 8))
	box.add_child(UiKit.margin(_center_label("Play games with friends, chat, and build your own games with words.", "body_large", UiKit.c("on_surface_variant")), 24, 0, 24, 32))
	box.add_child(UiKit.margin(UiKit.primary_button("Sign up", "user-plus", func(): _go("signup")), 24, 0, 24, 12))
	box.add_child(UiKit.margin(UiKit.outline_button("Log in", "lock-closed", func(): _go("login")), 24, 0, 24, 0))


func _go(m: String) -> void:
	mode = m
	_err = ""
	_err_field = ""
	_render()


func _header(box: VBoxContainer, title: String) -> void:
	var h := UiKit.hbox(4)
	h.add_child(UiKit.icon_button("arrow-left", func(): _go("start")))
	h.add_child(UiKit.label(title, "title_large", UiKit.c("on_surface"), false))
	box.add_child(UiKit.margin(h, 8, 12, 16, 8))


func _field(box: VBoxContainer, key: String, placeholder: String, max_len: int, secret := false, hint := "") -> LineEdit:
	var f: Array = UiKit.text_field(placeholder, str(_vals[key]), max_len, hint if _err_field != key else _err)
	var e: LineEdit = f[1]
	e.secret = secret
	e.text_changed.connect(func(t):
		_vals[key] = t.strip_edges() if key != "password" else t)
	box.add_child(f[0])
	return e


func _signup(box: VBoxContainer) -> void:
	_header(box, "Sign up")
	box.add_child(UiKit.margin(UiKit.label("Pick a username", "title_small", UiKit.c("on_surface"), false), 20, 8, 20, 4))
	var f: Array = UiKit.text_field("Username", _vals.username, 20)
	var ue: LineEdit = f[1]
	ue.text_changed.connect(func(t):
		var clean := SocialHub.clean_username(t.strip_edges().trim_prefix("@"))
		_vals.username = clean
		_name_state = ""
		_update_name_hint()
		_name_timer.start())
	box.add_child(f[0])
	_name_hint = UiKit.label("", "body_small", UiKit.c("on_surface_variant"))
	box.add_child(UiKit.margin(_name_hint, 24, 4, 20, 0))
	_update_name_hint()
	if _err_field == "username":
		_name_hint.text = _err
		_name_hint.add_theme_color_override("font_color", UiKit.c("error"))
	box.add_child(UiKit.margin(UiKit.label("Password", "title_small", UiKit.c("on_surface"), false), 20, 14, 20, 4))
	_field(box, "password", "At least %d characters" % SocialHub.MIN_PW, SocialHub.MAX_PW, true)
	box.add_child(UiKit.margin(UiKit.label("Birthday", "title_small", UiKit.c("on_surface"), false), 20, 14, 20, 4))
	box.add_child(UiKit.margin(_birthday_row(), 16, 0, 16, 0))
	if _err_field == "birthday":
		box.add_child(UiKit.margin(UiKit.label(_err, "body_small", UiKit.c("error")), 24, 4, 20, 0))
	box.add_child(UiKit.margin(UiKit.label("We use it to keep Plux right for your age. It isn't shown to anyone.", "body_small", UiKit.c("on_surface_variant")), 24, 4, 20, 0))
	box.add_child(UiKit.margin(UiKit.label("Email (optional)", "title_small", UiKit.c("on_surface"), false), 20, 14, 20, 4))
	var ee := _field(box, "email", "you@example.com", 120, false, "Only for getting back into your account")
	ee.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS
	box.add_child(UiKit.margin(UiKit.label("Invite code (optional)", "title_small", UiKit.c("on_surface"), false), 20, 14, 20, 4))
	_field(box, "invite", "From a friend's invite", 16, false, "You'll be friends straight away")
	if _err != "" and not (_err_field in ["username", "birthday", "password", "email"]):
		box.add_child(UiKit.margin(UiKit.label(_err, "body_medium", UiKit.c("error")), 24, 12, 20, 0))
	var go := UiKit.primary_button(_busy_text("Create account"), "check", _do_signup)
	go.disabled = _busy
	box.add_child(UiKit.margin(go, 16, 20, 16, 0))
	box.add_child(UiKit.margin(UiKit.text_button("I already have an account", UiKit.c("primary"), func(): _go("login")), 16, 8, 16, 0))


func _busy_text(idle: String) -> String:
	if not _busy:
		return idle
	if _waking_at > 0 and Time.get_ticks_msec() - _waking_at > 4000:
		return "Waking the server up..."
	return "One moment..."


func _birthday_row() -> Control:
	var h := UiKit.hbox(8)
	var months := ["Month", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var mo := _picker(months, int(_vals.m))
	mo.item_selected.connect(func(i): _vals.m = i)
	h.add_child(mo)
	var days := ["Day"]
	for d in range(1, 32):
		days.append(str(d))
	var dp := _picker(days, int(_vals.d))
	dp.item_selected.connect(func(i): _vals.d = i)
	h.add_child(dp)
	var years := ["Year"]
	var this_year := int(Time.get_date_dict_from_system().year)
	for y in range(this_year, this_year - 100, -1):
		years.append(str(y))
	var yp := _picker(years, 0 if int(_vals.y) == 0 else this_year - int(_vals.y) + 1)
	yp.item_selected.connect(func(i): _vals.y = 0 if i == 0 else this_year - i + 1)
	h.add_child(yp)
	return h


func _picker(items: Array, sel: int) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it))
	o.select(sel)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.custom_minimum_size = Vector2(0, 52)
	o.add_theme_font_size_override("font_size", 16)
	var sb := UiKit.pad(UiKit.box(UiKit.c("surface_container_highest"), 14), 12, 6)
	for st in ["normal", "hover", "pressed", "focus"]:
		o.add_theme_stylebox_override(st, sb)
	o.add_theme_color_override("font_color", UiKit.c("on_surface"))
	return o


func _do_signup() -> void:
	if _busy:
		return
	_err = ""
	_err_field = ""
	if _vals.username.length() < 3:
		_err = "Pick a username with at least 3 characters."
		_err_field = "username"
	elif _vals.password.length() < SocialHub.MIN_PW:
		_err = "Password must be at least %d characters." % SocialHub.MIN_PW
		_err_field = "password"
	elif int(_vals.y) == 0 or int(_vals.m) == 0 or int(_vals.d) == 0:
		_err = "Pick your birthday."
		_err_field = "birthday"
	if _err != "":
		_render()
		return
	_busy = true
	_waking_at = Time.get_ticks_msec()
	social.pre_send({"t": "s_signup", "username": _vals.username, "password": _vals.password,
		"birthday": "%04d-%02d-%02d" % [int(_vals.y), int(_vals.m), int(_vals.d)], "email": _vals.email,
		"invite": _vals.invite.to_upper(), "name": _vals.username, "key": str(social.data.get("key", ""))})
	_render()
	_tick_busy()


func _tick_busy() -> void:
	# Change the button to "Waking the server up..." if the free server is asleep.
	await get_tree().create_timer(4.5).timeout
	if _busy and is_inside_tree():
		_render()


func _login(box: VBoxContainer) -> void:
	_header(box, "Log in")
	box.add_child(UiKit.margin(UiKit.label("Username", "title_small", UiKit.c("on_surface"), false), 20, 8, 20, 4))
	_field(box, "username", "@username", 21)
	box.add_child(UiKit.margin(UiKit.label("Password", "title_small", UiKit.c("on_surface"), false), 20, 14, 20, 4))
	var pe := _field(box, "password", "Password", SocialHub.MAX_PW, true)
	pe.text_submitted.connect(func(_t): _do_login())
	if _err != "":
		box.add_child(UiKit.margin(UiKit.label(_err, "body_medium", UiKit.c("error")), 24, 12, 20, 0))
	var go := UiKit.primary_button(_busy_text("Log in"), "lock-closed", _do_login)
	go.disabled = _busy
	box.add_child(UiKit.margin(go, 16, 20, 16, 0))
	box.add_child(UiKit.margin(UiKit.label("Forgot your password? Ask the Plux team to reset it, then log in with the new one.", "body_small", UiKit.c("on_surface_variant")), 24, 12, 20, 0))
	box.add_child(UiKit.margin(UiKit.text_button("Make a new account", UiKit.c("primary"), func(): _go("signup")), 16, 8, 16, 0))


func _do_login() -> void:
	if _busy:
		return
	var un := str(_vals.username).trim_prefix("@")
	if un.length() < 3 or str(_vals.password) == "":
		_err = "Enter your username and password."
		_render()
		return
	_err = ""
	_busy = true
	_waking_at = Time.get_ticks_msec()
	social.pre_send({"t": "s_login", "username": un, "password": _vals.password})
	_render()
	_tick_busy()
