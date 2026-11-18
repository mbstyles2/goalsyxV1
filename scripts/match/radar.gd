extends CanvasLayer
# Radar / minimap along the bottom of the screen: the whole pitch from above with every player, the ball
# (with a short trail), who you control, how fast everybody is moving, and the part of the pitch the
# camera is showing right now. Press M to hide / show it.
#
# In the end-to-end camera modes (goals at the top and bottom of the screen) it turns into a vertical mini-pitch at the
# left-middle of the screen, laid out the same way as the view, so "up" on the radar is "up" on the screen.
#
# match.gd adds it as a child: add_child(MatchRadar.new(self)).

const RADAR_W = 220.0             # width on a 960-wide screen (scales with the screen)
const MARGIN_BOTTOM = 8.0
const RADAR_V_W = 84.0            # width of the vertical radar on a 960-wide screen (its height follows the pitch)
const RADAR_V_MARGIN = 14.0       # gap from the left edge of the screen
const BG_ALPHA = 0.62
const TRAIL_POINTS = 14

var m
var canvas
var shown = true
var key_prev = false
var trail = []
var trail_t = 0.0
# set every frame so the helper functions can map pitch -> radar
var rx = 0.0
var ry = 0.0
var rw = 1.0
var rh = 1.0
var ui = 1.0
var vert = false                  # the vertical (end-to-end) layout is on
var flip = false                  # the camera is behind the right-hand goal


class RadarCanvas extends Node2D:
	var host

	func _draw():
		if host != null:
			host.draw_radar(self)


func _init(match_node):
	m = match_node
	layer = 6


func _ready():
	canvas = RadarCanvas.new()
	canvas.host = self
	add_child(canvas)


# positions as the GAME sees them (flat), not as the fake-3D camera shows them
func _flat(n):
	var cc = m.camera_controller
	if m.USE_FAKE_3D and cc != null and cc.saved.has(n):
		return cc.saved[n]
	return n.position


# pitch position -> radar position
func _rp(v):
	var P = m.PITCH
	var u = (v.x - P.position.x) / P.size.x       # 0 = left goal ... 1 = right goal
	var l = (v.y - P.position.y) / P.size.y       # 0 = top touchline ... 1 = bottom touchline

	if vert:
		# the far goal is at the top, like on the screen
		if flip:
			return Vector2(rx + (1.0 - l) * rw, ry + u * rh)

		return Vector2(rx + l * rw, ry + (1.0 - u) * rh)

	return Vector2(rx + u * rw, ry + l * rh)


# a direction on the pitch -> the direction it points on the radar
func _rd(w):
	if not vert:
		return w

	if flip:
		return Vector2(-w.y, w.x)

	return Vector2(w.y, -w.x)


# a rectangle in pitch coordinates -> the same rectangle on the radar
func _rrect(r):
	var a = _rp(r.position)
	var b = _rp(r.end)

	return Rect2(Vector2(min(a.x, b.x), min(a.y, b.y)), Vector2(abs(b.x - a.x), abs(b.y - a.y)))


func _check_layout():
	var cc = m.camera_controller
	vert = m.USE_FAKE_3D and cc != null and cc.has_method("is_vertical") and cc.is_vertical()
	flip = vert and cc.get("vertical_flip") == true
func _process(delta):
	var down = Input.is_key_pressed(KEY_M)
	if down and not key_prev:
		shown = not shown
	key_prev = down
	var hidden = m.state == "shootout" or (m.ui_controller != null and m.ui_controller.intro_active)
	canvas.visible = shown and not hidden
	if m.ball != null:
		trail_t += delta
		if trail_t >= 0.06:
			trail_t = 0.0
			trail.append(_flat(m.ball))
			if trail.size() > TRAIL_POINTS:
				trail.pop_front()
	canvas.update()


