class_name AvatarArt
extends Control
## The 30 built-in profile avatars: little round "buddies" drawn as vectors, so they
## stay sharp at any size. Each one is a background colour from the Sky & Ink palette,
## a face shape, eyes, a mouth and one accessory. Index -1 means no avatar picked yet
## (the caller shows initials instead).

const COUNT := 30

# Background / body pairs, all from the design palette (sky, pink, success, amber, ink)
# and their light tints.
const BG := [
	Color("#37B1FF"), Color("#FF4BB7"), Color("#00BB77"), Color("#F29A2E"), Color("#202936"),
	Color("#009CFF"), Color("#AFE0FF"), Color("#FFC2E6"), Color("#9BE8CB"), Color("#FFD9A8"),
]
const BODY := [
	Color("#E3F4FF"), Color("#FFF0F8"), Color("#E6FFF5"), Color("#FFF4E6"), Color("#37B1FF"),
	Color("#FFFFFF"), Color("#009CFF"), Color("#FF4BB7"), Color("#00BB77"), Color("#F29A2E"),
]
const INK := Color("#202936")
const NAMES := [
	"Sky", "Bubblegum", "Mint", "Sunny", "Midnight", "Splash", "Cloud", "Blossom", "Leaf", "Peach",
	"Captain", "Star", "Beats", "Royal", "Wizard", "Ninja", "Robo", "Kitty", "Bunny", "Alien",
	"Chef", "Party", "Cool", "Sleepy", "Wink", "Ghost", "Halo", "Flower", "Devil", "Pilot",
]

var index := 0


static func make(i: int, size: float) -> AvatarArt:
	var a := AvatarArt.new()
	a.index = posmod(i, COUNT)
	a.custom_minimum_size = Vector2(size, size)
	a.size = Vector2(size, size)
	a.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return a


func _ready() -> void:
	resized.connect(queue_redraw)


# Per avatar: colour slot, eyes, mouth, accessory. Hand-picked so no two look alike.
const LOOK := [
	[0, 0, 0, 0], [1, 1, 1, 0], [2, 2, 0, 0], [3, 0, 2, 0], [4, 3, 0, 0],
	[5, 1, 3, 0], [6, 0, 1, 0], [7, 2, 2, 0], [8, 4, 0, 0], [9, 1, 0, 0],
	[0, 0, 0, 1], [1, 4, 1, 2], [2, 0, 2, 3], [3, 1, 0, 4], [4, 0, 3, 5],
	[5, 5, 4, 6], [6, 3, 4, 7], [7, 0, 1, 8], [8, 1, 0, 9], [9, 2, 2, 10],
	[0, 1, 0, 11], [1, 0, 2, 12], [2, 6, 0, 13], [3, 7, 3, 0], [4, 8, 1, 0],
	[5, 0, 5, 14], [6, 1, 0, 15], [7, 0, 2, 16], [8, 2, 1, 17], [9, 6, 0, 18],
]


func _draw() -> void:
	var s := minf(size.x, size.y)
	if s <= 0.0:
		return
	var look: Array = LOOK[index]
	var slot: int = look[0]
	var c := Vector2(s, s) * 0.5
	var r := s * 0.5
	# Background disc.
	draw_circle(c, r, BG[slot], true, -1.0, true)
	var body: Color = BODY[slot]
	var ghost: bool = look[3] == 14
	if ghost:
		body = Color("#FFFFFF")
	# Face blob, slightly low so accessories fit above.
	var fc := c + Vector2(0, s * 0.06)
	var fr := s * 0.33
	_back_accessory(look[3], fc, fr, s)
	draw_circle(fc, fr, body, true, -1.0, true)
	# Cheeks.
	var cheek := Color("#FF4BB7", 0.28)
	draw_circle(fc + Vector2(-fr * 0.58, fr * 0.22), fr * 0.14, cheek, true, -1.0, true)
	draw_circle(fc + Vector2(fr * 0.58, fr * 0.22), fr * 0.14, cheek, true, -1.0, true)
	var ink := INK if body.get_luminance() > 0.45 else Color.WHITE
	_eyes(look[1], fc, fr, ink)
	_mouth(look[2], fc, fr, ink)
	_front_accessory(look[3], fc, fr, s, ink)


