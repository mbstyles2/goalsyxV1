extends Reference
# MATCH RULES AND SET PIECES (one script, match.gd calls into it).
#
#  1. DETECTION   ball out of play (throw-in / corner / goal kick), goals (own goals, disallowed goals),
#                 offside, fouls from tackles (free kick or penalty), double touches, keeper handling
#  2. RESTARTS    kick-off, throw-in, goal kick, corner, direct free kick, indirect free kick, penalty:
#                 the ball is stopped, put on the right spot, the right team gets it, and every player
#                 walks to a legal place (walls, spread-out team-mates, attackers in the box, keepers home)
#  3. ENFORCEMENT nobody moves in before the kick, required distances are held, the clock stops while the
#                 ball is dead, play resumes only when the taker has kicked it, no repeated triggers
#  4. AI TAKERS   computer-controlled takers choose and play the right restart (throw, cross, shot, pass)
#
# Phases of a restart:  stoppage (referee's decision) -> arrange (players walk to their places)
#                       -> ready (the taker may kick) -> ball played = back to normal play
#
# Distances are in pitch pixels and match the markings drawn on the pitch (boxes, centre circle, spot).

const BOX_DEPTH = 300.0         # penalty area (as drawn)
const BOX_HALF = 250.0
const PEN_SPOT = 140.0
const CIRCLE_R = 75.0           # centre circle
const THROW_DIST = 55.0         # opponents this far from a throw-in
const CORNER_DIST = 90.0        # ... from a corner
const WALL_DIST = 90.0          # ... from a free kick (the wall stands exactly here)
const MIN_ARRANGE = 1.2         # least time players get to take their places
const ARRANGE_MAX = 3.8         # after this the taker may go regardless
const AI_DELAY = 1.1            # a computer taker waits this long once everyone is in place
const HUMAN_TIMEOUT = 8.0       # a human taker who takes too long gets the kick taken for him
const WALK_SPEED = 0.9          # fraction of AI speed while taking up positions

var m
var enabled = true

# ---- the current restart
var active = false              # the ball is dead and a restart is being set up / waited for
var kind = ""                   # kickoff throw_in goal_kick corner free_kick indirect penalty
var phase = ""                  # stoppage arrange ready
var team = 0                    # the team that takes it
var spot = Vector2.ZERO
var ball_pos = Vector2.ZERO
var ball_height = 0.0
var taker = null
var phase_t = 0.0
var stop_t = 0.8
var taking = false
var retry_t = 0.0
var targets = {}                # player -> where he must go
var arrived = {}
var fixed = {}                  # players whose place the layout must not move (the taker, the wall)
var indirect = false

# ---- what happened since the ball was last played
var in_play_t = 99.0
var fresh = false               # only the taker has played the ball since the restart
var fresh_taker = null
var fresh_kind = ""
var fresh_indirect = false
var last_kicker = null
var kicker_untouched = false
var grace_t = 0.0
var foul_cd = 0.0
var own_goal = false
var offside_set = {}
var offside_team = -1
var offside_line_a = 0.0
var yellow = {}


func _init(match_node):
	m = match_node


# ------------------------------------------------------------ geometry helpers

func _left():
	return m.PITCH.position.x


func _right():
	return m.PITCH.end.x


func _cy():
	return m.PITCH.position.y + m.PITCH.size.y * 0.5


func _cx():
	return m.PITCH.position.x + m.PITCH.size.x * 0.5


func _dir(t):
	return 1.0 if t == 0 else -1.0


func _pid(p):
	return p.team * 11 + p.slot


func _depth(x, t):
	return m._depth_of_x(x, t)


func _x_at_depth(depth, t):
	return (_left() + depth) if t == 0 else (_right() - depth)


func _attack_x(t):
	return _right() if t == 0 else _left()


func _gk_of(t):
	return m.players[t * 11]


func _fam(p):
	return m._role_traits_of(p)["fam"]


func _human_team(t):
	return t == 0 or Game.two_player


func _human_controlled(p):
	return p == m.sel[0] or (Game.two_player and p == m.sel[1])


func _in_box_of(def_team, pos):
	return _depth(pos.x, def_team) < BOX_DEPTH and abs(pos.y - _cy()) < BOX_HALF


func _penalty_spot(attacking_team):
	return Vector2(_attack_x(attacking_team) - _dir(attacking_team) * PEN_SPOT, _cy())


func _players_of(t, include_gk):
	var out = []
	for p in m.players:
		if p.team == t and (include_gk or not p.is_gk):
			out.append(p)
	return out


func _by_dist(a, b):
	return a.position.distance_to(spot) < b.position.distance_to(spot)


func _by_y(a, b):
	return a.home_pos.y < b.home_pos.y


func _by_goal_dist(a, b):
	var g = Vector2(_attack_x(team), _cy())
	return a.position.distance_to(g) < b.position.distance_to(g)


func _push_from(p, center, radius):
	var off = p.position - center
	if off.length() < 0.01:
		off = Vector2(_dir(1 - p.team), 0.0)
	p.position = m._inside(center + off.normalized() * radius)


# ------------------------------------------------------------ per-tick control (called by match.gd)

func clock_running():
	return not active


# true while a restart is being set up: match.gd then skips the ball's normal physics and contacts
func tick(delta):
	if not enabled:
		return false
	grace_t = max(0.0, grace_t - delta)
	foul_cd = max(0.0, foul_cd - delta)
	in_play_t += delta
	if not active:
		return false
	phase_t += delta
	if phase == "stoppage":
		if phase_t >= stop_t:
			_begin_arrange()
	elif phase == "arrange":
		var all_in = true
		for p in m.players:
			if not arrived.get(p, false):
				all_in = false
				break
		if (all_in and phase_t >= MIN_ARRANGE) or phase_t >= ARRANGE_MAX:
			phase = "ready"
			phase_t = 0.0
			retry_t = 0.0
	elif phase == "ready":
		_ready_step(delta)
	_hold_human_selection()
	_lock_ball()
	_enforce_zones()
	return active


