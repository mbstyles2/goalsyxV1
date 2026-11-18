extends Reference
# INPUT layer for passing and shooting. It only turns button states into kick EVENTS - no game logic.
#
#   press a kick button and hold  -> power charges (0.12 .. 1.0 over CHARGE_T seconds)
#   release                       -> an event {kind, power, aim, held, tap} is returned
#   quick tap                     -> a sensible default power for that kind of kick
#
# Kinds: "shoot", "pass", "through", "cross". The aim is the direction you are holding
# (the last direction held a moment ago counts too, so letting go of the stick as you
# release the button does not lose it).

const CHARGE_T = 0.8            # seconds to full power
const TAP_T = 0.16              # shorter than this = a tap
const MIN_POWER = 0.12
const KINDS = ["shoot", "pass", "through", "cross"]
const TAP_POWER = {"shoot": 0.62, "pass": 0.5, "through": 0.5, "cross": 0.55}

var hold = [0.0, 0.0]
var charging = ["", ""]         # which kick is being charged, per team ("" = none)
var charge = [0.0, 0.0]         # current power 0..1 (for the HUD)
var aim_mem = [Vector2.ZERO, Vector2.ZERO]
var aim_age = [9.0, 9.0]


func cancel(team):
	charging[team] = ""
	hold[team] = 0.0
	charge[team] = 0.0


func power_at(t):
	return clamp(MIN_POWER + (1.0 - MIN_POWER) * (t / CHARGE_T), MIN_POWER, 1.0)


# buttons: {"shoot": bool, "pass": bool, "through": bool, "cross": bool}; aim: movement direction or ZERO.
# Returns an event dictionary on the frame a kick button is released, otherwise null.
func update(team, buttons, aim, delta):
	if aim != Vector2.ZERO:
		aim_mem[team] = aim.normalized()
		aim_age[team] = 0.0
	else:
		aim_age[team] += delta
	var event = null
	if charging[team] == "":
		for k in KINDS:
			if buttons.get(k, false):
				charging[team] = k
				hold[team] = 0.0
				charge[team] = MIN_POWER
				break
	else:
		var k2 = charging[team]
		if buttons.get(k2, false):
			hold[team] += delta
			charge[team] = power_at(hold[team])
		else:
			var tap = hold[team] < TAP_T
			var cur = Vector2.ZERO
			if aim != Vector2.ZERO:
				cur = aim.normalized()
			elif aim_age[team] < 0.15:
				cur = aim_mem[team]
			event = {
				"kind": k2,
				"power": TAP_POWER[k2] if tap else power_at(hold[team]),
				"aim": cur,
				"held": hold[team],
				"tap": tap
			}
			cancel(team)
	return event