func _eyes(kind: int, fc: Vector2, fr: float, ink: Color) -> void:
	var l := fc + Vector2(-fr * 0.36, -fr * 0.12)
	var rr := fc + Vector2(fr * 0.36, -fr * 0.12)
	var e := fr * 0.12
	var w := maxf(1.2, fr * 0.09)
	match kind:
		0: # round with a shine
			for p in [l, rr]:
				draw_circle(p, e, ink, true, -1.0, true)
				draw_circle(p + Vector2(-e * 0.35, -e * 0.35), e * 0.35, Color.WHITE, true, -1.0, true)
		1: # happy arcs
			for p in [l, rr]:
				draw_arc(p + Vector2(0, e * 0.5), e * 1.1, PI * 1.15, PI * 1.85, 12, ink, w, true)
		2: # big sparkly
			for p in [l, rr]:
				draw_circle(p, e * 1.4, ink, true, -1.0, true)
				draw_circle(p + Vector2(-e * 0.45, -e * 0.45), e * 0.5, Color.WHITE, true, -1.0, true)
				draw_circle(p + Vector2(e * 0.45, e * 0.4), e * 0.22, Color.WHITE, true, -1.0, true)
		3: # sleepy lines
			for p in [l, rr]:
				draw_line(p + Vector2(-e, 0), p + Vector2(e, 0), ink, w, true)
		4: # star eyes
			for p in [l, rr]:
				_star(p, e * 1.5, Color("#F29A2E") if ink == INK else Color("#FFD9A8"))
		5: # ninja slit
			for p in [l, rr]:
				draw_circle(p, e * 0.8, ink, true, -1.0, true)
		6: # cool shades
			var sh := Color("#202936")
			for p in [l, rr]:
				draw_rect(Rect2(p - Vector2(e * 1.8, e * 1.0), Vector2(e * 3.6, e * 2.0)), sh, true)
			draw_line(l, rr, sh, w, true)
			draw_line(l + Vector2(-e * 1.2, -e * 0.6), l + Vector2(-e * 0.2, -e * 0.6), Color(1, 1, 1, 0.6), w * 0.7, true)
		7: # one closed (wink)
			draw_circle(l, e, ink, true, -1.0, true)
			draw_arc(rr + Vector2(0, e * 0.5), e * 1.1, PI * 1.15, PI * 1.85, 12, ink, w, true)
		8: # wink the other way
			draw_arc(l + Vector2(0, e * 0.5), e * 1.1, PI * 1.15, PI * 1.85, 12, ink, w, true)
			draw_circle(rr, e, ink, true, -1.0, true)


func _mouth(kind: int, fc: Vector2, fr: float, ink: Color) -> void:
	var m := fc + Vector2(0, fr * 0.3)
	var w := maxf(1.2, fr * 0.09)
	match kind:
		0: # smile
			draw_arc(m + Vector2(0, -fr * 0.12), fr * 0.24, PI * 0.15, PI * 0.85, 14, ink, w, true)
		1: # open grin
			var pts := PackedVector2Array()
			for i in 13:
				var a := PI * float(i) / 12.0
				pts.append(m + Vector2(cos(a) * fr * 0.24, sin(a) * fr * 0.2 - fr * 0.04))
			draw_colored_polygon(pts, ink)
			draw_circle(m + Vector2(0, fr * 0.1), fr * 0.08, Color("#FF4BB7"), true, -1.0, true)
		2: # little o
			draw_circle(m, fr * 0.08, ink, true, -1.0, true)
		3: # flat line
			draw_line(m + Vector2(-fr * 0.14, 0), m + Vector2(fr * 0.14, 0), ink, w, true)
		4: # cat mouth
			draw_arc(m + Vector2(-fr * 0.09, -fr * 0.05), fr * 0.09, 0.0, PI, 10, ink, w, true)
			draw_arc(m + Vector2(fr * 0.09, -fr * 0.05), fr * 0.09, 0.0, PI, 10, ink, w, true)
		5: # wavy ghost mouth
			draw_circle(m, fr * 0.11, ink, true, -1.0, true)


