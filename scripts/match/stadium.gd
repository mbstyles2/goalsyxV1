extends Reference

# ============================================================
# GOALSYX - STADIUM RENDERER
# Godot 3.x
# ============================================================

var match_node = null
var projection = null
var pitch = Rect2()

# Stands and crowd (generated once in setup)
var stand_defs = []
var crowd_chunks = []
var crowd_cache_key = ""        # the projected crowd is rebuilt only when the camera mode changes

# Visible area in draw space, used to skip off-screen crowd.
var view_rect = Rect2()

# Animation
var animation_time = 0.0

# ------------------------------------------------------------
# STADIUM DIMENSIONS
# ------------------------------------------------------------

# Distance from the pitch line to the first row of seats.
# The LED boards sit at 34, so the crowd starts right behind them.
const STAND_GAP = 52.0
# How deep the seating tiers are.
const STAND_DEPTH = 220.0

# Behind each goal there is extra room: the goal net, then a clear
# strip of grass, then the end boards, then another strip, then the
# end stands. Distances are measured from the goal line.
const END_BOARD_OFFSET = 85.0
const END_STAND_GAP = 135.0

# Spacing between spectators and layout of the seating blocks.
# The crowd is the most expensive thing on screen, so it is kept light: wider spacing and only the rows nearest
# the pitch are filled (about a third of the spectators of the old 11.0 spacing with every row). Raise
# CROWD_SPACING / CROWD_MAX_ROWS for a denser crowd, lower them for more speed.
const CROWD_SPACING = 16.0
const CROWD_MAX_ROWS = 10
const CROWD_SIZE = CROWD_SPACING / 11.0      # spectators are drawn this much bigger so the stands still look full
const AISLE_EVERY = 12
const CROWD_CHUNK = 240.0
const CHEER_PHASES = 4                       # cheering hop is done per group instead of per spectator

const BOARD_HEIGHT = 16.0

# Visual depth of the goal net. The end boards are 85 units behind
# the goal line, so there is clear space behind the net.
const GOAL_VISUAL_DEPTH = 30.0

const SKY_COLOR = Color(0.43, 0.72, 0.91)

const GRASS_OUTSIDE = Color(0.24, 0.39, 0.23)
const RUNOFF_GRASS = Color(0.13, 0.36, 0.20)
const CONCRETE = Color(0.32, 0.34, 0.37)
const DARK_CONCRETE = Color(0.17, 0.19, 0.22)

const SEAT_RED = Color(0.66, 0.17, 0.15)
const SEAT_BLUE = Color(0.12, 0.25, 0.42)

const LED_COLORS = [
	Color(0.12, 0.85, 0.95),
	Color(0.95, 0.72, 0.12),
	Color(0.95, 0.22, 0.16),
	Color(0.15, 0.85, 0.38)
]

# ------------------------------------------------------------
# SETUP
# ------------------------------------------------------------

func setup(p_match, p_projection):
	match_node = p_match
	projection = p_projection
	pitch = match_node.PITCH

	_build_stands()
	_build_stand_crowd()


# Four stands wrapped tightly around the pitch.
# "sign" is the direction pointing away from the pitch.
# Long stands cover the corners; end stands sit between them.
func _build_stands():
	stand_defs.clear()

	var P = pitch
	var g = STAND_GAP
	var d = STAND_DEPTH
	var eg = END_STAND_GAP
	var full_w = P.size.x + 2.0 * (eg + d)
	var end_h = P.size.y + 2.0 * g

	stand_defs.append({
		"rect": Rect2(P.position.x - eg - d, P.position.y - g - d, full_w, d),
		"along_x": true, "sign": -1.0
	})
	stand_defs.append({
		"rect": Rect2(P.position.x - eg - d, P.end.y + g, full_w, d),
		"along_x": true, "sign": 1.0
	})
	stand_defs.append({
		"rect": Rect2(P.position.x - eg - d, P.position.y - g, d, end_h),
		"along_x": false, "sign": -1.0
	})
	stand_defs.append({
		"rect": Rect2(P.end.x + eg, P.position.y - g, d, end_h),
		"along_x": false, "sign": 1.0
	})


func _stand_inner_edge(st):
	var r = st["rect"]

	if st["along_x"]:
		return r.end.y if st["sign"] < 0.0 else r.position.y

	return r.end.x if st["sign"] < 0.0 else r.position.x


