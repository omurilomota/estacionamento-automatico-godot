class_name EngineAudio
extends Node2D
## Procedural car audio — engine loop, reverse beep, park chime, body thud.
##
## WHY PROCEDURAL (and not .wav files in the repo): the project had ZERO audio
## and no audio assets, and downloading sound packs would drag licences into a
## repo that is presented publicly. Everything here is SYNTHESISED from a few
## sine/noise lines at load time, so it costs no bytes in the export, carries no
## licence and can be tuned by number instead of by ear.
##
## It is deliberately resilient: headless runs have no audio device, so the node
## disables itself (`OS.has_feature("headless")`) and every call becomes a no-op.
## That keeps `tools/gate_*.gd` (which boot the real scenes) silent AND safe.
##
## Wiring: `scenes/Carro.tscn` instantiates it as a child named `EngineAudio`;
## `Carro` pushes the speed every physics frame and fires the one-shots.

const SAMPLE_RATE := 22050
## Voice cap: below this the engine is silent, above it is loud. In px/s.
const SPEED_MIN := 4.0
const SPEED_MAX := 260.0

@export var enabled := true
@export var master_db := -6.0

var _engine: AudioStreamPlayer2D
var _beep: AudioStreamPlayer2D
var _chime: AudioStreamPlayer2D
var _thud: AudioStreamPlayer2D
var _beep_accum := 0.0
var _reverse_latched := false


func _ready() -> void:
	if OS.has_feature("headless") or DisplayServer.get_name() == "headless":
		enabled = false
	if not enabled:
		return
	_engine = _player("EngineLoop")
	_beep = _player("ReverseBeep")
	_chime = _player("ParkChime")
	_thud = _player("BodyThud")
	if _engine == null:
		return
	_engine.stream = _loop_wav(_engine_samples())
	_engine.volume_db = -80.0
	_beep.stream = _one_shot(_beep_samples())
	_chime.stream = _one_shot(_chime_samples())
	_thud.stream = _one_shot(_thud_samples())
	_engine.play()


func _player(node_name: String) -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.name = node_name
	p.max_polyphony = 3
	p.bus = &"Master"
	# The engine follows the car; everything else is positional too.
	p.panning_strength = 0.4
	add_child(p)
	return p


## Called every physics frame with the vehicle's signed speed in px/s.
## `parked` drops the engine to silence (the lot goes quiet when it is done).
func set_engine(speed: float, reversing: bool, parked: bool, delta: float) -> void:
	if not enabled or _engine == null:
		return
	var t: float = clampf((absf(speed) - SPEED_MIN) / (SPEED_MAX - SPEED_MIN), 0.0, 1.0)
	# Idle must still be audible (a car waiting has an engine), so the floor is
	# -30 dB, not silence.
	var target_db: float = -80.0 if parked else lerpf(-30.0, master_db, sqrt(t))
	if absf(_engine.volume_db - target_db) > 100.0:
		_engine.volume_db = target_db
	else:
		_engine.volume_db = lerpf(_engine.volume_db, target_db, clampf(delta * 4.0, 0.0, 1.0))
	_engine.pitch_scale = lerpf(0.45, 1.9, t)
	if parked:
		_engine.stop()
	elif not _engine.playing:
		_engine.play()
	# Reverse beep: one beep every 0.75 s while the car is actually reversing.
	if reversing and not parked:
		_beep_accum += delta
		if not _reverse_latched or _beep_accum >= 0.75:
			_beep_accum = 0.0
			_reverse_latched = true
			if _beep != null:
				_beep.play()
	else:
		_reverse_latched = false
		_beep_accum = 0.0


## A short three-note arpeggio the moment the car reaches PARKED.
func play_park() -> void:
	if enabled and _chime != null:
		_chime.play()


## Body impact. `strength` 0..1 scales the volume (0 = ignore, no sound).
func play_bump(strength: float) -> void:
	if not enabled or _thud == null or strength < 0.25:
		return
	_thud.volume_db = lerpf(-24.0, -4.0, clampf(strength, 0.0, 1.0))
	_thud.play()


# --- synthesis ------------------------------------------------------------

## A 0.40 s harmonic stack: the strongest partials of a small petrol engine plus
## a 30 Hz amplitude "putt". Every frequency is a multiple of 1/0.40 s = 2.5 Hz,
## so the loop is sample-exact seamless (no click at the seam).
func _engine_samples() -> PackedFloat32Array:
	var n := int(SAMPLE_RATE * 0.40)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var t := float(i) / SAMPLE_RATE
		var s := 0.50 * sin(TAU * 60.0 * t) \
			+ 0.24 * sin(TAU * 120.0 * t) \
			+ 0.12 * sin(TAU * 180.0 * t) \
			+ 0.06 * sin(TAU * 240.0 * t)
		# "putt": amplitude modulation, also loop-exact (30 Hz = 12 periods)
		s *= 0.72 + 0.28 * sin(TAU * 30.0 * t)
		out[i] = clampf(s * 0.8, -1.0, 1.0)
	return out


## 0.18 s square-ish beep with 8 ms fades (a square with hard edges clicks).
func _beep_samples() -> PackedFloat32Array:
	var n := int(SAMPLE_RATE * 0.18)
	var fade := int(SAMPLE_RATE * 0.008)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var s := signf(sin(TAU * 1000.0 * float(i) / SAMPLE_RATE)) * 0.55
		var env := 1.0
		if i < fade:
			env = float(i) / fade
		elif i > n - fade:
			env = float(n - i) / fade
		out[i] = s * env
	return out


## 784 / 1047 / 1568 Hz (G5-C6-G6), each a 0.14 s decaying note.
func _chime_samples() -> PackedFloat32Array:
	var notes := [784.0, 1047.0, 1568.0]
	var per := int(SAMPLE_RATE * 0.14)
	var out := PackedFloat32Array()
	out.resize(per * notes.size())
	for k in range(notes.size()):
		for i in range(per):
			var t := float(i) / SAMPLE_RATE
			var env: float = exp(-9.0 * t)
			var s: float = sin(TAU * notes[k] * t) * 0.42 + 0.12 * sin(TAU * notes[k] * 2.0 * t)
			out[k * per + i] = clampf(s * env, -1.0, 1.0)
	return out


## 0.22 s: a low thump plus band-limited noise, both decaying fast.
func _thud_samples() -> PackedFloat32Array:
	var n := int(SAMPLE_RATE * 0.22)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260927
	var last := 0.0
	for i in range(n):
		var t := float(i) / SAMPLE_RATE
		var env: float = exp(-16.0 * t)
		var noise: float = rng.randf_range(-1.0, 1.0)
		# one-pole low pass -> a dull "clunk" instead of white hiss
		last = lerpf(last, noise, 0.25)
		var s: float = 0.7 * sin(TAU * 90.0 * t) * exp(-22.0 * t) + 0.35 * last * env
		out[i] = clampf(s, -1.0, 1.0)
	return out


func _loop_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var w := _wav(samples)
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = samples.size()
	return w


func _one_shot(samples: PackedFloat32Array) -> AudioStreamWAV:
	return _wav(samples)


func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in range(samples.size()):
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SAMPLE_RATE
	w.stereo = false
	w.data = data
	return w
