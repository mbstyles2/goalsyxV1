extends Reference
# DECISION layer for passing and shooting: it looks at the game and returns a PLAN. It never touches the
# ball - kick_physics does that. Human players supply intent (kind, power, aim); the brain assists:
#
#   passes : rank team-mates by the line you aimed, how likely the ball is to be cut out (time-based),
#            how much space they have, where they are running, offside; lead moving receivers; or play
#            along your aim if nobody is on that line
#   through: a ball into the space ahead of a runner (lofted when you hold it long or the lane is blocked)
#   crosses: a lofted ball into the box, curled in from the wing
#   shots  : aim where you point (or the best spot if you do not), pick drive / finesse curler / chip from
#            power, keeper position and angle, set the height so it crosses the line under the bar
#   errors : grow with pressure, an awkward body angle, a weak foot and over-hit power. Humans get a
#            reduced, bounded error (ASSIST_HUMAN) so the controls stay predictable.
#
# A plan is a dictionary: kind, anim, dir, speed, lift, curve, dist, T, lofted, delay, foot, mate, target,
# quality, is_shot, record.

const ASSIST_HUMAN = 0.7        # human errors are this fraction of the AI's
const SHOT_ERR_BASE = 0.060      # how far a shot strays with nobody near him (radians, one standard deviation)
const SHOT_ERR_DIST = 0.080      # ... and the extra for a long shot
const OPP_SPEED = 190.0
const AVG_PASS = 310.0          # typical average speed of a ground pass
const AVG_THROUGH = 240.0

var m
var phys = null


func _init(match_node):
	m = match_node


# ------------------------------------------------------------ small helpers

func gauss():
	return (randf() + randf() + randf() - 1.5) * 2.0       # roughly normal, std 1


func dir_of(team):
	return 1.0 if team == 0 else -1.0


func keeper_of(team):
	return m.players[11] if team == 0 else m.players[0]    # the keeper a shooter of `team` faces


func nearest_opp(pos, team):
	var best = 400.0
	for o in m.players:
		if o.team != team:
			best = min(best, o.position.distance_to(pos))
	return best


# how hard the kicker is being closed down (0 = free, 1 = tackle range)
func pressure(p):
	var pr = 0.0
	for o in m.players:
		if o.team == p.team:
			continue
		var off = p.position - o.position
		var d = off.length()
		if d > 80.0:
			continue
		var toward = 0.0
		if o.vel.length() > 5.0 and d > 0.1:
			toward = clamp(o.vel.normalized().dot(off / d), 0.0, 1.0)
		pr = max(pr, pow(1.0 - d / 80.0, 1.2) * (0.75 + 0.25 * toward))
	return clamp(pr, 0.0, 1.0)


# kicking away from where you face, or flat out at full speed, costs balance
func body_penalty(p, d):
	var f = p.facing if p.facing.length() > 0.1 else d
	var ang = abs(f.normalized().angle_to(d))
	var turn = clamp((ang - 0.9) / (PI - 0.9), 0.0, 1.0)
	var run = clamp(p.vel.length() / 260.0, 0.0, 1.0)
	return clamp(turn * 0.85 + run * 0.15, 0.0, 1.0)


func dominant(p):
	return -1 if (p.slot * 7 + p.team * 3) % 4 == 0 else 1


# +1 right foot, -1 left foot (also what player.gd animates)
func foot_for(p, d):
	var f = p.facing if p.facing.length() > 0.1 else d
	if f.normalized().dot(d) > 0.6:
		return 1 if d.x >= 0.0 else -1
	return dominant(p)


# can an opponent get to the ball on its way? time-based: they win it if they reach the line first
func lane_risk(p, to_pos, ball_speed):
	var a = p.position
	var seg = to_pos - a
	var len2 = max(seg.length_squared(), 1.0)
	var risk = 0.0
	for o in m.players:
		if o.team == p.team:
			continue
		var t = clamp((o.position - a).dot(seg) / len2, 0.0, 1.0)
		var on_line = a + seg * t
		var t_ball = t * sqrt(len2) / max(ball_speed, 60.0)
		var t_opp = max(0.0, o.position.distance_to(on_line) - 12.0) / OPP_SPEED
		var slack = t_ball - t_opp
		if slack > -0.10:
			risk += clamp(0.35 + slack * 1.6, 0.0, 1.0)
	return min(risk, 1.6)