func _build_stand_crowd():
	crowd_chunks.clear()

	var rng = RandomNumberGenerator.new()
	rng.seed = 20261021

	var home_c = Game.team_color(Game.home_id)
	var away_c = Game.team_color(Game.away_id)

	# Home / away colours appear twice so they dominate the blocks.
	var palette = [
		home_c,
		away_c,
		home_c,
		away_c,
		Color(0.88, 0.22, 0.18),
		Color(0.95, 0.82, 0.20),
		Color(0.92, 0.92, 0.92),
		Color(0.15, 0.65, 0.34),
		Color(0.20, 0.42, 0.90),
		Color(0.75, 0.45, 0.75)
	]

	var skins = [
		Color(0.96, 0.78, 0.62),
		Color(0.85, 0.62, 0.45),
		Color(0.62, 0.42, 0.30),
		Color(0.40, 0.27, 0.20),
		Color(0.22, 0.15, 0.12)
	]

	var cells = {}

	for i in range(stand_defs.size()):
		_fill_stand(stand_defs[i], i, rng, palette, skins, cells)

	# Turn the grid cells into chunks with a bounding rect so whole
	# groups of spectators can be skipped when off-screen.
	for key in cells.keys():
		var cd = cells[key]
		var pts = cd["pos"]

		var lo = pts[0]
		var hi = pts[0]

		for p in pts:
			lo.x = min(lo.x, p.x)
			lo.y = min(lo.y, p.y)
			hi.x = max(hi.x, p.x)
			hi.y = max(hi.y, p.y)

		cd["rect"] = Rect2(lo, hi - lo).grow(6.0)
		crowd_chunks.append(cd)


func _fill_stand(st, stand_id, rng, palette, skins, cells):
	var r = st["rect"]
	var along_x = st["along_x"]
	var sign_out = st["sign"]
	var step = CROWD_SPACING

	var n_along = int((r.size.x if along_x else r.size.y) / step)
	var n_depth = min(int((r.size.y if along_x else r.size.x) / step), CROWD_MAX_ROWS)

	var along_start = r.position.x if along_x else r.position.y
	var inner = _stand_inner_edge(st)

	for a in range(n_along):
		# Aisle column: leave it empty.
		if a % AISLE_EVERY == AISLE_EVERY - 1:
			continue

		# Fans sit in colour blocks, split by the aisles.
		var block = int(floor(float(a) / float(AISLE_EVERY)))
		var base = palette[(block * 3 + stand_id) % palette.size()]

		for row in range(n_depth):
			if rng.randf() < 0.05:
				continue

			var along_pos = along_start + (a + 0.5) * step + rng.randf_range(-1.5, 1.5)
			var depth_pos = inner + sign_out * (row + 0.5) * step + rng.randf_range(-1.0, 1.0)

			var pos = Vector2(along_pos, depth_pos) if along_x else Vector2(depth_pos, along_pos)

			var col = base
			if rng.randf() > 0.7:
				col = palette[rng.randi() % palette.size()]

			# Slight random shade plus darker towards the back rows.
			col = col.darkened(
				rng.randf_range(0.0, 0.22) + float(row) / float(n_depth) * 0.18
			)

			var skin = skins[rng.randi() % skins.size()]

			var key = Vector2(
				floor(pos.x / CROWD_CHUNK),
				floor(pos.y / CROWD_CHUNK)
			)

			if not cells.has(key):
				cells[key] = {"pos": [], "col": [], "skin": [], "ph": []}

			cells[key]["pos"].append(pos)
			cells[key]["col"].append(col)
			cells[key]["skin"].append(skin)
			cells[key]["ph"].append(rng.randi() % CHEER_PHASES)


# ============================================================
# MAIN DRAW FUNCTION
# ============================================================

func draw_world(c):
	if match_node == null or projection == null:
		return

	animation_time = OS.get_ticks_msec() * 0.001

	_update_view_rect(c)

	_draw_environment(c)
	_draw_outside_surroundings(c)
	_draw_stadium_foundation(c)

	_draw_stands(c)
	_draw_stand_crowd(c)

	_draw_floodlights(c)
	_draw_physical_scoreboard(c)

	_draw_pitch_surroundings(c)
	_draw_pitch(c)

	_draw_boards(c)
	_draw_goals(c)


# Bounding box of the screen in draw space (works with camera
# rotation and zoom).
func _update_view_rect(c):
	var inv = c.get_global_transform_with_canvas().affine_inverse()
	var size = c.get_viewport_rect().size

	var pts = [
		inv.xform(Vector2(0, 0)),
		inv.xform(Vector2(size.x, 0)),
		inv.xform(size),
		inv.xform(Vector2(0, size.y))
	]

	var r = Rect2(pts[0], Vector2.ZERO)

	for p in pts:
		r = r.expand(p)

	view_rect = r.grow(80.0)


# True when a logical-space rect could appear on screen.
func _rect_visible(rect):
	var corners = [
		_proj(rect.position),
		_proj(Vector2(rect.end.x, rect.position.y)),
		_proj(rect.end),
		_proj(Vector2(rect.position.x, rect.end.y))
	]

	var r = Rect2(corners[0], Vector2.ZERO)

	for p in corners:
		r = r.expand(p)

	return view_rect.intersects(r.grow(12.0))


# ============================================================
# PROJECTION HELPERS
# ============================================================

func _proj(p):
	return projection.proj(p)


# Size factor at a pitch position. In the end-to-end views the size depends on x (the depth), in the others on y.
func _scale(p):
	if projection.has_method("scale_at_pos"):
		return projection.scale_at_pos(p)

	return projection.scale_at(p.y)


# True while the camera looks down the length of the pitch (goals top and bottom).
func _vertical():
	return projection.has_method("is_vertical") and projection.is_vertical()


