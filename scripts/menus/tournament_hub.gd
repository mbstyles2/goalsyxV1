extends Control

const Extras = preload("res://scripts/extras/extras.gd")
const GameAudio = preload("res://scripts/audio/game_audio.gd")
const UIStyle = preload("res://scripts/ui/ui_style.gd")
const SaveData = preload("res://scripts/save/save_data.gd")

var root

# ---- TABLE AREA: one place to adjust the space + background of every table ----
# (Round Robin, Knockout bracket, Last Team Standing, Set Match). Units are the
# 480x270 layout space. The title is at y=6, the buttons start at y=195.
const TABLE_AREA = Rect2(12, 24, 456, 166)    # x, y, width, height of the panel
const TABLE_BG = Color(0.03, 0.10, 0.06, 0.80)     # panel colour (dark green, see-through)
const TABLE_BORDER = Color(1.0, 0.86, 0.20, 0.55)  # thin gold edge (alpha 0 = no edge)
const TABLE_PAD_TOP = 6                            # gap between panel top and the first row
const ROW_GAP = 6                                 # space between rows (was 1)


func _ready():
	GameAudio.get_it(self).enter_menu()
	UIStyle.apply(self)
	if Extras.get_it().set_active:
		_build_set()
		return
	if Extras.get_it().lts_active:
		_build_lts()
		return
	Tournament.sim_until_player()
	root = Control.new()
	root.rect_scale = Vector2(2, 2)
	add_child(root)
	if Tournament.format == Tournament.Format.ROUND_ROBIN:
		_label("ROUND ROBIN", 6)
		_table()
	else:
		_label("KNOCKOUT", 6)
		_bracket()
	_footer()


func _label(text, y):
	var l = Label.new()
	l.text = text
	l.align = Label.ALIGN_CENTER
	l.rect_min_size = Vector2(480, 0)
	l.rect_position = Vector2(0, y)
	
	var custom_font = DynamicFont.new()
	custom_font.font_data = load("res://assets/fonts/batmfa.ttf")
	custom_font.size = 11
	l.add_font_override("font", custom_font)
	
	root.add_child(l)

# Dark rounded panel behind a table. Call it BEFORE the table is created.
func _table_panel():
	var p = Panel.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = TABLE_BG
	sb.set_corner_radius_all(6)
	sb.border_color = TABLE_BORDER
	sb.set_border_width_all(1)
	p.add_stylebox_override("panel", sb)
	p.rect_position = TABLE_AREA.position
	p.rect_size = TABLE_AREA.size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(p)


# Row spacing + centre the finished table inside the panel. Call it AFTER filling it.
func _place_table(node):
	if node is GridContainer:
		node.add_constant_override("vseparation", ROW_GAP)
	var sz = node.get_combined_minimum_size()
	node.rect_position = Vector2(
		TABLE_AREA.position.x + (TABLE_AREA.size.x - sz.x) / 2.0,
		TABLE_AREA.position.y + TABLE_PAD_TOP)


func _cell(text):
	var l = Label.new()
	l.text = text
	
	var custom_font = DynamicFont.new()
	custom_font.font_data = load("res://assets/fonts/batmfa.ttf")
	custom_font.size = 10
	l.add_font_override("font", custom_font)
	
	return l


func _table():
	_table_panel()
	var grid = GridContainer.new()
	grid.columns = 8
	grid.rect_position = Vector2(80, 26)
	grid.add_constant_override("hseparation", 14)
	grid.add_constant_override("vseparation", 1)
	root.add_child(grid)
	for h in ["", "Team", "P", "W", "D", "L", "GD", "Pts"]:
		grid.add_child(_cell(h))
	for id in Tournament.standings_sorted():
		var s = Tournament.standings[id]
		var sw = ColorRect.new()
		sw.color = Game.team_color(id)
		sw.rect_min_size = Vector2(10, 10)
		grid.add_child(sw)
		var nm = Game.team_name(id)
		if id == Tournament.player_id:
			nm += " <"
		grid.add_child(_cell(nm))
		for v in [s.p, s.w, s.d, s.l, s.gf - s.ga, s.pts]:
			grid.add_child(_cell(str(v)))
	_place_table(grid)


