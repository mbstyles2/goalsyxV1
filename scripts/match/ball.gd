extends Node2D

var vel = Vector2.ZERO

# --- 2.5D Height Simulation Properties ---
var height_z = 0.0          # height above the pitch in pixels
var vel_z = 0.0             # vertical velocity (positive = rising)
var frozen = false          # true while replay.gd plays a clip: the height physics must not run
const GRAVITY = 320.0       # gravity acceleration (px/s^2)  (unchanged)
const BOUNCE_DAMP = 0.35    # vertical restitution: a landing at speed s hops back up at s * BOUNCE_DAMP
const MIN_BOUNCE_SPEED = 55.0   # below this landing speed the ball settles instead of hopping

# Horizontal speed lost on landing = BOUNCE_FRICTION * impact + BOUNCE_FRICTION_STEEP * impact^2 (impact = vertical
# landing speed), never more than 65 %. A shallow landing (a low driven ball) keeps almost all of its pace; a steep one
# (a lob, a goal-kick) gives up a lot, so a lofted ball runs on ~55-90 px after it lands, like the old ball did.
# Continuous: there is no impact speed at which the ball suddenly loses 65 %. These two are the "how lively is a
# landing" knobs.
const BOUNCE_FRICTION = 0.45
const BOUNCE_FRICTION_STEEP = 0.0035
const BOUNCE_KEEP_MIN = 0.35


# The height model runs on the SAME fixed tick as match.gd's _update_ball (horizontal motion + drag), not on the
# render frame, so a kick flies the same arc at 30, 60 or 144 fps.
func _physics_process(delta):
	if frozen:
		return
	_update_height(delta)


func _process(delta):
	update()


func _update_height(delta):
	if height_z <= 0.0 and vel_z == 0.0:
		return
	# exact step for constant gravity: the arcs kick_physics.gd plans (hang time = 2 * vz / g) are reproduced
	# to within one tick, instead of landing a frame early with semi-implicit Euler
	var new_h = height_z + vel_z * delta - 0.5 * GRAVITY * delta * delta
	var new_vz = vel_z - GRAVITY * delta
	if new_h > 0.0:
		height_z = new_h
		vel_z = new_vz
		return
	_land(abs(new_vz))


func _land(impact):
	height_z = 0.0
	var sp = vel.length()
	if sp > 0.001 and impact > 0.0:
		var kept = max(sp - BOUNCE_FRICTION * impact - BOUNCE_FRICTION_STEEP * impact * impact, sp * BOUNCE_KEEP_MIN)
		vel *= kept / sp
	if impact > MIN_BOUNCE_SPEED:
		vel_z = impact * BOUNCE_DAMP
	else:
		vel_z = 0.0


func impulse_z(upward_speed: float):
	vel_z = max(vel_z, upward_speed)


# the ball is on the pitch: no height AND no vertical speed (setting height_z alone leaves vel_z behind,
# and the leftover speed re-launches or bounces the ball on the next tick)
func ground():
	height_z = 0.0
	vel_z = 0.0


# single source of truth for gravity (kick_physics.gd reads this instead of estimating it)
func gravity():
	return GRAVITY


func _draw():
	# Height-aware shadow on pitch surface
	var shadow_offset = Vector2(height_z * 0.3, height_z * 0.5 + 3.0)
	var shadow_radius = max(2.5, 4.0 - height_z * 0.08)
	var shadow_alpha = clamp(0.35 - height_z * 0.003, 0.08, 0.35)
	
	draw_circle(shadow_offset, shadow_radius, Color(0, 0, 0, shadow_alpha))
	
	# Render ball graphics offset upward by height_z
	var ball_draw_pos = Vector2(0, -height_z)
	var ball_radius = 6.0 + clamp(height_z * 0.02, 0.0, 3.0)
	
	# Main white sphere
	draw_circle(ball_draw_pos, ball_radius, Color(1, 1, 1))
	
	# Outer outline
	draw_arc(ball_draw_pos, ball_radius, 0, TAU, 24, Color(0.1, 0.1, 0.1), 1.8)
	
	# Pattern accent to show spin/direction
	var spin_angle = OS.get_ticks_msec() * 0.005 * (vel.length() / 100.0)
	var patch_pos = ball_draw_pos + Vector2(cos(spin_angle), sin(spin_angle)) * (ball_radius * 0.35)
	draw_circle(patch_pos, ball_radius * 0.32, Color(0.12, 0.12, 0.15))