## Accessories drawn behind the face (ears, horns, ...).
func _back_accessory(kind: int, fc: Vector2, fr: float, s: float) -> void:
	var body: Color = BODY[LOOK[index][0]]
	match kind:
		8: # cat ears
			for sx in [-1.0, 1.0]:
				draw_colored_polygon(PackedVector2Array([
					fc + Vector2(sx * fr * 0.85, -fr * 0.35), fc + Vector2(sx * fr * 0.75, -fr * 1.15),
					fc + Vector2(sx * fr * 0.2, -fr * 0.85)]), body)
		9: # bunny ears
			for sx in [-1.0, 1.0]:
				var ec := fc + Vector2(sx * fr * 0.42, -fr * 1.05)
				_ellipse(ec, Vector2(fr * 0.2, fr * 0.5), body)
				_ellipse(ec, Vector2(fr * 0.1, fr * 0.36), Color("#FFC2E6"))
		18: # devil horns
			for sx in [-1.0, 1.0]:
				draw_colored_polygon(PackedVector2Array([
					fc + Vector2(sx * fr * 0.7, -fr * 0.55), fc + Vector2(sx * fr * 0.95, -fr * 1.2),
					fc + Vector2(sx * fr * 0.3, -fr * 0.85)]), Color("#DA2F2F"))
		14: # ghost tail: the face becomes a sheet
			draw_rect(Rect2(fc + Vector2(-fr, 0), Vector2(fr * 2.0, fr * 1.0)), Color.WHITE, true)
			for i in 4:
				draw_circle(fc + Vector2(-fr + fr * 0.25 + fr * 0.5 * i, fr * 1.0), fr * 0.25, Color.WHITE, true, -1.0, true)


