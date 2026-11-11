extends Node
## Plux Admin 1.0.1: sign in, dashboard, Studio AI settings, Studio Builder agent rules,
## drawn with the Sky & Ink design system (light, dark or follow the phone).
## Everything is checked and stored on the server; the app only shows and sends.

const SETTINGS_PATH := "user://admin_settings.cfg"
const MAX_W := 760.0
const BAR_H := 72.0

var C: Dictionary:
	get: return AdminUi.C

var net: AdminNet
var ui: Control           # full-screen root, rebuilt per screen
var page := "dash"        # dash, ai, agents
var body: VBoxContainer   # scroll content of the current page
var scroll: ScrollContainer
var kb_spacer: Control
var divider: ColorRect
var status_lbl: Label
var status_pulse: AdminPulse
var toast_box: PanelContainer
var toast_lbl: Label
var _toast_t := 0.0
var _ins := {}
var _signed_in := false
var theme_mode := "light"   # light, dark, system
var _sys_dark := false
var _sys_poll := 0.0

# page state
var ai_state := {}
var agents_state := {}
var agent_edit := {}


func _ready() -> void:
	var root := get_tree().root
	ScreenUtil.configure(root)
	root.size_changed.connect(_on_resize)
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) == OK:
		theme_mode = str(cf.get_value("p", "theme", "light"))
	if OS.get_environment("ADMIN_THEME") != "" and not OS.has_feature("mobile"):
		theme_mode = OS.get_environment("ADMIN_THEME")
	_sys_dark = _phone_dark()
	_apply_theme()
	net = AdminNet.new()
	add_child(net)
	net.status_changed.connect(_on_status)
	net.signed_out.connect(func(why): _signed_in = false; _show_login(why))
	net.stats.connect(func(_s):
		if page == "dash" and _signed_in:
			_update_dash())
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


# ---------------------------------------------------------------- theme

func _phone_dark() -> bool:
	if DisplayServer.is_dark_mode_supported():
		return DisplayServer.is_dark_mode()
	return false


func _apply_theme() -> void:
	var d := theme_mode == "dark" or (theme_mode == "system" and _sys_dark)
	AdminUi.set_dark(d)
	# The window colour tells Android whether the status and navigation bar icons are dark or light.
	DisplayServer.window_set_color(C.bg)
	RenderingServer.set_default_clear_color(C.bg)
	if ui:
		ui.theme = AdminUi.theme()


func _set_theme(mode: String) -> void:
	theme_mode = mode
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)
	cf.set_value("p", "theme", mode)
	cf.save(SETTINGS_PATH)
	_apply_theme()
	_rebuild()
	toast({"light": "Light theme", "dark": "Dark theme", "system": "Following your phone's theme"}.get(mode, ""))


func _next_theme() -> void:
	_set_theme({"light": "dark", "dark": "system", "system": "light"}.get(theme_mode, "light"))


func _theme_icon() -> String:
	return {"light": "sun", "dark": "moon", "system": "device-phone-mobile"}.get(theme_mode, "sun")


# ---------------------------------------------------------------- frame

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


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and theme_mode == "system":
		_check_system_theme()


func _check_system_theme() -> void:
	var d := _phone_dark()
	if d != _sys_dark:
		_sys_dark = d
		_apply_theme()
		_rebuild()


func _process(delta: float) -> void:
	if theme_mode == "system":
		_sys_poll += delta
		if _sys_poll > 2.0:
			_sys_poll = 0.0
			_check_system_theme()
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
	if divider and is_instance_valid(divider) and scroll and is_instance_valid(scroll):
		var a := 1.0 if scroll.scroll_vertical > 0 else 0.0
		if divider.modulate.a != a:
			divider.modulate.a = a
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0 and toast_box and is_instance_valid(toast_box):
			create_tween().tween_property(toast_box, "modulate:a", 0.0, 0.25)


func _bottom_bar_h() -> float:
	return (BAR_H + _ins.get("rb", 0.0)) if _signed_in else 0.0


func _clear() -> void:
	for c in ui.get_children():
		c.queue_free()
	kb_spacer = null
	scroll = null
	body = null
	divider = null
	status_lbl = null
	status_pulse = null
	toast_box = null
	toast_lbl = null
	_dash = {}


func _bg() -> void:
	var bg := ColorRect.new()
	bg.color = C.bg
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(bg)