# who steers a player while the ball is dead: the rules (everybody, except a human taker once all is ready)
func takes_over(p):
	if not active:
		return false
	if phase == "ready" and p == taker and _human_controlled(p):
		if kind == "throw_in" and not arrived.get(p, false):
			return true                                   # he walks to the touchline first, then the throw is his
		return false
	return true


func control_player(p, delta):
	p.is_tackling = false
	if phase == "stoppage":
		p.vel = Vector2.ZERO
		_face(p, ball_pos)
		return
	var tgt = targets.get(p, p.position)
	var off = tgt - p.position
	# once he is in his place he stays there: only a real shove (more than 14 px) sends him back, so nobody shuffles
	if off.length() > (14.0 if arrived.get(p, false) else 6.0):
		var spd = m.AI_SPEED * WALK_SPEED
		if p == taker:
			spd = m.AI_SPEED
		p.vel = m._steer(p, tgt, spd)
		if p.vel != Vector2.ZERO:
			p.facing = p.vel.normalized()
		m._move(p, delta)
	else:
		p.vel = Vector2.ZERO
		arrived[p] = true
		_face(p, ball_pos)
		if p == taker and kind == "throw_in":
			p.facing = Vector2(0.0, 1.0 if spot.y < _cy() else -1.0)         # a thrower faces the pitch
		elif p == taker:
			p.facing = _aim_dir()                                           # a taker stands behind the ball looking at where it is going
		m._move(p, delta)


func _face(p, pt):
	var to = pt - p.position
	if to.length() > 1.0:
		p.facing = to.normalized()


# a human taker stays the player you control
func _hold_human_selection():
	if taker != null and _human_team(team) and (not taker.is_gk or kind == "goal_kick") and m.sel[team] != taker:
		m._set_selected(team, taker)                     # (a goal kick: the keeper is the one you control)


# the dead ball stays exactly where the referee put it (a throw-in ball is held above the thrower's head)
func _lock_ball():
	var b = m.ball
	if kind == "throw_in" and taker != null and arrived.get(taker, false):
		ball_pos = taker.position
		ball_height = 26.0
	b.position = ball_pos
	b.vel = Vector2.ZERO
	b.vel_z = 0.0
	b.height_z = ball_height
	m.dribble_owner = null
	m.pass_t = 0.0
	m.pass_target = null


# ------------------------------------------------------------ restarts: setting them up

func start_restart(kind_, team_, spot_, stop, msg):
	active = true
	kind = kind_
	team = team_
	phase = "stoppage"
	phase_t = 0.0
	stop_t = stop
	taking = false
	indirect = (kind_ == "indirect")
	spot = m._inside(spot_) if kind_ != "kickoff" else spot_
	ball_pos = spot
	ball_height = 0.0
	fresh = false
	offside_set.clear()
	last_kicker = null
	kicker_untouched = false
	targets.clear()
	arrived.clear()
	# the game stops: nothing is flying, nobody is holding or sliding
	m.dribble_owner = null
	m.pass_t = 0.0
	m.pass_target = null
	m.ball.vel = Vector2.ZERO
	m.gk_hold_timer = [0.0, 0.0]
	m.gk_human = [false, false]
	m.gk_dive_t = [0.0, 0.0]
	m.gk_down_t = [0.0, 0.0]
	m.gk_shot_seen = [false, false]
	for p in m.players:
		p.vel = Vector2.ZERO
		p.is_tackling = false
		p.is_diving = false
	if m.kick_system != null:
		m.kick_system.pending.clear()
		m.kick_system.cancel(0)
		m.kick_system.cancel(1)
	taker = _choose_taker()
	if msg != "":
		m._show_msg(msg, stop + 0.7)


# the kick-off after a goal (or the start of the match): players are already in their own halves
func begin_kickoff(t):
	own_goal = false
	offside_set.clear()
	foul_cd = 0.0
	start_restart("kickoff", t, Vector2(_cx(), _cy()), 0.0, "")
	phase = "ready"
	phase_t = 0.0
	for p in m.players:
		targets[p] = p.position
		arrived[p] = true
	_hold_human_selection()


func _begin_arrange():
	phase = "arrange"
	phase_t = 0.0
	_assign_targets()
	if _human_team(team) and taker != null and (not taker.is_gk or kind == "goal_kick"):
		m._set_selected(team, taker)


func _end_restart():
	active = false
	phase = ""
	taking = false
	targets.clear()
	arrived.clear()
	grace_t = 0.8


func _choose_taker():
	if kind == "goal_kick":
		return _gk_of(team)
	var best = null
	var best_s = 1e9
	var goal = Vector2(_attack_x(team), _cy())
	var fk_zone = _fk_zone() if (kind == "free_kick" or kind == "indirect") else ""
	for p in _players_of(team, false):
		var s = p.position.distance_to(spot)
		var fam = _fam(p)
		if kind == "penalty" and (fam == "ST" or fam == "AM"):
			s -= 150.0
		elif kind == "corner" and fam == "WG":
			s -= 90.0
		elif fk_zone == "shot" or fk_zone == "box":
			if fam == "AM" or fam == "ST" or fam == "CM":
				s -= 110.0                                          # a shooter
		elif fk_zone == "cross":
			if fam == "WG" or fam == "AM" or fam == "CM":
				s -= 90.0                                           # a crosser
		if s < best_s:
			best_s = s
			best = p
	# a human keeps the player he was already controlling if he is close
	if kind != "penalty" and _human_team(team):
		var cur = m.sel[team]
		if cur != null and not cur.is_gk and cur.team == team and cur.position.distance_to(spot) < 160.0:
			best = cur
	return best


