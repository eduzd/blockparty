class_name UiKit
extends RefCounted
## Sky & Ink design system, translated from the Compose spec to Godot.
## Units are dp: the project's base viewport is 800x360 (a landscape phone).

# Palette (section 12.2)
const SKY := Color("#37B1FF")
const SKY_MEDIUM := Color("#009CFF")
const SKY_LIGHT := Color("#AFE0FF")
const SKY_EXTRA_LIGHT := Color("#E3F4FF")
const INK := Color("#202936")
const PINK := Color("#FF4BB7")
const SUCCESS := Color("#00BB77")
const ERROR := Color("#DA2F2F")
const AMBER := Color("#F29A2E")
const ON_SKY_DARK := Color("#00121F")

static var dark := false

static var LIGHT := {
	"primary": SKY_MEDIUM, "on_primary": Color.WHITE, "primary_container": SKY_EXTRA_LIGHT,
	"on_primary_container": INK, "secondary": PINK, "tertiary": SUCCESS, "error": ERROR,
	"background": Color("#FFFFFF"), "on_background": Color.BLACK, "surface": Color("#FFFFFF"),
	"on_surface": Color.BLACK, "surface_variant": Color("#ECECEC"), "on_surface_variant": Color("#545454"),
	"surface_container_low": Color("#F9F9F9"), "surface_container": Color.WHITE,
	"surface_container_high": Color("#F5F5F5"), "surface_container_highest": Color("#ECECEC"),
	"inverse_surface": INK, "inverse_on_surface": Color.WHITE, "outline": Color("#CFCFCF"),
	"outline_variant": Color("#E6E6E6"), "button": INK, "on_button": Color.WHITE,
	"outline_button_border": Color.BLACK,
}
static var DARK := {
	"primary": SKY, "on_primary": ON_SKY_DARK, "primary_container": Color("#0B3550"),
	"on_primary_container": SKY_EXTRA_LIGHT, "secondary": PINK, "tertiary": SUCCESS, "error": Color("#FF6B6B"),
	"background": Color("#0E131A"), "on_background": Color("#F4F6F9"), "surface": Color("#0E131A"),
	"on_surface": Color("#F4F6F9"), "surface_variant": INK, "on_surface_variant": Color("#A7B0BE"),
	"surface_container_low": Color("#121820"), "surface_container": Color("#18202B"),
	"surface_container_high": INK, "surface_container_highest": Color("#2A3443"),
	"inverse_surface": Color("#FFFFFF"), "inverse_on_surface": INK, "outline": Color("#3A4556"),
	"outline_variant": Color("#263040"), "button": SKY, "on_button": ON_SKY_DARK,
	"outline_button_border": Color("#3A4556"),
}

# Typography (section 12.3): [family, size, weight, letter spacing px]
const TYPE := {
	"display_small": ["anton", 34, 400, 0], "headline_large": ["anton", 21, 400, 0],
	"headline_small": ["dm", 22, 700, 0], "title_large": ["dm", 20, 600, 0],
	"title_medium": ["dm", 16, 600, 0], "title_small": ["dm", 14, 600, 0],
	"body_large": ["dm", 16, 400, 0], "body_medium": ["dm", 14, 400, 0], "body_small": ["dm", 12, 400, 0],
	"label_large": ["dm", 14, 500, 0], "label_medium": ["dm", 12, 500, 0], "label_small": ["dm", 11, 500, 0],
	"section": ["dm", 12, 500, 1],
}

static var _fonts := {}
static var _icons := {}


static func c(role: String) -> Color:
	return (DARK if dark else LIGHT)[role]


static func font(family: String, weight: int, spacing: int = 0) -> Font:
	var key := "%s-%d-%d" % [family, weight, spacing]
	if _fonts.has(key):
		return _fonts[key]
	var fv := FontVariation.new()
	if family == "anton":
		fv.base_font = load("res://ui/fonts/Anton-Regular.ttf")
	else:
		fv.base_font = load("res://ui/fonts/DMSans.ttf")
		fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	fv.spacing_glyph = spacing
	_fonts[key] = fv
	return fv


static func type_font(token: String) -> Font:
	var t: Array = TYPE[token]
	return font(t[0], t[2], t[3])


static func style_text(ctrl: Control, token: String, color: Color) -> void:
	var t: Array = TYPE[token]
	ctrl.add_theme_font_override("font", font(t[0], t[2], t[3]))
	ctrl.add_theme_font_size_override("font_size", t[1])
	ctrl.add_theme_color_override("font_color", color)


