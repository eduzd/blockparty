class_name AdminUi
extends RefCounted
## Plux Admin's look: the Sky & Ink design system (UI Design.md), light and dark.
## Tokens, type scale, Heroicons v2 outline, 20dp hairline cards, 40dp icon badges,
## 12dp buttons with a spring press, switch rows, section titles and the Anton page title.

# ---------------------------------------------------------------- tokens

const PAL := {
	"sky": Color("37B1FF"), "sky_medium": Color("009CFF"), "sky_light": Color("AFE0FF"), "sky_xlight": Color("E3F4FF"),
	"ink": Color("202936"), "pink": Color("FF4BB7"), "success": Color("00BB77"), "warning": Color("B25E09"),
	"error": Color("DA2F2F"), "on_sky_dark": Color("00121F"),
}
const ACC := {
	"pink": Color("FF4BB7"), "red": Color("DA2F2F"), "sky": Color("37B1FF"), "amber": Color("F29A2E"),
	"green": Color("00BB77"), "ink": Color("202936"),
}
const LIGHT := {
	"primary": Color("009CFF"), "on_primary": Color("FFFFFF"), "primary_c": Color("E3F4FF"), "on_primary_c": Color("202936"),
	"error": Color("DA2F2F"), "bg": Color("FFFFFF"), "text": Color("000000"), "variant": Color("ECECEC"),
	"sub": Color("545454"), "lowest": Color("FFFFFF"), "low": Color("F9F9F9"), "card": Color("FFFFFF"),
	"high": Color("F5F5F5"), "highest": Color("ECECEC"), "inverse": Color("202936"), "on_inverse": Color("FFFFFF"),
	"outline": Color("CFCFCF"), "line": Color("E6E6E6"),
	"btn": Color("202936"), "on_btn": Color("FFFFFF"), "outline_btn": Color("000000"),
	"warn": Color("B25E09"), "good": Color("00BB77"),
}
const DARK := {
	"primary": Color("37B1FF"), "on_primary": Color("00121F"), "primary_c": Color("0B3550"), "on_primary_c": Color("E3F4FF"),
	"error": Color("FF6B6B"), "bg": Color("0E131A"), "text": Color("F4F6F9"), "variant": Color("202936"),
	"sub": Color("A7B0BE"), "lowest": Color("0A0E13"), "low": Color("121820"), "card": Color("18202B"),
	"high": Color("202936"), "highest": Color("2A3443"), "inverse": Color("FFFFFF"), "on_inverse": Color("202936"),
	"outline": Color("3A4556"), "line": Color("263040"),
	"btn": Color("37B1FF"), "on_btn": Color("00121F"), "outline_btn": Color("3A4556"),
	"warn": Color("F29A2E"), "good": Color("00BB77"),
}

static var dark := true
static var C: Dictionary = DARK

static var _fonts := {}
static var _icons := {}
static var _anton: Font


static func set_dark(d: bool) -> void:
	dark = d
	C = DARK if d else LIGHT


# ---------------------------------------------------------------- type

static func font(weight: int, spacing := 0) -> Font:
	var key := weight * 100 + spacing
	if _fonts.has(key):
		return _fonts[key]
	var fv := FontVariation.new()
	fv.base_font = load("res://ui/fonts/DMSans.ttf")
	fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	if spacing != 0:
		fv.spacing_glyph = spacing
	_fonts[key] = fv
	return fv