## A scroll page inside the safe area, centred with a max width, with room for the keyboard.
func _scroll_page(top: float, bottom: float) -> VBoxContainer:
	scroll = ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = top
	scroll.offset_bottom = -bottom
	scroll.offset_left = _ins.rl
	scroll.offset_right = -_ins.rr
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	ui.add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.use_top_left = false
	scroll.add_child(center)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for k in ["margin_left", "margin_right"]:
		m.add_theme_constant_override(k, 16)
	m.add_theme_constant_override("margin_top", 8)
	m.add_theme_constant_override("margin_bottom", 24)
	center.add_child(m)
	var fit := func():
		m.custom_minimum_size.x = minf(scroll.size.x, MAX_W)
	scroll.resized.connect(fit)
	var outer := AdminUi.vbox(0)
	m.add_child(outer)
	var v := AdminUi.vbox(12)
	outer.add_child(v)
	kb_spacer = Control.new()
	kb_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(kb_spacer)
	fit.call_deferred()
	return v


## Snackbar: inverse surface, 12dp corners, a small icon for good or bad news.
func toast(text: String, good := true) -> void:
	if toast_box == null or not is_instance_valid(toast_box):
		return
	toast_lbl.text = text
	var ic: TextureRect = toast_box.get_meta("icon")
	ic.texture = AdminUi.icon_tex("check-circle" if good else "exclamation-triangle")
	ic.self_modulate = (AdminUi.ACC.green if good else Color("FF6B6B")) if not AdminUi.dark else (AdminUi.ACC.green if good else AdminUi.ACC.red)
	toast_box.modulate.a = 1.0
	toast_box.visible = true
	_toast_t = 3.2


func _toast_layer(bottom: float) -> void:
	var p := PanelContainer.new()
	p.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	p.offset_left = 16 + _ins.l
	p.offset_right = -16 - _ins.r
	p.offset_bottom = -bottom - 12
	p.offset_top = p.offset_bottom - 48
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", AdminUi.box(C.inverse, 12, Color.TRANSPARENT, 0, 16, 12))
	p.visible = false
	var h := AdminUi.hbox(12)
	var ic := AdminUi.icon("check-circle", 22, AdminUi.ACC.green)
	h.add_child(ic)
	toast_lbl = AdminUi.lbl("", 14, C.on_inverse, 500, true)
	toast_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(toast_lbl)
	p.add_child(h)
	p.set_meta("icon", ic)
	toast_box = p
	ui.add_child(p)


# ---------------------------------------------------------------- sign in

var _login_status: Label
var _login_btn: Button
var _pw_field: LineEdit
var _remember: Button


func _show_login(why := "", auto := false) -> void:
	_ins = ScreenUtil.insets(get_viewport())
	_clear()
	_bg()
	var v := _scroll_page(_ins.t, _ins.b)
	# theme switch, top right
	var tr := AdminUi.hbox(0)
	tr.add_child(AdminUi.spacer())
	tr.add_child(AdminUi.icon_btn(_theme_icon(), C.sub, _next_theme))
	v.add_child(tr)
	var logo := AdminGrad.new(AdminUi.PAL.sky, AdminUi.PAL.sky_medium, 24.0)
	logo.custom_minimum_size = Vector2(76, 76)
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var pl := Label.new()
	pl.text = "P"
	pl.add_theme_font_override("font", AdminUi.anton())
	pl.add_theme_font_size_override("font_size", 40)
	pl.add_theme_color_override("font_color", AdminUi.PAL.ink)
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.add_child(pl)
	v.add_child(logo)
	var tt := AdminUi.page_title("Plux Admin")
	tt.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(tt)
	var s := AdminUi.lbl("Your control room for Plux. Only the admin password set on the server works here.", 14, C.sub, 400, true)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(s)
	AdminUi.section(v, "Sign in")
	var card := AdminUi.card(v, 16, 14)
	AdminUi.card_head(card, "lock-closed", AdminUi.ACC.sky, "Admin password", "The one saved on your Render server.")
	_pw_field = AdminUi.field("Admin password", "", true)
	_pw_field.text_submitted.connect(func(_t): _do_login())
	var row := AdminUi.hbox(8)
	row.add_child(_pw_field)
	var eye: Button
	eye = AdminUi.icon_btn("eye", C.sub, func():
		_pw_field.secret = not _pw_field.secret
		(eye.get_meta("icon") as TextureRect).texture = AdminUi.icon_tex("eye" if _pw_field.secret else "eye-slash"), true)
	row.add_child(eye)
	card.add_child(row)
	_remember = AdminUi.toggle("Stay signed in on this phone", true, "So you don't type it every time.")
	var rm := MarginContainer.new()
	rm.add_theme_constant_override("margin_left", -16)
	rm.add_theme_constant_override("margin_right", -16)
	rm.add_child(_remember)
	card.add_child(rm)
	_login_btn = AdminUi.btn("Sign in", "primary", "arrow-right-start-on-rectangle", _do_login)
	card.add_child(_login_btn)
	_login_status = AdminUi.lbl(why, 14, C.error if why != "" else C.sub, 500, true)
	_login_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(_login_status)
	if auto:
		_login_btn.disabled = true
		_login_status.add_theme_color_override("font_color", C.sub)
		_login_status.text = "Signing in..."


