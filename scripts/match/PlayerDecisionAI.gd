extends Reference
# PlayerDecisionAI - decides WHAT each AI outfield player is doing right now.
#
#   match.gd  _ai_outfield()  ->  PlayerDecisionAI.plan()
#       decide()   one Intent per player (priority order below)
#       execute()  turns the Intent into [target, speed]:
#                    AttackAI  -> runs, support, width        (team has the ball)
#                    DefendAI  -> press, cover, lane, mark,   (team has not)
#                                 counterpress, recovery
#                    match.gd  -> the existing carrier / pass / shot code, the
#                                 loose-ball interception and the shape targets
#
# Priority (first match wins):
#   1. CARRY       he has the ball                         (never delayed)
#   2. RECEIVE     a pass is on its way to him             (never delayed)
#   3. LOOSE_BALL  he is the one assigned to win it        (never delayed)
#   3b. REBOUND / CLEAR  a shot was saved, blocked or spilled: attackers crash the box, defenders clear it
#                       (ScrambleAI, only while its scramble window is open)
#   4. the team-state intents from DefendAI / AttackAI, kept for COMMIT_TIME so a
#      player never flickers between two jobs when possession wobbles
#   5. HOLD        stand in the team shape (the existing shape / marking code)
#
# Nothing here touches the goalkeeper (goalkeeper_ai.gd), the referee
# (match_rules.gd) or the kicking (kick_system.gd). While the ball is dead the
# old positioning code runs unchanged.

const TacticSystem = preload("res://scripts/match/tactic.gd")
const AttackAI = preload("res://scripts/match/AttackAI.gd")
const DefendAI = preload("res://scripts/match/DefendAI.gd")
const KeeperAI = preload("res://scripts/match/KeeperAI.gd")
const TrapAI = preload("res://scripts/match/TrapAI.gd")

const COMMIT_TIME = 0.45     # seconds a situational intent is kept before it may change


# [target, speed] for this player this frame.
static func plan(m, p, delta):
	if m._dead_ball():
		return hold_plan(m, p)
	return execute(m, p, decide(m, p), delta)


static func decide(m, p):
	var I = TacticSystem.Intent
	var team = p.team
	var gk_has_ball = m.gk_hold_timer[0] > 0.0 or m.gk_hold_timer[1] > 0.0
	var carrier = null
	if m.dribble_owner != null and is_instance_valid(m.dribble_owner):
		carrier = m.dribble_owner

	# 1-3: the urgent jobs are never delayed
	var urgent = -1
	if carrier == p:
		urgent = I.CARRY
	elif (not gk_has_ball) and carrier == null and m.pass_t > 0.0 and m.pass_target == p:
		urgent = I.RECEIVE
	elif (not gk_has_ball) and carrier == null and m._wants_loose_ball(p):
		urgent = I.LOOSE_BALL
	if urgent != -1:
		_remember(m, p, urgent)
		return urgent

	# 3a: the offside trap is on: the back line holds its shape and steps up together, nobody leaves it
	if urgent == -1 and TrapAI.trap_active(m, p.team) and TrapAI.line_member(m, p):
		_remember(m, p, I.HOLD)
		return I.HOLD

	# 3b: the box is a scramble: crash it (attackers) or clear it (defenders)
	if m.scramble != null and m.scramble.active and not gk_has_ball:
		var si = m.scramble.intent_for(p)
		if si != -1:
			_remember(m, p, si)
			return si

	# 4: what the team situation asks of him
	var st = m.team_state[team]
	var fresh = I.HOLD
	if gk_has_ball:
		fresh = I.HOLD                                   # the build-out / retreat code handles it
	elif carrier != null and carrier.team != team:
		fresh = DefendAI.intent_for(m, p, st, carrier)
	elif carrier != null:
		fresh = AttackAI.intent_for(m, p, st, carrier)
	elif TacticSystem.is_defend_state(st):
		fresh = DefendAI.intent_for(m, p, st, null)      # loose ball: the players behind it still get back
	return _commit(m, p, fresh)


