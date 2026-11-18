extends Reference

const GK_SPEED = 170.0
const GK_DIVE_SPEED = 240.0
const GK_CATCH_SPEED = 330.0
const GK_HOLD_TIME = 0.9
const GK_BOX_DEPTH = 130.0
const GK_BOX_HALF = 130.0
const GOAL_H = 200.0

var m

func _init(match_node):
	m = match_node

# Main entry point called from match.gd every frame for goalkeepers
func update_goalkeeper(p, delta):
	var team = p.team
	var dirx = (1.0 if team == 0 else -1.0)
	
	# Decrement cooldowns and timers stored on match node
	m.gk_cd[team] = max(0.0, m.gk_cd[team] - delta)
	_update_shot_trajectory(team, delta)
	_process_dive_and_recovery(p, team, delta)
	
	if (m.gk_dive_t[team] > 0.0 or m.gk_down_t[team] > 0.0) and m.gk_hold_timer[team] <= 0.0:
		_check_keeper_reach(p)
		return

	# Handle holding ball / distribution phase
	if m.gk_hold_timer[team] > 0.0:
		m.gk_hold_timer[team] -= delta
		p.vel = Vector2.ZERO
		p.facing = Vector2(dirx, 0.0)
		m.dribble_owner = null
		m.ball.position = p.position + Vector2(14.0 * dirx, 0.0)
		m.ball.vel = Vector2.ZERO
		m.ball.height_z = 0.0
		if m.gk_hold_timer[team] <= 0.0:
			m.gk_hold_timer[team] = 0.0
			_distribute_ball(p)
		return

	# Intelligent Positioning: Goal line tracking + 1v1 Rushing logic
	var target = _calculate_optimal_position(p, team)
	var speed = GK_SPEED
	
	# 1v1 Rushing out: If ball is loose inside the box and close, rush forward to smother
	if m.dribble_owner == null and _in_penalty_box(team, m.ball.position) and m.ball.position.distance_to(p.position) < 180.0:
		var nearest_opp_dist = _get_nearest_opp_dist(team, m.ball.position)
		if m.ball.position.distance_to(p.position) < nearest_opp_dist + 30.0:
			target = m._inside(m.ball.position)
			speed = GK_SPEED * 1.35 # Rushing speed burst

	# Dive tracking override
	if m.gk_shot_seen[team] and m.gk_react[team] <= 0.0:
		speed = GK_DIVE_SPEED

	p.vel = p.position.direction_to(target) * min(speed, p.position.distance_to(target) * 8.0)
	var to_ball = m.ball.position - p.position
	if to_ball.length() > 1.0:
		p.facing = to_ball.normalized()
		
	p.position += p.vel * delta
	m._clamp_player(p)
	_check_keeper_reach(p)


# --- Anticipate Incoming Shots & Trajectory ---
func _update_shot_trajectory(team, delta):
	var goal_c = (_own_goal(team))
	var v = m.ball.vel
	var sgn = (1.0 if team == 0 else -1.0)
	var threat = false
	var proj_y = 0.0
	var own_touch = m.last_touch != null and is_instance_valid(m.last_touch) and m.last_touch.team == team
	
	if v.length() > 300.0 and v.x * sgn < -80.0 and not own_touch:
		var dx = abs(m.ball.position.x - goal_c.x)
		if dx < 750.0 and dx * m._ball_k() < abs(v.x) * 0.98:
			proj_y = m.ball.position.y + v.y / abs(v.x) * dx
			threat = abs(proj_y - goal_c.y) < GOAL_H / 2.0 + 30.0

	if not threat:
		m.gk_shot_seen[team] = false
		m.gk_react[team] = 0.0
		return

	if not m.gk_shot_seen[team]:
		m.gk_shot_seen[team] = true
		m.gk_react[team] = 0.09 # Realistic human-like cognitive reaction delay
		m.gk_read_y[team] = proj_y + rand_range(-14.0, 14.0) # Slight read imperfection
	else:
		m.gk_react[team] = max(0.0, m.gk_react[team] - delta)


# --- Realistic Positioning ARC on Goal Line ---
func _calculate_optimal_position(p, team):
	var goal_c = _own_goal(team)
	var dirx = (1.0 if team == 0 else -1.0)
	var to_ball = m.ball.position - goal_c
	var dist = to_ball.length()
	
	# Base positioning tracks along an arc proportional to ball distance
	var tgt = Vector2(goal_c.x + dirx * 22.0, goal_c.y)
	if dist > 1.0:
		tgt = goal_c + to_ball.normalized() * (22.0 + clamp(dist * 0.14, 0.0, 52.0))
		
	var half = GOAL_H / 2.0 - 6.0
	tgt.y = clamp(tgt.y, goal_c.y - half, goal_c.y + half)
	
	if m.gk_shot_seen[team] and m.gk_react[team] <= 0.0:
		tgt = Vector2(goal_c.x + dirx * 18.0, clamp(m.gk_read_y[team], goal_c.y - half, goal_c.y + half))
		
	return m._inside(tgt)