func _hp(x, y, height):
	return _proj(Vector2(x, y)) + Vector2(0, -height * _scale(Vector2(x, y)))

func _poly(c, points, color):
	var result = PoolVector2Array()

	for p in points:
		result.append(_proj(p))

	if result.size() < 3 or Geometry.triangulate_polygon(result).empty():
		return

	c.draw_colored_polygon(result, color)


func _line(c, a, b, color, width = 1.0):
	c.draw_line(_proj(a), _proj(b), color, max(1.0, width * _scale(a)))


func _line_height(c, a, b, height, color, width = 1.0):
	c.draw_line(
		_hp(a.x, a.y, height),
		_hp(b.x, b.y, height),
		color,
		max(1.0, width * _scale(a))
	)


func _rect_poly(c, rect, color):
	_poly(c, [
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y)
	], color)


func _dot(c, point, radius, color):
	var s = _scale(point)
	c.draw_circle(_proj(point), max(1.0, radius * s), color)


func _rect_line(c, rect, color, width = 1.0):
	var a = rect.position
	var b = Vector2(rect.end.x, rect.position.y)
	var d = rect.end
	var e = Vector2(rect.position.x, rect.end.y)

	_line(c, a, b, color, width)
	_line(c, b, d, color, width)
	_line(c, d, e, color, width)
	_line(c, e, a, color, width)


# ============================================================
# ENVIRONMENT AND SKY
# ============================================================

func _draw_environment(c):
	c.draw_rect(
		Rect2(-12000, -12000, 24000, 24000),
		SKY_COLOR
	)

	c.draw_rect(
		Rect2(-12000, -1800, 24000, 900),
		Color(0.57, 0.77, 0.87, 0.35)
	)

	c.draw_rect(
		Rect2(-12000, -900, 24000, 550),
		Color(0.85, 0.84, 0.72, 0.18)
	)

	_poly(c, [
		Vector2(-6000, -1500),
		Vector2(8000, -1500),
		Vector2(8000, -900),
		Vector2(-6000, -900)
	], Color(0.44, 0.61, 0.43))

	_draw_cloud(c, Vector2(-900, -850), 1.0)
	_draw_cloud(c, Vector2(400, -1050), 0.75)
	_draw_cloud(c, Vector2(1450, -850), 0.9)
	_draw_cloud(c, Vector2(2700, -1100), 1.1)


func _draw_cloud(c, center, size):
	var color = Color(0.96, 0.97, 0.94, 0.65)

	var offsets = [
		Vector2(-35, 5),
		Vector2(-12, -12),
		Vector2(15, -18),
		Vector2(40, -3),
		Vector2(58, 8)
	]

	for offset in offsets:
		c.draw_circle(
			center + offset * size,
			22.0 * size,
			color
		)


# ============================================================
# OUTSIDE STADIUM SURROUNDINGS
# ============================================================

func _draw_outside_surroundings(c):
	var P = pitch

	_rect_poly(
		c,
		Rect2(
			P.position.x - 1700,
			P.position.y - 1400,
			P.size.x + 3400,
			P.size.y + 2800
		),
		GRASS_OUTSIDE
	)

	_rect_poly(
		c,
		Rect2(P.position.x - 1050, P.position.y - 950, 620, 280),
		Color(0.38, 0.41, 0.41)
	)

	_rect_poly(
		c,
		Rect2(P.end.x + 350, P.position.y - 900, 600, 300),
		Color(0.37, 0.40, 0.40)
	)

	for i in range(15):
		var x = P.position.x - 1000 + i * 35
		_line(
			c,
			Vector2(x, P.position.y - 930),
			Vector2(x + 20, P.position.y - 930),
			Color(0.83, 0.84, 0.80),
			2.0
		)

	_rect_poly(
		c,
		Rect2(P.position.x - 1500, P.position.y - 1200, P.size.x + 3000, 90),
		Color(0.18, 0.20, 0.21)
	)

	_rect_poly(
		c,
		Rect2(P.position.x - 1500, P.end.y + 500, P.size.x + 3000, 95),
		Color(0.18, 0.20, 0.21)
	)

	for i in range(35):
		var x = P.position.x - 1450 + i * 110

		_line(
			c,
			Vector2(x, P.position.y - 1155),
			Vector2(x + 55, P.position.y - 1155),
			Color(0.86, 0.83, 0.65),
			3.0
		)

		_line(
			c,
			Vector2(x, P.end.y + 545),
			Vector2(x + 55, P.end.y + 545),
			Color(0.86, 0.83, 0.65),
			3.0
		)

	_draw_building(c, Vector2(P.position.x - 1150, P.position.y - 650), 220, 160)
	_draw_building(c, Vector2(P.end.x + 500, P.position.y - 620), 240, 170)
	_draw_building(c, Vector2(P.position.x - 1100, P.end.y + 220), 210, 150)
	_draw_building(c, Vector2(P.end.x + 520, P.end.y + 220), 250, 160)

	for i in range(16):
		var x = P.position.x - 1250 + i * 250
		_draw_tree(c, Vector2(x, P.position.y - 1050))
		_draw_tree(c, Vector2(x, P.end.y + 700))

	for i in range(7):
		var y = P.position.y - 850 + i * 230
		_draw_tree(c, Vector2(P.position.x - 1350, y))
		_draw_tree(c, Vector2(P.end.x + 1350, y))


