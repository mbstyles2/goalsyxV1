extends Reference
# REPLAY + GOAL CUT-SCENE.
#
# What the player sees after a goal:
#   GOAL banner (match.gd's own "goal" state, 2 s)  ->  fade to black  ->  REPLAY of the last few seconds in slow
#   motion, easing slower as the ball nears the net  ->  hold on the goal  ->  fade to black  ->  kick-off.
# Any key / click / tap during the replay skips it.
#
# How it works
#   * While the match is "playing" it keeps the last PRE_SECONDS of play in a ring buffer: ball + all 22 players,
#     30 samples per second, in REAL (flat) game coordinates. The camera (camera.gd now, the vertical end-to-end
#     view later) only projects those positions, so a replay looks right through ANY camera with no extra work.
#   * A restart (kick-off, throw-in, free kick ...) teleports the ball, which empties the buffer, so the clip starts
#     at the restart and never smears across a jump.
#   * Playback writes the interpolated positions back onto the real nodes each tick and runs the camera, while
#     match.gd's game logic is paused (state "replay"). The ball is `frozen` so ball.gd's own height physics
#     does not fight the playback. Nothing is simulated twice, so nothing can drift.
#   * match._kickoff() already resets every player / ball field the replay touches.
#
# Camera hooks (optional, called only if camera.gd defines them; nothing breaks without them):
#   begin_goal_scene(focus_pos)   the goal has just gone in: push in on the scorer / the ball
#   begin_replay()                the replay is starting (e.g. pull back, or switch to a goal-line angle)
#   end_replay()                  back to normal play

const STEP = 1.0 / 30.0          # seconds between samples
const PRE_SECONDS = 5.0          # how much play before the goal a replay shows (at most)
const MAX_FRAMES = 151           # = PRE_SECONDS / STEP + 1
const MIN_CLIP = 1.5             # a goal straight from a restart with less play than this gets no replay
const JUMP = 160.0               # px: a bigger move between two samples is a teleport (restart), not play

const SPEED = 0.8                # playback speed
const SPEED_END = 0.4            # ...easing down for the last SLOW_LAST seconds, as the ball goes in
const SLOW_LAST = 1.2
const HOLD = 0.9                 # seconds held on the final frame
const FADE = 0.25                # seconds of each fade to / from black

const BALL_N = 3                 # x, y, height_z
const STRIDE = 10                # per player: x y vx vy fx fy kick_cd tackle_timer jump_height flags

var m
var enabled = true
var frames = []                  # PoolRealArray per sample, oldest first
var acc = 0.0
var armed = false                # a goal has just been scored: capture the final frame once
var goal_scorer = -1

var phase = ""                   # "" | to_black | from_black | play | hold | to_black_end | reveal
var phase_t = 0.0
var head = 0.0                   # playback position in seconds
var clip_len = 0.0
var fade = null


func _init(match_node):
	m = match_node


# builds the fade overlay on the HUD layer (call once the HUD exists)
func setup():
	if m.lbl_msg == null:
		enabled = false
		return
	var root = m.lbl_msg.get_parent()
	fade = ColorRect.new()
	fade.rect_position = Vector2(-300, -300)
	fade.rect_size = Vector2(1200, 900)
	fade.color = Color(0, 0, 0, 0)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade.hide()
	root.add_child(fade)


# ------------------------------------------------------------ called by match.gd

# every physics tick, after the game tick and before the camera projection
func tick(delta):
	if not enabled:
		return
	var s = m.state
	if s == "playing":
		_record(delta)
	elif s == "goal" and armed:
		armed = false
		_capture()                                   # the last frame: the ball in the net
	elif s == "replay":
		_run(delta)
	if phase == "reveal":
		phase_t += delta
		_set_veil(1.0 - phase_t / FADE)
		if phase_t >= FADE:
			phase = ""
			_set_veil(0.0)


# match._goal(): the goal has just been scored
func on_goal(scorer):
	if not enabled:
		return
	armed = true
	goal_scorer = scorer
	var focus = m.ball.position
	var lt = m.last_touch
	if lt != null and is_instance_valid(lt) and lt.team == scorer:
		focus = lt.position
	_cam("begin_goal_scene", [focus])


# match.gd, when the goal banner has been up long enough: true = the replay took over (state is now "replay")
func start():
	if not enabled or fade == null:
		return false
	if frames.size() < int(MIN_CLIP / STEP) + 1:
		return false
	clip_len = float(frames.size() - 1) * STEP
	phase = "to_black"
	phase_t = 0.0
	m.state = "replay"
	return true


# any key / click / tap
func skip():
	if m.state == "replay" and phase in ["from_black", "play", "hold"]:
		phase = "to_black_end"
		phase_t = 0.0


# ------------------------------------------------------------ recording

func _record(delta):
	acc += delta
	if acc < STEP:
		return
	acc = min(acc - STEP, STEP)
	_capture()


