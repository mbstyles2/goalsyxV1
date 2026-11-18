extends Node
# Autoload name: Game

const LoadingScreen = preload("res://scripts/ui/loading_screen.gd")

const TEAMS = [
	{"name": "Red",    "color": Color("e53935")},
	{"name": "Blue",   "color": Color("1e88e5")},
	{"name": "Green",  "color": Color("43a047")},
	{"name": "Yellow", "color": Color("fdd835")},
	{"name": "Orange", "color": Color("fb8c00")},
	{"name": "Purple", "color": Color("8e24aa")},
	{"name": "White",  "color": Color("f5f5f5")},
	{"name": "Black",  "color": Color("212121")},
]

# Pitch options
enum PitchType { MAIN, ESTATE_DIRT, CONCRETE_COURT, SANDY_FIELD, SCHOOL_FIELD }

const PITCHES = {
	PitchType.MAIN: {
		"name": "Grass Pitch",
		"bg": Color("1b5e20"),
		"stripe_a": Color("2e7d32"),
		"stripe_b": Color("388e3c"),
		"lines": Color(1, 1, 1, 0.85),
		"friction": 0.4
	},
	PitchType.ESTATE_DIRT: {
		"name": "Estate Dirt",
		"bg": Color("4e342e"),
		"stripe_a": Color("5d4037"),
		"stripe_b": Color("4e342e"),
		"lines": Color(0.85, 0.8, 0.7, 0.8),
		"friction": 0.25
	},
	PitchType.CONCRETE_COURT: {
		"name": "Concrete Court",
		"bg": Color("37474f"),
		"stripe_a": Color("455a64"),
		"stripe_b": Color("37474f"),
		"lines": Color(1, 0.85, 0.2, 0.85),
		"friction": 0.65
	},
	PitchType.SANDY_FIELD: {
		"name": "Sandy Field",
		"bg": Color("c2a649"),
		"stripe_a": Color("d4b85c"),
		"stripe_b": Color("c2a649"),
		"lines": Color(1, 1, 1, 0.75),
		"friction": 0.15
	},
	PitchType.SCHOOL_FIELD: {
		"name": "School Field",
		"bg": Color("2e7d32"),
		"stripe_a": Color("388e3c"),
		"stripe_b": Color("43a047"),
		"lines": Color(1, 1, 1, 0.85),
		"friction": 0.38
	}
}

enum Mode { EXHIBITION, TOURNAMENT, LAST_TEAM_STANDING }   # LAST_TEAM_STANDING: needed by Tournament.gd

var mode = Mode.EXHIBITION
var home_id = 0
var away_id = 1
var match_minutes = 45
var pending_format = 0
var two_player = false
var pitch_id = PitchType.MAIN  # Selected pitch or active pitch

var last_home_goals = 0
var last_away_goals = 0


func _ready():
	randomize()

# Add to Game.gd

var selected_pitch_id: int = 0

func set_active_pitch_id(id: int):
	selected_pitch_id = id

func get_active_pitch_id() -> int:
	return selected_pitch_id
	if mode == Mode.EXHIBITION:
		return pitch_id
	else:
		# Tournaments: 60% chance for Main field, 40% chance distributed across other fields
		if randf() < 0.60:
			return PitchType.MAIN
		var secondary_pitches = [
			PitchType.ESTATE_DIRT,
			PitchType.CONCRETE_COURT,
			PitchType.SANDY_FIELD,
			PitchType.SCHOOL_FIELD
		]
		return secondary_pitches[randi() % secondary_pitches.size()]


func team_name(id):
	return TEAMS[id].name


func team_color(id):
	return TEAMS[id].color


func all_team_ids():
	var ids = []
	for i in range(TEAMS.size()):
		ids.append(i)
	return ids


func goto(scene_path):
	# heavy scenes (the match) go through the loading screen, the rest switch instantly
	var ls = LoadingScreen.get_it(self)
	if ls.is_inside_tree() and ls.wants(scene_path):
		ls.go(scene_path)
		return
	get_tree().change_scene(scene_path)


# ---- Tournament.gd's built-in Last-Team-Standing code reads these (it errors
# ---- without them). The menu's Last Team Standing mode uses extras.gd instead.
var lms_active_teams = []
var lms_round = 1
var lms_scores = {}
var lms_round_pts = {}


func reset_lms():
	lms_active_teams = Tournament.team_ids.duplicate()
	lms_round = 1
	lms_scores = {}
	lms_round_pts = {}
	for id in lms_active_teams:
		lms_scores[id] = 0
		lms_round_pts[id] = 0
