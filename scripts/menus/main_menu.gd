extends Control

const Extras = preload("res://scripts/extras/extras.gd")
const GameAudio = preload("res://scripts/audio/game_audio.gd")
const UIStyle = preload("res://scripts/ui/ui_style.gd")
const LoadingScreen = preload("res://scripts/ui/loading_screen.gd")
const SaveData = preload("res://scripts/save/save_data.gd")

var menu_box
var reset_armed = false


func _ready():
	GameAudio.get_it(self).enter_menu()
	UIStyle.apply(self)
	LoadingScreen.get_it(self).boot()
	
	# entering the menu always clears the extra modes (Last Team Standing / shootouts)
	Extras.get_it().reset()
	var root = Control.new()
	root.rect_scale = Vector2(2, 2)
	add_child(root)
	var title = Label.new()
	title.text = "....GOALSYX:ELEVEN...."
	title.align = Label.ALIGN_CENTER
	title.rect_min_size = Vector2(480, 0)
	title.rect_position = Vector2(0, 24)
	var custom_font = DynamicFont.new()
	custom_font.font_data = load("res://assets/fonts/batmfa.ttf")
	custom_font.size = 13
	title.add_font_override("font", custom_font)
	title.add_color_override("font_color", UIStyle.GOLD)
	root.add_child(title)
	var box = VBoxContainer.new()
	box.rect_position = Vector2(100, 56)
	box.rect_min_size = Vector2(280, 0)
	box.add_constant_override("separation", 3)
	root.add_child(box)
	menu_box = box
	_main_menu()


# ---- menu panels: the top level only has 4 entries, everything else is inside them ----
func _clear():
	for c in menu_box.get_children():
		menu_box.remove_child(c)
		c.queue_free()


func _main_menu():
	_clear()
	_button(menu_box, "Exhibition", "_exhibition_menu")
	_button(menu_box, "Tournament", "_tournament_menu")
	_button(menu_box, "More Modes", "_more_modes")
	_button(menu_box, "Quit", "_quit")


func _exhibition_menu():
	_clear()
	_button(menu_box, "1 Player", "_exhibition")
	_button(menu_box, "2 Players", "_versus")
	_button(menu_box, "Back", "_main_menu")


func _tournament_menu():
	_clear()
	_button(menu_box, "Round Robin", "_tournament", [Tournament.Format.ROUND_ROBIN])
	_button(menu_box, "Knockout", "_tournament", [Tournament.Format.KNOCKOUT])
	_button(menu_box, "Back", "_main_menu")


func _button(parent, text, method, args = []):
	var b = Button.new()
	b.text = text
	b.rect_min_size = Vector2(280, 26)
	b.connect("pressed", self, method, args)
	parent.add_child(b)


func _exhibition():
	Game.mode = Game.Mode.EXHIBITION
	Game.two_player = false
	Game.goto("res://scenes/TeamSelect.tscn")


func _versus():
	Game.mode = Game.Mode.EXHIBITION
	Game.two_player = true
	Game.goto("res://scenes/TeamSelect.tscn")


func _tournament(fmt):
	Game.mode = Game.Mode.TOURNAMENT
	Game.two_player = false
	Game.pending_format = fmt
	Game.goto("res://scenes/TeamSelect.tscn")


func _more_modes():
	_clear()
	_button(menu_box, "Set Match: 1 Player", "_set_match", [false])
	_button(menu_box, "Set Match: 2 Players", "_set_match", [true])
	_button(menu_box, "Last Team Standing", "_last_team_standing")
	_button(menu_box, "Penalty Shootout: 1 Player", "_pens", [false])
	_button(menu_box, "Penalty Shootout: 2 Players", "_pens", [true])
	_button(menu_box, "Stats & Records", "_show_stats")
	_button(menu_box, "Back", "_main_menu")


func _show_stats():
	_clear()
	reset_armed = false
	var sd = SaveData.get_it()
	var lines = [
		"Matches played: %d" % sd.stat("matches"),
		"Your record: %dW  %dD  %dL" % [sd.stat("wins"), sd.stat("draws"), sd.stat("losses")],
		"Goals: %d for, %d against" % [sd.stat("goals_for"), sd.stat("goals_against")],
		"2-player matches: %d" % sd.stat("versus_matches"),
		"Shootouts won: %d / %d" % [sd.stat("shootouts_won"), sd.stat("shootouts_played")],
		"Titles: Knockout %d, Last Team %d" % [sd.title_count("knockout"), sd.title_count("last_team_standing")],
		"Titles: Set Match %d" % sd.title_count("set_match"),
	]
	for t in lines:
		var l = Label.new()
		l.text = t
		l.align = Label.ALIGN_CENTER
		menu_box.add_child(l)
	var rb = Button.new()
	rb.text = "Reset stats"
	rb.connect("pressed", self, "_reset_stats", [rb])
	menu_box.add_child(rb)
	_button(menu_box, "Back", "_more_modes")


func _reset_stats(btn):
	if not reset_armed:
		reset_armed = true
		btn.text = "Really reset? Press again"
		return
	SaveData.get_it().reset_stats()
	_show_stats()


func _set_match(two):
	Game.mode = Game.Mode.TOURNAMENT
	Game.two_player = false
	Extras.get_it().reset()
	Extras.get_it().set_active = true
	Extras.get_it().set_two = two
	Game.goto("res://scenes/TeamSelect.tscn")


func _last_team_standing():
	Game.mode = Game.Mode.TOURNAMENT
	Game.two_player = false
	Extras.get_it().reset()
	Extras.get_it().lts_active = true
	Game.goto("res://scenes/TeamSelect.tscn")


func _pens(two):
	Game.mode = Game.Mode.EXHIBITION
	Game.two_player = two
	Extras.get_it().reset()
	Extras.get_it().shootout_only = true
	Game.goto("res://scenes/TeamSelect.tscn")


func _quit():
	get_tree().quit()
