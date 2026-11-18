extends Reference
# ScrambleAI - shots, saves, rebounds and the scramble in the box that follows.
#
# One instance lives in match.gd (m.scramble); match.gd calls update() every live tick.
#
#   1. A fast ball from an attacker heading at the goal starts a SCRAMBLE WINDOW (phase "shot").
#   2. Once it is saved, blocked or spilled (the keeper or a defender touches it, or it slows down) the
#      phase is "loose": the ball is up for grabs in the box for a few seconds.
#   3. While the window is open, PlayerDecisionAI gives the players near the box two special jobs:
#        attackers  REBOUND  the two nearest crash the ball, the next one takes the cut-back spot, the
#                            next one the far post (a third crasher for teams that commit numbers)
#        defenders  CLEAR    the two nearest go and clear it, the rest pick up the lurking attackers
#                            goal-side or drop to the edge of the six-yard area
#   4. The window closes when somebody has held the ball for half a second, the keeper holds it, the
#      ball dies or leaves the area, or after WINDOW seconds.
#
# Also here (match.gd asks for them):
#   gk_outcome()       what the keeper does with a ball he reaches: catch / parry wide / spill / tip round
#                      the post. Hard and central shots are spilled, wide ones pushed wide, high ones tipped
#   resolve_contest()  two opponents reach a loose ball together: who gets it (and the ball squirts out)
#   note_parry()       the keeper just touched it: the rebound begins

const TacticSystem = preload("res://scripts/match/tactic.gd")

const SHOT_SPEED = 380.0       # a ball faster than this, heading at the goal, is a shot
const WINDOW = 3.6             # seconds a scramble can last
const ZONE_DEPTH = 420.0       # the scramble area: this far from the goal line ...
const ZONE_HALF = 380.0        # ... and this far from the middle of the goal
const ASSIGN_EVERY = 0.25      # roles are handed out again this often (they only change when the ball does)

var m
var active = false
var phase = ""                 # "shot" (on its way) / "loose" (saved, blocked, spilled)
var att = -1                   # the attacking team
var dfn = -1                   # the defending team
var started = 0.0
var ctrl_t = 0.0               # how long somebody has held the ball
var parry_clock = -99.0
var roles = {}                 # player id -> "crash" "cutback" "far" (attackers) / "clear" "cover" "drop" (defenders)
var marks = {}                 # defender id -> the attacker he picks up
var _next = 0.0


func _init(match_node):
	m = match_node


func reset():
	active = false
	phase = ""
	att = -1
	dfn = -1
	ctrl_t = 0.0
	_next = 0.0
	roles.clear()
	marks.clear()


# ------------------------------------------------------------------ the window

func update(delta):
	if m.state != "playing" or m._dead_ball() or m.gk_hold_timer[0] > 0.0 or m.gk_hold_timer[1] > 0.0:
		if active:
			reset()
		return
	var now = m.ai_clock
	if not active:
		_detect_shot(now)
		if not active:
			return
	var gp = m._own_goal(dfn)
	var b = m.ball.position
	var holder = m.dribble_owner != null and is_instance_valid(m.dribble_owner)
	ctrl_t = (ctrl_t + delta) if holder else 0.0
	if now - started > WINDOW or ctrl_t > 0.45 or abs(b.x - gp.x) > ZONE_DEPTH * 1.6 or abs(b.y - gp.y) > ZONE_HALF * 1.5:
		reset()
		return
	if phase == "shot":
		var v = m.ball.vel
		var coming = v.x * m._dir_of(dfn) < -60.0 and v.length() > 260.0
		var lt = m.last_touch
		var touched_back = lt != null and is_instance_valid(lt) and lt.team == dfn
		if (not coming) or touched_back or now - parry_clock < 0.4:
			phase = "loose"
			started = now                                  # the scramble window counts from the save
			_next = 0.0
	if now >= _next:
		_next = now + ASSIGN_EVERY
		_assign()


func _detect_shot(now):
	var lt = m.last_touch
	if lt == null or not is_instance_valid(lt) or lt.is_gk:
		return
	var v = m.ball.vel
	if v.length() < SHOT_SPEED:
		return
	var d_team = 1 - lt.team
	var gp = m._own_goal(d_team)
	if v.x * m._dir_of(d_team) > -120.0:
		return                                            # not heading at that goal
	var dx = abs(m.ball.position.x - gp.x)
	if dx > 820.0 or dx < 20.0:
		return
	var proj_y = m.ball.position.y + v.y / abs(v.x) * dx
	if abs(proj_y - gp.y) > m.GOAL_H / 2.0 + 90.0:
		return                                            # wide of the goal by a distance: not a shot at it
	active = true
	phase = "shot"
	att = lt.team
	dfn = d_team
	started = now
	ctrl_t = 0.0
	_next = 0.0


