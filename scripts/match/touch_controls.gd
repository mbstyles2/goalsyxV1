extends CanvasLayer
# On-screen controls for phones / tablets / touch browsers.
#
#   left  : small analog stick (partial tilt = slower walk)
#   right : SHOOT (big), PASS, TACKLE, SWITCH        [pause button: top-right]
#   shootouts: the stick and buttons are replaced by HIGH / MID / LOW
#
# They only show on touch devices (OS.has_touchscreen_ui_hint()) or as soon as
# the first touch is received. To try them on a PC, either set SHOW_ON_DESKTOP
# below to true, or turn on Project Settings > Input Devices > Pointing >
# "Emulate Touch From Mouse".
#
# Single player only: the controls drive team 0 (the human side). match.gd reads
# `move`, `shoot`, `pass_held`, `tackle`, consume_switch() and zone_pressed()
# right next to its keyboard code, so keys and touch work side by side.

const UIStyle = preload("res://scripts/ui/ui_style.gd")

const SHOW_ON_DESKTOP = false
const DEAD_ZONE = 0.18       # stick dead zone (0..1)
const FULL_TILT = 0.85       # tilt at which the player runs at full speed
const GRAB_SCALE = 1.7       # a touch this many stick-radii from the centre grabs the stick
const ZONE_WINDOW_MS = 700   # a shootout tap stays valid this long

var match_node
var canvas
var font
var active = false
var in_shootout = false
var hints_hidden = false

# what match.gd reads
var move = Vector2.ZERO
var shoot = false
var pass_held = false
var tackle = false
var switch_flag = false
var zone_value = -2
var zone_ms = 0

var touches = {}             # finger index -> role ("stick", "shoot", ...)
var stick_vec = Vector2.ZERO # knob offset (0..1), for drawing


func _init(m = null):
	match_node = m
	layer = 4


func _ready():
	active = SHOW_ON_DESKTOP or OS.has_touchscreen_ui_hint()
	font = UIStyle.make_font(13)
	canvas = Control.new()
	canvas.anchor_right = 1.0
	canvas.anchor_bottom = 1.0
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.connect("draw", self, "_on_draw")
	canvas.visible = active
	add_child(canvas)


# ------------------------------------------------------------------- public

# True when these controls should drive `team` (single player, human = team 0).
func is_active_for(team):
	return active and team == 0 and not Game.two_player


func consume_switch():
	var f = switch_flag
	switch_flag = false
	return f


# HIGH / MID / LOW tapped during a shootout: -1 / 0 / 1, or -2 for none.
func zone_pressed():
	var z = zone_value
	zone_value = -2
	if z != -2 and OS.get_ticks_msec() - zone_ms <= ZONE_WINDOW_MS:
		return z
	return -2


# ------------------------------------------------------------------- layout
# Everything is laid out for a 960x540 screen and scaled to the real size.

func _view():
	return get_viewport().get_visible_rect().size


func _s():
	return _view().y / 540.0


func _stick_center():
	return Vector2(120.0 * _s(), _view().y - 105.0 * _s())


func _stick_radius():
	return 55.0 * _s()


# name -> [centre, radius, label]
func _buttons():
	var sz = _view()
	var s = _s()
	var out = {}
	if in_shootout:
		out["zone-1"] = [Vector2(sz.x - 90.0 * s, sz.y - 250.0 * s), 36.0 * s, "HIGH"]
		out["zone0"] = [Vector2(sz.x - 90.0 * s, sz.y - 165.0 * s), 36.0 * s, "MID"]
		out["zone1"] = [Vector2(sz.x - 90.0 * s, sz.y - 80.0 * s), 36.0 * s, "LOW"]
	else:
		out["shoot"] = [Vector2(sz.x - 80.0 * s, sz.y - 80.0 * s), 38.0 * s, "SHOOT"]
		out["pass"] = [Vector2(sz.x - 175.0 * s, sz.y - 50.0 * s), 28.0 * s, "PASS"]
		out["tackle"] = [Vector2(sz.x - 45.0 * s, sz.y - 175.0 * s), 28.0 * s, "TACKLE"]
		out["switch"] = [Vector2(sz.x - 155.0 * s, sz.y - 145.0 * s), 26.0 * s, "SWITCH"]
	out["pause"] = [Vector2(sz.x - 36.0 * s, 36.0 * s), 20.0 * s, "II"]
	return out


# ------------------------------------------------------------------ updating