func _do_login() -> void:
	var pw := _pw_field.text.strip_edges()
	if pw == "":
		_login_status.add_theme_color_override("font_color", C.error)
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
	_paint_status()
	if _signed_in and page == "dash":
		_update_dash()


func _paint_status() -> void:
	if status_lbl == null or not is_instance_valid(status_lbl):
		return
	var st := net.state
	var txt: String = {"ready": "Connected", "waking": "Waking the server", "connecting": "Connecting", "signing_in": "Signing in"}.get(st, "Offline")
	status_lbl.text = txt
	status_lbl.add_theme_color_override("font_color", C.good if st == "ready" else (C.warn if st != "off" else C.error))
	if status_pulse and is_instance_valid(status_pulse):
		status_pulse.live = st == "ready"


# ---------------------------------------------------------------- main shell

const TABS := [["dash", "Dashboard", "squares-2x2"], ["ai", "Studio AI", "cpu-chip"], ["agents", "AI Agents", "sparkles"]]


func _show_main() -> void:
	_ins = ScreenUtil.insets(get_viewport())
	_clear()
	_bg()
	var bar_h := _bottom_bar_h()
	# pinned top bar: Anton title + sky dot, connection line, theme and sign-out actions
	var head := PanelContainer.new()
	head.add_theme_stylebox_override("panel", AdminUi.box(C.bg, 0))
	head.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_top", int(_ins.rt + 12))
	hm.add_theme_constant_override("margin_bottom", 4)
	hm.add_theme_constant_override("margin_left", int(20 + _ins.rl))
	hm.add_theme_constant_override("margin_right", int(8 + _ins.rr))
	head.add_child(hm)
	var hh := AdminUi.hbox(4)
	hm.add_child(hh)
	var tv := AdminUi.vbox(2)
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := ""
	for t in TABS:
		if t[0] == page:
			title = t[1]
	tv.add_child(AdminUi.page_title(title))
	var sh := AdminUi.hbox(4)
	status_pulse = AdminPulse.new()
	status_pulse.custom_minimum_size = Vector2(16, 16)
	sh.add_child(status_pulse)
	status_lbl = AdminUi.tag("", 14, C.sub, 500)
	sh.add_child(status_lbl)
	tv.add_child(sh)
	hh.add_child(tv)
	hh.add_child(AdminUi.icon_btn(_theme_icon(), C.sub, _next_theme))
	hh.add_child(AdminUi.icon_btn("arrow-right-start-on-rectangle", C.sub, _sign_out))
	ui.add_child(head)
	var head_h := head.get_combined_minimum_size().y
	head.offset_bottom = head_h
	body = _scroll_page(head_h, bar_h)
	ui.move_child(head, ui.get_child_count() - 1)
	divider = ColorRect.new()
	divider.color = C.line
	divider.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	divider.offset_top = head_h
	divider.offset_bottom = head_h + 1
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	divider.modulate.a = 0.0
	ui.add_child(divider)
	_paint_status()
	# bottom navigation bar, sitting above the phone's own navigation bar
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", AdminUi.box(C.low, 0))
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -bar_h
	ui.add_child(bar)
	var bm := MarginContainer.new()
	bm.add_theme_constant_override("margin_bottom", int(_ins.rb))
	bm.add_theme_constant_override("margin_left", int(_ins.rl))
	bm.add_theme_constant_override("margin_right", int(_ins.rr))
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
	b.custom_minimum_size.y = BAR_H
	for st in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var v := AdminUi.vbox(4)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", AdminUi.box(Color(C.primary, 0.14) if on else Color(0, 0, 0, 0), 16, Color.TRANSPARENT, 0, 20, 4))
	pill.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var i := AdminUi.icon(ic, 24, C.primary if on else C.sub)
	i.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pill.add_child(i)
	v.add_child(pill)
	var l := AdminUi.tag(text, 12, C.primary if on else C.sub, 600 if on else 500)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	b.add_child(v)
	AdminUi.press_fx(b)
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

var _dash := {}


