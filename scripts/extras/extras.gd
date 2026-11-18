extends Reference
# Shared state + logic for the "Last Team Standing" mode and penalty shootouts.
#
# One instance is kept in Engine metadata so it survives scene changes and
# needs NO autoload / project-settings change. From any script:
#
#   const Extras = preload("res://scripts/extras/extras.gd")
#   var ex = Extras.get_it()

const SELF_PATH = "res://scripts/extras/extras.gd"
const META_KEY = "extras_state"

# ---- Last Team Standing: survival points ----
const PTS_WIN = 3        # win inside normal / extra time
const PTS_PEN_WIN = 2    # win on penalties
const PTS_PEN_LOSS = 1   # lose on penalties
const PTS_LOSS = 0
const PTS_BYE = 1        # odd number of teams left: one team sits out

# ---- Penalty shootout ----
var shootout_only = false   # standalone exhibition shootout mode
var pens = null             # last shootout: {"home": int, "away": int, "winner": 0|1}

# ---- Nigerian Set Match ----
const SET_MATCH_MINUTES = 3
var set_active = false
var set_two = false          # 2-player variant (two human teams)
var set_teams = []           # selection order = starting queue order
var set_humans = []          # human-controlled team ids: [P1 team] or [P1 team, P2 team]
var set_queue = []           # FIFO waiting queue
var set_pitch = []           # [entered first, entered second]; winner stays as [0]
var set_total = 30           # tournament length in minutes
var set_goals_to_win = 2     # a match ends when a team scores this many goals (1 = golden goal)
var set_clock = 0            # tournament minutes used (3 per match, played or simulated)
var set_table = {}           # team id -> {p, w, d, l, gf, ga, tb}
var set_results = []         # every finished match
var set_finished = false
var set_saved = false         # title already written to save.json
var saved_minutes = -1       # Game.match_minutes before the set match changed it

# ---- Last Team Standing state ----
var lts_active = false
var lts_player = -1
var lts_round = 0
var lts_round_done = false
var lts_table = {}          # team id -> {pts, w, l, gf, ga, alive, out_round, byes, tb}
var lts_fixtures = []       # this round's fixtures (dictionaries)
var lts_last_eliminated = -1
var lts_champion = -1
var lts_last_result = {}


static func get_it():
	if not Engine.has_meta(META_KEY):
		Engine.set_meta(META_KEY, load(SELF_PATH).new())
	return Engine.get_meta(META_KEY)


func reset():
	if saved_minutes != -1:
		Game.match_minutes = saved_minutes
		saved_minutes = -1
	set_active = false
	set_two = false
	set_teams = []
	set_humans = []
	set_queue = []
	set_pitch = []
	set_total = 30
	set_goals_to_win = 2
	set_clock = 0
	set_table = {}
	set_results = []
	set_finished = false
	set_saved = false
	shootout_only = false
	pens = null
	lts_active = false
	lts_player = -1
	lts_round = 0
	lts_round_done = false
	lts_table = {}
	lts_fixtures = []
	lts_last_eliminated = -1
	lts_champion = -1
	lts_last_result = {}


# ============================================================ Last Team Standing

func lts_start(player_id, ids):
	reset()
	randomize()
	lts_active = true
	lts_player = player_id
	for id in ids:
		lts_table[id] = {
			"pts": 0, "w": 0, "l": 0, "gf": 0, "ga": 0,
			"alive": true, "out_round": 0, "byes": 0, "tb": randf()
		}
	lts_next_round()


func alive_ids():
	var out = []
	for id in lts_table.keys():
		if lts_table[id].alive:
			out.append(id)
	return out


func is_alive(id):
	return lts_table.has(id) and lts_table[id].alive


func _fixture(h, a):
	return {
		"home": h, "away": a, "bye": a == -1, "played": false,
		"hg": 0, "ag": 0, "pens": false, "winner": -1
	}


