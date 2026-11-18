extends Reference
# Persistent save data, stored as human-readable JSON in user://save.json
# (Godot's per-user folder: survives updates, works on every platform).
#
# What is saved:
#   settings : music / effects volume, mute, last Set Match setup
#   stats    : career totals (matches, your W/D/L, goals, shootouts)
#   titles   : tournaments you have won, per mode
#   teams    : per-team career record (keyed by team NAME, so adding or
#              re-ordering teams never corrupts old saves)
#
# Safety:
#   - missing / new keys are filled from defaults (old saves keep working)
#   - a corrupt file is copied to save.json.bak and the game starts fresh
#   - saves go to a temp file first, then replace the real one
#
# Usage from any script:
#   const SaveData = preload("res://scripts/save/save_data.gd")
#   SaveData.get_it().get_setting("music_volume")
#
# NOTE: Godot parses every JSON number as a float. Counters are read through
# int() (see stat()/title()), so never compare them to ints directly.

const SELF_PATH = "res://scripts/save/save_data.gd"
const META_KEY = "save_data"
const SAVE_PATH = "user://save.json"
const TMP_PATH = "user://save.json.tmp"
const BAK_PATH = "user://save.json.bak"
const VERSION = 1

var data = {}


static func get_it():
	if not Engine.has_meta(META_KEY):
		var s = load(SELF_PATH).new()
		Engine.set_meta(META_KEY, s)
		s.load_data()
	return Engine.get_meta(META_KEY)


func _defaults():
	return {
		"version": VERSION,
		"settings": {
			"music_volume": 1.0,
			"sfx_volume": 1.0,
			"muted": false,
			"jersey_style": "plain",
			"set_minutes": 30,
			"set_goals": 2,
			"set_teams": []
		},
		"stats": {
			"matches": 0, "wins": 0, "draws": 0, "losses": 0,
			"goals_for": 0, "goals_against": 0,
			"versus_matches": 0,
			"shootouts_played": 0, "shootouts_won": 0
		},
		"titles": {
			"knockout": 0, "last_team_standing": 0, "set_match": 0
		},
		"teams": {}
	}


# ------------------------------------------------------------------ file I/O

func load_data():
	data = _defaults()
	var f = File.new()
	if not f.file_exists(SAVE_PATH):
		return
	if f.open(SAVE_PATH, File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	var parsed = JSON.parse(text)
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		var d = Directory.new()
		d.copy(SAVE_PATH, BAK_PATH)
		print("save.json was unreadable - starting fresh (copy kept as save.json.bak)")
		return
	data = _merge(_defaults(), parsed.result)
	_migrate()


func save():
	var f = File.new()
	if f.open(TMP_PATH, File.WRITE) != OK:
		return false
	f.store_string(JSON.print(data, "\t"))
	f.close()
	var d = Directory.new()
	if d.file_exists(SAVE_PATH):
		d.remove(SAVE_PATH)
	return d.rename(TMP_PATH, SAVE_PATH) == OK


# Fills in anything missing; keeps unknown keys; ignores wrong-typed values.
func _merge(base, loaded):
	var out = base.duplicate(true)
	for k in loaded.keys():
		if base.has(k):
			var bt = typeof(base[k])
			var lt = typeof(loaded[k])
			if bt == TYPE_DICTIONARY and lt == TYPE_DICTIONARY:
				if base[k].empty():
					out[k] = loaded[k]   # free-form dictionary (teams)
				else:
					out[k] = _merge(base[k], loaded[k])
			elif bt == lt or (_is_num(bt) and _is_num(lt)):
				out[k] = loaded[k]
		else:
			out[k] = loaded[k]
	return out


func _is_num(t):
	return t == TYPE_INT or t == TYPE_REAL


# Future save-format changes go here (if data.version < 2: convert...).
func _migrate():
	data.version = VERSION


# ------------------------------------------------------------------ settings

func get_setting(key):
	return data.settings.get(key)


func set_setting(key, value, save_now = true):
	data.settings[key] = value
	if save_now:
		save()


# --------------------------------------------------------------------- stats

func stat(key):
	return int(data.stats.get(key, 0))


func title_count(kind):
	return int(data.titles.get(kind, 0))


func _inc(dict, key, n = 1):
	dict[key] = int(dict.get(key, 0)) + n


func _team(name):
	if not data.teams.has(name):
		data.teams[name] = {"p": 0, "w": 0, "d": 0, "l": 0, "gf": 0, "ga": 0}
	return data.teams[name]


func _team_add(name, gf, ga):
	var t = _team(name)
	_inc(t, "p")
	_inc(t, "gf", gf)
	_inc(t, "ga", ga)
	if gf > ga:
		_inc(t, "w")
	elif gf < ga:
		_inc(t, "l")
	else:
		_inc(t, "d")


# One finished match that the human played. `home` is the human side unless it
# was a two-player game. Level scores after a shootout count as draws here;
# the shootout itself is recorded with record_shootout().
func record_match(home_name, away_name, hg, ag, two_player):
	_team_add(home_name, hg, ag)
	_team_add(away_name, ag, hg)
	var st = data.stats
	_inc(st, "matches")
	if two_player:
		_inc(st, "versus_matches")
	else:
		_inc(st, "goals_for", hg)
		_inc(st, "goals_against", ag)
		if hg > ag:
			_inc(st, "wins")
		elif hg < ag:
			_inc(st, "losses")
		else:
			_inc(st, "draws")
	save()


func record_shootout(two_player, home_won):
	_inc(data.stats, "shootouts_played")
	if home_won and not two_player:
		_inc(data.stats, "shootouts_won")
	save()


func record_title(kind):
	_inc(data.titles, kind)
	save()


# Clears stats / titles / team records. Settings are kept.
func reset_stats():
	var d = _defaults()
	data.stats = d.stats
	data.titles = d.titles
	data.teams = d.teams
	save()
