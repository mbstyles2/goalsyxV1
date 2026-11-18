extends Node

enum ViewMode {
	STANDARD,
	ISOMETRIC,
	PORTRAIT,
	DYNAMIC,
	VERTICAL
}

# =========================================================
# CAMERA SETTINGS
# =========================================================

var current_mode = ViewMode.DYNAMIC
var perspective_enabled = true

var target_rotation = 0.0

# Perspective parameters (set per mode in set_mode).
var far_scale = 0.80
var foreshorten = 0.90

# Dynamic mode: how much of the (projected) pitch height is visible.
# 1.0 = whole pitch height fills the screen. Lower = tighter.
const DYN_VIEW_FRACTION = 0.92
# Dynamic mode: extra zoom-out (fraction) when the ball is at full speed.
const DYN_SPEED_ZOOM_OUT = 0.10

# Portrait mode: how much of the pitch width fills the screen width.
const PORT_VIEW_FRACTION = 1.10

# Vertical end-to-end mode (FIFA-style "end to end"): the camera sits low behind your own goal and looks down the LENGTH of
# the pitch. The far goal is small at the top, the near end is big at the bottom. Depth runs along the pitch x axis.
const E2E_FAR_SCALE = 0.45           # size of things at the far end (1.0 = no perspective). Lower = stronger perspective
const E2E_FORESHORTEN = 0.55         # projected pitch length = real length * this. Lower = more tilted / flatter
const E2E_WIDTH_FRACTION = 1.0       # fraction of the pitch width on screen at the ball's depth
const E2E_ZOOM_COMP = 0.60           # 0 = zoom never changes, 1 = the ball area keeps its size wherever the ball is
const E2E_AHEAD = 0.12               # the ball sits this fraction of the screen height below the centre (see more ahead)
# Portrait: the same end-to-end view, wider and flatter (the whole pitch width at a glance).
const PORT_FAR_SCALE = 0.72
const PORT_FORESHORTEN = 0.72
const PORT_ZOOM_COMP = 0.35
const PORT_AHEAD = 0.06

# The sideways views share the tilted, broadcast "feel" of the end-to-end view, each to its own degree
# (far_scale: size of the far side, lower = stronger perspective; foreshorten: lower = flatter / more tilted).
const STD_FAR_SCALE = 0.86
const STD_FORESHORTEN = 0.92
const ISO_FAR_SCALE = 0.58
const ISO_FORESHORTEN = 0.68
const DYN_FAR_SCALE = 0.62
const DYN_FORESHORTEN = 0.74
const DEPTH_COMP = 0.35              # the zoom follows the ball's depth a little, like the end-to-end view (0 = never)
# Goal cut-scene / replay (called by replay.gd): stay on the scorer, then snap to the replay.
const SCENE_TIME = 2.4               # seconds the camera stays on the scorer after a goal
const SCENE_ZOOM = 0.80              # < 1.0 = closer
const REPLAY_ZOOM = 1.06             # a touch wider while the replay runs

# Legacy zoom for Standard / Isometric (1.0 = native size).
const BASE_ZOOM = 1.0

const FOLLOW = 7.0
const LEAD_T = 0.30
const LEAD_MAX = 150.0

# How far past the pitch the camera may drift, so the crowd stays visible.
const EDGE_MARGIN = 260.0

const SHAKE_FADE = 1.0

# =========================================================
# CAMERA REFERENCES
# =========================================================

var enabled = true

var m = null
var cam = null

var pitch = Rect2()

var cx = 0.0
var k = 0.0
var y_bottom = 0.0
var view_h = 0.0

# Original positions and scales during projection.
var saved = {}
var saved_scales = {}
var saved_rot = {}
var saved_facing = {}

# Camera movement.
var cam_pos = Vector2.ZERO
var look = Vector2.ZERO
var zoom_cur = 1.0

var inited = false
# Vertical (end-to-end) view: depth runs along the pitch length instead of the width.
var vert_axis = false
var e2e_comp = 0.0       # zoom follows the ball's depth (end-to-end modes)
var e2e_ahead = 0.0      # the ball sits this far below the screen centre (end-to-end modes)
var depth_comp = 0.0     # zoom follows the ball's depth (sideways modes)
# false = the camera is behind the LEFT goal, team 0 attacks up the screen. true = behind the right goal.
var vertical_flip = false

# Goal cut-scene / replay state.
var scene_t = 0.0
var scene_focus = Vector2.ZERO
var replay_mode = false