func _page_dash() -> void:
	var d := {}
	# hero: sky gradient card with the player count and the live dot
	var hero := AdminGrad.new(AdminUi.PAL.sky, AdminUi.PAL.sky_medium, 24.0, 20.0)
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(hero)
	var hv := AdminUi.vbox(4)
	hero.add_child(hv)
	var ht := AdminUi.hbox(6)
	var hl := AdminUi.lbl("Players on Plux", 14, Color(AdminUi.PAL.ink, 0.8), 500)
	ht.add_child(hl)
	var live_pill := PanelContainer.new()
	live_pill.add_theme_stylebox_override("panel", AdminUi.box(Color(1, 1, 1, 0.55), 999, Color.TRANSPARENT, 0, 8, 2))
	live_pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	live_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lph := AdminUi.hbox(2)
	lph.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	d.pulse = AdminPulse.new()
	lph.add_child(d.pulse)
	d.live = AdminUi.tag("LIVE", 12, AdminUi.PAL.ink, 700)
	lph.add_child(d.live)
	live_pill.add_child(lph)
	ht.add_child(live_pill)
	hv.add_child(ht)
	d.players = Label.new()
	d.players.add_theme_font_override("font", AdminUi.anton())
	d.players.add_theme_font_size_override("font_size", 44)
	d.players.add_theme_color_override("font_color", AdminUi.PAL.ink)
	d.players.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hv.add_child(d.players)
	d.hero_sub = AdminUi.lbl("", 14, Color(AdminUi.PAL.ink, 0.8), 500)
	hv.add_child(d.hero_sub)
	# stat tiles
	AdminUi.section(body, "Today")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.resized.connect(func(): grid.columns = 1 if grid.size.x < 300.0 else (4 if grid.size.x >= 640.0 else 2))
	body.add_child(grid)
	d.online = _tile(grid, "signal", AdminUi.ACC.green, "Online now")
	d.signups = _tile(grid, "user-plus", AdminUi.ACC.sky, "New players")
	d.ai = _tile(grid, "sparkles", AdminUi.ACC.pink, "AI builds")
	d.games = _tile(grid, "rocket-launch", AdminUi.ACC.amber, "Games published")
	# chart
	AdminUi.section(body, "Last 14 days")
	var cc := AdminUi.card(body, 16, 12)
	AdminUi.card_head(cc, "chart-bar", AdminUi.ACC.sky, "Sign-ups and AI builds", "Tap a day to see its numbers.")
	var legend := AdminUi.hbox(16)
	legend.add_child(_legend("Sign-ups", AdminUi.PAL.sky))
	legend.add_child(_legend("AI builds", AdminUi.PAL.pink))
	legend.add_child(AdminUi.spacer())
	cc.add_child(legend)
	var chart := AdminChart.new()
	chart.col_a = AdminUi.PAL.sky
	chart.col_b = AdminUi.PAL.pink
	cc.add_child(chart)
	d.chart = chart
	d.pick = AdminUi.lbl("", 14, C.sub, 500)
	cc.add_child(d.pick)
	chart.picked.connect(func(_i): _paint_pick())
	# server rows
	AdminUi.section(body, "Server")
	var sc := AdminUi.card(body, 0, 0)
	d.r_status = AdminUi.row(sc, "server", AdminUi.ACC.sky, "Status", "-")
	d.r_version = AdminUi.row(sc, "tag", AdminUi.ACC.ink if not AdminUi.dark else AdminUi.PAL.sky_light, "Version", "-")
	d.r_up = AdminUi.row(sc, "clock", AdminUi.ACC.amber, "Running for", "-")
	d.r_db = AdminUi.row(sc, "circle-stack", AdminUi.ACC.green, "Database", "-")
	d.r_mem = AdminUi.row(sc, "cpu-chip", AdminUi.ACC.pink, "Memory", "-")
	d.r_rooms = AdminUi.row(sc, "user-group", AdminUi.ACC.sky, "Game rooms", "-")
	d.r_ai = AdminUi.row(sc, "sparkles", AdminUi.ACC.pink, "Studio AI", "-")
	d.setup = AdminUi.btn("Set up Studio AI", "primary", "cog-6-tooth", func(): page = "ai"; _show_main())
	body.add_child(d.setup)
	body.add_child(AdminUi.btn("Refresh", "outline", "arrow-path", func():
		net.rq({"t": "a_stats"}, "a_stats_res")
		toast("Refreshing...")))
	var note := AdminUi.lbl("Updates by itself every 10 seconds while the app is open.", 12, C.sub, 400, true)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(note)
	_dash = d
	_update_dash()
	net.rq({"t": "a_stats"}, "a_stats_res")