func _bracket():
	_table_panel()
	var box = VBoxContainer.new()
	box.rect_position = Vector2(150, 24)
	box.add_constant_override("separation", 0)
	root.add_child(box)
	var last_round = -1
	for m in Tournament.fixtures:
		if m.round != last_round:
			last_round = m.round
			box.add_child(_cell("-- " + Tournament.round_label(m) + " --"))
		var t = Game.team_name(m.home) + " vs " + Game.team_name(m.away)
		if m.played:
			t = "%s %d - %d %s" % [Game.team_name(m.home), m.hg, m.ag, Game.team_name(m.away)]
			if m.hg == m.ag:
				t += "  (" + Game.team_name(m.winner) + " on pens)"
		if m.home == Tournament.player_id or m.away == Tournament.player_id:
			t = "> " + t
		box.add_child(_cell(t))
	_place_table(box)


func _footer():
	var box = VBoxContainer.new()
	box.rect_position = Vector2(140, 195)
	box.rect_min_size = Vector2(200, 0)
	root.add_child(box)
	if Tournament.is_finished():
		var c = Tournament.champion
		var msg = "CHAMPION: " + Game.team_name(c).to_upper()
		if c == Tournament.player_id:
			msg += "  - that's you!"
		_label(msg, 172)
		_button(box, "Main menu", "_menu")
	else:
		var m = Tournament.next_fixture()
		var opp = m.away if m.home == Tournament.player_id else m.home
		_label("Next: " + Tournament.round_label(m) + " - vs " + Game.team_name(opp), 172)
		_button(box, "Play match", "_play", [opp])
		_button(box, "Main menu", "_menu")


func _button(parent, text, method, args = []):
	var b = Button.new()
	b.text = text
	b.connect("pressed", self, method, args)
	parent.add_child(b)


func _play(opp):
	Game.home_id = Tournament.player_id
	Game.away_id = opp
	Game.goto("res://scenes/Match.tscn")


func _menu():
	Game.goto("res://scenes/MainMenu.tscn")


# ---- added: Last Team Standing ----
func _build_lts():
	var ex = Extras.get_it()
	root = Control.new()
	root.rect_scale = Vector2(2, 2)
	add_child(root)
	_label("LAST TEAM STANDING - ROUND %d" % ex.lts_round, 6)
	_lts_table(ex)
	_lts_footer(ex)


func _lts_table(ex):
	_table_panel()
	var grid = GridContainer.new()
	grid.columns = 7
	grid.rect_position = Vector2(70, 26)
	grid.add_constant_override("hseparation", 14)
	grid.add_constant_override("vseparation", 1)
	root.add_child(grid)
	for h in ["", "Team", "Pts", "W", "L", "GD", "Status"]:
		grid.add_child(_cell(h))
	var ranked = ex.ranked_alive()
	for id in ex.lts_standings():
		var s = ex.lts_table[id]
		var alive = s.alive
		var sw = ColorRect.new()
		sw.color = Game.team_color(id)
		sw.rect_min_size = Vector2(10, 10)
		if not alive:
			sw.modulate = Color(1, 1, 1, 0.4)
		grid.add_child(sw)
		var nm = Game.team_name(id)
		if id == ex.lts_player:
			nm += " <"
		var cells = [nm, str(s.pts), str(s.w), str(s.l), str(s.gf - s.ga)]
		var status = "OUT R%d" % s.out_round
		if alive:
			status = "In"
			if ex.lts_champion == id:
				status = "WINNER"
			elif not ex.lts_round_done and ranked.size() > 1 and ranked[ranked.size() - 1] == id:
				status = "At risk"
		cells.append(status)
		for c in cells:
			var l = _cell(c)
			if not alive:
				l.modulate = Color(1, 1, 1, 0.4)
			grid.add_child(l)
	_place_table(grid)