func _process(_delta):
	if not active or match_node == null or not is_instance_valid(match_node):
		return
	var so = match_node.get("state") == "shootout"
	if so != in_shootout:
		in_shootout = so
		_release_all()
	_hide_hints()
	canvas.update()


# The keyboard hint line at the bottom is no use on a phone.
func _hide_hints():
	if hints_hidden:
		return
	var lm = match_node.get("lbl_msg")
	if lm == null:
		return
	for c in lm.get_parent().get_children():
		if c is Label and c.rect_position.y >= 250.0:
			c.hide()
	hints_hidden = true


func _notification(what):
	# a finger lifted while the pause menu was open never reports its release
	if what == NOTIFICATION_PAUSED:
		_release_all()


func _release_all():
	touches.clear()
	move = Vector2.ZERO
	stick_vec = Vector2.ZERO
	shoot = false
	pass_held = false
	tackle = false
	switch_flag = false


# -------------------------------------------------------------------- input

func _input(event):
	if event is InputEventScreenTouch:
		if not active:
			active = true
			canvas.visible = true
		if event.pressed:
			_touch_down(event.index, event.position)
		else:
			_touch_up(event.index)
	elif event is InputEventScreenDrag and active:
		if touches.get(event.index) == "stick":
			_update_stick(event.position)


func _role_at(pos):
	var b = _buttons()
	for name in b:
		if pos.distance_to(b[name][0]) <= b[name][1] + 10.0 * _s():
			return name
	if not in_shootout and pos.distance_to(_stick_center()) <= _stick_radius() * GRAB_SCALE:
		return "stick"
	return ""


func _touch_down(idx, pos):
	var role = _role_at(pos)
	if role == "":
		return
	if role == "stick" and touches.values().has("stick"):
		return   # one finger on the stick at a time
	touches[idx] = role
	if role == "stick":
		_update_stick(pos)
	elif role == "shoot":
		shoot = true
	elif role == "pass":
		pass_held = true
	elif role == "tackle":
		tackle = true
	elif role == "switch":
		switch_flag = true
	elif role == "pause":
		_press_pause()
	elif role.begins_with("zone"):
		zone_value = int(role.substr(4))
		zone_ms = OS.get_ticks_msec()


func _touch_up(idx):
	if not touches.has(idx):
		return
	var role = touches[idx]
	touches.erase(idx)
	if role == "stick":
		move = Vector2.ZERO
		stick_vec = Vector2.ZERO
	elif role == "shoot":
		shoot = false
	elif role == "pass":
		pass_held = false
	elif role == "tackle":
		tackle = false


func _update_stick(pos):
	var v = (pos - _stick_center()) / _stick_radius()
	if v.length() > 1.0:
		v = v.normalized()
	stick_vec = v
	var l = v.length()
	if l < DEAD_ZONE:
		move = Vector2.ZERO
	else:
		move = v.normalized() * clamp((l - DEAD_ZONE) / (FULL_TILT - DEAD_ZONE), 0.0, 1.0)


# The pause menu listens for the P key, so the button just presses it.
func _press_pause():
	var down = InputEventKey.new()
	down.scancode = KEY_P
	down.pressed = true
	Input.parse_input_event(down)
	var up = InputEventKey.new()
	up.scancode = KEY_P
	up.pressed = false
	Input.parse_input_event(up)


# ------------------------------------------------------------------ drawing

func _on_draw():
	if not active:
		return
	var f = font
	if f == null:
		f = canvas.get_font("font")
	if not in_shootout:
		var c = _stick_center()
		var r = _stick_radius()
		canvas.draw_circle(c, r, Color(0, 0, 0, 0.25))
		canvas.draw_arc(c, r, 0.0, TAU, 40, Color(1, 1, 1, 0.45), 2.0)
		var knob = c + stick_vec * r
		canvas.draw_circle(knob, r * 0.42, Color(0.20, 0.75, 0.35, 0.75))
		canvas.draw_arc(knob, r * 0.42, 0.0, TAU, 24, Color(1, 1, 1, 0.85), 2.0)
	var b = _buttons()
	var held = touches.values()
	for name in b:
		var d = b[name]
		var down = held.has(name)
		canvas.draw_circle(d[0], d[1], Color(0.13, 0.60, 0.25, 0.80 if down else 0.45))
		canvas.draw_arc(d[0], d[1], 0.0, TAU, 32, Color(1, 1, 1, 0.85 if down else 0.50), 2.0)
		var w = f.get_string_size(d[2]).x
		canvas.draw_string(f, d[0] + Vector2(-w / 2.0, f.get_ascent() / 2.0 - 1.0), d[2], Color.white)
