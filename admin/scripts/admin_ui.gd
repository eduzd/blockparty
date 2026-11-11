class_name AdminUi
extends RefCounted
## Plux Admin's look: Roblox-style colours on the Sky & Ink layout (rounded cards,
## DM Sans, 16 dp spacing, pill buttons, Heroicons).

const C := {
	"bg": Color("111216"), "card": Color("1d1f23"), "card2": Color("2a2d33"), "line": Color("393b3d"),
	"text": Color("f7f7f8"), "sub": Color("b8b9bd"), "faint": Color("7d7f85"),
	"blue": Color("335fff"), "blue_hi": Color("4f74ff"), "green": Color("3fc679"), "red": Color("e5484d"),
	"gold": Color("f5b82e"), "orange": Color("ff8a3d"),
}

static var _fonts := {}
static var _icons := {}


static func font(weight: int) -> Font:
	if _fonts.has(weight):
		return _fonts[weight]
	var fv := FontVariation.new()
	fv.base_font = load("res://ui/fonts/DMSans.ttf")
	fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	_fonts[weight] = fv
	return fv


static func box(bg: Color, radius: float, border := Color.TRANSPARENT, bw := 0, ph := 0.0, pv := 0.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(radius))
	s.corner_detail = 10
	s.anti_aliasing = true
	if bw > 0:
		s.border_color = border
		s.set_border_width_all(bw)
	s.content_margin_left = ph
	s.content_margin_right = ph
	s.content_margin_top = pv
	s.content_margin_bottom = pv
	return s


static func theme() -> Theme:
	var t := Theme.new()
	t.default_font = font(450)
	t.default_font_size = 15
	t.set_color("font_color", "Label", C.text)
	var le_n := box(C.card2, 12, C.line, 1, 12, 10)
	var le_f := box(C.card2, 12, C.blue, 2, 12, 10)
	t.set_stylebox("normal", "LineEdit", le_n)
	t.set_stylebox("focus", "LineEdit", le_f)
	t.set_stylebox("read_only", "LineEdit", box(C.card, 12, C.line, 1, 12, 10))
	t.set_color("font_color", "LineEdit", C.text)
	t.set_color("font_placeholder_color", "LineEdit", C.faint)
	t.set_color("caret_color", "LineEdit", C.blue_hi)
	t.set_color("selection_color", "LineEdit", Color(C.blue, 0.4))
	t.set_stylebox("normal", "TextEdit", le_n)
	t.set_stylebox("focus", "TextEdit", le_f)
	t.set_color("font_color", "TextEdit", C.text)
	t.set_color("font_placeholder_color", "TextEdit", C.faint)
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		t.set_stylebox(st, "OptionButton", box(C.card2 if st != "pressed" else C.line, 12, C.line, 1, 12, 9))
	t.set_color("font_color", "OptionButton", C.text)
	t.set_color("font_hover_color", "OptionButton", C.text)
	t.set_color("font_pressed_color", "OptionButton", C.text)
	t.set_color("font_focus_color", "OptionButton", C.text)
	t.set_stylebox("panel", "PopupMenu", box(C.card2, 14, C.line, 1, 6, 8))
	t.set_stylebox("hover", "PopupMenu", box(C.line, 10))
	t.set_color("font_color", "PopupMenu", C.text)
	t.set_color("font_hover_color", "PopupMenu", C.text)
	t.set_constant("v_separation", "PopupMenu", 14)
	t.set_font_size("font_size", "PopupMenu", 16)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.18)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 3
	sb.content_margin_right = 3
	t.set_stylebox("grabber", "VScrollBar", sb)
	t.set_stylebox("grabber_highlight", "VScrollBar", sb)
	t.set_stylebox("grabber_pressed", "VScrollBar", sb)
	t.set_stylebox("scroll", "VScrollBar", StyleBoxEmpty.new())
	t.set_stylebox("scroll", "HScrollBar", StyleBoxEmpty.new())
	t.set_stylebox("grabber", "HScrollBar", StyleBoxEmpty.new())
	return t


