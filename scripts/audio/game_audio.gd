extends Node
# Audio base: background music, crowd noise and goal shouts.
#
# Drop your files (.ogg / .mp3 / .wav) into these folders - any number of files,
# the manager picks randomly and never repeats the same clip twice in a row:
#
#   res://audio/music/   background music (plays on menus, quieter during matches)
#   res://audio/crowd/   crowd ambience (loops during matches)
#   res://audio/goal/    "GOAL!" shouts (one plays on every goal; crowd swells)
#
# Empty / missing folders are fine: that sound is simply skipped.
# Press M in-game to mute / unmute everything.
#
# Lives in Engine metadata + the scene-tree root, so it survives scene changes
# and needs no autoload. From any script:
#   const GameAudio = preload("res://scripts/audio/game_audio.gd")
#   GameAudio.get_it(self).enter_menu()

const SaveData = preload("res://scripts/save/save_data.gd")

const SELF_PATH = "res://scripts/audio/game_audio.gd"
const META_KEY = "game_audio"

const MUSIC_DIR = "res://audio/music"
const CROWD_DIR = "res://audio/crowd"
const GOAL_DIR = "res://audio/goal"

# Volumes (dB). 0 = full volume of the file; negative = quieter.
const MUSIC_DB = -10.0          # menus
const MUSIC_MATCH_DB = -18.0    # during a match (ducked under the crowd)
const CROWD_DB = -8.0
const GOAL_DB = 0.0
const GOAL_SWELL_DB = 5.0       # crowd gets this much louder after a goal...
const GOAL_SWELL_TIME = 3.0     # ...and fades back over this many seconds

var music
var crowd
var sfx
var tween
var music_clips = []
var crowd_clips = []
var goal_clips = []
var last_music = null
var last_crowd = null
var last_goal = null
var last_goal_ms = -10000
var in_match = false
var music_scale = 1.0   # 0..1 user volume (saved in save.json)
var sfx_scale = 1.0     # crowd + goal shouts


static func get_it(from):
	if Engine.has_meta(META_KEY):
		var inst = Engine.get_meta(META_KEY)
		if is_instance_valid(inst):
			return inst
	var n = load(SELF_PATH).new()
	n.name = "GameAudio"
	Engine.set_meta(META_KEY, n)
	# the scene root is still busy setting up its children during _ready()
	from.get_tree().root.call_deferred("add_child", n)
	return n


func _ready():
	randomize()
	pause_mode = PAUSE_MODE_PROCESS
	var sd = SaveData.get_it()
	music_scale = clamp(float(sd.get_setting("music_volume")), 0.0, 1.0)
	sfx_scale = clamp(float(sd.get_setting("sfx_volume")), 0.0, 1.0)
	AudioServer.set_bus_mute(0, bool(sd.get_setting("muted")))
	music = _make_player("Music")
	crowd = _make_player("Crowd")
	sfx = _make_player("Goal")
	music.connect("finished", self, "_on_music_finished")
	crowd.connect("finished", self, "_on_crowd_finished")
	tween = Tween.new()
	add_child(tween)
	music_clips = _load_dir(MUSIC_DIR)
	crowd_clips = _load_dir(CROWD_DIR)
	goal_clips = _load_dir(GOAL_DIR)
	for c in goal_clips:
		_no_loop(c)   # even if 'Loop' is ticked in the file's import settings
	_apply()


func _input(event):
	if event is InputEventKey and event.pressed and not event.echo and event.scancode == KEY_M:
		toggle_mute()


# ------------------------------------------------------------------- public

# Menus, team select, tournament hub, results: music up, crowd off.
func enter_menu():
	in_match = false
	_apply()


# Match scene: music ducked, crowd loop on.
func enter_match():
	in_match = true
	_apply()