func _draw_building(c, pos, width, height):
	var rect = Rect2(pos.x, pos.y, width, height)

	_rect_poly(c, rect, Color(0.56, 0.55, 0.48))

	var bs = _scale(pos)

	_screen_poly(c, [
		_proj(pos),
		_proj(pos + Vector2(width, 0)),
		_proj(pos + Vector2(width, 0)) + Vector2(30, -25) * bs,
		_proj(pos) + Vector2(25, -25) * bs
	], Color(0.28, 0.31, 0.32))

	for x in range(3):
		for y in range(2):
			var window_pos = pos + Vector2(25 + x * 65, 30 + y * 60)

			_rect_poly(
				c,
				Rect2(window_pos.x, window_pos.y, 30, 25),
				Color(0.25, 0.45, 0.53)
			)


func _draw_tree(c, pos):
	var s = _scale(pos)
	var base = _proj(pos)

	c.draw_rect(
		Rect2(base.x - 4.0 * s, base.y - 5.0 * s, 8.0 * s, 35.0 * s),
		Color(0.34, 0.23, 0.14)
	)

	c.draw_circle(
		base + Vector2(0, -25) * s,
		25.0 * s,
		Color(0.13, 0.31, 0.17)
	)

	c.draw_circle(
		base + Vector2(-12, -38) * s,
		17.0 * s,
		Color(0.20, 0.40, 0.20)
	)

# ============================================================
# STADIUM FOUNDATION
# ============================================================

func _draw_stadium_foundation(c):
	var ox = END_STAND_GAP + STAND_DEPTH + 40.0
	var oy = STAND_GAP + STAND_DEPTH + 40.0
	var outer = Rect2(
		pitch.position.x - ox,
		pitch.position.y - oy,
		pitch.size.x + ox * 2.0,
		pitch.size.y + oy * 2.0
	)

	_rect_poly(c, outer, DARK_CONCRETE)
	_rect_line(c, outer, Color(0.53, 0.55, 0.55), 7.0)


# ============================================================
# STANDS (seating tiers under the crowd)
# ============================================================

func _draw_stands(c):
	for st in stand_defs:
		_draw_stand(c, st)


func _draw_stand(c, st):
	var r = st["rect"]
	var along_x = st["along_x"]
	var sign_out = st["sign"]
	var step = CROWD_SPACING

	if not _rect_visible(r):
		return

	_rect_poly(c, r, DARK_CONCRETE)

	var inner = _stand_inner_edge(st)
	var n_depth = int((r.size.y if along_x else r.size.x) / step)
	var n_along = int((r.size.x if along_x else r.size.y) / step)
	var along_start = r.position.x if along_x else r.position.y
	var along_len = r.size.x if along_x else r.size.y

	# Tier strips: two spectator rows per step.
	var tier_color_a = SEAT_BLUE.darkened(0.45)
	var tier_color_b = SEAT_RED.darkened(0.62)

	for t in range(int(n_depth / 2)):
		var d0 = inner + sign_out * float(t) * 2.0 * step
		var d1 = d0 + sign_out * 2.0 * step

		var strip
		if along_x:
			strip = Rect2(r.position.x, min(d0, d1), r.size.x, abs(d1 - d0))
		else:
			strip = Rect2(min(d0, d1), r.position.y, abs(d1 - d0), r.size.y)

		_rect_poly(c, strip, tier_color_a if t % 2 == 0 else tier_color_b)

	# Aisles.
	var aisle_col = CONCRETE
	var a = AISLE_EVERY - 1

	while a < n_along:
		var pos = along_start + (a + 0.5) * CROWD_SPACING
		var p0
		var p1

		if along_x:
			p0 = Vector2(pos, r.position.y)
			p1 = Vector2(pos, r.end.y)
		else:
			p0 = Vector2(r.position.x, pos)
			p1 = Vector2(r.end.x, pos)

		_line(c, p0, p1, aisle_col, CROWD_SPACING * 0.9)
		a += AISLE_EVERY

	# Front barrier along the pitch side of the stand.
	var front_a
	var front_b

	if along_x:
		front_a = Vector2(r.position.x, inner)
		front_b = Vector2(r.end.x, inner)
	else:
		front_a = Vector2(inner, r.position.y)
		front_b = Vector2(inner, r.end.y)

	_line(c, front_a, front_b, Color(0.62, 0.62, 0.58), 4.0)

	_rect_line(c, r, Color(0.45, 0.47, 0.48), 3.0)


# ============================================================
# STAND CROWD
# Small body + head per spectator, drawn flat so it stays
# readable from the top-down camera.
# ============================================================