static func icon(name: String, size: float, tint: Color) -> TextureRect:
	var r := TextureRect.new()
	if not _icons.has(name):
		var img := Image.new()
		var svg: String = HeroIcons.SVG.get(name, HeroIcons.SVG.get("squares-2x2", ""))
		img.load_svg_from_string(svg, 4.0)
		img.generate_mipmaps()
		_icons[name] = ImageTexture.create_from_image(img)
	r.texture = _icons[name]
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(size, size)
	r.self_modulate = tint
	r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


static func lbl(text: String, size := 15, col: Color = C.text, weight := 450, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.custom_minimum_size.x = 60
	else:
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.clip_text = true
	return l


static func vbox(sep := 12) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return v


static func hbox(sep := 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return h


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## A rounded card; add children to the returned VBox (meta "panel" is the card).
static func card(parent: Control, title := "", sub := "") -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(C.card, 20, Color.TRANSPARENT, 0, 16, 16))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := vbox(12)
	p.add_child(v)
	parent.add_child(p)
	if title != "":
		v.add_child(lbl(title, 17, C.text, 700))
	if sub != "":
		v.add_child(lbl(sub, 13, C.sub, 450, true))
	v.set_meta("panel", p)
	return v


static func section(parent: Control, text: String) -> void:
	var l := lbl(text.to_upper(), 12, C.faint, 700)
	l.add_theme_constant_override("line_spacing", 0)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 6)
	m.add_theme_constant_override("margin_top", 6)
	m.add_child(l)
	parent.add_child(m)


