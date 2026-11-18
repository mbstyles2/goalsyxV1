extends Reference
# KeeperAI - what the outfield players do while a keeper has the ball in his hands (his six seconds).
#
# Before, every outfield player went straight back to his place in the team shape at full speed the moment the
# keeper caught it. Now:
#   - ONE opponent stays to bother the keeper: he hovers a few steps off him, swaying from side to side. He keeps
#     his distance (the keeper's space is his own) and he is slow: he is there to distract, not to win the ball.
#   - the rest of that side walks back, they do not sprint.
#   - the keeper's own team spreads out for the build-out at an unhurried jog.
# match.gd's keeper code (his box is his domain) does the rest.

const WALK = 0.38              # the rest of the other side: a walk back
const JOG = 0.60               # the keeper's own team
const PEST_SPEED = 0.60
const PEST_DIST = 125.0        # he never gets nearer than this to the keeper


# [target, speed] for an outfield player while a keeper holds the ball; base is what the shape code wanted
static func hold_plan(m, p, base):
	var holder = 0 if m.gk_hold_timer[0] > 0.0 else 1
	var keeper = null
	for q in m.players:
		if q.is_gk and q.team == holder:
			keeper = q
	if keeper == null:
		return base
	if p.team == holder:
		return [base[0], m._ai_speed() * JOG]
	if _pest(m, holder, keeper) == p:
		return [_pest_target(m, p, keeper), m._ai_speed() * PEST_SPEED]
	return [base[0], m._ai_speed() * WALK]


# the one player who stays: the front player nearest the keeper (kept while he is still near)
static func _pest(m, holder, keeper):
	var key = "pest" + str(holder)
	var cur = m.shape_mem.get(key)
	if cur != null and is_instance_valid(cur) and cur.team != holder and cur.position.distance_to(keeper.position) < 700.0:
		return cur
	var best = null
	var bs = 1e9
	for q in m.players:
		if q.team == holder or q.is_gk:
			continue
		var fam = m._role_traits_of(q)["fam"]
		var s = q.position.distance_to(keeper.position)
		if fam == "ST" or fam == "AM" or fam == "WG":
			s -= 90.0
		if s < bs:
			bs = s
			best = q
	m.shape_mem[key] = best
	return best


static func _pest_target(m, p, keeper):
	var dirx = m._dir_of(keeper.team)
	var cy = m.PITCH.position.y + m.PITCH.size.y * 0.5
	var side = 1.0 if keeper.position.y < cy else -1.0          # towards the middle: he does not block the keeper's pass out
	var base = keeper.position + Vector2(dirx * 85.0, side * 90.0)
	var t = m.ai_clock
	var tgt = base + Vector2(cos(t * 1.3) * 14.0, sin(t * 2.2 + float(p.slot)) * 36.0)
	var off = tgt - keeper.position
	if off.length() < PEST_DIST:
		tgt = keeper.position + (off.normalized() if off.length() > 1.0 else Vector2(dirx, 0.0)) * PEST_DIST
	return m._inside(tgt)
