class_name PopRules
extends RefCounted
## Pop-Up Panic: rules and numbers shared by the phone and the referee.
## A floating round table high in the sky. Everyone is a weird head on a spring,
## popping out of a weird object. Bonk the others off the edge; hop over the giant
## spinning spoon. Most knockouts in two minutes wins.

const ARENA_R := 12.0          # table top radius (top surface at y = 0)
const HUB_R := 1.6             # the spoon's centre post: solid
const FALL_Y := -5.0           # below this you are out: knockout
const SPAWN_Y := 7.0           # you drop back in from the sky
const SPAWN_RING := 6.5

const MOVE_SPEED := 6.4
const ACCEL := 40.0
const HOP_VELOCITY := 9.0
const GRAVITY := 24.0
const COYOTE_S := 0.12
const JUMP_BUFFER_S := 0.15
const BODY_R := 0.55           # collision radius of a character

const BONK_RANGE := 2.7        # how far the spring-head reaches
const BONK_CONE := 0.34        # cos(70 deg) half-angle in front of you
const BONK_COOLDOWN_S := 0.6
const BONK_PUSH := 12.5        # sideways speed of a fresh hit
const BONK_UP := 6.5
const WOBBLE_STEP := 0.3       # every hit you take since landing makes the next one stronger
const WOBBLE_MAX := 2.6
const SHIELD_S := 2.0          # after dropping back in, nobody can bonk you
const CREDIT_S := 6.0          # a fall within this long after a bonk counts for the bonker
const KNOCK_DECAY := 2.6       # how fast a knock's sideways speed fades

const SPOON_Y := 0.55          # height of the spoon arm's centre line
const SPOON_R := 0.42          # thickness (radius) of the arm
const SPOON_SPEED := 0.8       # radians per second
const SPOON_PUSH := 13.0
const SPOON_UP := 9.5

const PAD_RING := 8.3
const PAD_R := 1.15
const PAD_VELOCITY := 17.0
const PAD_ANGLES := [0.785398, 2.356194, 3.926991, 5.497787]

const ROUND_S := 120.0
const FRENZY_S := 30.0         # last 30 s: a second spoon arm rises
const RESULTS_S := 9.0
const MAX_BOTS := 5

## The characters: a weird head popping out of a weird object.
const CHARACTERS := [
	{"name": "Teapot Tom", "obj": "teapot"},
	{"name": "Sneaker Sam", "obj": "sneaker"},
	{"name": "Boxy Bea", "obj": "box"},
	{"name": "Fridge Fritz", "obj": "fridge"},
	{"name": "Cactus Kiki", "obj": "cactus"},
	{"name": "Mailbox Max", "obj": "mailbox"},
	{"name": "Washer Wanda", "obj": "washer"},
	{"name": "Jam Jar Jo", "obj": "jar"},
]
const BOT_NAMES := ["Wobbles", "Sir Bonks", "Toasty", "Noodle", "Pickles", "Biscuit", "Doodle", "Gizmo"]


static func pad_center(i: int) -> Vector3:
	var a: float = PAD_ANGLES[i]
	return Vector3(cos(a) * PAD_RING, 0.0, sin(a) * PAD_RING)


## The spoon's angle at time t (seconds on the referee's clock). Same on every phone.
static func spoon_angle(t: float) -> float:
	return fposmod(t * SPOON_SPEED, TAU)


## How far the frenzy arm has risen (0 hidden .. 1 up), from the time left in the round.
static func frenzy_amount(left_s: float, playing: bool) -> float:
	if not playing:
		return 0.0
	return clampf((FRENZY_S - left_s) / 1.2, 0.0, 1.0)


## Is a character at `p` hit by an arm at `angle`? Returns the push velocity or ZERO.
static func arm_push(p: Vector3, angle: float) -> Vector3:
	if p.y > SPOON_Y + SPOON_R + 0.15 or p.y < -0.6:
		return Vector3.ZERO
	var dir := Vector2(cos(angle), sin(angle))
	var q := Vector2(p.x, p.z)
	var along := q.dot(dir)
	if along < HUB_R - 0.2 or along > ARENA_R + 0.6:
		return Vector3.ZERO
	var side := q.dot(Vector2(-dir.y, dir.x))
	if absf(side) > SPOON_R + BODY_R:
		return Vector3.ZERO
	# The arm turns counter-clockwise (+angle): it pushes things on its leading side.
	var s := 1.0 if side >= 0.0 else -1.0
	var tangent := Vector2(-dir.y, dir.x) * s
	var push := (tangent * 0.8 + dir * 0.35).normalized() * SPOON_PUSH
	return Vector3(push.x, SPOON_UP, push.y)


static func arms_push(p: Vector3, t: float, frenzy: float) -> Vector3:
	var a := spoon_angle(t)
	var v := arm_push(p, a)
	if v == Vector3.ZERO and frenzy >= 0.99:
		v = arm_push(p, a + PI)
	return v


static func on_table(p: Vector3) -> bool:
	return Vector2(p.x, p.z).length() <= ARENA_R


static func random_spawn(rng: RandomNumberGenerator) -> Vector3:
	var a := rng.randf() * TAU
	var r := rng.randf_range(SPAWN_RING - 2.0, SPAWN_RING)
	return Vector3(cos(a) * r, SPAWN_Y, sin(a) * r)


static func wobble_mult(hits: int) -> float:
	return minf(1.0 + WOBBLE_STEP * hits, WOBBLE_MAX)


static func character_name(ch: int) -> String:
	return str(CHARACTERS[posmod(ch, CHARACTERS.size())].name)