static func label(text: String, token: String, color: Color, wrap := true) -> Label:
	var l := Label.new()
	l.text = text
	style_text(l, token, color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## Heroicons outline texture, rendered from the bundled SVG at 4x.
static func icon_texture(name: String) -> Texture2D:
	if _icons.has(name):
		return _icons[name]
	var img := Image.new()
	img.load_svg_from_string(HeroIcons.SVG[name], 4.0)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_icons[name] = tex
	return tex


static func icon(name: String, size: float, tint: Color) -> TextureRect:
	var r := TextureRect.new()
	r.texture = icon_texture(name)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(size, size)
	r.self_modulate = tint
	r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


static func box(bg: Color, radius: float, border: Color = Color.TRANSPARENT, border_w: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(radius))
	s.corner_detail = 12
	s.anti_aliasing = true
	if border_w > 0:
		s.border_color = border
		s.set_border_width_all(border_w)
	return s


static func pad(s: StyleBox, h: float, v: float) -> StyleBox:
	s.content_margin_left = h
	s.content_margin_right = h
	s.content_margin_top = v
	s.content_margin_bottom = v
	return s


static func margin(child: Control, left: float, top: float, right: float, bottom: float) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", int(left))
	m.add_theme_constant_override("margin_top", int(top))
	m.add_theme_constant_override("margin_right", int(right))
	m.add_theme_constant_override("margin_bottom", int(bottom))
	m.mouse_filter = Control.MOUSE_FILTER_PASS
	m.add_child(child)
	return m


static func vbox(gap: float = 0) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", int(gap))
	return b


static func hbox(gap: float = 0) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", int(gap))
	return b


## Press feedback: shrink to 96% with a spring (damping 0.55, stiffness 600).
static func add_press_shrink(ctrl: Control) -> void:
	var shrink := func(down: bool):
		ctrl.pivot_offset = ctrl.size / 2.0
		var tw := ctrl.create_tween()
		tw.set_trans(Tween.TRANS_SPRING if not down else Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(ctrl, "scale", Vector2.ONE * (0.96 if down else 1.0), 0.12 if down else 0.3)
	if ctrl is BaseButton:
		ctrl.button_down.connect(shrink.bind(true))
		ctrl.button_up.connect(shrink.bind(false))


static func _button(text: String, icon_name: String, cb: Callable, fill: Color, fg: Color, border: Color, border_w: int,
		min_h: float, pad_h: float, pad_v: float, token: String, icon_px: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, min_h)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_PASS
	var t: Array = TYPE[token]
	b.add_theme_font_override("font", font("dm", 500))
	b.add_theme_font_size_override("font_size", t[1])
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(state, fg)
	b.add_theme_color_override("font_disabled_color", c("on_surface_variant"))
	var normal := pad(box(fill, 12, border, border_w), pad_h, pad_v)
	var pressed := pad(box(fill.lerp(c("on_surface"), 0.12) if fill.a > 0 else Color(c("on_surface"), 0.10), 12, border, border_w), pad_h, pad_v)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.add_theme_stylebox_override("disabled", pad(box(c("surface_variant"), 12), pad_h, pad_v))
	if icon_name != "":
		b.icon = icon_texture(icon_name)
		b.add_theme_constant_override("icon_max_width", icon_px)
		b.add_theme_constant_override("h_separation", 8)
		for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color", "icon_hover_pressed_color"]:
			b.add_theme_color_override(state, fg)
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if cb.is_valid():
		b.pressed.connect(cb)
	add_press_shrink(b)
	return b


## Primary: Ink (light) / Sky (dark), 52dp min height, 12dp corners, 22/12 padding.
static func primary_button(text: String, icon_name: String, cb: Callable) -> Button:
	return _button(text, icon_name, cb, c("button"), c("on_button"), Color.TRANSPARENT, 0, 52, 22, 12, "title_medium", 20)


## Outline: transparent, 1dp border, 48dp min height, 18/10 padding, titleSmall.
static func outline_button(text: String, icon_name: String, cb: Callable) -> Button:
	return _button(text, icon_name, cb, Color.TRANSPARENT, c("on_surface"), c("outline_button_border"), 1, 48, 18, 10, "title_small", 19)


static func text_button(text: String, color: Color, cb: Callable) -> Button:
	var b := _button(text, "", cb, Color.TRANSPARENT, color, Color.TRANSPARENT, 0, 40, 12, 8, "label_large", 0)
	b.autowrap_mode = TextServer.AUTOWRAP_OFF
	return b


## Chip: pill, 40dp min height, 14/8 padding, labelLarge. Selected = Ink/Sky.
static func chip(text: String, selected: bool, cb: Callable) -> Button:
	var fill := c("button") if selected else c("surface_container_high")
	var fg := c("on_button") if selected else c("on_surface")
	var b := _button(text, "", cb, fill, fg, Color.TRANSPARENT, 0, 40, 14, 8, "label_large", 17)
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		var sb: StyleBoxFlat = b.get_theme_stylebox(st)
		sb.set_corner_radius_all(20)
	b.add_theme_font_override("font", font("dm", 500))
	b.autowrap_mode = TextServer.AUTOWRAP_OFF
	return b


## Section title: uppercase 12sp Medium, 1.2sp spacing, primary, 20 start / 22 top / 8 bottom.
static func section_title(text: String) -> Control:
	return margin(label(text.to_upper(), "section", c("primary"), false), 20, 22, 20, 8)


## Card: 16dp side margin, 20dp corners, surfaceContainer, 1dp outlineVariant, no shadow.
static func card() -> Array:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", box(c("surface_container"), 20, c("outline_variant"), 1))
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var inner := vbox(0)
	panel.add_child(inner)
	return [margin(panel, 16, 0, 16, 0), inner]


## Icon badge: 40dp, 12dp corners, accent 13% behind a 22dp accent icon.
static func icon_badge(icon_name: String, tint: Color) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(40, 40)
	p.add_theme_stylebox_override("panel", box(Color(tint, 0.13), 12))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ic := icon(icon_name, 22, tint)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_child(ic)
	return p


## Settings row: badge, 14dp gap, title/sub, value, chevron. Padding 16/13. Whole row taps.
## Long values (over 18 chars) go under the title in the primary colour.
static func setting_row(icon_name: String, title: String, sub: String, value: String, tint: Color, cb: Callable) -> Control:
	var row := TapRow.new()
	row.on_tap = cb
	var h := hbox(0)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(icon_badge(icon_name, tint))
	h.add_child(_spacer(14))
	var col := vbox(0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(label(title, "title_medium", c("on_surface")))
	var stacked := value != "" and value.length() > 18
	if stacked:
		col.add_child(label(value, "body_medium", c("primary")))
	if sub != "":
		col.add_child(label(sub, "body_medium", c("on_surface_variant")))
	h.add_child(col)
	if value != "" and not stacked:
		var v := label(value, "body_medium", c("on_surface_variant"), false)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		h.add_child(margin(v, 8, 0, 0, 0))
	h.add_child(icon("chevron-right", 24, c("on_surface_variant")))
	for ch in h.get_children():
		ch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(margin(h, 16, 13, 16, 13))
	row.get_child(0).mouse_filter = Control.MOUSE_FILTER_IGNORE
	return row


static func _spacer(w: float, hgt: float = 0) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(w, hgt)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s


static func vspace(hgt: float) -> Control:
	return _spacer(0, hgt)


## Outlined text field: 8dp corners, 1dp outline (2dp primary when focused), 56dp tall.
static func text_field(placeholder: String, value: String, max_len: int, hint: String = "") -> Array:
	var col := vbox(4)
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = value
	e.max_length = max_len
	e.custom_minimum_size = Vector2(0, 56)
	e.mouse_filter = Control.MOUSE_FILTER_PASS
	var t: Array = TYPE["body_large"]
	e.add_theme_font_override("font", font("dm", 400))
	e.add_theme_font_size_override("font_size", t[1])
	e.add_theme_color_override("font_color", c("on_surface"))
	e.add_theme_color_override("font_placeholder_color", c("on_surface_variant"))
	e.add_theme_color_override("caret_color", c("primary"))
	e.add_theme_color_override("selection_color", Color(c("primary"), 0.3))
	e.add_theme_stylebox_override("normal", pad(box(Color.TRANSPARENT, 8, c("outline"), 1), 16, 14))
	e.add_theme_stylebox_override("focus", pad(box(Color.TRANSPARENT, 8, c("primary"), 2), 15, 13))
	col.add_child(e)
	if hint != "":
		col.add_child(margin(label(hint, "body_small", c("on_surface_variant")), 16, 0, 16, 0))
	return [margin(col, 16, 0, 16, 0), e]


## Hero action card: 16/10 margin, 24dp corners, sky gradient, 22dp padding,
## title (titleLarge, Ink), sub (bodyMedium, Ink 80%), 64dp Ink box with a 32dp white icon.
static func hero_card(title: String, sub: String, icon_name: String, cb: Callable) -> Control:
	var row := TapRow.new()
	row.on_tap = cb
	row.gradient_radius = 24
	var h := hbox(12)
	var col := vbox(4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_child(label(title, "title_large", INK))
	col.add_child(label(sub, "body_medium", Color(INK, 0.8)))
	h.add_child(col)
	var ink_box := PanelContainer.new()
	ink_box.custom_minimum_size = Vector2(64, 64)
	ink_box.add_theme_stylebox_override("panel", box(INK, 20))
	var ic := icon(icon_name, 32, Color.WHITE)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ink_box.add_child(ic)
	h.add_child(ink_box)
	for n in [h, col, ink_box]:
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for l in col.get_children():
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := margin(h, 22, 22, 22, 22)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(m)
	add_press_shrink_row(row)
	return margin(row, 16, 10, 16, 10)


static func add_press_shrink_row(row: TapRow) -> void:
	row.pressed_changed.connect(func(down: bool):
		row.pivot_offset = row.size / 2.0
		var tw := row.create_tween()
		tw.set_trans(Tween.TRANS_SPRING if not down else Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(row, "scale", Vector2.ONE * (0.96 if down else 1.0), 0.12 if down else 0.3))


## Avatar: Sky circle with Ink initials at 38% of the size.
static func avatar(size: float, name: String, av: int = -1) -> Control:
	if av >= 0 and av < AvatarArt.COUNT:
		return AvatarArt.make(av, size)
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(size, size)
	p.add_theme_stylebox_override("panel", box(SKY, size / 2.0))
	var parts := name.strip_edges().split(" ", false)
	var ini := ""
	if parts.size() > 0:
		ini += parts[0].substr(0, 1)
	if parts.size() > 1:
		ini += parts[parts.size() - 1].substr(0, 1)
	if ini == "":
		var ic := icon("user-circle", size * 0.5, INK)
		ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		p.add_child(ic)
	else:
		var l := Label.new()
		l.text = ini.to_upper()
		l.add_theme_font_override("font", font("dm", 600))
		l.add_theme_font_size_override("font_size", int(size * 0.38))
		l.add_theme_color_override("font_color", INK)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		p.add_child(l)
	return p


## Pill: fully round, black 55%, white 11sp SemiBold, 8/3 padding.
static func pill(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font("dm", 600))
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_stylebox_override("normal", pad(box(Color(0, 0, 0, 0.55), 50), 8, 3))
	return l


## Snackbar (M3 default): inverseSurface, inverseOnSurface text, 4dp corners.
static func snackbar(text: String, action: String = "", cb: Callable = Callable()) -> Array:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", pad(box(c("inverse_surface"), 4), 16, 6))
	var h := hbox(8)
	var l := label(text, "body_medium", c("inverse_on_surface"))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(0, 36)
	h.add_child(l)
	if action != "":
		h.add_child(text_button(action, SKY if not dark else SKY_MEDIUM, cb))
	p.add_child(h)
	return [p, l]


## Page with the pinned Anton uppercase title and the sky dot; content scrolls below.
## Returns [root, content_vbox].
static func pinned_page(title: String, back_cb: Callable, leading: Control = null, trailing: Array = []) -> Array:
	var root := vbox(0)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var head := hbox(0)
	if back_cb.is_valid():
		var back := Button.new()
		back.flat = true
		back.icon = icon_texture("arrow-left")
		back.add_theme_constant_override("icon_max_width", 24)
		back.add_theme_color_override("icon_normal_color", c("on_background"))
		back.add_theme_color_override("icon_pressed_color", c("on_background"))
		back.add_theme_color_override("icon_hover_color", c("on_background"))
		back.custom_minimum_size = Vector2(48, 48)
		back.focus_mode = Control.FOCUS_NONE
		back.pressed.connect(back_cb)
		head.add_child(back)
	if leading:
		head.add_child(leading)
		head.add_child(_spacer(12))
	var t := label(title.to_upper(), "headline_large", c("on_background"), false)
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.clip_text = true
	# clip_text drops the label's minimum width to 0; keep its natural width (capped
	# so actions always fit on a 360dp phone) so the title never collapses.
	var natural: float = t.get_theme_font("font").get_string_size(t.text, HORIZONTAL_ALIGNMENT_LEFT, -1, t.get_theme_font_size("font_size")).x
	var room := 330.0 - (48.0 if back_cb.is_valid() else 0.0) - (56.0 if leading else 0.0) - 48.0 * trailing.size()
	t.custom_minimum_size.x = minf(natural + 1.0, maxf(room, 120.0))
	head.add_child(t)
	head.add_child(_spacer(6))
	var dot := GradientShape.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.radius = 4
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.position.y = 3
	var dot_wrap := margin(dot, 0, 6, 0, 0)
	head.add_child(dot_wrap)
	var fill := _spacer(0)
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(fill)
	for tr in trailing:
		head.add_child(tr)
	for ch in head.get_children():
		ch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	root.add_child(margin(head, 4 if back_cb.is_valid() else 20, 12, 8 if not trailing.is_empty() else 20, 4))
	var divider := ColorRect.new()
	divider.color = c("outline_variant")
	divider.custom_minimum_size = Vector2(0, 1)
	divider.modulate.a = 0.0
	root.add_child(divider)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.get_v_scroll_bar().modulate.a = 0.0
	scroll.get_v_scroll_bar().value_changed.connect(func(v: float): divider.modulate.a = 1.0 if v > 0.5 else 0.0)
	root.add_child(scroll)
	var limiter := WidthLimiter.new()
	limiter.max_width = 760
	limiter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(limiter)
	var content := vbox(0)
	limiter.add_child(content)
	return [root, content]


static func end_padding() -> Control:
	return vspace(24)


# ------------------------------------------------------------------ navigation and social pieces

## Icon button (48dp touch target, 24dp icon) for top-bar actions. Optional badge count.
static func icon_button(icon_name: String, cb: Callable, tint: Color = Color(0, 0, 0, 0), badge_count := 0) -> Control:
	var b := Button.new()
	b.flat = true
	b.icon = icon_texture(icon_name)
	b.add_theme_constant_override("icon_max_width", 24)
	var col := tint if tint.a > 0 else c("on_background")
	for st in ["icon_normal_color", "icon_pressed_color", "icon_hover_color", "icon_focus_color", "icon_hover_pressed_color"]:
		b.add_theme_color_override(st, col)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var press := box(Color(c("on_surface"), 0.10), 24)
	b.add_theme_stylebox_override("pressed", press)
	b.add_theme_stylebox_override("hover_pressed", press)
	b.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	b.custom_minimum_size = Vector2(48, 48)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_PASS
	b.pressed.connect(cb)
	if badge_count > 0:
		var bd := badge(badge_count)
		bd.position = Vector2(26, 6)
		b.add_child(bd)
	return b


## Count badge (Material 3 large badge): error colour, 16dp tall, white labelSmall.
static func badge(count: int) -> Control:
	var l := Label.new()
	l.text = str(count) if count < 100 else "99+"
	l.add_theme_font_override("font", font("dm", 600))
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var sb := box(c("error"), 8)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	l.add_theme_stylebox_override("normal", sb)
	l.custom_minimum_size = Vector2(16, 16)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## One navigation destination: 64x32 indicator pill (primary 14% when selected) with
## a 24dp icon, then the 12sp label. Selected icon and label use primary. The parts are
## kept on the row so nav_update can restyle it in place: the bar is built once and never
## rebuilt, so it never jumps or flickers.
static func _nav_item(item: Dictionary, selected: bool, cb: Callable, vertical_gap: float) -> Control:
	var row := TapRow.new()
	row.on_tap = cb
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var col := vbox(4)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pill_box := PanelContainer.new()
	pill_box.custom_minimum_size = Vector2(64, 32)
	pill_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pill_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ic := icon(str(item.icon), 24, Color.WHITE)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pill_box.add_child(ic)
	# The badge floats over the pill's top-right corner and takes no layout space.
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bd := badge(1)
	bd.position = Vector2(38, 0)
	bd.visible = false
	holder.add_child(bd)
	col.add_child(pill_box)
	var l := Label.new()
	l.text = str(item.label)
	l.add_theme_font_size_override("font_size", 12)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(l)
	row.add_child(margin(col, 0, vertical_gap, 0, vertical_gap))
	row.get_child(0).mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(holder)
	row.set_meta("parts", {"pill": pill_box, "icon": ic, "label": l, "badge": bd, "sel": null, "n": -1})
	_nav_item_style(row, selected, int(item.get("badge", 0)))
	return row


static func _nav_item_style(row: Control, selected: bool, n: int) -> void:
	var parts: Dictionary = row.get_meta("parts")
	if parts.sel != selected:
		parts.sel = selected
		var tint := c("primary") if selected else c("on_surface_variant")
		parts.pill.add_theme_stylebox_override("panel", box(Color(c("primary"), 0.14 if selected else 0.0), 16))
		parts.icon.self_modulate = tint
		parts.label.add_theme_font_override("font", font("dm", 600 if selected else 500))
		parts.label.add_theme_color_override("font_color", tint)
	if parts.n != n:
		parts.n = n
		var bd: Label = parts.badge
		bd.visible = n > 0
		bd.text = str(n) if n < 100 else "99+"
		bd.reset_size()
		_place_badge.call_deferred(row)


## Puts the badge on the indicator pill's top-right corner once layout is done.
static func _place_badge(row: Control) -> void:
	if not is_instance_valid(row):
		return
	var parts: Dictionary = row.get_meta("parts")
	var bd: Label = parts.badge
	var pill: Control = parts.pill
	var off := pill.get_global_rect().position - row.get_global_rect().position
	var w := maxf(bd.size.x, 16.0)
	bd.position = Vector2(off.x + 64.0 - w * 0.5 - 8.0, off.y - 4.0)


## Restyles a nav bar or rail in place (selected tab, badges, gesture-bar inset).
static func nav_update(nav: Control, items: Array, selected: int, bottom_inset: float = -1.0) -> void:
	if nav == null or not is_instance_valid(nav):
		return
	var rows: Array = nav.get_meta("rows", [])
	for i in mini(rows.size(), items.size()):
		_nav_item_style(rows[i], i == selected, int(items[i].get("badge", 0)))
	var sp = nav.get_meta("inset") if nav.has_meta("inset") else null
	if bottom_inset >= 0.0 and sp != null and is_instance_valid(sp):
		(sp as Control).custom_minimum_size.y = bottom_inset


## Bottom navigation bar (phones under 600dp): surfaceContainerLow, 80dp + the
## gesture-bar inset, items share the width. Its background runs behind the phone's own
## navigation bar; the items always sit above it.
static func nav_bar(items: Array, selected: int, cb: Callable, bottom_inset: float) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(c("surface_container_low"), 0))
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	var col := vbox(0)
	var line := ColorRect.new()
	line.color = c("outline_variant")
	line.custom_minimum_size = Vector2(0, 1)
	col.add_child(line)
	var h := hbox(0)
	h.custom_minimum_size = Vector2(0, 79)
	var rows := []
	for i in items.size():
		var it := _nav_item(items[i], i == selected, cb.bind(i), 12)
		rows.append(it)
		h.add_child(it)
	col.add_child(h)
	var sp := vspace(bottom_inset)
	col.add_child(sp)
	p.add_child(col)
	p.set_meta("rows", rows)
	p.set_meta("inset", sp)
	# Badges are placed from the row width, which is only known after layout.
	h.resized.connect(func():
		for r in rows:
			var parts: Dictionary = r.get_meta("parts")
			var n: int = parts.n
			parts.n = -1
			_nav_item_style(r, bool(parts.sel), n))
	return p


## Side rail (600dp and wider): 80dp wide, same colours, items centred vertically.
static func nav_rail(items: Array, selected: int, cb: Callable) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(c("surface_container_low"), 0))
	p.custom_minimum_size = Vector2(80, 0)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	var h := hbox(0)
	var col := vbox(12)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var rows := []
	for i in items.size():
		var it := _nav_item(items[i], i == selected, cb.bind(i), 4)
		it.size_flags_horizontal = Control.SIZE_FILL
		rows.append(it)
		col.add_child(it)
	p.set_meta("rows", rows)
	col.resized.connect(func():
		for r in rows:
			var parts: Dictionary = r.get_meta("parts")
			var n: int = parts.n
			parts.n = -1
			_nav_item_style(r, bool(parts.sel), n))
	h.add_child(col)
	var line := ColorRect.new()
	line.color = c("outline_variant")
	line.custom_minimum_size = Vector2(1, 0)
	h.add_child(line)
	p.add_child(h)
	return p


## Search field: 12dp corners, 20dp magnifying glass, clear (x-circle) once there is text.
static func search_field(placeholder: String, value: String = "") -> Array:
	var holder := PanelContainer.new()
	var normal := box(Color.TRANSPARENT, 12, c("outline"), 1)
	var focused := box(Color.TRANSPARENT, 12, c("primary"), 2)
	holder.add_theme_stylebox_override("panel", normal)
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	var h := hbox(8)
	h.add_child(_spacer(6))
	var glass := icon("magnifying-glass", 20, c("on_surface_variant"))
	glass.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(glass)
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = value
	e.max_length = 30
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.custom_minimum_size = Vector2(0, 54)
	e.add_theme_font_override("font", font("dm", 400))
	e.add_theme_font_size_override("font_size", 16)
	e.add_theme_color_override("font_color", c("on_surface"))
	e.add_theme_color_override("font_placeholder_color", c("on_surface_variant"))
	e.add_theme_color_override("caret_color", c("primary"))
	e.add_theme_color_override("selection_color", Color(c("primary"), 0.3))
	for st in ["normal", "focus", "read_only"]:
		e.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	e.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
	h.add_child(e)
	var clear := icon_button("x-circle", func(): e.text = ""; e.text_changed.emit(""), c("on_surface_variant"))
	clear.visible = value != ""
	h.add_child(clear)
	e.text_changed.connect(func(t: String): clear.visible = t != "")
	e.focus_entered.connect(func(): holder.add_theme_stylebox_override("panel", focused))
	e.focus_exited.connect(func(): holder.add_theme_stylebox_override("panel", normal))
	holder.add_child(h)
	return [margin(holder, 16, 4, 16, 4), e]


## Empty state: 32/56 padding, 44dp icon, title and sub centred.
static func empty_state(icon_name: String, title: String, sub: String, action: Control = null) -> Control:
	var col := vbox(0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var ic := icon(icon_name, 44, c("on_surface_variant"))
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(ic)
	col.add_child(vspace(12))
	var t := label(title, "title_medium", c("on_surface"))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(t)
	var s := label(sub, "body_medium", c("on_surface_variant"))
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(s)
	if action:
		col.add_child(vspace(16))
		action.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(action)
	return margin(col, 32, 40, 32, 40)


## Avatar with a presence dot (success green with a background-coloured ring).
static func avatar_presence(size: float, name: String, online: bool, av: int = -1) -> Control:
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(size, size)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var art := avatar(size, name, av)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(art)
	if online:
		var d := maxf(10.0, size * 0.28)
		var dot := Panel.new()
		dot.add_theme_stylebox_override("panel", box(SUCCESS, d / 2.0, c("surface_container"), 2))
		dot.size = Vector2(d, d)
		dot.position = Vector2(size - d + 1, size - d + 1)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wrap.add_child(dot)
	return wrap


## Person row inside a card: avatar (with presence), name (titleMedium), sub line,
## optional trailing controls. The whole row taps unless cb is empty.
static func person_row(name: String, sub: String, online: bool, cb: Callable, trailing: Array = [], sub_color: Color = Color(0, 0, 0, 0), av: int = -1) -> Control:
	var row := TapRow.new()
	row.on_tap = cb
	var h := hbox(14)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(avatar_presence(44, name, online, av))
	var col := vbox(0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := label(name, "title_medium", c("on_surface"), false)
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.clip_text = true
	col.add_child(t)
	if sub != "":
		var s := label(sub, "body_medium", sub_color if sub_color.a > 0 else c("on_surface_variant"), false)
		s.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		s.clip_text = true
		col.add_child(s)
	h.add_child(col)
	for tr in trailing:
		h.add_child(tr)
	for ch in h.get_children():
		ch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(margin(h, 16, 11, 12 if not trailing.is_empty() else 16, 11))
	row.get_child(0).mouse_filter = Control.MOUSE_FILTER_IGNORE
	return row


## Small buttons used inside rows (36dp tall): filled Ink/Sky or outline.
static func small_button(text: String, filled: bool, cb: Callable, icon_name := "") -> Button:
	var b := _button(text, icon_name, cb, c("button") if filled else Color.TRANSPARENT,
		c("on_button") if filled else c("on_surface"), Color.TRANSPARENT if filled else c("outline_button_border"),
		0 if filled else 1, 36, 14, 6, "label_large", 16)
	b.autowrap_mode = TextServer.AUTOWRAP_OFF
	return b


## Profile header (16/10 margin, 24dp corners, surfaceContainer, 16dp padding, 72dp
## avatar, name titleLarge, @username primary). `actions` sit full width below.
static func profile_header(name: String, username: String, bio: String, online: bool, actions: Array, note := "", av: int = -1) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", pad(box(c("surface_container"), 24, c("outline_variant"), 1), 16, 16))
	var col := vbox(0)
	var h := hbox(14)
	h.add_child(avatar_presence(72, name, online, av))
	var tc := vbox(2)
	tc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tc.add_child(label(name, "title_large", c("on_surface")))
	if username != "":
		tc.add_child(label("@" + username, "body_medium", c("primary")))
	else:
		tc.add_child(label("Add a username", "body_medium", c("on_surface_variant")))
	h.add_child(tc)
	col.add_child(h)
	if bio != "":
		col.add_child(vspace(12))
		col.add_child(label(bio, "body_medium", c("on_surface")))
	if not actions.is_empty():
		col.add_child(vspace(12))
		var ah := hbox(8)
		for a in actions:
			a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			if a is Button:
				a.autowrap_mode = TextServer.AUTOWRAP_OFF
				a.clip_text = true
			ah.add_child(a)
		col.add_child(ah)
	if note != "":
		col.add_child(vspace(8))
		col.add_child(label(note, "body_small", c("on_surface_variant")))
	p.add_child(col)
	return margin(p, 16, 10, 16, 10)


## Stat tile for a row of counts (Friends / Followers / Following).
static func stat_tile(value: int, title: String, cb: Callable) -> Control:
	var row := TapRow.new()
	row.on_tap = cb
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_stylebox_override("panel", box(c("surface_container"), 20, Color(c("outline_variant"), 0.6), 1))
	var col := vbox(2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := label(str(value), "title_large", c("on_surface"), false)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(v)
	var t := label(title, "body_medium", c("on_surface_variant"), false)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(t)
	row.add_child(margin(col, 8, 14, 8, 14))
	row.get_child(0).mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_press_shrink_row(row)
	return row


## Quick grid cell: 48dp primary-12% box with a 24dp primary icon, labelMedium below.
static func quick_cell(icon_name: String, text: String, cb: Callable, badge_count := 0) -> Control:
	var row := TapRow.new()
	row.on_tap = cb
	row.gradient_radius = 0
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var col := vbox(6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bx := PanelContainer.new()
	bx.custom_minimum_size = Vector2(48, 48)
	bx.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	bx.add_theme_stylebox_override("panel", box(Color(c("primary"), 0.12), 16))
	bx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ic := icon(icon_name, 24, c("primary"))
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bx.add_child(ic)
	if badge_count > 0:
		var holder := Control.new()
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.size_flags_horizontal = Control.SIZE_SHRINK_END
		holder.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		bx.add_child(holder)
		var bd := badge(badge_count)
		bd.position = Vector2(-12, -4)
		holder.add_child(bd)
	col.add_child(bx)
	var l := label(text, "label_medium", c("on_surface"))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(l)
	row.add_child(margin(col, 8, 8, 8, 8))
	row.get_child(0).mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_press_shrink_row(row)
	return row


# ------------------------------------------------------------------ helpers

## Tappable container that still lets the scroll view drag (taps < 10dp of movement).
class TapRow extends PanelContainer:
	signal pressed_changed(down: bool)
	var on_tap := Callable()
	var gradient_radius := 0.0
	var _down_at := Vector2.ZERO
	var _down := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if _on_inner_button(self, event.global_position):
					return   # a button inside the row takes this tap
				_down = true
				_down_at = event.global_position
				pressed_changed.emit(true)
				queue_redraw()
			elif _down:
				_down = false
				pressed_changed.emit(false)
				queue_redraw()
				if event.global_position.distance_to(_down_at) < 10.0 and on_tap.is_valid():
					on_tap.call()
		elif event is InputEventMouseMotion and _down and event.global_position.distance_to(_down_at) > 10.0:
			_down = false
			pressed_changed.emit(false)
			queue_redraw()

	static func _on_inner_button(n: Node, at: Vector2) -> bool:
		for ch in n.get_children():
			if ch is BaseButton and ch.is_visible_in_tree() and ch.get_global_rect().has_point(at):
				return true
			if ch is Control and _on_inner_button(ch, at):
				return true
		return false

	func _draw() -> void:
		if gradient_radius > 0.0:
			GradientShape.draw_gradient_rect(self, Rect2(Vector2.ZERO, size), gradient_radius)
		if _down:
			draw_style_box(UiKit.box(Color(UiKit.c("on_surface"), 0.08), maxf(gradient_radius, 0.0)), Rect2(Vector2.ZERO, size))


## Draws a rounded shape filled with the brand gradient (Sky -> SkyMedium, top-left to bottom-right).
class GradientShape extends Control:
	var radius := 4.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_gradient_rect(self, Rect2(Vector2.ZERO, size), radius)

	static func draw_gradient_rect(ci: CanvasItem, rect: Rect2, r: float, from: Color = UiKit.SKY, to: Color = UiKit.SKY_MEDIUM) -> void:
		r = minf(r, minf(rect.size.x, rect.size.y) / 2.0)
		var pts := PackedVector2Array()
		var corners := [
			[rect.position + Vector2(rect.size.x - r, r), -PI / 2.0],
			[rect.position + Vector2(rect.size.x - r, rect.size.y - r), 0.0],
			[rect.position + Vector2(r, rect.size.y - r), PI / 2.0],
			[rect.position + Vector2(r, r), PI]]
		for cdef in corners:
			for k in range(9):
				var a: float = cdef[1] + (PI / 2.0) * k / 8.0
				pts.append(cdef[0] + Vector2(cos(a), sin(a)) * r)
		var cols := PackedColorArray()
		var diag := rect.size
		var len2 := maxf(diag.length_squared(), 1.0)
		for p in pts:
			var t := clampf((p - rect.position).dot(diag) / len2, 0.0, 1.0)
			cols.append(from.lerp(to, t))
		ci.draw_polygon(pts, cols)
		pts.append(pts[0])
		cols.append(cols[0])
		ci.draw_polyline_colors(pts, cols, 1.0, true)


## Centres its child and caps its width (ContentWidth.page = 760dp).
class WidthLimiter extends Container:
	var max_width := 760.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _notification(what: int) -> void:
		if what == NOTIFICATION_SORT_CHILDREN:
			for ch in get_children():
				if ch is Control:
					var w := minf(size.x, max_width)
					fit_child_in_rect(ch, Rect2((size.x - w) / 2.0, 0, w, size.y))

	func _get_minimum_size() -> Vector2:
		var m := Vector2.ZERO
		for ch in get_children():
			if ch is Control:
				m.y = maxf(m.y, ch.get_combined_minimum_size().y)
		return m
