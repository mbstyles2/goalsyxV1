extends Reference
# DefendAI - HOW players behave while their team does not have the ball
# (team state DEFENDING or TRANSITION_DEFEND). PlayerDecisionAI picks the intent,
# this script turns it into a [target, speed] plan.
#
#   intent_for()          PRESS / COUNTERPRESS / COVER / BLOCK_LANE / MARK / RECOVER / HOLD
#   press_plan()          the first presser and the cover player (existing _ai_press)
#   counterpress_plan()   straight after losing the ball: close the carrier down at once
#   lane_block_plan()     stand on the line between the carrier and his most dangerous option
#   mark_plan()           the existing marking, plus tracking of fast runners
#   recovery_plan()       players who are ahead of the ball get back goal-side of it
#   assign_lane_blockers() called once a frame by match.gd
#
# Who presses and who marks is still decided by match.gd (_assign_pressers /
# _assign_marks), so only the right number of players ever chase the ball.
#
# Zones and spacing (ShapeAI): the shape every plan starts from is ShapeAI.base_shape (a compact block that
# shifts to the ball side, flat back line); marking, lane blocking and recovery end in ShapeAI.finish, so a
# marker follows his man but cannot be dragged out of his zone, and the block never bunches up.

const TacticSystem = preload("res://scripts/match/tactic.gd")
const ShapeAI = preload("res://scripts/match/ShapeAI.gd")


static func intent_for(m, p, st, carrier):
	var I = TacticSystem.Intent
	var team = p.team
	var pid = m._pid(p)
	var tac = m.profiles[team]["tac"]
	if carrier != null:
		var idx = m.pressers_of[team].find(p)
		if idx == 0:
			return I.PRESS
		if idx > 0:
			# right after losing it a high-pressing team swarms the carrier
			if st == TacticSystem.TeamState.TRANSITION_DEFEND and float(tac["press_intensity"]) >= 1.0:
				return I.COUNTERPRESS
			return I.COVER
		if m.lane_blocker[team] == pid:
			return I.BLOCK_LANE
		if m.marks_of[team].has(pid):
			return I.MARK
	if needs_recovery(m, p, st, tac):
		return I.RECOVER
	return I.HOLD


# Is he ahead of the ball while his team has lost it?
static func needs_recovery(m, p, st, tac):
	if not TacticSystem.is_defend_state(st):
		return false
	var team = p.team
	var ahead = (p.position.x - m.ball.position.x) * m._dir_of(team)
	if ahead < 90.0:
		return false
	var fam = m._role_traits_of(p)["fam"]
	var rec = float(tac["recovery"])
	if fam == "ST":
		var L = m.team_ctx[team]["pitch"].size.x
		return rec >= 0.95 or m._depth_of_x(m.ball.position.x, team) < L * 0.40
	if fam == "WG" or fam == "AM":
		return rec >= 0.65
	return true


static func press_plan(m, p, delta):
	return m._ai_press(p, delta)                     # existing: jockey, tackle, cover


# Win it back fast: come at the carrier from goal-side, a little infield. The second and third man
# come in from different sides so they do not stand on each other.
static func counterpress_plan(m, p):
	var carrier = m.dribble_owner
	var pitch = m.team_ctx[p.team]["pitch"]
	var to_own = (m._own_goal(p.team) - carrier.position).normalized()
	var mid_y = pitch.position.y + pitch.size.y * 0.5
	var side = 1.0 if mid_y >= carrier.position.y else -1.0
	var idx = max(1, m.pressers_of[p.team].find(p))
	var lat = (28.0 + 40.0 * float(idx - 1)) * (side if idx % 2 == 1 else -side)
	var target = carrier.position + to_own * (48.0 + 22.0 * float(idx - 1)) + Vector2(0.0, lat)
	return [m._inside(target), m._ai_speed() * m._press_speed_mult(p) * 1.03]