func _capture():
	var b = m.ball
	var ps = m.players
	var f = PoolRealArray()
	f.resize(BALL_N + ps.size() * STRIDE)
	f[0] = b.position.x
	f[1] = b.position.y
	f[2] = b.height_z
	var o = BALL_N
	for p in ps:
		f[o] = p.position.x
		f[o + 1] = p.position.y
		f[o + 2] = p.vel.x
		f[o + 3] = p.vel.y
		f[o + 4] = p.facing.x
		f[o + 5] = p.facing.y
		f[o + 6] = p.kick_cd
		f[o + 7] = p.tackle_timer
		f[o + 8] = p.jump_height
		f[o + 9] = (1.0 if p.is_tackling else 0.0) + (2.0 if p.is_diving else 0.0)
		o += STRIDE
	if not frames.empty() and _jumped(frames.back(), f, ps.size()):
		frames.clear()                               # a restart: the clip starts here
	frames.append(f)
	while frames.size() > MAX_FRAMES:
		frames.pop_front()


func _jumped(a, b, n):
	if Vector2(a[0] - b[0], a[1] - b[1]).length() > JUMP:
		return true
	var o = BALL_N
	for i in range(n):
		if Vector2(a[o] - b[o], a[o + 1] - b[o + 1]).length() > JUMP:
			return true
		o += STRIDE
	return false


# ------------------------------------------------------------ playback

func _run(delta):
	phase_t += delta
	if phase == "to_black":
		_set_veil(phase_t / FADE)
		if phase_t >= FADE:
			_enter_replay()
	elif phase == "from_black":
		_set_veil(1.0 - phase_t / FADE)
		_advance(delta)
		if phase_t >= FADE:
			phase = "play"
	elif phase == "play":
		_advance(delta)
		if head >= clip_len:
			phase = "hold"
			phase_t = 0.0
	elif phase == "hold":
		m._update_camera(delta)
		if phase_t >= HOLD:
			phase = "to_black_end"
			phase_t = 0.0
	elif phase == "to_black_end":
		m._update_camera(delta)
		_set_veil(phase_t / FADE)
		if phase_t >= FADE:
			_leave()


func _enter_replay():
	head = 0.0
	m.ball.frozen = true
	_apply(0.0)
	m._show_msg("REPLAY", 0)
	_cam("begin_replay")
	phase = "from_black"
	phase_t = 0.0


func _advance(delta):
	var spd = SPEED_END if clip_len - head < SLOW_LAST else SPEED
	head = min(head + delta * spd, clip_len)
	_apply(head)
	m._update_camera(delta)                          # the camera follows the replayed ball like it follows the live one


func _leave():
	m.ball.frozen = false
	_cam("end_replay")
	m._show_msg("", 0)
	phase = "reveal"
	phase_t = 0.0
	_set_veil(1.0)
	frames.clear()
	m._after_goal()                                  # kick-off (or the end of the match on a golden / set-ending goal)


# write the clip at time t back onto the real ball and players
func _apply(t):
	var n = frames.size()
	var fi = clamp(t / STEP, 0.0, float(n - 1))
	var i = int(floor(fi))
	var j = min(i + 1, n - 1)
	var a = fi - float(i)
	var A = frames[i]
	var B = frames[j]
	var ball = m.ball
	ball.position = Vector2(lerp(A[0], B[0], a), lerp(A[1], B[1], a))
	ball.height_z = lerp(A[2], B[2], a)
	ball.vel = Vector2(B[0] - A[0], B[1] - A[1]) / STEP     # only drives the ball's spin graphic
	ball.vel_z = 0.0
	var src = A if a < 0.5 else B
	var o = BALL_N
	for p in m.players:
		p.position = Vector2(lerp(A[o], B[o], a), lerp(A[o + 1], B[o + 1], a))
		p.vel = Vector2(lerp(A[o + 2], B[o + 2], a), lerp(A[o + 3], B[o + 3], a))
		var fv = Vector2(lerp(A[o + 4], B[o + 4], a), lerp(A[o + 5], B[o + 5], a))
		if fv.length() > 0.05:
			p.facing = fv.normalized()
		p.kick_cd = src[o + 6]                       # drives the kick animation
		p.tackle_timer = src[o + 7]
		p.jump_height = src[o + 8]
		var fl = int(src[o + 9])
		p.is_tackling = (fl & 1) != 0
		p.is_diving = (fl & 2) != 0
		p.update()
		o += STRIDE


# ------------------------------------------------------------ helpers

func _set_veil(a):
	if fade == null:
		return
	a = clamp(a, 0.0, 1.0)
	fade.color = Color(0, 0, 0, a)
	if a > 0.001:
		fade.show()
	else:
		fade.hide()


func _cam(method, args = []):
	var c = m.camera_controller
	if c != null and c.has_method(method):
		c.callv(method, args)