func lts_next_round():
	if alive_ids().size() < 2:
		return
	lts_round += 1
	lts_round_done = false
	lts_last_eliminated = -1
	lts_last_result = {}
	lts_fixtures = []
	var ids = alive_ids()
	ids.shuffle()
	if ids.size() % 2 == 1:
		# the bye goes to whoever has had the fewest
		var bye = ids[0]
		for id in ids:
			if lts_table[id].byes < lts_table[bye].byes:
				bye = id
		ids.erase(bye)
		lts_fixtures.append(_fixture(bye, -1))
	for i in range(0, ids.size(), 2):
		var h = ids[i]
		var a = ids[i + 1]
		if a == lts_player:
			var tmp = h
			h = a
			a = tmp
		lts_fixtures.append(_fixture(h, a))


# The human's fixture this round (null if they have a bye / are out).
func lts_player_fixture():
	for m in lts_fixtures:
		if not m.bye and (m.home == lts_player or m.away == lts_player):
			return m
	return null


func lts_player_has_bye():
	for m in lts_fixtures:
		if m.bye and m.home == lts_player:
			return true
	return false


func _apply_result(m, hg, ag, pen_winner):
	m.played = true
	m.hg = hg
	m.ag = ag
	var h = lts_table[m.home]
	var a = lts_table[m.away]
	h.gf += hg
	h.ga += ag
	a.gf += ag
	a.ga += hg
	var win_id = -1
	var by_pens = false
	if hg > ag:
		win_id = m.home
	elif ag > hg:
		win_id = m.away
	else:
		by_pens = true
		win_id = pen_winner
		if win_id != m.home and win_id != m.away:
			win_id = m.home if randf() < 0.5 else m.away
	var lose_id = m.away if win_id == m.home else m.home
	var w = lts_table[win_id]
	var l = lts_table[lose_id]
	w.w += 1
	l.l += 1
	w.pts += PTS_PEN_WIN if by_pens else PTS_WIN
	l.pts += PTS_PEN_LOSS if by_pens else PTS_LOSS
	m.winner = win_id
	m.pens = by_pens


# Called from Results after the human's match. Uses `pens` if there was a shootout.
func lts_report_player(hg, ag):
	var m = lts_player_fixture()
	if m == null or m.played:
		return lts_last_result
	var pw = -1
	var pen_score = [0, 0]
	if hg == ag:
		if pens != null:
			pw = m.home if pens.winner == 0 else m.away
			pen_score = [pens.home, pens.away]
		else:
			pw = m.home if randf() < 0.5 else m.away
	_apply_result(m, hg, ag, pw)
	var pts = 0
	if m.winner == lts_player:
		pts = PTS_PEN_WIN if m.pens else PTS_WIN
	else:
		pts = PTS_PEN_LOSS if m.pens else PTS_LOSS
	lts_last_result = {
		"winner": m.winner, "pts": pts, "pens": m.pens,
		"hg": hg, "ag": ag, "pen_score": pen_score
	}
	lts_resolve_round()
	return lts_last_result


# Plays out every remaining fixture, awards byes, then eliminates the bottom team.
func lts_resolve_round():
	if lts_round_done or lts_champion != -1:
		return
	for m in lts_fixtures:
		if m.played:
			continue
		if m.bye:
			var t = lts_table[m.home]
			t.pts += PTS_BYE
			t.byes += 1
			m.played = true
		else:
			_sim_fixture(m)
	var ranked = ranked_alive()
	var out = -1
	if ranked.size() == 2:
		# the final is head-to-head: whoever wins the match survives
		for m in lts_fixtures:
			if not m.bye:
				out = m.away if m.winner == m.home else m.home
	if out == -1:
		out = ranked[ranked.size() - 1]
	lts_table[out].alive = false
	lts_table[out].out_round = lts_round
	lts_last_eliminated = out
	lts_round_done = true
	var left = alive_ids()
	if left.size() == 1:
		lts_champion = left[0]