## Accessories drawn over the face (hats, headphones, ...).
func _front_accessory(kind: int, fc: Vector2, fr: float, s: float, ink: Color) -> void:
	match kind:
		1: # sky cap
			_cap(fc, fr, Color("#009CFF"), Color("#202936"))
		2: # star on the head
			_star(fc + Vector2(fr * 0.55, -fr * 0.95), fr * 0.38, Color("#F29A2E"))
		3: # headphones
			draw_arc(fc, fr * 1.08, PI * 1.05, PI * 1.95, 24, Color("#202936"), fr * 0.14, true)
			for sx in [-1.0, 1.0]:
				_ellipse(fc + Vector2(sx * fr * 1.0, 0), Vector2(fr * 0.2, fr * 0.32), Color("#FF4BB7"))
		4: # crown
			var y := fc.y - fr * 0.8
			var w := fr * 0.75
			draw_colored_polygon(PackedVector2Array([
				Vector2(fc.x - w, y + fr * 0.2), Vector2(fc.x - w, y - fr * 0.3), Vector2(fc.x - w * 0.5, y - fr * 0.05),
				Vector2(fc.x, y - fr * 0.45), Vector2(fc.x + w * 0.5, y - fr * 0.05), Vector2(fc.x + w, y - fr * 0.3),
				Vector2(fc.x + w, y + fr * 0.2)]), Color("#F29A2E"))
			draw_circle(Vector2(fc.x, y - fr * 0.02), fr * 0.08, Color("#FF4BB7"), true, -1.0, true)
		5: # wizard hat
			var base := fc.y - fr * 0.6
			draw_colored_polygon(PackedVector2Array([
				Vector2(fc.x - fr * 0.7, base), Vector2(fc.x + fr * 0.15, base - fr * 1.05), Vector2(fc.x + fr * 0.7, base)]), Color("#009CFF"))
			draw_line(Vector2(fc.x - fr * 0.95, base), Vector2(fc.x + fr * 0.95, base), Color("#009CFF"), fr * 0.16, true)
			_star(Vector2(fc.x, base - fr * 0.4), fr * 0.16, Color("#FFD9A8"))
		6: # ninja band
			draw_rect(Rect2(fc + Vector2(-fr, -fr * 0.36), Vector2(fr * 2.0, fr * 0.22)), Color("#DA2F2F"), true)
			draw_line(fc + Vector2(fr * 0.9, -fr * 0.25), fc + Vector2(fr * 1.25, -fr * 0.05), Color("#DA2F2F"), fr * 0.1, true)
		7: # robot antenna and bolts
			draw_line(fc + Vector2(0, -fr), fc + Vector2(0, -fr * 1.35), Color("#202936"), fr * 0.08, true)
			draw_circle(fc + Vector2(0, -fr * 1.38), fr * 0.12, Color("#FF4BB7"), true, -1.0, true)
			for sx in [-1.0, 1.0]:
				draw_rect(Rect2(fc + Vector2(sx * fr * 1.0 - fr * 0.1, -fr * 0.12), Vector2(fr * 0.2, fr * 0.24)), Color("#202936"), true)
		10: # alien antennae
			for sx in [-1.0, 1.0]:
				draw_line(fc + Vector2(sx * fr * 0.3, -fr * 0.9), fc + Vector2(sx * fr * 0.6, -fr * 1.35), Color("#00BB77"), fr * 0.08, true)
				draw_circle(fc + Vector2(sx * fr * 0.6, -fr * 1.38), fr * 0.12, Color("#00BB77"), true, -1.0, true)
		11: # chef hat
			var y2 := fc.y - fr * 0.85
			draw_rect(Rect2(Vector2(fc.x - fr * 0.55, y2), Vector2(fr * 1.1, fr * 0.3)), Color.WHITE, true)
			for dx in [-0.4, 0.0, 0.4]:
				draw_circle(Vector2(fc.x + fr * dx, y2 - fr * 0.12), fr * 0.32, Color.WHITE, true, -1.0, true)
		12: # party hat
			var b2 := fc.y - fr * 0.75
			draw_colored_polygon(PackedVector2Array([
				Vector2(fc.x - fr * 0.4, b2), Vector2(fc.x, b2 - fr * 0.8), Vector2(fc.x + fr * 0.4, b2)]), Color("#F29A2E"))
			draw_circle(Vector2(fc.x, b2 - fr * 0.82), fr * 0.12, Color("#37B1FF"), true, -1.0, true)
			draw_line(Vector2(fc.x - fr * 0.2, b2 - fr * 0.25), Vector2(fc.x + fr * 0.2, b2 - fr * 0.25), Color.WHITE, fr * 0.07, true)
		13: # backwards cap for the cool one
			_cap(fc, fr, Color("#FF4BB7"), Color("#FF4BB7"), true)
		15: # halo
			draw_arc(fc + Vector2(0, -fr * 1.05), fr * 0.5, 0.0, TAU, 32, Color("#FFD9A8"), fr * 0.12, true)
		16: # flower
			var fp := fc + Vector2(fr * 0.6, -fr * 0.75)
			for i in 5:
				var a := TAU * float(i) / 5.0
				draw_circle(fp + Vector2(cos(a), sin(a)) * fr * 0.18, fr * 0.14, Color("#FFC2E6"), true, -1.0, true)
			draw_circle(fp, fr * 0.12, Color("#F29A2E"), true, -1.0, true)
		17: # pilot goggles
			draw_rect(Rect2(fc + Vector2(-fr, -fr * 0.72), Vector2(fr * 2.0, fr * 0.14)), Color("#202936"), true)
			for sx in [-1.0, 1.0]:
				draw_circle(fc + Vector2(sx * fr * 0.36, -fr * 0.66), fr * 0.22, Color("#202936"), true, -1.0, true)
				draw_circle(fc + Vector2(sx * fr * 0.36, -fr * 0.66), fr * 0.15, Color("#AFE0FF"), true, -1.0, true)


func _cap(fc: Vector2, fr: float, col: Color, brim: Color, backwards := false) -> void:
	var pts := PackedVector2Array()
	for i in 17:
		var a := PI + PI * float(i) / 16.0
		pts.append(fc + Vector2(cos(a) * fr * 0.98, sin(a) * fr * 0.98 - fr * 0.18))
	draw_colored_polygon(pts, col)
	var dir := -1.0 if backwards else 1.0
	draw_rect(Rect2(fc + Vector2(-fr * 0.2 if dir > 0 else -fr * 1.1, -fr * 0.26), Vector2(fr * 1.3, fr * 0.14)), brim, true)


func _star(p: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI / 2.0 + TAU * float(i) / 10.0
		var rr := r if i % 2 == 0 else r * 0.45
		pts.append(p + Vector2(cos(a), sin(a)) * rr)
	draw_colored_polygon(pts, col)


func _ellipse(p: Vector2, rad: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 24:
		var a := TAU * float(i) / 24.0
		pts.append(p + Vector2(cos(a) * rad.x, sin(a) * rad.y))
	draw_colored_polygon(pts, col)
