extends Reference
# ShapeAI - where an AI outfield player stands: width, zones, spacing and flat lines.
#
# tactic.gd's shape_target() gives every player his place in the team block. This script is the layer
# on top that makes the block play like a team (the FIFA 14 half of the hybrid: strict, structured
# shape; the FC half comes from AttackAI's overlaps / runs and DefendAI's cover):
#
#   base_shape()   the shape target, then
#                    - WIDTH:  in possession the whole block stretches (tactic `width` > 1, wing play) or
#                              squeezes (< 1, narrow). Without the ball it squeezes towards the middle, tighter
#                              the nearer the ball is to our goal, and the far side tucks in most.
#                    - LINES:  the centre-backs (and full-backs standing level with them) hold ONE flat line,
#                              the midfield holds one line.
#   finish()       the last step of a plan (a run, a support position, a mark ...):
#                    - ZONE:   a player can be pulled away from his place by his job, but only so far (the
#                              tactic's `zone`, the role's ZONE_LEASH); past it the pull counts for a quarter.
#                    - SPACE:  team-mates keep a minimum distance, mostly sideways, so nobody stacks up
#                    - SMOOTH: no twitching when two plans disagree for a frame
#
# Nothing here touches the carrier, a pass receiver, the primary presser or a loose-ball chaser.

const TacticSystem = preload("res://scripts/match/tactic.gd")

const MIN_SPACE_ATT = 170.0   # px between team-mates with the ball (x tactic `spacing`)
const MIN_SPACE_DEF = 130.0   # ... and without it (a compact block)
const MAX_PUSH = 70.0         # most a target is moved to make room
const SMOOTH = 0.30           # 0..1 share of the way to a new target taken per frame

# what finish() allows per kind of plan: [zone slack along the pitch, zone slack across it, keep spaced?]
const KINDS = {
	"hold": [1.0, 1.0, true],
	"support": [2.4, 1.6, true],
	"run": [99.0, 1.4, true],
	"mark": [1.5, 1.5, false],
	"block": [1.5, 1.5, false],
	"recover": [2.5, 2.0, false]
}


# ------------------------------------------------------------------ the base shape

static func base_shape(m, p):
	var team = p.team
	var ctx = m.team_ctx[team]
	var base = TacticSystem.shape_target(m.shape_proxy[m._pid(p)], ctx)
	var pitch = ctx["pitch"]
	var tac = ctx["tac"]
	var tr = m._role_traits_of(p)
	var fam = tr["fam"]
	var dir = ctx["dir"]
	var L = pitch.size.x
	var H = pitch.size.y
	var mid_y = pitch.position.y + H * 0.5
	var w = float(tac.get("width", 1.0))
	var off = base.y - mid_y
	var d = m._depth_of_x(base.x, team)

	if ctx["poss"]:
		# the block stretches or squeezes with the ball; a winger always keeps his lane
		var k = w
		if tr["width"] >= 0.5:
			k = max(w, 1.0)
		off *= k
	else:
		var ball = ctx["ball"]
		var ball_d = m._depth_of_x(ball.x, team)
		var danger = clamp(1.0 - ball_d / (L * 0.55), 0.0, 1.0)         # 0 = far from our goal, 1 = right in front of it
		var squeeze = lerp(0.10, 0.28, danger) * clamp(1.5 - 0.5 * w, 0.6, 1.3)
		if fam == "ST" or fam == "WG":
			squeeze *= 0.6                                              # the front players keep their width for the break
		var ball_off = ball.y - mid_y
		if abs(ball_off) > H * 0.12 and off * ball_off < 0.0:
			squeeze *= 1.25                                             # the far side tucks in most
		off *= (1.0 - clamp(squeeze, 0.0, 0.45))
		# flat lines
		var ln = _lines(m, team)
		if fam == "CB" and ln["cb"] >= 0.0:
			d = lerp(d, ln["cb"], 0.75)
		elif fam == "FB" and ln["cb"] >= 0.0 and abs(d - ln["cb"]) < L * 0.12:
			d = lerp(d, ln["cb"], 0.75)                                 # (wing-backs standing much higher are left alone)
		elif (fam == "DM" or fam == "CM") and ln["mid"] >= 0.0:
			d = lerp(d, ln["mid"], 0.5)
		# the offside trap: the back line steps up together (never past the ball)
		if (fam == "CB" or fam == "FB") and m.trap_until[team] > m.ai_clock:
			d = min(d + m.trap_step[team], max(d, ball_d - 90.0))

	var x = (pitch.position.x + d) if dir > 0.0 else (pitch.end.x - d)
	var y = clamp(mid_y + off, pitch.position.y + 30.0, pitch.end.y - 30.0)
	return Vector2(x, y)