# where a moving team-mate will be when the ball gets to him
func lead_point(p, q, v_avg, extra_t):
	var v = q.vel * 0.9
	var pt = q.position
	for i in range(3):
		var t = p.position.distance_to(pt) / max(v_avg, 60.0) + extra_t
		pt = q.position + v * t
	return m._inside(pt)


# the rule the referee applies (match_rules.gd), so the assist avoids exactly what the game would flag;
# the old copy of the rule below is only used when the referee is switched off
func offside_pos(p, q):
	if m.rules != null and m.rules.enabled:
		return m.rules.is_offside_position(p, q)
	var team = p.team
	var dir = dir_of(team)
	var mid_x = m.PITCH.position.x + m.PITCH.size.x * 0.5
	if team == 0 and q.position.x <= mid_x:
		return false
	if team == 1 and q.position.x >= mid_x:
		return false
	var xs = []
	for o in m.players:
		if o.team != team:
			xs.append(o.position.x * dir)
	xs.sort()
	if xs.size() < 2:
		return false
	var second = xs[1] * dir
	var qrel = q.position.x * dir
	return qrel > second and qrel > p.position.x * dir


func in_box(pos, team):
	var depth = m._depth_of_x(pos.x, team)
	var mid = m.PITCH.position.y + m.PITCH.size.y * 0.5
	return depth > m.PITCH.size.x * 0.72 and abs(pos.y - mid) < m.PITCH.size.y * 0.30


# ------------------------------------------------------------ choosing a team-mate

# every team-mate that is a sensible target for this kind of pass, best first
func rank_mates(p, kind, aim):
	var out = []
	var dirt = dir_of(p.team)
	for q in m.players:
		if q.team != p.team or q == p or q.is_gk:
			continue
		var avg = AVG_PASS
		if kind == "through":
			avg = AVG_THROUGH
		elif kind == "cross":
			avg = 430.0
		var lead = lead_point(p, q, avg, 0.10)
		var to = lead - p.position
		var d = to.length()
		var dmin = 40.0
		var dmax = 650.0
		if kind == "through":
			dmax = 720.0
		elif kind == "cross":
			dmin = 140.0
			dmax = 900.0
		if d < dmin or d > dmax:
			continue
		var dv = to / d
		var risk = lane_risk(p, lead, avg) * (0.25 if kind == "cross" else 1.0)
		var open = clamp(nearest_opp(lead, p.team) / 90.0, 0.0, 1.0)
		var fwd = clamp(to.x * dirt / 500.0, -1.0, 1.0)
		var quality = 1.0 - clamp(risk, 0.0, 1.2) * 0.55 + open * 0.35 + fwd * 0.20
		if kind == "through":
			quality += clamp(q.vel.x * dirt / 200.0, 0.0, 1.0) * 0.5 + fwd * 0.3
			if fwd < 0.03:
				continue
		elif kind == "cross":
			quality += 0.7 if in_box(lead, p.team) else -0.4
		if offside_pos(p, q):
			quality -= 0.45
		var align = 0.0
		var score = 0.0
		if aim != Vector2.ZERO:
			align = aim.dot(dv)
			if align < 0.55:
				continue
			score = align * 0.75 + quality * 0.25
		else:
			var f = p.facing if p.facing.length() > 0.1 else dv
			align = f.normalized().dot(dv)
			score = quality + align * 0.15
		out.append({"mate": q, "lead": lead, "d": d, "risk": risk, "score": score, "align": align})
	out.sort_custom(self, "_by_score")
	return out


func _by_score(a, b):
	return a["score"] > b["score"]


# the space ahead of a runner that a through ball should go to
func through_point(p, q, power):
	var dirt = dir_of(p.team)
	var runv = Vector2(dirt, 0.0)
	if q.vel.length() > 20.0:
		runv = q.vel.normalized()
	var run_speed = max(q.vel.length(), 120.0)
	var t = p.position.distance_to(q.position) / AVG_THROUGH + 0.2
	var ahead = run_speed * t + lerp(30.0, 110.0, power)
	var best_pt = m._inside(q.position + runv * ahead)
	var best_s = -1e9
	for a in [0.0, 0.4, -0.4]:
		var pt = m._inside(q.position + runv.rotated(a) * ahead)
		var s = nearest_opp(pt, p.team) / 100.0 - lane_risk(p, pt, AVG_THROUGH) * 0.8 + (pt.x - q.position.x) * dirt / 300.0
		if s > best_s:
			best_s = s
			best_pt = pt
	return best_pt