# Camera shake.
var shake_t = 0.0
var shake_d = 0.1
var shake_i = 0.0


# =========================================================
# INITIAL SETUP
# =========================================================

func setup(match_node, camera):
	m = match_node
	cam = camera

	if m == null or cam == null:
		return

	pitch = m.PITCH

	cx = pitch.position.x + pitch.size.x * 0.5
	y_bottom = pitch.end.y

	cam.current = true
	cam.smoothing_enabled = false
	cam.rotating = true            # Godot 3: a Camera2D only turns the view when this is on
	cam.rotation = 0.0

	set_mode(ViewMode.DYNAMIC)

	cam_pos = proj(pitch.position + pitch.size * 0.5)
	cam.position = cam_pos

	set_process_input(true)


# =========================================================
# CAMERA MODE NAMES
# =========================================================

func get_mode_name():
	match current_mode:
		ViewMode.STANDARD:
			return "Standard"

		ViewMode.ISOMETRIC:
			return "Isometric"

		ViewMode.PORTRAIT:
			return "Portrait"

		ViewMode.DYNAMIC:
			return "Dynamic"

		ViewMode.VERTICAL:
			return "Vertical"

	return "Dynamic"


# =========================================================
# CHANGE CAMERA MODE
#
# Every mode now has a tilted, perspective "broadcast" feel (see the *_FAR_SCALE / *_FORESHORTEN constants):
# STANDARD  : native zoom, gentle tilt.
# ISOMETRIC : strong tilt, slightly turned.
# PORTRAIT  : end-to-end (goals top and bottom), wider and flatter than Vertical.
# DYNAMIC   : broadcast-style, tilted. Tight on the action, follows the ball
#             with look-ahead, eases out slightly on fast play.
# VERTICAL  : end-to-end, FIFA style. The camera sits low behind your
#             own goal and looks down the length of the pitch with strong
#             perspective: far goal small at the top, near end big at the
#             bottom, ball a little below the centre. Players stay upright
#             and face the way they run on the screen; the controls turn
#             with the view; the goal cut-scene and replay work in it.
# =========================================================

func set_mode(new_mode):

	current_mode = int(new_mode) % 5

	vert_axis = false
	e2e_comp = 0.0
	e2e_ahead = 0.0
	depth_comp = 0.0

	match current_mode:

		ViewMode.STANDARD:
			# native zoom, with a gentle tilt
			perspective_enabled = true
			far_scale = STD_FAR_SCALE
			foreshorten = STD_FORESHORTEN
			target_rotation = 0.0

		ViewMode.ISOMETRIC:
			perspective_enabled = true
			far_scale = ISO_FAR_SCALE
			foreshorten = ISO_FORESHORTEN
			target_rotation = deg2rad(-12.0)
			depth_comp = DEPTH_COMP

		ViewMode.PORTRAIT:
			# end-to-end like Vertical, but wider and flatter
			vert_axis = true
			perspective_enabled = true
			far_scale = PORT_FAR_SCALE
			foreshorten = PORT_FORESHORTEN
			target_rotation = 0.0
			e2e_comp = PORT_ZOOM_COMP
			e2e_ahead = PORT_AHEAD

		ViewMode.DYNAMIC:
			perspective_enabled = true
			far_scale = DYN_FAR_SCALE
			foreshorten = DYN_FORESHORTEN
			target_rotation = 0.0
			depth_comp = DEPTH_COMP

		ViewMode.VERTICAL:
			vert_axis = true
			perspective_enabled = true
			far_scale = E2E_FAR_SCALE
			foreshorten = E2E_FORESHORTEN
			target_rotation = 0.0
			e2e_comp = E2E_ZOOM_COMP
			e2e_ahead = E2E_AHEAD

	k = 1.0 / far_scale - 1.0
	view_h = (pitch.size.x if vert_axis else pitch.size.y) * foreshorten

	if cam != null:
		cam.rotation = target_rotation
		zoom_cur = _base_zoom()
		cam.zoom = Vector2(zoom_cur, zoom_cur)

	inited = false
	look = Vector2.ZERO

	if m != null:
		m.update()


