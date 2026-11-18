extends Reference
# Jersey switcher: plain team colours (as before) or your picture designs.
#
# YOUR PICTURES: put the 8 images in  res://art/jerseys/  named after their
# colour: blue.png, red.png, ... (.png / .jpg / .jpeg / .webp).
#
# Each image is matched to the team whose colour is closest to the file's
# colour name, one image per team (best matches first). Check Godot's Output
# panel when the game starts: it prints "Jerseys: <team> -> <file>" so you can
# see exactly what was matched. If one is wrong, force it in OVERRIDES below.
#
# The player's choice (plain / designs) is saved in save.json.
#
# From any script:
#   const Jerseys = preload("res://scripts/ui/jerseys.gd")
#   Jerseys.get_it().texture_for(team_id)   # null when "plain" is selected

const SaveData = preload("res://scripts/save/save_data.gd")

const SELF_PATH = "res://scripts/ui/jerseys.gd"
const META_KEY = "jerseys"
const JERSEY_DIR = "res://art/jerseys"

# Force a match when the automatic one is wrong:  "Team Name": "filename_without_ext"
const OVERRIDES = {
}

# Reference colour for each file name (spaces / _ / - in file names are ignored).
const COLOR_NAMES = {
	"red": Color(0.85, 0.10, 0.10),
	"blue": Color(0.15, 0.30, 0.85),
	"green": Color(0.10, 0.65, 0.20),
	"yellow": Color(0.95, 0.85, 0.10),
	"orange": Color(0.95, 0.50, 0.10),
	"purple": Color(0.50, 0.20, 0.70),
	"pink": Color(0.95, 0.50, 0.70),
	"white": Color(0.95, 0.95, 0.95),
	"black": Color(0.10, 0.10, 0.10),
	"gray": Color(0.50, 0.50, 0.50),
	"grey": Color(0.50, 0.50, 0.50),
	"brown": Color(0.50, 0.30, 0.15),
	"cyan": Color(0.10, 0.80, 0.90),
	"skyblue": Color(0.40, 0.70, 0.95),
	"lightblue": Color(0.40, 0.70, 0.95),
	"navy": Color(0.05, 0.10, 0.40),
	"darkblue": Color(0.05, 0.10, 0.40),
	"maroon": Color(0.50, 0.05, 0.10),
	"gold": Color(0.90, 0.75, 0.20),
	"teal": Color(0.10, 0.50, 0.50),
	"lime": Color(0.60, 0.90, 0.10),
	"lightgreen": Color(0.60, 0.90, 0.10),
	"darkgreen": Color(0.05, 0.35, 0.12),
	"magenta": Color(0.90, 0.10, 0.80),
	"violet": Color(0.60, 0.40, 0.90),
}

var textures = {}        # normalised file name -> Texture
var assigned = {}        # team id -> Texture
var assigned_name = {}   # team id -> file name (for the debug print)


static func get_it():
	if not Engine.has_meta(META_KEY):
		var j = load(SELF_PATH).new()
		Engine.set_meta(META_KEY, j)
		j.build()
	return Engine.get_meta(META_KEY)


# ------------------------------------------------------------------- public

func designs_available():
	return textures.size() > 0


# True when the player has chosen "designs" (and pictures exist).
func enabled():
	return designs_available() and str(SaveData.get_it().get_setting("jersey_style")) == "designs"


func toggle():
	var nxt = "plain" if enabled() else "designs"
	SaveData.get_it().set_setting("jersey_style", nxt)
	return enabled()


# Texture to draw on this team's players, or null for the plain colour.
func texture_for(team_id):
	if not enabled():
		return null
	return assigned.get(team_id)


# The design for a team regardless of the current choice (team-select preview).
func preview_for(team_id):
	return assigned.get(team_id)


# ----------------------------------------------------------------- building

func build():
	_scan()
	if textures.size() == 0:
		return
	_assign()


func _norm(n):
	return n.to_lower().replace(" ", "").replace("_", "").replace("-", "")


func _scan():
	var d = Directory.new()
	if d.open(JERSEY_DIR) != OK:
		return
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		if not d.current_is_dir():
			var fname = f
			if fname.ends_with(".import"):
				fname = fname.substr(0, fname.length() - 7)
			var ext = fname.get_extension().to_lower()
			var key = _norm(fname.get_basename())
			if (ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "webp") and not textures.has(key):
				var tex = load(JERSEY_DIR + "/" + fname)
				if tex != null:
					textures[key] = tex
		f = d.get_next()
	d.list_dir_end()


func _dist(a, b):
	return Vector3(a.r, a.g, a.b).distance_to(Vector3(b.r, b.g, b.b))


func _pair_cmp(a, b):
	return a[0] < b[0]


# One picture per team, closest colours first; leftovers take the nearest picture.
func _assign():
	var ids = Game.all_team_ids()
	var used = {}
	var pairs = []
	for id in ids:
		var forced = _norm(str(OVERRIDES.get(Game.team_name(id), "")))
		if forced != "" and textures.has(forced):
			assigned[id] = textures[forced]
			assigned_name[id] = forced
			continue
		for key in textures.keys():
			var ref = COLOR_NAMES.get(key)
			if ref != null:
				pairs.append([_dist(Game.team_color(id), ref), id, key])
	pairs.sort_custom(self, "_pair_cmp")
	for p in pairs:
		if not assigned.has(p[1]) and not used.has(p[2]):
			assigned[p[1]] = textures[p[2]]
			assigned_name[p[1]] = p[2]
			used[p[2]] = true
	for id in ids:
		if assigned.has(id):
			continue
		var best = null
		var best_d = 1000.0
		for key in textures.keys():
			var ref = COLOR_NAMES.get(key)
			if ref != null:
				var dd = _dist(Game.team_color(id), ref)
				if dd < best_d:
					best_d = dd
					best = key
		if best == null:
			for key in textures.keys():
				if COLOR_NAMES.get(key) == null and not used.has(key):
					best = key
					break
		if best != null:
			assigned[id] = textures[best]
			assigned_name[id] = best
			used[best] = true
	for id in ids:
		print("Jerseys: ", Game.team_name(id), " -> ", assigned_name.get(id, "(plain)"))