func _tile(parent: Control, ic: String, accent: Color, label: String) -> Label:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", AdminUi.box(C.card, 20, C.line, 1, 16, 16))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := AdminUi.vbox(10)
	v.add_child(AdminUi.badge(ic, accent))
	var val := Label.new()
	val.text = "-"
	val.add_theme_font_override("font", AdminUi.anton())
	val.add_theme_font_size_override("font_size", 30)
	val.add_theme_color_override("font_color", C.text)
	val.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tv := AdminUi.vbox(0)
	tv.add_child(val)
	tv.add_child(AdminUi.lbl(label, 14, C.sub, 500))
	v.add_child(tv)
	p.add_child(v)
	parent.add_child(p)
	return val


func _legend(text: String, col: Color) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot := Panel.new()
	dot.add_theme_stylebox_override("panel", AdminUi.box(col, 5))
	dot.custom_minimum_size = Vector2(10, 10)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(dot)
	h.add_child(AdminUi.tag(text, 12, C.sub, 500))
	return h


func _update_dash() -> void:
	if _dash.is_empty() or not is_instance_valid(_dash.players):
		return
	var d := _dash
	var s: Dictionary = net.last_stats
	var ready := net.state == "ready"
	d.players.text = AdminUi.commas(int(s.get("accounts", 0)))
	d.hero_sub.text = "%s online now, %s in games" % [AdminUi.commas(int(s.get("online", 0))), AdminUi.commas(int(s.get("in_games", 0)))]
	d.pulse.live = ready
	d.live.text = "LIVE" if ready else "OFFLINE"
	var days: Array = s.get("days", [])
	var today: Dictionary = days[-1] if not days.is_empty() else {}
	d.online.text = AdminUi.commas(int(s.get("online", 0)))
	d.signups.text = AdminUi.commas(int(today.get("signups", 0)))
	d.ai.text = AdminUi.commas(int(today.get("ai", 0)))
	d.games.text = AdminUi.commas(int(s.get("games_published", 0)))
	var rows := []
	for x in days:
		rows.append({"day": str(x.get("day", "")), "a": int(x.get("signups", 0)), "b": int(x.get("ai", 0))})
	d.chart.set_rows(rows)
	_paint_pick()
	AdminUi.set_row(d.r_status, "Online" if ready else "Not connected", C.good if ready else C.error)
	AdminUi.set_row(d.r_version, str(s.get("version", "-")))
	AdminUi.set_row(d.r_up, _dur(int(s.get("uptime_s", 0))))
	var st := bool(s.get("storage", false))
	AdminUi.set_row(d.r_db, "Saving" if st else "Not saving", C.good if st else C.error)
	AdminUi.set_row(d.r_mem, "%.0f MB" % float(s.get("mem_mb", 0.0)))
	AdminUi.set_row(d.r_rooms, str(int(s.get("rooms", 0))))
	var ai_ok := bool(s.get("ai_ready", false))
	AdminUi.set_row(d.r_ai, "Ready" if ai_ok else "Not set up yet", C.good if ai_ok else C.warn)
	d.setup.visible = not ai_ok


func _paint_pick() -> void:
	if _dash.is_empty() or not is_instance_valid(_dash.pick):
		return
	var chart: AdminChart = _dash.chart
	var rows: Array = chart.rows
	if rows.is_empty():
		_dash.pick.text = "No numbers yet."
		return
	if chart.sel < 0:
		var sa := 0
		var sb := 0
		for r in rows:
			sa += int(r.a)
			sb += int(r.b)
		_dash.pick.text = "%d sign-ups and %d AI builds in the last %d days." % [sa, sb, rows.size()]
		_dash.pick.add_theme_color_override("font_color", C.sub)
	else:
		var r: Dictionary = rows[chart.sel]
		_dash.pick.text = "%s: %d sign-ups, %d AI builds." % [AdminChart.long_day(str(r.day)), int(r.a), int(r.b)]
		_dash.pick.add_theme_color_override("font_color", C.primary)


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
var _test_lbl: Label


func _loading() -> Label:
	var wait := AdminUi.lbl("Loading...", 14, C.sub)
	wait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(wait)
	return wait


func _page_ai() -> void:
	var wait := _loading()
	net.rq({"t": "a_ai_get"}, "a_ai_res", func(m):
		ai_state = m
		if page == "ai" and body and is_instance_valid(body):
			wait.queue_free()
			_fill_ai())