# Goal shout + crowd swell. Safe to call any time.
func goal_scored():
	if sfx == null:
		return
	# one shout per goal: ignore a second trigger for the same goal
	var now = OS.get_ticks_msec()
	if now - last_goal_ms < 1000:
		return
	last_goal_ms = now
	if goal_clips.size() > 0:
		last_goal = _pick(goal_clips, last_goal)
		sfx.stream = last_goal
		sfx.volume_db = _db(GOAL_DB, sfx_scale)
		sfx.play()
	if crowd.playing:
		tween.stop_all()
		tween.interpolate_property(crowd, "volume_db", _db(CROWD_DB + GOAL_SWELL_DB, sfx_scale), _db(CROWD_DB, sfx_scale),
				GOAL_SWELL_TIME, Tween.TRANS_QUAD, Tween.EASE_OUT)
		tween.start()


# Volume sliders (0..1). Saved to disk by the caller via SaveData.save().
func set_music_volume(v):
	music_scale = clamp(v, 0.0, 1.0)
	if music != null:
		music.volume_db = _db(MUSIC_MATCH_DB if in_match else MUSIC_DB, music_scale)
	SaveData.get_it().set_setting("music_volume", music_scale, false)


func set_sfx_volume(v):
	sfx_scale = clamp(v, 0.0, 1.0)
	if crowd != null and crowd.playing and not tween.is_active():
		crowd.volume_db = _db(CROWD_DB, sfx_scale)
	SaveData.get_it().set_setting("sfx_volume", sfx_scale, false)


func toggle_mute():
	AudioServer.set_bus_mute(0, not AudioServer.is_bus_mute(0))
	SaveData.get_it().set_setting("muted", AudioServer.is_bus_mute(0))
	return AudioServer.is_bus_mute(0)


# Called by the pause menu: freezes / unfreezes the match sounds.
func set_match_paused(p):
	if crowd != null:
		crowd.stream_paused = p
		sfx.stream_paused = p


# ---------------------------------------------------------------- internals

func _db(base, scale):
	if scale <= 0.001:
		return -80.0
	return base + linear2db(scale)


func _apply():
	if music == null:
		return   # not in the tree yet; _ready() will call _apply()
	music.volume_db = _db(MUSIC_MATCH_DB if in_match else MUSIC_DB, music_scale)
	if not music.playing and music_clips.size() > 0:
		_next_music()
	if in_match:
		if not crowd.playing and crowd_clips.size() > 0:
			crowd.volume_db = _db(CROWD_DB, sfx_scale)
			_next_crowd()
	else:
		tween.stop_all()
		sfx.stop()   # a shout never carries over into the menus
		crowd.stream_paused = false
		sfx.stream_paused = false
		crowd.stop()


func _next_music():
	last_music = _pick(music_clips, last_music)
	music.stream = last_music
	music.play()


func _next_crowd():
	last_crowd = _pick(crowd_clips, last_crowd)
	crowd.stream = last_crowd
	crowd.play()


# Goal shouts are one-shots: switch off looping on whatever stream type it is.
func _no_loop(stream):
	if stream is AudioStreamOGGVorbis or stream is AudioStreamMP3:
		stream.loop = false
	elif stream is AudioStreamSample:
		stream.loop_mode = AudioStreamSample.LOOP_DISABLED


func _on_music_finished():
	_next_music()


func _on_crowd_finished():
	if in_match:
		_next_crowd()


func _make_player(player_name):
	var p = AudioStreamPlayer.new()
	p.name = player_name
	add_child(p)
	return p


func _pick(clips, last):
	if clips.size() == 1:
		return clips[0]
	var s = clips[randi() % clips.size()]
	while s == last:
		s = clips[randi() % clips.size()]
	return s


# Loads every .ogg / .mp3 / .wav in a folder. Works in exported builds too,
# where files are listed as "name.ogg.import".
func _load_dir(path):
	var out = []
	var d = Directory.new()
	if d.open(path) != OK:
		return out
	var seen = {}
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		if not d.current_is_dir():
			var name = f
			if name.ends_with(".import"):
				name = name.substr(0, name.length() - 7)
			var ext = name.get_extension().to_lower()
			if (ext == "ogg" or ext == "mp3" or ext == "wav") and not seen.has(name):
				seen[name] = true
				var res = load(path + "/" + name)
				if res != null:
					out.append(res)
		f = d.get_next()
	d.list_dir_end()
	return out