func _draw_stand_crowd(c):
	var cheering = false

	if match_node.get("crowd_t") != null:
		cheering = match_node.get("crowd_t") > 0.0

	# Screen positions only change when the camera mode does (the projection is static; the Camera2D does the
	# scrolling), so they are worked out once per mode, not once per spectator per frame.
	var key = str(projection.get("current_mode")) + str(projection.get("vertical_flip")) + str(projection.get("perspective_enabled"))

	if key != crowd_cache_key:
		crowd_cache_key = key

		for chunk in crowd_chunks:
			var sps = PoolVector2Array()
			var scs = PoolRealArray()

			for pt in chunk["pos"]:
				sps.append(_proj(pt))
				scs.append(_scale(pt))

			chunk["sp"] = sps
			chunk["sc"] = scs

	# Cheering hop: a few groups bounce out of step with each other.
	var hop = []

	for g in range(CHEER_PHASES):
		hop.append(abs(sin(animation_time * 9.0 + float(g) * 1.7)) * 5.0)

	for chunk in crowd_chunks:
		if not _rect_visible(chunk["rect"]):
			continue

		var sps = chunk["sp"]
		var scs = chunk["sc"]
		var colors = chunk["col"]
		var skins = chunk["skin"]
		var phases = chunk["ph"]

		for i in range(sps.size()):
			var sp = sps[i]

			if not view_rect.has_point(sp):
				continue

			var s = scs[i] * CROWD_SIZE

			if cheering:
				sp.y -= hop[phases[i]] * s

			# Body.
			c.draw_rect(
				Rect2(sp.x - 3.4 * s, sp.y - 2.4 * s, 6.8 * s, 5.8 * s),
				colors[i]
			)

			# Head.
			c.draw_rect(
				Rect2(sp.x - 1.6 * s, sp.y - 4.4 * s, 3.2 * s, 3.2 * s),
				skins[i]
			)

# ============================================================
# FLOODLIGHTS
# ============================================================

func _draw_floodlights(c):
	var P = pitch
	var ex = END_STAND_GAP + STAND_DEPTH + 90.0
	var ey = STAND_GAP + STAND_DEPTH + 90.0

	var positions = [
		Vector2(P.position.x - ex, P.position.y - ey),
		Vector2(P.end.x + ex, P.position.y - ey),
		Vector2(P.position.x - ex, P.end.y + ey),
		Vector2(P.end.x + ex, P.end.y + ey)
	]

	for pos in positions:
		_draw_floodlight(c, pos)


func _draw_floodlight(c, pos):
	var s = _scale(pos)
	var base = _proj(pos)
	var top = _hp(pos.x, pos.y, 250.0)
	var pole = Color(0.20, 0.22, 0.24)

	c.draw_line(base, top, pole, max(1.0, 9.0 * s))
	c.draw_line(base + Vector2(18, 0) * s, top + Vector2(8, 0) * s, pole, max(1.0, 6.0 * s))

	for i in range(4):
		c.draw_line(
			base + Vector2(0, -i * 55) * s,
			base + Vector2(18, -(i + 1) * 55) * s,
			Color(0.32, 0.34, 0.35),
			max(1.0, 3.0 * s)
		)

	c.draw_rect(
		Rect2(top.x - 30.0 * s, top.y - 12.0 * s, 70.0 * s, 24.0 * s),
		Color(0.20, 0.22, 0.25)
	)

	for i in range(5):
		c.draw_circle(
			top + Vector2(-22 + i * 14, 0) * s,
			max(2.0, 5.0 * s),
			Color(1.0, 0.91, 0.63)
		)

	c.draw_circle(
		top,
		max(5.0, 18.0 * s),
		Color(1.0, 0.82, 0.45, 0.12)
	)

# ============================================================
# PHYSICAL SCOREBOARD
# ============================================================

func _draw_physical_scoreboard(c):
	if _vertical():
		_draw_scoreboard_far_end(c)
		return

	var P = pitch

	# Mounted just behind the far stand.
	var center_x = P.position.x + P.size.x * 0.5
	var board_y = P.position.y - (STAND_GAP + STAND_DEPTH) - 140.0

	var board_pos = Vector2(center_x, board_y)
	var board_width = 370.0
	var board_height = 125.0

	_line_height(
		c,
		board_pos + Vector2(-125, 65),
		board_pos + Vector2(-125, 150),
		0,
		Color(0.18, 0.20, 0.22),
		9.0
	)

	_line_height(
		c,
		board_pos + Vector2(125, 65),
		board_pos + Vector2(125, 150),
		0,
		Color(0.18, 0.20, 0.22),
		9.0
	)

	var board = Rect2(
		board_pos.x - board_width * 0.5,
		board_pos.y - board_height * 0.5,
		board_width,
		board_height
	)

	_rect_poly(c, board.grow(12), Color(0.12, 0.14, 0.17))
	_rect_poly(c, board, Color(0.025, 0.045, 0.06))
	_rect_line(c, board, Color(0.44, 0.53, 0.58), 4.0)

	var font = _get_default_font()

	if font == null:
		return

	var text_color = Color(0.88, 0.96, 0.96)

	var home_name = _get_team_name(true)
	var away_name = _get_team_name(false)

	var home_score = _get_score(true)
	var away_score = _get_score(false)

	var timer_text = _get_timer_text()

	c.draw_string(
		font,
		_proj(Vector2(board.position.x + 18, board.position.y + 25)),
		"GOALSYX",
		Color(0.20, 0.90, 0.78)
	)

	c.draw_string(
		font,
		_proj(Vector2(board.position.x + 25, board.position.y + 57)),
		home_name,
		text_color
	)

	c.draw_string(
		font,
		_proj(Vector2(board.end.x - 125, board.position.y + 57)),
		away_name,
		text_color
	)

	c.draw_string(
		font,
		_proj(Vector2(center_x - 45, board.position.y + 85)),
		str(home_score) + " - " + str(away_score),
		Color(1.0, 0.90, 0.48)
	)

	c.draw_string(
		font,
		_proj(Vector2(center_x - 30, board.position.y + 110)),
		timer_text,
		Color(0.65, 0.90, 0.95)
	)