func _fill_ai() -> void:
	var ready := bool(ai_state.get("ready", false))
	AdminUi.section(body, "Connection")
	var top := AdminUi.card(body, 16, 12)
	AdminUi.card_head(top, "link", AdminUi.ACC.sky, "Omni Route", "", AdminUi.pill("Ready" if ready else "Not set up yet", C.good if ready else C.warn))
	top.add_child(AdminUi.lbl("Studio builds games with AI through Omni Route. Paste the three values from your Omni Route account below. The key stays on the server: this app never shows it again, and players never see it.", 14, C.sub, 400))
	AdminUi.section(body, "Settings")
	var f := AdminUi.card(body, 16, 16)
	_base_f = AdminUi.labeled(f, "Base URL", AdminUi.field("https://.../v1", str(ai_state.get("base", ""))), "The address ending in /v1.")
	_base_f.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_URL
	_model_f = AdminUi.labeled(f, "Model", AdminUi.field("Exactly as Omni Route shows it", str(ai_state.get("model", ""))))
	var masked := str(ai_state.get("key", ""))
	_key_f = AdminUi.field("Paste a new key to replace it" if masked != "" else "Paste your API key", "", true)
	var kr := AdminUi.hbox(8)
	kr.add_child(_key_f)
	var eye: Button
	eye = AdminUi.icon_btn("eye", C.sub, func():
		_key_f.secret = not _key_f.secret
		(eye.get_meta("icon") as TextureRect).texture = AdminUi.icon_tex("eye" if _key_f.secret else "eye-slash"), true)
	kr.add_child(eye)
	AdminUi.labeled(f, "API key", kr, ("Saved key: %s. Leave the box empty to keep it." % masked) if masked != "" else "No key saved yet.")
	f.add_child(AdminUi.btn("Save", "primary", "check", _save_ai))
	AdminUi.section(body, "Test")
	var t := AdminUi.card(body, 16, 12)
	AdminUi.card_head(t, "bolt", AdminUi.ACC.amber, "Test connection", "Sends a tiny request with the saved settings. Save first if you changed something.")
	t.add_child(AdminUi.btn("Test connection", "outline", "bolt", _test_ai))
	_test_lbl = AdminUi.lbl("", 14, C.sub, 500, true)
	t.add_child(_test_lbl)
	if masked != "":
		AdminUi.section(body, "Danger zone")
		var d := AdminUi.card(body, 16, 12)
		AdminUi.card_head(d, "trash", AdminUi.ACC.red, "Remove the saved key", "Studio goes back to \"AI not set up yet\" and makes simpler games until you add a key again.")
		d.add_child(AdminUi.btn("Remove the saved key", "danger", "trash", func():
			net.rq({"t": "a_ai_set", "base": _base_f.text, "model": _model_f.text, "clear_key": true}, "a_ok", func(m):
				if m.get("ok", false):
					_show_main()
					toast("Key removed.")
				else:
					toast(str(m.get("why", "Couldn't remove it.")), false))))


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
		_last_save_ai = m
		if m.get("ok", false):
			_show_main()
			toast("Saved. Studio uses it from the next game." if m.get("ready", false) else "Saved. Add the base URL, model and key to switch AI on.")
		else:
			toast(str(m.get("why", "Couldn't save.")), false))


var _last_save_ai := {}
var _last_test := {}
var _last_save_agent := {}


func _test_ai() -> void:
	_test_lbl.add_theme_color_override("font_color", C.sub)
	_test_lbl.text = "Testing..."
	net.rq({"t": "a_ai_test"}, "a_ai_test_res", func(m):
		_last_test = m
		if not is_instance_valid(_test_lbl):
			return
		if m.get("ok", false):
			_test_lbl.add_theme_color_override("font_color", C.good)
			_test_lbl.text = "Connected. The AI answered in %.1f seconds." % (float(m.get("ms", 0)) / 1000.0)
		else:
			_test_lbl.add_theme_color_override("font_color", C.error)
			_test_lbl.text = "Didn't work: " + str(m.get("why", "no answer")))


# ---------------------------------------------------------------- AI agents

func _page_agents() -> void:
	var wait := _loading()
	net.rq({"t": "a_agents"}, "a_agents_res", func(m):
		agents_state = m
		for a in m.get("agents", []):
			if a.id == "studio_builder":
				agent_edit = a.duplicate(true)
		if page == "agents" and body and is_instance_valid(body):
			wait.queue_free()
			_fill_agents())


const GROUP_ICONS := {"Allowed objects": ["cube", "amber"], "Safety": ["shield-check", "green"]}


