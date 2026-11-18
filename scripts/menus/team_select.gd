extends Control

const Extras = preload("res://scripts/extras/extras.gd")
const GameAudio = preload("res://scripts/audio/game_audio.gd")
const UIStyle = preload("res://scripts/ui/ui_style.gd")
const Jerseys = preload("res://scripts/ui/jerseys.gd")
const SaveData = preload("res://scripts/save/save_data.gd")

var step = 0
var my_id = -1
var selected_pitch_id = 0
var title
var pitch_btn

# --- FIFA-Style Carousel & Kit States ---
var current_index = 0
var team_cards = []
var card_container
var btn_left
var btn_right
var kit_toggle_btn
var is_away_kit = false # false = Home Kit (Designs), true = Away Kit (Plain)

var buttons = [] # Kept for compatibility with set match / tournament flows


func _ready():
	GameAudio.get_it(self).enter_menu()
	UIStyle.apply(self)
	var root = Control.new()
	root.rect_scale = Vector2(2, 2)
	add_child(root)
	
	title = Label.new()
	title.align = Label.ALIGN_CENTER
	title.rect_min_size = Vector2(480, 0)
	title.rect_position = Vector2(0, 15)
	root.add_child(title)
	
	# --- FIFA-Style Horizontal Carousel Container ---
	card_container = Control.new()
	card_container.rect_position = Vector2(90, 60)
	card_container.rect_min_size = Vector2(300, 120)
	root.add_child(card_container)
	
	btn_left = Button.new()
	btn_left.text = "<"
	btn_left.rect_position = Vector2(45, 100)
	btn_left.rect_min_size = Vector2(35, 45)
	btn_left.connect("pressed", self, "_shift_team", [-1])
	root.add_child(btn_left)
	
	btn_right = Button.new()
	btn_right.text = ">"
	btn_right.rect_position = Vector2(400, 100)
	btn_right.rect_min_size = Vector2(35, 45)
	btn_right.connect("pressed", self, "_shift_team", [1])
	root.add_child(btn_right)

	# Build dummy button references for compatibility
	for id in range(Game.TEAMS.size()):
		var b = Button.new()
		buttons.append(b)
		_build_fifa_card(id)

	# --- Action Buttons & Kit / Pitch Pickers ---
	var action_box = HBoxContainer.new()
	action_box.rect_position = Vector2(90, 195)
	action_box.rect_min_size = Vector2(300, 30)
	action_box.alignment = BoxContainer.ALIGN_CENTER
	root.add_child(action_box)

	kit_toggle_btn = Button.new()
	kit_toggle_btn.connect("pressed", self, "_toggle_kit")
	action_box.add_child(kit_toggle_btn)

	var select_btn = Button.new()
	select_btn.text = "SELECT TEAM"
	select_btn.connect("pressed", self, "_confirm_selection")
	action_box.add_child(select_btn)
	
	var pitch_box = HBoxContainer.new()
	pitch_box.rect_position = Vector2(140, 230)
	pitch_box.rect_min_size = Vector2(200, 0)
	pitch_box.alignment = BoxContainer.ALIGN_CENTER
	root.add_child(pitch_box)
	
	pitch_btn = Button.new()
	pitch_btn.connect("pressed", self, "_cycle_pitch")
	pitch_box.add_child(pitch_btn)
	
	var back = Button.new()
	back.text = "Back"
	back.rect_position = Vector2(20, 230)
	back.connect("pressed", self, "_back")
	root.add_child(back)
	
	_refresh_kit_button()
	_refresh()
	if Extras.get_it().set_active:
		_set_init()


func _build_fifa_card(id):
	var card = VBoxContainer.new()
	card.rect_min_size = Vector2(300, 120)
	card.visible = false
	
	# Team color banner / background panel
	var banner = ColorRect.new()
	banner.color = Game.team_color(id)
	banner.rect_min_size = Vector2(300, 75)
	card.add_child(banner)
	
	# Jersey texture preview overlay on banner
	var pic = TextureRect.new()
	pic.texture = Jerseys.get_it().texture_for(id)
	pic.expand = true
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.anchor_right = 1.0
	pic.anchor_bottom = 1.0
	banner.add_child(pic)
	
	# Team Name label
	var lbl = Label.new()
	lbl.text = Game.team_name(id).to_upper()
	lbl.align = Label.ALIGN_CENTER
	card.add_child(lbl)
	
	card_container.add_child(card)
	team_cards.append({"card": card, "texture": pic})