# the keeper has touched the ball (a parry, a spill, a tip): the rebound begins
func note_parry(gk):
	parry_clock = m.ai_clock
	if not active:
		active = true
		att = 1 - gk.team
		dfn = gk.team
		ctrl_t = 0.0
	phase = "loose"
	started = m.ai_clock
	_next = 0.0


# ------------------------------------------------------------------ who does what

func _cmp(a, b):
	return a[0] < b[0]


func _assign():
	roles.clear()
	marks.clear()
	var gp = m._own_goal(dfn)
	var b = m.ball.position + m.ball.vel * 0.15
	# attackers: the nearest crash it, then a cut-back runner and a far-post runner
	var atk = []
	for q in m.players:
		if q.team == att and not q.is_gk:
			atk.append([q.position.distance_to(b), q])
	atk.sort_custom(self, "_cmp")
	var n_crash = 3 if int(m.profiles[att]["tac"]["committed"]) >= 3 else 2
	var i = 0
	var crashed = 0
	while i < atk.size() and crashed < n_crash:
		if atk[i][0] < 520.0:
			roles[m._pid(atk[i][1])] = "crash"
			crashed += 1
		i += 1
	var extra = ["cutback", "far"]
	var e = 0
	while i < atk.size() and e < extra.size():
		if atk[i][0] < 900.0:
			roles[m._pid(atk[i][1])] = extra[e]
			e += 1
		i += 1
	# defenders: the nearest two clear it, the others pick somebody up or drop to the edge of the six-yard area
	var dfs = []
	for q in m.players:
		if q.team == dfn and not q.is_gk:
			dfs.append([q.position.distance_to(b), q])
	dfs.sort_custom(self, "_cmp")
	var lurkers = []
	for q in m.players:
		if q.team == att and not q.is_gk and abs(q.position.x - gp.x) < ZONE_DEPTH * 1.3 and abs(q.position.y - gp.y) < ZONE_HALF * 1.2:
			lurkers.append([abs(q.position.x - gp.x), q])
	lurkers.sort_custom(self, "_cmp")
	var taken = {}
	for j in range(dfs.size()):
		var df = dfs[j][1]
		var pid = m._pid(df)
		if j < 2 and dfs[j][0] < 600.0:
			roles[pid] = "clear"
			continue
		var pick = null
		var pd = 260.0
		for lk in lurkers:
			var a = lk[1]
			if taken.has(m._pid(a)):
				continue
			var dd = df.position.distance_to(a.position)
			if dd < pd:
				pd = dd
				pick = a
		if pick != null:
			taken[m._pid(pick)] = true
			marks[pid] = pick
			roles[pid] = "cover"
		else:
			var fam = m._role_traits_of(df)["fam"]
			if fam == "CB" or fam == "FB" or fam == "DM":
				roles[pid] = "drop"


func intent_for(p):
	if not active or p.is_gk:
		return -1
	if not roles.has(m._pid(p)):
		return -1
	if p.team == dfn and m.gk_claim_t[dfn] > 0.0:
		return -1                                          # the keeper has come for it: it is his box, nobody else goes
	var I = TacticSystem.Intent
	return I.REBOUND if p.team == att else I.CLEAR


# [target, speed] for an attacker in the scramble
func rebound_plan(p):
	var r = roles.get(m._pid(p), "crash")
	var gp = m._own_goal(dfn)
	var da = m._dir_of(att)
	var cy = gp.y
	var side = 1.0 if m.ball.position.y >= cy else -1.0
	var sp = m._ai_speed() * 1.07
	var target
	if r == "crash":
		if phase == "loose":
			target = m._intercept_point(p, sp)                       # go and get it
		else:
			target = Vector2(gp.x - da * 170.0, cy + side * 95.0)   # follow the shot in, near post
	elif r == "cutback":
		target = Vector2(gp.x - da * 215.0, cy - side * 70.0)     # where a loose ball is pulled back to
	else:
		target = Vector2(gp.x - da * 120.0, cy - side * 105.0)    # the far post
	if phase == "shot" and m.rules != null:
		target = m.rules.clamp_onside(att, target)                # (once it is saved it is a new phase of play: no offside)
	return [m._inside(target), sp]


