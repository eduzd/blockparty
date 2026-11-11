class_name Music
extends AudioStreamPlayer
## Procedural soundtrack synthesised on the phone, locked to the shared
## BeatClock so everyone hears the drop at the same moment as the gravity flip.
## A spectrum analyser on the Master bus feeds the pulsing walls.

const MIX_RATE := 22050.0
const ROOTS := [55.0, 43.65, 65.41, 49.0]   # A, F, C, G (two bars each)
const BASS_STEPS := [0, 0, 12, 0, 7, 0, 12, 10]

var clock := Callable()        # shared world time in seconds
var analyzer: AudioEffectSpectrumAnalyzerInstance
var _playback: AudioStreamGeneratorPlayback
var _song_t := 0.0
var _noise := 22222


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = 0.25
	stream = gen
	volume_db = -4.0
	var bus := AudioServer.get_bus_index("Master")
	var idx := -1
	for i in range(AudioServer.get_bus_effect_count(bus)):
		if AudioServer.get_bus_effect(bus, i) is AudioEffectSpectrumAnalyzer:
			idx = i
	if idx == -1:
		var fx := AudioEffectSpectrumAnalyzer.new()
		fx.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(bus, fx)
		idx = AudioServer.get_bus_effect_count(bus) - 1
	analyzer = AudioServer.get_bus_effect_instance(bus, idx)


func start() -> void:
	_song_t = _world_t()
	play()
	_playback = get_stream_playback()
	_fill()


func _world_t() -> float:
	return clock.call() if clock.is_valid() else Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	if _playback == null or not playing:
		return
	# Stay locked to the shared clock (what's buffered plays slightly later).
	var ahead := float(_playback.get_frames_available()) / MIX_RATE
	var heard := _song_t - (0.25 - ahead)
	if absf(heard - _world_t()) > 0.3:
		_song_t = _world_t() + (0.25 - ahead)
	_fill()


func _fill() -> void:
	var n := _playback.get_frames_available()
	if n <= 0:
		return
	var buf := PackedVector2Array()
	buf.resize(n)
	var dt := 1.0 / MIX_RATE
	for i in range(n):
		var s := _sample(_song_t)
		buf[i] = Vector2(s, s)
		_song_t += dt
	_playback.push_buffer(buf)


func _rand() -> float:
	_noise = (_noise * 1103515245 + 12345) & 0x7fffffff
	return float(_noise) / 1073741823.5 - 1.0


func _sample(t: float) -> float:
	var song := BeatClock.since_drop(t)
	var bar := int(song / BeatClock.BAR)
	var tb := fposmod(song, BeatClock.BEAT)                 # time since beat
	var beat_in_bar := int(fposmod(song, BeatClock.BAR) / BeatClock.BEAT)
	var building := bar >= BeatClock.BUILD_START_BAR
	var out := 0.0
	# Kick: every beat, except during the build; huge on the drop bar
	if not building:
		var ph := TAU * (45.0 * tb + 105.0 * (1.0 - exp(-30.0 * tb)) / 30.0)
		out += sin(ph) * exp(-tb * 7.0) * (1.0 if bar > 0 else 1.25)
	# Hi-hat on the off-beats
	var toff := fposmod(song + BeatClock.BEAT * 0.5, BeatClock.BEAT)
	if bar < BeatClock.SONG_BARS - 1 or beat_in_bar < 3:
		out += _rand() * exp(-toff * 45.0) * 0.12
	# Bass line, ducked by the kick
	var t8 := fposmod(song, BeatClock.BEAT * 0.5)
	var step := int(fposmod(song, BeatClock.BAR) / (BeatClock.BEAT * 0.5)) % 8
	var root: float = ROOTS[(bar / 2) % 4]
	var f := root * pow(2.0, BASS_STEPS[step] / 12.0)
	var saw := 2.0 * fposmod(f * t, 1.0) - 1.0
	var duck := 1.0 if building else (0.35 + 0.65 * minf(tb * 6.0, 1.0))
	var bass_level := 0.12 if building else 0.22
	if bar == BeatClock.SONG_BARS - 1 and beat_in_bar == 3:
		bass_level = 0.0   # a breath of silence before the drop
	out += saw * exp(-t8 * 5.0) * bass_level * duck
	# Build-up: snare roll that speeds up, and a rising tone
	if building and not (bar == BeatClock.SONG_BARS - 1 and beat_in_bar == 3):
		var into := song - BeatClock.BUILD_START_BAR * BeatClock.BAR     # 0..8 s
		var div := 1.0 if into < 4.0 else (2.0 if into < 6.0 else 4.0)
		var ts := fposmod(song, BeatClock.BEAT / div)
		out += _rand() * exp(-ts * 30.0) * (0.10 + 0.03 * into)
		var rise := into / 8.0
		out += sin(TAU * (200.0 + 900.0 * rise * rise) * t) * 0.05 * rise
	# Crash on the drop
	if song < 1.5:
		out += _rand() * exp(-song * 2.5) * 0.18
	return out * 0.7 / (1.0 + absf(out * 0.7))


## Smoothed energy 0..1 for a frequency band (used by the walls).
func band_energy(lo: float, hi: float) -> float:
	if analyzer == null:
		return 0.0
	var m := analyzer.get_magnitude_for_frequency_range(lo, hi).length()
	return clampf((linear_to_db(maxf(m, 0.00001)) + 60.0) / 60.0, 0.0, 1.0)