func _shift_team(dir):
	current_index = (current_index + dir + Game.TEAMS.size()) % Game.TEAMS.size()
	# Skip opponent if step == 1 in exhibition/tourney mode
	if step == 1 and current_index == my_id:
		current_index = (current_index + dir + Game.TEAMS.size()) % Game.TEAMS.size()
	_update_carousel_view()


func _update_carousel_view():
	for i in range(team_cards.size()):
		var item = team_cards[i]
		var active = (i == current_index)
		item["card"].visible = active
		if active:
			var jz = Jerseys.get_it()
			# Home Kit = designs enabled, Away Kit = plain (designs disabled)
			item["texture"].visible = (not is_away_kit) and (jz.texture_for(i) != null)


func _toggle_kit():
	is_away_kit = not is_away_kit
	# Sync global jersey toggle state based on kit choice
	var jz = Jerseys.get_it()
	if jz.designs_available():
		# If away kit, turn custom designs off (plain). If home kit, turn designs on.
		if is_away_kit and jz.enabled():
			jz.toggle()
		elif not is_away_kit and not jz.enabled():
			jz.toggle()
	_refresh_kit_button()
	_update_carousel_view()


func _refresh_kit_button():
	if is_away_kit:
		kit_toggle_btn.text = "Kit: Away (Plain)"
	else:
		kit_toggle_btn.text = "Kit: Home (Design)"


func _confirm_selection():
	_pick(current_index)


func _input(event):
	if event is InputEventKey and event.pressed and not event.echo:
		if event.scancode == KEY_LEFT or event.scancode == KEY_A:
			_shift_team(-1)
		elif event.scancode == KEY_RIGHT or event.scancode == KEY_D:
			_shift_team(1)
		elif event.scancode == KEY_ENTER or event.scancode == KEY_SPACE:
			_confirm_selection()
			


func _refresh():
	if Game.two_player:
		title.text = "Player 1: choose your team" if step == 0 else "Player 2: choose your team"
	elif step == 0:
		title.text = "Choose your team"
	else:
		title.text = "Choose your opponent"
		
	# Ensure current index isn't disabled/same as my_id
	if step == 1 and current_index == my_id:
		_shift_team(1)
	else:
		_update_carousel_view()
		
	# Show pitch selector on step 1 when playing Exhibition
	if Game.mode == Game.Mode.EXHIBITION and step == 1:
		pitch_btn.show()
		_update_pitch_button_text()
	else:
		pitch_btn.hide()


func _cycle_pitch():
	var keys = Game.PITCHES.keys()
	var idx = keys.find(selected_pitch_id)
	idx = (idx + 1) % keys.size()
	selected_pitch_id = keys[idx]
	_update_pitch_button_text()


func _update_pitch_button_text():
	var p_data = Game.PITCHES[selected_pitch_id]
	pitch_btn.text = "Pitch: " + str(p_data.get("name", "Field " + str(selected_pitch_id)))


func _pick(id):
	if Extras.get_it().set_active:
		_set_pick(id)
		return
	if step == 0:
		my_id = id
		if Extras.get_it().lts_active:
			Extras.get_it().lts_start(id, Game.all_team_ids())
			Game.goto("res://scenes/TournamentHub.tscn")
			return
		if Game.mode == Game.Mode.EXHIBITION:
			step = 1
			_shift_team(1) # move to valid opponent card
			_refresh()
		else:
			Tournament.player_id = id
			Tournament.start(Game.pending_format, Game.all_team_ids())
			Game.goto("res://scenes/TournamentHub.tscn")
	else:
		Game.home_id = my_id
		Game.away_id = id
		if Game.has_method("set_active_pitch_id"):
			Game.set_active_pitch_id(selected_pitch_id)
		elif "selected_pitch_id" in Game:
			Game.selected_pitch_id = selected_pitch_id
		Game.goto("res://scenes/Match.tscn")


func _back():
	if Extras.get_it().set_active:
		_set_back()
		return
	if step == 1:
		step = 0
		_refresh()
	else:
		Game.goto("res://scenes/MainMenu.tscn")


