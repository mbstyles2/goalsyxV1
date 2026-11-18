extends Reference
# AttackAI - HOW players without the ball behave while their team attacks
# (team state ATTACKING or TRANSITION_ATTACK). PlayerDecisionAI picks the intent,
# this script turns it into a [target, speed] plan.
#
#   intent_for()   RUN / SUPPORT / HOLD for a player whose team has the ball
#   run_plan()     a forward run onto the last defender's shoulder
#   support_plan() a passing option next to the carrier, clear of the others
#
# What it adds on top of the existing shape / support code in match.gd:
#   - forward runs are limited: at most `committed` players run at once, and how
#     often a runner goes depends on the tactic (`forward_runs`, plus
#     `counter_urgency` right after winning the ball)
#   - runners stay onside (match_rules.clamp_onside) and time the run
#   - supporters that are not one of the two nearest options keep clear of the
#     carrier so nobody crowds him
# The carrier himself is still driven by match.gd (_ai_carrier / _ai_decide).
#
# Spacing and zones (ShapeAI): every plan here starts from ShapeAI.base_shape (stretched or squeezed by the
# tactic's `width`) and ends in ShapeAI.finish, so a run or a support position can pull a player out of his
# zone only so far, and team-mates never stack up. Full-backs also make the overlapping run round the outside
# of a team-mate who has the ball on their flank.

const TacticSystem = preload("res://scripts/match/tactic.gd")
const ShapeAI = preload("res://scripts/match/ShapeAI.gd")
const TrapAI = preload("res://scripts/match/TrapAI.gd")

const RUN_WINDOW = 2.0        # seconds a "will he run now?" answer stays the same
const KEEP_CLEAR = 110.0      # non-supporters stay at least this far from the carrier


static func intent_for(m, p, st, carrier):
	var I = TacticSystem.Intent
	if carrier == p:
		return I.HOLD
	var tr = m._role_traits_of(p)
	var tac = m.profiles[p.team]["tac"]
	if tr["run"] and can_run(m, p, st, carrier, tac):
		return I.RUN
	if m._support_rank(p, carrier) < 2:
		return I.SUPPORT
	return I.HOLD


# Should this player make a forward run now?
static func can_run(m, p, st, carrier, tac):
	var I = TacticSystem.Intent
	var team = p.team
	var pid = m._pid(p)
	var ctx = m.team_ctx[team]
	var L = ctx["pitch"].size.x
	var dir = ctx["dir"]
	# already running: keep going (PlayerDecisionAI holds the intent for a while)
	var mem = m.ai_intent.get(pid)
	var running_now = mem != null and mem["i"] == I.RUN and m.ai_clock - mem["seen"] < 0.3
	# the move must make sense: ball is past the first third (or we just won it), runner is not far behind it
	var counter = st == TacticSystem.TeamState.TRANSITION_ATTACK
	if not counter and m._depth_of_x(carrier.position.x, team) < L * 0.30:
		return false
	if (p.position.x - carrier.position.x) * dir < -80.0:
		return false
	# how many are running already?
	var running = 0
	for q in m.players:
		if q.team != team or q == p:
			continue
		var qm = m.ai_intent.get(m._pid(q))
		if qm != null and qm["i"] == I.RUN and m.ai_clock - qm["seen"] < 0.3:
			running += 1
	if running >= int(tac["committed"]):
		return false
	if running_now:
		return true
	# how often this tactic sends runners (steady for RUN_WINDOW seconds, different per player)
	var prob = float(tac["forward_runs"])
	if counter:
		prob = min(1.0, prob + 0.35 * float(tac["counter_urgency"]))
	return _gate(pid, int(m.ai_clock / RUN_WINDOW)) < prob


# 0..1, the same for a given player and time window, different between players
static func _gate(pid, window):
	return fposmod(sin(float(pid) * 12.9898 + float(window) * 78.233) * 43758.5453, 1.0)


static func tempo_of(m, p):
	return float(m.profiles[p.team]["tac"]["tempo"])


# Run onto the last defender's shoulder, staying onside until the pass is played. A full-back whose
# team-mate has the ball on his flank goes round the outside instead (the overlap).
static func run_plan(m, p):
	var team = p.team
	var ctx = m.team_ctx[team]
	var pitch = ctx["pitch"]
	var dir = ctx["dir"]
	var L = pitch.size.x
	var H = pitch.size.y
	var mid_y = pitch.position.y + H * 0.5
	var shape = ShapeAI.base_shape(m, p)
	var margin = 30.0
	if TrapAI.trap_active(m, 1 - team) and TrapAI.reads_trap(m, p):
		margin = 110.0                                  # he sees the line coming up: he stays well behind it (a few do not)
	var run_d = min(ctx["opp_last_d"] - margin, L - 120.0)
	run_d = max(run_d, m._depth_of_x(shape.x, team))
	var x = (pitch.position.x + run_d) if dir > 0.0 else (pitch.end.x - run_d)
	var y = shape.y
	var tr = m._role_traits_of(p)
	if tr["width"] < 0.5:
		# a central runner attacks the gap between the centre-backs
		y = lerp(shape.y, mid_y, 0.4)
	var carrier = m.dribble_owner
	if tr["fam"] == "FB" and tr["width"] >= 0.5 and carrier != null and is_instance_valid(carrier) and carrier != p and carrier.team == team:
		var same_flank = (p.position.y - mid_y) * (carrier.position.y - mid_y) > 0.0 and abs(carrier.position.y - mid_y) > H * 0.16
		var behind = (p.position.x - carrier.position.x) * dir < 60.0
		if same_flank and behind and m._depth_of_x(carrier.position.x, team) > L * 0.40:
			var edge = (pitch.position.y + 75.0) if carrier.position.y < mid_y else (pitch.end.y - 75.0)
			var ov_d = min(m._depth_of_x(carrier.position.x, team) + 240.0, run_d)
			x = (pitch.position.x + ov_d) if dir > 0.0 else (pitch.end.x - ov_d)
			y = lerp(carrier.position.y, edge, 0.85)
	var target = Vector2(x, y)
	if m.rules != null:
		target = m.rules.clamp_onside(team, target)
	var sp = m._ai_speed() * (1.04 + 0.06 * tempo_of(m, p))
	return ShapeAI.finish(m, p, [target, sp], "run", shape)


# A passing option near the carrier; supporters who are not one of the two
# nearest options keep clear of him.
static func support_plan(m, p):
	var team = p.team
	var shape = ShapeAI.base_shape(m, p)
	var target = m._support_target(p, shape)
	if m.rules != null:
		target = m.rules.clamp_onside(team, target)
	var carrier = m.dribble_owner
	if carrier != null and is_instance_valid(carrier) and carrier != p:
		if m._support_rank(p, carrier) >= 2:
			var off = target - carrier.position
			if off.length() < KEEP_CLEAR:
				if off.length() < 1.0:
					off = Vector2(0.0, -1.0)
				target = carrier.position + off.normalized() * KEEP_CLEAR
	var sp = m._ai_positioning_speed(p) * (1.0 + 0.04 * (tempo_of(m, p) - 1.0))
	return ShapeAI.finish(m, p, [m._inside(target), sp], "support", shape)
