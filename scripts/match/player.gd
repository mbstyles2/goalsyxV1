extends Node2D
# Stickman footballer with procedural animation.
#
# Everything is driven by what the game already tells the player (vel, facing, kick_cd, is_tackling,
# is_diving, jump_height ...) so match.gd, the AI, the controls and the fake-3D camera need no changes.
#
#  * Movement is read through a smoothed "visual velocity": the legs wind up when he accelerates, wind
#    down when he stops, and he leans into pushes, braking and turns.
#  * The stride is locked to the distance he covers (one cycle per STRIDE_PX), so feet stay planted
#    while the body passes over them instead of skating.
#  * Legs and arms are bent with 2-bone IK, so knees and elbows flex naturally.
#  * Separate poses: idle / walk / run / sprint, dribbling, pass, shot, slide tackle, keeper ready stance
#    and dive, header jump, and goal celebrations (call celebrate() on the scoring team).
#
# THREE LOOKS, ONE SCRIPT
#  * Sheets (preferred, USE_SHEETS): 8-direction animated sheets, res://assets/players/<anim>.png (64x64 frames, one row
#    per direction S SE E NE N NW W SW; goalkeepers use gk_<anim>.png). The state logic below picks the animation, the
#    direction comes from `facing`, the stride speed from how fast he really moves, and kick animations are timed so the
#    strike frame lands when the ball is released. Team colours: see TEAM_TINT / KIT_* below.
#  * Atlas (fallback when there are no sheets): the drawn footballer from player_atlas.png. Hair, skin and the three kit parts are
#    recoloured by player_recolor.shader, so every player can have his own hair (blonde / black / brown) and
#    skin (fair / brown / black) and his team's kit. The state logic below picks the frame.
#  * Stickman (fallback): the procedural figure underneath. Used when USE_SPRITES is false, when the sprite
#    files are missing, or for a single player with force_stickman = true.

var team = 0
var slot = 0
var is_gk = false
var color = Color(1, 0, 0)
var home_pos = Vector2.ZERO
var vel = Vector2.ZERO
var facing = Vector2.RIGHT
var kick_cd = 0.0
var tackle_cd = 0.0
var is_tackling = false
var tackle_timer = 0.0
var ring = Color(1, 0.9, 0.2)
var jersey = null              # optional jersey picture, clipped to the shirt
var selected = false setget set_selected
var is_diving = false          # keeper diving / lying down (set by match.gd)
var dive_dir = Vector2.UP      # direction of the dive
var jump_height = 0.0          # header / jump: lifts him off his shadow
var force_stickman = false     # (kept so scripts written for the sprite version still work)
var number = 0                 # jersey number, printed on the back of the shirt (set by player_status_bar.gd)
var kick_kind = ""             # set by kick_system.gd just before a kick: pass / through / cross / shot / chip / clear
var kick_foot = 0              # ... and the foot: +1 right, -1 left, 0 = the leg on the side he faces
var shorts_color = null        # optional kit colours; null = derived from `color` (shorts a touch darker, socks the same)
var sock_color = null

# ---- SIZE: change these numbers to make the players bigger / taller ----------------------------
const FIG_SCALE = 1.0          # overall size
const HEIGHT_STRETCH = 1.0     # 1.15 = 15% taller without getting wider
# -------------------------------------------------------------------------------------------------

# ---- animation feel ------------------------------------------------------------------------------
const RUN_REF = 215.0          # the speed that counts as a full run
const STRIDE_PX = 52.0         # ground covered per full leg cycle (two steps): smaller = quicker legs
const AMP_MAX = 9.5            # how far a foot travels from the hip at a full run
const LEG_L = 6.3              # thigh and shin length
const ARM_L = 4.8              # upper arm and forearm length
const HIP_Y = -12.0
const SHOULDER_Y = -22.0
const KICK_T = 0.34            # length of the kick animation
const TURN_T = 0.16            # time to swing round when he changes the way he faces
const CELEBRATE_T = 2.4
# -------------------------------------------------------------------------------------------------

const FEET_Y = 5.0             # feet sit slightly below the node centre so the ball is at foot level
const SKIN = Color(0.96, 0.80, 0.65)
const HAIR = Color(0.18, 0.12, 0.08)
const GLOVE = Color(1.0, 0.85, 0.1)
const BOOT = Color(0.08, 0.08, 0.08)
const NUM_FONT_PATH = "res://assets/fonts/batmfa.ttf"

var walk_phase = 0.0           # stride phase: match.gd uses it to swing the dribbled ball foot to foot
var face_dir = 1.0             # +1 looking right, -1 looking left
var clock = 0.0
var vis_vel = Vector2.ZERO
var prev_vis = Vector2.ZERO
var acc = Vector2.ZERO
var vis_speed = 0.0
var vis_face = Vector2.RIGHT
var turn_t = 0.0
var turn_from = 1.0
var draw_dir = 1.0
var squash_x = 1.0
var kick_anim = 0.0
var kick_shot = false
var kick_style = "pass"          # the style of the kick being animated
var kick_leg = 0               # which leg is kicking it (+1 right, -1 left, 0 = the one he faces)
var prev_kick_cd = 0.0
var dribbling = false
var holding_ball = false          # throw-in taker: the ball is held over his head until he throws it
var tilt_cur = 0.0
var dive_amt = 0.0
var dive_ang = 0.0
var dive_clock = 0.0
var was_diving = false
var celebrate_t = 0.0
var celebrate_kind = 0
var celebrate_lead = false
var cel_clock = 0.0
var _hip = HIP_Y               # pose values shared with the drawing helpers
var _lean = 0.0
var _sock = Color.white
var _base_pos = Vector2.ZERO    # the figure's transform, so the shirt number can be drawn on the leaning torso
var _base_rot = 0.0
var _base_scale = Vector2.ONE


# ------------------------------------------------------------ sprite look
const PlayerFrames = preload("res://scripts/match/player_frames.gd")
const ATLAS_PATH = "res://assets/players/player_atlas.png"
const MASK_PATH = "res://assets/players/player_mask.png"
const SHADER_PATH = "res://assets/players/player_recolor.shader"
const USE_SPRITES = true       # false = always the drawn stickman
const SPRITE_SCALE = 0.52      # sprite pixels -> game pixels (the drawing is ~95 px tall, the stickman ~49)
# ------------------------------------------------------------ sheet look (8 directions)
const USE_SHEETS = true
const SHEET_DIR = "res://assets/players/"
const SHEET_FRAME = 64
const SHEET_DIRS = ["S", "SE", "E", "NE", "N", "NW", "W", "SW"]
const SHEET_SCALE = 1.0          # sheet pixels -> game pixels (a 64 px frame; make him bigger / smaller here)
const SHEET_HEAD_H = 50.0        # where the marker above the head of the player you control floats
const KICK_CONTACT_T = 0.14      # the ball leaves the foot this long after a kick starts (kick_system's delay)

# name: [frames, fps, loop]. Anything marked optional may be missing: the game falls back to a simpler animation.
const SHEET_ANIMS = {
	"idle": [1, 4, true], "walk": [4, 8, true], "run": [6, 12, true],
	"sprint": [6, 16, true], "dribble": [6, 12, true],
	"short_pass": [4, 14, false], "long_pass": [5, 12, false], "shoot": [5, 14, false],
	"tackle": [5, 12, false], "turn": [4, 12, false], "trap": [4, 10, false],
	"jump_head": [5, 10, false], "celebrate": [6, 8, true],
	"throw": [4, 12, false], "hold_ball": [1, 4, true],                   # optional: the throw-in
	"gk_ready": [1, 4, true], "gk_shuffle": [6, 12, true], "gk_dive": [5, 10, false],
	"gk_catch": [4, 10, false], "gk_punt": [5, 12, false],
	"gk_hold": [1, 4, true],                                              # optional: the keeper holding the ball
}
const SHEET_OPTIONAL = ["throw", "hold_ball", "gk_hold", "gk_throw", "gk_hold_ball", "turn", "trap"]
const SHEET_CONTACT = {"short_pass": 2, "long_pass": 3, "shoot": 3, "throw": 2, "gk_punt": 3}   # strike frame
# what to show when a sheet is missing
const SHEET_FALLBACK = {
	"sprint": "run", "dribble": "run", "run": "walk", "walk": "idle",
	"long_pass": "short_pass", "shoot": "short_pass", "short_pass": "idle", "throw": "long_pass",
	"tackle": "idle", "trap": "idle", "jump_head": "idle", "celebrate": "idle", "turn": "idle",
	"hold_ball": "idle", "dive": "idle", "punt": "long_pass", "hold": "catch", "catch": "idle",
}
const SHEET_NATURAL = {"walk": 70.0, "run": 130.0, "sprint": 185.0, "dribble": 115.0}   # speed one cycle looks right at