# average depth of the centre-backs and of the central midfielders, once per tick and team
static func _lines(m, team):
	var key = "lines" + str(team)
	var c = m.shape_mem.get(key)
	if c != null and c["t"] == m.ai_clock:
		return c
	var ctx = m.team_ctx[team]
	var cb = 0.0
	var ncb = 0
	var mid = 0.0
	var nmid = 0
	for q in m.players:
		if q.team != team or q.is_gk:
			continue
		var fam = m._role_traits_of(q)["fam"]
		if fam != "CB" and fam != "DM" and fam != "CM":
			continue
		var d = m._depth_of_x(TacticSystem.shape_target(m.shape_proxy[m._pid(q)], ctx).x, team)
		if fam == "CB":
			cb += d
			ncb += 1
		else:
			mid += d
			nmid += 1
	var out = {"t": m.ai_clock, "cb": (cb / ncb) if ncb > 0 else -1.0, "mid": (mid / nmid) if nmid > 0 else -1.0}
	m.shape_mem[key] = out
	return out


# ------------------------------------------------------------------ the last step of a plan

# plan = [target, speed]; shp = his base_shape (pass it if you already have it)
static func finish(m, p, plan, kind, shp = null):
	var cfg = KINDS.get(kind, KINDS["hold"])
	if shp == null:
		shp = base_shape(m, p)
	var target = hold_zone(m, p, shp, plan[0], cfg[0], cfg[1])
	if cfg[2]:
		target = spread(m, p, target)
	target = smooth(m, p, target)
	return [m._inside(target), plan[1]]


# A job may pull him out of his zone, but only so far.
static func hold_zone(m, p, shp, target, slack_x, slack_y):
	var tac = m.profiles[p.team]["tac"]
	var z = float(tac.get("zone", 0.75))
	var lz = TacticSystem.zone_leash(m._role_traits_of(p)["fam"])
	var k = clamp(1.8 - 1.1 * z, 0.6, 1.8)
	var lx = lz.x * k * slack_x
	var ly = lz.y * k * slack_y
	var dir = m._dir_of(p.team)
	var off = target - shp
	var ox = off.x * dir
	var oy = off.y
	var e = sqrt((ox / lx) * (ox / lx) + (oy / ly) * (oy / ly))
	if e <= 1.0:
		return target
	var sc = (1.0 + (e - 1.0) * 0.25) / e                  # past the edge of his zone only a quarter of the pull counts
	return shp + Vector2(ox * sc * dir, oy * sc)


# Team-mates keep a minimum distance, mostly sideways (the metric is squeezed along the pitch).
static func spread(m, p, target):
	var ctx = m.team_ctx[p.team]
	var space = (MIN_SPACE_ATT if ctx["poss"] else MIN_SPACE_DEF) * float(ctx["tac"].get("spacing", 1.0))
	var carrier = m.dribble_owner
	var push = Vector2.ZERO
	for q in m.players:
		if q.team != p.team or q == p or q.is_gk or q == carrier:
			continue
		var away = target - q.position
		var ell = Vector2(away.x * 0.5, away.y)
		var dist = ell.length()
		if dist >= space:
			continue
		if dist < 0.5:
			ell = Vector2(0.0, -1.0 if int(p.slot) % 2 == 0 else 1.0)
			dist = 0.5
		push += ell / dist * (space - dist) * 0.5
	if push.length() > MAX_PUSH:
		push = push.normalized() * MAX_PUSH
	return target + push


static func smooth(m, p, target):
	var pid = m._pid(p)
	var prev = m.shape_mem.get(pid)
	if prev == null or prev.distance_to(target) > 260.0:
		m.shape_mem[pid] = target
		return target
	var out = prev.linear_interpolate(target, SMOOTH)
	m.shape_mem[pid] = out
	return out
