extends Control

const Extras = preload("res://scripts/extras/extras.gd")
const GameAudio = preload("res://scripts/audio/game_audio.gd")
const UIStyle = preload("res://scripts/ui/ui_style.gd")
const SaveData = preload("res://scripts/save/save_data.gd")


func _ready():
	GameAudio.get_it(self).enter_menu()
	UIStyle.apply(self)
	if Extras.get_it().shootout_only:
		_shootout_results()
		return
	var root = Control.new()
	root.rect_scale = Vector2(2, 2)
	add_child(root)
	var hg = Game.last_home_goals
	var ag = Game.last_away_goals
	# career stats (save.json): every human match is recorded once, here
	SaveData.get_it().record_match(Game.team_name(Game.home_id), Game.team_name(Game.away_id), hg, ag, Game.two_player)
	if Extras.get_it().pens != null:
		SaveData.get_it().record_shootout(Game.two_player, Extras.get_it().pens.winner == 0)
	_label(root, "FULL TIME", 30)
	_label(root, "%s  %d - %d  %s" % [Game.team_name(Game.home_id), hg, ag, Game.team_name(Game.away_id)], 85)
	_swatch(root, Game.team_color(Game.home_id), 110, 82)
	_swatch(root, Game.team_color(Game.away_id), 356, 82)
	var box = VBoxContainer.new()
	box.rect_position = Vector2(140, 175)
	box.rect_min_size = Vector2(200, 0)
	root.add_child(box)
	if Extras.get_it().set_active:
		_set_results(root, box, hg, ag)
		return
	if Extras.get_it().lts_active:
		_lts_results(root, box, hg, ag)
		return
	if Game.mode == Game.Mode.TOURNAMENT:
		# Tournament.report_result() takes the shootout winner (team id) directly
		var pw = -1
		if hg == ag and Extras.get_it().pens != null:
			pw = Game.home_id if Extras.get_it().pens.winner == 0 else Game.away_id
		Tournament.report_player_result(hg, ag, pw)
		var m = Tournament.fixtures[Tournament.current - 1]
		if Tournament.format == Tournament.Format.KNOCKOUT:
			if hg == ag:
				_label(root, "Level - " + Game.team_name(m.winner) + " win on penalties", 115)
				if Extras.get_it().pens != null:
					_label(root, "Penalties: %d - %d" % [Extras.get_it().pens.home, Extras.get_it().pens.away], 155)
			var won = (m.winner == Tournament.player_id)
			if won and Tournament.is_finished():
				_label(root, "You are the champions!", 135)
				SaveData.get_it().record_title("knockout")
			elif won:
				_label(root, "You advance!", 135)
			else:
				_label(root, "You are out of the tournament", 135)
		_button(box, "Continue", "_continue")
	else:
		_button(box, "Rematch", "_rematch")
		_button(box, "Main menu", "_menu")


func _label(parent, text, y):
	var l = Label.new()
	l.text = text
	l.align = Label.ALIGN_CENTER
	l.rect_min_size = Vector2(480, 0)
	l.rect_position = Vector2(0, y)
	parent.add_child(l)


func _swatch(parent, color, x, y):
	var r = ColorRect.new()
	r.color = color
	r.rect_min_size = Vector2(14, 14)
	r.rect_position = Vector2(x, y)
	parent.add_child(r)


func _button(parent, text, method):
	var b = Button.new()
	b.text = text
	b.connect("pressed", self, method)
	parent.add_child(b)


func _continue():
	Game.goto("res://scenes/TournamentHub.tscn")


func _rematch():
	Game.goto("res://scenes/Match.tscn")


func _menu():
	Game.goto("res://scenes/MainMenu.tscn")


# ---- added: standalone penalty shootout results ----
func _shootout_results():
	var pn = Extras.get_it().pens
	if pn == null:
		pn = {"home": 0, "away": 0, "winner": 0}
	var root = Control.new()
	root.rect_scale = Vector2(2, 2)
	add_child(root)
	_label(root, "PENALTY SHOOTOUT", 30)
	SaveData.get_it().record_shootout(Game.two_player, pn.winner == 0)
	_label(root, "%s  %d - %d  %s" % [Game.team_name(Game.home_id), pn.home, pn.away, Game.team_name(Game.away_id)], 85)
	_swatch(root, Game.team_color(Game.home_id), 110, 82)
	_swatch(root, Game.team_color(Game.away_id), 356, 82)
	var wid = Game.home_id if pn.winner == 0 else Game.away_id
	_label(root, Game.team_name(wid) + " win on penalties", 115)
	if not Game.two_player:
		_label(root, "You win!" if pn.winner == 0 else "You lose!", 135)
	var box = VBoxContainer.new()
	box.rect_position = Vector2(140, 175)
	box.rect_min_size = Vector2(200, 0)
	root.add_child(box)
	_button(box, "Rematch", "_rematch")
	_button(box, "Main menu", "_menu")


# ---- added: Last Team Standing results ----
func _lts_results(root, box, hg, ag):
	var ex = Extras.get_it()
	var res = ex.lts_report_player(hg, ag)
	var me = ex.lts_player
	if res.get("pens", false):
		var ps = res.pen_score
		_label(root, "Level - %s win %d - %d on penalties" % [Game.team_name(res.winner), ps[0], ps[1]], 115)
	var won = (res.get("winner", -1) == me)
	var txt = "Victory!" if won else "Defeat."
	_label(root, "%s  +%d survival points" % [txt, res.get("pts", 0)], 135)
	var out = ex.lts_last_eliminated
	if ex.lts_champion == me:
		_label(root, "You are the last team standing!", 155)
		SaveData.get_it().record_title("last_team_standing")
	elif out == me:
		_label(root, "You have been eliminated!", 155)
	elif out != -1:
		_label(root, Game.team_name(out) + " eliminated - you survive!", 155)
	_button(box, "Continue", "_continue")


# ---- added: Nigerian Set Match results ----
func _set_results(root, box, hg, ag):
	var ex = Extras.get_it()
	var res = ex.set_report(Game.home_id, Game.away_id, hg, ag)
	if res.get("draw", false):
		_label(root, "Draw - both teams go to the back of the queue", 115)
		_label(root, "No points awarded", 135)
	elif res.has("winner"):
		_label(root, "%s stay on the pitch  (+1 point)" % Game.team_name(res.winner), 115)
		_label(root, "%s go to the back of the queue" % Game.team_name(res.loser), 135)
	if ex.set_finished:
		_label(root, "Tournament time is up!", 155)
	else:
		_label(root, "Tournament time: %d / %d min" % [ex.set_clock, ex.set_total], 155)
	_button(box, "Continue", "_continue")