# End-to-end views: the scoreboard stands on legs above the stand behind the far goal, facing the camera.
func _draw_scoreboard_far_end(c):
	var P = pitch
	var flip = projection.get("vertical_flip") == true
	var far_x = P.position.x - (END_STAND_GAP + STAND_DEPTH + 140.0) if flip else P.end.x + (END_STAND_GAP + STAND_DEPTH + 140.0)
	var ground = Vector2(far_x, P.position.y + P.size.y * 0.5)
	var s = _scale(ground)
	var base = _proj(ground)
	var top = _hp(ground.x, ground.y, 230.0)
	var leg = Color(0.18, 0.20, 0.22)
	var board = Rect2(top.x - 185.0 * s, top.y - 125.0 * s, 370.0 * s, 125.0 * s)

	c.draw_line(Vector2(base.x - 125.0 * s, base.y), Vector2(board.position.x + 60.0 * s, board.end.y), leg, max(1.0, 9.0 * s))
	c.draw_line(Vector2(base.x + 125.0 * s, base.y), Vector2(board.end.x - 60.0 * s, board.end.y), leg, max(1.0, 9.0 * s))

	c.draw_rect(board.grow(12.0 * s), Color(0.12, 0.14, 0.17))
	c.draw_rect(board, Color(0.025, 0.045, 0.06))

	var font = _get_default_font()

	if font == null:
		return

	var text_color = Color(0.88, 0.96, 0.96)

	# text is laid out at full size and scaled with the board
	c.draw_set_transform(board.position, 0.0, Vector2(s, s))
	c.draw_string(font, Vector2(18, 25), "GOALSYX", Color(0.20, 0.90, 0.78))
	c.draw_string(font, Vector2(25, 57), _get_team_name(true), text_color)
	c.draw_string(font, Vector2(245, 57), _get_team_name(false), text_color)
	c.draw_string(font, Vector2(140, 85), str(_get_score(true)) + " - " + str(_get_score(false)), Color(1.0, 0.90, 0.48))
	c.draw_string(font, Vector2(155, 110), _get_timer_text(), Color(0.65, 0.90, 0.95))
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _get_default_font():

	var control = Control.new()
	var font = control.get_font("font")
	control.free()
	return font


func _get_team_name(home):
	var team_id = Game.home_id if home else Game.away_id

	if Game.has_method("team_name"):
		return str(Game.team_name(team_id))

	return "HOME" if home else "AWAY"


func _get_score(home):
	var value = match_node.get("score")

	if value == null:
		return 0

	if value is Array:
		if value.size() >= 2:
			return int(value[0] if home else value[1])

	return 0


func _get_timer_text():
	var value = match_node.get("time_left")

	if value == null:
		return "00:00"

	var seconds = max(0, int(value))
	var minutes = int(seconds / 60)
	var remaining = seconds % 60

	return "%02d:%02d" % [minutes, remaining]


# ============================================================
# PITCH SURROUNDINGS
# Grass run-off between the touchlines and the first row of
# seats, then the walkway just outside the boards.
# ============================================================

# Walkway ring around the pitch. "side" is the distance from the
# touchlines; the distance behind the goal lines is larger by the
# same amount the end boards are pushed out.
func _walk_rect(side):
	var end_d = END_BOARD_OFFSET + (side - 34.0)

	return Rect2(
		pitch.position.x - end_d,
		pitch.position.y - side,
		pitch.size.x + end_d * 2.0,
		pitch.size.y + side * 2.0
	)


func _draw_pitch_surroundings(c):
	var P = pitch

	_rect_poly(c, Rect2(
		P.position.x - END_STAND_GAP,
		P.position.y - STAND_GAP,
		P.size.x + END_STAND_GAP * 2.0,
		P.size.y + STAND_GAP * 2.0
	), RUNOFF_GRASS)

	_rect_line(
		c,
		_walk_rect(34.0),
		Color(0.10, 0.12, 0.14),
		10.0
	)

	_rect_line(
		c,
		_walk_rect(23.0),
		Color(0.67, 0.67, 0.62),
		3.0
	)


# ============================================================
# LED ADVERTISING BOARDS
# ============================================================