# ------------------------------------------------------------ passes

# human: ev = {kind: pass / through / cross, power, aim}
func plan_pass(p, ev):
	var kind = ev["kind"]
	var power = ev["power"]
	var aim = ev["aim"]
	var strict = 0.82
	if aim == Vector2.ZERO:
		aim = p.facing.normalized() if p.facing.length() > 0.1 else Vector2(dir_of(p.team), 0.0)
		strict = 0.90
	var ranked = rank_mates(p, kind, aim if ev["aim"] != Vector2.ZERO else Vector2.ZERO)
	var mate = null
	var point = null
	var risk = 0.0
	if not ranked.empty():
		var best = ranked[0]
		var need = strict if kind != "through" else strict - 0.12
		if kind == "cross":
			need = 0.60
		if best["align"] >= need or ev["aim"] == Vector2.ZERO:
			mate = best["mate"]
			risk = best["risk"]
			point = best["lead"]
			if kind == "through":
				point = through_point(p, mate, power)
				risk = lane_risk(p, point, AVG_THROUGH)
	if point == null:
		# nobody on that line: play it along the aim, as far as the power says
		var reach = lerp(120.0, 520.0, power)
		if kind == "through":
			reach = lerp(180.0, 620.0, power)
		elif kind == "cross":
			reach = lerp(260.0, 720.0, power)
		point = m._inside(p.position + aim * reach)
		risk = lane_risk(p, point, AVG_PASS)
	return make_pass_plan(p, kind, power, point, mate, risk, false)


# AI: a pass to a chosen team-mate (lift_z > 0 = lofted through ball)
func plan_ai_pass(p, mate, lead, lift_z):
	var kind = "through" if lift_z > 0.0 else "pass"
	var point = lead_point(p, mate, AVG_PASS, 0.10 + max(0.0, lead - 0.18))
	var risk = lane_risk(p, point, AVG_PASS)
	var power = 0.5 + clamp(risk, 0.0, 1.0) * 0.12
	if lift_z > 0.0:
		power = 0.85
	var plan = make_pass_plan(p, kind, power, point, mate, risk, true)
	if p.is_gk:
		plan["delay"] = 0.0
	return plan


# AI: a clearance towards a point
func plan_clear(p, point):
	var plan = make_pass_plan(p, "clear", 0.8, point, null, 0.0, true)
	return plan