static func anton() -> Font:
	if _anton == null:
		var fv := FontVariation.new()
		fv.base_font = load("res://ui/fonts/Anton-Regular.ttf")
		fv.spacing_glyph = 0   # 0.4sp at 21sp rounds to 0 px
		_anton = fv
	return _anton


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
	t.default_font = font(400)
	t.default_font_size = 16
	t.set_color("font_color", "Label", C.text)
	# Outlined text fields: 8dp corners, 1dp outline, 2dp primary when focused.
	var le_n := box(C.bg, 8, C.outline, 1, 16, 12)
	var le_f := box(C.bg, 8, C.primary, 2, 15, 11)
	t.set_stylebox("normal", "LineEdit", le_n)
	t.set_stylebox("focus", "LineEdit", le_f)
	t.set_stylebox("read_only", "LineEdit", box(C.variant, 8, C.line, 1, 16, 12))
	t.set_color("font_color", "LineEdit", C.text)
	t.set_color("font_placeholder_color", "LineEdit", Color(C.sub, 0.8))
	t.set_color("caret_color", "LineEdit", C.primary)
	t.set_color("selection_color", "LineEdit", Color(C.primary, 0.3))
	t.set_stylebox("normal", "TextEdit", le_n)
	t.set_stylebox("focus", "TextEdit", le_f)
	t.set_color("font_color", "TextEdit", C.text)
	t.set_color("font_placeholder_color", "TextEdit", Color(C.sub, 0.8))
	t.set_color("caret_color", "TextEdit", C.primary)
	t.set_color("selection_color", "TextEdit", Color(C.primary, 0.3))
	t.set_color("background_color", "TextEdit", Color(0, 0, 0, 0))
	for st in ["normal", "hover", "focus", "disabled"]:
		t.set_stylebox(st, "OptionButton", box(C.bg, 8, C.outline, 1, 16, 11))
	t.set_stylebox("pressed", "OptionButton", box(Color(C.primary, 0.08), 8, C.primary, 2, 15, 10))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		t.set_color(k, "OptionButton", C.text)
	t.set_icon("arrow", "OptionButton", icon_tex("chevron-down"))
	t.set_color("modulate_arrow", "OptionButton", C.sub)
	t.set_constant("modulate_arrow", "OptionButton", 1)
	t.set_constant("arrow_margin", "OptionButton", 12)
	# Menus: surfaceContainer, 16dp corners, primary 12% on hover, check in primary.
	t.set_stylebox("panel", "PopupMenu", box(C.card, 16, C.line, 1, 8, 8))
	t.set_stylebox("hover", "PopupMenu", box(Color(C.primary, 0.12), 12, Color.TRANSPARENT, 0, 8, 0))
	t.set_color("font_color", "PopupMenu", C.text)
	t.set_color("font_hover_color", "PopupMenu", C.primary)
	t.set_constant("v_separation", "PopupMenu", 18)
	t.set_constant("item_start_padding", "PopupMenu", 12)
	t.set_constant("item_end_padding", "PopupMenu", 12)
	t.set_font_size("font_size", "PopupMenu", 16)
	t.set_font("font", "PopupMenu", font(500))
	t.set_icon("radio_checked", "PopupMenu", _sized_icon("check", 20, C.primary))
	t.set_icon("radio_unchecked", "PopupMenu", _blank(20))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C.sub, 0.35)
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


# ---------------------------------------------------------------- icons

static func icon_tex(name: String) -> Texture2D:
	if not _icons.has(name):
		var img := Image.new()
		var svg: String = HeroIcons.SVG.get(name, HeroIcons.SVG.get("squares-2x2", ""))
		img.load_svg_from_string(svg, 4.0)
		img.generate_mipmaps()
		_icons[name] = ImageTexture.create_from_image(img)
	return _icons[name]


## A tinted icon texture at an exact dp size (for theme icons, which aren't scaled).
static func _sized_icon(name: String, px: int, tint: Color) -> Texture2D:
	var key := "%s@%d#%s" % [name, px, tint.to_html()]
	if _icons.has(key):
		return _icons[key]
	var img := Image.new()
	var svg: String = HeroIcons.SVG.get(name, "").replace("#FFFFFF", "#" + tint.to_html(false))
	img.load_svg_from_string(svg, px / 24.0 * 2.0)
	img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	var tex := ImageTexture.create_from_image(img)
	_icons[key] = tex
	return tex


static func _blank(px: int) -> Texture2D:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	return ImageTexture.create_from_image(img)


static func icon(name: String, size: float, tint: Color) -> TextureRect:
	var r := TextureRect.new()
	r.texture = icon_tex(name)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(size, size)
	r.self_modulate = tint
	r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r


## IconBadge: 40dp square, 12dp corners, accent at 13% behind a 22dp icon in the accent.
static func badge(ic: String, accent: Color, side := 40.0, icon_size := 22.0, radius := 12.0) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(Color(accent, 0.13), radius))
	p.custom_minimum_size = Vector2(side, side)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var i := icon(ic, icon_size, accent)
	i.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	p.add_child(i)
	return p


