extends Node
## Music and sound effects. Every file in audio/ is synthesized by
## tools/make_audio.py.
##
## The music adapts. During a mission two stems of the same thriller cue
## play in lockstep: "base" (strings, bass, ticking hats) always, and
## "drive" (drums and brass) faded in as danger rises. Same tempo and length,
## started on the same frame, so they never drift apart.
##
## Godot audio basics: an AudioStreamPlayer plays one stream at a time, and
## players route into named buses (Music, SFX) that mix into Master, so each
## group's volume is set in one place. In a browser, sound can only start
## after the player's first tap or key press; Godot resumes it then.

const SFX := {
	"shot": preload("res://audio/sfx/shot.wav"),
	"shatter": preload("res://audio/sfx/shatter.wav"),
	"lights_out": preload("res://audio/sfx/lights_out.wav"),
	"takedown": preload("res://audio/sfx/takedown.wav"),
	"nv_on": preload("res://audio/sfx/nv_on.wav"),
	"alarm": preload("res://audio/sfx/alarm.wav"),
	"key": preload("res://audio/sfx/key.wav"),
	"huh": preload("res://audio/sfx/huh.wav"),
	"step": preload("res://audio/sfx/step.wav"),
	"vent": preload("res://audio/sfx/vent.wav"),
	"rung": preload("res://audio/sfx/rung.wav"),
	"interact": preload("res://audio/sfx/interact.wav"),
	"objective": preload("res://audio/sfx/objective.wav"),
	"spotted": preload("res://audio/sfx/spotted.wav"),
	"locked": preload("res://audio/sfx/locked.wav"),
	"click": preload("res://audio/sfx/click.wav"),
	"complete": preload("res://audio/sfx/complete.wav"),
}
const MUSIC := {
	"base": preload("res://audio/music/thriller_base.wav"),
	"drive": preload("res://audio/music/thriller_drive.wav"),
	"menu": preload("res://audio/music/menu.wav"),
}
const SILENT_DB := -60.0
const POOL_SIZE := 12
const DRIVE_FLOOR := 0.22   # a little drive is always there: it's a thriller

var music_on := true
var danger := 0.0           # 0..1, eased toward the target each frame

var _current := ""          # "mission", "menu" or "" (silence)
var _base: AudioStreamPlayer
var _drive: AudioStreamPlayer
var _pool: Array[AudioStreamPlayer] = []


func _ready() -> void:
	_ensure_bus("Music", -8.0)
	_ensure_bus("SFX", -2.0)
	for stream in MUSIC.values():
		_make_loop(stream)
	_base = _player("Music")
	_drive = _player("Music")
	for i in POOL_SIZE:
		_pool.append(_player("SFX"))


## One-shot effect. `pitch_jitter` varies the pitch a little each time so
## repeated sounds (footsteps) don't sound mechanical.
func play(sound: String, volume_db := 0.0, pitch_jitter := 0.0) -> void:
	var p := _pool[0]
	for candidate in _pool:
		if not candidate.playing:
			p = candidate
			break
	p.stream = SFX[sound]
	p.volume_db = volume_db
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.play()


func play_music(track: String) -> void:
	if track == _current:
		return
	_current = track
	_start_current()


func toggle_music() -> bool:
	music_on = not music_on
	_start_current()
	return music_on


## Called every frame with how much danger the agent is in (0..1).
func set_danger(target: float, delta: float) -> void:
	danger = move_toward(danger, clampf(maxf(target, DRIVE_FLOOR), 0.0, 1.0), delta * 1.2)
	_drive.volume_db = linear_to_db(maxf(danger, 0.001))


func _start_current() -> void:
	_base.stop()
	_drive.stop()
	if not music_on or _current == "":
		return
	if _current == "mission":
		_base.stream = MUSIC.base
		_drive.stream = MUSIC.drive
		danger = DRIVE_FLOOR
		_drive.volume_db = linear_to_db(DRIVE_FLOOR)
		_base.play()
		_drive.play()
	else:
		_base.stream = MUSIC.menu
		_base.play()


func _player(bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus
	add_child(p)
	return p


static func _make_loop(stream: AudioStreamWAV) -> void:
	# The files are written to loop exactly, so loop the whole thing.
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = int(round(stream.get_length() * stream.mix_rate))


static func _ensure_bus(bus_name: String, volume_db: float) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, bus_name)
	AudioServer.set_bus_send(i, "Master")
	AudioServer.set_bus_volume_db(i, volume_db)