# Zoom for the current mode (Godot: smaller zoom = closer in).
func _base_zoom():
	var vp = get_viewport().get_visible_rect().size

	match current_mode:

		ViewMode.DYNAMIC:
			# Visible screen height covers a fraction of the
			# projected pitch height.
			return (view_h * DYN_VIEW_FRACTION) / max(vp.y, 1.0)

		ViewMode.PORTRAIT:
			# Screen horizontal == pitch width (world y) after the
			# 90 degree rotation. Fit the pitch width to the screen.
			return (pitch.size.y * PORT_VIEW_FRACTION) / max(vp.x, 1.0)

		ViewMode.VERTICAL:
			# The pitch width fills the screen at scale 1 (the near end); _update_view
			# then zooms with the ball's depth so the area around it keeps its size.
			return (pitch.size.y * E2E_WIDTH_FRACTION) / max(vp.x, 1.0)
	return BASE_ZOOM


# =========================================================
# CYCLE CAMERA MODES
# =========================================================

func cycle_mode():

	var next_mode = (current_mode + 1) % 5

	set_mode(next_mode)

	return get_mode_name()


# =========================================================
# KEYBOARD CAMERA SWITCHING
# Press V to switch views.
# =========================================================

func _input(event):

	if event is InputEventKey:

		if event.pressed and not event.echo:

			if event.scancode == KEY_V:
				cycle_mode()


# =========================================================
# PERSPECTIVE PROJECTION
# =========================================================

# 0 = far end ... 1 = near end, for the vertical view (depth runs along the pitch length)
func _depth_t(p):

	var u = (p.x - pitch.position.x) / pitch.size.x

	if vertical_flip:
		return u

	return 1.0 - u


func _scale_from_t(t):

	t = min(
		t,
		1.0 + 1.0 / k - 0.05
	)

	return 1.0 / (
		1.0 + k * (1.0 - t)
	)


# size factor at a pitch position. Use this one: in the vertical view the size depends on x, not y.
func scale_at_pos(p):

	if not perspective_enabled:
		return 1.0

	if vert_axis:
		return _scale_from_t(_depth_t(p))

	return scale_at(p.y)


# size factor for a pitch y (the normal views). In the vertical view it cannot know the depth: use scale_at_pos().
func scale_at(y):

	if not perspective_enabled:
		return 1.0

	if vert_axis:
		return 1.0

	var t = (y - pitch.position.y) / pitch.size.y

	return _scale_from_t(t)


func proj(p):

	if not perspective_enabled:
		return p

	if vert_axis:

		var sv = _scale_from_t(_depth_t(p))

		var lat = p.y - (pitch.position.y + pitch.size.y * 0.5)

		if vertical_flip:
			lat = -lat

		return Vector2(
			cx + lat * sv,

			y_bottom - view_h * (1.0 - sv) / (1.0 - far_scale)
		)

	var s = scale_at(p.y)

	return Vector2(
		cx + (p.x - cx) * s,

		y_bottom - view_h * (1.0 - s) / (1.0 - far_scale)
	)


func unproj(v):

	if not perspective_enabled:
		return v

	var s = 1.0 - (
		(y_bottom - v.y) *
		(1.0 - far_scale) /
		view_h
	)

	s = clamp(s, 0.3, 3.0)

	var t = 1.0 - (
		(1.0 / s) - 1.0
	) / k

	if vert_axis:

		var u = t if vertical_flip else 1.0 - t

		var lat = (v.x - cx) / s

		if vertical_flip:
			lat = -lat

		return Vector2(
			pitch.position.x + u * pitch.size.x,
			pitch.position.y + pitch.size.y * 0.5 + lat
		)

	return Vector2(
		cx + (v.x - cx) / s,
		pitch.position.y + t * pitch.size.y
	)


# =========================================================
# PROJECTED HEIGHT POSITION
# =========================================================

func hp(x, y, h):

	var up = Vector2(0.0, -h * scale_at_pos(Vector2(x, y)))

	if cam != null:
		up = up.rotated(cam.rotation)

	return proj(Vector2(x, y)) + up
# =========================================================
# VIEW <-> WORLD DIRECTIONS
# The game moves things in flat pitch coordinates. When the view is
# turned (Vertical), "up on the screen" is no longer world -y, so the
# stick / keys have to be turned with the view.
# =========================================================

# a direction as seen on the screen -> the same direction in pitch coordinates
func view_to_world_dir(v):

	if cam == null or not enabled:
		return v

	if vert_axis:
		# screen up = towards the far goal (+x), screen right = +y (mirrored when the camera is behind the other goal)
		if vertical_flip:
			return Vector2(v.y, -v.x)

		return Vector2(-v.y, v.x)

	return v.rotated(cam.rotation)