# ---------------------------------------------------------------- text

static func lbl(text: String, size := 16, col: Color = Color(-1, 0, 0), weight := 400, wrap := true) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", C.text if col.r < 0 else col)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.custom_minimum_size.x = 40
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A one-line label that keeps its full width (never cut off).
static func tag(text: String, size := 14, col: Color = Color(-1, 0, 0), weight := 500) -> Label:
	var l := lbl(text, size, col, weight, false)
	return l


## Page title: Anton 21sp UPPERCASE, a 6dp gap, then the 8dp sky-gradient dot nudged 3dp down.
static func page_title(text: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_override("font", anton())
	l.add_theme_font_size_override("font_size", 21)
	l.add_theme_color_override("font_color", C.text)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	var dm := MarginContainer.new()
	dm.add_theme_constant_override("margin_top", 3)
	dm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot := AdminGrad.new(PAL.sky, PAL.sky_medium, 4.0)
	dot.custom_minimum_size = Vector2(8, 8)
	dm.add_child(dot)
	h.add_child(dm)
	h.set_meta("label", l)
	return h


## Section title: 12sp DM Sans Medium, uppercase, 1.2sp letter spacing, primary, 20dp in, 22dp over, 8dp under.
static func section(parent: Control, text: String, right: Control = null) -> HBoxContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 4)
	m.add_theme_constant_override("margin_top", 10)   # + the page's 12dp stack gap = 22dp
	m.add_theme_constant_override("margin_bottom", -4) # 12dp gap - 4 = 8dp under
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := hbox(8)
	var l := lbl(text.to_upper(), 12, C.primary, 500, false)
	l.add_theme_font_override("font", font(500, 1))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_vertical = Control.SIZE_SHRINK_END
	h.add_child(l)
	if right:
		h.add_child(right)
	m.add_child(h)
	parent.add_child(m)
	return h


static func vbox(sep := 12) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v


static func hbox(sep := 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ---------------------------------------------------------------- containers

## AppCard: 20dp corners, surfaceContainer, 1dp outlineVariant border, no shadow.
## Returns the inner VBox (meta "panel" is the card). pad = inner padding for loose content.
static func card(parent: Control, pad := 16.0, sep := 12) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(C.card, 20, C.line, 1, pad, pad))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := vbox(sep)
	p.add_child(v)
	parent.add_child(p)
	v.set_meta("panel", p)
	return v


## A card header: icon badge, title (titleMedium) and sub (bodyMedium, onSurfaceVariant).
static func card_head(parent: Control, ic: String, accent: Color, title: String, sub := "", right: Control = null) -> HBoxContainer:
	var h := hbox(14)
	h.add_child(badge(ic, accent))
	var tv := vbox(2)
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tv.add_child(lbl(title, 16, C.text, 600))
	if sub != "":
		tv.add_child(lbl(sub, 14, C.sub, 400))
	h.add_child(tv)
	if right:
		right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(right)
	parent.add_child(h)
	return h


## A small rounded status pill: the colour at 14% with the colour as text.
static func pill(text: String, col: Color, dot := true) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(Color(col, 0.14), 999, Color.TRANSPARENT, 0, 10, 4))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if dot:
		var d := Panel.new()
		d.add_theme_stylebox_override("panel", box(col, 4))
		d.custom_minimum_size = Vector2(8, 8)
		d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(d)
	var l := tag(text, 12, col, 600)
	h.add_child(l)
	p.add_child(h)
	p.set_meta("label", l)
	return p


# ---------------------------------------------------------------- buttons

## Press feedback: shrink to 96% with a spring (damping 0.55, stiffness 600), back on release.
static func press_fx(b: BaseButton) -> void:
	b.resized.connect(func(): b.pivot_offset = b.size / 2.0)
	var go := func(to: float):
		if not b.is_inside_tree():
			return
		var old: Tween = b.get_meta("press_tw") if b.has_meta("press_tw") else null
		if old and old.is_valid():
			old.kill()
		var tw := b.create_tween()
		if to < 1.0:
			tw.tween_property(b, "scale", Vector2(to, to), 0.09).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		else:
			tw.tween_property(b, "scale", Vector2.ONE, 0.32).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
		b.set_meta("press_tw", tw)
	b.button_down.connect(go.bind(0.96))
	b.button_up.connect(go.bind(1.0))


