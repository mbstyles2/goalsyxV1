extends Reference
# KICK SYSTEM: ties the four layers together and is the only thing match.gd talks to.
#
#   kick_input.gd   buttons -> events (hold for power, release to kick)        [INPUT]
#   kick_brain.gd   who to pass to, where to shoot, how big the error is       [DECISION]
#   kick_physics.gd launch speed / loft / curve that obey the ball model       [BALL PHYSICS]
#   player.gd       the kicking animation (kick_kind / kick_foot say which)    [ANIMATION]
#
# Flow of a human kick: release -> event -> brain makes a plan -> the player starts his kick animation ->
# the ball leaves at the moment of contact (plan["delay"], about 0.1 s later) -> physics launches it.
# A press made a moment before the ball arrives is buffered (BUFFER_T) so late presses still count.
# AI kicks use the same brain and physics (ai_pass / ai_shoot / ai_clear), so they behave alike.

const KickInput = preload("res://scripts/match/kick_input.gd")
const KickBrain = preload("res://scripts/match/kick_brain.gd")
const KickPhysics = preload("res://scripts/match/kick_physics.gd")

const BUFFER_T = 0.25

var m
var input
var brain
var physics
var pending = {}                # player -> {plan, t, human}  (kicks winding up)
var buffered = [null, null]     # per team: {ev, age}
var last_p = [null, null]
var hud = null


# a Node2D that draws the power bar and aim arrow above the player who is charging a kick
class KickHud extends Node2D:
	var sys

	func _process(_delta):
		update()

	func _draw():
		if sys != null:
			sys.draw_hud(self)


func _init(match_node):
	m = match_node
	input = KickInput.new()
	physics = KickPhysics.new(m)
	brain = KickBrain.new(m)
	brain.phys = physics
	hud = KickHud.new()
	hud.sys = self
	hud.z_index = 210
	m.add_child(hud)


func cancel(team):
	input.cancel(team)
	buffered[team] = null


# ------------------------------------------------------------ human input

# called every frame for the player a human controls (buttons: shoot / pass / through / cross)
func human_frame(p, team, buttons, aim, delta):
	if m.state != "playing":
		cancel(team)
		return
	if last_p[team] != p:
		cancel(team)
		last_p[team] = p
	var ev = input.update(team, buttons, aim, delta)
	if ev != null:
		if _can_kick(p):
			_begin(p, ev)
		else:
			buffered[team] = {"ev": ev, "age": 0.0}
	if buffered[team] != null:
		buffered[team]["age"] += delta
		if buffered[team]["age"] > BUFFER_T:
			buffered[team] = null
		elif _can_kick(p):
			var e = buffered[team]["ev"]
			buffered[team] = null
			_begin(p, e)


func _can_kick(p):
	if pending.has(p) or p.is_tackling:
		return false
	if p.is_gk:
		return true
	if p.kick_cd > 0.0:
		return false
	if m.gk_hold_timer[0] > 0.0 or m.gk_hold_timer[1] > 0.0:
		return false
	return p.position.distance_to(m.ball.position) <= m.PR + m.BR + 14.0


func _begin(p, ev):
	var plan = null
	if ev["kind"] == "shoot":
		plan = brain.plan_shot(p, ev, false, null)
	else:
		plan = brain.plan_pass(p, ev)
	if plan == null:
		return
	if plan["mate"] != null:
		m._check_offside(p, plan["mate"])
	_schedule(p, plan, true)


# ------------------------------------------------------------ AI entry points

# a pass to a chosen team-mate (lift_z > 0 = lofted through ball). Returns true if the kick started.
func ai_pass(p, mate, lead, _jitter, lift_z):
	if mate == null or not is_instance_valid(mate) or not _can_kick(p):
		return false
	_schedule(p, brain.plan_ai_pass(p, mate, lead, lift_z), false)
	return true


# a shot at a goal point the AI chose; speed_hint says how hard it wants to hit it
func ai_shoot(p, target, speed_hint):
	if not _can_kick(p):
		return false
	_schedule(p, brain.plan_ai_shot(p, target, speed_hint), false)
	return true


# a hoof clear towards a point
func ai_clear(p, point):
	if not _can_kick(p):
		return false
	_schedule(p, brain.plan_clear(p, point), false)
	return true


# ------------------------------------------------------------ the wind-up and the moment of contact