# the opposite: a direction on the pitch -> the direction it points on the screen
func world_to_view_dir(w):

	if not vert_axis:
		return w

	if vertical_flip:
		return Vector2(-w.y, w.x)

	return Vector2(w.y, -w.x)


# true while the end-to-end view is on (radar / stadium drawing use this to lay themselves out vertically)
func is_vertical():

	return vert_axis
# how far the view is turned right now (HUD drawn in pitch space uses it to stay upright)
func view_rotation():

	if cam == null:
		return 0.0

	return cam.rotation


# =========================================================
# GOAL CUT-SCENE / REPLAY HOOKS (called by replay.gd)
# =========================================================

# a goal has just gone in: stay on the scorer (pitch coordinates), a little closer
func begin_goal_scene(focus_pos):

	scene_focus = focus_pos
	scene_t = SCENE_TIME
	replay_mode = false


# the replay starts: follow the replayed ball, snapping to where it is
func begin_replay():

	scene_t = 0.0
	replay_mode = true
	inited = false
	look = Vector2.ZERO


# back to normal play: snap to the kick-off
func end_replay():

	scene_t = 0.0
	replay_mode = false
	inited = false
	look = Vector2.ZERO
# =========================================================
# RESTORE ORIGINAL POSITIONS AND SCALES
# Before physics calculations.
# =========================================================

func restore_positions():

	for n in saved.keys():

		if is_instance_valid(n):

			n.position = saved[n]

			if saved_scales.has(n):
				n.scale = saved_scales[n]

			if saved_rot.has(n):
				n.rotation = saved_rot[n]

			if saved_facing.has(n):
				n.facing = saved_facing[n]

	saved.clear()
	saved_scales.clear()
	saved_rot.clear()
	saved_facing.clear()


# =========================================================
# APPLY FAKE-3D PROJECTION
# After physics calculations.
# =========================================================

func apply_projection(delta):

	if not enabled or m == null:
		return

	saved.clear()
	saved_scales.clear()
	saved_rot.clear()
	saved_facing.clear()

	# Project players.
	for p in m.players:

		if not is_instance_valid(p):
			continue

		var logical_position = p.position

		saved[p] = logical_position
		saved_scales[p] = p.scale
		saved_rot[p] = p.rotation

		var s = scale_at_pos(logical_position)

		var base = m.GK_SCALE if p.is_gk else 1.0

		p.position = proj(logical_position)

		# end-to-end view: the player draws the way he runs ON THE SCREEN, not on the pitch
		if vert_axis:
			saved_facing[p] = p.facing
			p.facing = world_to_view_dir(p.facing)

		# A camera turned by r shows the world turned by -r, so a sprite turned by +r comes out upright on the screen
		p.rotation = saved_rot[p] + cam.rotation

		p.scale = saved_scales[p] * Vector2(
			base * s,
			base * s
		)

	# Project ball.
	if m.ball != null:

		var b = m.ball

		saved[b] = b.position
		saved_scales[b] = b.scale
		saved_rot[b] = b.rotation

		var sb = scale_at_pos(b.position)

		b.position = proj(b.position)
		b.rotation = saved_rot[b] + cam.rotation

		b.scale = saved_scales[b] * Vector2(
			sb,
			sb
		)

	_update_view(delta)


# =========================================================
# CAMERA UPDATE
# =========================================================

func update_camera(_delta):
	pass


# =========================================================
# MAIN CAMERA FOLLOW SYSTEM
# =========================================================

