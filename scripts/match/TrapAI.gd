extends Reference
# TrapAI - the offside trap and the pressing triggers.
#
# OFFSIDE TRAP (the team without the ball)
#   When an opponent carrier is in the middle of the pitch, well in front of our back line, with an attacker level
#   with that line or just in front of it, the back line (centre-backs and the full-backs standing level with them)
#   may STEP UP together: they move up about 90-150 px, fast, for 0.9 s, so an attacker who stays put is suddenly
#   offside when the pass is played. Three things set it off, in this order of strength:
#     - the carrier has wound up a pass (his kick is pending), then it happens with the team's `trap` chance,
#     - the carrier is standing still / slow, head up, and nobody is on him (a few chances a second),
#   and a cool-down of 4.5 s keeps it from becoming a habit. The tactic's `trap` (0 = never, deep blocks ... 1 = always)
#   says how keen a team is. Attackers (AttackAI) read the line coming up: most of the computer's attackers hold
#   back when it starts; a few do not, and they are caught. You have to watch the line yourself.
#
# PRESS TRIGGERS (the team without the ball)
#   A moment when pressing pays off: the opponent has just played a pass BACK, taken a heavy / poor first touch,
#   has his back to the play with one of ours on him, or is in a touchline trap. A trigger lasts 0.5-2.2 s: one more
#   man presses, the presser's zone is wider, and everybody closes down 12% faster. (match.gd reads press_active().)

const TacticSystem = preload("res://scripts/match/tactic.gd")

const STEP_BASE = 90.0
const STEP_MAX = 150.0
const TRAP_TIME = 0.9
const TRAP_COOLDOWN = 4.5


# called once per tick from match._update_team_states
static func tick(m, delta):
	for t in range(2):
		_trap_check(m, t, delta)
		_trigger_check(m, t)


static func trap_active(m, t):
	return m.trap_until[t] > m.ai_clock


static func press_active(m, t):
	return m.press_trig_until[t] > m.ai_clock


static func line_member(m, p):
	var f = m._role_traits_of(p)["fam"]
	return f == "CB" or f == "FB"


# does this attacker read the trap? (the same ones every time: about 7 in 10)
static func reads_trap(m, p):
	return (abs(int(hash(p.team * 53 + int(p.slot) * 7)) % 100)) < 72


# a pass has been wound up by somebody of this team (his kick is pending)
static func pass_wound_up(m, team):
	for q in m.kick_system.pending.keys():
		if is_instance_valid(q) and q.team == team:
			var plan = m.kick_system.pending[q]["plan"]
			if plan.get("mate") != null and not plan.get("is_shot", false):
				return true
	return false


static func note_press_trigger(m, t, kind, secs):
	m.press_trig_until[t] = max(m.press_trig_until[t], m.ai_clock + secs)
	m.press_trig_kind[t] = kind


# ------------------------------------------------------------------ the trap

static func _trap_check(m, t, delta):
	if m.ai_clock < m.trap_cd[t] or trap_active(m, t):
		return
	var tendency = float(m.profiles[t]["tac"].get("trap", 0.4))
	if tendency <= 0.0:
		return
	var c = m.dribble_owner
	if c == null or not is_instance_valid(c) or c.team == t or c.is_gk:
		return
	var L = m.PITCH.size.x
	var bd = m._depth_of_x(c.position.x, t)                   # how far the ball is from OUR goal
	if bd < L * 0.30 or bd > L * 0.72:
		return
	var line = 0.0
	var n = 0
	for q in m.players:
		if q.team == t and not q.is_gk and line_member(m, q):
			line += m._depth_of_x(q.position.x, t)
			n += 1
	if n < 3:
		return
	line /= float(n)
	if bd - line < 260.0:
		return                                                  # the ball is too close to the line to step up
	var runner = false
	for q in m.players:
		if q.team != t and not q.is_gk and q != c:
			var qd = m._depth_of_x(q.position.x, t)
			if qd > line - 50.0 and qd < line + 340.0:
				runner = true
				break
	if not runner:
		return
	var go = false
	if pass_wound_up(m, c.team):
		go = randf() < tendency
	elif c.vel.length() < 90.0 and m.pressers_of[t].empty():
		go = randf() < tendency * 0.9 * delta                   # he is on the ball, head up, nobody on him: a few chances a second
	if go:
		m.trap_until[t] = m.ai_clock + TRAP_TIME
		m.trap_cd[t] = m.ai_clock + TRAP_COOLDOWN
		m.trap_step[t] = clamp(STEP_BASE + 60.0 * tendency, STEP_BASE, STEP_MAX)


# ------------------------------------------------------------------ the press triggers (the ones seen on the ball)

static func _trigger_check(m, t):
	var c = m.dribble_owner
	if c == null or not is_instance_valid(c) or c.team == t or c.is_gk:
		return
	var near_one = false
	var nearest = 1e9
	for q in m.players:
		if q.team == t and not q.is_gk:
			nearest = min(nearest, q.position.distance_to(c.position))
	near_one = nearest < 170.0
	var P = m.PITCH
	var edge = min(abs(c.position.y - P.position.y), abs(P.end.y - c.position.y))
	if edge < 150.0 and near_one:
		note_press_trigger(m, t, "sideline", 0.5)               # a touchline trap: he has nowhere to go
	if nearest < 120.0 and c.facing.x * m._dir_of(c.team) < -0.4:
		note_press_trigger(m, t, "turned", 0.6)                 # his back is to the play and one of ours is on him