# ---- Nigerian Set Match setup compatibility ----
var set_stage = 0          
var set_sel = []           
var set_humans = []
var set_minutes = 30
var set_goals = 2          
var set_goals_btn
var set_bar
var set_minutes_label
var set_next_btn


func _set_init():
	set_bar = HBoxContainer.new()
	set_bar.rect_position = Vector2(70, 230)
	set_bar.rect_min_size = Vector2(340, 0)
	set_bar.alignment = BoxContainer.ALIGN_CENTER
	title.get_parent().add_child(set_bar)
	var minus = Button.new()
	minus.text = "-"
	minus.connect("pressed", self, "_set_change_minutes", [-3])
	set_bar.add_child(minus)
	set_minutes_label = Label.new()
	set_bar.add_child(set_minutes_label)
	var plus = Button.new()
	plus.text = "+"
	plus.connect("pressed", self, "_set_change_minutes", [3])
	set_bar.add_child(plus)
	set_goals_btn = Button.new()
	set_goals_btn.connect("pressed", self, "_set_toggle_goals")
	set_bar.add_child(set_goals_btn)
	set_next_btn = Button.new()
	set_next_btn.text = "Next"
	set_next_btn.connect("pressed", self, "_set_next")
	set_bar.add_child(set_next_btn)
	
	var sd = SaveData.get_it()
	set_minutes = int(clamp(round(float(sd.get_setting("set_minutes")) / 3.0) * 3, 6, 180))
	set_goals = 1 if int(sd.get_setting("set_goals")) == 1 else 2
	for n in sd.get_setting("set_teams"):
		for i in range(Game.TEAMS.size()):
			if Game.team_name(i) == n and set_sel.size() < 8 and not set_sel.has(i):
				set_sel.append(i)
	_set_refresh()


func _set_refresh():
	var two = Extras.get_it().set_two
	if set_stage == 0:
		title.text = "Nigerian Set Match: pick 4-8 teams (%d)" % set_sel.size()
	elif set_stage == 1:
		title.text = "Player 1: choose your team" if two else "Choose your team"
	else:
		title.text = "Player 2: choose your team"
	set_bar.visible = (set_stage == 0)
	set_minutes_label.text = "Tournament: %d min" % set_minutes
	set_goals_btn.text = "Golden goal" if set_goals == 1 else "First to 2"
	set_next_btn.disabled = set_sel.size() < 4 or set_sel.size() > 8


func _set_toggle_goals():
	set_goals = 1 if set_goals == 2 else 2
	_set_refresh()


func _set_change_minutes(delta):
	set_minutes = int(clamp(set_minutes + delta, 6, 180))
	_set_refresh()


func _set_next():
	if set_sel.size() < 4 or set_sel.size() > 8:
		return
	set_stage = 1
	_set_refresh()


func _set_pick(id):
	if set_stage == 0:
		if set_sel.has(id):
			set_sel.erase(id)
		else:
			if set_sel.size() < 8:
				set_sel.append(id)
		_set_refresh()
		return
	set_humans.append(id)
	if Extras.get_it().set_two and set_humans.size() < 2:
		set_stage = 2
		_set_refresh()
		return
	var names = []
	for i in set_sel:
		names.append(Game.team_name(i))
	SaveData.get_it().set_setting("set_teams", names, false)
	SaveData.get_it().set_setting("set_goals", set_goals, false)
	SaveData.get_it().set_setting("set_minutes", set_minutes, false)
	Extras.get_it().set_start(set_sel, set_humans, set_minutes, set_goals)
	Game.goto("res://scenes/TournamentHub.tscn")


func _set_back():
	if set_stage == 0:
		Game.goto("res://scenes/MainMenu.tscn")
		return
	if set_stage == 1:
		set_stage = 0
		set_humans = []
	else:
		set_stage = 1
		set_humans = []
	_set_refresh()


func _label(parent, text, y):
	var l = Label.new()
	l.text = text
	l.align = Label.ALIGN_CENTER
	l.rect_min_size = Vector2(480, 0)
	l.rect_position = Vector2(0, y)
	
	var custom_font = DynamicFont.new()
	custom_font.font_data = load("res://assets/fonts/batmfa.ttf")
	custom_font.size = 12
	l.add_font_override("font", custom_font)
	
	parent.add_child(l)
	return l