func _update_view(delta):

	if m == null or m.ball == null:
		return

	var b = m.ball

	var logic = saved.get(b, b.position)

	var target = b.position
	var on_scene = scene_t > 0.0

	# Predict ball movement slightly ahead.
	var ahead = proj(
		logic + b.vel * LEAD_T
	) - target

	if ahead.length() > LEAD_MAX:
		ahead = ahead.normalized() * LEAD_MAX

	if on_scene:
		# the goal cut-scene: stay on the scorer instead of the ball in the net
		scene_t = max(0.0, scene_t - delta)
		target = proj(scene_focus)
		ahead = Vector2.ZERO

	look = look.linear_interpolate(
		ahead,
		1.0 - exp(-4.0 * delta)
	)

	var want = target + look

	if vert_axis:
		# the ball sits below the centre of the screen: more of the pitch ahead of it is visible
		want.y -= get_viewport().get_visible_rect().size.y * zoom_cur * e2e_ahead

	if not inited:

		cam_pos = want
		inited = true

	else:

		cam_pos = cam_pos.linear_interpolate(
			want,
			1.0 - exp(-FOLLOW * delta)
		)

	# -----------------------------------------------------
	# ZOOM
	# Recomputed every frame so window resizes / rotation
	# of the device keep the pitch correctly framed.
	# Dynamic eases out a little when the ball is fast.
	# -----------------------------------------------------

	var zt = _base_zoom()

	var comp = e2e_comp if vert_axis else depth_comp

	if perspective_enabled and comp > 0.0:
		# the far side is drawn small: zoom in as the play goes away from the camera so the action keeps its size
		var focus = scene_focus if on_scene else logic
		zt *= pow(scale_at_pos(focus), comp)

	if current_mode == ViewMode.DYNAMIC:

		var speed_t = clamp(
			b.vel.length() / max(m.MAX_BALL_SPEED, 1.0),
			0.0,
			1.0
		)

		zt *= 1.0 + speed_t * DYN_SPEED_ZOOM_OUT

	if on_scene:
		zt *= SCENE_ZOOM
	elif replay_mode:
		zt *= REPLAY_ZOOM

	zoom_cur = lerp(
		zoom_cur,
		zt,
		1.0 - exp(-2.5 * delta)
	)

	# -----------------------------------------------------
	# CAMERA ROTATION
	# -----------------------------------------------------

	cam.rotation = lerp_angle(
		cam.rotation,
		target_rotation,
		1.0 - exp(-5.0 * delta)
	)

	# -----------------------------------------------------
	# VIEWPORT BOUNDARIES
	# Projected pitch corners, accounting for camera rotation.
	# The margin lets the camera show the crowd at the edges.
	# -----------------------------------------------------

	var viewport_size = get_viewport().get_visible_rect().size

	var half = viewport_size * zoom_cur * 0.5

	var center = proj(
		pitch.position + pitch.size * 0.5
	)

	var corners = [
		proj(pitch.position),

		proj(
			Vector2(
				pitch.end.x,
				pitch.position.y
			)
		),

		proj(pitch.end),

		proj(
			Vector2(
				pitch.position.x,
				pitch.end.y
			)
		)
	]

	var min_x = INF
	var max_x = -INF

	var min_y = INF
	var max_y = -INF

	for corner in corners:

		var local_corner = center + (
			corner - center
		).rotated(-cam.rotation)

		min_x = min(min_x, local_corner.x)
		max_x = max(max_x, local_corner.x)

		min_y = min(min_y, local_corner.y)
		max_y = max(max_y, local_corner.y)

	# Convert camera target into rotated coordinates.
	var local_pos = center + (
		cam_pos - center
	).rotated(-cam.rotation)

	# Clamp camera position.
	local_pos.x = _clamp_axis(
		local_pos.x,
		min_x - EDGE_MARGIN,
		max_x + EDGE_MARGIN,
		half.x
	)

	local_pos.y = _clamp_axis(
		local_pos.y,
		min_y - EDGE_MARGIN,
		max_y + EDGE_MARGIN,
		half.y
	)

	# Convert back to world coordinates.
	var final_pos = center + (
		local_pos - center
	).rotated(cam.rotation)

	# -----------------------------------------------------
	# CAMERA SHAKE
	# -----------------------------------------------------

	var off = Vector2.ZERO

	if shake_t > 0.0:

		shake_t = max(
			0.0,
			shake_t - delta
		)

		off = Vector2(
			rand_range(-1.0, 1.0),
			rand_range(-1.0, 1.0)
		) * shake_i * (
			shake_t / shake_d
		)

	else:

		shake_i = 0.0

	cam.position = final_pos + off

	cam.zoom = Vector2(
		zoom_cur,
		zoom_cur
	)


# =========================================================
# CAMERA BOUNDARY HELPER
# =========================================================

func _clamp_axis(value, low, high, half):

	if high - low <= half * 2.0:
		return (low + high) * 0.5

	return clamp(
		value,
		low + half,
		high - half
	)


# =========================================================
# CAMERA SHAKE
# =========================================================

func trigger_shake(intensity, duration):

	shake_i = max(
		shake_i * (
			shake_t / max(shake_d, 0.01)
		),
		intensity
	)

	shake_d = max(duration, 0.05)

	shake_t = shake_d