func _lts_footer(ex):
	var box = VBoxContainer.new()
	box.rect_position = Vector2(140, 195)
	box.rect_min_size = Vector2(200, 0)
	root.add_child(box)
	var me = ex.lts_player
	if ex.lts_champion != -1:
		var msg = "LAST TEAM STANDING: " + Game.team_name(ex.lts_champion).to_upper()
		if ex.lts_champion == me:
			msg += "  - that's you!"
		_label(msg, 172)
	elif ex.lts_round_done:
		_label("Round %d: %s eliminated" % [ex.lts_round, Game.team_name(ex.lts_last_eliminated)], 172)
		if ex.is_alive(me):
			_button(box, "Next round", "_lts_next")
		else:
			_button(box, "Simulate rest", "_lts_sim_all")
	else:
		var m = ex.lts_player_fixture()
		if m == null:
			_label("Round %d: you have a bye (+%d pt)" % [ex.lts_round, Extras.PTS_BYE], 172)
			_button(box, "Continue", "_lts_resolve")
		else:
			var opp = m.away if m.home == me else m.home
			_label("Round %d - vs %s" % [ex.lts_round, Game.team_name(opp)], 172)
			_button(box, "Play match", "_lts_play", [opp])
	_button(box, "Main menu", "_menu")


func _lts_play(opp):
	Game.mode = Game.Mode.TOURNAMENT
	Game.home_id = Extras.get_it().lts_player
	Game.away_id = opp
	Game.goto("res://scenes/Match.tscn")


func _lts_resolve():
	Extras.get_it().lts_resolve_round()
	Game.goto("res://scenes/TournamentHub.tscn")


func _lts_next():
	Extras.get_it().lts_next_round()
	Game.goto("res://scenes/TournamentHub.tscn")


func _lts_sim_all():
	Extras.get_it().lts_sim_to_end()
	Game.goto("res://scenes/TournamentHub.tscn")


# ---- added: Nigerian Set Match ----
func _build_set():
	var ex = Extras.get_it()
	ex.set_sim_until_human()   # plays out AI-vs-AI matches until a human team is up
	root = Control.new()
	root.rect_scale = Vector2(2, 2)
	add_child(root)
	var rule = "golden goal" if ex.set_goals_to_win == 1 else "first to %d" % ex.set_goals_to_win
	_label("NIGERIAN SET MATCH - %d / %d min  (%s)" % [ex.set_clock, ex.set_total, rule], 6)
	_set_table(ex)
	_set_footer(ex)


func _set_table(ex):
	_table_panel()
	var grid = GridContainer.new()
	grid.columns = 9
	grid.rect_position = Vector2(40, 26)
	grid.add_constant_override("hseparation", 10)
	grid.add_constant_override("vseparation", 1)
	root.add_child(grid)
	for h in ["", "Team", "Queue", "P", "W", "D", "L", "GD", "Pts"]:
		grid.add_child(_cell(h))
	var ranking = ex.set_ranking()
	for i in range(ranking.size()):
		var id = ranking[i]
		var s = ex.set_table[id]
		var sw = ColorRect.new()
		sw.color = Game.team_color(id)
		sw.rect_min_size = Vector2(10, 10)
		grid.add_child(sw)
		var nm = Game.team_name(id)
		var hi = ex.set_humans.find(id)
		if hi != -1:
			nm += (" (P%d)" % (hi + 1)) if ex.set_two else " <"
		var st = "-"
		if ex.set_finished:
			if i == 0:
				st = "WINNER"
		elif ex.set_pitch.has(id):
			st = "PITCH"
		else:
			st = "Q%d" % (ex.set_queue.find(id) + 1)
		var cells = [nm, st, str(s.p), str(s.w), str(s.d), str(s.l), str(s.gf - s.ga), str(s.w)]
		for c in cells:
			grid.add_child(_cell(c))
	_place_table(grid)


func _set_footer(ex):
	var box = VBoxContainer.new()
	box.rect_position = Vector2(140, 195)
	box.rect_min_size = Vector2(200, 0)
	root.add_child(box)
	if ex.set_finished:
		var w = ex.set_ranking()[0]
		var msg = "WINNER: " + Game.team_name(w).to_upper()
		if ex.set_humans.has(w):
			msg += "  - that's you!"
			if not ex.set_saved:
				ex.set_saved = true
				SaveData.get_it().record_title("set_match")
		_label(msg, 172)
	else:
		var a = ex.set_pitch[0]
		var b = ex.set_pitch[1]
		var msg = "Next: %s vs %s" % [Game.team_name(a), Game.team_name(b)]
		if ex.set_two and (ex.set_humans.has(a) != ex.set_humans.has(b)):
			msg += "  (use WASD)"
		_label(msg, 172)
		_button(box, "Play match", "_set_play")
	_button(box, "Main menu", "_menu")


func _set_play():
	Extras.get_it().set_prepare_match()
	Game.goto("res://scenes/Match.tscn")