# Team colours. The sheets carry no colour mask, so the kit is found by its colour and recoloured by a small shader.
# The sheets show a light-blue / white striped kit (outfield) and a cream / yellow kit (keeper): every kit pixel becomes the
# team colour, keeping the sheet's shading. Skin, hair, boots and outlines are untouched, and so are the eyes: a kit-coloured
# pixel only counts as kit if enough of the pixels around it are kit too.
#   KIT_STYLE = "solid"   : shirt, shorts and socks all take the team colour.
#   KIT_STYLE = "striped" : only the saturated (blue / yellow) stripes take it, the white parts stay white.
# TEAM_TINT = false leaves the sheets exactly as drawn. If you redraw the sheets with another kit colour, change the hue
# range (degrees, 0-360) to the new kit's.
const TEAM_TINT = true
const KIT_STYLE = "solid"
const KIT_NEIGHBOURS = 4                  # of the 8 pixels around, at least this many must be kit for a pixel to be recoloured
const KIT_HUE = [170.0, 260.0]            # outfield kit: blue / white-blue
const KIT_SAT_MIN = 0.04
const GK_KIT_HUE = [28.0, 75.0]           # keeper kit: cream / yellow (skin is hue 5-26, so it is left alone)
const GK_KIT_SAT_MIN = 0.18
const SHEET_FEET_ROW = 60                 # the row of a 64 px frame his boots touch the ground at
const SHEET_SMOOTH = true                 # false = hard pixels (no filtering); true = smooth when scaled
const SHEET_SHADER = """shader_type canvas_item;

uniform vec4 shirt_col : hint_color = vec4(1.0, 0.0, 0.0, 1.0);
uniform float hue_lo = 170.0;
uniform float hue_hi = 260.0;
uniform float sat_min = 0.04;
uniform float neighbours = 4.0;
uniform float striped = 0.0;

vec3 to_hsv(vec3 c) {
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	float d = mx - mn;
	float h = 0.0;
	if (d > 0.0001) {
		if (mx == c.r) {
			h = mod((c.g - c.b) / d, 6.0);
		} else if (mx == c.g) {
			h = (c.b - c.r) / d + 2.0;
		} else {
			h = (c.r - c.g) / d + 4.0;
		}
		h = h * 60.0;
	}
	float s = 0.0;
	if (mx > 0.0001) {
		s = d / mx;
	}
	return vec3(h, s, mx);
}

float kit_at(vec2 uv) {
	vec4 c = texture(TEXTURE, uv);
	float k = 0.0;
	if (c.a >= 0.5) {
		vec3 hsv = to_hsv(c.rgb);
		if (hsv.z >= 0.30) {
			if (hsv.y < 0.10 && hsv.z > 0.55) {
				k = 1.0;
			} else if (hsv.x >= hue_lo && hsv.x <= hue_hi && hsv.y >= sat_min) {
				k = 1.0;
			}
		}
	}
	return k;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	vec2 px = TEXTURE_PIXEL_SIZE;
	vec2 sz = vec2(1.0) / px;
	vec2 uc = (floor(UV * sz) + vec2(0.5)) / sz;
	float recolor = kit_at(uc);
	if (recolor > 0.5) {
		float n = 0.0;
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				if (dx != 0 || dy != 0) {
					n += kit_at(uc + vec2(float(dx), float(dy)) * px);
				}
			}
		}
		if (n < neighbours) {
			recolor = 0.0;
		}
	}
	vec3 hsv = to_hsv(c.rgb);
	if (striped > 0.5 && hsv.y < 0.40) {
		recolor = 0.0;
	}
	float ref_v = 0.90;
	if (striped > 0.5) {
		ref_v = 0.75;
	}
	float f = min(hsv.z / ref_v, 1.25);
	vec3 tinted = shirt_col.rgb * f;
	COLOR = vec4(mix(c.rgb, tinted, recolor), c.a);
}"""

# hair: 0 blonde (as drawn), 1 black, 2 brown.   skin: 0 fair (as drawn), 1 brown, 2 black.
# -1 = chosen from his team and slot (the same player always looks the same); set_look() overrides it.
var hair_id = -1
var skin_id = -1
var sprite_ok = false
var spr = null                 # the Sprite child that shows the frame
var _mat = null
var _look_key = ""
var _look_done = false
var slide_clock = 0.0
# sheet look
var look = "stick"             # "sheets", "atlas" or "stick": what is actually showing
var sheet = null               # the AnimatedSprite child (sheet look)
var _sh_mat = null
var _sh_tint_key = ""
var _sh_dir = 0                # facing, in eighths: 0 S, 1 SE, 2 E, 3 NE, 4 N, 5 NW, 6 W, 7 SW
var _sh_base = ""
var _sh_kick_serial = 0
var kick_serial = 0            # counts kicks (a new one restarts the kick animation even if the last is still playing)


func _ready():
	vis_face = facing
	face_dir = 1.0 if facing.x >= 0.0 else -1.0
	draw_dir = face_dir
	_setup_sprite()


func set_selected(v):
	selected = v
	update()


# ------------------------------------------------------------ public: goal celebration

# kind: 0 jog on the spot with arms up, 1 fist pump, 2 big jumps, 3 arms out "aeroplane" (-1 = random)
func celebrate(kind = -1, lead = false):
	celebrate_kind = kind if kind >= 0 else randi() % 4
	celebrate_lead = lead
	celebrate_t = CELEBRATE_T
	cel_clock = randf() * 0.4


func stop_celebrating():
	celebrate_t = 0.0


# ------------------------------------------------------------ state, once per frame

