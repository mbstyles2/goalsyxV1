extends Node2D

# --- GOALSYX Multi-Camera System (Godot 3.x) ---

enum CameraType {
	STANDARD,
	ISOMETRIC,
	PORTRAIT,
	DYNAMIC
}

export(CameraType) var current_mode = CameraType.DYNAMIC

var camera: Camera2D = null
var match_node = null

# --- Configurable Tuning Parameters ---
var pos_smooth_speed: float = 6.0
var zoom_smooth_speed: float = 4.0

# Screen Shake State
var camera_shake_t: float = 0.0
var camera_shake_intensity: float = 0.0

const PITCH = Rect2(50, 50, 1800, 950)


func setup(p_match_node, p_camera: Camera2D):
	match_node = p_match_node
	camera = p_camera
	if camera:
		camera.current = true


func set_mode(new_mode):
	current_mode = new_mode
	_reset_mode_transformations()


func get_mode_name(m = current_mode) -> String:
	match m:
		CameraType.STANDARD: return "Standard"
		CameraType.ISOMETRIC: return "Isometric"
		CameraType.PORTRAIT: return "Portrait"
		CameraType.DYNAMIC: return "Broadcast Dynamic"
		_: return "Standard"


func cycle_mode() -> String:
	current_mode = (current_mode + 1) % CameraType.size()
	_reset_mode_transformations()
	return get_mode_name()


func trigger_shake(intensity: float, duration: float):
	camera_shake_intensity = intensity
	camera_shake_t = duration


func _reset_mode_transformations():
	if camera:
		camera.rotation = 0.0
		camera.zoom = Vector2(1.0, 1.0)


func update_camera(delta: float):
	if camera == null or match_node == null or not is_instance_valid(match_node.ball):
		return

	match current_mode:
		CameraType.STANDARD:
			_update_standard_camera(delta)
		CameraType.ISOMETRIC:
			_update_isometric_camera(delta)
		CameraType.PORTRAIT:
			_update_portrait_camera(delta)
		CameraType.DYNAMIC:
			_update_dynamic_camera(delta)


# --- Mode A: STANDARD ---
func _update_standard_camera(delta: float):
	var ball = match_node.ball
	_apply_transform(ball.position, Vector2(1.0, 1.0), 0.0, delta)


# --- Mode B: ISOMETRIC ---
# Creates a tilted, diamond-shaped 2.5D arcade perspective via targeted skew & rotation
func _update_isometric_camera(delta: float):
	var ball = match_node.ball
	var pitch_center = PITCH.position + PITCH.size / 2.0
	
	# Slightly pull camera back towards center for balanced isometric framing
	var target_pos = ball.position.linear_interpolate(pitch_center, 0.15)
	
	# Asymmetric zoom + clean 35-degree tilt creates the classic 2.5D diamond aesthetic
	var target_zoom = Vector2(1.2, 0.75) 
	var target_rot = deg2rad(-32.0)

	_apply_transform(target_pos, target_zoom, target_rot, delta)


# --- Mode C: PORTRAIT ---
# Reorients the landscape pitch to run vertically from top to bottom
func _update_portrait_camera(delta: float):
	var ball = match_node.ball
	var pitch_center = PITCH.position + PITCH.size / 2.0
	
	# Center tracking along the vertical axis
	var target_pos = Vector2(pitch_center.x, ball.position.y)
	
	# 90-degree rotation flips the horizontal field into a vertical top-to-bottom layout
	var target_zoom = Vector2(0.85, 1.35)
	var target_rot = deg2rad(90.0)

	_apply_transform(target_pos, target_zoom, target_rot, delta)


# --- Mode D: DYNAMIC ---
func _update_dynamic_camera(delta: float):
	var ball = match_node.ball
	var ball_vel = ball.vel
	var ball_spd = ball_vel.length()
	var pitch_center = PITCH.position + PITCH.size / 2.0

	var look_ahead = ball_vel * 0.28
	if look_ahead.length() > 260.0:
		look_ahead = look_ahead.normalized() * 260.0

	var target_pos = ball.position + look_ahead
	
	var dist_from_center = abs(ball.position.x - pitch_center.x)
	var zoom_val = 0.95
	if ball_spd > 380.0 or dist_from_center > 400.0:
		zoom_val = 1.25
	elif ball.height_z > 35.0:
		zoom_val = 1.12

	_apply_transform(target_pos, Vector2(zoom_val, zoom_val), 0.0, delta)


# --- Common Camera Application & Boundary Constraints ---
func _apply_transform(target_pos: Vector2, target_zoom: Vector2, target_rot: float, delta: float):
	if camera_shake_t > 0.0:
		camera_shake_t -= delta
		var shake = Vector2(rand_range(-1.0, 1.0), rand_range(-1.0, 1.0)) * camera_shake_intensity
		target_pos += shake
		if camera_shake_t <= 0.0:
			camera_shake_intensity = 0.0

	# Pitch boundary clamping
	var view_size = get_viewport_rect().size * camera.zoom * 0.5
	var min_x = PITCH.position.x + view_size.x
	var max_x = PITCH.end.x - view_size.x
	var min_y = PITCH.position.y + view_size.y
	var max_y = PITCH.end.y - view_size.y

	if max_x > min_x:
		target_pos.x = clamp(target_pos.x, min_x, max_x)
	else:
		target_pos.x = PITCH.position.x + PITCH.size.x / 2.0

	if max_y > min_y:
		target_pos.y = clamp(target_pos.y, min_y, max_y)
	else:
		target_pos.y = PITCH.position.y + PITCH.size.y / 2.0

	# Smooth interpolation
	camera.position = camera.position.linear_interpolate(target_pos, delta * pos_smooth_speed)
	camera.zoom = camera.zoom.linear_interpolate(target_zoom, delta * zoom_smooth_speed)
	camera.rotation = lerp(camera.rotation, target_rot, delta * 5.0)
