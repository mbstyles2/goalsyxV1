extends Node

var match_scene: Node2D = null

var intro_layer: CanvasLayer = null
var stats_layer: CanvasLayer = null
var lbl_intro_title: Label = null
var lbl_intro_sub: Label = null
var lbl_stats_display: Label = null

# Match Stats Tracking [Team 0 (Home), Team 1 (Away)]
var stats_possession_frames = [0.0, 0.0]
var stats_shots = [0, 0]
var stats_offsides = [0, 0]
var stats_fouls = [0, 0]
var stats_passes = [0, 0]

var intro_active = true
var intro_timer = 3.5


func _init(p_match_scene):
	match_scene = p_match_scene


func setup_ui():
	_build_intro_overlay()
	_build_stats_overlay()


# --------------------------------------------------------------------------
# 1. PRE-MATCH INTRO SCREEN
# --------------------------------------------------------------------------
func _build_intro_overlay():
	intro_layer = CanvasLayer.new()
	intro_layer.layer = 105
	match_scene.add_child(intro_layer)

	var bg = ColorRect.new()
	bg.rect_size = Vector2(1600, 950)
	bg.color = Color(0.04, 0.04, 0.06, 0.95)
	intro_layer.add_child(bg)

	var center_node = Control.new()
	center_node.rect_position = Vector2(400, 300)
	intro_layer.add_child(center_node)

	var home_name = Game.team_name(Game.home_id).to_upper()
	var away_name = Game.team_name(Game.away_id).to_upper()

	lbl_intro_title = Label.new()
	lbl_intro_title.rect_min_size = Vector2(80, 80)
	lbl_intro_title.align = Label.ALIGN_CENTER
	lbl_intro_title.text = "%s   VS   %s" % [home_name, away_name]
	
	var font = DynamicFont.new()
	font.font_data = load("res://assets/fonts/batmfa.ttf")
	font.size = 28
	lbl_intro_title.add_font_override("font", font)
	center_node.add_child(lbl_intro_title)

	lbl_intro_sub = Label.new()
	lbl_intro_sub.rect_min_size = Vector2(80, 40)
	lbl_intro_sub.rect_position = Vector2(40, 90)
	lbl_intro_sub.align = Label.ALIGN_CENTER
	lbl_intro_sub.text = "MATCH STARTING..."
	
	var sub_font = DynamicFont.new()
	sub_font.font_data = load("res://assets/fonts/batmfa.ttf")
	sub_font.size = 14
	lbl_intro_sub.add_font_override("font", sub_font)
	center_node.add_child(lbl_intro_sub)

	match_scene.state = "intro"


func update_intro(delta):
	if not intro_active:
		return
	intro_timer -= delta
	if intro_timer <= 0.0:
		intro_active = false
		if intro_layer:
			intro_layer.queue_free()
		match_scene.state = "playing"


# --------------------------------------------------------------------------
# 2. IN-MATCH STATS TRACKER OVERLAY (Hidden by default, shown on pause/full-time)
# --------------------------------------------------------------------------
func _build_stats_overlay():
	stats_layer = CanvasLayer.new()
	stats_layer.layer = 90
	match_scene.add_child(stats_layer)

	var root = Control.new()
	root.rect_position = Vector2(300, 200) # Centered box for pause/end-game view
	root.rect_scale = Vector2(2.2, 2.2)
	stats_layer.add_child(root)

	var panel = ColorRect.new()
	panel.rect_size = Vector2(240, 120)
	panel.color = Color(0.02, 0.02, 0.04, 0.92)
	root.add_child(panel)

	lbl_stats_display = Label.new()
	lbl_stats_display.rect_position = Vector2(12, 10)
	lbl_stats_display.rect_min_size = Vector2(215, 100)
	
	var font = DynamicFont.new()
	font.font_data = load("res://assets/fonts/batmfa.ttf")
	font.size = 9
	lbl_stats_display.add_font_override("font", font)
	root.add_child(lbl_stats_display)
	
	_refresh_stats_display()
	
	# Keep hidden during live gameplay
	stats_layer.visible = false


func set_stats_visible(is_visible: bool):
	if is_instance_valid(stats_layer):
		_refresh_stats_display()
		stats_layer.visible = is_visible


func process_stats(delta, possession_array):
	if intro_active or match_scene.state != "playing":
		return

	if possession_array[0]:
		stats_possession_frames[0] += delta
	elif possession_array[1]:
		stats_possession_frames[1] += delta


func record_shot(team):
	stats_shots[team] += 1
	_refresh_stats_display()

func record_offside(team):
	stats_offsides[team] += 1
	_refresh_stats_display()

func record_foul(team):
	stats_fouls[team] += 1
	_refresh_stats_display()

func record_pass(team):
	stats_passes[team] += 1
	_refresh_stats_display()


func _refresh_stats_display():
	if not is_instance_valid(lbl_stats_display):
		return

	var total_poss = stats_possession_frames[0] + stats_possession_frames[1]
	var p0_pct = 50
	var p1_pct = 50
	if total_poss > 0.0:
		p0_pct = int((stats_possession_frames[0] / total_poss) * 100)
		p1_pct = 100 - p0_pct

	var text = "=== MATCH STATISTICS ===\n"
	text += "Possession: %d%% - %d%%\n" % [p0_pct, p1_pct]
	text += "Shots:          %d - %d\n" % [stats_shots[0], stats_shots[1]]
	text += "Passes:       %d - %d\n" % [stats_passes[0], stats_passes[1]]
	text += "Offsides:     %d - %d\n" % [stats_offsides[0], stats_offsides[1]]
	text += "Fouls:          %d - %d" % [stats_fouls[0], stats_fouls[1]]
	
	lbl_stats_display.text = text