# ------------------------------------------------------------ restarts: where everybody stands

func _shape_pos(p):
	var t = p.home_pos + (spot - Vector2(_cx(), _cy())) * 0.5
	if p.is_gk:
		t = _gk_post(p.team)
	return m._inside(t)


func _gk_post(t):
	var x = (_left() + 26.0) if t == 0 else (_right() - 26.0)
	return Vector2(x, _cy() + clamp((spot.y - _cy()) * 0.12, -40.0, 40.0))


# a throw-in is taken from OUTSIDE the touchline, a step behind the line, where the ball went out
func _throw_stand():
	var P = m.PITCH
	var out = -1.0 if spot.y < _cy() else 1.0
	var line_y = P.position.y if out < 0.0 else P.end.y
	return Vector2(spot.x, line_y + out * 14.0)


func _assign_targets():
	targets.clear()
	arrived.clear()
	fixed.clear()
	for p in m.players:
		targets[p] = _shape_pos(p)
	if kind == "throw_in":
		_plan_throw_in()
	elif kind == "goal_kick":
		_plan_goal_kick()
	elif kind == "corner":
		_plan_corner()
	elif kind == "free_kick" or kind == "indirect":
		_plan_free_kick()
	elif kind == "penalty":
		_plan_penalty()
	if taker != null and kind != "throw_in" and kind != "goal_kick":
		if kind == "free_kick" or kind == "indirect" or kind == "penalty":
			targets[taker] = m._inside(spot - _aim_dir() * 24.0)          # behind the ball, on the line to where it is going
		else:
			targets[taker] = spot - Vector2(_dir(team) * 18.0, 0.0)        # a corner: beside the ball
	if taker != null and kind == "goal_kick":
		targets[taker] = spot - Vector2(_dir(team) * 20.0, 0.0)
	if taker != null and kind == "throw_in":
		targets[taker] = _throw_stand()
	_declutter()


func _plan_throw_in():
	var att = Vector2(_dir(team), 0.0)
	var inward = Vector2(0.0, 1.0 if spot.y < _cy() else -1.0)
	var opts = [spot + att * 110.0 + inward * 70.0, spot - att * 90.0 + inward * 100.0, spot + att * 30.0 + inward * 190.0]
	var mates = _players_of(team, false)
	mates.erase(taker)
	mates.sort_custom(self, "_by_dist")
	for i in range(min(3, mates.size())):
		targets[mates[i]] = m._inside(opts[i])
	# opponents mark the options, goal-side
	var opps = _players_of(1 - team, false)
	opps.sort_custom(self, "_by_dist")
	for i in range(min(3, opps.size())):
		targets[opps[i]] = m._inside(opts[i] + att * 30.0)


func _plan_goal_kick():
	var d = _dir(team)
	var cbs = []
	for p in _players_of(team, false):
		if _fam(p) == "CB":
			cbs.append(p)
	cbs.sort_custom(self, "_by_y")
	for i in range(cbs.size()):
		targets[cbs[i]] = Vector2(_x_at_depth(BOX_DEPTH + 30.0, team), _cy() + (i - (cbs.size() - 1) * 0.5) * 170.0)
	for p in _players_of(team, false):
		if _fam(p) != "CB":
			targets[p] = m._inside(p.home_pos + Vector2(d * 140.0, 0.0))
	# opponents wait outside the penalty area
	for o in _players_of(1 - team, false):
		var t = targets[o]
		if _depth(t.x, team) < BOX_DEPTH + 50.0:
			t.x = _x_at_depth(BOX_DEPTH + 70.0, team)
		targets[o] = m._inside(t)


func _fam_rank(p):
	var order = ["ST", "AM", "WG", "CM", "CB", "FB", "DM"]
	var i = order.find(_fam(p))
	return i if i >= 0 else 9


# ------------------------------------------------------------ set pieces: the pictures
# Every layout is written for the attacking goal at depth 0; `_pt(depth, lateral)` is a point `depth` px in front
# of it and `lateral` px from its middle. `s` is +1 / -1 for the side of the pitch the ball is on, so a left-hand
# and a right-hand set piece are the same picture mirrored.

func _pt(depth, lateral):
	return Vector2(_attack_x(team) - _dir(team) * depth, _cy() + lateral)


func _side():
	return 1.0 if spot.y >= _cy() else -1.0


func _goal_c():
	return Vector2(_attack_x(team), _cy())


# the way the taker faces: where the ball is going
func _aim_dir():
	var to = _goal_c() - spot
	if kind == "corner":
		to = _pt(150.0, 0.0) - spot
	elif kind == "kickoff" or kind == "goal_kick":
		to = Vector2(_dir(team), 0.0)
	return to.normalized() if to.length() > 1.0 else Vector2(_dir(team), 0.0)


func _put(p, pos):
	targets[p] = m._inside(pos)


# takes the n players of `pool` nearest to pos out of it and returns them
func _take_nearest(pool, pos, n):
	var out = []
	for k in range(n):
		if pool.empty():
			break
		var best = 0
		var bd = 1e9
		for i in range(pool.size()):
			var dd = pool[i].position.distance_to(pos)
			if dd < bd:
				bd = dd
				best = i
		out.append(pool[best])
		pool.remove(best)
	return out


# the most attacking players first
func _ranked(list):
	var r = []
	for p in list:
		r.append([_fam_rank(p), p])
	r.sort_custom(self, "_cmp_first")
	var out = []
	for e in r:
		out.append(e[1])
	return out