## kind: primary, secondary, danger, ghost, gold
static func btn(text: String, kind := "primary", ic := "", cb: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size.y = 44
	b.add_theme_font_override("font", font(650))
	b.add_theme_font_size_override("font_size", 15)
	var bg: Color = {"primary": C.blue, "secondary": C.card2, "danger": Color(C.red, 0.16), "ghost": Color(0, 0, 0, 0), "gold": C.gold}.get(kind, C.blue)
	var fg: Color = {"primary": Color.WHITE, "secondary": C.text, "danger": C.red, "ghost": C.blue_hi, "gold": Color("1a1a1a")}.get(kind, Color.WHITE)
	var hi := bg.lightened(0.08) if kind != "ghost" else Color(1, 1, 1, 0.06)
	b.add_theme_stylebox_override("normal", box(bg, 22, Color.TRANSPARENT, 0, 16, 8))
	b.add_theme_stylebox_override("hover", box(bg, 22, Color.TRANSPARENT, 0, 16, 8))
	b.add_theme_stylebox_override("pressed", box(hi, 22, Color.TRANSPARENT, 0, 16, 8))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("disabled", box(Color(bg, 0.4), 22, Color.TRANSPARENT, 0, 16, 8))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(k, fg)
	b.add_theme_color_override("font_disabled_color", Color(fg, 0.5))
	if ic != "":
		var img := icon(ic, 18, fg)
		b.icon = img.texture
		b.add_theme_constant_override("icon_max_width", 18)
		b.add_theme_color_override("icon_normal_color", fg)
		b.add_theme_color_override("icon_hover_color", fg)
		b.add_theme_color_override("icon_pressed_color", fg)
		b.add_theme_color_override("icon_focus_color", fg)
		b.add_theme_constant_override("h_separation", 8)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func field(placeholder: String, value := "", secret := false) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = value
	e.secret = secret
	e.custom_minimum_size.y = 46
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.add_theme_font_size_override("font_size", 16)
	e.virtual_keyboard_enabled = true
	return e


static func labeled(parent: Control, label: String, ctrl: Control, hint := "") -> Control:
	var v := vbox(6)
	v.add_child(lbl(label, 13, C.sub, 600))
	v.add_child(ctrl)
	if hint != "":
		v.add_child(lbl(hint, 12, C.faint, 450, true))
	parent.add_child(v)
	return ctrl


static func toggle(text: String, on: bool, sub := "") -> CheckButton:
	var b := CheckButton.new()
	b.text = text
	b.button_pressed = on
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = 44
	b.add_theme_font_override("font", font(550))
	b.add_theme_font_size_override("font_size", 15)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(k, C.text)
	for st in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.add_theme_icon_override("checked", _switch_tex(true))
	b.add_theme_icon_override("unchecked", _switch_tex(false))
	if sub != "":
		b.tooltip_text = sub
	return b


static func _switch_tex(on: bool) -> Texture2D:
	var key := "sw_on" if on else "sw_off"
	if _icons.has(key):
		return _icons[key]
	var w := 52
	var h := 32
	var img := Image.create(w * 2, h * 2, false, Image.FORMAT_RGBA8)
	var track: Color = C.blue if on else C.line
	var r := h
	for y in h * 2:
		for x in w * 2:
			var cx := clampf(x, r, w * 2 - r)
			var d := Vector2(x - cx, y - r).length()
			var a := clampf(r - d, 0.0, 1.0)
			var col := track
			var kx := (w * 2 - r) if on else r
			var kd := Vector2(x - kx, y - r).length()
			if kd < r - 6:
				col = Color.WHITE
			elif kd < r - 5:
				col = track.lerp(Color.WHITE, r - 5 - kd)
			img.set_pixel(x, y, Color(col, a))
	img.resize(w, h, Image.INTERPOLATE_LANCZOS)
	var tex := ImageTexture.create_from_image(img)
	_icons[key] = tex
	return tex


static func pill(text: String, col: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(Color(col, 0.18), 10, Color.TRANSPARENT, 0, 8, 2))
	p.add_child(lbl(text, 12, col, 700))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p


## A tappable list row: icon or initial, title, subtitle, optional right text and pills.
static func row(title: String, sub: String, right := "", ic := "", cb: Callable = Callable(), pills := []) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = 60
	b.add_theme_stylebox_override("normal", box(C.card, 16))
	b.add_theme_stylebox_override("hover", box(C.card, 16))
	b.add_theme_stylebox_override("pressed", box(C.card2, 16))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in ["margin_left", "margin_right"]:
		m.add_theme_constant_override(k, 14)
	m.add_theme_constant_override("margin_top", 8)
	m.add_theme_constant_override("margin_bottom", 8)
	var h := hbox(12)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(h)
	if ic != "":
		var circ := PanelContainer.new()
		circ.add_theme_stylebox_override("panel", box(C.card2, 20))
		circ.custom_minimum_size = Vector2(40, 40)
		circ.mouse_filter = Control.MOUSE_FILTER_IGNORE
		circ.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if ic.length() <= 2:
			var l := lbl(ic.to_upper(), 16, C.text, 700)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			circ.add_child(l)
		else:
			var cc := CenterContainer.new()
			cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cc.add_child(icon(ic, 20, C.sub))
			circ.add_child(cc)
		h.add_child(circ)
	var v := vbox(2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var top := hbox(6)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tl := lbl(title, 15, C.text, 650)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(tl)
	for p in pills:
		top.add_child(pill(p[0], p[1]))
	v.add_child(top)
	if sub != "":
		v.add_child(lbl(sub, 13, C.sub))
	h.add_child(v)
	if right != "":
		var rl := lbl(right, 14, C.sub, 600)
		rl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(rl)
	if cb.is_valid():
		h.add_child(icon("chevron-right", 18, C.faint))
		b.pressed.connect(cb)
	b.add_child(m)
	b.resized.connect(func(): b.custom_minimum_size.y = maxf(60.0, m.get_combined_minimum_size().y))
	return b


static func human_bytes(n: float) -> String:
	if n >= 1e9:
		return "%.2f GB" % (n / 1e9)
	if n >= 1e6:
		return "%.1f MB" % (n / 1e6)
	if n >= 1e3:
		return "%d KB" % int(n / 1e3)
	return "%d B" % int(n)


static func ago(ts: int) -> String:
	if ts <= 0:
		return "never"
	var d := int(Time.get_unix_time_from_system()) - ts
	if d < 60:
		return "just now"
	if d < 3600:
		return "%d min ago" % (d / 60)
	if d < 86400:
		return "%d h ago" % (d / 3600)
	return "%d days ago" % (d / 86400)


static func date(ts: int) -> String:
	if ts <= 0:
		return "-"
	return Time.get_date_string_from_unix_time(ts)


static func commas(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