func lts_sim_to_end():
	while lts_champion == -1:
		if lts_round_done:
			lts_next_round()
		lts_resolve_round()


# Alive teams by rank, then eliminated teams (latest exit first).
func lts_standings():
	var out = ranked_alive()
	var gone = []
	for id in lts_table.keys():
		if not lts_table[id].alive:
			gone.append(id)
	gone.sort_custom(self, "_later_out")
	return out + gone


func ranked_alive():
	var ids = alive_ids()
	ids.sort_custom(self, "_better")
	return ids


func _better(a, b):
	var ta = lts_table[a]
	var tb = lts_table[b]
	if ta.pts != tb.pts:
		return ta.pts > tb.pts
	var gda = ta.gf - ta.ga
	var gdb = tb.gf - tb.ga
	if gda != gdb:
		return gda > gdb
	if ta.gf != tb.gf:
		return ta.gf > tb.gf
	return ta.tb > tb.tb


func _later_out(a, b):
	return lts_table[a].out_round > lts_table[b].out_round


func _poisson(mean):
	var limit = exp(-mean)
	var k = 0
	var p = 1.0
	while true:
		k += 1
		p *= randf()
		if p <= limit:
			break
	return k - 1


func _sim_fixture(m):
	var hg = _poisson(1.5)
	var ag = _poisson(1.5)
	var pw = -1
	if hg == ag:
		# short extra time, then penalties
		if randf() < 0.4:
			if randf() < 0.5:
				hg += 1
			else:
				ag += 1
		if hg == ag:
			pw = m.home if randf() < 0.5 else m.away
	_apply_result(m, hg, ag, pw)


# ============================================================ Knockout + shootout

# Knockout only: the original Tournament picks a random penalty winner when a
# fixture ends level. Replace it with the winner of the shootout the player
# actually played (and fix up anything that was already advanced).
func apply_pens_to_fixture(m):
	if pens == null:
		return
	var new_w = Game.home_id if pens.winner == 0 else Game.away_id
	var old_w = m.winner
	if new_w == old_w:
		return
	m.winner = new_w
	if Tournament.is_finished() and Tournament.champion == old_w:
		Tournament.champion = new_w
	for f in Tournament.fixtures:
		if f != m and f.round == m.round + 1 and not f.played:
			if f.home == old_w:
				f.home = new_w
			elif f.away == old_w:
				f.away = new_w


# ============================================================ Nigerian Set Match
# Winner stays on, loser joins the back of a FIFO queue, a draw sends both off
# (in the order they entered). Each win = 1 point. Every match uses 3 minutes
# of tournament time; a match that starts before time runs out is played fully.

func set_start(teams, humans, total_minutes, goals_to_win = 2):
	var two = set_two
	reset()
	randomize()
	set_active = true
	set_two = two
	saved_minutes = Game.match_minutes
	Game.match_minutes = SET_MATCH_MINUTES
	set_teams = teams.duplicate()
	set_humans = humans.duplicate()
	set_total = total_minutes
	set_goals_to_win = goals_to_win
	set_queue = teams.duplicate()
	var first = set_queue.pop_front()
	var second = set_queue.pop_front()
	set_pitch = [first, second]
	for id in teams:
		set_table[id] = {"p": 0, "w": 0, "d": 0, "l": 0, "gf": 0, "ga": 0, "tb": randf()}
	set_sim_until_human()


func set_human_match():
	return set_humans.has(set_pitch[0]) or set_humans.has(set_pitch[1])


# Simulates every match that involves no human team, up to the next human match
# (or the end of the tournament).
func set_sim_until_human():
	while not set_finished and not set_human_match():
		var h = set_pitch[0]
		var a = set_pitch[1]
		var sc = _set_sim_score()
		_set_apply(h, a, sc[0], sc[1])