func _schedule(p, plan, human):
	p.set("kick_kind", plan["anim"])         # player.gd animates the right kick with the right foot
	p.set("kick_foot", plan["foot"])
	p.kick_cd = 0.35                         # also starts the animation
	if plan["delay"] <= 0.0:
		physics.release(p, plan)
		_after(p, plan, human)
		return
	pending[p] = {"plan": plan, "t": plan["delay"], "human": human}


# public entry for code outside this file (offside-trap / set-piece / AI scripts) that already holds a finished plan from
# kick_brain (plan_ai_pass / plan_ai_shot / plan_clear ...): starts the wind-up exactly like the AI entry points above.
# Returns true if the kick started.
func schedule_plan(p, plan, human = false):
	if p == null or not is_instance_valid(p) or plan == null or not _can_kick(p):
		return false
	_schedule(p, plan, human)
	return true


func _after(p, plan, human):
	if human and plan["mate"] != null and is_instance_valid(plan["mate"]):
		m._set_selected(p.team, plan["mate"])


# called every game tick by match.gd
func tick(delta):
	physics.calibrate(delta)
	for p in pending.keys():
		var e = pending[p]
		e["t"] -= delta
		if e["t"] > 0.0:
			continue
		pending.erase(p)
		if not is_instance_valid(p) or m.state != "playing" or p.is_tackling:
			continue
		# the ball must still be at his feet when the foot swings through (else it is an air kick)
		if not p.is_gk and p.position.distance_to(m.ball.position) > m.PR + m.BR + 20.0:
			continue
		physics.release(p, e["plan"])
		_after(p, e["plan"], e["human"])


# ------------------------------------------------------------ feedback: power bar and aim arrow

func _flat(n):
	var cc = m.camera_controller
	if m.USE_FAKE_3D and cc != null and cc.saved.has(n):
		return cc.saved[n]
	return n.position


func draw_hud(c):
	if m.state != "playing":
		return
	for team in range(2):
		var kind = input.charging[team]
		if kind == "":
			continue
		var p = m.sel[team]
		if p == null or not is_instance_valid(p):
			continue
		var sc = max(p.scale.y, 0.5)
		var cc = m.camera_controller
		var rot = 0.0                                 # how far the view is turned (vertical end-to-end mode)
		if m.USE_FAKE_3D and cc != null and cc.has_method("view_rotation"):
			rot = cc.view_rotation()
		var pw = input.charge[team]
		var col = Color(1, 1, 1)
		var z0 = 0.40
		var z1 = 0.65
		if kind == "shoot":
			col = Color(1.0, 0.55, 0.2)
			z0 = 0.55
			z1 = 0.85
		elif kind == "through":
			col = Color(0.4, 0.9, 1.0)
		elif kind == "cross":
			col = Color(1.0, 0.9, 0.3)

		# power bar with its sweet zone
		var w = 34.0
		var h = 5.0
		c.draw_set_transform(p.position, rot, Vector2.ONE)    # draw the bar upright above the player (see camera.gd: +rot cancels the view turn)
		var x = -w * 0.5
		var top = -58.0 * sc
		c.draw_rect(Rect2(x - 1.5, top - 1.5, w + 3.0, h + 3.0), Color(0, 0, 0, 0.75))
		c.draw_rect(Rect2(x, top, w, h), Color(0.18, 0.18, 0.22))
		c.draw_rect(Rect2(x + w * z0, top, w * (z1 - z0), h), Color(0.2, 0.6, 0.3, 0.85))
		var fill = Color(1.0, 0.85, 0.2)
		if pw >= z0 and pw <= z1:
			fill = Color(0.4, 1.0, 0.5)
		elif pw > z1:
			fill = Color(1.0, 0.35, 0.3)
		c.draw_rect(Rect2(x, top, w * pw, h), fill)
		c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

		# arrow along the direction you are aiming (in the picture, so it works with the fake-3D view)
		var aim = input.aim_mem[team]
		if aim != Vector2.ZERO and input.aim_age[team] < 0.25:
			var flat = _flat(p)
			var tip = flat + aim * (50.0 + 80.0 * pw)
			var b = tip
			if m.USE_FAKE_3D and cc != null:
				b = cc.proj(tip)
			var a = p.position + Vector2(0.0, 5.0 * sc).rotated(rot)
			c.draw_line(a, b, col, 2.0)
			var dirv = (b - a).normalized()
			c.draw_line(b, b - dirv.rotated(0.5) * 7.0, col, 2.0)
			c.draw_line(b, b - dirv.rotated(-0.5) * 7.0, col, 2.0)