func _cmp_first(a, b):
	return a[0] < b[0]


# defenders sorted by distance to the goal that is being attacked
func _by_goal_dist_def(a, b):
	var g = Vector2(_attack_x(team), _cy())
	return a.position.distance_to(g) < b.position.distance_to(g)


# After the layout: nobody stands on anybody (they are pushed apart further than the game pushes players, so
# nobody has to be shoved back in place later) and the other side keeps its distance from the ball.
func _declutter():
	var gap = 32.0
	if taker != null:
		fixed[taker] = true
	for pass_i in range(8):
		for i in range(m.players.size()):
			for j in range(i + 1, m.players.size()):
				var a = m.players[i]
				var b = m.players[j]
				var fa = fixed.has(a)
				var fb = fixed.has(b)
				if fa and fb:
					continue
				var off = targets[a] - targets[b]
				var dist = off.length()
				if dist >= gap:
					continue
				if dist < 0.5:
					off = Vector2(0.0, 1.0 if a.slot % 2 == 0 else -1.0)
					dist = 0.5
				var push = off / dist * (gap - dist)
				if fa:
					targets[b] -= push
				elif fb:
					targets[a] += push
				else:
					targets[a] += push * 0.5
					targets[b] -= push * 0.5
	var keep = 0.0
	if kind == "free_kick" or kind == "indirect":
		keep = WALL_DIST - 2.0                       # (the game pushes anybody under WALL_DIST - 4, so a target here is never shoved)
	elif kind == "corner":
		keep = CORNER_DIST + 2.0
	for p in m.players:
		if not fixed.has(p):
			targets[p] = m._inside(targets[p])
		if keep > 0.0 and p.team != team:
			var t = targets[p]
			if abs(t.x - _attack_x(team)) < 30.0 and kind != "corner":
				continue                                   # on his goal line, where the laws let him stand
			var off2 = t - spot
			if off2.length() < keep:
				if off2.length() < 0.5:
					off2 = Vector2(_dir(team), 0.0)
				targets[p] = m._inside(spot + off2.normalized() * keep)


# ------------------------------------------------------------ the corner kick

func _plan_corner():
	var d = _dir(team)
	var s = _side()
	var cy = _cy()
	var mates = _players_of(team, false)
	mates.erase(taker)
	var ranked = _ranked(mates)
	# the attackers: near post, six-yard box, penalty spot, far post, back post, top of the box   (depth, lateral)
	var slots = [Vector2(55.0, 62.0 * s), Vector2(75.0, -8.0 * s), Vector2(150.0, 20.0 * s),
			Vector2(80.0, -100.0 * s), Vector2(150.0, -85.0 * s), Vector2(300.0, 70.0 * s)]
	var n_box = min(slots.size(), ranked.size())
	for i in range(n_box):
		_put(ranked[i], _pt(slots[i].x, slots[i].y))
	# the others: one offers a short corner, the rest stay back for the counter
	var rest = []
	for i in range(n_box, ranked.size()):
		rest.append(ranked[i])
	if not rest.empty():
		_put(rest[0], spot + Vector2(-d * 115.0, -s * 28.0))
	var back = rest.size() - 1
	for i in range(1, rest.size()):
		_put(rest[i], Vector2(_cx() - d * 140.0, cy + (float(i - 1) - (back - 1) * 0.5) * 220.0))
	# the defence: keeper, two men on the posts, a man off the near post against the short corner, the rest mark
	var def_gk = _gk_of(1 - team)
	_put(def_gk, _pt(10.0, 20.0 * s))
	var pool = _players_of(1 - team, false)
	pool.sort_custom(self, "_by_goal_dist_def")
	if not pool.empty():
		_put(pool.pop_front(), _pt(16.0, 92.0 * s))
	if not pool.empty():
		_put(pool.pop_front(), _pt(16.0, -92.0 * s))
	var guard = _take_nearest(pool, spot + Vector2(0.0, -s * 95.0), 1)
	for g in guard:
		_put(g, spot + Vector2(0.0, -s * 95.0))
	for i in range(n_box):
		var mk = _take_nearest(pool, _pt(slots[i].x, slots[i].y), 1)
		for q in mk:
			_put(q, _pt(max(slots[i].x - 28.0, 20.0), slots[i].y))                # goal-side of his man
	for i in range(pool.size()):
		_put(pool[i], Vector2(_cx() - _dir(team) * 160.0, cy + (float(i) - (pool.size() - 1) * 0.5) * 220.0))   # up for the counter


# ------------------------------------------------------------ free kicks (direct and indirect)

# which picture: shot (a wall), box (indirect inside the area), cross (wide, in the final third), mid, deep (our own third)
func _fk_zone():
	var goal = _goal_c()
	var dx = abs(goal.x - spot.x)
	var dy = abs(spot.y - _cy())
	if indirect and _in_box_of(1 - team, spot) and dx < 300.0:
		return "box"
	if spot.distance_to(goal) < 620.0 and dy < 340.0:
		return "shot"
	if dx < 1000.0:
		return "cross"
	if dx < 1600.0:
		return "mid"
	return "deep"


func _plan_free_kick():
	var s = _side()
	var zone = _fk_zone()
	var toward = (_goal_c() - spot).normalized()
	var perp = Vector2(-toward.y, toward.x)
	var mates = _players_of(team, false)
	mates.erase(taker)
	mates.sort_custom(self, "_by_dist")
	var opps = _players_of(1 - team, false)
	opps.sort_custom(self, "_by_dist")
	if zone == "box":
		_fk_box(mates, opps, perp)
	elif zone == "shot":
		_fk_shot(mates, opps, s, toward, perp)
	elif zone == "cross":
		_fk_cross(mates, opps, s)
	elif zone == "mid":
		_fk_mid(mates, opps, s)
	else:
		_fk_deep(mates, opps, s)


