extends CanvasLayer
# Penalty shootout, seen from behind the kicker: a fake-3D scene on a pure 2D canvas.
# Everything is placed in a tiny 3D world (metres) and projected to the screen by hand.
#
# match.gd creates it with PenaltyShootout.new(self), adds it as a child and waits for "finished(goals)".
#
# 1 player : you take team 0's kicks and keep goal for team 1's kicks; the AI does the rest.
# 2 players: P1 = team 0, P2 = team 1.
#   shooter: aim with the direction keys, HOLD the shoot key to charge power, RELEASE to shoot
#            (green zone on the power bar = accurate; too weak = slow, too hard = wild)
#   keeper : left / right to dive, hold up as well for a high dive, up alone to jump
#   keys   : 1P  WASD or arrows + SPACE      2P  P1: WASD + F      P2: arrows + ENTER
#   touch  : stick = aim / dive, shoot button = charge + shoot (uses match's touch controls)

signal finished(goals)

const PlayerScript = preload("res://scripts/match/player.gd")
const FONT_PATH = "res://assets/fonts/batmfa.ttf"

const KICKS = 5                 # kicks per team before sudden death

# ---- the little world: X across, Y up, Z towards the goal (metres). The penalty spot is Z = 0.
const GOAL_Z = 11.0
const GOAL_HALF = 3.66          # half the goal width
const GOAL_TOP = 2.44
const NET_DEPTH = 2.0
const BALL_R = 0.16

# ---- the camera: behind the spot, a bit above head height. Screen is a 960 x 540 canvas.
const VW = 960.0
const VH = 540.0
const CAM_Z = -6.0
const CAM_Y = 1.7
const FOCAL = 700.0
const HORIZON = 160.0

# ---- timings
const READY_T = 1.3
const RUN_T = 0.55
const RESULT_T = 2.0
const DIVE_T = 0.30
const AI_READ = 0.22            # chance the AI keeper "reads" the shot (0 = pure guess, 1 = psychic)
const AIM_TIMEOUT = 9.0

var m                           # the match node
var goals = [0, 0]
var marks = [[], []]            # "O" scored / "X" not
var kick = 0
var shooter = 0
var phase = "wait"              # wait, ready, aim, run, flight, result, over
var phase_t = 0.0
var clock = 0.0
var started = false
var wait_total = 0.0
var done = false

# aiming / shooting
var aim = Vector2(0.0, 1.0)     # where on the goal face (x across, y height)
var power = 0.0
var charging = false
var charge_t = 0.0
var armed = false               # the shoot key must be released once before it can charge
var ai_plan = {}
var shot = {}
var launch_clock = 0.0

# ball (metres) and what happens to it after it reaches the keeper
var ball = Vector3(0.0, BALL_R, 0.0)
var ball_v = Vector3.ZERO
var spin = 0.0
var outcome = ""
var msg_text = ""
var msg_col = Color.white

# keeper
var dive = null                 # {"side", "high", "t0", "x0"} once he has committed
var keeper_x = 0.0              # idle sway
var pend = -1.0                 # human dive input: wait a moment so "left + up" can be pressed together
var pend_side = 0
var pend_high = false
var ai_keeper = {}

# effects
var cheer_t = 0.0
var net_shake = 0.0
var shake = 0.0

# nodes
var holder
var bg
var keeper_holder
var kicker_holder
var back_scene
var front_scene
var kicker_node = null
var keeper_node = null
var font_big
var font_mid
var font_small
var pad = 6.0
var base_pos = Vector2.ZERO
var crowd_pos = PoolVector2Array()
var crowd_col = []


# a Node2D that just hands its _draw() to the shootout (so one script can draw several layers)
class Scene extends Node2D:
	var host
	var mode = 0

	func _draw():
		if host != null:
			if mode == 0:
				host.draw_back(self)
			else:
				host.draw_front(self)


func _init(match_node):
	m = match_node
	layer = 30