func _process(delta):
	clock += delta
	var parent = get_parent()

	# while the game is frozen (goal scored, full time) or he is celebrating, the legs stop "running"
	var live_vel = vel
	if celebrate_t > 0.0:
		live_vel = Vector2.ZERO
	elif parent != null:
		var st = parent.get("state")
		if st == "goal" or st == "over":
			live_vel = Vector2.ZERO

	# visual velocity: eases towards the real one, so a standing start ramps up and a stop winds down
	var rate = 9.0 if live_vel.length() > vis_vel.length() else 13.0
	vis_vel = vis_vel.linear_interpolate(live_vel, 1.0 - exp(-rate * delta))
	vis_speed = vis_vel.length()
	var a_raw = (vis_vel - prev_vis) / max(delta, 0.0001)
	acc = acc.linear_interpolate(a_raw, 1.0 - exp(-10.0 * delta))
	prev_vis = vis_vel
	# one stride cycle per STRIDE_PX of ground covered: the feet keep time with the pitch
	if vis_speed > 6.0:
		walk_phase = fmod(walk_phase + TAU * min(vis_speed, 330.0) * delta / STRIDE_PX, TAU)

	# which way he faces; a change swings him round (a quick squash) instead of popping over
	if abs(facing.x) > 0.2:
		var nd = 1.0 if facing.x > 0.0 else -1.0
		if nd != face_dir:
			turn_from = face_dir
			face_dir = nd
			turn_t = TURN_T
	vis_face = vis_face.linear_interpolate(facing, 1.0 - exp(-12.0 * delta))
	if turn_t > 0.0:
		turn_t = max(0.0, turn_t - delta)
		var prog = 1.0 - turn_t / TURN_T
		draw_dir = turn_from if prog < 0.5 else face_dir
		squash_x = 0.4 + 0.6 * abs(cos(prog * PI))
	else:
		draw_dir = face_dir
		squash_x = 1.0

	# a kick starts when kick_cd jumps to ~0.35 (a tackled player's 0.5 stun is not a kick);
	# a fast ball means a shot, a slower one a pass
	if kick_cd > prev_kick_cd + 0.2 and kick_cd > 0.28 and kick_cd < 0.42:
		kick_anim = KICK_T
		kick_shot = true
		var b = parent.get("ball") if parent != null else null
		if b != null:
			kick_shot = b.vel.length() > 540.0
		kick_style = kick_kind if kick_kind != "" else ("shot" if kick_shot else "pass")
		kick_leg = kick_foot
		kick_kind = ""
		kick_foot = 0
		kick_serial += 1
	prev_kick_cd = kick_cd
	kick_anim = max(0.0, kick_anim - delta)

	dribbling = parent != null and parent.get("dribble_owner") == self
	var rl = parent.get("rules") if parent != null else null      # match_rules.gd: is he about to take a throw-in?
	holding_ball = rl != null and rl.enabled and rl.active and rl.kind == "throw_in" and rl.taker == self and rl.arrived.get(self, false)

	# slide tackle tilt and keeper dive blend in and out smoothly
	var tt = face_dir * 1.15 if is_tackling else 0.0
	tilt_cur = lerp(tilt_cur, tt, 1.0 - exp(-(16.0 if is_tackling else 9.0) * delta))
	if is_diving:
		if not was_diving:
			dive_clock = 0.0
		dive_clock += delta
		dive_ang = atan2(dive_dir.x, -dive_dir.y)
	dive_amt = lerp(dive_amt, 1.0 if is_diving else 0.0, 1.0 - exp(-(14.0 if is_diving else 7.0) * delta))
	was_diving = is_diving

	if celebrate_t > 0.0:
		celebrate_t = max(0.0, celebrate_t - delta)
		cel_clock += delta
		if parent != null and parent.get("state") == "playing":
			celebrate_t = 0.0
	_sprite_update(delta)
	update()


# ------------------------------------------------------------ drawing

func _draw():
	var lum = color.r * 0.3 + color.g * 0.59 + color.b * 0.11
	var outline = Color(0, 0, 0) if lum > 0.5 else Color(1, 1, 1)
	var feet = Vector2(0.0, FEET_Y)
	var cel = _celebration()
	var lift = jump_height + cel["jump"]
	var sh = 1.0 / (1.0 + lift * 0.06)

	# ground: shadow (shrinks when he jumps), selection ring and tackle ring
	draw_set_transform(feet, 0.0, Vector2(1.0, 0.4))
	draw_circle(Vector2.ZERO, 11.0 * FIG_SCALE * sh, Color(0, 0, 0, 0.28 * (0.5 + 0.5 * sh)))
	if selected:
		draw_arc(Vector2.ZERO, 16.0 * FIG_SCALE, 0.0, TAU, 32, ring, 4.0)
	if is_tackling:
		draw_arc(Vector2.ZERO, 22.0 * FIG_SCALE, 0.0, TAU, 32, Color(1, 0.2, 0.2), 5.0)

	# the figure: origin at his feet, tipped over for a slide tackle or a dive
	if not _use_sprite():
		var rot = tilt_cur + dive_ang * dive_amt
		_base_pos = feet + Vector2(0.0, -lift * FIG_SCALE)
		_base_rot = rot
		_base_scale = Vector2(FIG_SCALE * squash_x, FIG_SCALE * HEIGHT_STRETCH)
		draw_set_transform(_base_pos, _base_rot, _base_scale)
		_figure(outline, cel)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# marker above the head for the player you control
	if selected:
		var bob = sin(OS.get_ticks_msec() * 0.008) * 1.5
		var head_h = 53.0 if _use_sprite() else 44.0         # the drawn player is a little taller than the stickman
		if look == "sheets" and _use_sprite():
			head_h = SHEET_HEAD_H
		var tip = Vector2(0.0, FEET_Y - head_h * FIG_SCALE * HEIGHT_STRETCH - lift * FIG_SCALE + bob)
		var tri = PoolVector2Array([tip + Vector2(-5.0, -7.0), tip + Vector2(5.0, -7.0), tip])
		draw_colored_polygon(tri, ring)
		draw_polyline(PoolVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color(0, 0, 0, 0.8), 1.5)