func _fill_agents() -> void:
	if agent_edit.is_empty():
		body.add_child(AdminUi.lbl("The server didn't send the Studio Builder agent. Update the server, then try again.", 14, C.error, 500, true))
		return
	var a := agent_edit
	var opts: Dictionary = a.get("opts", {})
	var head := AdminUi.card(body, 16, 12)
	AdminUi.card_head(head, "sparkles", AdminUi.ACC.pink, str(a.get("name", "Studio Builder")), str(a.get("job", "")) + " Its rules also apply when players change their game in words.")
	var on := AdminUi.toggle("Agent on", bool(a.get("on", true)), "Off means Studio makes simpler games without AI.")
	on.toggled.connect(func(v): a.on = v)
	var om := MarginContainer.new()
	om.add_theme_constant_override("margin_left", -16)
	om.add_theme_constant_override("margin_right", -16)
	om.add_child(on)
	head.add_child(om)
	if not bool(agents_state.get("ready", false)):
		var wr := AdminUi.hbox(10)
		wr.add_child(AdminUi.icon("exclamation-triangle", 20, C.warn))
		wr.add_child(AdminUi.lbl("Studio AI isn't set up yet, so players see \"AI not set up yet\". Add the key on the Studio AI tab.", 14, C.warn, 500, true))
		head.add_child(wr)
	var schema: Array = agents_state.get("schema", [])
	AdminUi.section(body, "Rules")
	var choices := AdminUi.card(body, 16, 16)
	var groups := {}
	for opt in schema:
		var fr: Array = opt.get("for", ["all"])
		if not (fr.has("all") or fr.has("studio_builder")):
			continue
		if opt.type == "choice":
			var ob := OptionButton.new()
			ob.focus_mode = Control.FOCUS_NONE
			ob.custom_minimum_size.y = 52
			ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ob.add_theme_font_size_override("font_size", 16)
			ob.add_theme_font_override("font", AdminUi.font(500))
			ob.clip_text = true
			ob.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
		AdminUi.section(body, g)
		var gc := AdminUi.card(body, 4, 0)
		if g == "Allowed objects":
			var hint := MarginContainer.new()
			for k in ["margin_left", "margin_right"]:
				hint.add_theme_constant_override(k, 12)
			hint.add_theme_constant_override("margin_top", 10)
			hint.add_theme_constant_override("margin_bottom", 4)
			hint.add_child(AdminUi.lbl("Switch off anything Studio must never use.", 14, C.sub, 400))
			gc.add_child(hint)
		var gi: Array = GROUP_ICONS.get(g, ["adjustments-horizontal", "sky"])
		for opt in groups[g]:
			var tg := AdminUi.toggle(str(opt.label), bool(opts.get(opt.key, opt.default)), "", gi[0], AdminUi.ACC[gi[1]])
			var key: String = opt.key
			tg.toggled.connect(func(v): opts[key] = v)
			gc.add_child(tg)
	AdminUi.section(body, "Extra rules")
	var ex := AdminUi.card(body, 16, 12)
	AdminUi.card_head(ex, "document-text", AdminUi.ACC.sky, "Optional", "Anything else the AI should always follow, in plain words.")
	var te := TextEdit.new()
	te.text = str(a.get("rules", ""))
	te.placeholder_text = "For example: Always put a star near the start."
	te.custom_minimum_size.y = 120
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.add_theme_font_size_override("font_size", 16)
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.text_changed.connect(func(): a.rules = te.text)
	te.focus_entered.connect(func():
		await get_tree().create_timer(0.4).timeout
		if is_instance_valid(te) and scroll:
			scroll.ensure_control_visible(te))
	ex.add_child(te)
	body.add_child(AdminUi.btn("Save rules", "primary", "check", _save_agent))
	var prev_lbl := AdminUi.lbl("", 14, C.sub, 400, true)
	body.add_child(AdminUi.btn("Show what the AI is told", "outline", "document-text", func():
		net.rq({"t": "a_agent_preview", "agent": a}, "a_agent_preview_res", func(m):
			if is_instance_valid(prev_lbl):
				prev_lbl.text = str(m.get("text", "")))))
	body.add_child(prev_lbl)


func _save_agent() -> void:
	get_viewport().gui_release_focus()
	DisplayServer.virtual_keyboard_hide()
	var a := agent_edit.duplicate(true)
	net.rq({"t": "a_agent_save", "agent": a}, "a_ok", func(m):
		_last_save_agent = m
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
			_last_save_agent = m2
			if m2.get("ok", false):
				toast("Rules saved. Studio uses them from the next game.")
			else:
				toast("Saved for new games, but not for changes: " + str(m2.get("why", "")), false)))


# ---------------------------------------------------------------- desktop test runs