func _ready():
	var vp = get_viewport().get_visible_rect().size
	var s = min(vp.x / VW, vp.y / VH)
	pad = max(0.0, (vp.x / s - VW) * 0.5) + 6.0

	bg = ColorRect.new()
	bg.rect_size = vp
	bg.color = Color(0, 0, 0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	holder = Node2D.new()
	holder.scale = Vector2(s, s)
	base_pos = Vector2((vp.x - VW * s) * 0.5, (vp.y - VH * s) * 0.5)
	holder.position = base_pos
	add_child(holder)

	back_scene = Scene.new()
	back_scene.host = self
	back_scene.mode = 0
	holder.add_child(back_scene)
	keeper_holder = Node2D.new()
	holder.add_child(keeper_holder)
	front_scene = Scene.new()
	front_scene.host = self
	front_scene.mode = 1
	holder.add_child(front_scene)
	kicker_holder = Node2D.new()
	holder.add_child(kicker_holder)

	font_big = _font(40)
	font_mid = _font(20)
	font_small = _font(13)
	_build_crowd()
	_set_visible(false)


func _font(size):
	var f = DynamicFont.new()
	f.font_data = load(FONT_PATH)
	f.size = size
	return f


func _set_visible(v):
	bg.visible = v
	holder.visible = v


func _build_crowd():
	var rng = RandomNumberGenerator.new()
	rng.seed = 777
	var home_c = m.players[0].color
	var away_c = m.players[11].color
	var palette = [Color(0.85, 0.2, 0.2), Color(0.95, 0.85, 0.2), Color(0.2, 0.45, 0.9), Color(0.9, 0.9, 0.9),
		Color(0.2, 0.7, 0.35), Color(0.95, 0.55, 0.15), Color(0.6, 0.3, 0.8), Color(0.15, 0.15, 0.15)]
	for row in range(6):
		var y = 34.0 + row * 20.0
		var x = -pad + rng.randf_range(0.0, 12.0)
		while x < VW + pad:
			crowd_pos.append(Vector2(x, y + rng.randf_range(-3.0, 3.0)))
			var roll = rng.randf()
			var c
			if roll < 0.40:
				c = home_c if x < VW * 0.5 else away_c
			elif roll < 0.55:
				c = away_c if x < VW * 0.5 else home_c
			else:
				c = palette[rng.randi() % palette.size()]
			crowd_col.append(c.darkened(rng.randf_range(0.0, 0.25)))
			x += rng.randf_range(10.0, 16.0)


# ------------------------------------------------------------ helpers

func proj(x, y, z):
	var d = max(z - CAM_Z, 0.4)
	var sc = FOCAL / d
	return Vector3(VW * 0.5 + x * sc, HORIZON + (CAM_Y - y) * sc, sc)


func _is_human(team):
	return team == 0 or Game.two_player


func _team_tag(team):
	var tid = Game.home_id if team == 0 else Game.away_id
	return Game.team_name(tid).substr(0, 3).to_upper()


func _team_col(team):
	return m.players[team * 11].color


# direction keys / stick for a team (same key layout as the match itself)
func _dir_for(team):
	var two = Game.two_player
	var use_wasd = (not two) or team == 0
	var use_arrows = (not two) or team == 1
	var d = Vector2.ZERO
	if (use_arrows and Input.is_key_pressed(KEY_LEFT)) or (use_wasd and Input.is_key_pressed(KEY_A)):
		d.x -= 1.0
	if (use_arrows and Input.is_key_pressed(KEY_RIGHT)) or (use_wasd and Input.is_key_pressed(KEY_D)):
		d.x += 1.0
	if (use_arrows and Input.is_key_pressed(KEY_UP)) or (use_wasd and Input.is_key_pressed(KEY_W)):
		d.y -= 1.0
	if (use_arrows and Input.is_key_pressed(KEY_DOWN)) or (use_wasd and Input.is_key_pressed(KEY_S)):
		d.y += 1.0
	var tc = m.touch_controls
	if tc != null and tc.is_active_for(team) and tc.move != Vector2.ZERO:
		d = tc.move
	return d


func _shoot_held(team):
	var two = Game.two_player
	var h = false
	if not two:
		h = Input.is_key_pressed(KEY_SPACE)
	elif team == 0:
		h = Input.is_key_pressed(KEY_F)
	else:
		h = Input.is_key_pressed(KEY_ENTER) or Input.is_key_pressed(KEY_KP_ENTER)
	var tc = m.touch_controls
	if tc != null and tc.is_active_for(team) and tc.shoot:
		h = true
	return h


# ------------------------------------------------------------ main loop

func _process(delta):
	if done:
		return
	clock += delta
	cheer_t = max(0.0, cheer_t - delta)
	net_shake = max(0.0, net_shake - delta * 1.6)
	shake = max(0.0, shake - delta * 2.0)

	if not started:
		# let the pre-match intro finish first (give up waiting after 8 seconds)
		wait_total += delta
		var ui = m.ui_controller
		if ui != null and ui.intro_active and wait_total < 8.0:
			return
		started = true
		_set_visible(true)
		_begin_kick()

	phase_t += delta
	keeper_x = 0.3 * sin(clock * 2.2)

	if phase == "ready":
		if phase_t >= READY_T:
			phase = "aim"
			phase_t = 0.0
			armed = false
	elif phase == "aim":
		_update_aim(delta)
	elif phase == "run":
		if phase_t >= RUN_T:
			_launch()
	elif phase == "flight":
		var u = clamp(phase_t / shot["T"], 0.0, 1.0)
		ball = _flight_pos(u)
		spin += delta * 14.0
		if u >= 1.0:
			_resolve()
	elif phase == "result":
		_step_ball(delta)
		if phase_t >= RESULT_T:
			_next_kick()
	elif phase == "over":
		_step_ball(delta)
		if phase_t >= 2.6:
			done = true
			emit_signal("finished", goals.duplicate())
			return

	_keeper_input(delta)
	_ai_keeper_step()
	_update_figures(delta)
	holder.position = base_pos + Vector2(rand_range(-1.0, 1.0), rand_range(-1.0, 1.0)) * shake * 8.0
	back_scene.update()
	front_scene.update()


# ------------------------------------------------------------ one kick

func _begin_kick():
	shooter = kick % 2
	phase = "ready"
	phase_t = 0.0
	aim = Vector2(0.0, 1.0)
	power = 0.0
	charging = false
	charge_t = 0.0
	armed = false
	dive = null
	ai_keeper = {}
	outcome = ""
	msg_text = ""
	ball = Vector3(0.0, BALL_R, 0.0)
	ball_v = Vector3.ZERO
	spin = 0.0
	net_shake = 0.0
	pend = -1.0
	ai_plan = {}
	_build_figures()
	if not _is_human(shooter):
		_plan_ai_shot()


func _build_figures():
	if kicker_node != null and is_instance_valid(kicker_node):
		kicker_node.queue_free()
	if keeper_node != null and is_instance_valid(keeper_node):
		keeper_node.queue_free()
	var slot = 1 + int(kick / 2) % 10
	kicker_node = _make_figure(m.players[shooter * 11 + slot], false)
	kicker_node.facing = Vector2(0.0, -1.0)          # seen from behind
	kicker_holder.add_child(kicker_node)
	keeper_node = _make_figure(m.players[(1 - shooter) * 11], true)
	keeper_node.facing = Vector2(0.0, 1.0)           # facing us
	keeper_holder.add_child(keeper_node)


# a stickman using the same player.gd as the match (kit, jersey picture and all)
func _make_figure(src, gk):
	var p = PlayerScript.new()
	p.team = src.team
	p.slot = src.slot
	p.is_gk = gk
	p.color = src.color
	p.ring = src.ring
	p.jersey = src.jersey
	p.force_stickman = true      # the sprite sheet has no back view, so this scene keeps the stickman
	var shirt_no = src.get("number")                 # shirt number (a player.gd without one gives null)
	if shirt_no != null:
		p.set("number", shirt_no)
	return p


func _plan_ai_shot():
	var zones = [[-1, 0], [-1, 1], [-1, 2], [1, 0], [1, 1], [1, 2], [0, 1], [0, 2]]
	var weights = [3.0, 2.0, 3.0, 3.0, 2.0, 3.0, 1.0, 1.0]
	var total = 0.0
	for w in weights:
		total += w
	var roll = randf() * total
	var pick = 0
	for i in range(weights.size()):
		roll -= weights[i]
		if roll <= 0.0:
			pick = i
			break
	var side = zones[pick][0]
	var hc = zones[pick][1]
	var tx = rand_range(-0.7, 0.7)
	if side != 0:
		tx = side * rand_range(2.3, 3.3)
	var ty = [rand_range(0.3, 0.6), rand_range(0.9, 1.4), rand_range(1.8, 2.25)][hc]
	ai_plan = {"tx": tx, "ty": ty, "power": rand_range(0.58, 0.9), "delay": rand_range(1.0, 1.7)}


func _update_aim(delta):
	if _is_human(shooter):
		var d = _dir_for(shooter)
		aim.x = clamp(aim.x + d.x * 2.8 * delta, -GOAL_HALF - 0.5, GOAL_HALF + 0.5)
		aim.y = clamp(aim.y - d.y * 1.9 * delta, 0.1, GOAL_TOP + 0.4)
		var held = _shoot_held(shooter)
		if not held:
			armed = true
			if charging:
				var pw = power if charge_t > 0.12 else 0.55
				_fire(pw)
				return
		elif armed:
			charging = true
			charge_t += delta
			power = clamp(charge_t / 1.0, 0.0, 1.0)
		if phase_t > AIM_TIMEOUT:
			_fire(0.6)
	else:
		aim = aim.linear_interpolate(Vector2(ai_plan["tx"], ai_plan["ty"]), 0.08)
		if phase_t >= ai_plan["delay"]:
			aim = Vector2(ai_plan["tx"], ai_plan["ty"])
			_fire(ai_plan["power"])


# the shot is struck: accuracy depends on power (green zone is best)
func _fire(pw):
	var sigma = 0.10 + max(0.0, pw - 0.85) * 4.0 + max(0.0, 0.45 - pw) * 0.8
	var nx = (randf() + randf() - 1.0) * sigma * 1.5
	var ny = (randf() + randf() - 1.0) * sigma
	shot = {
		"tx": aim.x + nx,
		"ty": clamp(aim.y + ny, 0.05, 3.6),
		"T": lerp(0.95, 0.42, pw),
		"loft": 0.18 * (1.0 - pw) + 0.05
	}
	power = pw
	charging = false
	phase = "run"
	phase_t = 0.0


func _launch():
	phase = "flight"
	phase_t = 0.0
	launch_clock = clock
	if kicker_node != null:
		kicker_node.kick_cd = 0.35
	if not _is_human(1 - shooter):
		_plan_ai_keeper()


func _flight_pos(u):
	var x = lerp(0.0, shot["tx"], u)
	var y = lerp(BALL_R, shot["ty"], u) + shot["loft"] * sin(PI * u)
	var z = lerp(0.0, GOAL_Z - 0.5, u)
	return Vector3(x, y, z)


# the ball reaches the goal: keeper, woodwork or net?
func _resolve():
	var tx = shot["tx"]
	var ty = shot["ty"]
	var ks = _keeper_state(launch_clock + shot["T"])
	var inside = abs(tx) < GOAL_HALF - 0.1 and ty < GOAL_TOP - 0.1 and ty > 0.0
	var post = abs(abs(tx) - GOAL_HALF) < 0.16 and ty < GOAL_TOP + 0.1
	var bar = abs(ty - GOAL_TOP) < 0.16 and abs(tx) < GOAL_HALF
	var vel = (_flight_pos(1.0) - _flight_pos(0.96)) / (0.04 * shot["T"])
	ball = _flight_pos(1.0)
	ball_v = vel
	if not (inside or post or bar):
		outcome = "MISS"
		msg_text = "OVER!" if ty > GOAL_TOP else "WIDE!"
		msg_col = Color(1.0, 0.45, 0.35)
	elif abs(tx - ks["x"]) < ks["hw"] and abs(ty - ks["ky"]) < ks["hh"]:
		outcome = "SAVED"
		msg_text = "SAVED!"
		msg_col = Color(0.4, 0.8, 1.0)
		var side = 1.0 if randf() < 0.5 else -1.0
		ball_v = Vector3(side * rand_range(1.5, 3.0), rand_range(1.5, 3.0), -rand_range(2.5, 4.5))
	elif post:
		outcome = "POST"
		msg_text = "OFF THE POST!"
		msg_col = Color(1.0, 0.85, 0.3)
		ball_v = Vector3(-sign(tx) * rand_range(2.0, 4.0), vel.y * 0.3, -rand_range(3.0, 6.0))
		shake = 0.5
	elif bar:
		outcome = "BAR"
		msg_text = "OFF THE BAR!"
		msg_col = Color(1.0, 0.85, 0.3)
		ball_v = Vector3(vel.x * 0.3, -rand_range(2.0, 4.0), -rand_range(3.0, 6.0))
		shake = 0.5
	else:
		outcome = "GOAL"
		msg_text = "GOAL!"
		msg_col = Color(0.4, 1.0, 0.5)
		goals[shooter] += 1
		cheer_t = 2.6
		net_shake = 1.0
	marks[shooter].append("O" if outcome == "GOAL" else "X")
	phase = "result"
	phase_t = 0.0


# simple physics for the ball after it reaches the goal (net, deflections, bounces)
func _step_ball(delta):
	if outcome == "":
		return
	ball += ball_v * delta
	ball_v.y -= 9.8 * delta
	if ball.y < BALL_R:
		ball.y = BALL_R
		if abs(ball_v.y) > 0.6:
			ball_v.y = -ball_v.y * 0.5
		else:
			ball_v.y = 0.0
		ball_v.x *= 0.93
		ball_v.z *= 0.93
	if outcome == "GOAL":
		var back = GOAL_Z + NET_DEPTH - 0.25
		if ball.z > back:
			ball.z = back
			ball_v.z = -ball_v.z * 0.12
			ball_v.x *= 0.4
			net_shake = max(net_shake, 0.8)
		ball.x = clamp(ball.x, -GOAL_HALF + 0.2, GOAL_HALF - 0.2)
	spin += delta * 6.0


func _next_kick():
	if _should_finish():
		phase = "over"
		phase_t = 0.0
		return
	kick += 1
	_begin_kick()


func _should_finish():
	var taken0 = marks[0].size()
	var taken1 = marks[1].size()
	if taken0 < KICKS or taken1 < KICKS:
		var remaining0 = max(0, KICKS - taken0)
		var remaining1 = max(0, KICKS - taken1)
		if goals[0] > goals[1] + remaining1:
			return true
		if goals[1] > goals[0] + remaining0:
			return true
		return false
	return taken0 == taken1 and goals[0] != goals[1]


# ------------------------------------------------------------ keeper

# where his hands / body can reach at time t (a late dive has not got there yet)
func _keeper_state(t):
	if dive == null:
		return {"x": keeper_x, "ky": 1.0, "hh": 1.05, "hw": 0.95, "e": 0.0}
	var p = clamp((t - dive["t0"]) / DIVE_T, 0.0, 1.0)
	var e = 1.0 - pow(1.0 - p, 2.0)
	var side = dive["side"]
	var ky_end = 1.85 if dive["high"] else 0.55
	var hh_end = 0.85 if dive["high"] else 0.65
	var hw_end = 1.2
	if side == 0:
		ky_end = 1.9
		hh_end = 0.8
		hw_end = 0.95
	return {
		"x": lerp(dive["x0"], side * 2.7, e),
		"ky": lerp(1.0, ky_end, e),
		"hh": lerp(1.05, hh_end, e),
		"hw": lerp(0.95, hw_end, e),
		"e": e
	}


func _start_dive(side, high):
	if dive != null:
		return
	if side == 0:
		high = true     # straight up = a jump
	dive = {"side": side, "high": high, "t0": clock, "x0": keeper_x}


# human keeper: left / right to dive, up for high (or a jump). Only once the shot is on its way
# (in 1 player mode against the AI he may also guess early).
func _keeper_input(delta):
	if dive != null or phase == "over" or phase == "result":
		return
	var team = 1 - shooter
	if not _is_human(team):
		return
	var allowed = phase == "run" or phase == "flight" or (phase == "aim" and not _is_human(shooter))
	if not allowed:
		pend = -1.0
		return
	var d = _dir_for(team)
	var wants_side = abs(d.x) > 0.3
	var wants_high = d.y < -0.4
	if pend < 0.0:
		if wants_side or wants_high:
			pend = 0.08
			pend_side = 0
			pend_high = false
	if pend >= 0.0:
		if wants_side:
			pend_side = 1 if d.x > 0.0 else -1
		if wants_high:
			pend_high = true
		pend -= delta
		if pend <= 0.0:
			pend = -1.0
			if pend_side != 0 or pend_high:
				_start_dive(pend_side, pend_high)


func _plan_ai_keeper():
	var side = 0
	var high = randf() < 0.5
	var r = randf()
	if r < 0.38:
		side = -1
	elif r < 0.76:
		side = 1
	elif randf() < 0.5:
		side = 0
	else:
		side = 9                         # stays where he is
	if randf() < AI_READ:                # sometimes he reads the shot
		side = 0
		if abs(shot["tx"]) > 1.0:
			side = 1 if shot["tx"] > 0.0 else -1
		high = shot["ty"] > 1.3
	ai_keeper = {"t": launch_clock + rand_range(0.02, 0.16), "side": side, "high": high, "done": false}


func _ai_keeper_step():
	if ai_keeper.empty() or ai_keeper["done"] or phase != "flight":
		return
	if clock >= ai_keeper["t"]:
		ai_keeper["done"] = true
		if ai_keeper["side"] != 9:
			_start_dive(ai_keeper["side"], ai_keeper["high"])


# ------------------------------------------------------------ placing the stickmen

func _place(node, x, y, z, height_m):
	var pr = proj(x, y, z)
	var k = pr.z * height_m / 38.0
	node.scale = Vector2(k, k)
	node.position = Vector2(pr.x, pr.y - 5.0 * k)


func _update_figures(delta):
	# kicker: waits, then runs up diagonally to the ball
	if kicker_node != null:
		kicker_node.kick_cd = max(0.0, kicker_node.kick_cd - delta)
		var kx = -1.35
		var kz = -2.6
		kicker_node.vel = Vector2.ZERO
		if phase == "run":
			var e = clamp(phase_t / RUN_T, 0.0, 1.0)
			e = 1.0 - pow(1.0 - e, 2.0)
			kx = lerp(-1.35, -0.5, e)
			kz = lerp(-2.6, -0.6, e)
			kicker_node.vel = Vector2(0.0, -170.0)
		elif phase == "flight" or phase == "result" or phase == "over":
			kx = -0.5
			kz = -0.6
		_place(kicker_node, kx, 0.0, kz, 1.78)

	# keeper: bounces on his line, then dives
	if keeper_node != null:
		var ks = _keeper_state(clock)
		var foot_x = ks["x"]
		var lift = 0.0
		keeper_node.is_diving = false
		keeper_node.vel = Vector2.ZERO
		if dive != null:
			var side = dive["side"]
			keeper_node.is_diving = true
			if side == 0:
				keeper_node.dive_dir = Vector2(0.0, -1.0)
				lift = 0.55 * ks["e"]
			elif dive["high"]:
				keeper_node.dive_dir = Vector2(side * 0.9, -0.45).normalized()
				foot_x = ks["x"] - side * 0.95 * ks["e"]
				lift = 0.7 * ks["e"]
			else:
				keeper_node.dive_dir = Vector2(side, -0.12).normalized()
				foot_x = ks["x"] - side * 0.95 * ks["e"]
				lift = 0.12 * ks["e"]
		_place(keeper_node, foot_x, lift, GOAL_Z - 0.4, 2.0)


# ------------------------------------------------------------ drawing: the scenery (behind the keeper)

func _line3(c, a, b, col, wm):
	var az = max(a.z, CAM_Z + 1.0)
	var bz = max(b.z, CAM_Z + 1.0)
	var pa = proj(a.x, a.y, az)
	var pb = proj(b.x, b.y, bz)
	var w = max(1.5, wm * (pa.z + pb.z) * 0.5)
	c.draw_line(Vector2(pa.x, pa.y), Vector2(pb.x, pb.y), col, w)


func draw_back(c):
	var x0 = -pad
	var w = VW + pad * 2.0

	# stands
	c.draw_rect(Rect2(x0, 0.0, w, HORIZON), Color(0.05, 0.06, 0.13))
	for i in range(crowd_pos.size()):
		var pt = crowd_pos[i]
		if cheer_t > 0.0:
			pt.y -= abs(sin(clock * 9.0 + pt.x * 0.07)) * 4.0
		c.draw_circle(pt, 3.2, crowd_col[i])
	c.draw_rect(Rect2(x0, HORIZON - 16.0, w, 16.0), Color(0.10, 0.10, 0.16))     # advertising boards

	# grass with mowing stripes (every stripe is a band of constant depth, so it is a plain rectangle)
	c.draw_rect(Rect2(x0, HORIZON, w, VH - HORIZON + 30.0), Color(0.16, 0.48, 0.23))
	var z = -8.25
	var idx = 0
	while z < 70.0:
		var z0 = max(z, CAM_Z + 0.4)
		var z1 = z + 2.75
		if z1 > CAM_Z + 0.4:
			var y_far = proj(0.0, 0.0, z1).y
			var y_near = min(proj(0.0, 0.0, z0).y, VH + 30.0)
			var col = Color(0.15, 0.46, 0.22) if idx % 2 == 0 else Color(0.19, 0.53, 0.27)
			c.draw_rect(Rect2(x0, y_far, w, y_near - y_far + 1.0), col)
		z += 2.75
		idx += 1

	# pitch markings
	var white = Color(1, 1, 1, 0.9)
	c.draw_line(Vector2(x0, proj(0.0, 0.0, GOAL_Z).y), Vector2(x0 + w, proj(0.0, 0.0, GOAL_Z).y), white, max(1.5, 0.12 * proj(0.0, 0.0, GOAL_Z).z))
	_line3(c, Vector3(-9.16, 0, GOAL_Z - 5.5), Vector3(9.16, 0, GOAL_Z - 5.5), white, 0.12)       # 6-yard box
	_line3(c, Vector3(-9.16, 0, GOAL_Z - 5.5), Vector3(-9.16, 0, GOAL_Z), white, 0.12)
	_line3(c, Vector3(9.16, 0, GOAL_Z - 5.5), Vector3(9.16, 0, GOAL_Z), white, 0.12)
	_line3(c, Vector3(-20.16, 0, GOAL_Z - 16.5), Vector3(-20.16, 0, GOAL_Z), white, 0.12)        # 18-yard box
	_line3(c, Vector3(20.16, 0, GOAL_Z - 16.5), Vector3(20.16, 0, GOAL_Z), white, 0.12)
	var sp = proj(0.0, 0.0, 0.0)                                                                    # penalty spot
	c.draw_set_transform(Vector2(sp.x, sp.y), 0.0, Vector2(1.0, 0.35))
	c.draw_circle(Vector2.ZERO, 0.22 * sp.z, white)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# the net (a grid on the back plane, side and roof lines) and the frame
	var zb = GOAL_Z + NET_DEPTH
	var net = Color(1, 1, 1, 0.30)
	var gx = -GOAL_HALF
	while gx <= GOAL_HALF + 0.01:
		c.draw_line(_net_pt(gx, 0.0, zb), _net_pt(gx, GOAL_TOP, zb), net, 1.0)
		gx += 0.4
	var gy = 0.0
	while gy <= GOAL_TOP + 0.01:
		c.draw_line(_net_pt(-GOAL_HALF, gy, zb), _net_pt(GOAL_HALF, gy, zb), net, 1.0)
		gy += 0.4
	for sgn in [-1.0, 1.0]:
		for yy in [0.0, 0.6, 1.2, 1.8, GOAL_TOP]:
			_line3(c, Vector3(sgn * GOAL_HALF, yy, GOAL_Z), Vector3(sgn * GOAL_HALF, yy, zb), net, 0.0)
	var rx = -GOAL_HALF
	while rx <= GOAL_HALF + 0.01:
		_line3(c, Vector3(rx, GOAL_TOP, GOAL_Z), Vector3(rx, GOAL_TOP, zb), net, 0.0)
		rx += 0.8
	var frame = Color(0.97, 0.97, 0.97)
	_line3(c, Vector3(-GOAL_HALF, 0, GOAL_Z), Vector3(-GOAL_HALF, GOAL_TOP, GOAL_Z), frame, 0.13)
	_line3(c, Vector3(GOAL_HALF, 0, GOAL_Z), Vector3(GOAL_HALF, GOAL_TOP, GOAL_Z), frame, 0.13)
	_line3(c, Vector3(-GOAL_HALF, GOAL_TOP, GOAL_Z), Vector3(GOAL_HALF, GOAL_TOP, GOAL_Z), frame, 0.13)


func _net_pt(x, y, z):
	var p = proj(x, y, z)
	return Vector2(p.x + sin(clock * 38.0 + y * 6.0 + x * 3.0) * net_shake * 4.0, p.y)


# ------------------------------------------------------------ drawing: ball, aim, HUD (in front of the keeper)

func _text(c, font, text, pos, col, centered):
	var p = pos
	if centered:
		p.x -= font.get_string_size(text).x * 0.5
	c.draw_string(font, p + Vector2(2.0, 2.0), text, Color(0, 0, 0, 0.85))
	c.draw_string(font, p, text, col)


func draw_front(c):
	# ---- ball (with its shadow on the grass, so you can read its height)
	var bp = proj(ball.x, ball.y, ball.z)
	var gp = proj(ball.x, 0.0, ball.z)
	var br = max(2.5, BALL_R * bp.z)
	c.draw_set_transform(Vector2(gp.x, gp.y), 0.0, Vector2(1.0, 0.35))
	c.draw_circle(Vector2.ZERO, br * 1.15, Color(0, 0, 0, 0.35))
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	c.draw_circle(Vector2(bp.x, bp.y), br + 1.5, Color(0.1, 0.1, 0.1))
	c.draw_circle(Vector2(bp.x, bp.y), br, Color(0.98, 0.98, 0.98))
	c.draw_circle(Vector2(bp.x, bp.y) + Vector2(cos(spin), sin(spin)) * br * 0.38, br * 0.28, Color(0.15, 0.15, 0.15))

	# ---- aim reticle on the goal face
	if phase == "aim" and _is_human(shooter):
		var pr = proj(aim.x, aim.y, GOAL_Z)
		var r = max(12.0, 0.3 * pr.z) * (1.0 + 0.08 * sin(clock * 8.0))
		var cc = Vector2(pr.x, pr.y)
		c.draw_arc(cc, r, 0.0, TAU, 24, Color(1.0, 0.9, 0.2, 0.95), 2.5)
		c.draw_line(cc + Vector2(-r - 6.0, 0.0), cc + Vector2(-r + 5.0, 0.0), Color(1.0, 0.9, 0.2), 2.0)
		c.draw_line(cc + Vector2(r + 6.0, 0.0), cc + Vector2(r - 5.0, 0.0), Color(1.0, 0.9, 0.2), 2.0)
		c.draw_line(cc + Vector2(0.0, -r - 6.0), cc + Vector2(0.0, -r + 5.0), Color(1.0, 0.9, 0.2), 2.0)
		c.draw_line(cc + Vector2(0.0, r + 6.0), cc + Vector2(0.0, r - 5.0), Color(1.0, 0.9, 0.2), 2.0)

	# ---- power bar
	if phase == "aim" and _is_human(shooter):
		var bx = VW * 0.5 - 150.0
		var by = 470.0
		c.draw_rect(Rect2(bx - 3.0, by - 3.0, 306.0, 22.0), Color(0, 0, 0, 0.7))
		c.draw_rect(Rect2(bx, by, 300.0, 16.0), Color(0.2, 0.2, 0.25))
		c.draw_rect(Rect2(bx + 300.0 * 0.55, by, 300.0 * 0.30, 16.0), Color(0.2, 0.6, 0.3, 0.8))
		var fc = Color(1.0, 0.85, 0.2)
		if power >= 0.55 and power <= 0.85:
			fc = Color(0.4, 1.0, 0.5)
		elif power > 0.85:
			fc = Color(1.0, 0.35, 0.3)
		c.draw_rect(Rect2(bx, by, 300.0 * power, 16.0), fc)
		_text(c, font_small, "POWER", Vector2(VW * 0.5, 462.0), Color.white, true)

	# ---- scoreboard: score and a dot per kick
	var score_txt = "%s  %d - %d  %s" % [_team_tag(0), goals[0], goals[1], _team_tag(1)]
	_text(c, font_mid, score_txt, Vector2(VW * 0.5, 30.0), Color.white, true)
	_text(c, font_small, "PENALTY SHOOTOUT" + ("  -  SUDDEN DEATH" if kick >= KICKS * 2 else ""), Vector2(VW * 0.5, 50.0), Color(1, 1, 1, 0.75), true)
	for team in range(2):
		var y = 70.0 + team * 20.0
		c.draw_rect(Rect2(VW * 0.5 - 150.0, y - 11.0, 12.0, 12.0), _team_col(team))
		_text(c, font_small, _team_tag(team), Vector2(VW * 0.5 - 132.0, y), Color.white, false)
		var n = max(KICKS, marks[team].size())
		for i in range(n):
			var cc = Vector2(VW * 0.5 - 70.0 + i * 22.0, y - 5.0)
			if i < marks[team].size():
				c.draw_circle(cc, 7.5, Color(0.35, 0.95, 0.45) if marks[team][i] == "O" else Color(0.95, 0.3, 0.3))
			else:
				c.draw_arc(cc, 7.0, 0.0, TAU, 16, Color(1, 1, 1, 0.5), 1.5)

	# ---- messages
	if phase == "ready":
		var shooter_name = Game.team_name(Game.home_id if shooter == 0 else Game.away_id).to_upper()
		_text(c, font_mid, "PENALTY %d" % (kick + 1), Vector2(VW * 0.5, 112.0), Color(1, 1, 1, 0.9), true)
		_text(c, font_big, shooter_name + " TO SHOOT", Vector2(VW * 0.5, 420.0), Color(1.0, 0.9, 0.3), true)
	elif phase == "result":
		var pop = 1.0 + 0.35 * max(0.0, 1.0 - phase_t * 5.0)
		c.draw_set_transform(Vector2(VW * 0.5, 410.0), 0.0, Vector2(pop, pop))
		_text(c, font_big, msg_text, Vector2(0.0, 0.0), msg_col, true)
		c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	elif phase == "over":
		var win = 0 if goals[0] > goals[1] else 1
		var wname = Game.team_name(Game.home_id if win == 0 else Game.away_id).to_upper()
		_text(c, font_big, wname + " WIN!", Vector2(VW * 0.5, 400.0), Color(0.4, 1.0, 0.5), true)
		_text(c, font_mid, "%d - %d ON PENALTIES" % [goals[0], goals[1]], Vector2(VW * 0.5, 432.0), Color.white, true)

	# ---- controls hint
	if phase == "ready" or phase == "aim":
		var lines = []
		if _is_human(shooter):
			lines.append("SHOOT: " + _aim_keys(shooter) + " aim   -   hold " + _shoot_key(shooter) + " to power up, release to shoot")
		if _is_human(1 - shooter):
			lines.append("KEEPER: " + _dive_keys(1 - shooter))
		for i in range(lines.size()):
			_text(c, font_small, lines[i], Vector2(VW * 0.5, 506.0 + i * 16.0), Color(1, 1, 1, 0.85), true)


func _aim_keys(team):
	if not Game.two_player:
		return "WASD / ARROWS"
	return "WASD" if team == 0 else "ARROWS"


func _shoot_key(team):
	if not Game.two_player:
		return "SPACE"
	return "F" if team == 0 else "ENTER"


func _dive_keys(team):
	var k = "LEFT / RIGHT dive, UP = high or jump"
	if not Game.two_player:
		return "A D / ARROWS dive, W / UP = high or jump"
	if team == 0:
		return "A / D dive, W = high or jump"
	return k