# a free kick in shooting range: a wall on the line to the near post, the keeper on the far side, a second man over
# the ball, three attackers for the rebound with a marker each, two defenders holding the edge of the box
func _fk_shot(mates, opps, s, toward, perp):
	var d = _dir(team)
	var goal = _goal_c()
	var dist = spot.distance_to(goal)
	var dy = spot.y - _cy()
	var n = 5 if dist < 420.0 else (4 if dist < 500.0 else (3 if dist < 570.0 else 2))
	if abs(dy) > 250.0:
		n -= 1                                                     # from a wide angle the wall is smaller
	if indirect:
		n += 1                                                     # somebody has to touch it first: a bigger wall
	n = int(clamp(n, 1, 6))
	var aim = goal + Vector2(0.0, clamp(dy * 0.15, -40.0, 40.0))   # the wall covers the near post
	var wdir = (aim - spot).normalized()
	var wall_c = spot + wdir * WALL_DIST
	var wperp = Vector2(-wdir.y, wdir.x)
	var pool = opps.duplicate()
	var wall = _take_nearest(pool, wall_c, n)
	for i in range(wall.size()):
		_put(wall[i], wall_c + wperp * ((float(i) - (wall.size() - 1) * 0.5) * 28.0))    # shoulder to shoulder
		fixed[wall[i]] = true
	var far = -s if abs(dy) > 30.0 else 0.0
	_put(_gk_of(1 - team), Vector2(goal.x - d * 22.0, _cy() + far * 38.0))            # the far side of the goal
	var ranked = _ranked(mates)
	if not ranked.empty():
		var decoy = ranked.pop_front()                              # a second man over the ball
		_put(decoy, spot + Vector2(0.0, -s * 40.0))
		fixed[decoy] = true
	var slots = [Vector2(110.0, -75.0 * s), Vector2(165.0, 45.0 * s), Vector2(230.0, -170.0 * s)]
	for i in range(min(slots.size(), ranked.size())):
		_put(ranked[i], _pt(slots[i].x, slots[i].y))
		var mk = _take_nearest(pool, _pt(slots[i].x, slots[i].y), 1)
		for q in mk:
			_put(q, _pt(slots[i].x - 28.0, slots[i].y))
	var edge = _take_nearest(pool, _pt(330.0, 0.0), 2)
	for i in range(edge.size()):
		_put(edge[i], _pt(330.0, (-110.0 if i == 0 else 110.0)))


# an indirect free kick inside the area: the defenders on their goal line, the keeper in the middle, two attackers
# over the ball (one touches it, one shoots), the others waiting on the edge of the box
func _fk_box(mates, opps, perp):
	var d = _dir(team)
	var goal = _goal_c()
	var lat = [34.0, -34.0, 68.0, -68.0, 102.0, -102.0]
	var pool = opps.duplicate()
	var line = _take_nearest(pool, goal, 6)
	_put(_gk_of(1 - team), Vector2(goal.x - d * 14.0, _cy()))
	for i in range(line.size()):
		targets[line[i]] = Vector2(goal.x - d * 14.0, _cy() + lat[i])          # on the line, where the laws let them stand
		fixed[line[i]] = true
	var ranked = _ranked(mates)
	if not ranked.empty():
		var shooter = ranked.pop_front()
		_put(shooter, spot + perp * 42.0)
		fixed[shooter] = true
	var arc = [-190.0, -65.0, 65.0, 190.0]
	for i in range(min(arc.size(), ranked.size())):
		_put(ranked[i], _pt(340.0, arc[i]))
	for i in range(min(3, pool.size())):
		_put(pool[i], _pt(250.0, (float(i) - 1.0) * 120.0))


# a free kick wide, in the final third: no wall, five attackers running into the box with a marker each, the
# rest of the defence on a line at the edge of the box, one player short for a pass
func _fk_cross(mates, opps, s):
	var d = _dir(team)
	var goal = _goal_c()
	var ranked = _ranked(mates)
	var slots = [Vector2(70.0, 45.0 * s), Vector2(95.0, -65.0 * s), Vector2(150.0, 5.0 * s),
			Vector2(195.0, -115.0 * s), Vector2(250.0, 85.0 * s)]
	if not ranked.empty():
		var short_p = ranked.pop_back()
		_put(short_p, spot + Vector2(-d * 70.0, -s * 60.0))
	var pool = opps.duplicate()
	_put(_gk_of(1 - team), Vector2(goal.x - d * 45.0, _cy() + s * 28.0))      # a little off his line: he will come for the cross
	for i in range(min(slots.size(), ranked.size())):
		_put(ranked[i], _pt(slots[i].x, slots[i].y))
		if i < 4:
			var mk = _take_nearest(pool, _pt(slots[i].x, slots[i].y), 1)
			for q in mk:
				_put(q, _pt(slots[i].x - 28.0, slots[i].y))
	var line = _take_nearest(pool, _pt(280.0, 0.0), 3)
	for i in range(line.size()):
		_put(line[i], _pt(280.0, (float(i) - 1.0) * 130.0))


# a free kick in the middle third: the team pushes up and offers three short options, two defenders close them
func _fk_mid(mates, opps, s):
	var d = _dir(team)
	var opts = [spot + Vector2(d * 150.0, -s * 170.0), spot + Vector2(d * 270.0, s * 140.0), spot + Vector2(-d * 90.0, -s * 140.0)]
	var pool = mates.duplicate()
	for o in opts:
		for q in _take_nearest(pool, o, 1):
			_put(q, o)
	var op = opps.duplicate()
	for i in range(2):
		for q in _take_nearest(op, opts[i], 1):
			_put(q, opts[i] + Vector2(d * 34.0, 0.0))                           # goal-side of the man he picks up


