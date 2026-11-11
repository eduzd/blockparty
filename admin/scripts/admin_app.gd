extends Node
## Plux Admin 1.0: sign in, dashboard, Studio AI settings, Studio Builder agent rules.
## Everything is checked and stored on the server; the app only shows and sends.

const C := AdminUi.C

var net: AdminNet
var ui: Control           # full-screen root, rebuilt per screen
var page := "dash"        # dash, ai, agents
var body: VBoxContainer   # scroll content of the current page
var scroll: ScrollContainer
var kb_spacer: Control
var status_dot: Label
var toast_lbl: Label
var _toast_t := 0.0
var _ins := {}
var _signed_in := false

# page state
var dash_box: VBoxContainer
var ai_state := {}
var agents_state := {}
var agent_edit := {}


func _ready() -> void:
	var root := get_tree().root
	ScreenUtil.configure(root)
	root.size_changed.connect(_on_resize)
	DisplayServer.window_set_color(C.bg)
	RenderingServer.set_default_clear_color(C.bg)
	net = AdminNet.new()
	add_child(net)
	net.status_changed.connect(_on_status)
	net.signed_out.connect(func(why): _signed_in = false; _show_login(why))
	net.stats.connect(func(_s):
		if page == "dash" and _signed_in:
			_fill_dash())
	var canvas := CanvasLayer.new()
	add_child(canvas)
	ui = Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.theme = AdminUi.theme()
	canvas.add_child(ui)
	if OS.get_environment("ADMIN_SHOT") != "" and not OS.has_feature("mobile"):
		_autotest()
		return
	var saved := net.saved_password()
	if saved != "":
		_show_login("", true)
		net.sign_in(saved, true, _on_login)
	else:
		_show_login()


func _on_resize() -> void:
	ScreenUtil.configure(get_tree().root)
	var ni := ScreenUtil.insets(get_viewport())
	if ni != _ins:
		_rebuild()


func _rebuild() -> void:
	if _signed_in:
		_show_main()
	else:
		_show_login()


func _process(delta: float) -> void:
	if kb_spacer and is_instance_valid(kb_spacer):
		var kh := ScreenUtil.keyboard_height(get_viewport())
		var want := maxf(0.0, kh - _bottom_bar_h())
		if absf(kb_spacer.custom_minimum_size.y - want) > 1.0:
			kb_spacer.custom_minimum_size.y = want
			var f := get_viewport().gui_get_focus_owner()
			if f and scroll and is_instance_valid(scroll) and scroll.is_ancestor_of(f):
				await get_tree().process_frame
				if is_instance_valid(f):
					scroll.ensure_control_visible(f)
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0 and toast_lbl and is_instance_valid(toast_lbl):
			var p: Control = toast_lbl.get_parent()
			create_tween().tween_property(p, "modulate:a", 0.0, 0.25)


func _bottom_bar_h() -> float:
	return (64.0 + _ins.get("rb", 0.0)) if _signed_in else 0.0


func _clear() -> void:
	for c in ui.get_children():
		c.queue_free()
	kb_spacer = null
	scroll = null
	body = null
	dash_box = null
	status_dot = null
	toast_lbl = null


func _bg() -> void:
	var bg := ColorRect.new()
	bg.color = C.bg
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(bg)