# --- Diving & Recovery Animations ---
func _process_dive_and_recovery(p, team, delta):
	if not m.gk_shot_seen[team]:
		m.gk_dived[team] = false
		
	if m.gk_shot_seen[team] and m.gk_react[team] <= 0.0 and not m.gk_dived[team] and m.gk_dive_t[team] <= 0.0 \
			and m.gk_down_t[team] <= 0.0 and m.gk_hold_timer[team] <= 0.0:
		var dy = m.gk_read_y[team] - p.position.y
		if abs(dy) >= 14.0:
			m.gk_dive_dir[team] = Vector2((1.0 if team == 0 else -1.0) * 0.25, sign(dy)).normalized()
			m.gk_dive_speed[team] = clamp(abs(dy) / 0.26, 180.0, 400.0)
			m.gk_dive_t[team] = 0.32
			m.gk_dived[team] = true

	if m.gk_dive_t[team] > 0.0:
		m.gk_dive_t[team] -= delta
		p.vel = m.gk_dive_dir[team] * m.gk_dive_speed[team]
		p.position += p.vel * delta
		var cy = m.PITCH.position.y + m.PITCH.size.y / 2.0
		p.position.y = clamp(p.position.y, cy - (GOAL_H / 2.0 + 45.0), cy + (GOAL_H / 2.0 + 45.0))
		if m.gk_dive_t[team] <= 0.0:
			m.gk_dive_t[team] = 0.0
			m.gk_down_t[team] = 0.60 # Recovery grounded delay time
			p.vel = Vector2.ZERO
	elif m.gk_down_t[team] > 0.0:
		m.gk_down_t[team] = max(0.0, m.gk_down_t[team] - delta)
		p.vel = Vector2.ZERO
		
	p.is_diving = m.gk_dive_t[team] > 0.0 or m.gk_down_t[team] > 0.0
	p.dive_dir = m.gk_dive_dir[team]


# --- Catch, Punch or Deflect Decisions ---
func _check_keeper_reach(p):
	var team = p.team
	if m.gk_cd[team] > 0.0 or m.state != "playing":
		return
	if p.position.distance_to(m.ball.position) > m.GK_RADIUS + m.BR + 20.0:
		return
	if m.dribble_owner != null and is_instance_valid(m.dribble_owner) and m.dribble_owner.team == team:
		return

	var spd = m.ball.vel.length()
	var dirx = (1.0 if team == 0 else -1.0)
	
	if _in_penalty_box(team, m.ball.position):
		# Clean Catch vs Punch depending on ball velocity and height
		if spd <= GK_CATCH_SPEED or randf() < 0.40:
			m.gk_hold_timer[team] = GK_HOLD_TIME
			m.gk_wait[team] = 0.0
			m.gk_dive_t[team] = 0.0
			m.dribble_owner = null
			m.ball.vel = Vector2.ZERO
			m.ball.height_z = 0.0
			m.last_touch = p
			m.pass_t = 0.0
			m.pass_target = null
			m.gk_shot_seen[team] = false
		else:
			# High-speed punch / deflection away from goal mouth
			var away = (m.ball.position - p.position).normalized().rotated(rand_range(-0.6, 0.6))
			away.x = dirx * max(abs(away.x), 0.4)
			away = away.normalized()
			m.ball.position = p.position + away * (m.GK_RADIUS + m.BR + 4.0)
			m.ball.vel = away * max(spd * 0.5, 240.0)
			m.ball.impulse_z(120.0)
			m.ball_ghost_t = 0.15
			m.gk_cd[team] = 0.4
			m.last_touch = p
			m.pass_t = 0.0
			m.pass_target = null


# --- Intelligent Ball Distribution ---
func _distribute_ball(p):
	var team = p.team
	var dirx = (1.0 if team == 0 else -1.0)
	var best_mate = null
	var best_score = -1e9
	
	for q in m.players:
		if q.team != team or q.is_gk:
			continue
		var d = q.position.distance_to(m.ball.position)
		if d < 120.0 or d > 750.0:
			continue
		var score = (q.position.x * dirx) - (d * 0.03)
		if score > best_score:
			best_score = score
			best_mate = q
			
	p.kick_cd = 0.0
	if best_mate != null:
		m._pass_to(p, best_mate, 0.25, 0.0, 0.0)
	else:
		var cy = m.PITCH.position.y + m.PITCH.size.y / 2.0
		var aim = Vector2(p.position.x + dirx * 600.0, cy)
		m._try_kick(p, aim - m.ball.position, 620.0, 150.0)
	m.ball_ghost_t = 0.15


func _own_goal(team):
	var cy = m.PITCH.position.y + m.PITCH.size.y / 2.0
	return Vector2(m.PITCH.position.x if team == 0 else m.PITCH.end.x, cy)


func _in_penalty_box(team, pt):
	var cy = m.PITCH.position.y + m.PITCH.size.y / 2.0
	var depth = (pt.x - m.PITCH.position.x) if team == 0 else (m.PITCH.end.x - pt.x)
	return depth < GK_BOX_DEPTH and abs(pt.y - cy) < GK_BOX_HALF


func _get_nearest_opp_dist(team, pos):
	var best = 1e9
	for q in m.players:
		if q.team != team:
			best = min(best, q.position.distance_to(pos))
	return best