# a free kick deep in the taker's own third: the build-up. Two centre-backs level with the ball either side,
# the full-backs high and wide on the touchlines, a midfield diamond ahead, the forwards stay up; the other
# side's front players come to press from a respectful distance.
func _fk_deep(mates, opps, s):
	var d = _dir(team)
	var P = m.PITCH
	var cbs = []
	var fbs = []
	var dms = []
	var cms = []
	for p in mates:
		var f = _fam(p)
		if f == "CB":
			cbs.append(p)
		elif f == "FB":
			fbs.append(p)
		elif f == "DM":
			dms.append(p)
		elif f == "CM" or f == "AM":
			cms.append(p)
	for i in range(min(2, cbs.size())):
		_put(cbs[i], Vector2(spot.x - d * 10.0, spot.y + (210.0 if i == 0 else -210.0)))
	for p in fbs:
		var top = p.home_pos.y < _cy()
		_put(p, Vector2(spot.x + d * 260.0, (P.position.y + 110.0) if top else (P.end.y - 110.0)))
	if not dms.empty():
		_put(dms[0], Vector2(spot.x + d * 330.0, (spot.y + _cy()) * 0.5))
	for i in range(cms.size()):
		_put(cms[i], Vector2(spot.x + d * (520.0 + 90.0 * float(i)), spot.y + (170.0 if i % 2 == 0 else -170.0)))
	var press = []
	for p in opps:
		var f2 = _fam(p)
		if f2 == "ST" or f2 == "AM" or f2 == "WG":
			press.append(p)
	for i in range(min(2, press.size())):
		_put(press[i], spot + Vector2(d * (WALL_DIST + 30.0), (130.0 if i == 0 else -130.0)))


func _plan_penalty():
	var d = _dir(team)
	var gxa = _attack_x(team)
	var cy = _cy()
	targets[_gk_of(1 - team)] = Vector2(gxa - d * 12.0, cy)
	var others = []
	for p in m.players:
		if p == taker or (p.is_gk and p.team != team):
			continue
		others.append(p)
	# everybody else waits outside the box, attackers in a row, defenders in a row behind them
	var atk = []
	var dfn = []
	for p in others:
		if p.team == team:
			atk.append(p)
		else:
			dfn.append(p)
	for i in range(atk.size()):
		targets[atk[i]] = m._inside(Vector2(gxa - d * (BOX_DEPTH + 50.0), cy + (i - (atk.size() - 1) * 0.5) * 46.0))
	for i in range(dfn.size()):
		targets[dfn[i]] = m._inside(Vector2(gxa - d * (BOX_DEPTH + 100.0), cy + (i - (dfn.size() - 1) * 0.5) * 42.0))


# ------------------------------------------------------------ restarts: holding the rules while the ball is dead

func _enforce_zones():
	var cx = _cx()
	for p in m.players:
		if p == taker:
			continue
		var pos = p.position
		if kind == "throw_in":
			if p.team != team and pos.distance_to(spot) < THROW_DIST:
				_push_from(p, spot, THROW_DIST)
		elif kind == "corner":
			if p.team != team and pos.distance_to(spot) < CORNER_DIST:
				_push_from(p, spot, CORNER_DIST)
		elif kind == "free_kick" or kind == "indirect":
			if p.team != team and pos.distance_to(spot) < WALL_DIST - 4.0 and abs(pos.x - _attack_x(team)) > 30.0:
				_push_from(p, spot, WALL_DIST)                       # (the laws let defenders stand on their goal line)
		elif kind == "goal_kick":
			if p.team != team and _in_box_of(team, pos):
				p.position = m._inside(Vector2(_x_at_depth(BOX_DEPTH + 12.0, team), pos.y))
		elif kind == "penalty":
			var keeper = p.is_gk and p.team != team
			if not keeper:
				var d_def = 1 - team
				if _in_box_of(d_def, pos) or pos.distance_to(spot) < CIRCLE_R:
					p.position = m._inside(Vector2(_x_at_depth(BOX_DEPTH + 14.0, d_def), pos.y))
		elif kind == "kickoff":
			if p.team == 0 and pos.x > cx - 2.0:
				p.position.x = cx - 2.0
			elif p.team == 1 and pos.x < cx + 2.0:
				p.position.x = cx + 2.0
			if p.team != team and pos.distance_to(Vector2(cx, _cy())) < CIRCLE_R:
				_push_from(p, Vector2(cx, _cy()), CIRCLE_R)
				if p.team == 0:
					p.position.x = min(p.position.x, cx - 2.0)
				else:
					p.position.x = max(p.position.x, cx + 2.0)


# ------------------------------------------------------------ restarts: the kick

func _ready_step(delta):
	if taker == null:
		_force_take()
		return
	var human = _human_team(team) and _human_controlled(taker)
	var limit = HUMAN_TIMEOUT if human else AI_DELAY
	if taking:
		retry_t -= delta
		if retry_t <= 0.0:
			taking = false
		if phase_t > limit + 6.0:
			_force_take()
		return
	if phase_t >= limit:
		_ai_take()