## A scroll page inside the safe area, with room at the bottom for the keyboard.
func _scroll_page(top: float, bottom: float) -> VBoxContainer:
	scroll = ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = top
	scroll.offset_bottom = -bottom
	scroll.offset_left = _ins.l
	scroll.offset_right = -_ins.r
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	ui.add_child(scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for k in ["margin_left", "margin_right"]:
		m.add_theme_constant_override(k, 16)
	m.add_theme_constant_override("margin_top", 8)
	m.add_theme_constant_override("margin_bottom", 24)
	scroll.add_child(m)
	var outer := AdminUi.vbox(0)
	m.add_child(outer)
	var v := AdminUi.vbox(14)
	outer.add_child(v)
	kb_spacer = Control.new()
	kb_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(kb_spacer)
	return v


func toast(text: String, good := true) -> void:
	if toast_lbl == null or not is_instance_valid(toast_lbl):
		return
	var p: Control = toast_lbl.get_parent()
	toast_lbl.text = text
	p.add_theme_stylebox_override("panel", AdminUi.box(C.green.darkened(0.55) if good else C.red.darkened(0.5), 14, Color.TRANSPARENT, 0, 14, 10))
	p.modulate.a = 1.0
	p.visible = true
	_toast_t = 3.0


func _toast_layer(bottom: float) -> void:
	var p := PanelContainer.new()
	p.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	p.offset_left = 16 + _ins.l
	p.offset_right = -16 - _ins.r
	p.offset_bottom = -bottom - 12
	p.offset_top = p.offset_bottom - 48
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.visible = false
	toast_lbl = AdminUi.lbl("", 14, C.text, 600, true)
	p.add_child(toast_lbl)
	ui.add_child(p)


# ---------------------------------------------------------------- sign in

var _login_status: Label
var _login_btn: Button
var _pw_field: LineEdit
var _remember: CheckButton


func _show_login(why := "", auto := false) -> void:
	_ins = ScreenUtil.insets(get_viewport())
	_clear()
	_bg()
	var v := _scroll_page(_ins.t, _ins.b)
	var top := Control.new()
	top.custom_minimum_size.y = 40
	v.add_child(top)
	var logo := PanelContainer.new()
	logo.add_theme_stylebox_override("panel", AdminUi.box(C.blue, 20))
	logo.custom_minimum_size = Vector2(72, 72)
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var pl := AdminUi.lbl("P", 40, Color.WHITE, 800)
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	logo.add_child(pl)
	v.add_child(logo)
	var t := _full(AdminUi.lbl("Plux Admin", 26, C.text, 800))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var s := AdminUi.lbl("Your control room for Plux. Only the admin password set on the server works here.", 14, C.sub, 450, true)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(s)
	var card := AdminUi.card(v, "Sign in")
	_pw_field = AdminUi.field("Admin password", "", true)
	_pw_field.text_submitted.connect(func(_t): _do_login())
	var row := AdminUi.hbox(8)
	row.add_child(_pw_field)
	var eye := AdminUi.btn("", "secondary", "eye")
	eye.custom_minimum_size = Vector2(46, 46)
	eye.pressed.connect(func(): _pw_field.secret = not _pw_field.secret)
	row.add_child(eye)
	card.add_child(AdminUi.lbl("Password", 13, C.sub, 600))
	card.add_child(row)
	_remember = AdminUi.toggle("Stay signed in on this phone", true)
	card.add_child(_remember)
	_login_btn = AdminUi.btn("Sign in", "primary", "lock-closed", _do_login)
	card.add_child(_login_btn)
	_login_status = AdminUi.lbl(why, 13, C.red if why != "" else C.sub, 500, true)
	card.add_child(_login_status)
	if auto:
		_login_btn.disabled = true
		_login_status.add_theme_color_override("font_color", C.sub)
		_login_status.text = "Signing in..."


func _do_login() -> void:
	var pw := _pw_field.text.strip_edges()
	if pw == "":
		_login_status.add_theme_color_override("font_color", C.red)
		_login_status.text = "Type the admin password."
		return
	_pw_field.release_focus()
	DisplayServer.virtual_keyboard_hide()
	_login_btn.disabled = true
	_login_status.add_theme_color_override("font_color", C.sub)
	_login_status.text = "Signing in..."
	net.sign_in(pw, _remember.button_pressed, _on_login)


func _on_login(ok: bool, why: String) -> void:
	if ok:
		_signed_in = true
		page = "dash"
		_show_main()
	else:
		_signed_in = false
		_show_login(why if why != "" else "Wrong password.")


func _on_status(st: String) -> void:
	if not _signed_in and _login_status and is_instance_valid(_login_status) and _login_btn.disabled:
		if st == "waking":
			_login_status.text = "Waking the server up. The free server can take up to a minute..."
		elif st == "signing_in":
			_login_status.text = "Signing in..."
	_paint_dot()


func _paint_dot() -> void:
	if status_dot == null or not is_instance_valid(status_dot):
		return
	var st := net.state
	var txt: String = {"ready": "Connected", "waking": "Waking server", "connecting": "Connecting", "signing_in": "Signing in"}.get(st, "Offline")
	var col: Color = C.green if st == "ready" else (C.gold if st != "off" else C.red)
	status_dot.text = "●  " + txt
	status_dot.add_theme_color_override("font_color", col)


# ---------------------------------------------------------------- main shell

const TABS := [["dash", "Dashboard", "squares-2x2"], ["ai", "Studio AI", "cog-6-tooth"], ["agents", "AI Agents", "sparkles"]]


func _show_main() -> void:
	_ins = ScreenUtil.insets(get_viewport())
	_clear()
	_bg()
	var head_h := 56.0
	var top: float = _ins.rt + head_h
	var bar_h := _bottom_bar_h()
	body = _scroll_page(top, bar_h)
	# header
	var head := PanelContainer.new()
	head.add_theme_stylebox_override("panel", AdminUi.box(C.bg, 0))
	head.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	head.offset_bottom = top
	ui.add_child(head)
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_top", int(_ins.rt))
	hm.add_theme_constant_override("margin_left", int(16 + _ins.l))
	hm.add_theme_constant_override("margin_right", int(8 + _ins.r))
	head.add_child(hm)
	var hh := AdminUi.hbox(8)
	hm.add_child(hh)
	var tv := AdminUi.vbox(0)
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var title := ""
	for t in TABS:
		if t[0] == page:
			title = t[1]
	tv.add_child(_full(AdminUi.lbl(title, 22, C.text, 800)))
	status_dot = _full(AdminUi.lbl("", 12, C.green, 600))
	tv.add_child(status_dot)
	hh.add_child(tv)
	var out := AdminUi.btn("Sign out", "ghost", "", _sign_out)
	out.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hh.add_child(out)
	_paint_dot()
	# bottom tabs
	var bar := PanelContainer.new()
	var sb := AdminUi.box(C.card, 0)
	sb.border_color = C.line
	sb.border_width_top = 1
	bar.add_theme_stylebox_override("panel", sb)
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -bar_h
	ui.add_child(bar)
	var bm := MarginContainer.new()
	bm.add_theme_constant_override("margin_bottom", int(_ins.rb))
	bm.add_theme_constant_override("margin_left", int(_ins.l))
	bm.add_theme_constant_override("margin_right", int(_ins.r))
	bar.add_child(bm)
	var bh := AdminUi.hbox(0)
	bm.add_child(bh)
	for t in TABS:
		bh.add_child(_tab_btn(t[0], t[1], t[2]))
	_toast_layer(bar_h)
	match page:
		"dash": _page_dash()
		"ai": _page_ai()
		"agents": _page_agents()


func _tab_btn(id: String, text: String, ic: String) -> Button:
	var on := page == id
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = 64
	for st in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var v := AdminUi.vbox(3)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", AdminUi.box(Color(C.blue, 0.22) if on else Color(0, 0, 0, 0), 14, Color.TRANSPARENT, 0, 16, 3))
	pill.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_child(AdminUi.icon(ic, 22, C.blue_hi if on else C.sub))
	v.add_child(pill)
	var l := _full(AdminUi.lbl(text, 12, C.text if on else C.sub, 700 if on else 500))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	b.add_child(v)
	b.pressed.connect(func():
		if page != id:
			page = id
			_show_main())
	return b


func _sign_out() -> void:
	_signed_in = false
	net.sign_out()
	_show_login("Signed out.")
	if _login_status:
		_login_status.add_theme_color_override("font_color", C.sub)


# ---------------------------------------------------------------- dashboard

func _page_dash() -> void:
	dash_box = AdminUi.vbox(14)
	body.add_child(dash_box)
	_fill_dash()
	net.rq({"t": "a_stats"}, "a_stats_res")


func _fill_dash() -> void:
	if dash_box == null or not is_instance_valid(dash_box):
		return
	for c in dash_box.get_children():
		c.queue_free()
	var s: Dictionary = net.last_stats
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dash_box.add_child(grid)
	_stat(grid, "users", "Players", AdminUi.commas(int(s.get("accounts", 0))), "accounts")
	_stat(grid, "signal", "Online now", AdminUi.commas(int(s.get("online", 0))), "%d in games" % int(s.get("in_games", 0)))
	var days: Array = s.get("days", [])
	var today: Dictionary = days[-1] if not days.is_empty() else {}
	_stat(grid, "user-plus", "New today", str(int(today.get("signups", 0))), "sign-ups")
	_stat(grid, "sparkles", "AI builds today", str(int(today.get("ai", 0))), "Studio")
	var card := AdminUi.card(dash_box, "Server")
	var ready := net.state == "ready"
	_kv(card, "Status", "Online" if ready else "Not connected", C.green if ready else C.red)
	_kv(card, "Version", str(s.get("version", "-")))
	_kv(card, "Running for", _dur(int(s.get("uptime_s", 0))))
	_kv(card, "Database", "Saving" if s.get("storage", false) else "Not saving", C.green if s.get("storage", false) else C.red)
	_kv(card, "Memory", "%.0f MB" % float(s.get("mem_mb", 0.0)))
	_kv(card, "Game rooms", str(int(s.get("rooms", 0))))
	var ai_ok := bool(s.get("ai_ready", false))
	_kv(card, "Studio AI", "Ready" if ai_ok else "Not set up yet", C.green if ai_ok else C.gold)
	if not ai_ok:
		dash_box.add_child(AdminUi.btn("Set up Studio AI", "primary", "cog-6-tooth", func(): page = "ai"; _show_main()))
	dash_box.add_child(AdminUi.btn("Refresh", "secondary", "arrow-path", func(): net.rq({"t": "a_stats"}, "a_stats_res")))
	var note := AdminUi.lbl("Updates by itself every 10 seconds while the app is open.", 12, C.faint, 450, true)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dash_box.add_child(note)


func _stat(parent: Control, ic: String, label: String, value: String, sub: String) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", AdminUi.box(C.card, 20, Color.TRANSPARENT, 0, 14, 14))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := AdminUi.vbox(4)
	var h := AdminUi.hbox(6)
	h.add_child(AdminUi.icon(ic, 16, C.blue_hi))
	h.add_child(_full(AdminUi.lbl(label, 13, C.sub, 600)))
	v.add_child(h)
	v.add_child(_full(AdminUi.lbl(value, 28, C.text, 800)))
	v.add_child(_full(AdminUi.lbl(sub, 12, C.faint)))
	p.add_child(v)
	parent.add_child(p)


func _kv(parent: Control, k: String, v: String, col: Color = C.text) -> void:
	var h := AdminUi.hbox(8)
	var kl := AdminUi.lbl(k, 15, C.sub)
	kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(kl)
	h.add_child(_full(AdminUi.lbl(v, 15, col, 650)))
	parent.add_child(h)


func _dur(sec: int) -> String:
	if sec < 60:
		return "%d s" % sec
	if sec < 3600:
		return "%d min" % (sec / 60)
	if sec < 86400:
		return "%d h %d min" % [sec / 3600, (sec % 3600) / 60]
	return "%d days" % (sec / 86400)


# ---------------------------------------------------------------- Studio AI settings

var _base_f: LineEdit
var _model_f: LineEdit
var _key_f: LineEdit
var _ai_status: Label
var _test_lbl: Label


func _page_ai() -> void:
	var wait := AdminUi.lbl("Loading...", 14, C.sub)
	body.add_child(wait)
	net.rq({"t": "a_ai_get"}, "a_ai_res", func(m):
		ai_state = m
		if page == "ai" and body and is_instance_valid(body):
			wait.queue_free()
			_fill_ai())


func _fill_ai() -> void:
	var ready := bool(ai_state.get("ready", false))
	var top := AdminUi.card(body, "Omni Route connection", "Studio builds games with AI through Omni Route. Paste the three values from your Omni Route account here. The key is locked away on the server: this app never shows it again, and players never see it.")
	var sh := AdminUi.hbox(8)
	sh.add_child(_full(AdminUi.lbl("Status", 15, C.sub)))
	sh.add_child(AdminUi.spacer())
	_ai_status = _full(AdminUi.lbl("", 15, C.text, 700))
	sh.add_child(_ai_status)
	top.add_child(sh)
	_paint_ai_status(ready)
	var f := AdminUi.card(body, "Settings")
	_base_f = AdminUi.labeled(f, "Base URL", AdminUi.field("https://.../v1", str(ai_state.get("base", ""))), "The address ending in /v1. Studio calls {base URL}/chat/completions.")
	_base_f.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_URL
	_model_f = AdminUi.labeled(f, "Model", AdminUi.field("Model name, exactly as Omni Route shows it", str(ai_state.get("model", ""))))
	var masked := str(ai_state.get("key", ""))
	_key_f = AdminUi.field("Paste a new key to replace %s" % masked if masked != "" else "Paste your API key", "", true)
	var kr := AdminUi.hbox(8)
	kr.add_child(_key_f)
	var eye := AdminUi.btn("", "secondary", "eye")
	eye.custom_minimum_size = Vector2(46, 46)
	eye.pressed.connect(func(): _key_f.secret = not _key_f.secret)
	kr.add_child(eye)
	f.add_child(AdminUi.lbl("API key", 13, C.sub, 600))
	f.add_child(kr)
	f.add_child(AdminUi.lbl(("Saved key: %s. Leave the box empty to keep it." % masked) if masked != "" else "No key saved yet.", 12, C.faint, 450, true))
	f.add_child(AdminUi.btn("Save", "primary", "check", _save_ai))
	var t := AdminUi.card(body, "Test connection", "Sends a tiny request with the saved settings and shows the answer. Save first if you changed something.")
	_test_lbl = AdminUi.lbl("", 14, C.sub, 500, true)
	t.add_child(AdminUi.btn("Test connection", "secondary", "bolt", _test_ai))
	t.add_child(_test_lbl)
	if masked != "":
		var d := AdminUi.card(body, "Remove key", "Studio goes back to showing \"AI not set up yet\" and makes simpler games until you add a key again.")
		d.add_child(AdminUi.btn("Remove the saved key", "danger", "trash", func():
			net.rq({"t": "a_ai_set", "base": _base_f.text, "model": _model_f.text, "clear_key": true}, "a_ok", func(m):
				if m.get("ok", false):
					toast("Key removed.")
					_show_main()
				else:
					toast(str(m.get("why", "Couldn't remove it.")), false))))


func _paint_ai_status(ready: bool) -> void:
	if _ai_status and is_instance_valid(_ai_status):
		_ai_status.text = "Ready" if ready else "Not set up yet"
		_ai_status.add_theme_color_override("font_color", C.green if ready else C.gold)


func _save_ai() -> void:
	var base := _base_f.text.strip_edges()
	if base != "" and not base.begins_with("http"):
		toast("The base URL must start with https://", false)
		return
	var msg := {"t": "a_ai_set", "base": base, "model": _model_f.text.strip_edges()}
	if _key_f.text.strip_edges() != "":
		msg.key = _key_f.text.strip_edges()
	get_viewport().gui_release_focus()
	DisplayServer.virtual_keyboard_hide()
	net.rq(msg, "a_ok", func(m):
		if m.get("ok", false):
			toast("Saved. Studio uses it from the next game." if m.get("ready", false) else "Saved. Add the base URL, model and key to switch AI on.")
			_show_main()
		else:
			toast(str(m.get("why", "Couldn't save.")), false))


func _test_ai() -> void:
	_test_lbl.add_theme_color_override("font_color", C.sub)
	_test_lbl.text = "Testing..."
	net.rq({"t": "a_ai_test"}, "a_ai_test_res", func(m):
		if not is_instance_valid(_test_lbl):
			return
		if m.get("ok", false):
			_test_lbl.add_theme_color_override("font_color", C.green)
			_test_lbl.text = "Connected. The AI answered in %.1f seconds." % (float(m.get("ms", 0)) / 1000.0)
		else:
			_test_lbl.add_theme_color_override("font_color", C.red)
			_test_lbl.text = "Didn't work: " + str(m.get("why", "no answer")))


# ---------------------------------------------------------------- AI agents

func _page_agents() -> void:
	var wait := AdminUi.lbl("Loading...", 14, C.sub)
	body.add_child(wait)
	net.rq({"t": "a_agents"}, "a_agents_res", func(m):
		agents_state = m
		for a in m.get("agents", []):
			if a.id == "studio_builder":
				agent_edit = a.duplicate(true)
		if page == "agents" and body and is_instance_valid(body):
			wait.queue_free()
			_fill_agents())


func _fill_agents() -> void:
	if agent_edit.is_empty():
		body.add_child(AdminUi.lbl("The server didn't send the Studio Builder agent. Update the server, then try again.", 14, C.red, 500, true))
		return
	var a := agent_edit
	var opts: Dictionary = a.get("opts", {})
	var head := AdminUi.card(body, str(a.get("name", "Studio Builder")), str(a.get("job", "")) + " Its rules also apply when players change their game in words.")
	var on := AdminUi.toggle("Agent on", bool(a.get("on", true)))
	on.toggled.connect(func(v): a.on = v)
	head.add_child(on)
	if not bool(agents_state.get("ready", false)):
		head.add_child(AdminUi.lbl("Studio AI isn't set up yet, so players see \"AI not set up yet\". Add the key on the Studio AI tab.", 12, C.gold, 500, true))
	var schema: Array = agents_state.get("schema", [])
	var choices := AdminUi.card(body, "Rules")
	var groups := {}
	for opt in schema:
		var f: Array = opt.get("for", ["all"])
		if not (f.has("all") or f.has("studio_builder")):
			continue
		if opt.type == "choice":
			var ob := OptionButton.new()
			ob.focus_mode = Control.FOCUS_NONE
			ob.custom_minimum_size.y = 46
			ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ob.add_theme_font_size_override("font_size", 15)
			var cur := str(opts.get(opt.key, opt.default))
			var i := 0
			for ch in opt.choices:
				ob.add_item(str(ch[1]))
				if str(ch[0]) == cur:
					ob.select(i)
				i += 1
			var key: String = opt.key
			var chs: Array = opt.choices
			ob.item_selected.connect(func(idx): opts[key] = str(chs[idx][0]))
			AdminUi.labeled(choices, str(opt.label), ob)
		elif opt.type == "toggle":
			var g := str(opt.get("group", "Safety"))
			if not groups.has(g):
				groups[g] = []
			groups[g].append(opt)
	for g in groups:
		var gc := AdminUi.card(body, g, "Switch off anything Studio must never use." if g == "Allowed objects" else "")
		for opt in groups[g]:
			var tg := AdminUi.toggle(str(opt.label), bool(opts.get(opt.key, opt.default)))
			var key: String = opt.key
			tg.toggled.connect(func(v): opts[key] = v)
			gc.add_child(tg)
	var ex := AdminUi.card(body, "Extra rules (optional)", "Anything else the AI should always follow, in plain words.")
	var te := TextEdit.new()
	te.text = str(a.get("rules", ""))
	te.placeholder_text = "For example: Always put a star near the start."
	te.custom_minimum_size.y = 110
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.add_theme_font_size_override("font_size", 15)
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.text_changed.connect(func(): a.rules = te.text)
	te.focus_entered.connect(func():
		await get_tree().create_timer(0.4).timeout
		if is_instance_valid(te) and scroll:
			scroll.ensure_control_visible(te))
	ex.add_child(te)
	body.add_child(AdminUi.btn("Save rules", "primary", "check", _save_agent))
	var prev_lbl := AdminUi.lbl("", 13, C.sub, 450, true)
	body.add_child(AdminUi.btn("Show what the AI is told", "secondary", "document-text", func():
		net.rq({"t": "a_agent_preview", "agent": a}, "a_agent_preview_res", func(m):
			if is_instance_valid(prev_lbl):
				prev_lbl.text = str(m.get("text", "")))))
	body.add_child(prev_lbl)


func _save_agent() -> void:
	get_viewport().gui_release_focus()
	DisplayServer.virtual_keyboard_hide()
	var a := agent_edit.duplicate(true)
	net.rq({"t": "a_agent_save", "agent": a}, "a_ok", func(m):
		if not m.get("ok", false):
			toast(str(m.get("why", "Couldn't save.")), false)
			return
		agent_edit = m.get("agent", agent_edit)
		# The same rules apply when players change a game in words (the Game Editor agent).
		var ed := {}
		for x in agents_state.get("agents", []):
			if x.id == "game_editor":
				ed = x.duplicate(true)
		if ed.is_empty():
			toast("Rules saved. Studio uses them from the next game.")
			return
		ed.on = a.on
		ed.rules = a.rules
		var eo: Dictionary = ed.get("opts", {})
		for k in a.opts:
			eo[k] = a.opts[k]
		ed.opts = eo
		net.rq({"t": "a_agent_save", "agent": ed}, "a_ok", func(m2):
			if m2.get("ok", false):
				toast("Rules saved. Studio uses them from the next game.")
			else:
				toast("Saved for new games, but not for changes: " + str(m2.get("why", "")), false)))


# Desktop test runs: ADMIN_SHOT=/path/prefix ADMIN_PW=... saves login.png, dash.png, ai.png, agents.png.
func _autotest() -> void:
	var pre := OS.get_environment("ADMIN_SHOT")
	_show_login()
	await get_tree().create_timer(1.5).timeout
	await _shot(pre + "login.png")
	_pw_field.text = OS.get_environment("ADMIN_PW")
	_do_login()
	var t := 0.0
	while not _signed_in and t < 30.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
	print("ADMIN AUTOTEST signed_in=", _signed_in, " stats=", net.last_stats.get("accounts", -1))
	for p in ["dash", "ai", "agents"]:
		page = p
		_show_main()
		await get_tree().create_timer(3.0).timeout
		await _shot(pre + p + ".png")
		if p == "agents":
			scroll.scroll_vertical = 100000
			await get_tree().create_timer(0.6).timeout
			await _shot(pre + p + "_end.png")
		if p == "ai":
			_test_ai()
			await get_tree().create_timer(5.0).timeout
			print("ADMIN AUTOTEST test=", _test_lbl.text)
	get_tree().quit()


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("ADMIN AUTOTEST shot ", path)


## A label that keeps its full width (AdminUi.lbl clips, which lets a row squeeze it to nothing).
func _full(l: Label) -> Label:
	l.clip_text = false
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	return l