## kind: primary (Ink / Sky), outline, danger (red outline, destructive only), text.
static func btn(text: String, kind := "primary", ic := "", cb: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var primary := kind == "primary"
	b.custom_minimum_size.y = 52 if primary else 48
	b.add_theme_font_override("font", font(500))
	b.add_theme_font_size_override("font_size", 16 if primary else 14)
	var bg: Color
	var fg: Color
	var border := Color.TRANSPARENT
	var bw := 0
	match kind:
		"primary":
			bg = C.btn
			fg = C.on_btn
		"danger":
			bg = Color(ACC.red, 0.0)
			fg = ACC.red if not dark else C.error
			border = Color(fg, 0.6)
			bw = 1
		"text":
			bg = Color(0, 0, 0, 0)
			fg = C.primary
		_:
			bg = Color(0, 0, 0, 0)
			fg = C.text
			border = C.outline_btn
			bw = 1
	var ph := 22.0 if primary else 18.0
	var pv := 12.0 if primary else 10.0
	var pressed_bg := bg.lightened(0.12) if primary else Color(C.text, 0.06)
	if primary and not dark:
		pressed_bg = Color("1E1E1E")
	b.add_theme_stylebox_override("normal", box(bg, 12, border, bw, ph, pv))
	b.add_theme_stylebox_override("hover", box(bg, 12, border, bw, ph, pv))
	b.add_theme_stylebox_override("pressed", box(pressed_bg, 12, border, bw, ph, pv))
	b.add_theme_stylebox_override("hover_pressed", box(pressed_bg, 12, border, bw, ph, pv))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var dis_bg: Color = C.variant if primary else Color(0, 0, 0, 0)
	b.add_theme_stylebox_override("disabled", box(dis_bg, 12, Color(border, 0.4), bw, ph, pv))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(k, fg)
	b.add_theme_color_override("font_disabled_color", C.sub if primary else Color(fg, 0.45))
	if ic != "":
		b.icon = icon_tex(ic)
		var isz := 20 if primary else 19
		b.add_theme_constant_override("icon_max_width", isz)
		for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color", "icon_hover_pressed_color"]:
			b.add_theme_color_override(k, fg)
		b.add_theme_color_override("icon_disabled_color", C.sub if primary else Color(fg, 0.45))
		b.add_theme_constant_override("h_separation", 8)
	press_fx(b)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


## 48dp round icon button (top-bar actions, show/hide password).
static func icon_btn(ic: String, tint: Color, cb: Callable = Callable(), boxed := false) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(48, 48)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var n := box(Color(0, 0, 0, 0), 24 if not boxed else 8, C.outline if boxed else Color.TRANSPARENT, 1 if boxed else 0)
	var p := box(Color(C.text, 0.08), 24 if not boxed else 8, C.outline if boxed else Color.TRANSPARENT, 1 if boxed else 0)
	for st in ["normal", "hover", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, n)
	b.add_theme_stylebox_override("pressed", p)
	b.add_theme_stylebox_override("hover_pressed", p)
	var i := icon(ic, 24 if not boxed else 22, tint)
	i.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	i.position -= i.custom_minimum_size / 2.0
	b.add_child(i)
	b.set_meta("icon", i)
	press_fx(b)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


## ChipButton: pill, 40dp, 14/8 padding, labelLarge. Selected = Ink/white (light) or Sky/#00121F (dark).
static func chip(text: String, selected: bool, cb: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size.y = 40
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_override("font", font(500))
	b.add_theme_font_size_override("font_size", 14)
	var bg: Color = C.btn if selected else C.high
	var fg: Color = C.on_btn if selected else C.text
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, box(bg, 999, Color.TRANSPARENT, 0, 14, 8))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(k, fg)
	press_fx(b)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


# ---------------------------------------------------------------- fields and rows

static func field(placeholder: String, value := "", secret := false) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = value
	e.secret = secret
	e.custom_minimum_size.y = 52
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.add_theme_font_size_override("font_size", 16)
	e.virtual_keyboard_enabled = true
	return e


## A field with its label above (labelLarge-ish, onSurfaceVariant) and an optional hint under it.
static func labeled(parent: Control, label: String, ctrl: Control, hint := "") -> Control:
	var v := vbox(6)
	v.add_child(lbl(label, 14, C.sub, 500))
	v.add_child(ctrl)
	if hint != "":
		v.add_child(lbl(hint, 12, C.sub, 400))
	parent.add_child(v)
	return ctrl


## SwitchRow: optional icon badge, title (titleMedium) + optional sub, Material 3 switch on the
## right; the whole row toggles it. Returns a toggle-mode Button (button_pressed / toggled).
static func toggle(text: String, on: bool, sub := "", ic := "", accent: Color = Color(-1, 0, 0)) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_pressed = on
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var n := box(Color(0, 0, 0, 0), 16)
	var p := box(Color(C.text, 0.05), 16)
	for st in ["normal", "hover", "focus", "pressed", "hover_pressed", "disabled"]:
		b.add_theme_stylebox_override(st, n)
	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_left", 16)
	m.add_theme_constant_override("margin_right", 16)
	m.add_theme_constant_override("margin_top", 11)
	m.add_theme_constant_override("margin_bottom", 11)
	var h := hbox(14)
	if ic != "":
		h.add_child(badge(ic, C.primary if accent.r < 0 else accent))
	var tv := vbox(2)
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tv.add_child(lbl(text, 16, C.text, 600))
	if sub != "":
		tv.add_child(lbl(sub, 14, C.sub, 400))
	h.add_child(tv)
	var sw := AdminSwitch.new(on)
	h.add_child(sw)
	m.add_child(h)
	b.add_child(m)
	b.custom_minimum_size.y = 56
	var fit := func():
		var want := maxf(56.0, m.get_combined_minimum_size().y)
		if absf(b.custom_minimum_size.y - want) > 0.5:
			b.custom_minimum_size.y = want
	m.minimum_size_changed.connect(fit)
	b.resized.connect(fit)
	b.toggled.connect(func(v): sw.set_on(v, true, false))
	b.button_down.connect(func(): b.add_theme_stylebox_override("hover", p); b.add_theme_stylebox_override("normal", p))
	b.button_up.connect(func(): b.add_theme_stylebox_override("hover", n); b.add_theme_stylebox_override("normal", n))
	return b


## SettingRow (read-only): icon badge, title, value on the right in onSurfaceVariant. The value
## moves under the title in the primary colour when the row is narrow or the value is long.
static func row(parent: Control, ic: String, accent: Color, title: String, value: String, value_col: Color = Color(-1, 0, 0)) -> Label:
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_left", 16)
	m.add_theme_constant_override("margin_right", 16)
	m.add_theme_constant_override("margin_top", 11)
	m.add_theme_constant_override("margin_bottom", 11)
	var h := hbox(14)
	var bd := badge(ic, accent)
	h.add_child(bd)
	var tv := vbox(2)
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var tl := lbl(title, 16, C.text, 600)
	tv.add_child(tl)
	h.add_child(tv)
	var vc: Color = C.sub if value_col.r < 0 else value_col
	var right := lbl(value, 14, vc, 500, false)
	right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(right)
	var under := lbl(value, 14, vc if value_col.r >= 0 else C.primary, 500)
	under.visible = false
	tv.add_child(under)
	m.add_child(h)
	parent.add_child(m)
	var relayout := func():
		var narrow := m.size.x < 340.0 or right.text.length() > 18
		right.visible = not narrow
		under.visible = narrow
		under.text = right.text
		bd.visible = m.size.x >= 300.0
	m.resized.connect(relayout)
	right.set_meta("relayout", relayout)
	right.set_meta("under", under)
	return right


## Updates a row() value label (and its stacked twin).
static func set_row(right: Label, value: String, col: Color = Color(-1, 0, 0)) -> void:
	if not is_instance_valid(right):
		return
	right.text = value
	var under: Label = right.get_meta("under")
	if col.r >= 0:
		right.add_theme_color_override("font_color", col)
		under.add_theme_color_override("font_color", col)
	right.get_meta("relayout").call()


# ---------------------------------------------------------------- formatting

static func commas(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