func _ease(t):
	t = clamp(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


# the foot's path through one leg cycle: (forward offset, height). Stance (first half) moves the foot
# back at a constant speed - that is what keeps it planted; swing (second half) brings it through.
func _stride(theta, amp, lift):
	var th = fmod(theta, TAU)
	if th < 0.0:
		th += TAU
	if th < PI:
		return Vector2(amp * (1.0 - 2.0 * th / PI), 0.0)
	var u = (th - PI) / PI
	return Vector2(-amp + 2.0 * amp * _ease(u), lift * sin(u * PI))


# two-bone IK: the middle joint (knee / elbow) of a limb from root to target; bend = which side it bends to
func _ik(root, target, l, bend):
	var to = target - root
	var dist = to.length()
	var maxd = l * 2.0 - 0.05
	if dist > maxd:
		to = to.normalized() * maxd
		dist = maxd
	if dist < 0.05:
		return root + Vector2(bend * l, 0.0)
	var a = dist * 0.5
	var h = sqrt(max(l * l - a * a, 0.0))
	var dir = to / dist
	return root + dir * a + Vector2(-dir.y, dir.x) * bend * h


# upper-body points lean around the hips and follow the hip height
func _tp(pt):
	var pivot = Vector2(0.0, HIP_Y)
	return Vector2(0.0, _hip - HIP_Y) + pivot + (pt - pivot).rotated(_lean)


# celebration pose overrides (empty when he is not celebrating)
func _celebration():
	var r = {"jump": 0.0, "hl": null, "hr": null, "fa": null, "fb": null, "lean": 0.0}
	if celebrate_t <= 0.0:
		return r
	var t = cel_clock
	var fade = min(1.0, celebrate_t / 0.35)         # settle back at the end
	var big = 1.6 if celebrate_lead else 1.0
	if celebrate_kind == 0:
		var ph = t * 11.0
		r["fa"] = Vector2(-3.0, -max(0.0, sin(ph)) * 5.0)
		r["fb"] = Vector2(3.0, -max(0.0, -sin(ph)) * 5.0)
		r["hl"] = Vector2(-8.5, -37.0)
		r["hr"] = Vector2(8.5, -37.0)
		r["jump"] = 1.6 * big * abs(sin(ph)) * fade
	elif celebrate_kind == 1:
		r["hr"] = Vector2(7.5, -35.0 + sin(t * 10.0) * 5.0)
		r["hl"] = Vector2(-8.0, -14.0)
		r["jump"] = 1.8 * big * abs(sin(t * 5.0)) * fade
		r["lean"] = 0.05 * sin(t * 5.0)
	elif celebrate_kind == 2:
		var hop = abs(sin(t * PI * 1.7))
		r["jump"] = 7.0 * big * hop * fade
		r["hl"] = Vector2(-5.5, -39.0)
		r["hr"] = Vector2(5.5, -39.0)
		if hop > 0.25:
			r["fa"] = Vector2(-2.5, -5.0)
			r["fb"] = Vector2(2.5, -5.0)
	else:
		r["hl"] = Vector2(-13.5, -25.0 + sin(t * 7.0) * 2.0)
		r["hr"] = Vector2(13.5, -25.0 - sin(t * 7.0) * 2.0)
		r["lean"] = 0.14 * sin(t * 3.5) * fade
		var ph2 = t * 6.0
		r["fa"] = Vector2(-3.0, -max(0.0, sin(ph2)) * 2.5)
		r["fb"] = Vector2(3.0, -max(0.0, -sin(ph2)) * 2.5)
		r["jump"] = 1.0 * big * abs(sin(ph2)) * fade
	return r


# kick pose: [forward foot offset, foot height, body lean] through plant -> strike -> follow-through
func _kick_pose(u, style):
	var back = 5.0
	var fwd = 9.0
	var up_b = 2.5
	var up_f = 2.0
	var lean_s = 0.14
	if style == "shot":
		back = 8.0
		fwd = 13.0
		up_b = 4.5
		up_f = 5.0
		lean_s = 0.22
	elif style == "through":        # side-foot, body open
		back = 4.0
		fwd = 10.0
		up_b = 1.5
		up_f = 3.0
		lean_s = 0.10
	elif style == "cross":          # a big swing, getting under the ball
		back = 9.0
		fwd = 12.0
		up_b = 5.0
		up_f = 7.0
		lean_s = 0.06
	elif style == "chip":           # a short scoop
		back = 3.0
		fwd = 8.0
		up_b = 0.5
		up_f = 7.5
		lean_s = 0.08
	elif style == "clear":
		back = 9.0
		fwd = 14.0
		up_b = 5.0
		up_f = 6.0
		lean_s = 0.20
	if u < 0.30:
		var k = _ease(u / 0.30)
		return [lerp(0.0, -back, k), lerp(0.0, up_b, k), lerp(0.0, -0.12, k)]
	if u < 0.48:
		var k2 = _ease((u - 0.30) / 0.18)
		return [lerp(-back, fwd, k2), lerp(up_b, up_f, k2), lerp(-0.12, lean_s, k2)]
	var k3 = _ease((u - 0.48) / 0.52)
	return [lerp(fwd, 1.0, k3), lerp(up_f, 0.0, k3), lerp(lean_s, 0.0, k3)]


# everything below is in "figure space": (0, 0) = feet on the ground, up is negative y
func _figure(outline, cel):
	var d = draw_dir
	var spd = vis_speed
	var moving = spd > 6.0
	var sp_n = clamp(spd / RUN_REF, 0.0, 1.5)
	var lat = 1.0
	var vsign = 0.0
	if moving:
		lat = clamp(abs(vis_vel.x) / spd, 0.0, 1.0)
		vsign = sign(vis_vel.y)
	var vert = 1.0 - lat
	var mx = vis_vel.x / max(spd, 1.0) if moving else 0.0
	var tk = clamp(abs(tilt_cur) / 1.15, 0.0, 1.0)         # slide tackle amount
	var dv = dive_amt                                        # keeper dive amount
	var ph_a = walk_phase
	var ph_b = walk_phase + PI
	var looking_up = vis_face.y < -0.45 and abs(vis_face.x) < 0.8
	var looking_down = vis_face.y > 0.45 and abs(vis_face.x) < 0.8

	# ---- body: lean into movement / pushes / braking, bob with each step
	var amp = AMP_MAX * clamp(spd / 120.0, 0.0, 1.0)
	var lift_h = 1.5 + 4.5 * min(sp_n, 1.2)
	var crouch = 0.0
	var lean = mx * (0.05 + 0.20 * min(sp_n, 1.2))
	lean += clamp(acc.x / 900.0, -0.12, 0.12)
	var sway = 0.0
	if dribbling:
		amp *= 0.8
		lift_h *= 0.6
		lean += d * 0.05
		crouch += 0.6
	if not moving:
		sway = sin(clock * 1.7) * 0.5
		crouch += 0.2 * sin(clock * 2.3)                    # breathing
	if is_gk and not is_diving:
		crouch += 1.4                                        # keeper's ready stance
		amp *= 0.6
	var bob = 0.0
	if moving:
		bob = 1.4 * min(sp_n, 1.2) * 0.5 * (1.0 - cos(2.0 * walk_phase))

	# ---- feet
	var sa = _stride(ph_a, amp, lift_h)
	var sb = _stride(ph_b, amp, lift_h)
	var stance = 2.5 + 0.9 * (1.0 - min(sp_n * 2.0, 1.0))   # feet a little wider when standing
	var foot_a = Vector2(-stance + d * sa.x * lat, -sa.y + sa.x * vert * vsign * 0.45)
	var foot_b = Vector2(stance + d * sb.x * lat, -sb.y + sb.x * vert * vsign * 0.45)
	if dribbling and moving:
		# a touch on the ball every step: the foot pushes on just before it lands
		foot_a.x += d * lat * 1.8 * max(0.0, sin(ph_a - 0.6)) * (1.0 if sa.y > 0.0 else 0.0)
		foot_b.x += d * lat * 1.8 * max(0.0, sin(ph_b - 0.6)) * (1.0 if sb.y > 0.0 else 0.0)

	# ---- arms: swing against the legs, elbows bent
	var aamp = 2.0 + 5.0 * min(sp_n, 1.2)
	var hand_l = _hand(-6.8, ph_b, aamp, d, lat, vsign, vert, sp_n)
	var hand_r = _hand(6.8, ph_a, aamp, d, lat, vsign, vert, sp_n)
	if not moving:
		hand_l = Vector2(-8.4, -13.0 + sin(clock * 1.7) * 0.4)
		hand_r = Vector2(8.4, -13.0 + sin(clock * 1.7 + 0.6) * 0.4)
	if dribbling:
		hand_l += Vector2(-1.5, 1.2)
		hand_r += Vector2(1.5, 1.2)
	if is_gk and not is_diving:
		hand_l = Vector2(-11.5, -17.5 + sin(clock * 5.0) * 0.8)    # gloves out, ready
		hand_r = Vector2(11.5, -17.5 + sin(clock * 5.0 + 1.0) * 0.8)

	# ---- kick: plant the support foot, swing the other leg through, arms counter-balance
	var throwing = kick_anim > 0.0 and kick_style == "throw"
	var hands_up = holding_ball or throwing
	if kick_anim > 0.0 and tk < 0.2 and dv < 0.2 and not throwing:
		var u = 1.0 - kick_anim / KICK_T
		var kp = _kick_pose(u, kick_style)
		var kick_right = (kick_leg > 0) if kick_leg != 0 else d > 0.0
		var kfoot = Vector2((stance if kick_right else -stance) + d * kp[0], -kp[1])
		var sfoot = Vector2((-stance if kick_right else stance) - d * 1.5, 0.0)
		if kick_right:
			foot_b = kfoot
			foot_a = sfoot
		else:
			foot_a = kfoot
			foot_b = sfoot
		lean += d * kp[2]
		crouch += 1.1 * sin(u * PI)
		var swing_f = Vector2(d * 5.0, -14.0)
		var swing_b = Vector2(-d * 4.0, -15.0)
		# the arm opposite the kicking leg goes forward as the leg comes through
		var fwd_arm = Vector2(-7.5 if kick_right else 7.5, 0.0) + swing_f
		var back_arm = Vector2(7.5 if kick_right else -7.5, 0.0) + swing_b
		var w = _ease((u - 0.2) / 0.3)
		if kick_right:
			hand_l = hand_l.linear_interpolate(fwd_arm, w)
			hand_r = hand_r.linear_interpolate(back_arm, w)
		else:
			hand_r = hand_r.linear_interpolate(fwd_arm, w)
			hand_l = hand_l.linear_interpolate(back_arm, w)

	# ---- throw-in: the ball is held over the head, then both arms swing it forward and let go
	if hands_up and tk < 0.2 and dv < 0.2:
		var hx = 0.0
		var hy = -39.0
		if throwing:
			var ut = 1.0 - kick_anim / KICK_T
			if ut < 0.3:                                      # wind-up: the ball goes back behind the head
				var kk = _ease(ut / 0.3)
				hx = lerp(0.0, -d * 4.0, kk)
				hy = lerp(-39.0, -41.0, kk)
				lean += -d * 0.10 * kk
			elif ut < 0.5:                                    # the throw: arms whip forward, ball is let go
				var k2 = _ease((ut - 0.3) / 0.2)
				hx = lerp(-d * 4.0, d * 9.0, k2)
				hy = lerp(-41.0, -33.0, k2)
				lean += d * lerp(-0.10, 0.18, k2)
			else:                                             # follow-through
				var k3 = _ease((ut - 0.5) / 0.5)
				hx = lerp(d * 9.0, d * 6.0, k3)
				hy = lerp(-33.0, -24.0, k3)
				lean += d * lerp(0.18, 0.0, k3)
			crouch += 0.8 * sin(ut * PI)
		hand_l = Vector2(-3.2 + hx, hy)
		hand_r = Vector2(3.2 + hx, hy)

	# ---- celebration
	if celebrate_t > 0.0:
		if cel["fa"] != null:
			foot_a = cel["fa"]
			foot_b = cel["fb"]
		if cel["hl"] != null:
			hand_l = cel["hl"]
		if cel["hr"] != null:
			hand_r = cel["hr"]
		lean += cel["lean"]
		bob = 0.0

	# ---- airborne (header / jump): knees tucked, arms up
	var tuck = clamp(jump_height / 6.0, 0.0, 1.0)
	if tuck > 0.0:
		foot_a.y -= 4.5 * tuck
		foot_b.y -= 4.5 * tuck
		hand_l = hand_l.linear_interpolate(Vector2(-6.0, -34.0), tuck)
		hand_r = hand_r.linear_interpolate(Vector2(6.0, -34.0), tuck)

	# ---- slide tackle: lead leg out in front, trailing leg folded, arms out for balance
	if tk > 0.0:
		foot_a = foot_a.linear_interpolate(Vector2(d * 10.0, -1.0), tk)
		foot_b = foot_b.linear_interpolate(Vector2(-d * 5.0, -3.0), tk)
		hand_l = hand_l.linear_interpolate(Vector2(-d * 9.0, -17.0), tk)
		hand_r = hand_r.linear_interpolate(Vector2(d * 4.0, -21.0), tk)
		lean = lerp(lean, 0.0, tk)
		bob = lerp(bob, 0.0, tk)

	# ---- keeper dive: legs trail, both hands stretched out in front
	if dv > 0.0:
		var prep = clamp(dive_clock / 0.12, 0.0, 1.0)
		foot_a = foot_a.linear_interpolate(Vector2(-1.8, -1.0), dv)
		foot_b = foot_b.linear_interpolate(Vector2(1.8, -2.5), dv)
		hand_l = hand_l.linear_interpolate(Vector2(-3.5, -41.0 + 3.0 * (1.0 - prep)), dv)
		hand_r = hand_r.linear_interpolate(Vector2(3.5, -41.0 + 3.0 * (1.0 - prep)), dv)
		lean = lerp(lean, 0.0, dv)
		bob = lerp(bob, 0.0, dv)
		crouch = lerp(crouch, 0.0, dv)

	_lean = clamp(lean, -0.5, 0.5)
	_hip = HIP_Y + bob + crouch
	var hip_a = Vector2(-2.5 + sway, _hip)
	var hip_b = Vector2(2.5 + sway, _hip)

	# ---- draw: legs (the rearmost first), shorts, shirt, arms, head
	var shorts = _shorts_col()
	_sock = _sock_col()
	var first_is_a = foot_a.x * d <= foot_b.x * d
	if first_is_a:
		_leg(hip_a, foot_a, d, lat, 1.0, shorts, outline)
		_leg(hip_b, foot_b, d, lat, -1.0, shorts, outline)
	else:
		_leg(hip_b, foot_b, d, lat, -1.0, shorts, outline)
		_leg(hip_a, foot_a, d, lat, 1.0, shorts, outline)
	# shorts: waist and hips (the legs of the shorts are drawn with each leg)
	draw_colored_polygon(PoolVector2Array([
		Vector2(-5.8 + sway, _hip - 1.6), Vector2(5.8 + sway, _hip - 1.6),
		Vector2(5.6 + sway, _hip + 2.8), Vector2(-5.6 + sway, _hip + 2.8)]), shorts)
	draw_line(Vector2(-5.6 + sway, _hip - 1.3), Vector2(5.6 + sway, _hip - 1.3), shorts.darkened(0.3), 1.6)    # waistband
	draw_line(Vector2(sway, _hip - 1.0), Vector2(sway, _hip + 2.6), shorts.darkened(0.25), 0.8)               # centre seam

	var shirt = PoolVector2Array([
		Vector2(-5.5, -26.0), Vector2(5.5, -26.0), Vector2(8.5, -23.5), Vector2(7.0, -20.5),
		Vector2(5.5, -21.5), Vector2(5.5, -13.0), Vector2(-5.5, -13.0), Vector2(-5.5, -21.5),
		Vector2(-7.0, -20.5), Vector2(-8.5, -23.5)])
	var moved = PoolVector2Array()
	for p in shirt:
		moved.append(_tp(p))
	if jersey != null:
		var uvs = PoolVector2Array()
		for p in shirt:
			uvs.append(Vector2(0.5, 0.5) + (p - Vector2(0.0, -19.0)) / 17.0)
		draw_colored_polygon(moved, Color.white, uvs, jersey)
	else:
		draw_colored_polygon(moved, color)
	var closed = PoolVector2Array(moved)
	closed.append(moved[0])
	draw_polyline(closed, outline, 1.2)
	if number > 0 and not looking_down:
		_back_number(1.0 if looking_up else 0.5)      # running away from us: the full number; side-on: part of it

	var sh_l_design = Vector2(-7.0, -21.5)
	var sh_r_design = Vector2(7.0, -21.5)
	var sh_l = _tp(sh_l_design)
	var sh_r = _tp(sh_r_design)
	var open_l = 0.35
	var open_r = 0.35
	if spd > 60.0:
		open_l = 0.0                          # running: fists
		open_r = 0.0
	if is_gk or tk > 0.3 or dv > 0.3 or tuck > 0.3 or hands_up:
		open_l = 1.0                          # keeper, sliding, diving, jumping: open hands
		open_r = 1.0
	if celebrate_t > 0.0:
		open_l = 1.0
		open_r = 1.0
		if celebrate_kind == 1:
			open_r = 0.0                      # the fist pump
	_arm(sh_l, sh_l + (hand_l - sh_l_design), d, lat, -1.0, outline, open_l)
	_arm(sh_r, sh_r + (hand_r - sh_r_design), d, lat, 1.0, outline, open_r)

	# head: back of the head running away from the camera, two eyes coming towards it, one eye side-on
	var neck_a = _tp(Vector2(0.0, -26.0))
	var neck_b = _tp(Vector2(0.0, -28.5))
	draw_line(neck_a, neck_b, SKIN, 2.5)
	var head_off = Vector2(0.0, 0.0)
	if dribbling:
		head_off = Vector2(d * 0.8, 1.2)                      # eyes on the ball
	var head = _tp(Vector2(0.0, -33.0)) + head_off
	draw_circle(head, 5.4, outline)
	if looking_up and not is_diving:
		draw_circle(head, 4.4, HAIR)
	else:
		draw_circle(head, 4.4, SKIN)
		draw_arc(head, 3.6, PI * 1.05 + _lean, PI * 1.95 + _lean, 12, HAIR, 2.6)
		var ey = 0.0 if not dribbling else 0.7
		if looking_down:
			draw_circle(head + Vector2(-1.7, 0.4 + ey), 0.9, HAIR)
			draw_circle(head + Vector2(1.7, 0.4 + ey), 0.9, HAIR)
		else:
			draw_circle(head + Vector2(d * 2.2, ey), 0.9, HAIR)


# the number on the back of the shirt (squeezed when we only see the shirt from the side)
func _num_font(size):
	var key = "fb_num_font_%d" % size
	if Engine.has_meta(key):
		return Engine.get_meta(key)
	var f = DynamicFont.new()
	f.font_data = load(NUM_FONT_PATH)
	f.size = size
	Engine.set_meta(key, f)
	return f


func _back_number(width_amount):
	var txt = str(number)
	var f = _num_font(11 if txt.length() == 1 else 8)
	var c = _tp(Vector2(0.0, -18.2))
	var at = _base_pos + Vector2(c.x * _base_scale.x, c.y * _base_scale.y).rotated(_base_rot)
	var lum = color.r * 0.3 + color.g * 0.59 + color.b * 0.11
	var ink = Color(0.04, 0.04, 0.08) if lum > 0.55 else Color(1, 1, 1)
	draw_set_transform(at, _base_rot + _lean, Vector2(_base_scale.x * width_amount, _base_scale.y))
	var w = f.get_string_size(txt).x
	draw_string(f, Vector2(-w * 0.5, (f.get_ascent() - f.get_descent()) * 0.5), txt, ink)
	draw_set_transform(_base_pos, _base_rot, _base_scale)       # back to the figure's own transform


# hand position of a running arm (relative to the figure): swings forward / back against the leg
func _hand(sx, theta, aamp, d, lat, vsign, vert, sp_n):
	var f = cos(theta)
	var x = sx * 1.15 + d * f * aamp * lat
	var y = SHOULDER_Y + 9.0 - 3.2 * max(0.0, f) * min(sp_n, 1.2) + f * vsign * 2.2 * vert
	return Vector2(x, y)


# the kit: shirt colour a touch darker for the shorts, socks as the shirt unless set
func _shorts_col():
	if shorts_color != null:
		return shorts_color
	return color.darkened(0.22)


func _sock_col():
	if sock_color != null:
		return sock_color
	return color


# contrast for the stripe, hem and sock tops
func _trim_col():
	var lum = color.r * 0.3 + color.g * 0.59 + color.b * 0.11
	return Color(1, 1, 1) if lum < 0.6 else Color(0.1, 0.1, 0.15)


# a leg: shorts down to mid-thigh (side stripe, hem), bare thigh, a sock with a turn-over band, a boot
func _leg(hip, foot, d, lat, out, shorts, outline):
	var knee = _ik(hip, foot, LEG_L, -d * lat + out * (1.0 - lat))
	var trim = _trim_col()
	var mid = hip.linear_interpolate(knee, 0.78)
	# bare thigh between the shorts and the knee
	draw_line(mid, knee, outline, 3.8)
	draw_line(mid, knee, SKIN, 2.2)
	# shin: sock with a band at the top, then the boot
	draw_line(knee, foot, outline, 4.6)
	draw_line(knee, foot, _sock, 2.6)
	draw_line(knee, knee.linear_interpolate(foot, 0.22), trim, 2.6)
	var toe = foot + Vector2(d * 2.6, 0.4 if foot.y < -0.5 else 0.0)
	var heel = foot - Vector2(d * 1.1, 0.0)
	draw_line(heel, toe, outline, 3.8)
	draw_line(heel, toe, BOOT, 2.4)
	# the shorts leg: a wide tube from the waist to mid-thigh
	draw_line(hip, mid, outline, 6.4)
	draw_line(hip, mid, shorts, 5.0)
	var dir = (mid - hip).normalized()
	var n = Vector2(-dir.y, dir.x)
	if n.x * out > 0.0:
		n = -n                                   # towards the outside of the leg
	draw_line(hip + n * 1.9, mid + n * 1.9, trim, 0.9)                              # side stripe
	draw_line(mid - n * 2.6, mid + n * 2.6, shorts.darkened(0.3), 0.8)               # hem


func _arm(shoulder, hand, d, lat, side, outline, open):
	var elbow = _ik(shoulder, hand, ARM_L, d * lat - side * (1.0 - lat))
	draw_line(shoulder, elbow, outline, 4.0)
	draw_line(elbow, hand, outline, 4.0)
	draw_line(shoulder, elbow, SKIN, 2.2)
	draw_line(elbow, hand, SKIN, 2.2)
	var fore = hand - elbow
	_draw_hand(hand, fore.normalized() if fore.length() > 0.01 else Vector2.DOWN, open, side, outline)


# a hand: palm, thumb and fingers. open 0 = a fist (knuckles, thumb across), 1 = fingers spread.
# The keeper's hands are yellow gloves with a white cuff.
func _draw_hand(wrist, dir, open, side, outline):
	var glove = is_gk
	var skin = GLOVE if glove else SKIN
	var edge = Color(0.08, 0.08, 0.08) if glove else outline
	var n = Vector2(-dir.y, dir.x)
	var thumb_n = n if n.x * side < 0.0 else -n          # the thumb is on the side nearest the body
	var pl = lerp(2.6, 1.9, open) + (0.4 if glove else 0.0)
	var pw = 1.5 + (0.3 if glove else 0.0)
	var a = wrist + dir * 0.1
	var b = wrist + dir * pl
	var poly = PoolVector2Array([a + n * pw, b + n * (pw * 0.92), b - n * (pw * 0.92), a - n * pw])
	var closed = PoolVector2Array(poly)
	closed.append(poly[0])
	var t0 = wrist + dir * 0.8 + thumb_n * pw * 0.7
	var t1 = t0 + thumb_n * lerp(0.9, 1.7, open) + dir * lerp(1.3, 1.2, open)
	var tips = []
	if open > 0.2:
		var flen = 0.5 + 2.3 * open
		for i in range(4):
			var off = (i - 1.5) * 0.85
			var base = b + n * off * 0.8
			tips.append([base, b + dir * (flen + (0.3 if (i == 1 or i == 2) else 0.0)) + n * off * (1.0 + 0.5 * open)])
	# outline, then fill
	for f in tips:
		draw_line(f[0], f[1], edge, 2.0)
	draw_line(t0, t1, edge, 2.2)
	draw_polyline(closed, edge, 2.2)
	for f in tips:
		draw_line(f[0], f[1], skin, 1.0)
	draw_line(t0, t1, skin, 1.1)
	draw_colored_polygon(poly, skin)
	if open < 0.5:
		draw_line(b + n * pw * 0.8, b - n * pw * 0.8, skin.darkened(0.3), 0.7)             # the knuckles
		draw_line(a.linear_interpolate(b, 0.5) + n * pw * 0.7, a.linear_interpolate(b, 0.5) - n * pw * 0.7, skin.darkened(0.2), 0.6)
	if glove:
		draw_line(wrist + n * pw * 1.15, wrist - n * pw * 1.15, Color.white, 1.6)          # the cuff


# ============================================================ SPRITE PLAYER

func _use_sprite():
	return sprite_ok and not force_stickman


# public: choose his look by hand (hair 0 blonde / 1 black / 2 brown, skin 0 fair / 1 brown / 2 black; -1 = leave it to chance)
func set_look(hair, skin):
	hair_id = hair
	skin_id = skin
	_look_done = false
	_look_key = ""


func _setup_sprite():
	if not USE_SPRITES:
		return
	if USE_SHEETS and _setup_sheets():
		return
	_setup_atlas()


func _setup_atlas():
	if not (ResourceLoader.exists(ATLAS_PATH) and ResourceLoader.exists(MASK_PATH) and ResourceLoader.exists(SHADER_PATH)):
		return                                   # no sprite files: he stays a stickman
	# the mask must not be smoothed (its values are labels), so it is made once with the filter off and shared
	var mask = null
	if Engine.has_meta("player_mask_tex"):
		mask = Engine.get_meta("player_mask_tex")
	else:
		mask = ImageTexture.new()
		mask.create_from_image(load(MASK_PATH).get_data(), 0)
		Engine.set_meta("player_mask_tex", mask)
	spr = Sprite.new()
	spr.texture = load(ATLAS_PATH)
	spr.centered = false
	spr.region_enabled = true
	spr.region_filter_clip = true
	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	_mat.set_shader_param("mask", mask)
	_mat.set_shader_param("hair_ref", PlayerFrames.REF_HAIR)
	_mat.set_shader_param("skin_ref", PlayerFrames.REF_SKIN)
	_mat.set_shader_param("kit_ref", PlayerFrames.REF_KIT)
	spr.material = _mat
	add_child(spr)
	sprite_ok = true
	look = "atlas"


# his hair and skin, from his team and slot, so the same player always looks the same. Skin and hair go together
# the way they mostly do (a blond with black skin is rare), but every combination can occur.
func _pick_look():
	var rng = RandomNumberGenerator.new()
	rng.seed = team * 977 + slot * 131 + 17
	if skin_id < 0:
		var r = rng.randf()
		skin_id = 0 if r < 0.42 else (1 if r < 0.76 else 2)
	if hair_id < 0:
		var h = rng.randf()
		if skin_id == 0:
			hair_id = 0 if h < 0.35 else (2 if h < 0.70 else 1)
		elif skin_id == 1:
			hair_id = 1 if h < 0.50 else (2 if h < 0.90 else 0)
		else:
			hair_id = 1 if h < 0.80 else 2
	_look_done = true


func _hair_target():
	if hair_id == 1:
		return Color(0.13, 0.115, 0.125, 1.0)
	if hair_id == 2:
		return Color(0.40, 0.245, 0.125, 1.0)
	return Color(0.0, 0.0, 0.0, 0.0)           # blonde: as drawn


func _skin_target():
	if skin_id == 1:
		return Color(0.64, 0.42, 0.27, 1.0)
	if skin_id == 2:
		return Color(0.36, 0.23, 0.165, 1.0)
	return Color(0.0, 0.0, 0.0, 0.0)           # fair: as drawn


# push his colours into the shader (only when something changed: the kit is set by match.gd after he is made)
func _apply_look():
	var sc = _shorts_col()
	var so = _sock_col()
	var key = "%d|%d|%s|%s|%s" % [hair_id, skin_id, color.to_html(false), sc.to_html(false), so.to_html(false)]
	if key == _look_key:
		return
	_look_key = key
	_mat.set_shader_param("hair_col", _hair_target())
	_mat.set_shader_param("skin_col", _skin_target())
	_mat.set_shader_param("shirt_col", color)
	_mat.set_shader_param("shorts_col", sc)
	_mat.set_shader_param("sock_col", so)


# a frame of an animation: `phase` runs 0..1 over one cycle
func _cyc(anim, phase):
	var a = PlayerFrames.ANIMS[anim]
	return a[int(floor(phase * a.size())) % a.size()]


# which frame he shows right now: [frame name, rotation, mirrored]. The drawing looks to the right; a mirror turns him round.
func _sprite_pick():
	var spd = vis_speed
	var flip = draw_dir < 0.0
	var dir_v = vis_vel if spd > 14.0 else vis_face * 50.0
	var cls = 0                                # 0 side-on, 1 running away (back view), 2 running at the camera
	if abs(dir_v.y) > abs(dir_v.x) * 1.7:
		cls = 1 if dir_v.y < 0.0 else 2

	# goal celebration
	if celebrate_t > 0.0:
		return [_cyc("cel" + str(celebrate_kind), cel_clock * 1.6), 0.0, flip]

	# keeper diving (and lying where he landed)
	if is_gk and (is_diving or dive_amt > 0.3):
		var dd = dive_dir
		var lying = PlayerFrames.ANIMS["gk_dive"]
		var idx = 4
		if is_diving:
			idx = 0 if dive_clock < 0.05 else (1 if dive_clock < 0.10 else (2 if dive_clock < 0.20 else (3 if dive_clock < 0.34 else 4)))
		if abs(dd.x) >= 0.35:                    # along the ground to one side: the dive drawing, tipped up or down a little
			flip = dd.x < 0.0
			var sgn = -1.0 if flip else 1.0
			return [lying[idx], sgn * clamp(dd.y, -1.0, 1.0) * 0.55, flip]
		if dd.y < 0.0:                           # straight up: the stretch for the top corner
			var up = PlayerFrames.ANIMS["gk_dive_up"]
			return [up[0 if dive_clock < 0.2 else 1], 0.0, flip]
		return [lying[idx], (-1.0 if flip else 1.0) * 0.7, flip]   # falling forward onto the ball

	# slide tackle
	if is_tackling:
		var sl = PlayerFrames.ANIMS["slide"]
		return [sl[0 if slide_clock < 0.08 else (1 if slide_clock < 0.20 else (2 if slide_clock < 0.36 else 3))], 0.0, flip]

	# kick / throw: the frame follows the kick animation (the ball leaves the foot at u = 0.41)
	if kick_anim > 0.0:
		var u = 1.0 - kick_anim / KICK_T
		var nm = "kick_pass"
		if kick_style == "shot":
			nm = "kick_shot"
		elif kick_style == "chip" or kick_style == "cross":
			nm = "kick_chip"
		elif kick_style == "clear":
			nm = "kick_clear"
		elif kick_style == "throw":
			nm = "throw"
		var ka = PlayerFrames.ANIMS[nm]
		return [ka[0 if u < 0.22 else (1 if u < 0.48 else (2 if u < 0.72 else 3))], 0.0, flip]

	# the throw-in taker holds the ball over his head until he lets go
	if holding_ball:
		return [PlayerFrames.ANIMS["hold_ball"][0], 0.0, flip]

	# header / jump
	if jump_height > 1.2:
		var ja = PlayerFrames.ANIMS["jump"]
		return [ja[0 if jump_height < 2.4 else (1 if jump_height < 4.5 else 2)], 0.0, flip]

	# keeper on his feet: ready stance, or holding the ball
	if is_gk and spd < 70.0:
		if dribbling and spd < 40.0:
			return [PlayerFrames.ANIMS["gk_hold"][0], 0.0, flip]
		return [_cyc("gk_ready", fmod(clock * 0.5, 1.0)), 0.0, flip]

	# standing, walking, running: the stride phase picks the frame, so the feet keep time with the ground
	if spd < 12.0:
		return [_cyc("idle_up" if cls == 1 else "idle", fmod(clock * 0.45, 1.0)), 0.0, flip]
	var tier = 0 if spd < 100.0 else (1 if spd < 178.0 else 2)
	var phase = walk_phase / TAU
	var anim = "walk"
	if cls == 1:
		anim = "walk_up" if tier == 0 else "run_up"
	elif cls == 2:
		anim = "walk_down" if tier == 0 else "run_down"
	else:
		anim = "walk" if tier == 0 else ("run" if tier == 1 else "sprint")
	return [_cyc(anim, phase), 0.0, flip]


func _sprite_update(delta):
	if not sprite_ok:
		return
	if look == "sheets":
		_sheet_update(delta)
		return
	if not _use_sprite():
		spr.visible = false
		return
	spr.visible = true
	slide_clock = slide_clock + delta if is_tackling else 0.0
	if not _look_done:
		_pick_look()
	_apply_look()
	var pick = _sprite_pick()
	var f = PlayerFrames.FRAMES[pick[0]]
	var cel = _celebration()
	var lift = jump_height + cel["jump"]
	var sc = SPRITE_SCALE * FIG_SCALE
	spr.region_rect = Rect2(f[0], f[1], f[2], f[3])
	spr.offset = Vector2(-f[4], -f[5])         # the pivot (his feet) sits on the node's ground point
	spr.position = Vector2(0.0, FEET_Y - lift * FIG_SCALE)
	spr.rotation = pick[1]
	spr.scale = Vector2(sc * squash_x * (-1.0 if pick[2] else 1.0), sc * HEIGHT_STRETCH)


# ============================================================ SHEET PLAYER (8 directions)

# the sheets exist and are loaded: true = this is his look
func _setup_sheets():
	var need = SHEET_DIR + ("gk_ready.png" if is_gk else "idle.png")
	if not ResourceLoader.exists(need):
		return false                                 # no sheets: he stays an atlas / stickman player
	var frames = _sheet_frames(is_gk)
	if frames == null or not frames.has_animation(_sheet_name("idle") + "_S"):
		return false
	sheet = AnimatedSprite.new()
	sheet.frames = frames
	sheet.centered = true
	sheet.offset = Vector2(0.0, -(float(SHEET_FEET_ROW) - SHEET_FRAME / 2.0))      # his boots sit on the node's ground point
	if TEAM_TINT:
		_sh_mat = ShaderMaterial.new()
		_sh_mat.shader = _sheet_shader()
		var hue = GK_KIT_HUE if is_gk else KIT_HUE
		_sh_mat.set_shader_param("hue_lo", hue[0])
		_sh_mat.set_shader_param("hue_hi", hue[1])
		_sh_mat.set_shader_param("sat_min", GK_KIT_SAT_MIN if is_gk else KIT_SAT_MIN)
		_sh_mat.set_shader_param("neighbours", float(KIT_NEIGHBOURS))
		_sh_mat.set_shader_param("striped", 1.0 if KIT_STYLE == "striped" else 0.0)
		sheet.material = _sh_mat
	add_child(sheet)
	sprite_ok = true
	look = "sheets"
	_sh_dir = _eighth(facing)
	return true


# the animation sheet for a plain animation name: the keeper has his own set
func _sheet_name(b):
	if is_gk:
		if b == "idle":
			return "gk_ready"
		if b == "walk":
			return "gk_shuffle"
		if b == "dive":
			return "gk_dive"
		if b == "catch":
			return "gk_catch"
		if b == "punt":
			return "gk_punt"
		if b == "hold":
			return "gk_hold"
		return "gk_" + b
	return b


# the animation to use for `b` in direction `idx`, walking down the fallbacks if a sheet is missing: [name, full name]
func _sheet_resolve(b, idx):
	var cur = b
	for i in range(7):
		var full = "%s_%s" % [_sheet_name(cur), SHEET_DIRS[idx]]
		if sheet.frames.has_animation(full):
			return [cur, full]
		cur = SHEET_FALLBACK.get(cur, "idle")
	return ["idle", ""]


# a direction as the nearest eighth: 0 S, 1 SE, 2 E, 3 NE, 4 N, 5 NW, 6 W, 7 SW
func _eighth(v):
	return posmod(int(round(atan2(v.x, v.y) / (PI / 4.0))), 8)


# the direction he is shown in: follows `facing`, but only turns when it is clearly past the middle of the next
# eighth, so a player running along a line does not flicker between two drawings
func _sheet_direction(v):
	if v.length() < 0.05:
		return _sh_dir
	var f = atan2(v.x, v.y) / (PI / 4.0)
	var diff = fposmod(f - float(_sh_dir) + 4.0, 8.0) - 4.0
	if abs(diff) > 0.62:
		_sh_dir = posmod(int(round(f)), 8)
	return _sh_dir


# pitch direction -> screen direction (they differ only in the end-to-end camera views)
func _to_view(v):
	var par = get_parent()
	if par != null:
		var cc = par.get("camera_controller")
		if cc != null and cc.has_method("world_to_view_dir"):
			return cc.world_to_view_dir(v)
	return v


# which animation he is in right now: [plain name, restarts when this changes]
func _sheet_state():
	var spd = vis_speed
	if celebrate_t > 0.0:
		return ["celebrate", "celebrate"]
	if is_gk and (is_diving or dive_amt > 0.3):
		return ["dive", "dive"]
	if is_tackling:
		return ["tackle", "tackle"]
	if kick_anim > 0.0:
		var nm = "short_pass"
		if kick_style == "shot":
			nm = "shoot"
		elif kick_style == "chip" or kick_style == "cross" or kick_style == "clear":
			nm = "long_pass"
		elif kick_style == "throw":
			nm = "throw"
		if is_gk and nm != "throw":
			nm = "punt"
		return [nm, nm + str(kick_serial)]
	if holding_ball:
		return ["hold_ball", "hold_ball"]
	if jump_height > 1.2:
		return ["jump_head", "jump_head"]
	if is_gk and spd < 70.0:
		if dribbling and spd < 40.0:
			return ["hold", "hold"]
		return ["idle", "idle"]
	if spd < 12.0:
		return ["idle", "idle"]
	var nm2 = "walk" if spd < 100.0 else ("run" if spd < 178.0 else "sprint")
	if dribbling and nm2 != "walk":
		nm2 = "dribble"
	return [nm2, nm2]


func _sheet_update(delta):
	if not _use_sprite():
		sheet.visible = false
		return
	sheet.visible = true
	_sheet_tint()

	# size, and lifted off the ground for a header or a celebration hop
	var cel = _celebration()
	var lift = jump_height + cel["jump"]
	var sc = SHEET_SCALE * FIG_SCALE
	sheet.position = Vector2(0.0, FEET_Y - lift * FIG_SCALE)
	sheet.scale = Vector2(sc, sc * HEIGHT_STRETCH)

	var st = _sheet_state()
	var base = st[0]

	# direction: a diving keeper goes the way he dives, everybody else faces where he faces
	var idx = _sh_dir
	if base == "dive":
		idx = _eighth(_to_view(dive_dir))
	else:
		idx = _sheet_direction(vis_face)

	var restart = st[1] != _sh_base
	_sh_base = st[1]
	_sheet_set(base, idx, restart)

	# speed of the animation
	var ss = 1.0
	if SHEET_NATURAL.has(base):
		ss = clamp(vis_speed / SHEET_NATURAL[base], 0.55, 1.7)         # feet keep time with the ground
	elif SHEET_CONTACT.has(_sheet_name(base)) and SHEET_ANIMS.has(_sheet_name(base)):
		var a = SHEET_ANIMS[_sheet_name(base)]
		ss = clamp((float(SHEET_CONTACT[_sheet_name(base)]) / float(a[1])) / KICK_CONTACT_T, 0.7, 2.2)   # strike frame = release
	elif base == "tackle":
		ss = 1.5
	elif base == "dive":
		ss = 1.3
	elif base == "jump_head":
		ss = 1.2
	sheet.speed_scale = ss


# play `base` in direction idx; the frame is kept when only the direction changes (the stride does not jump)
func _sheet_set(base, idx, restart):
	var r = _sheet_resolve(base, idx)
	var full = r[1]
	if full == "":
		sheet.visible = false
		return
	sheet.visible = true
	var cur = sheet.animation
	if restart or cur != full:
		var prefix = _sheet_name(r[0]) + "_"
		var same = (not restart) and cur.begins_with(prefix)
		var keep = sheet.frame if same else 0
		sheet.play(full)
		if same and keep < sheet.frames.get_frame_count(full):
			sheet.frame = keep
	elif not sheet.playing and sheet.frames.get_animation_loop(full):
		sheet.play(full)


# the team colour, pushed into the shader whenever it changes (match.gd sets it after he is made)
func _sheet_tint():
	if _sh_mat == null:
		return
	var key = color.to_html(false)
	if key == _sh_tint_key:
		return
	_sh_tint_key = key
	_sh_mat.set_shader_param("shirt_col", color)


# the recolour shader, compiled once and shared by everybody (each player has his own material for his own colour)
static func _sheet_shader():
	if Engine.has_meta("gs_player_shader"):
		return Engine.get_meta("gs_player_shader")
	var sh = Shader.new()
	sh.code = SHEET_SHADER
	Engine.set_meta("gs_player_shader", sh)
	return sh


# SpriteFrames for the outfield players or the keepers, built once and shared by everybody

# (Godot 3 has no static variables, so they live in Engine metadata).
static func _sheet_frames(gk):
	var key = "gs_player_frames_gk" if gk else "gs_player_frames_out"
	if Engine.has_meta(key):
		return Engine.get_meta(key)
	var sf = SpriteFrames.new()
	sf.remove_animation("default")
	for anim_name in SHEET_ANIMS.keys():
		var is_gk_sheet = anim_name.begins_with("gk_")
		if not gk and is_gk_sheet:
			continue
		var sheet_name = anim_name
		if gk and not is_gk_sheet:
			sheet_name = "gk_" + anim_name
		var path = SHEET_DIR + sheet_name + ".png"
		if not ResourceLoader.exists(path):
			if not (anim_name in SHEET_OPTIONAL):
				push_warning("Player: missing sprite sheet " + sheet_name + ".png (a simpler animation is used instead)")
			continue
		var tex = load(path)
		if tex == null:
			continue
		if not SHEET_SMOOTH:
			tex.flags = tex.flags & ~Texture.FLAG_FILTER
		var n = int(SHEET_ANIMS[anim_name][0])
		for d in range(SHEET_DIRS.size()):
			var anim = "%s_%s" % [sheet_name, SHEET_DIRS[d]]
			sf.add_animation(anim)
			sf.set_animation_speed(anim, SHEET_ANIMS[anim_name][1])
			sf.set_animation_loop(anim, SHEET_ANIMS[anim_name][2])
			for f in range(n):
				var at = AtlasTexture.new()
				at.atlas = tex
				at.filter_clip = true                      # no slivers of the neighbouring frames at the edges
				at.region = Rect2(f * SHEET_FRAME, d * SHEET_FRAME, SHEET_FRAME, SHEET_FRAME)
				sf.add_frame(anim, at)
	Engine.set_meta(key, sf)
	return sf