# a computer taker (or a human who took too long) plays the right kind of restart
func _ai_take():
	var brain = m.kick_system.brain
	var tk = taker
	if tk.position.distance_to(ball_pos) > 40.0 and kind != "throw_in":
		tk.position = m._inside(ball_pos - Vector2(_dir(team) * 16.0, 0.0))        # (a late human is put back at the ball)
	taking = true
	retry_t = 0.5
	var ok = false
	var goal = Vector2(_attack_x(team), _cy())
	if kind == "penalty":
		ok = m.kick_system.ai_shoot(tk, Vector2(goal.x, _cy() + rand_range(-70.0, 70.0)), 700.0)
	elif kind == "corner":
		var ranked = brain.rank_mates(tk, "cross", Vector2.ZERO)
		if not ranked.empty():
			var r = ranked[0]
			var plan = brain.make_pass_plan(tk, "cross", 0.65, r["lead"], r["mate"], r["risk"], true)
			plan["record"] = false
			ok = m.kick_system.schedule_plan(tk, plan, false)
		else:
			ok = m.kick_system.ai_clear(tk, Vector2(goal.x - _dir(team) * 150.0, _cy()))
	elif kind == "free_kick" and spot.distance_to(goal) < 480.0 and randf() < 0.75:
		var shot = m._evaluate_shot(tk, goal)
		ok = m.kick_system.ai_shoot(tk, shot["target"], 650.0)
	else:
		var ranked2 = brain.rank_mates(tk, "pass", Vector2.ZERO)
		if kind == "goal_kick":
			ranked2 = brain.rank_mates(tk, "pass", Vector2.ZERO)
		if not ranked2.empty():
			ok = m.kick_system.ai_pass(tk, ranked2[0]["mate"], 0.15, 0.0, 0.0)
		else:
			ok = m.kick_system.ai_clear(tk, Vector2(tk.position.x + _dir(team) * 400.0, _cy()))
	if not ok:
		taking = false
		retry_t = 0.0


# last resort so a restart can never hang: the taker just plays the ball forward
func _force_take():
	if taker == null:
		taker = _choose_taker()
	var dirv = Vector2(_dir(team), 0.0)
	m._kick_apply(taker, dirv, 280.0, 0.0, true)
	on_ball_played(taker)


# the kick has been made (called by match._kick_apply for every kick)
func on_ball_played(p):
	if not enabled:
		return
	var restart_kick = active and p == taker
	offside_set.clear()
	var no_offside = restart_kick and (kind == "throw_in" or kind == "goal_kick" or kind == "corner")
	if not no_offside:
		_snapshot_offside(p)
	last_kicker = p
	kicker_untouched = true
	in_play_t = 0.0
	if restart_kick:
		fresh = true
		fresh_taker = p
		fresh_kind = kind
		fresh_indirect = indirect
		_end_restart()
	else:
		fresh = false


# a throw-in is a throw: the plan the kick system made is slowed down and given a throw's flight
func adjust_plan(p, plan):
	if not enabled or not active:
		return true
	if p != taker or phase != "ready":
		return false                                  # nobody else may play the ball, and not before all is ready
	if kind == "throw_in":
		plan["anim"] = "throw"
		plan["speed"] = min(plan["speed"], 300.0)
		plan["lift"] = max(plan["lift"], 45.0)
		plan["curve"] = 0.0
		plan["is_shot"] = false
		plan["delay"] = 0.14
	return true


# ------------------------------------------------------------ detection: the ball leaves the pitch or goes in

# replaces the old "bounce off the walls": decides what happens when the ball goes out or into a goal
func check_ball(_delta):
	if not enabled or active or m.state != "playing":
		return
	var P = m.PITCH
	var br = m.BR
	var b = m.ball.position
	var cy = _cy()
	if b.y < P.position.y - br or b.y > P.end.y + br:
		_out_touchline(b)
	elif b.x < P.position.x - br or b.x > P.end.x + br:
		_out_goal_line(b)


func _out_touchline(b):
	var P = m.PITCH
	var last = m.last_touch
	var t = (1 - last.team) if last != null else (1 if b.x < _cx() else 0)
	var sp = Vector2(clamp(b.x, P.position.x + 40.0, P.end.x - 40.0), P.position.y + 6.0 if b.y < _cy() else P.end.y - 6.0)
	start_restart("throw_in", t, sp, 0.7, "THROW-IN")


func _out_goal_line(b):
	var P = m.PITCH
	var left_side = b.x < P.position.x
	var cy = _cy()
	var in_mouth = abs(b.y - cy) < m.GOAL_H * 0.5 - 4.0 and m.ball.height_z <= m.CROSSBAR_Z
	var def_team = 0 if left_side else 1
	if in_mouth:
		m._goal(1 - def_team)                          # a goal (validate_goal decides if it counts)
		return
	var last = m.last_touch
	var touch_team = last.team if last != null else def_team
	if touch_team == def_team:
		var cx = (P.position.x + 8.0) if left_side else (P.end.x - 8.0)
		var cyy = (P.position.y + 8.0) if b.y < cy else (P.end.y - 8.0)
		start_restart("corner", 1 - def_team, Vector2(cx, cyy), 0.7, "CORNER KICK")
	else:
		var gx = (P.position.x + 90.0) if left_side else (P.end.x - 90.0)
		start_restart("goal_kick", def_team, Vector2(gx, cy + (60.0 if b.y > cy else -60.0)), 0.7, "GOAL KICK")