# Between the carrier and the opponent he would most like to pass to.
static func lane_block_plan(m, p):
	var team = p.team
	var carrier = m.dribble_owner
	var opt = m.lane_target[team]
	var shape = ShapeAI.base_shape(m, p)
	if opt == null or not is_instance_valid(opt) or carrier == null:
		return ShapeAI.finish(m, p, [shape, m._ai_positioning_speed(p)], "hold", shape)
	var lane = carrier.position + (opt.position - carrier.position) * 0.5
	return ShapeAI.finish(m, p, [m._inside(shape.linear_interpolate(lane, 0.7)), m._ai_speed()], "block", shape)


# The existing marking (goal-side of his man), plus: stick tighter to a man who is running.
# He follows his man, but only as far as his zone allows.
static func mark_plan(m, p):
	var team = p.team
	var shape = ShapeAI.base_shape(m, p)
	var target = m._marking_target(p, shape)
	var sp = m._ai_positioning_speed(p)
	var mk = m.marks_of[team].get(m._pid(p))
	if mk != null and is_instance_valid(mk) and mk.vel.length() > 110.0:
		var to_goal = m._own_goal(team) - mk.position
		if to_goal.length() > 1.0:
			var tight = mk.position + to_goal.normalized() * 24.0
			target = target.linear_interpolate(tight, 0.4)
		sp = m._ai_speed() * 1.06                    # track the runner
	return ShapeAI.finish(m, p, [m._inside(target), sp], "mark", shape)


# Get back goal-side of the ball, blended with the defensive shape.
static func recovery_plan(m, p):
	var team = p.team
	var ctx = m.team_ctx[team]
	var pitch = ctx["pitch"]
	var shape = ShapeAI.base_shape(m, p)
	var ball = m.ball.position
	var back = (m._own_goal(team) - ball)
	if back.length() < 1.0:
		back = Vector2(-ctx["dir"], 0.0)
	var mid_y = pitch.position.y + pitch.size.y * 0.5
	var goal_side = ball + back.normalized() * 190.0 + Vector2(0.0, (mid_y - ball.y) * 0.3)
	var target = shape.linear_interpolate(goal_side, 0.7)
	var rec = float(ctx["tac"]["recovery"])
	return ShapeAI.finish(m, p, [m._inside(target), m._ai_speed() * (1.08 + 0.05 * rec)], "recover", shape)


# One blocker per defending team: the nearest free midfielder / full-back to the
# passing lane, kept while he is still a sensible choice (no flicker).
static func assign_lane_blockers(m):
	for team in range(2):
		var keep = m.lane_blocker[team]
		m.lane_blocker[team] = -1
		m.lane_target[team] = null
		var carrier = m.dribble_owner
		if carrier == null or not is_instance_valid(carrier) or carrier.team == team:
			continue
		if m.gk_hold_timer[0] > 0.0 or m.gk_hold_timer[1] > 0.0:
			continue
		# the opponent we most fear: furthest towards our goal, ahead of the carrier, in range
		var carrier_d = m._depth_of_x(carrier.position.x, team)
		var opt = null
		var best_d = 1e9
		for q in m.players:
			if q.team != carrier.team or q == carrier or q.is_gk:
				continue
			var dist = q.position.distance_to(carrier.position)
			if dist < 120.0 or dist > 650.0:
				continue
			var qd = m._depth_of_x(q.position.x, team)
			if qd < carrier_d - 40.0 and qd < best_d:
				best_d = qd
				opt = q
		if opt == null:
			continue
		var mid = carrier.position + (opt.position - carrier.position) * 0.5
		var best = null
		var best_dist = 380.0
		var kept = null
		for p in m.players:
			if p.team != team or p.is_gk or m.pressers_of[team].has(p) or m.marks_of[team].has(m._pid(p)):
				continue
			var fam = m._role_traits_of(p)["fam"]
			if fam == "ST" or fam == "WG" or fam == "CB":
				continue
			var d = p.position.distance_to(mid)
			if m._pid(p) == keep and d < best_dist + 90.0:
				kept = p
			if d < best_dist:
				best_dist = d
				best = p
		if kept != null:
			best = kept
		if best != null:
			m.lane_blocker[team] = m._pid(best)
			m.lane_target[team] = opt