func draw_radar(c):
	if m.ball == null or m.players.empty():
		return
	_check_layout()
	var P = m.PITCH
	var vp = get_viewport().get_visible_rect().size
	ui = vp.x / 960.0
	var pad = 6.0 * ui
	if vert:
		rw = RADAR_V_W * ui
		rh = rw * P.size.x / P.size.y                  # same shape as the pitch, standing up
		rx = RADAR_V_MARGIN * ui
		ry = (vp.y - rh) * 0.5
	else:
		rw = RADAR_W * ui
		rh = rw * P.size.y / P.size.x                  # same shape as the pitch
		rx = (vp.x - rw) * 0.5
		ry = vp.y - rh - pad - MARGIN_BOTTOM * ui
	var d = m.active_pitch_data

	# panel + pitch
	c.draw_rect(Rect2(rx - pad, ry - pad, rw + pad * 2.0, rh + pad * 2.0), Color(0.04, 0.05, 0.08, BG_ALPHA))
	var n = 12
	for i in range(n):
		var col = d["stripe_a"] if i % 2 == 0 else d["stripe_b"]
		var sr = _rrect(Rect2(P.position.x + i * P.size.x / n, P.position.y, P.size.x / n, P.size.y)).grow(0.5)
		c.draw_rect(sr, Color(col.r, col.g, col.b, 0.85))
	var line = Color(1, 1, 1, 0.75)
	var k = (rw / P.size.y) if vert else (rw / P.size.x)      # radar pixels per pitch unit
	var cyp = P.position.y + P.size.y * 0.5
	var cxp = P.position.x + P.size.x * 0.5
	c.draw_rect(Rect2(rx, ry, rw, rh), line, false, 1.0)
	c.draw_line(_rp(Vector2(cxp, P.position.y)), _rp(Vector2(cxp, P.end.y)), line, 1.0)
	c.draw_arc(_rp(Vector2(cxp, cyp)), 75.0 * k, 0.0, TAU, 24, line, 1.0)
	c.draw_rect(_rrect(Rect2(P.position.x, cyp - 250.0, 300.0, 500.0)), line, false, 1.0)
	c.draw_rect(_rrect(Rect2(P.end.x - 300.0, cyp - 250.0, 300.0, 500.0)), line, false, 1.0)
	var gd = 3.0 * ui / k                              # the goals stick out of the pitch by 3 screen pixels
	c.draw_rect(_rrect(Rect2(P.position.x - gd, cyp - m.GOAL_H * 0.5, gd, m.GOAL_H)), line)
	c.draw_rect(_rrect(Rect2(P.end.x, cyp - m.GOAL_H * 0.5, gd, m.GOAL_H)), line)

	# what the camera is showing
	_draw_view(c, vp)

	# ball trail
	for i in range(trail.size() - 1):
		var a = float(i + 1) / trail.size()
		c.draw_line(_rp(trail[i]), _rp(trail[i + 1]), Color(1, 1, 1, 0.55 * a), 1.5 * ui)

	# players: coloured dot, a tick showing where he is running, a ring on the ones you control
	var sel0 = m.sel[0]
	var sel1 = m.sel[1] if Game.two_player else null
	for p in m.players:
		var pos = _rp(_flat(p))
		var r = (3.6 if p.is_gk else 3.0) * ui
		if p.vel.length() > 20.0:
			c.draw_line(pos, pos + _rd(p.vel) * 0.25 * k, p.color.lightened(0.45), 1.2 * ui)
		c.draw_circle(pos, r + 1.0 * ui, Color(1, 1, 1, 0.95) if p.team == 1 else Color(0, 0, 0, 0.85))
		c.draw_circle(pos, r, p.color)
		if p == sel0 or p == sel1:
			c.draw_arc(pos, r + 2.6 * ui, 0.0, TAU, 14, p.ring, 1.6 * ui)

	# the ball (a ring around it while it is in the air; the carrier's colour when someone has it)
	var bp = _rp(_flat(m.ball))
	if m.ball.height_z > 8.0:
		c.draw_arc(bp, 4.6 * ui, 0.0, TAU, 12, Color(1, 1, 1, 0.6), 1.0 * ui)
	if m.dribble_owner != null and is_instance_valid(m.dribble_owner):
		c.draw_arc(bp, 3.6 * ui, 0.0, TAU, 12, m.dribble_owner.color.lightened(0.3), 1.4 * ui)
	c.draw_circle(bp, 2.7 * ui, Color(0.05, 0.05, 0.05))
	c.draw_circle(bp, 2.0 * ui, Color.white)


# the camera's view as an outline on the radar (a trapezoid when the fake-3D view is on)
func _draw_view(c, vp):
	var cam = m.camera
	if cam == null:
		return
	var P = m.PITCH
	var half = vp * 0.5 * cam.zoom
	var centre = cam.get_camera_screen_center()
	var pts = PoolVector2Array()
	for sgn in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var v = centre + Vector2(half.x * sgn.x, half.y * sgn.y)
		if m.USE_FAKE_3D and m.camera_controller != null:
			v = m.camera_controller.unproj(v)
		v.x = clamp(v.x, P.position.x, P.end.x)
		v.y = clamp(v.y, P.position.y, P.end.y)
		pts.append(_rp(v))
	pts.append(pts[0])
	c.draw_polyline(pts, Color(1.0, 0.9, 0.2, 0.8), 1.2 * ui)

func _safe_poly(c, pts, col):
	var packed = PoolVector2Array(pts)
	if packed.size() < 3 or Geometry.triangulate_polygon(packed).empty():
		return
	c.draw_colored_polygon(packed, col)