func make_pass_plan(p, kind, power, point, mate, risk, ai):
	var start = p.position
	var to = point - start
	var d = max(to.length(), 30.0)
	var dv = to.normalized() if to.length() > 0.1 else p.facing
	var pr = pressure(p)
	var bp = body_penalty(p, dv)
	var foot = foot_for(p, dv)
	var weak = 1.0 if foot != dominant(p) else 0.0
	var assist = 1.0 if ai else ASSIST_HUMAN

	var lofted = kind == "cross" or kind == "clear"
	if kind == "through" and (power > 0.8 or risk > 0.9):
		lofted = true
	if kind == "pass" and d > 220.0 and risk > 0.85:
		lofted = true
	var speed = 0.0
	var lift = 0.0
	var T = 0.0
	if lofted:
		T = clamp(0.62 + d / 1000.0, 0.6, 1.2)
		if kind == "clear":
			T = clamp(0.85 + d / 1200.0, 0.85, 1.25)
		T *= lerp(0.92, 1.08, power)                    # a longer hold = a bit more hang time
		var lp = phys.lob(d, T)
		speed = lp[0]
		lift = lp[1]
		T = lp[2]                                       # lob() may have lengthened the hang time for a long ball: the curve and pass_t must use the real one
	else:
		var va = lerp(120.0, 260.0, power)
		if kind == "through":
			va = lerp(90.0, 160.0, power)
		speed = phys.ground_speed(d, va)

	var sigma = 0.012 + 0.075 * pr + 0.05 * bp + 0.02 * clamp(d / 600.0, 0.0, 1.0) + 0.03 * weak
	if lofted:
		sigma += 0.012
	if kind == "clear":
		sigma += 0.03
	sigma *= assist
	var ang = clamp(gauss() * sigma, -0.16, 0.16)
	speed = min(speed * (1.0 + gauss() * 0.02 * (0.5 + pr) * assist), m.MAX_BALL_SPEED)

	# a cross bends in from the wing, a lofted through ball just floats
	var curve = 0.0
	if kind == "cross" and T > 0.0:
		var mid = m.PITCH.position.y + m.PITCH.size.y * 0.5
		var side = 1.0 if (mid - start.y) >= 0.0 else -1.0
		var perp = Vector2(-dv.y, dv.x)
		var sgn = side * (1.0 if perp.y >= 0.0 else -1.0)
		curve = clamp(sgn * 2.0 * 18.0 / (T * T), -200.0, 200.0)
		dv = (point - start - perp * sgn * 18.0).normalized()
	var final_dir = dv.rotated(ang)
	var anim = kind
	if kind == "pass" and lofted:
		anim = "through"
	var delay = 0.09
	if kind == "through":
		delay = 0.10
	elif kind == "cross":
		delay = 0.13
	elif kind == "clear":
		delay = 0.11
	return {
		"kind": kind, "anim": anim, "dir": final_dir, "speed": speed, "lift": lift, "curve": curve,
		"dist": d, "T": T, "lofted": lofted, "delay": delay, "foot": foot, "mate": mate, "target": point,
		"quality": clamp(1.0 - abs(ang) / 0.12 * 0.6 - pr * 0.2, 0.0, 1.0),
		"is_shot": false, "record": not ai
	}


# ------------------------------------------------------------ shots

