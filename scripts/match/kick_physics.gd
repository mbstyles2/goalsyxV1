extends Reference
# BALL PHYSICS for kicks: turns "where and how hard" into launch speed, loft and curve that obey the
# match's real ball model, so a pass arrives where it was meant to and a shot crosses the line at the
# height it was meant to.
#
# The match model (match._update_ball + ball.gd), which every formula below mirrors:
#   * horizontal speed decays as v * f^(rate * t). rate = 1 on the ground and AIR_DRAG in the air, blended by
#     height: air_t = clamp(height_z / AIR_BLEND_H, 0, 1). k = -ln f, so a ball launched at v0 covers
#     v0 * (1 - e^(-k t)) / k.
#   * height is a plain parabola: impulse_z(vz), constant gravity (ball.gravity()), hang time 2 * vz / g,
#     apex vz^2 / 2g.
#   * a landing costs horizontal speed in proportion to its vertical speed (ball.BOUNCE_FRICTION).
# Because drag depends on how high the ball is, the drag a kick will feel is a function of its ARC (its apex).
# k_flight(apex) is that function; the planner and the ball use the same blend, so they cannot disagree.

const GRAV_DEFAULT = 320.0

# Apex ceilings (px of height) for kicks that are not lofted. They are ceilings on the ARC the kick draws, derived
# from what the game treats as playable height, not a flat clamp on the impulse:
#   players cannot touch a ball above 32 px, the crossbar is match.CROSSBAR_Z (60 px).
const PASS_APEX = 8.0     # ground / driven pass: skims the turf
const SHOT_APEX = 30.0    # driven shot: stays playable for the keeper's reach and well under the bar

const DEBUG_KICKS = false  # true: print what every kick is expected to do

var m
var g_est = GRAV_DEFAULT
var curve_acc = 0.0
var curve_t = 0.0
var curve_owner = null


func _init(match_node):
	m = match_node


# ------------------------------------------------------------ the ball model

func k_ground():
	var f = clamp(float(m.active_pitch_data.get("friction", 0.4)), 0.05, 0.98)
	return -log(f)


# decay rate while the ball is fully in the air
func k_air():
	return k_ground() * m.AIR_DRAG


# fraction of a parabolic flight with the given apex that the ball spends "in the air" for drag purposes
# (average of clamp(h / AIR_BLEND_H, 0, 1) over the arc; 8 samples is plenty)
func air_share(apex):
	var s = 0.0
	for i in range(8):
		var u = (i + 0.5) / 8.0
		s += min(1.0, 4.0 * u * (1.0 - u) * apex / m.AIR_BLEND_H)
	return s / 8.0


# average decay rate of a flight whose highest point is `apex`
func k_flight(apex):
	return lerp(k_ground(), k_air(), air_share(apex))


# kept for older callers: the hint is the height the arc reaches
func k_for(height_hint):
	return k_flight(height_hint)


func gravity():
	var b = m.ball
	if b != null and b.has_method("gravity"):
		return b.gravity()
	return g_est


# gravity is read straight from ball.gd now; nothing to measure (old callers may still call this)
func calibrate(_delta):
	return


func apex_of(vz):
	return vz * vz / (2.0 * gravity())


func vz_for_apex(apex):
	return sqrt(2.0 * gravity() * apex)


# [hang time, landing distance, apex] a ball launched at v0 with vertical impulse vz will have (first landing)
func predict(v0, vz):
	if vz <= 0.0:
		return [0.0, 0.0, 0.0]
	var t_air = 2.0 * vz / gravity()
	var apex = apex_of(vz)
	var kk = k_flight(apex)
	return [t_air, v0 * (1.0 - exp(-kk * t_air)) / kk, apex]


# ------------------------------------------------------------ solving launch values

# launch speed that makes a ball cover d and still be moving at `arrive` when it gets there.
# vz = the vertical impulse it will be kicked with (0 = a ball that rolls the whole way)
func ground_speed(d, arrive, vz = 0.0):
	return clamp(arrive + k_flight(apex_of(vz)) * d, 150.0, m.MAX_BALL_SPEED)


# how long a ball launched at v0 takes to cover d (3.0 = it never gets there)
func travel_time(d, v0, kk = -1.0):
	if kk < 0.0:
		kk = k_ground()
	var ratio = 1.0 - kk * d / max(v0, 1.0)
	if ratio < 0.03:
		return 3.0
	return -log(ratio) / kk


