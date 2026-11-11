class_name BeatClock
extends RefCounted
## One shared musical clock for the whole room, driven by the referee's time.
## 120 BPM, 16-bar song loop (32 s). Bars 12-15 build up; the beat drops on
## bar 0. On every drop, gravity flips AND the origami blocks fold (or unfold),
## at the same instant, for every player. Pure functions of time, so the
## referee and every phone agree without extra messages.

const BPM := 120.0
const BEAT := 60.0 / BPM          # 0.5 s
const BAR := BEAT * 4.0           # 2 s
const SONG_BARS := 16
const DROP_PERIOD := BAR * SONG_BARS   # 32 s
const BUILD_START_BAR := 12
const FOLD_TIME := 1.2            # seconds the fold takes after a drop


static func drop_index(t: float) -> int:
	return int(floor(t / DROP_PERIOD))


static func since_drop(t: float) -> float:
	return fposmod(t, DROP_PERIOD)


static func until_drop(t: float) -> float:
	return DROP_PERIOD - since_drop(t)


static func bar_in_song(t: float) -> int:
	return int(floor(since_drop(t) / BAR)) % SONG_BARS


static func beat_phase(t: float) -> float:
	return fposmod(t, BEAT) / BEAT


## Gravity: normal on even drops, upside down on odd drops.
static func gravity_sign(t: float) -> float:
	return 1.0 if drop_index(t) % 2 == 0 else -1.0


## 0 = flat, 1 = folded. Changes only right after a drop, eased like paper snapping.
static func fold_amount(t: float) -> float:
	var folded := drop_index(t) % 2 != 0
	var p := clampf(since_drop(t) / FOLD_TIME, 0.0, 1.0)
	p = 1.0 - pow(1.0 - p, 3.0)   # ease-out cubic
	return p if folded else 1.0 - p