# ev = {power, aim}; target_hint = a goal point the AI already chose (or null)
func plan_shot(p, ev, ai, target_hint):
	var power = ev["power"]
	var aim = ev["aim"]
	var team = p.team
	var dirt = dir_of(team)
	var goal = m._attack_goal(team)
	var gx = goal.x
	var cy = goal.y
	var half = m.GOAL_H * 0.5 - 14.0
	var keeper = keeper_of(team)
	var start = p.position

	# where to aim: where you point, else the best spot
	var ty = cy
	if target_hint != null:
		ty = clamp(target_hint.y, cy - half, cy + half)
	elif aim != Vector2.ZERO and aim.x * dirt > 0.15:
		var t = (gx - start.x) / aim.x
		ty = clamp(start.y + aim.y * t, cy - half, cy + half)
		if abs(ty - keeper.position.y) < 16.0:
			ty = clamp(ty + (14.0 if ty >= keeper.position.y else -14.0), cy - half, cy + half)    # not straight at him
	else:
		ty = best_zone(p, keeper, cy, half, gx, power)
	var tgt = Vector2(gx, ty)
	var d = start.distance_to(tgt)

	# what kind of shot
	var kdepth = abs(keeper.position.x - gx)
	var kind = "shot"
	if power < 0.38 and kdepth > 45.0 and d < 300.0:
		kind = "chip"
	elif power >= 0.35 and power <= 0.72 and abs(start.y - cy) > 90.0 and d > 160.0:
		kind = "finesse"
	var kk = phys.k_ground()
	var speed = 0.0
	var tz = 0.0
	if kind == "chip":
		speed = clamp(phys.k_for(30.0) * d + 150.0, 270.0, 430.0)
		tz = 38.0
	else:
		speed = lerp(380.0, 720.0, pow(power, 0.9))
		speed = max(speed, min(phys.k_for(20.0) * d + 110.0, 720.0))
		if kind == "finesse":
			speed *= 0.9
		tz = lerp(8.0, 36.0, clamp(d / 520.0, 0.0, 1.0)) * (0.7 + 0.5 * power)
	tz = min(tz, 46.0)
	var apex_cap = 30.0                      # a driven shot draws an arc no higher than this (players play up to 32, the bar is 60)
	if kind == "chip":
		apex_cap = 55.0                      # a chip has to get up and over

	# errors: pressure, body angle, weak foot, too hard, too soft, distance
	var dv = (tgt - start).normalized()
	var pr = pressure(p)
	var bp = body_penalty(p, dv)
	var foot = foot_for(p, dv)
	var weak = 1.0 if foot != dominant(p) else 0.0
	var assist = 1.0 if ai else ASSIST_HUMAN
	var over = clamp((power - 0.9) / 0.1, 0.0, 1.0)
	# How far a shot strays. Simulated over thousands of kicks: the old numbers (0.018 / 0.025) put 77-100% of shots
	# on target from 250-450 px and 83-98% from 650 px with nobody near him. These give a footballer's spread: about
	# 95% from the six-yard area, 77% from 19 m, 65% from 27 m and 52% from 36 m with no pressure, much less when
	# he is closed down. (You get the `assist` discount, so you are a little better than the computer.)
	var sigma = SHOT_ERR_BASE + 0.09 * pr + 0.05 * bp + 0.05 * clamp((power - 0.85) / 0.15, 0.0, 1.0)
	sigma += 0.03 * clamp((0.45 - power) / 0.45, 0.0, 1.0) + SHOT_ERR_DIST * clamp((d - 150.0) / 300.0, 0.0, 1.0) + 0.03 * weak
	sigma *= assist
	var ang = clamp(gauss() * sigma, -0.30, 0.30)
	speed = min(speed * (1.0 + gauss() * 0.015), m.MAX_BALL_SPEED)
	if randf() < pr * 0.35 * assist + over * 0.30:
		tz += abs(gauss()) * (14.0 * pr + 18.0 * over)          # skied under pressure / over-hit
		apex_cap = max(apex_cap, 60.0)                          # ...and it really does go up

	# a finesse shot starts towards the keeper and bends away from him into the corner
	var curve = 0.0
	var aim_pt = tgt
	if kind == "finesse":
		var T = max(phys.travel_time(d, speed, phys.k_for(tz)), 0.2)
		var toward_keeper = 1.0 if keeper.position.y >= ty else -1.0
		aim_pt = Vector2(gx, ty + toward_keeper * 22.0)
		var dtmp = (aim_pt - start).normalized()
		var perp = Vector2(-dtmp.y, dtmp.x)
		var s_a = -toward_keeper * (1.0 if perp.y >= 0.0 else -1.0)
		curve = clamp(s_a * 2.0 * 22.0 / (T * T), -220.0, 220.0)
	var final_dir = (aim_pt - start).normalized().rotated(ang)
	var lift = phys.shot_vz(speed, d, tz, apex_cap)
	var delay = 0.13
	if kind == "chip":
		delay = 0.15
	return {
		"kind": kind, "anim": "chip" if kind == "chip" else "shot", "dir": final_dir, "speed": speed,
		"lift": lift, "curve": curve, "dist": d, "T": 0.0, "lofted": false, "delay": delay, "foot": foot,
		"mate": null, "target": tgt,
		"quality": clamp(1.0 - abs(ang) / 0.15 * 0.6 - pr * 0.2 - over * 0.2, 0.0, 1.0),
		"is_shot": true, "record": not ai, "apex_cap": apex_cap
	}


# the corner of the goal the keeper is least likely to reach, away from defenders in the way
func best_zone(p, keeper, cy, half, gx, power):
	var best = cy
	var best_s = -1e9
	var dist = p.position.distance_to(Vector2(gx, cy))
	var t_ball = dist / 520.0
	for i in range(-3, 4):
		var ty = cy + half * i / 3.0
		var t_keeper = max(0.0, abs(ty - keeper.position.y) - 20.0) / 230.0 + 0.12
		var risk = lane_risk(p, Vector2(gx, ty), 520.0)
		var s = (t_keeper - t_ball) * 100.0 - risk * 60.0 + abs(ty - cy) * 0.08
		if s > best_s:
			best_s = s
			best = ty
	return best


# AI: a shot at a goal point it has already picked; speed_hint (~520..720) says how hard it wants to hit it
func plan_ai_shot(p, target, speed_hint):
	var power = clamp((speed_hint - 450.0) / 270.0, 0.35, 1.0)
	return plan_shot(p, {"power": power, "aim": Vector2.ZERO}, true, target)