# Simulated match with the Set Match rules: goals arrive at random (about 1.5 per
# team per 3 minutes) and the match stops as soon as a team reaches the goal
# target; if the time runs out first the score stands (level = draw).
func _set_sim_score():
	var hg = 0
	var ag = 0
	var t = 0.0
	while true:
		t += -log(max(randf(), 0.0001))   # about 1 goal per minute, either team
		if t > float(SET_MATCH_MINUTES):
			break
		if randf() < 0.5:
			hg += 1
		else:
			ag += 1
		if hg >= set_goals_to_win or ag >= set_goals_to_win:
			break
	return [hg, ag]


# Sets Game.* for the match now on the pitch. The human team is always "home"
# (so single-player controls work for either human); both humans => 2-player.
func set_prepare_match():
	Game.mode = Game.Mode.TOURNAMENT
	Game.match_minutes = SET_MATCH_MINUTES
	var a = set_pitch[0]
	var b = set_pitch[1]
	var home = a
	if set_humans.has(b) and (not set_humans.has(a) or b == set_humans[0]):
		home = b
	Game.home_id = home
	Game.away_id = b if home == a else a
	Game.two_player = set_humans.has(a) and set_humans.has(b)


# Called from Results after a human match.
func set_report(hid, aid, hg, ag):
	var ok = (hid == set_pitch[0] and aid == set_pitch[1]) or (hid == set_pitch[1] and aid == set_pitch[0])
	if not ok or set_finished:
		return {}
	return _set_apply(hid, aid, hg, ag)


func _set_apply(h, a, hg, ag):
	var th = set_table[h]
	var ta = set_table[a]
	th.p += 1
	ta.p += 1
	th.gf += hg
	th.ga += ag
	ta.gf += ag
	ta.ga += hg
	var first = set_pitch[0]
	var second = set_pitch[1]
	var winner = -1
	var loser = -1
	if hg > ag:
		winner = h
		loser = a
	elif ag > hg:
		winner = a
		loser = h
	if winner == -1:
		# draw: both off, in the order they entered; next two in the queue play
		th.d += 1
		ta.d += 1
		set_queue.append(first)
		set_queue.append(second)
		var n1 = set_queue.pop_front()
		var n2 = set_queue.pop_front()
		set_pitch = [n1, n2]
	else:
		var tw = set_table[winner]
		var tl = set_table[loser]
		tw.w += 1
		tl.l += 1
		set_queue.append(loser)
		var challenger = set_queue.pop_front()
		set_pitch = [winner, challenger]
	set_results.append({"home": h, "away": a, "hg": hg, "ag": ag, "winner": winner})
	set_clock += SET_MATCH_MINUTES
	if set_clock >= set_total:
		set_finished = true
	return {"winner": winner, "loser": loser, "draw": winner == -1}


# Most wins; ties broken by head-to-head wins among the tied teams, then overall
# goal difference, then goals scored.
func set_ranking():
	var groups = {}
	for id in set_teams:
		var w = set_table[id].w
		if not groups.has(w):
			groups[w] = []
		groups[w].append(id)
	var keys = groups.keys()
	keys.sort()
	keys.invert()
	var out = []
	for w in keys:
		var g = groups[w]
		if g.size() > 1:
			g = _set_break_tie(g)
		out = out + g
	return out


var _h2h = {}


func _set_break_tie(g):
	_h2h = {}
	for id in g:
		_h2h[id] = 0
	for r in set_results:
		if r.winner != -1 and _h2h.has(r.home) and _h2h.has(r.away):
			_h2h[r.winner] += 1
	var out = g.duplicate()
	out.sort_custom(self, "_set_tie_cmp")
	return out


func _set_tie_cmp(a, b):
	if _h2h[a] != _h2h[b]:
		return _h2h[a] > _h2h[b]
	var ta = set_table[a]
	var tb = set_table[b]
	var gda = ta.gf - ta.ga
	var gdb = tb.gf - tb.ga
	if gda != gdb:
		return gda > gdb
	if ta.gf != tb.gf:
		return ta.gf > tb.gf
	return ta.tb > tb.tb