# ADMIN_SHOT=/path/prefix ADMIN_PW=... [ADMIN_THEME=light|dark] [ADMIN_SAVES=1]
# saves login/dash/ai/agents screenshots, checks layout, and (with ADMIN_SAVES) re-saves the
# current AI settings and agent rules unchanged, then runs Test connection.
func _autotest() -> void:
	var pre := OS.get_environment("ADMIN_SHOT")
	_show_login()
	await get_tree().create_timer(1.5).timeout
	await _shot(pre + "login.png")
	_layout_check("login")
	_pw_field.text = OS.get_environment("ADMIN_PW")
	_do_login()
	var t := 0.0
	while not _signed_in and t < 90.0:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
	print("ADMIN AUTOTEST signed_in=", _signed_in, " accounts=", net.last_stats.get("accounts", -1), " days=", (net.last_stats.get("days", []) as Array).size())
	if not _signed_in:
		print("ADMIN AUTOTEST login_status=", _login_status.text if is_instance_valid(_login_status) else "")
		get_tree().quit()
		return
	for p in ["dash", "ai", "agents"]:
		page = p
		_show_main()
		await get_tree().create_timer(3.0).timeout
		await _shot(pre + p + ".png")
		_layout_check(p)
		scroll.scroll_vertical = 100000
		await get_tree().create_timer(0.6).timeout
		await _shot(pre + p + "_end.png")
		if p == "dash":
			_dash.chart.sel = 13
			_paint_pick()
			print("ADMIN AUTOTEST chart rows=", _dash.chart.rows.size(), " pick=", _dash.pick.text)
		if p == "ai":
			print("ADMIN AUTOTEST ai base=", ai_state.get("base", ""), " model=", ai_state.get("model", ""), " key_masked=", ai_state.get("key", ""), " ready=", ai_state.get("ready", false))
			if OS.get_environment("ADMIN_SAVES") == "1":
				if OS.get_environment("AI_BASE") != "":
					_base_f.text = OS.get_environment("AI_BASE")
					_model_f.text = OS.get_environment("AI_MODEL")
					_key_f.text = OS.get_environment("AI_KEY")
				_save_ai()
				await get_tree().create_timer(4.0).timeout
				print("ADMIN AUTOTEST save_ai=", JSON.stringify(_last_save_ai))
				await get_tree().create_timer(2.0).timeout
				await _shot(pre + "ai_saved.png")
				print("ADMIN AUTOTEST ai after save key_masked=", ai_state.get("key", ""), " base=", ai_state.get("base", ""))
			_test_ai()
			var w := 0.0
			while _last_test.is_empty() and w < 40.0:
				await get_tree().create_timer(0.5).timeout
				w += 0.5
			print("ADMIN AUTOTEST test=", JSON.stringify(_last_test))
			await _shot(pre + "ai_test.png")
		if p == "agents" and OS.get_environment("ADMIN_SAVES") == "1":
			if OS.get_environment("AGENT_RULE") != "":
				agent_edit.rules = OS.get_environment("AGENT_RULE")
				agent_edit.opts["allow_lava"] = false
			_save_agent()
			await get_tree().create_timer(5.0).timeout
			print("ADMIN AUTOTEST save_agent=", JSON.stringify(_last_save_agent).left(400))
			await _shot(pre + "agents_saved.png")
	get_tree().quit()


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("ADMIN AUTOTEST shot ", path)


## Prints any visible label whose text doesn't fit (cut off) and anything wider than the screen.
func _layout_check(name: String) -> void:
	var vw := get_viewport().get_visible_rect().size.x
	var bad := []
	var n := 0
	var stack: Array = [ui]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		for k in c.get_children():
			stack.append(k)
		if not (c is Control) or not (c as Control).is_visible_in_tree():
			continue
		var ctl := c as Control
		var r := ctl.get_global_rect()
		if r.size.x > 0 and (r.position.x < -1.0 or r.end.x > vw + 1.0) and not (ctl is ScrollContainer):
			bad.append("%s wider than screen (%d..%d)" % [ctl.get_class(), r.position.x, r.end.x])
		if c is Label:
			var l := c as Label
			if l.text == "":
				continue
			n += 1
			if l.autowrap_mode == TextServer.AUTOWRAP_OFF:
				var f := l.get_theme_font("font")
				var fs := l.get_theme_font_size("font_size")
				var need := f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				if need > l.size.x + 1.0:
					bad.append("cut: '%s' needs %d has %d" % [l.text.left(40), need, l.size.x])
			elif l.get_line_count() > l.get_visible_line_count() and l.max_lines_visible < 0:
				bad.append("lines hidden: '%s'" % l.text.left(40))
		elif c is Button and (c as Button).text != "":
			var b := c as Button
			if b.get_combined_minimum_size().x > b.size.x + 1.0:
				bad.append("button cut: '%s'" % b.text.left(40))
	print("ADMIN LAYOUT %s %s labels=%d problems=%d %s" % [name, "dark" if AdminUi.dark else "light", n, bad.size(), str(bad.slice(0, 12))])