# called first thing in match._goal(scorer): does this goal count?
func validate_goal(scorer):
	if not enabled:
		return true
	own_goal = false
	var def_team = 1 - scorer
	var kicker_team = last_kicker.team if last_kicker != null else -1
	# nothing counts straight from an indirect free kick, or from a throw-in, before another player touches it
	if fresh and fresh_kind == "throw_in" and in_play_t < 4.0 and kicker_team == scorer:
		start_restart("goal_kick", def_team, _goal_kick_spot(def_team), 1.0, "NO GOAL - GOAL KICK")
		return false
	if fresh and fresh_indirect and in_play_t < 4.0 and kicker_team == scorer:
		start_restart("goal_kick", def_team, _goal_kick_spot(def_team), 1.0, "NO GOAL - INDIRECT FREE KICK")
		return false
	# thrown, kicked or free-kicked straight into your own goal: a corner to the other side
	if fresh and in_play_t < 4.0 and kicker_team == def_team and fresh_kind != "kickoff":
		var P = m.PITCH
		var cxx = (P.end.x - 8.0) if def_team == 1 else (P.position.x + 8.0)
		start_restart("corner", scorer, Vector2(cxx, P.position.y + 8.0 if randf() < 0.5 else P.end.y - 8.0), 1.0, "OWN GOAL DISALLOWED - CORNER")
		return false
	if m.last_touch != null and m.last_touch.team == def_team:
		own_goal = true
	return true


func _goal_kick_spot(def_team):
	var P = m.PITCH
	var gx = (P.position.x + 90.0) if def_team == 0 else (P.end.x - 90.0)
	return Vector2(gx, _cy() + 60.0)


func goal_prefix():
	return "OWN GOAL!" if own_goal else "GOAL!"


# ------------------------------------------------------------ detection: contact with the ball

# called whenever a player touches the ball in open play; true = play was stopped
func on_touch(p):
	if not enabled or active:
		return false
	if offside_set.has(_pid(p)) and p.team == offside_team:
		_call_offside(p)
		return true
	offside_set.clear()                                # any other touch wipes the offside reference
	if fresh and in_play_t > 0.2:
		if p == fresh_taker and in_play_t < 3.0:
			fresh = false
			start_restart("indirect", 1 - p.team, p.position, 1.2, "DOUBLE TOUCH - INDIRECT FREE KICK")
			return true
		elif p != fresh_taker:
			fresh = false
	if p != last_kicker:
		kicker_untouched = false
	return false


# the keeper may not pick the ball up when a team-mate has just kicked or thrown it to him
func gk_may_handle(gk):
	if not enabled:
		return true
	if last_kicker != null and kicker_untouched and last_kicker.team == gk.team and not last_kicker.is_gk:
		return false
	return true


# ------------------------------------------------------------ detection: offside

# attack-axis position of the opponents' second-last man (the keeper counts)
func second_last_a(t):
	var vals = []
	for o in m.players:
		if o.team != t:
			vals.append(_depth(o.position.x, t))
	vals.sort()
	if vals.size() < 2:
		return m.PITCH.size.x
	return vals[vals.size() - 2]


# is q in an offside position at the moment p plays the ball?
func is_offside_position(p, q):
	var qa = _depth(q.position.x, q.team)
	if qa <= m.PITCH.size.x * 0.5:
		return false                                   # his own half
	if qa <= _depth(p.position.x, p.team) + 3.0:
		return false                                   # level with or behind the ball
	return qa > second_last_a(q.team) + 3.0


func _snapshot_offside(kicker):
	offside_set.clear()
	offside_team = kicker.team
	offside_line_a = second_last_a(kicker.team)
	for q in m.players:
		if q.team == kicker.team and q != kicker and not q.is_gk and is_offside_position(kicker, q):
			offside_set[_pid(q)] = true


func _call_offside(p):
	offside_set.clear()
	var t = 1 - p.team
	# show the offside line for a moment (match.gd / camera.gd draw it)
	m.offside_line_x = _x_at_depth(offside_line_a, p.team)
	m.offside_timer = 2.5
	m.update()
	if m.ui_controller:
		m.ui_controller.record_offside(p.team)
	start_restart("indirect", t, p.position, 1.5, "OFFSIDE")


# keep waiting attackers level with the last defender instead of drifting offside (used by the AI)
func clamp_onside(t, pt):
	if not enabled:
		return pt
	var a = _depth(pt.x, t)
	var limit = max(second_last_a(t) - 8.0, _depth(m.ball.position.x, t))
	if a > limit and a > m.PITCH.size.x * 0.5:
		pt.x = _x_at_depth(limit, t)
	return pt


# ------------------------------------------------------------ detection: fouls

# a tackle on the ball carrier: returns true if the referee blows for a foul
func on_tackle(tackler, holder, won):
	if not enabled or active or holder == null or foul_cd > 0.0 or m.state != "playing":
		return false
	var to_tackler = tackler.position - holder.position
	var behind = 0.0
	if to_tackler.length() > 1.0 and holder.facing.length() > 0.1:
		behind = clamp(-holder.facing.normalized().dot(to_tackler.normalized()), 0.0, 1.0)
	var slide = 1.0 if tackler.is_tackling else 0.3
	var p_foul = 0.05 + 0.10 * behind * slide
	if not won:
		p_foul = 0.30 + 0.45 * behind + 0.15 * (1.0 if tackler.is_tackling else 0.0)
	if _human_controlled(tackler):
		p_foul *= 0.8                                  # a touch more forgiving for the player
	if randf() >= clamp(p_foul, 0.0, 0.95):
		return false
	_call_foul(tackler, holder, clamp(0.3 + 0.6 * behind + 0.2 * slide, 0.0, 1.0))
	return true


func _call_foul(tackler, victim, severity):
	foul_cd = 1.2
	var t = victim.team
	var sp = m._inside(victim.position)
	if m.ui_controller:
		m.ui_controller.record_foul(tackler.team)
	var card = ""
	if severity > 0.78:
		yellow[_pid(tackler)] = yellow.get(_pid(tackler), 0) + 1
		card = "  -  YELLOW CARD"
	if _in_box_of(tackler.team, sp):
		start_restart("penalty", t, _penalty_spot(t), 1.4, "FOUL - PENALTY!" + card)
	else:
		start_restart("free_kick", t, sp, 1.2, "FOUL - FREE KICK" + card)