func _draw_boards(c):
	var P = pitch
	var ex = END_BOARD_OFFSET

	# Side boards run past the goal lines to meet the end boards.
	_draw_led_segment(
		c,
		Vector2(P.position.x - ex, P.position.y - 34),
		Vector2(P.end.x + ex, P.position.y - 34)
	)

	_draw_led_segment(
		c,
		Vector2(P.position.x - ex, P.end.y + 34),
		Vector2(P.end.x + ex, P.end.y + 34)
	)

	# End boards sit well behind the goals.
	_draw_led_segment(
		c,
		Vector2(P.position.x - ex, P.position.y - 34),
		Vector2(P.position.x - ex, P.end.y + 34)
	)

	_draw_led_segment(
		c,
		Vector2(P.end.x + ex, P.position.y - 34),
		Vector2(P.end.x + ex, P.end.y + 34)
	)


func _draw_led_segment(c, a, b):
	_line(c, a, b, Color(0.035, 0.045, 0.055), BOARD_HEIGHT)

	var length = a.distance_to(b)
	var segments = max(1, int(length / 180.0))

	for i in range(segments):
		var t1 = float(i) / segments
		var t2 = float(i + 1) / segments

		var p1 = a.linear_interpolate(b, t1)
		var p2 = a.linear_interpolate(b, t2)

		var color = LED_COLORS[i % LED_COLORS.size()]

		_line(c, p1, p2, color, 5.0)


# ============================================================
# GOALS
# Goal with height: posts, crossbar, sloped roof and side nets,
# a lower rear frame, and mesh. Heights use the same projected
# height system as everything else, so it follows the camera.
# ============================================================

func _draw_goals(c):
	_draw_goal(c, true)
	_draw_goal(c, false)


func _draw_goal(c, left_goal):
	var P = pitch

	var goal_x = P.position.x if left_goal else P.end.x
	var direction = -1.0 if left_goal else 1.0
	var center_y = P.position.y + P.size.y * 0.5
	var half_width = float(match_node.GOAL_H) * 0.5
	var depth = GOAL_VISUAL_DEPTH

	# Real goals are roughly 3:1 wide to tall. The back of the
	# frame is lower than the front, like a real goal.
	var height = clamp(half_width * 2.0 / 3.0, 28.0, 90.0)
	var rear = height * 0.6

	var s = _scale(Vector2(goal_x, center_y))

	# Ground corners. "a" is the upper post on screen, "b" the lower.
	var fa = Vector2(goal_x, center_y - half_width)
	var fb = Vector2(goal_x, center_y + half_width)
	var ba = Vector2(goal_x + direction * depth, fa.y)
	var bb = Vector2(goal_x + direction * depth, fb.y)

	var fa_top = _hp(fa.x, fa.y, height)
	var fb_top = _hp(fb.x, fb.y, height)
	var ba_top = _hp(ba.x, ba.y, rear)
	var bb_top = _hp(bb.x, bb.y, rear)

	var net_fill = Color(0.90, 0.94, 0.92, 0.16)
	var net_back = Color(0.60, 0.66, 0.64, 0.30)
	var net_mesh = Color(0.93, 0.96, 0.94, 0.50)

	# ------------------------------------------------------------
	# Ground shadow
	# ------------------------------------------------------------
	var off = Vector2(6.0, 7.0) * s
	_screen_poly(c, [
		_proj(fa) + off, _proj(fb) + off,
		_proj(bb) + off, _proj(ba) + off
	], Color(0.02, 0.05, 0.03, 0.35))

	# ------------------------------------------------------------
	# Net panels (back, roof, two sides)
	# ------------------------------------------------------------
	_screen_poly(c, [_proj(ba), _proj(bb), bb_top, ba_top], net_back)
	_screen_poly(c, [fa_top, fb_top, bb_top, ba_top], net_fill)
	_screen_poly(c, [_proj(fa), _proj(ba), ba_top, fa_top], net_fill)
	_screen_poly(c, [_proj(fb), _proj(bb), bb_top, fb_top], net_fill)

	# ------------------------------------------------------------
	# Net mesh
	# ------------------------------------------------------------
	for i in range(1, 7):
		var t = float(i) / 7.0

		# Back panel: horizontal strands and vertical strands.
		_screen_line(c,
			_hp(ba.x, ba.y, rear * t), _hp(bb.x, bb.y, rear * t),
			net_mesh, 1.0)

		var g = ba.linear_interpolate(bb, t)
		_screen_line(c, _proj(g), _hp(g.x, g.y, rear), net_mesh, 1.0)

		# Roof strands running front to back.
		var f = fa.linear_interpolate(fb, t)
		var r = ba.linear_interpolate(bb, t)
		_screen_line(c,
			_hp(f.x, f.y, height), _hp(r.x, r.y, rear),
			net_mesh, 1.0)

	for i in range(1, 5):
		var t = float(i) / 5.0
		var h = lerp(height, rear, t)

		# Side panels: vertical strands.
		var ga = fa.linear_interpolate(ba, t)
		var gb = fb.linear_interpolate(bb, t)
		_screen_line(c, _proj(ga), _hp(ga.x, ga.y, h), net_mesh, 1.0)
		_screen_line(c, _proj(gb), _hp(gb.x, gb.y, h), net_mesh, 1.0)

		# Side panels: horizontal strands.
		var u = float(i) / 5.0
		_screen_line(c,
			_hp(fa.x, fa.y, height * u), _hp(ba.x, ba.y, rear * u),
			net_mesh, 1.0)
		_screen_line(c,
			_hp(fb.x, fb.y, height * u), _hp(bb.x, bb.y, rear * u),
			net_mesh, 1.0)

	# ------------------------------------------------------------
	# Rear frame: ground rails, rear uprights, rear top bar
	# ------------------------------------------------------------
	_tube(c, _proj(fa), _proj(ba), 2.5 * s)
	_tube(c, _proj(fb), _proj(bb), 2.5 * s)
	_tube(c, _proj(ba), _proj(bb), 2.5 * s)

	_tube(c, _proj(ba), ba_top, 3.2 * s)
	_tube(c, _proj(bb), bb_top, 3.2 * s)
	_tube(c, ba_top, bb_top, 3.2 * s)

	# Angled top bars from the front posts down to the rear uprights.
	_tube(c, fa_top, ba_top, 3.2 * s)
	_tube(c, fb_top, bb_top, 3.2 * s)

	# ------------------------------------------------------------
	# Front posts and crossbar, drawn last so they stay prominent
	# ------------------------------------------------------------
	_tube(c, _proj(fa), fa_top, 5.0 * s)
	_tube(c, _proj(fb), fb_top, 5.0 * s)
	_tube(c, fa_top, fb_top, 5.5 * s)

	# Post bases.
	_dot(c, fa, 4.0, Color(0.10, 0.12, 0.12, 0.8))
	_dot(c, fb, 4.0, Color(0.10, 0.12, 0.12, 0.8))