# Keep an active job for COMMIT_TIME unless it stopped making sense.
static func _commit(m, p, fresh):
	var I = TacticSystem.Intent
	var pid = m._pid(p)
	var now = m.ai_clock
	var mem = m.ai_intent.get(pid)
	if mem != null and mem["i"] != fresh and mem["i"] != I.HOLD and now - mem["t"] < COMMIT_TIME and _valid(m, p, mem["i"]):
		mem["seen"] = now
		return mem["i"]
	_remember(m, p, fresh)
	return fresh


static func _remember(m, p, intent):
	var pid = m._pid(p)
	var now = m.ai_clock
	var mem = m.ai_intent.get(pid)
	if mem == null or mem["i"] != intent:
		m.ai_intent[pid] = {"i": intent, "t": now, "seen": now, "team": p.team}
	else:
		mem["seen"] = now


# Is this intent still sensible right now?
static func _valid(m, p, intent):
	var I = TacticSystem.Intent
	var team = p.team
	var carrier = null
	if m.dribble_owner != null and is_instance_valid(m.dribble_owner):
		carrier = m.dribble_owner
	var opp_has = carrier != null and carrier.team != team
	var my_has = carrier != null and carrier.team == team
	var st = m.team_state[team]
	if intent == I.PRESS or intent == I.COUNTERPRESS or intent == I.COVER:
		return opp_has and m.pressers_of[team].has(p)
	if intent == I.BLOCK_LANE:
		return opp_has and m.lane_blocker[team] == m._pid(p)
	if intent == I.MARK:
		return opp_has and m.marks_of[team].has(m._pid(p))
	if intent == I.RECOVER:
		return TacticSystem.is_defend_state(st)
	if intent == I.RUN or intent == I.SUPPORT:
		return my_has and TacticSystem.is_attack_state(st)
	if intent == I.REBOUND or intent == I.CLEAR:
		return m.scramble != null and m.scramble.active
	return intent == I.HOLD


# [target, speed]
static func execute(m, p, intent, delta):
	var I = TacticSystem.Intent
	var sp
	if intent == I.CARRY:
		return m._ai_carrier(p, delta)                   # existing: decide / dribble / pass / shoot
	if intent == I.RECEIVE:
		sp = m._ai_speed() * 1.12
		return [m._intercept_point(p, sp), sp]
	if intent == I.LOOSE_BALL:
		sp = m._ai_speed() * m._press_speed_mult(p)
		return [m._intercept_point(p, sp), sp]
	if intent == I.PRESS or intent == I.COVER:
		return DefendAI.press_plan(m, p, delta)
	if intent == I.COUNTERPRESS:
		return DefendAI.counterpress_plan(m, p)
	if intent == I.BLOCK_LANE:
		return DefendAI.lane_block_plan(m, p)
	if intent == I.MARK:
		return DefendAI.mark_plan(m, p)
	if intent == I.RECOVER:
		return DefendAI.recovery_plan(m, p)
	if intent == I.RUN:
		return AttackAI.run_plan(m, p)
	if intent == I.SUPPORT:
		return AttackAI.support_plan(m, p)
	if intent == I.REBOUND:
		return m.scramble.rebound_plan(p)
	if intent == I.CLEAR:
		return m.scramble.clear_plan(p)
	return hold_plan(m, p)


static func hold_plan(m, p):
	var plan = [m._ai_positioning_target(p), m._ai_positioning_speed(p)]
	if TrapAI.trap_active(m, p.team) and TrapAI.line_member(m, p):
		plan[1] = m._ai_speed() * 1.30                  # stepping up: together and quickly
	if m.gk_hold_timer[0] > 0.0 or m.gk_hold_timer[1] > 0.0:
		plan = KeeperAI.hold_plan(m, p, plan)       # a keeper has the ball: one man bothers him, the rest walk back
	return plan