# lofted ball landing about d away after T seconds in the air -> [launch speed, vertical impulse, hang time used]
# A long ball cannot be hit harder than the speed limit, so instead of falling short it is lobbed higher and hangs
# longer. The drag is that of the arc actually drawn (k_flight), so the first landing is where it was planned.
func lob(d, T):
	var g = gravity()
	var vmax = m.MAX_BALL_SPEED * 0.97
	var kk = k_flight(g * T * T / 8.0)
	var need = d * kk / vmax                     # (1 - e^-kT) has to be at least this for the ball to get there
	if need < 0.95:
		T = max(T, -log(1.0 - need) / kk)
	T = min(T, 2.2)
	kk = k_flight(g * T * T / 8.0)
	var v0 = d * kk / max(1.0 - exp(-kk * T), 0.05)
	return [min(v0, m.MAX_BALL_SPEED), g * T * 0.5, T]


# vertical impulse for a driven shot: reach height target_z when the ball gets to distance d at launch speed v0,
# but never draw an arc higher than apex_cap. When the distance is too long to do both, the ball is allowed to
# come down early and run on low (a skimming drive) instead of ballooning to meet the target at the far end.
func shot_vz(v0, d, target_z, apex_cap = -1.0):
	# Ground-level shots should remain driven.
	if target_z <= 2.0:
		return 0.0
	if apex_cap < 0.0:
		apex_cap = SHOT_APEX
	var g = gravity()
	var cap = vz_for_apex(apex_cap)
	var vz = cap
	# the drag depends on the arc and the arc on the drag: a few passes settle it
	for i in range(4):
		var t = max(travel_time(d, v0, k_flight(apex_of(vz))), 0.12)
		vz = min((target_z + 0.5 * g * t * t) / t, cap)
	return max(vz, 0.0)


# ------------------------------------------------------------ executing a kick

# the foot meets the ball: apply the plan to the real ball
func release(p, plan):
	var lift = max(float(plan["lift"]), 0.0)

	# A kick that is not lofted may not draw an arc above its class ceiling. This limits the arc (what the kick is),
	# not a flat number for every kick, and lofted passes / crosses are untouched.
	if not plan["lofted"]:
		var apex_max = SHOT_APEX if plan["is_shot"] else PASS_APEX
		lift = min(lift, vz_for_apex(apex_max))

	if DEBUG_KICKS:
		var pr = predict(plan["speed"], lift)
		print("KICK ", "lofted" if plan["lofted"] else ("shot" if plan["is_shot"] else "pass"),
			" v0=", int(plan["speed"]), " vz=", int(lift), " apex=", stepify(pr[2], 0.1),
			" hang=", stepify(pr[0], 0.01), "s lands@", int(pr[1]), "px (planned dist ", int(plan["dist"]), ")")

	m._kick_apply(
		p,
		plan["dir"],
		plan["speed"],
		lift,
		plan["delay"] <= 0.0
	)
	curve_acc = plan["curve"]
	curve_t = 0.9 if plan["curve"] != 0.0 else 0.0
	curve_owner = p
	var mate = plan["mate"]
	if mate != null and is_instance_valid(mate):
		var t
		if plan["lofted"]:
			t = plan["T"] + 0.5
		else:
			t = travel_time(plan["dist"], plan["speed"], k_flight(apex_of(lift)))
		m.pass_target = mate
		m.pass_t = clamp(t + 0.4, 0.8, 2.8)
	if plan["record"] and m.ui_controller:
		if plan["is_shot"]:
			m.ui_controller.record_shot(p.team)
		else:
			m.ui_controller.record_pass(p.team)


# bend: a sideways pull on the flying ball (called from match._update_ball); ends as soon as anyone touches it
func apply_curve(delta):
	if curve_t <= 0.0 or curve_acc == 0.0:
		return
	if m.last_touch != curve_owner:
		curve_t = 0.0
		return
	var v = m.ball.vel
	if v.length() < 60.0:
		curve_t = 0.0
		return
	m.ball.vel += Vector2(-v.y, v.x).normalized() * curve_acc * delta
	curve_t -= delta