# White tube with a dark outline and a thin highlight.
func _tube(c, a, b, width):
	width = max(1.5, width)

	c.draw_line(a, b, Color(0.14, 0.17, 0.18, 0.9), width + 2.2, true)
	c.draw_line(a, b, Color(0.96, 0.97, 0.96), width, true)

	if width >= 3.0:
		var hl = Vector2(-width * 0.22, -width * 0.22)
		c.draw_line(a + hl, b + hl, Color(1, 1, 1, 0.9), max(1.0, width * 0.25), true)


func _screen_line(c, a, b, color, width):
	c.draw_line(a, b, color, width, true)


# Polygon in screen space. Skips shapes that cannot be triangulated,
# which would otherwise raise "Invalid polygon data".
func _screen_poly(c, points, color):
	var pts = PoolVector2Array(points)

	if pts.size() < 3:
		return

	if Geometry.triangulate_polygon(pts).empty():
		return

	c.draw_colored_polygon(pts, color)


# ============================================================
# PITCH
# ============================================================

func _draw_pitch(c):
	var P = pitch

	_rect_poly(
		c,
		P,
		Color(0.16, 0.42, 0.22)
	)

	var stripe_width = P.size.x / 12.0

	for i in range(12):
		if i % 2 == 0:
			var stripe = Rect2(
				P.position.x + i * stripe_width,
				P.position.y,
				stripe_width,
				P.size.y
			)

			_rect_poly(
				c,
				stripe,
				Color(0.20, 0.47, 0.25)
			)

	_rect_line(c, P, Color(0.94, 0.95, 0.88), 4.0)

	var center = P.position + P.size * 0.5

	_line(
		c,
		Vector2(center.x, P.position.y),
		Vector2(center.x, P.end.y),
		Color(0.94, 0.95, 0.88),
		4.0
	)

	_draw_circle_outline(
		c,
		center,
		130.0,
		Color(0.94, 0.95, 0.88),
		4.0
	)

	_dot(c, center, 5.0, Color(0.96, 0.96, 0.90))

	_rect_line(
		c,
		Rect2(P.position.x, center.y - 270, 320, 540),
		Color(0.94, 0.95, 0.88),
		4.0
	)

	_rect_line(
		c,
		Rect2(P.end.x - 250, center.y - 270, 320, 540),
		Color(0.94, 0.95, 0.88),
		4.0
	)

	_rect_line(
		c,
		Rect2(P.position.x, center.y - 100, 90, 200),
		Color(0.94, 0.95, 0.88),
		4.0
	)

	_rect_line(
		c,
		Rect2(P.end.x - 90, center.y - 100, 90, 200),
		Color(0.94, 0.95, 0.88),
		4.0
	)

	_dot(
		c,
		Vector2(P.position.x + 180, center.y),
		5.0,
		Color(0.96, 0.96, 0.90)
	)

	_dot(
		c,
		Vector2(P.end.x - 180, center.y),
		5.0,
		Color(0.96, 0.96, 0.90)
	)


func _draw_circle_outline(c, center, radius, color, width):
	var points = PoolVector2Array()

	for i in range(49):
		var angle = PI * 2.0 * float(i) / 48.0
		var p = center + Vector2(cos(angle), sin(angle)) * radius
		points.append(_proj(p))

	c.draw_polyline(points, color, width)


# ============================================================
# END OF STADIUM RENDERER
# ============================================================