# [target, speed] for a defender in the scramble
func clear_plan(p):
	var r = roles.get(m._pid(p), "drop")
	var gp = m._own_goal(dfn)
	var b = m.ball.position
	var sp = m._ai_speed() * 1.06
	var target
	if r == "clear":
		if phase == "loose":
			target = m._intercept_point(p, sp)
		else:
			target = b + (gp - b) * 0.6                              # step into the shot's lane
	elif r == "cover":
		var a = marks.get(m._pid(p))
		if a != null and is_instance_valid(a):
			var to_goal = gp - a.position
			target = a.position + (to_goal.normalized() * 26.0 if to_goal.length() > 1.0 else Vector2.ZERO)
		else:
			target = b + (gp - b).normalized() * 160.0
	else:
		var back = gp - b
		target = b + (back.normalized() * 190.0 if back.length() > 1.0 else Vector2.ZERO)
		target.y = lerp(target.y, gp.y, 0.35)
	return [m._inside(target), sp]


# ------------------------------------------------------------------ the keeper

# What he does with a ball he can reach. Returns {"kind": "catch"} or
# {"kind": "parry" / "spill" / "tip", "dir": Vector2, "speed": px/s, "lift": z impulse}
func gk_outcome(gk, spd):
	var gp = m._own_goal(gk.team)
	var dirx = m._dir_of(gk.team)                        # out of his goal into the pitch
	var h = m.ball.height_z
	var rel_y = m.ball.position.y - gp.y
	var side = 1.0 if rel_y >= 0.0 else -1.0
	var c = m.GK_CATCH_SPEED
	var shot = m.gk_shot_seen[gk.team]                   # a shot at goal, or a ball played in (a cross, a corner, a free kick)
	var catch_p
	if h > 14.0:
		if shot:
			catch_p = 0.5 if spd <= c * 0.7 else 0.0         # a hard shot above him is tipped away
		else:
			catch_p = 0.70 if spd <= c * 1.1 else 0.30       # a cross is his: he comes and claims it
	elif spd <= c * 0.9:
		catch_p = 1.0
	else:
		catch_p = clamp(lerp(0.65, 0.05, (spd - c * 0.9) / (c * 0.8)), 0.05, 0.65)
	if randf() < catch_p:
		return {"kind": "catch"}
	if h > 14.0 and not shot:
		# a cross he cannot hold: punched clear, out and wide (not behind his own goal line)
		return {"kind": "punch", "dir": Vector2(dirx * 0.8, side * 0.6).normalized(), "speed": 380.0, "lift": 110.0}
	var near_post = abs(rel_y) > m.GOAL_H * 0.5 - 40.0
	var r = randf()
	if h > 14.0 or near_post or r < 0.20:
		# round the post / over the bar: out behind the goal line on the side the shot came from (a corner).
		# Always lifted well above the bar, so a tip can never drop into his own goal.
		return {"kind": "tip", "dir": Vector2(-dirx * 0.45, side * 0.89).normalized(), "speed": max(spd * 0.45, 260.0), "lift": 150.0}
	if r < 0.42 and spd > c * 0.85 and abs(rel_y) < 60.0:
		# a hard shot straight at him: he gets his hands to it but cannot hold it, it drops just in front
		return {"kind": "spill", "dir": Vector2(dirx, side * rand_range(0.1, 0.6)).normalized(), "speed": rand_range(70.0, 150.0), "lift": 20.0}
	var ang = rand_range(0.55, 1.15)                     # 31..66 degrees off the goal-line normal: wide, to the flank
	return {"kind": "parry", "dir": Vector2(dirx * cos(ang), side * sin(ang)).normalized(),
			"speed": clamp(spd * rand_range(0.35, 0.55), 200.0, 380.0), "lift": rand_range(50.0, 100.0)}


# ------------------------------------------------------------------ a 50/50

# cands: [{"p": player, "d": distance to the ball}] of players from both teams reaching the ball together.
# Closeness, facing the ball and how keen he is decide, with a good dose of luck.
func resolve_contest(cands):
	var best = null
	var bs = -1e9
	for c in cands:
		var q = c["p"]
		var to_ball = m.ball.position - q.position
		var face = 0.0
		if to_ball.length() > 1.0:
			face = q.facing.dot(to_ball.normalized()) * 0.25
		var keen = float(m._role_traits_of(q)["press"]) * 0.25
		var s = (1.0 - c["d"] / (m.PR + m.BR + 8.0)) * 0.8 + keen + face + randf() * 0.55
		if s > bs:
			bs = s
			best = q
	return best
