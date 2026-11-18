extends Node
# Autoload name: Tournament

enum Format { ROUND_ROBIN, KNOCKOUT }

var format = Format.ROUND_ROBIN
var team_ids = []
var fixtures = []      # {round, home, away, played, hg, ag, winner}
var current = 0        # index of the next fixture to play
var standings = {}     # team_id -> {p, w, d, l, gf, ga, pts}
var champion = -1
var player_id = 0


func start(new_format, ids):
	format = new_format
	team_ids = ids.duplicate()
	fixtures.clear()
	current = 0
	champion = -1
	_init_standings()
	if Game.mode == Game.Mode.LAST_TEAM_STANDING:
		Game.reset_lms()
		_build_lms_round()
	elif format == Format.ROUND_ROBIN:
		_build_round_robin()
	else:
		team_ids.shuffle()
		_build_knockout_round(team_ids, 0)


func is_finished():
	return champion != -1


func next_fixture():
	if current < fixtures.size():
		return fixtures[current]
	return null


func round_label(m):
	if Game.mode == Game.Mode.LAST_TEAM_STANDING:
		return "LMS Stage " + str(m.round + 1)
	if format == Format.ROUND_ROBIN:
		return "Matchday " + str(m.round + 1)
	var names = ["Quarter-final", "Semi-final", "Final"]
	return names[m.round]


func report_result(hg, ag, pen_winner = -1):
	var m = fixtures[current]
	m.hg = hg
	m.ag = ag
	m.played = true
	
	if Game.mode == Game.Mode.LAST_TEAM_STANDING:
		_update_lms_result(m, hg, ag, pen_winner)
	elif format == Format.ROUND_ROBIN:
		_update_standings(m)
	else:
		if hg == ag:
			m.winner = pen_winner if pen_winner != -1 else (m.home if randi() % 2 == 0 else m.away)
		else:
			m.winner = m.home if hg > ag else m.away
			
	current += 1
	
	if Game.mode == Game.Mode.LAST_TEAM_STANDING:
		_check_lms_progress()
	elif format == Format.ROUND_ROBIN:
		if current >= fixtures.size():
			champion = standings_sorted()[0]
	else:
		_check_knockout_progress()


func standings_sorted():
	var ids = standings.keys()
	ids.sort_custom(self, "_cmp")
	return ids


# ---------- internals ----------

func _make(a, b, r):
	return {"round": r, "home": a, "away": b, "played": false, "hg": 0, "ag": 0, "winner": -1}


func _init_standings():
	standings.clear()
	for id in team_ids:
		standings[id] = {"p": 0, "w": 0, "d": 0, "l": 0, "gf": 0, "ga": 0, "pts": 0}


func _build_round_robin():
	var t = team_ids.duplicate()
	var n = t.size()
	for r in range(n - 1):
		for i in range(n / 2):
			var a = t[i]
			var b = t[n - 1 - i]
			if r % 2 == 1:
				var tmp = a
				a = b
				b = tmp
			fixtures.append(_make(a, b, r))
		t.insert(1, t.pop_back())


func _build_knockout_round(ids, r):
	for i in range(0, ids.size(), 2):
		fixtures.append(_make(ids[i], ids[i + 1], r))


func _build_lms_round():
	var active = Game.lms_active_teams.duplicate()
	for id in active:
		Game.lms_round_pts[id] = 0
	active.shuffle()
	if active.size() % 2 != 0:
		active.append(active[0]) # Dummy pairing safeguard if odd
	for i in range(0, active.size(), 2):
		fixtures.append(_make(active[i], active[i+1], Game.lms_round - 1))


func _update_lms_result(m, hg, ag, pen_winner):
	var hp = 1
	var ap = 1
	if hg > ag or pen_winner == m.home:
		hp = 3
		ap = 0
	elif ag > hg or pen_winner == m.away:
		hp = 0
		ap = 3
		
	Game.lms_scores[m.home] += hp
	Game.lms_scores[m.away] += ap
	Game.lms_round_pts[m.home] += hp
	Game.lms_round_pts[m.away] += ap


func _check_lms_progress():
	if current < fixtures.size():
		return
		
	if Game.lms_active_teams.size() <= 1:
		champion = Game.lms_active_teams[0] if Game.lms_active_teams.size() == 1 else -1
		return

	# Eliminate bottom team of this round
	var lowest_id = Game.lms_active_teams[0]
	var lowest_pts = 99999
	for id in Game.lms_active_teams:
		var p = Game.lms_round_pts[id]
		if p < lowest_pts:
			lowest_pts = p
			lowest_id = id
			
	Game.lms_active_teams.erase(lowest_id)
	
	if Game.lms_active_teams.size() == 1:
		champion = Game.lms_active_teams[0]
	else:
		Game.lms_round += 1
		_build_lms_round()


func _check_knockout_progress():
	if current < fixtures.size():
		return
	var r = fixtures[fixtures.size() - 1].round
	var winners = []
	for m in fixtures:
		if m.round == r:
			winners.append(m.winner)
	if winners.size() == 1:
		champion = winners[0]
	else:
		_build_knockout_round(winners, r + 1)


func _update_standings(m):
	var h = standings[m.home]
	var a = standings[m.away]
	h.p += 1
	a.p += 1
	h.gf += m.hg
	h.ga += m.ag
	a.gf += m.ag
	a.ga += m.hg
	if m.hg > m.ag:
		h.w += 1
		a.l += 1
		h.pts += 3
	elif m.hg < m.ag:
		a.w += 1
		h.l += 1
		a.pts += 3
	else:
		h.d += 1
		a.d += 1
		h.pts += 1
		a.pts += 1


func _cmp(x, y):
	var a = standings[x]
	var b = standings[y]
	if a.pts != b.pts:
		return a.pts > b.pts
	var gda = a.gf - a.ga
	var gdb = b.gf - b.ga
	if gda != gdb:
		return gda > gdb
	return a.gf > b.gf


# ---------- single-player helpers ----------

func sim_until_player():
	while not is_finished():
		var m = next_fixture()
		if m == null or m.home == player_id or m.away == player_id:
			return
		var hg = _sim_goals()
		var ag = _sim_goals()
		var pw = -1
		if hg == ag and (Game.mode == Game.Mode.LAST_TEAM_STANDING or format == Format.KNOCKOUT):
			pw = m.home if randi() % 2 == 0 else m.away
		report_result(hg, ag, pw)


func report_player_result(player_goals, opp_goals, pen_winner = -1):
	var m = fixtures[current]
	if m.home == player_id:
		report_result(player_goals, opp_goals, pen_winner)
	else:
		report_result(opp_goals, player_goals, pen_winner)


func _sim_goals():
	var g = 0
	for i in range(6):
		if randf() < 0.28:
			g += 1
	return g
