extends Node2D

const Extras = preload("res://scripts/extras/extras.gd")
const GameAudio = preload("res://scripts/audio/game_audio.gd")
const PauseMenu = preload("res://scripts/match/pause_menu.gd")
const Scoreboard = preload("res://scripts/match/scoreboard.gd")
const TouchControls = preload("res://scripts/match/touch_controls.gd")
const Jerseys = preload("res://scripts/ui/jerseys.gd")
const TacticSystem = preload("res://scripts/match/tactic.gd")
const PlayerDecisionAI = preload("res://scripts/match/PlayerDecisionAI.gd")   # decides WHAT each AI player is doing
const AttackAI = preload("res://scripts/match/AttackAI.gd")                   # runs, support (team has the ball)
const DefendAI = preload("res://scripts/match/DefendAI.gd")                   # press, cover, lane block, recovery (team has not)
const MatchUIController = preload("res://scripts/match/match_ui_controller.gd")
const CameraController = preload("res://scripts/match/camera_controller.gd")   # the old flat camera (unused while USE_FAKE_3D)
const PlayerStatusBar = preload("res://scripts/match/player_status_bar.gd")   # jersey-number tag above the player you control
const MatchRadar = preload("res://scripts/match/radar.gd")                    # minimap along the bottom (M hides it)
const KickSystem = preload("res://scripts/match/kick_system.gd")           # passing + shooting (input / brain / physics)
const MatchCamera = preload("res://scripts/match/camera.gd")                    # fake-3D camera + perspective pitch
const MatchReplay = preload("res://scripts/match/replay.gd")                    # goal replay + cut-scene
const USE_FAKE_3D = true      # false = the old flat top-down view and camera_controller.gd come back
const PenaltyShootout = preload("res://scripts/match/penalty_shootout.gd")
const GoalkeeperAI = preload("res://scripts/match/goalkeeper_ai.gd")
const MatchRules = preload("res://scripts/match/match_rules.gd")           # restarts, fouls, offside, ball out of play
const StadiumRenderer = preload("res://scripts/match/stadium.gd")
const ShapeAI = preload("res://scripts/match/ShapeAI.gd")                     # team width, zones, spacing, flat lines
const TrapAI = preload("res://scripts/match/TrapAI.gd")                       # the offside trap and the pressing triggers
const ScrambleAI = preload("res://scripts/match/ScrambleAI.gd")               # shots, saves, rebounds and scrambles in the box

# --- Pitch Dimensions ---
# ---- 2.5D feel
const CROSSBAR_Z = 60.0     # a ball higher than this when it crosses the goal line goes over the bar
const SORT_BASE = 10        # players are drawn back-to-front by their y position (z_index SORT_BASE..SORT_BASE+SORT_RANGE)
const SORT_RANGE = 30
const PERSP_FAR = 0.94      # size of a player at the top of the pitch ...
const PERSP_NEAR = 1.06     # ... and at the bottom (nearer the camera)
const PITCH = Rect2(50, 50, 3000, 1250)
const GOAL_H = 200.0
const GOAL_DEPTH = 40.0
const PR = 13.0          
const BR = 7.0           
const HUMAN_SPEED = 215.0      
const AI_SPEED = 185.0
const USE_SPEC_AI = true     # false = the old in-file decision order (_ai_plan_legacy)
const GK_SPEED = 170.0
const MAX_BALL_SPEED = 720.0
const AIR_DRAG = 0.45         # a ball in the air loses speed more slowly than a rolling one (1.0 = the same)
const AIR_BLEND_H = 6.0         # ball height (px) at which it counts as fully airborne for drag; below it the drag blends from rolling to air (kick_physics.gd uses the same blend)
const CORNER_ZONE = 40.0

# ---- Duels & Keepers ----
const TACKLE_SUCCESS = 0.65         
const TRAP_SPEED = 250.0            
const RECEIVER_TRAP_SPEED = 340.0   
const GK_HOLD_TIME = 0.9            
const GK_HUMAN_HOLD = 6.0           # a human keeper who has caught it has six seconds (the law) to find a team-mate
const GK_CATCH_SPEED = 330.0        
const GK_DIVE_SPEED = 240.0
const GK_SCALE = 1.4               
const GK_RADIUS = PR * GK_SCALE     
const GK_BOX_DEPTH = 300.0          # the 18-yard box: his domain (it was 130 x 130, a small patch in front of the goal)
const GK_BOX_HALF = 250.0

# ---- Match rules (restarts, fouls, offside, ball out of play: all of it lives in match_rules.gd) ----
const SET_PIECES = true        # false = the old game: the ball bounces off the walls and there is no referee
const AI_TACKLE_RATE = 2.0

# --- Tactical System Configuration ---
var current_formation = "4-4-2"
var current_tactic = TacticSystem.TacticType.BALANCED

var profiles = [null, null]
var shape_proxy = []            
var team_ctx = [{}, {}]         
var pressers_of = [[], []]      
var marks_of = [{}, {}]         
var trans_t = [0.0, 0.0]        
var team_state = [1, 1]          # TacticSystem.TeamState per team (1 = DEFENDING)
var state_poss = [false, false]  # smoothed "has the ball" that drives the team state
var state_hold_t = [0.0, 0.0]
var gain_t = [99.0, 99.0]        # seconds since the team won the ball
var loss_t = [99.0, 99.0]        # seconds since the team lost the ball
var ai_clock = 0.0               # AI time (only runs while play is live)
var ai_intent = {}               # player id -> {i: Intent, t: since, seen: last frame, team}
var lane_blocker = [-1, -1]      # player id of the passing-lane blocker per team
var lane_target = [null, null]   # the opponent that lane is aimed at
var last_poss_team = -1
var kickoff_team = 0
var first_kickoff_team = 0
var pass_target = null          
var pass_t = 0.0
var carry_dir_mem = {}
var ball_off_mem = {}          
var gk_cd = [0.0, 0.0]          
var gk_react = [0.0, 0.0]
var gk_read_y = [0.0, 0.0]
var gk_shot_seen = [false, false]
var gk_system = null
# Sprint and Knock-on
var sprint_prev = [false, false]
var sprint_taps = [0, 0]
var sprint_last = [-10.0, -10.0]
var run_until = [0.0, 0.0]
var push_level = [0, 0]             
var dribble_len = [12.0, 12.0]      
var gk_dive_t = [0.0, 0.0]          
var gk_down_t = [0.0, 0.0]          
var gk_dive_dir = [Vector2.UP, Vector2.UP]
var gk_dive_speed = [0.0, 0.0]
var gk_dived = [false, false]       
var gk_wait = [0.0, 0.0]            
const SHIELD_DIST = 95.0            # an opponent this close makes a carrier shield the ball
var shield_p = null                 # the player who is shielding the ball right now
var shield_away = Vector2.ZERO      # from the opponent he is shielding it from, towards him: the ball goes on this side
var shield_t = {}                   # player id -> how long he has been shielding
var shield_rest = {}                # player id -> seconds before the computer lets him shield again
var shield_hint = {}                # player id -> the computer's carrier sees no good option (set in _ai_decide)
var human_shield = [false, false]   # the shield button is held
var gk_claim_t = [0.0, 0.0]         # the keeper has come for the ball: in his box nobody else goes for it
var gk_human = [false, false]       # the keeper is held in the human's hands: after a save, or taking a goal kick

# Offside line, shown for a moment after a call (match_rules.gd sets these, _draw draws them)
var offside_line_x = 0.0
var offside_timer = 0.0

# Controller / Particle References
var ui_controller = null
var turf_particles: CPUParticles2D = null

# Camera 2.5D Shake & Lead Parameters
var camera_shake_t = 0.0
var camera_shake_intensity = 0.0
var camera_controller = null
var status_bar = null
var radar = null
var kick_system = null
var replay = null              # replay.gd: records the last seconds of play, shows the goal replay

# Crowd
var crowd_pos = PoolVector2Array()
var crowd_col = []
var crowd_t = 0.0   

var active_pitch_data = {}
var ball
var players = []
var chasers = [null, null]
var attacking = [false, false]
var possession = [false, false]
var ball_stuck_t = 0.0
var ball_ghost_t = 0.0
var gk_hold_timer = [0.0, 0.0] 

var sel = [null, null]
var score = [0, 0]
var time_left = 120.0
var overtime = false
var state = "playing"
var state_timer = 0.0
var msg_timer = 0.0
var lbl_score
var lbl_time
var lbl_msg
var msg_bg 
var scoreboard
var touch_controls
var camera: Camera2D      
var last_touch = null
var dribble_owner = null 
var ai_decision_timers = {} 
var rules = null               # match_rules.gd: the referee (restarts, fouls, offside, ball out of play)
var set_goal_end = false
var scramble = null            # scramble_ai.gd: a saved / blocked / spilled shot and the scramble that follows
var shape_mem = {}             # ShapeAI: smoothing memory per player and the line averages per tick
var contest_cd = 0.0           # a 50/50 for the ball can only be decided this often
var throw_taker = null         # the player who has just taken a throw-in (may still be outside the line for a moment)
var throw_free_t = 0.0
const THROW_LEASH = 6.0        # a thrower may shuffle this far from his spot (a few centimetres), no more
# THE CLOCK: a match is 90 game minutes, two halves of 45, with a short break between them.
# match_time_speed = game seconds per real second: 9 -> a half takes 5 real minutes, the match 10.
const HALF_MINUTES = 45.0
const ET_MINUTES = 15.0        # extra time (knockouts): one golden-goal period
const HALFTIME_BREAK = 3.5     # real seconds between the halves
var match_time_speed= 9.0
var current_half = 1
var halftime_timer = 0.0
var stadium_renderer = null


var prev_switch_p1 = false
var prev_switch_p2 = false

var shootout = null            # the penalty shootout scene (penalty_shootout.gd)
var trap_until = {
	0: 0.0,
	1: 0.0
}

var trap_step = {
	0: 0.0,
	1: 0.0
}

var trap_cd = {0: 0.0, 1: 0.0}               # TrapAI: no new offside trap before this ai_clock time
var press_trig_until = {0: 0.0, 1: 0.0}      # TrapAI: a pressing trigger (back-pass, bad touch, touchline trap) is on until then
var press_trig_kind = {0: "", 1: ""}


func _ready():
	randomize()
	Extras.get_it().pens = null
	GameAudio.get_it(self).enter_match()
	add_child(PauseMenu.new(self))
	touch_controls = TouchControls.new(self)
	add_child(touch_controls)
	
	camera = Camera2D.new()
	add_child(camera)
	camera_controller = (MatchCamera if USE_FAKE_3D else CameraController).new()
	add_child(camera_controller)
	camera_controller.setup(self, camera)
	
	stadium_renderer = StadiumRenderer.new()
	stadium_renderer.setup(self, camera_controller)
	
	var pitch_enum = Game.get_active_pitch_id()
	active_pitch_data = Game.PITCHES[pitch_enum]
	
	
	time_left = HALF_MINUTES * 60.0         # seconds left in this half (counts down; the HUD shows minutes played)

	
	for t in range(2):
		var t_id = Game.home_id if t == 0 else Game.away_id
		profiles[t] = TacticSystem.get_team_profile(Game.team_name(t_id))
	current_formation = profiles[0]["formation"]
	current_tactic = profiles[0]["tactic"]
	
	var Player = load("res://scripts/match/player.gd")
	for team in range(2):
		var tid = Game.home_id if team == 0 else Game.away_id
		for slot in range(11):  
			var p = Player.new()
			p.team = team
			p.slot = slot
			p.is_gk = (slot == 0)
			if p.is_gk:
				p.scale = Vector2(GK_SCALE, GK_SCALE)
			p.color = Game.team_color(tid)
			p.jersey = Jerseys.get_it().texture_for(tid)
			if team == 1:
				p.ring = Color(0.2, 0.9, 1.0)
			add_child(p)
			players.append(p)
			
	for sp_p in players:
		shape_proxy.append({"role": TacticSystem.role_for(profiles[sp_p.team]["formation"], sp_p.slot), "home_pos": Vector2.ZERO})
		
	ball = load("res://scripts/match/ball.gd").new()
	add_child(ball)
	
	_setup_turf_particles()
	_build_crowd()
	_build_hud()
	
	ui_controller = MatchUIController.new(self)
	ui_controller.setup_ui()

	status_bar = PlayerStatusBar.new(self)
	add_child(status_bar)
	radar = MatchRadar.new(self)
	add_child(radar)
	kick_system = KickSystem.new(self)
	replay = MatchReplay.new(self)
	replay.setup()
	rules = MatchRules.new(self)
	rules.enabled = SET_PIECES
	scramble = ScrambleAI.new(self)
	first_kickoff_team = kickoff_team
	_kickoff()

	if Extras.get_it().shootout_only:
		_start_shootout()



func _setup_turf_particles():
	turf_particles = CPUParticles2D.new()
	turf_particles.emitting = false
	turf_particles.one_shot = true
	turf_particles.amount = 14
	turf_particles.lifetime = 0.4
	turf_particles.explosiveness = 0.85
	turf_particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE # Fixed from EMISSION_SHAPE_CIRCLE
	turf_particles.emission_sphere_radius = 6.0
	turf_particles.direction = Vector2.UP
	turf_particles.spread = 60.0
	turf_particles.gravity = Vector2(0, 220)
	turf_particles.initial_velocity = 80.0
	turf_particles.scale_amount = 2.2
	turf_particles.color = Color(0.25, 0.65, 0.22)
	turf_particles.z_index = 10
	add_child(turf_particles)


func emit_turf_impact(pos: Vector2, dir: Vector2):
	if turf_particles:
		turf_particles.position = camera_controller.proj(pos) if (USE_FAKE_3D and camera_controller != null) else pos
		turf_particles.direction = -dir.normalized()
		turf_particles.restart()
		turf_particles.emitting = true


func trigger_camera_shake(intensity: float, duration: float):
	if camera_controller:
		camera_controller.trigger_shake(intensity, duration)

# ---------------------------------------------------------------- DRAWING

func _draw():
	if USE_FAKE_3D and stadium_renderer != null:
		stadium_renderer.draw_world(self)
		return

	# Keep your existing non-fake-3D drawing code here.
	# Pitch Surround/Background
	draw_rect(Rect2(-320, -320, PITCH.size.x + 740, PITCH.size.y + 740), Color(0.10, 0.10, 0.12))
	draw_rect(Rect2(0, 0, PITCH.size.x + 100, PITCH.size.y + 100), active_pitch_data["bg"])
	
	# Mowing Stripes
	var n = 12
	var sw = PITCH.size.x / n
	for i in range(n):
		var c = active_pitch_data["stripe_a"] if i % 2 == 0 else active_pitch_data["stripe_b"]
		draw_rect(Rect2(PITCH.position.x + i * sw, PITCH.position.y, sw, PITCH.size.y), c)
		
	var line = active_pitch_data["lines"]
	var cx = PITCH.position.x + PITCH.size.x / 2
	var cy = PITCH.position.y + PITCH.size.y / 2
	_outline(PITCH, line, 3.0)
	draw_line(Vector2(cx, PITCH.position.y), Vector2(cx, PITCH.end.y), line, 3.0)
	draw_arc(Vector2(cx, cy), 75.0, 0, TAU, 48, line, 3.0)
	draw_circle(Vector2(cx, cy), 4.0, line)
	
	# 18-yard and 6-yard boxes
	var box_w =1000.0
	var box_h = 1500.0
	var small_box_w = 800.0
	var small_box_h = 750.0
	
	var l_box_rect = Rect2(PITCH.position.x, cy - box_h / 2.0, box_w, box_h)
	_outline(l_box_rect, line, 2.0)
	var l_small_box = Rect2(PITCH.position.x, cy - small_box_h / 2.0, small_box_w, small_box_h)
	_outline(l_small_box, line, 2.0)
	draw_circle(Vector2(PITCH.position.x + 140.0, cy), 3.5, line)
	draw_arc(Vector2(PITCH.position.x + 140.0, cy), 75.0, -PI/2, PI/2, 32, line, 2.0)

	var r_box_rect = Rect2(PITCH.end.x - box_w, cy - box_h / 2.0, box_w, box_h)
	_outline(r_box_rect, line, 2.0)
	var r_small_box = Rect2(PITCH.end.x - small_box_w, cy - small_box_h / 2.0, small_box_w, small_box_h)
	_outline(r_small_box, line, 2.0)
	draw_circle(Vector2(PITCH.end.x - 140.0, cy), 3.5, line)
	draw_arc(Vector2(PITCH.end.x - 140.0, cy), 75.0, PI/2, 3 * PI/2, 32, line, 2.0)

	# Goal mouth rendering
	var post = Color(0.95, 0.95, 0.95)
	var net = Color(1, 1, 1, 0.22)
	var gl = Rect2(PITCH.position.x - GOAL_DEPTH, cy - GOAL_H / 2, GOAL_DEPTH, GOAL_H)
	var gr = Rect2(PITCH.end.x, cy - GOAL_H / 2, GOAL_DEPTH, GOAL_H)
	draw_rect(gl, net)
	draw_rect(gr, net)
	_outline(gl, post, 3.0)
	_outline(gr, post, 3.0)
	
	if offside_timer > 0.0:
		var line_col = Color(1.0, 0.3, 0.3, 0.8)
		draw_line(Vector2(offside_line_x, PITCH.position.y), Vector2(offside_line_x, PITCH.end.y), line_col, 2.0)

	_draw_crowd()


func _outline(r, col, w):
	var pts = PoolVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), r.position])
	draw_polyline(pts, col, w)


# ---------------------------------------------------------------- HUD

func _build_hud():
	var layer = CanvasLayer.new()
	add_child(layer)
	var root = Control.new()
	root.rect_scale = Vector2(2, 2)
	layer.add_child(root)
	
	scoreboard = Scoreboard.new(self)
	add_child(scoreboard)

	lbl_score = _label(root, 7)
	lbl_time = _label(root, 19)
	msg_bg = ColorRect.new()
	msg_bg.rect_position = Vector2(120, 126)
	msg_bg.rect_size = Vector2(240, 22)
	msg_bg.color = Color(0.02, 0.02, 0.02, 0.72)
	msg_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(msg_bg)
	msg_bg.hide()
	lbl_msg = _label(root, 130)

	var hint = _label(root, 252)
	if Game.two_player:
		hint.text = ""
		var h1 = _label(root, 252)
		h1.rect_min_size = Vector2(236, 0)
		h1.rect_position.x = 4
		h1.align = Label.ALIGN_LEFT
		h1.text = "P1: WASD | F/Space Shoot | G Pass | H Through | E Switch"
		var h2 = _label(root, 252)
		h2.rect_min_size = Vector2(236, 0)
		h2.rect_position.x = 240
		h2.align = Label.ALIGN_RIGHT
		h2.text = "P2: Arrows | Enter Shoot | Ctrl Pass | Shift Through"
	else:
		hint.text = "Move: WASD/Arrows | Shoot: Space | Pass: J | Through Ball: L | Tackle: K | Sprint: Shift"


func _label(parent, y):
	var l = Label.new()
	l.align = Label.ALIGN_CENTER
	l.rect_min_size = Vector2(480, 0)
	l.rect_position = Vector2(0, y)
	
	var custom_font = DynamicFont.new()
	custom_font.font_data = load("res://assets/fonts/batmfa.ttf") 
	custom_font.size = 9
	l.add_font_override("font", custom_font)
	
	parent.add_child(l)
	return l


func _update_hud():
	var h_name = Game.team_name(Game.home_id).substr(0, 3).to_upper()
	var a_name = Game.team_name(Game.away_id).substr(0, 3).to_upper()
	lbl_score.text = "%s   %d  -  %d   %s" % [h_name, score[0], score[1], a_name]
	
	var t = int(floor(_clock_seconds()))
	var clock = "%d:%02d" % [int(t / 60), t % 60]
	if state == "halftime":
		lbl_time.text = "HT  " + clock
	elif overtime:
		lbl_time.text = "ET  " + clock
	elif current_half == 1:
		lbl_time.text = "1H  " + clock
	else:
		lbl_time.text = "2H  " + clock


# game seconds played: 0 -> 2700 in the first half, 2700 -> 5400 in the second, then extra time
func _clock_seconds():
	var length = HALF_MINUTES * 60.0
	var base = 0.0
	if overtime:
		base = length * 2.0
		length = ET_MINUTES * 60.0
	elif current_half == 2:
		base = length
	return base + clamp(length - time_left, 0.0, length)


func _show_msg(text, duration):
	lbl_msg.text = text
	msg_timer = duration
	if msg_bg:
		if text != "":
			msg_bg.show()
		else:
			msg_bg.hide()


# ------------------------------------------------------------ MATCH FLOW

func _goal(scorer):
	if rules != null and not rules.validate_goal(scorer):
		return                                   # the referee ruled it out (a restart has been started instead)
	score[scorer] += 1
	crowd_t = 2.5
	for cp in players:
		if cp.team == scorer and not cp.is_gk and cp.has_method("celebrate"):
			cp.celebrate(-1, cp == last_touch)
	kickoff_team = 1 - scorer
	GameAudio.get_it(self).goal_scored()
	trigger_camera_shake(12.0, 0.6)
	
	if Extras.get_it().set_active and score[scorer] >= Extras.get_it().set_goals_to_win:
		set_goal_end = true
	state = "goal"
	state_timer = 2.0
	ball.vel = Vector2.ZERO
	ball.vel_z = 0.0
	if replay != null:
		replay.on_goal(scorer)
	var tid = Game.home_id if scorer == 0 else Game.away_id
	var prefix = rules.goal_prefix() if rules != null else "GOAL!"
	_show_msg(prefix + "  " + Game.team_name(tid).to_upper() + "  %d'" % (int(_clock_seconds() / 60.0) + 1), 0)
	_update_hud()


# what happens when the goal banner (and the replay after it) is over
func _after_goal():
	if overtime or set_goal_end:
		_finish()
	else:
		_kickoff()


func _needs_overtime():
	if Extras.get_it().lts_active:
		return score[0] == score[1]
	if Extras.get_it().set_active:
		return false   
	return Game.mode == Game.Mode.TOURNAMENT \
		and Tournament.format == Tournament.Format.KNOCKOUT \
		and score[0] == score[1]


func _update_clock(delta):
	time_left -= delta * match_time_speed

	if time_left > 0:
		return

	time_left = 0

	# End of the first half (45:00): a short break, then the other team kicks off
	if current_half == 1 and not overtime:
		halftime_timer = HALFTIME_BREAK
		state = "halftime"
		_show_msg("HALF TIME   %d - %d" % [score[0], score[1]], HALFTIME_BREAK)
		_update_hud()
		return

	# End of the second half (90:00)
	if not overtime and _needs_overtime():
		overtime = true
		time_left = ET_MINUTES * 60.0
		_show_msg("EXTRA TIME - GOLDEN GOAL", 2.5)
	else:
		_finish()

func _finish():
	if overtime and _needs_overtime():
		_start_shootout()
		return
	state = "over"
	Game.last_home_goals = score[0]
	Game.last_away_goals = score[1]
	_update_hud()
	_show_msg("FULL TIME", 0)

	if ui_controller:
		ui_controller.set_stats_visible(true)

	yield(get_tree().create_timer(3.5), "timeout")
	Game.goto("res://scenes/Results.tscn")


func _input(event):
	# any key (not Esc: that leaves the match), click or tap skips the goal replay
	if state != "replay" or replay == null:
		return
	if (event is InputEventKey and event.pressed and not event.echo and event.scancode != KEY_ESCAPE) \
			or (event is InputEventMouseButton and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed):
		replay.skip()


func _physics_process(delta):
	if USE_FAKE_3D and camera_controller != null:
		camera_controller.restore_positions()      # give the game its real (flat) positions back
	_game_tick(delta)
	if replay != null:
		replay.tick(delta)                         # records play / runs the goal replay (real positions, before the projection)
	if USE_FAKE_3D and camera_controller != null:
		camera_controller.apply_projection(delta)  # ...then show everything in perspective and move the camera
	
func _game_tick(delta):
	if ui_controller and ui_controller.intro_active:
		ui_controller.update_intro(delta)
		return

	if state != "over" and Input.is_key_pressed(KEY_ESCAPE):
		state = "over"
		Game.goto("res://scenes/MainMenu.tscn")
		return
	if msg_timer > 0:
		msg_timer -= delta
		if msg_timer <= 0 and state == "playing":
			lbl_msg.text = ""
			if msg_bg:
				msg_bg.hide()
	if crowd_t > 0.0:
		crowd_t = max(0.0, crowd_t - delta)
		update()
	if offside_timer > 0.0:
		offside_timer -= delta
		update()
	if state == "over":
		return
	if state == "shootout":
		return   # the penalty scene runs itself
	if state == "halftime":
		halftime_timer -= delta
		if halftime_timer <= 0.0:
			current_half = 2
			time_left = HALF_MINUTES * 60.0
			kickoff_team = 1 - first_kickoff_team           # the team that did not start the match starts the second half
			_kickoff()
			_show_msg("SECOND HALF", 1.5)
			return
	
	if state == "goal":
		state_timer -= delta
		if state_timer <= 0:
			if replay != null and replay.start():
				return                                 # the replay runs from replay.tick(); it calls _after_goal() when done
			_after_goal()
		return
	if state == "replay":
		return                                         # nothing is simulated while the replay plays
	if rules == null or rules.clock_running():
		_update_clock(delta)                     # the clock stops while the ball is dead
	if state != "playing":
		return
		
	pass_t = max(0.0, pass_t - delta)
	throw_free_t = max(0.0, throw_free_t - delta)
	contest_cd = max(0.0, contest_cd - delta)
	for tt in range(2):
		trans_t[tt] = max(0.0, trans_t[tt] - delta)
	if rules != null:
		rules.tick(delta)                        # phases of a restart, the ball held on its spot, players held to the rules
	var dead = _dead_ball()
	_update_chasers()
	_update_team_plans()
	_update_team_states(delta)                  # ATTACKING / DEFENDING / TRANSITIONS + lane blockers
	if scramble != null:
		scramble.update(delta)                    # a saved / blocked / spilled shot: who crashes the box, who clears it
	_update_shield(delta)
	if not dead:
		_update_selection()                      # while the ball is dead the rules keep the human on his taker
	_depth_sort()
	kick_system.tick(delta)
	
	if ui_controller and not dead:
		ui_controller.process_stats(delta, possession)

	for p in players:
		if state != "playing":
			break   
		p.kick_cd = max(0.0, p.kick_cd - delta)
		p.tackle_cd = max(0.0, p.tackle_cd - delta)
		if p.is_tackling:
			p.tackle_timer -= delta
			if p.tackle_timer <= 0.0:
				p.is_tackling = false
				p.update()
		
		if rules != null and rules.takes_over(p):
			rules.control_player(p, delta)         # walking to a place / waiting, while the ball is dead
		elif p == sel[0]:
			_human_control(p, delta, 0)
		elif Game.two_player and p == sel[1]:
			_human_control(p, delta, 1)
		else:
			_ai_control(p, delta)
			
	if state != "playing":
		return
	_separate_players()
	for p in players:
		_clamp_player(p)
	if not _dead_ball():                       # a dead ball is held by the rules: no physics, no contacts
		_ball_player_contacts()
		_update_ball(delta)
	_update_camera(delta)
	_update_hud()


# ------------------------------------------------------------ 2.5D CAMERA SYSTEM

func _update_camera(delta):
	if camera_controller:
		camera_controller.update_camera(delta)
	# Smooth lead tracking: camera looks ahead of ball movement



# ------------------------------------------------------------ AI & SELECTION

func _set_selected(team, p):
	if sel[team] != null:
		sel[team].set_selected(false)
	sel[team] = p
	p.set_selected(true)


func _update_selection():
	_update_selection_for(0)
	if Game.two_player:
		_update_selection_for(1)


func _cycle_next_player(team):
	if gk_human[team]:
		return
	if _dead_ball():
		return                                   # the rules hold the selection during a restart
	var cur = sel[team]
	var best_candidate = null
	var min_dist = 1e9
	for p in players:
		if p.team != team or p.is_gk or p == cur:
			continue
		var d = p.position.distance_to(ball.position)
		if d < min_dist:
			min_dist = d
			best_candidate = p
	if best_candidate != null:
		_set_selected(team, best_candidate)


# a direction read on the screen (keys, touch stick) -> the same direction on the pitch. Only differs when the camera
# turns the view (the vertical end-to-end mode).
func _view_dir(v):
	if USE_FAKE_3D and camera_controller != null and camera_controller.has_method("view_to_world_dir"):
		return camera_controller.view_to_world_dir(v)
	return v


func _human_control(p, delta, team):
	var two = Game.two_player
	var use_wasd = (not two) or team == 0
	var use_arrows = (not two) or team == 1
	var switch_pressed = false
	if not two:
		switch_pressed = Input.is_key_pressed(KEY_TAB)
		if switch_pressed and not prev_switch_p1:
			_cycle_next_player(0)
		prev_switch_p1 = switch_pressed
	elif team == 0:
		switch_pressed = Input.is_key_pressed(KEY_E)
		if switch_pressed and not prev_switch_p1:
			_cycle_next_player(0)
		prev_switch_p1 = switch_pressed
	else:
		switch_pressed = Input.is_key_pressed(KEY_SHIFT)
		if switch_pressed and not prev_switch_p2:
			_cycle_next_player(1)
		prev_switch_p2 = switch_pressed

	var tc = touch_controls
	var touch_on = tc != null and tc.is_active_for(team)
	if touch_on and tc.consume_switch():
		_cycle_next_player(team)

	var dir = Vector2.ZERO
	if (use_arrows and Input.is_key_pressed(KEY_LEFT)) or (use_wasd and Input.is_key_pressed(KEY_A)):
		dir.x -= 1
	if (use_arrows and Input.is_key_pressed(KEY_RIGHT)) or (use_wasd and Input.is_key_pressed(KEY_D)):
		dir.x += 1
	if (use_arrows and Input.is_key_pressed(KEY_UP)) or (use_wasd and Input.is_key_pressed(KEY_W)):
		dir.y -= 1
	if (use_arrows and Input.is_key_pressed(KEY_DOWN)) or (use_wasd and Input.is_key_pressed(KEY_S)):
		dir.y += 1
	if dir != Vector2.ZERO:
		dir = _view_dir(dir.normalized())      # keys are read on the screen: turn them with the view
		p.facing = dir
		
	if touch_on and tc.move != Vector2.ZERO:
		dir = _view_dir(tc.move)
		p.facing = dir.normalized()
	
	# PRESS (hold): your player closes down the opponent who has the ball, staying goal-side of him
	var press = false
	if not two:
		press = Input.is_key_pressed(KEY_U)
	elif team == 0:
		press = Input.is_key_pressed(KEY_T)
	else:
		press = Input.is_key_pressed(KEY_COMMA)
	if touch_on and tc.get("press"):
		press = true
	var press_carrier = null
	if press and not _dead_ball() and not p.is_gk and dribble_owner != null and is_instance_valid(dribble_owner) and dribble_owner.team != p.team:
		press_carrier = dribble_owner
	var speed = HUMAN_SPEED * _sprint_update(team, delta, two, touch_on, tc)
	if p.is_tackling:
		speed = HUMAN_SPEED * 1.45
	# SHIELD (hold): turn your back on the defender and keep the ball on the far side of your body: slower, hard to tackle
	var shield_key = false
	if not two:
		shield_key = Input.is_key_pressed(KEY_O)
	elif team == 0:
		shield_key = Input.is_key_pressed(KEY_Y)
	else:
		shield_key = Input.is_key_pressed(KEY_M)
	if touch_on and tc.get("shield"):
		shield_key = true
	human_shield[team] = shield_key
	if shield_p == p:
		speed = HUMAN_SPEED * 0.55
	var keeper_holds = p.is_gk and gk_human[team] and gk_hold_timer[team] > 0.0
	if keeper_holds:
		speed = HUMAN_SPEED * 0.45                   # he walks with the ball, he does not sprint
		
		#eej
	if press_carrier != null:
		var distance_to_carrier = p.position.distance_to(press_carrier.position)
		var to_own = _own_goal(p.team) - press_carrier.position
		var gdir = to_own.normalized() if to_own.length() > 1.0 else Vector2.ZERO
		var ptgt = press_carrier.position + gdir * 38.0 + press_carrier.vel * 0.15
	# Get closer to the ball when approaching the opponent
		if distance_to_carrier < 75.0:
			ptgt = ball.position + press_carrier.vel * 0.08
		ptgt = _inside(ptgt)
		p.vel = _steer(p, ptgt, speed)
		var face_to = ball.position - p.position
		if face_to.length() > 1.0:
			p.facing = face_to.normalized()
	else:
		p.vel = dir * speed
	_move(p, delta)
	if keeper_holds:
		_human_keeper_hold(p, delta, team)
# Automatically attempt to win the ball when close enough
	if press_carrier != null:
		if p.tackle_cd <= 0.0 and state == "playing":
			if ball.height_z <= 32.0:
				if p.position.distance_to(ball.position) < PR + BR + 18.0:
					kick_system.cancel(team)
					_perform_tackle(p)
	
	var shoot = false
	var do_pass = false
	var through_ball = false
	var tackle = false
	if not two:
		shoot = Input.is_key_pressed(KEY_SPACE)
		do_pass = Input.is_key_pressed(KEY_J)
		through_ball = Input.is_key_pressed(KEY_L)
		tackle = Input.is_key_pressed(KEY_K)
	elif team == 0:
		shoot = Input.is_key_pressed(KEY_F)
		do_pass = Input.is_key_pressed(KEY_G)
		through_ball = Input.is_key_pressed(KEY_H)
		tackle = Input.is_key_pressed(KEY_SPACE)
	else:
		shoot = Input.is_key_pressed(KEY_ENTER) or Input.is_key_pressed(KEY_KP_ENTER)
		do_pass = Input.is_key_pressed(KEY_CONTROL)
		through_ball = Input.is_key_pressed(KEY_SHIFT)
		tackle = Input.is_key_pressed(KEY_ALT)
		
	if touch_on:
		shoot = shoot or tc.shoot
		do_pass = do_pass or tc.pass_held
		tackle = tackle or tc.tackle
	
	var cross = false
	if not two:
		cross = Input.is_key_pressed(KEY_I)
	elif team == 0:
		cross = Input.is_key_pressed(KEY_R)
	else:
		cross = Input.is_key_pressed(KEY_PERIOD)
	if touch_on and tc.get("cross"):
		cross = true

	if tackle and p.tackle_cd <= 0.0 and not _dead_ball():
		kick_system.cancel(team)
		_perform_tackle(p)
	else:
		# kicks: hold for power, release to kick (kick_system.gd decides the rest)
		kick_system.human_frame(p, team, {"shoot": shoot, "pass": do_pass, "through": through_ball, "cross": cross}, dir, delta)


# the keeper has caught it and you are in charge: the ball stays in his hands while you aim a pass, a throw or a kick
# (the usual pass / shoot buttons). Six seconds, then the game plays it for you.
func _human_keeper_hold(p, delta, team):
	gk_hold_timer[team] -= delta
	dribble_owner = null
	var f = p.facing if p.facing.length() > 0.1 else Vector2(_dir_of(team), 0.0)
	ball.position = p.position + f.normalized() * 14.0
	ball.vel = Vector2.ZERO
	ball.height_z = 0.0
	ball.vel_z = 0.0
	if gk_hold_timer[team] <= 0.0:
		gk_hold_timer[team] = 0.0
		gk_human[team] = false
		kick_system.cancel(team)
		_gk_distribute(p, false)


func _attack_goal(team):
	var cy = PITCH.position.y + PITCH.size.y / 2.0
	return Vector2(PITCH.end.x if team == 0 else PITCH.position.x, cy)


func _steer(p, target, speed):
	var d = target - p.position
	if d.length() < 4.0:
		return Vector2.ZERO
	return d.normalized() * min(speed, d.length() * 8.0)


func _evaluate_shot(p, opp_goal):
	var center_y = PITCH.position.y + PITCH.size.y / 2.0
	var goal_x = opp_goal.x
	var best_target = Vector2(goal_x, center_y)
	var best_score = -100.0
	for offset in [-GOAL_H * 0.32, 0.0, GOAL_H * 0.32]:
		var target = Vector2(goal_x, center_y + offset)
		var shot_vec = target - p.position
		var dist = shot_vec.length()
		var forward = shot_vec.x * (1.0 if p.team == 0 else -1.0)
		if forward <= 0.0:
			continue
		var forward_ratio = forward / max(dist, 1.0)
		var score = 100.0 - dist * 0.16
		score -= (1.0 - forward_ratio) * 42.0
		score -= _shot_lane_risk(p.position, target, p.team) * 1.0
		var keeper = players[11] if p.team == 0 else players[0]
		if keeper != null:
			var keeper_y_dist = abs(target.y - keeper.position.y)
			if keeper_y_dist < 34.0:
				score -= (34.0 - keeper_y_dist) * 0.45
		if score > best_score:
			best_score = score
			best_target = target
	return {"target": best_target, "score": best_score}


func _shot_lane_risk(from_pos, to_pos, attacking_team):
	var risk = 0.0
	for opp in players:
		if opp.team == attacking_team:
			continue
		var lane_dist = _distance_to_segment(opp.position, from_pos, to_pos)
		if lane_dist < 24.0:
			risk += 24.0 * (1.0 - lane_dist / 24.0)
		elif lane_dist < 48.0:
			risk += 8.0 * (1.0 - (lane_dist - 24.0) / 24.0)
	return min(risk, 42.0)


func _distance_to_segment(point, a, b):
	var ab = b - a
	var length_sq = ab.length_squared()
	if length_sq <= 0.001:
		return point.distance_to(a)
	var t = clamp((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return point.distance_to(a + ab * t)


func _pass_lane_risk(p, receiver):
	if receiver == null:
		return 100.0
	var target = receiver.position + receiver.vel * 0.18
	var risk = 0.0
	for opp in players:
		if opp.team == p.team:
			continue
		var lane_dist = _distance_to_segment(opp.position, p.position, target)
		if lane_dist < 25.0:
			risk += 22.0 * (1.0 - lane_dist / 25.0)
		elif lane_dist < 48.0:
			risk += 7.0 * (1.0 - (lane_dist - 25.0) / 23.0)
	return min(risk, 38.0)


func _carry_option_score(p, opp_goal):
	var dir = 1.0 if p.team == 0 else -1.0
	var nearest_ahead = 180.0
	var nearest_any = 180.0
	for opp in players:
		if opp.team == p.team:
			continue
		var delta_pos = opp.position - p.position
		var d = delta_pos.length()
		nearest_any = min(nearest_any, d)
		var forward = delta_pos.x * dir
		if forward > -8.0 and d < nearest_ahead:
			nearest_ahead = d
	var space_bonus = clamp((nearest_ahead - 25.0) * 0.22, 0.0, 28.0)
	var pressure_penalty = max(0.0, 65.0 - nearest_any) * 0.32
	var dist_goal = p.position.distance_to(opp_goal)
	var progress_bonus = clamp((520.0 - dist_goal) * 0.035, 0.0, 14.0)
	return 39.0 + space_bonus + progress_bonus - pressure_penalty


func _opponent_near(p, r):
	for q in players:
		if q.team != p.team and q.position.distance_to(p.position) < r:
			return true
	return false


func _clamp_player(p):
	if rules != null and rules.enabled:
		var thrower = _dead_ball() and rules.kind == "throw_in" and rules.taker == p
		if thrower or (p == throw_taker and throw_free_t > 0.0):
			# a thrower stands OUTSIDE the touchline ...
			p.position.x = clamp(p.position.x, PITCH.position.x + PR, PITCH.end.x - PR)
			p.position.y = clamp(p.position.y, PITCH.position.y - 40.0, PITCH.end.y + 40.0)
			# ... and cannot walk away from his spot while he takes it
			if thrower and rules.phase == "ready" and rules.arrived.get(p, false):
				var anchor = rules.targets.get(p, p.position)
				var off = p.position - anchor
				if off.length() > THROW_LEASH:
					p.position = anchor + off.normalized() * THROW_LEASH
			return
		# every other taker (free kick, corner, penalty, goal kick, kick-off) also stands still over the ball:
		# a few pixels of give, no walking about; the stick still aims the kick
		if _dead_ball() and rules.taker == p and rules.phase == "ready" and rules.arrived.get(p, false):
			var anchor2 = rules.targets.get(p, p.position)
			var off2 = p.position - anchor2
			if off2.length() > THROW_LEASH:
				p.position = anchor2 + off2.normalized() * THROW_LEASH
	p.position.x = clamp(p.position.x, PITCH.position.x + PR, PITCH.end.x - PR)
	p.position.y = clamp(p.position.y, PITCH.position.y + PR, PITCH.end.y - PR)


func _inside(pt):
	return Vector2(
		clamp(pt.x, PITCH.position.x + PR, PITCH.end.x - PR),
		clamp(pt.y, PITCH.position.y + PR, PITCH.end.y - PR))


func _move(p, delta):
	p.position += p.vel * delta
	_clamp_player(p)


func _separate_players():
	for i in range(players.size()):
		for j in range(i + 1, players.size()):
			var a = players[i]
			var b = players[j]
			var d = a.position - b.position
			var dist = d.length()
			if dist < PR * 2.0 and dist > 0.01:
				var push = d / dist * (PR * 2.0 - dist) * 0.5
				a.position += push
				b.position -= push


# ------------------------------------------------------------ HELPERS

func _pid(p):
	return p.team * 11 + p.slot


func _is_human_player(p):
	return p == sel[0] or (Game.two_player and p == sel[1])


# true while the referee holds the ball (a restart is being set up or waited for)
func _dead_ball():
	return rules != null and rules.enabled and rules.active


func _dir_of(team):
	return 1.0 if team == 0 else -1.0


func _own_goal(team):
	var cy = PITCH.position.y + PITCH.size.y / 2.0
	return Vector2(PITCH.position.x if team == 0 else PITCH.end.x, cy)


func _depth_of_x(x, team):
	return (x - PITCH.position.x) if team == 0 else (PITCH.end.x - x)


func _ball_k():
	var f = clamp(float(active_pitch_data.get("friction", 0.4)), 0.05, 0.98)
	return -log(f)


func _pass_speed(d):
	return clamp(d * _ball_k() * 1.55, 240.0, 560.0)


func _in_own_box(team, pt):
	var cy = PITCH.position.y + PITCH.size.y / 2.0
	return _depth_of_x(pt.x, team) < GK_BOX_DEPTH and abs(pt.y - cy) < GK_BOX_HALF


func _role_traits_of(p):
	return TacticSystem.role_traits(shape_proxy[_pid(p)]["role"])


func _nearest_opp_dist(team, pos):
	var best = 1e9
	for q in players:
		if q.team != team:
			best = min(best, q.position.distance_to(pos))
	return best


func _striker_index(team):
	var layout = TacticSystem.FORMATIONS.get(profiles[team]["formation"], TacticSystem.FORMATIONS["4-4-2"])
	var best = 1
	var bx = -1.0
	for s in range(1, layout.size()):
		if layout[s].x > bx:
			bx = layout[s].x
			best = s
	return team * 11 + best


func _cmp_first(a, b):
	return a[0] < b[0]


# ------------------------------------------------------------ OFFSIDE
# Offside is judged in match_rules.gd: a snapshot is taken when the ball is played (on_ball_played, called
# from _kick_apply) and the call is made when an offside team-mate touches it (on_touch, called from
# _ball_player_contacts).

# kept only so that older callers (kick_system.gd) do not break: it no longer does anything
func _check_offside(_passer, _receiver):
	return false


# ------------------------------------------------------------ KICK-OFF

func _home_pos(team, slot):
	return TacticSystem.get_formation_pos(profiles[team]["formation"], slot, team, PITCH)


func _kickoff():
	ball.position = PITCH.position + PITCH.size / 2.0
	ball.vel = Vector2.ZERO
	ball.height_z = 0.0
	ball.vel_z = 0.0
	ball_stuck_t = 0.0
	ball_ghost_t = 0.0
	gk_hold_timer = [0.0, 0.0]
	gk_cd = [0.0, 0.0]
	gk_react = [0.0, 0.0]
	gk_shot_seen = [false, false]
	gk_dive_t = [0.0, 0.0]
	gk_down_t = [0.0, 0.0]
	gk_dived = [false, false]
	gk_wait = [0.0, 0.0]
	gk_human = [false, false]
	gk_claim_t = [0.0, 0.0]
	shield_p = null
	trap_until = {0: 0.0, 1: 0.0}
	trap_cd = {0: 0.0, 1: 0.0}
	press_trig_until = {0: 0.0, 1: 0.0}
	shield_t.clear()
	shield_rest.clear()
	shield_hint.clear()
	dribble_len = [12.0, 12.0]
	run_until = [0.0, 0.0]
	push_level = [0, 0]
	pass_t = 0.0
	pass_target = null
	trans_t = [0.0, 0.0]
	last_poss_team = -1
	dribble_owner = null
	last_touch = null
	if scramble != null:
		scramble.reset()
	shape_mem.clear()
	contest_cd = 0.0
	prev_switch_p1 = false
	prev_switch_p2 = false
	ai_decision_timers.clear()
	carry_dir_mem.clear()
	ball_off_mem.clear()
	if kick_system != null:
		kick_system.pending.clear()
		kick_system.cancel(0)
		kick_system.cancel(1)
	possession = [false, false]
	
	offside_timer = 0.0
	
	var cx = PITCH.position.x + PITCH.size.x / 2.0
	var cy = PITCH.position.y + PITCH.size.y / 2.0
	var takers = [_striker_index(0), _striker_index(1)]
	for p in players:
		var home = _home_pos(p.team, p.slot)
		p.home_pos = home
		shape_proxy[_pid(p)]["home_pos"] = home
		var pos = home
		var gap = 40.0                           # the kicking side may stand close to the circle ...
		if p.team != kickoff_team:
			gap = MatchRules.CIRCLE_R + 6.0        # ... the other side starts outside the centre circle
		if p.team == 0:
			pos.x = min(pos.x, cx - gap)
		else:
			pos.x = max(pos.x, cx + gap)
		if _pid(p) == takers[kickoff_team]:
			pos = Vector2(cx - 18.0 * _dir_of(kickoff_team), cy)
		p.position = pos
		p.vel = Vector2.ZERO
		p.facing = Vector2.RIGHT if p.team == 0 else Vector2.LEFT
		p.kick_cd = 0.0
		p.tackle_cd = 0.0
		p.is_tackling = false
		p.tackle_timer = 0.0
		p.is_diving = false
		p.jump_height = 0.0
	_set_selected(0, players[takers[0]])
	if Game.two_player:
		_set_selected(1, players[takers[1]])
	state = "playing"
	_show_msg("", 0)
	_update_hud()
	if rules != null and rules.enabled:
		rules.begin_kickoff(kickoff_team)        # the referee holds the ball on the spot until the taker plays it

# ------------------------------------------------------------ POSSESSION & CHASERS

func _update_chasers():
	if gk_hold_timer[0] > 0.0 or gk_hold_timer[1] > 0.0:
		chasers = [null, null]
		attacking = [false, false]
		possession = [gk_hold_timer[0] > 0.0, gk_hold_timer[1] > 0.0]
		_track_possession_change()
		return

	for team in range(2):
		var best = null
		var bd = 1e9
		for p in players:
			if p.team != team or p.is_gk:
				continue
			var d = p.position.distance_to(ball.position)
			if d < bd:
				bd = d
				best = p
		chasers[team] = best

	if pass_t > 0.0 and pass_target != null and is_instance_valid(pass_target):
		chasers[pass_target.team] = pass_target

	if dribble_owner != null and is_instance_valid(dribble_owner):
		chasers[dribble_owner.team] = dribble_owner
		possession[dribble_owner.team] = true
		possession[1 - dribble_owner.team] = false
	elif last_touch != null and is_instance_valid(last_touch) and ball.vel.length() > 90.0:
		possession[last_touch.team] = true
		possession[1 - last_touch.team] = false
	else:
		for team in range(2):
			if chasers[team] == null:
				possession[team] = false
				continue
			var mine = chasers[team].position.distance_to(ball.position)
			var theirs = chasers[1 - team].position.distance_to(ball.position) if chasers[1 - team] != null else 1e9
			var diff = theirs - mine
			if diff > 12.0:
				possession[team] = true
			elif diff < -12.0:
				possession[team] = false

	var mid = PITCH.position.x + PITCH.size.x / 2.0
	for team in range(2):
		if chasers[team] == null:
			attacking[team] = false
			continue
		var mine2 = chasers[team].position.distance_to(ball.position)
		var theirs2 = chasers[1 - team].position.distance_to(ball.position) if chasers[1 - team] != null else 1e9
		var in_opp_half = (ball.position.x > mid) if team == 0 else (ball.position.x < mid)
		attacking[team] = possession[team] or mine2 < theirs2 + 15.0 or (in_opp_half and mine2 < theirs2 + 80.0)
	_track_possession_change()


func _track_possession_change():
	var pt = -1
	if possession[0] and not possession[1]:
		pt = 0
	elif possession[1] and not possession[0]:
		pt = 1
	if pt != -1 and pt != last_poss_team:
		trans_t[pt] = 1.6 * float(profiles[pt]["tac"]["transition_speed"])
		last_poss_team = pt


func _update_selection_for(team):
	if gk_human[team]:
		return                                       # the keeper has the ball in his hands: he stays yours until it is played
	var best = chasers[team]
	var cur = sel[team]
	if best == null:
		return
	if cur == null or cur.is_gk:
		_set_selected(team, best)
		return
	if pass_t > 0.0 and pass_target != null and is_instance_valid(pass_target) and pass_target.team == team and best == pass_target and cur != best:
		_set_selected(team, best)
		return
	if best != cur:
		if dribble_owner == cur:
			return   
		if best.position.distance_to(ball.position) < cur.position.distance_to(ball.position) - 25.0:
			_set_selected(team, best)


# ------------------------------------------------------------ TEAM PLANS

func _update_team_plans():
	for team in range(2):
		team_ctx[team] = _build_ctx(team)
	for team in range(2):
		_assign_pressers(team)
	for team in range(2):
		_assign_marks(team)


func _build_ctx(team):
	var prof = profiles[team]
	var last_d = 0.0
	for q in players:
		if q.team == team or q.is_gk:
			continue
		last_d = max(last_d, _depth_of_x(q.position.x, team))
	var poss = possession[team]
	if not possession[0] and not possession[1]:
		var mine = chasers[team].position.distance_to(ball.position) if chasers[team] != null else 1e9
		var theirs = chasers[1 - team].position.distance_to(ball.position) if chasers[1 - team] != null else 1e9
		poss = mine <= theirs
	return {
		"pitch": PITCH, "ball": ball.position, "dir": _dir_of(team),
		"tac": prof["tac"], "style": prof["style"], "poss": poss,
		"trans": trans_t[team] > 0.0, "opp_last_d": last_d
	}


func _assign_pressers(team):
	var list = []
	pressers_of[team] = list
	if gk_hold_timer[0] > 0.0 or gk_hold_timer[1] > 0.0 or possession[team]:
		return
	if gk_claim_t[team] > 0.0 and _in_own_box(team, ball.position):
		return                                       # (the keeper has come for it)
	var tac = profiles[team]["tac"]
	var L = PITCH.size.x
	var ball_d = _depth_of_x(ball.position.x, team)
	var loose = (not possession[0]) and (not possession[1])
	var trig = TrapAI.press_active(self, team)       # a trigger: he has just passed it back / mis-controlled it / is in a trap
	var may_press = ball_d <= float(tac["press_depth"]) * L or ball_d < L * 0.22 or trig
	var cands = []
	for q in players:
		if q.team == team and not q.is_gk:
			cands.append([q.position.distance_to(ball.position), q])
	cands.sort_custom(self, "_cmp_first")
	var n = min(int(tac["pressers"]) + (1 if trig else 0), 3)
	for i in range(cands.size()):
		if list.size() >= n:
			break
		var dist = cands[i][0]
		var cand = cands[i][1]
		if i == 0:
			if may_press or loose or dist < 220.0:
				list.append(cand)
			else:
				break
		else:
			var tr = _role_traits_of(cand)
			if may_press and tr["press"] >= (0.6 if trig else 0.8) and dist < (380.0 if trig else 320.0) and not (tr["fam"] == "CB" and ball_d > L * 0.5):
				list.append(cand)


func _assign_marks(team):
	var old = marks_of[team]
	var fresh = {}
	marks_of[team] = fresh
	if possession[team] or gk_hold_timer[0] > 0.0 or gk_hold_timer[1] > 0.0:
		return
	var own_goal = _own_goal(team)
	var busy = {}
	for pr in pressers_of[team]:
		busy[_pid(pr)] = true
	var defenders = []
	for p in players:
		if p.team != team or p.is_gk or busy.has(_pid(p)):
			continue
		var fam = _role_traits_of(p)["fam"]
		if fam == "ST" or fam == "WG":
			continue
		defenders.append(p)
	var threats = []
	for q in players:
		if q.team == team or q.is_gk or dribble_owner == q:
			continue
		var dg = q.position.distance_to(own_goal)
		if dg < 520.0:
			threats.append([dg, q])
	threats.sort_custom(self, "_cmp_first")
	var claimed = {}
	var used = {}
	for df in defenders:
		var did = _pid(df)
		if old.has(did):
			var oq = old[did]
			if is_instance_valid(oq) and not claimed.has(_pid(oq)) and oq != dribble_owner \
					and oq.position.distance_to(own_goal) < 560.0 and df.position.distance_to(oq.position) < 230.0:
				fresh[did] = oq
				claimed[_pid(oq)] = true
				used[did] = true
	for th in threats:
		var tq = th[1]
		if claimed.has(_pid(tq)):
			continue
		var best = null
		var bd = 190.0
		for df2 in defenders:
			if used.has(_pid(df2)):
				continue
			var dd = df2.position.distance_to(tq.position)
			if dd < bd:
				bd = dd
				best = df2
		if best != null:
			fresh[_pid(best)] = tq
			claimed[_pid(tq)] = true
			used[_pid(best)] = true


# ------------------------------------------------------------ HUMAN ACTIONS

func _human_shoot(p):
	var opp_goal = _attack_goal(p.team)
	var shot_dir = p.facing
	var to_goal = opp_goal - p.position
	var dist = to_goal.length()
	if dist > 1.0 and p.facing.dot(to_goal / dist) > 0.3:
		var shot = _evaluate_shot(p, opp_goal)
		shot_dir = (shot["target"] - ball.position).normalized()
		
	if ui_controller:
		ui_controller.record_shot(p.team)
		
	_try_kick(p, shot_dir, 720.0, 110.0) # Elevated shot force


func _human_pass(p):
	if p.kick_cd > 0.0 or p.position.distance_to(ball.position) > PR + BR + 12.0:
		return
	var best = null
	var best_score = -1e9
	for q in players:
		if q.team != p.team or q == p or q.is_gk:
			continue
		var to = q.position - p.position
		var d = to.length()
		if d < 25.0 or d > 600.0:
			continue
		var align = p.facing.dot(to / d)
		var obstruction = 0.0
		for opp in players:
			if opp.team != p.team and opp.position.distance_to(q.position) < 60.0:
				obstruction += 1.5
		var score = (align * 2.0) - (d * 0.002) - obstruction - _pass_lane_risk(p, q) * 0.05
		if score > best_score:
			best_score = score
			best = q
			
	if best != null:
		if _pass_to(p, best, 0.25, 12.0, 0.0):
			_set_selected(p.team, best)
			if ui_controller:
				ui_controller.record_pass(p.team)
	else:
		_try_kick(p, p.facing, 400.0, 0.0)
		if ui_controller:
			ui_controller.record_pass(p.team)


func _human_through_ball(p):
	if p.kick_cd > 0.0 or p.position.distance_to(ball.position) > PR + BR + 12.0:
		return
	var best = null
	var best_score = -1e9
	var dir = _dir_of(p.team)
	
	for q in players:
		if q.team != p.team or q == p or q.is_gk:
			continue
		var to_q = q.position - p.position
		var d = to_q.length()
		if d < 40.0 or d > 700.0:
			continue
		
		var fwd = to_q.x * dir
		if fwd < 10.0:
			continue
			
		var space_ahead_score = q.vel.x * dir * 2.5
		var score = fwd * 0.8 + space_ahead_score - d * 0.003
		if score > best_score:
			best_score = score
			best = q
			
	if best != null:
		_pass_to(p, best, 0.65, 18.0, 130.0) # Lobbed lofted through pass
		_set_selected(p.team, best)
		if ui_controller:
			ui_controller.record_pass(p.team)
	else:
		var forward_space = p.position + Vector2(dir * 300.0, rand_range(-60.0, 60.0))
		_try_kick(p, forward_space - ball.position, 550.0, 90.0)
		if ui_controller:
			ui_controller.record_pass(p.team)


func _pass_to(p, q, lead, jitter, lift_z = 0.0):
	if kick_system != null:
		return kick_system.ai_pass(p, q, lead, jitter, lift_z)
	return _pass_to_legacy(p, q, lead, jitter, lift_z)


# the previous pass code, kept as a fallback
func _pass_to_legacy(p, q, lead, jitter, lift_z = 0.0):
	var tgt = q.position + q.vel * lead
	if jitter > 0.0:
		tgt += Vector2(rand_range(-jitter, jitter), rand_range(-jitter, jitter))
	tgt = _inside(tgt)
	var d = tgt.distance_to(ball.position)
	var spd = _pass_speed(d)
	if _try_kick(p, tgt - ball.position, spd, lift_z):
		var kk = _ball_k()
		var arrive = 1.0 - d * kk / spd
		var t = 2.2 if arrive <= 0.05 else clamp(-log(arrive) / kk, 0.5, 2.2)
		pass_target = q
		pass_t = t + 0.4
		return true
	return false


func _perform_tackle(p):
	p.is_tackling = true
	p.tackle_timer = 0.25
	p.tackle_cd = 0.8
	p.update()
	
	emit_turf_impact(p.position + p.facing * 12.0, p.facing)
	
	if state != "playing" or p.position.distance_to(ball.position) >= PR + BR + 18.0:
		return
	if gk_hold_timer[0] > 0.0 or gk_hold_timer[1] > 0.0:
		return   
	var holder = null
	if dribble_owner != null and is_instance_valid(dribble_owner):
		holder = dribble_owner
		if holder.team == p.team:
			return
	var won = true
	if holder != null:
		var chance = TACKLE_SUCCESS
		if shield_p == holder:
			var tdir = p.position - holder.position
			if tdir.length() > 1.0 and tdir.normalized().dot(-shield_away) > 0.25:
				chance *= 0.35                           # he has his body between you and the ball
			else:
				chance *= 0.8                            # (from the other side it is easier, but he is still turning)
		won = randf() <= chance
		# the referee: a late or clumsy tackle on the ball carrier is a foul (free kick / penalty, maybe a card)
		if rules != null and rules.on_tackle(p, holder, won):
			return
	if holder != null and not won:
		p.tackle_cd = 1.4
		return
	var swing = ball.position - p.position
	if swing.length() < 0.5:
		swing = p.facing
	var dirv = swing.normalized() * 0.5 + p.facing.normalized() * 0.5
	if dirv.length() < 0.1:
		dirv = swing.normalized()
	dirv = dirv.normalized().rotated(rand_range(-0.5, 0.5))
	dribble_owner = null
	if holder != null:
		holder.kick_cd = 0.5
		ai_decision_timers[_pid(holder)] = 0.5
	ball.position = p.position + dirv * (PR + BR + 2.0)
	ball.vel = dirv * 300.0
	ball_ghost_t = 0.15
	last_touch = p
	pass_t = 0.0
	pass_target = null


# ------------------------------------------------------------ AI CONTROLS

func _ai_control(p, delta):
	if p.is_gk:
		_ai_goalkeeper(p, delta)
	else:
		_ai_outfield(p, delta)


func _ai_plan_legacy(p, delta):
	var team = p.team
	var gk_has_ball = gk_hold_timer[0] > 0.0 or gk_hold_timer[1] > 0.0
	var has_owner = dribble_owner != null and is_instance_valid(dribble_owner)
	var receiving = (not gk_has_ball) and (not has_owner) and pass_t > 0.0 and pass_target == p
	var plan
	if dribble_owner == p:
		plan = _ai_carrier(p, delta)
	elif receiving:
		plan = [_intercept_point(p, AI_SPEED * 1.12), AI_SPEED * 1.12]
	elif (not gk_has_ball) and (not has_owner) and _wants_loose_ball(p):
		var sp = AI_SPEED * _press_speed_mult(p)
		plan = [_intercept_point(p, sp), sp]
	elif (not gk_has_ball) and has_owner and dribble_owner.team != team and pressers_of[team].has(p):
		plan = _ai_press(p, delta)
	else:
		plan = [_ai_positioning_target(p), _ai_positioning_speed(p)]
	return plan


func _ai_outfield(p, delta):
	var plan
	if USE_SPEC_AI:
		plan = PlayerDecisionAI.plan(self, p, delta)   # intent -> AttackAI / DefendAI / existing executors
	else:
		plan = _ai_plan_legacy(p, delta)

	var target = _inside(plan[0])
	p.vel = _steer(p, target, plan[1])
	if p.vel != Vector2.ZERO:
		p.facing = p.vel.normalized()
	else:
		var tb = ball.position - p.position
		if tb.length() > 1.0:
			p.facing = tb.normalized()
	_move(p, delta)


func _ai_speed():
	return AI_SPEED


# Smoothed team state: possession must change for 0.25 s before the state does,
# so a ball that wobbles between two players never makes a whole team flip.
func _update_team_states(delta):
	ai_clock += delta
	for t in range(2):
		gain_t[t] = min(gain_t[t] + delta, 60.0)
		loss_t[t] = min(loss_t[t] + delta, 60.0)
		var want = bool(team_ctx[t]["poss"])
		if want != state_poss[t]:
			state_hold_t[t] += delta
			if state_hold_t[t] >= 0.25:
				state_poss[t] = want
				state_hold_t[t] = 0.0
				if ai_clock > 1.0:                # (not at the kick-off)
					if want:
						gain_t[t] = 0.0
					else:
						loss_t[t] = 0.0
		else:
			state_hold_t[t] = 0.0
		team_state[t] = TacticSystem.compute_state(state_poss[t], gain_t[t], loss_t[t], profiles[t]["tac"])
		team_ctx[t]["state"] = team_state[t]
	DefendAI.assign_lane_blockers(self)
	TrapAI.tick(self, delta)                     # the offside trap and the pressing triggers


func _wants_loose_ball(p):
	if p.is_gk or p.kick_cd > 0.0:
		return false
	if gk_claim_t[p.team] > 0.0 and _in_own_box(p.team, ball.position):
		return false                                 # the keeper is coming for it: it is his box
	var team = p.team
	if pass_t > 0.0 and pass_target != null and is_instance_valid(pass_target) and pass_target.team == team:
		return false   
	if pressers_of[team].has(p):
		return true
	return possession[team] and chasers[team] == p


func _press_speed_mult(p):
	return 0.97 + 0.07 * float(profiles[p.team]["tac"]["press_intensity"]) + (0.12 if TrapAI.press_active(self, p.team) else 0.0)


func _ai_positioning_speed(p):
	if trans_t[p.team] > 0.0:
		return AI_SPEED * (1.0 + 0.05 * float(profiles[p.team]["tac"]["transition_speed"]))
	return AI_SPEED


func _ai_positioning_target(p):
	var ctx = team_ctx[p.team]
	var shape = ShapeAI.base_shape(self, p)       # the team shape: stretched / squeezed by the tactic's width, flat lines
	if gk_hold_timer[p.team] > 0.0:
		return _buildout_target(p, shape)
	var t
	if ctx["poss"]:
		t = _support_target(p, shape)
		if rules != null:
			t = rules.clamp_onside(p.team, t)      # wait level with the last defender instead of drifting offside
	else:
		t = _marking_target(p, shape)
	return ShapeAI.finish(self, p, [t, 0.0], "hold", shape)[0]   # his zone, room from his team-mates, no twitching


func _support_target(p, shape):
	var team = p.team
	var target = shape
	var carrier = null
	if dribble_owner != null and is_instance_valid(dribble_owner) and dribble_owner.team == team:
		carrier = dribble_owner
	if carrier != null and carrier != p:
		var rank = _support_rank(p, carrier)
		if rank < 2:
			var tr = _role_traits_of(p)
			var sd = float(profiles[team]["tac"]["support_dist"]) * 520.0
			var dir = _dir_of(team)
			var side = 1.0 if p.position.y >= carrier.position.y else -1.0
			if abs(p.position.y - carrier.position.y) < 10.0:
				side = -1.0 if rank == 0 else 1.0
			var ang = 55.0
			if (p.position.x - carrier.position.x) * dir < -20.0:
				ang = 125.0
			var a = deg2rad(ang)
			var slot = carrier.position + Vector2(dir * cos(a), side * sin(a)) * sd
			var w = 0.25 if tr["run"] else 0.6
			target = shape.linear_interpolate(_inside(slot), w)
	for mate in players:
		if mate.team != team or mate == p or mate.is_gk or mate == carrier:
			continue
		var away = target - mate.position
		var md = away.length()
		if md < 48.0:
			if md < 0.01:
				away = Vector2(0.0, -1.0 if int(p.slot) % 2 == 0 else 1.0)
			target += away.normalized() * (48.0 - md) * 0.55
	return _inside(target)


func _support_rank(p, carrier):
	var dp = p.position.distance_to(carrier.position)
	var rank = 0
	for q in players:
		if q.team != p.team or q == p or q == carrier or q.is_gk:
			continue
		if q.position.distance_to(carrier.position) < dp:
			rank += 1
	return rank


func _marking_target(p, shape):
	var marks = marks_of[p.team]
	var pid = _pid(p)
	if not marks.has(pid):
		return shape
	var m = marks[pid]
	if not is_instance_valid(m):
		return shape
	var to_goal = _own_goal(p.team) - m.position
	var mp = m.position
	if to_goal.length() > 1.0:
		mp = m.position + to_goal.normalized() * 28.0   
	var fam = _role_traits_of(p)["fam"]
	var w = 0.65
	if fam == "CM" or fam == "AM":
		w = 0.45
	elif fam == "FB":
		w = 0.55
	return shape.linear_interpolate(mp, w)


func _ai_carrier(p, delta):
	var team = p.team
	var prof = profiles[team]
	var tac = prof["tac"]
	var st = prof["style"]
	var opp_goal = _attack_goal(team)
	_ai_decide(p, opp_goal, delta)
	if dribble_owner != p:
		return [p.position, AI_SPEED]   
	var goal_dir = (opp_goal - p.position).normalized()
	var cdir = _best_carry_dir(p, goal_dir, st, tac)
	var speed = AI_SPEED * 0.95
	if trans_t[team] > 0.0:
		speed = AI_SPEED * (0.95 + 0.04 * float(tac["transition_speed"]))
	if shield_p == p:
		speed *= 0.5                                 # shielding: he holds his ground with his back to the man
	return [p.position + cdir * 80.0, speed]


func _ai_press(p, delta):
	var team = p.team
	var tac = profiles[team]["tac"]
	var tr = _role_traits_of(p)
	var carrier = dribble_owner
	var spd = AI_SPEED * _press_speed_mult(p)
	var to_goal = _own_goal(team) - carrier.position
	var gdir = to_goal.normalized() if to_goal.length() > 1.0 else Vector2.ZERO
	var primary = pressers_of[team].size() > 0 and pressers_of[team][0] == p
	var target
	if primary:
		target = carrier.position + gdir * 30.0 + carrier.vel * 0.15
		if p.position.distance_to(carrier.position) < 60.0:
			target = ball.position + carrier.vel * 0.08
		var db = p.position.distance_to(ball.position)
		if p.tackle_cd <= 0.0 and db < PR + BR + 16.0 and state == "playing":
			var rate = AI_TACKLE_RATE * float(tac["press_intensity"]) * float(tr["press"])
			if randf() < rate * delta:
				_perform_tackle(p)
	else:
		var side = 1.0 if p.position.y > carrier.position.y else -1.0
		target = carrier.position + gdir * 85.0 + Vector2(0.0, side * 55.0)
	return [target, spd]


func _ai_decide(p, opp_goal, delta):
	if p.kick_cd > 0.0 or p.is_gk or state != "playing":
		return
	var pid = _pid(p)
	var wait = float(ai_decision_timers.get(pid, 0.0))
	if wait > 0.0:
		ai_decision_timers[pid] = max(0.0, wait - delta)
		return
	ai_decision_timers[pid] = rand_range(0.18, 0.30) / max(0.5, float(profiles[p.team]["tac"].get("tempo", 1.0)))

	if dribble_owner != p and p.position.distance_to(ball.position) > PR + BR + 10.0:
		return

	var prof = profiles[p.team]
	var st = prof["style"]
	var dist_goal = p.position.distance_to(opp_goal)
	var pressured = _opponent_near(p, 58.0)
	var shot = _evaluate_shot(p, opp_goal)
	var shot_sc = shot["score"] + (st["shoot"] - 0.5) * 24.0
	var opt = _best_pass_option(p)
	var mate = opt["mate"]
	var pass_score = opt["score"]
	var carry_score = _carry_option_score(p, opp_goal) + (st["dribble"] - 0.4) * 24.0
	shield_hint[pid] = pass_score < 44.0 and carry_score < 60.0 and shot_sc < 24.0    # nothing good: cover the ball

	var shoot_range = 350.0 + 450.0 * st["shoot"]
	var shot_thr = 22.0 - (st["shoot"] - 0.5) * 18.0
	if scramble != null and scramble.active and p.team == scramble.att:
		shoot_range += 100.0
		shot_thr -= 10.0                             # a loose ball in the box: shoot first, think later
	if dist_goal < shoot_range and shot_sc >= shot_thr and shot_sc >= pass_score + 4.0:
		var sd = clamp(580.0 + (500.0 - dist_goal) * 0.3, 520.0, 720.0)
		if ui_controller:
			ui_controller.record_shot(p.team)
		kick_system.ai_shoot(p, shot["target"], sd)
		return

	var own_third = _depth_of_x(p.position.x, p.team) < PITCH.size.x * 0.22
	var scrambling_back = scramble != null and scramble.active and p.team == scramble.dfn
	if (own_third and pressured and pass_score < 38.0 and carry_score < 50.0) or scrambling_back:
		_clear_ball(p)                               # (in a scramble in his own box he does not dribble: he clears it)
		return

	var pass_min = 43.0 - (st["risk"] - 0.5) * 12.0
	var lead = 0.18 + 0.30 * st["directness"]
	if mate != null and pass_score >= pass_min and (pass_score >= carry_score + 2.0 or (pressured and pass_score >= pass_min - 6.0)):
		_pass_to(p, mate, lead, 6.0, 0.0)
		if ui_controller:
			ui_controller.record_pass(p.team)
		return
	if pressured and mate != null and pass_score >= pass_min - 9.0 and pass_score > carry_score - 5.0:
		_pass_to(p, mate, lead, 6.0, 0.0)
		if ui_controller:
			ui_controller.record_pass(p.team)
		return


func _best_pass_option(p):
	var best = null
	var best_sc = -100.0
	for q in players:
		if q.team != p.team or q == p or q.is_gk:
			continue
		var s = _pass_eval(p, q)
		if s > best_sc:
			best_sc = s
			best = q
	return {"mate": best, "score": best_sc}


func _best_pass_target(p):
	return _best_pass_option(p)["mate"]


func _pass_option_score(p, mate):
	if mate == null:
		return -100.0
	return _pass_eval(p, mate)


func _pass_eval(p, q):
	var prof = profiles[p.team]
	var tac = prof["tac"]
	var st = prof["style"]
	var dir = _dir_of(p.team)
	var to_q = q.position - p.position
	var d = to_q.length()
	if d < 30.0 or d > 650.0:
		return -100.0
	var fwd = to_q.x * dir
	var lane = _pass_lane_risk(p, q)
	var rp = 0.0
	for opp in players:
		if opp.team != p.team:
			var od = opp.position.distance_to(q.position)
			if od < 65.0:
				rp += (65.0 - od) * 0.35
	var w_fwd = 0.045 + 0.075 * tac["forward_bias"] * (0.5 + st["directness"])
	var lane_w = (0.6 + tac["pass_safety"] * 0.8) * (1.15 - st["risk"] * 0.6)
	var s = 43.0 + fwd * w_fwd - d * 0.02 - lane * lane_w - rp
	s += (tac["pass_safety"] - 0.6) * 8.0
	var pref = tac["support_dist"] * 520.0 * (1.0 + st["directness"])
	s -= abs(d - pref) * 0.012 * (1.0 - st["directness"])
	if st["directness"] > 0.6 and d > 280.0 and fwd > 150.0:
		s += (st["directness"] - 0.6) * 30.0
	if fwd < -35.0:
		s -= 12.0
	var mid_y = PITCH.position.y + PITCH.size.y * 0.5
	var qd = _depth_of_x(q.position.x, p.team)
	var pd = _depth_of_x(p.position.x, p.team)
	if abs(q.position.y - mid_y) > PITCH.size.y * 0.3:
		s += st["wide"] * 5.0
	if abs(p.position.y - mid_y) > PITCH.size.y * 0.28 and pd > PITCH.size.x * 0.68 \
			and abs(q.position.y - mid_y) < PITCH.size.y * 0.22 and qd > PITCH.size.x * 0.78:
		s += 14.0 * st["wide"]
	return s


func _clear_ball(p):
	var dir = _dir_of(p.team)
	var mid_y = PITCH.position.y + PITCH.size.y * 0.5
	var side = 1.0 if p.position.y > mid_y else -1.0
	var aim = _inside(Vector2(p.position.x + dir * 520.0, mid_y + side * PITCH.size.y * 0.30))
	if ui_controller:
		ui_controller.record_pass(p.team)
	kick_system.ai_clear(p, aim)


func _best_carry_dir(p, goal_dir, st, tac):
	var pid = _pid(p)
	var prev = carry_dir_mem.get(pid, goal_dir)
	var best = goal_dir
	var best_s = -1e9
	for ang in [-70.0, -45.0, -22.0, 0.0, 22.0, 45.0, 70.0]:
		var dirv = goal_dir.rotated(deg2rad(ang))
		var probe = p.position + dirv * 95.0
		var near = 140.0
		for opp in players:
			if opp.team == p.team:
				continue
			near = min(near, opp.position.distance_to(probe))
		var s = cos(deg2rad(ang)) * (35.0 + 25.0 * tac["forward_bias"]) + near * 0.30
		var margin_y = min(probe.y - PITCH.position.y, PITCH.end.y - probe.y)
		if margin_y < 40.0:
			s -= (40.0 - margin_y) * 1.2
		var margin_x = min(probe.x - PITCH.position.x, PITCH.end.x - probe.x)
		if margin_x < 40.0:
			s -= (40.0 - margin_x) * 0.8
		s += prev.dot(dirv) * 6.0
		if s > best_s:
			best_s = s
			best = dirv
	carry_dir_mem[pid] = best
	return best


func _intercept_point(p, speed):
	if ball.vel.length() < 25.0:
		return ball.position
	var f = clamp(float(active_pitch_data.get("friction", 0.4)), 0.05, 0.98)
	var k = -log(f)
	var best = ball.position + ball.vel / k
	for i in range(1, 15):
		var t = i * 0.1
		var bp = ball.position + ball.vel * ((1.0 - pow(f, t)) / k)
		if p.position.distance_to(bp) <= speed * t + 6.0:
			best = bp
			break
	return _inside(best)


# ------------------------------------------------------------ AI: GOALKEEPERS

func _ai_goalkeeper(p, delta):
	var team = p.team
	var dirx = _dir_of(team)
	var scr = scramble != null and scramble.active and scramble.dfn == team     # a rebound is up for grabs in his area
	gk_cd[team] = max(0.0, gk_cd[team] - delta)
	gk_claim_t[team] = max(0.0, gk_claim_t[team] - delta)
	_gk_update_shot(team, delta)
	_gk_dive_step(p, team, delta)
	if (gk_dive_t[team] > 0.0 or gk_down_t[team] > 0.0) and gk_hold_timer[team] <= 0.0:
		_gk_reach(p)   
		return

	if gk_hold_timer[team] > 0.0:
		gk_hold_timer[team] -= delta
		p.vel = Vector2.ZERO
		p.facing = Vector2(dirx, 0.0)
		dribble_owner = null
		ball.position = p.position + Vector2(14.0 * dirx, 0.0)
		ball.vel = Vector2.ZERO
		ball.height_z = 0.0
		ball.vel_z = 0.0
		if gk_hold_timer[team] <= 0.0:
			gk_hold_timer[team] = 0.0
			_gk_distribute(p, true)
		return

	var target = _gk_target(p)
	var speed = GK_SPEED
	if gk_shot_seen[team] and gk_react[team] <= 0.0:
		speed = GK_DIVE_SPEED
	else:
		var dom = _gk_domain(p, scr)                   # his box is his domain: one-on-ones, crosses, loose balls, a ball over the top
		if dom != null:
			target = dom[0]
			speed = dom[1]
			gk_claim_t[team] = 0.5                       # (his own defenders stay out of it)
	p.vel = _steer(p, target, speed)
	var tb = ball.position - p.position
	if tb.length() > 1.0:
		p.facing = tb.normalized()
	_move(p, delta)
	_gk_reach(p)


# What he does when he is not just standing on his line. Returns [target, speed] or null.
func _gk_domain(p, scr):
	var team = p.team
	if gk_cd[team] > 0.0:
		return null
	var goal_c = _own_goal(team)
	var dirx = _dir_of(team)
	var cy = PITCH.position.y + PITCH.size.y / 2.0
	var bp = ball.position
	var depth_ball = abs(bp.x - goal_c.x)

	# 1. a one-on-one: an attacker through on goal with nobody of ours between him and it. He comes out to narrow the
	#    angle and dives at the attacker's feet when the ball is a little loose
	var carrier = dribble_owner
	if carrier != null and is_instance_valid(carrier) and carrier.team != team and not carrier.is_gk:
		var to_goal = goal_c - carrier.position
		var cdepth = abs(carrier.position.x - goal_c.x)
		if cdepth < 640.0 and abs(carrier.position.y - cy) < GK_BOX_HALF + 90.0 and to_goal.length() > 1.0:
			var heading = carrier.vel.dot(to_goal.normalized()) > 55.0
			if heading and _lane_clear(team, carrier, goal_c):
				if p.position.distance_to(carrier.position) < 110.0 and carrier.position.distance_to(bp) > 14.0:
					return [_inside(bp + carrier.vel * 0.08), GK_DIVE_SPEED * 1.2]      # the ball is out of his feet: go
				var close = clamp(to_goal.length() * 0.55, 70.0, 300.0)               # come out and meet him ...
				var tgt = carrier.position + to_goal.normalized() * close
				var out = clamp(abs(tgt.x - goal_c.x), 30.0, GK_BOX_DEPTH * 0.85)     # ... but not further than that
				tgt.x = goal_c.x + dirx * out
				return [_inside(tgt), GK_DIVE_SPEED]

	# 2. a ball played in (a cross, a corner, a free kick) that he can reach before any attacker: it is his
	var lt = last_touch
	if carrier == null and lt != null and is_instance_valid(lt) and lt.team != team and not gk_shot_seen[team]:
		if (ball.height_z > 14.0 or ball.vel.length() > 260.0) and ball.vel.x * dirx < -30.0 and ball.height_z < 110.0:
			var ip = _intercept_point(p, GK_DIVE_SPEED)
			if _in_own_box(team, ip) and _gk_first(p, ip):
				return [ip, GK_DIVE_SPEED * 1.05]

	# 3. a loose ball in his box: it is his unless an attacker is clearly nearer
	if carrier == null and ball.vel.length() < (380.0 if scr else 320.0) and _in_own_box(team, bp):
		if p.position.distance_to(bp) < _nearest_opp_dist(team, bp) + (55.0 if scr else 34.0):
			return [_inside(bp), GK_SPEED * 1.3]

	# 4. a ball over the top, running through behind the defence: he sweeps up outside the box if he is first to it
	if carrier == null and not _in_own_box(team, bp) and depth_ball < 480.0 and ball.vel.length() > 60.0 and ball.vel.x * dirx < -40.0:
		var ip2 = _intercept_point(p, GK_DIVE_SPEED)
		if abs(ip2.x - goal_c.x) < 460.0 and _gk_first(p, ip2):
			return [ip2, GK_DIVE_SPEED]
	return null


# nobody of his own team stands between the attacker and the goal (then it is a one-on-one)
func _lane_clear(team, carrier, goal_c):
	var line = goal_c - carrier.position
	var length = line.length()
	if length < 1.0:
		return true
	var u = line / length
	for q in players:
		if q.team != team or q.is_gk:
			continue
		var rel = q.position - carrier.position
		var along = rel.dot(u)
		if along < -20.0 or along > length:
			continue
		if abs(rel.cross(u)) < 80.0 + 0.12 * along:
			return false                                 # a defender covers the lane
	return true


# is the keeper clearly the first of all the players to a point?
func _gk_first(p, pt):
	var kt = p.position.distance_to(pt) / GK_DIVE_SPEED
	for q in players:
		if q == p or q.is_gk:
			continue
		if q.position.distance_to(pt) / (AI_SPEED * 1.05) < kt + 0.12:
			return false
	return true


func _gk_update_shot(team, delta):
	var goal_c = _own_goal(team)
	var v = ball.vel
	var sgn = _dir_of(team)
	var threat = false
	var proj_y = 0.0
	var own_touch = last_touch != null and is_instance_valid(last_touch) and last_touch.team == team
	if v.length() > 320.0 and v.x * sgn < -100.0 and not own_touch:
		var dx = abs(ball.position.x - goal_c.x)
		if dx < 700.0 and dx * _ball_k() < abs(v.x) * 0.95:
			proj_y = ball.position.y + v.y / abs(v.x) * dx
			threat = abs(proj_y - goal_c.y) < GOAL_H / 2.0 + 25.0
	if not threat:
		gk_shot_seen[team] = false
		gk_react[team] = 0.0
		return
	if not gk_shot_seen[team]:
		gk_shot_seen[team] = true
		gk_react[team] = 0.08
		gk_read_y[team] = proj_y + rand_range(-18.0, 18.0)
	else:
		gk_react[team] = max(0.0, gk_react[team] - delta)


func _gk_target(p):
	var team = p.team
	var goal_c = _own_goal(team)
	var dirx = _dir_of(team)
	var to_ball = ball.position - goal_c
	var dist = to_ball.length()
	var tgt = Vector2(goal_c.x + dirx * 24.0, goal_c.y)
	if dist > 1.0:
		tgt = goal_c + to_ball.normalized() * (24.0 + clamp(dist * 0.12, 0.0, 46.0))
	var half = GOAL_H / 2.0 - 8.0
	tgt.y = clamp(tgt.y, goal_c.y - half, goal_c.y + half)
	if gk_shot_seen[team] and gk_react[team] <= 0.0:
		tgt = Vector2(goal_c.x + dirx * 20.0, clamp(gk_read_y[team], goal_c.y - half, goal_c.y + half))
	return _inside(tgt)


func _gk_reach(p):
	var team = p.team
	if gk_cd[team] > 0.0 or state != "playing":
		return
	if p.position.distance_to(ball.position) > GK_RADIUS + BR + 18.0 + (14.0 if p.is_diving else 0.0):
		return
	if ball.height_z > 75.0 and not p.is_diving:
		return                                       # over his head
	if dribble_owner != null and is_instance_valid(dribble_owner) and dribble_owner.team == team:
		return   
	var spd = ball.vel.length()
	var dirx = _dir_of(team)
	# a ball a team-mate has just kicked or thrown to him: he may not pick it up (he has to play it with his feet)
	var may_handle = rules == null or rules.gk_may_handle(p)
	if _in_own_box(team, ball.position) and may_handle:
		var feet = dribble_owner
		if feet != null and is_instance_valid(feet) and feet.team != team:
			# he goes in at the attacker's feet: that is a contest, not a free pick-up
			var roll = randf()
			gk_cd[team] = 0.9
			if roll >= 0.55:
				if roll < 0.80:
					var knock = (ball.position - p.position).normalized().rotated(rand_range(-0.9, 0.9))
					dribble_owner = null
					ball.vel = knock * rand_range(160.0, 260.0)           # he gets a touch and it squirts loose
					feet.kick_cd = max(feet.kick_cd, 0.4)
					last_touch = p
				return                                                  # (or the attacker takes it round him)
			gk_cd[team] = 0.0
		var oc = {"kind": "catch"}
		if scramble != null:
			oc = scramble.gk_outcome(p, spd)           # catch / parry wide / spill in front / tip round the post
		if oc["kind"] == "catch":
			gk_hold_timer[team] = GK_HOLD_TIME
			gk_wait[team] = 0.0
			gk_dive_t[team] = 0.0
			dribble_owner = null
			ball.vel = Vector2.ZERO
			ball.height_z = 0.0
			ball.vel_z = 0.0
			last_touch = p
			pass_t = 0.0
			pass_target = null
			gk_shot_seen[team] = false
			if team == 0 or Game.two_player:
				# a save: the human takes over the keeper to choose where it goes (six seconds, then the game plays it)
				gk_human[team] = true
				gk_hold_timer[team] = GK_HUMAN_HOLD
				_set_selected(team, p)
		else:
			var away = oc["dir"]
			ball.position = p.position + away * (GK_RADIUS + BR + 3.0)
			ball.vel = away * oc["speed"]
			ball.impulse_z(oc["lift"])
			ball_ghost_t = 0.15
			gk_cd[team] = 0.35
			last_touch = p
			pass_t = 0.0
			pass_target = null
			gk_shot_seen[team] = false
			if scramble != null:
				scramble.note_parry(p)                   # the rebound is on
	elif dribble_owner == null and spd < TRAP_SPEED and ball.height_z < 30.0:
		_gk_distribute(p)


func _gk_distribute(p, may_wait = false):
	var team = p.team
	var st = profiles[team]["style"]
	var dirx = _dir_of(team)
	var best = null
	var best_s = -1e9
	for q in players:
		if q.team != team or q.is_gk:
			continue
		var d = q.position.distance_to(ball.position)
		if d < 100.0 or d > 760.0:
			continue
		var lane = _pass_lane_risk(p, q)
		var rp = 0.0
		for opp in players:
			if opp.team != team:
				var od = opp.position.distance_to(q.position)
				if od < 70.0:
					rp += (70.0 - od) * 0.4
		var fwd = (q.position.x - p.position.x) * dirx
		var want = lerp(280.0, 560.0, st["directness"])
		var s = 30.0 - lane * 1.3 - rp * 1.3 + fwd * (0.01 + 0.03 * st["directness"]) - abs(d - want) * 0.03
		if s > best_s:
			best_s = s
			best = q
	if may_wait and (best == null or best_s < 14.0) and gk_wait[team] < 1.5:
		gk_wait[team] += 0.35
		gk_hold_timer[team] = 0.35
		return
	p.kick_cd = 0.0
	var done = false
	if best != null and best_s >= 14.0:
		done = _pass_to(p, best, 0.25, 0.0, 0.0)
		if ui_controller:
			ui_controller.record_pass(team)
	else:
		var cy = PITCH.position.y + PITCH.size.y / 2.0
		var aim = Vector2(p.position.x + dirx * 620.0, cy)
		var best_r = 1e9
		for oy in [0.0, -0.30, 0.30]:
			var cand = _inside(Vector2(p.position.x + dirx * 620.0, cy + oy * PITCH.size.y))
			var r = _shot_lane_risk(ball.position, cand, team)
			if r < best_r:
				best_r = r
				aim = cand
		var gk_d = (aim - ball.position).length()
		var gk_lob = kick_system.physics.lob(gk_d, clamp(0.85 + gk_d / 1200.0, 0.85, 1.25))   # same arc maths as every other lofted kick
		done = _try_kick(p, aim - ball.position, gk_lob[0], gk_lob[1])  # High goal-kick distribution
		if ui_controller:
			ui_controller.record_pass(team)
	if done:
		gk_wait[team] = 0.0
		gk_cd[team] = 1.2   
		ball_ghost_t = 0.14


# ------------------------------------------------------------ BALL CONTACT

func _try_kick(p, dir, speed, lift_z = 0.0):
	if p.kick_cd > 0.0 and not p.is_gk:
		return false
	if not p.is_gk and p.position.distance_to(ball.position) > PR + BR + 12.0:
		return false
	if not p.is_gk and (gk_hold_timer[0] > 0.0 or gk_hold_timer[1] > 0.0):
		return false   
	if dir.length() < 0.01:
		return false

	var final_dir = dir.normalized()
	if not p.is_gk and _opponent_near(p, 35.0):
		final_dir = final_dir.rotated(rand_range(-0.07, 0.07))

	_kick_apply(p, final_dir, speed, lift_z, true)
	return true


# the ball leaves the foot: reposition it at his boot, give it speed and lift, hand it over to the game
# (kick_physics.gd calls this at the moment of contact; reset_cd false = the kick animation is already running)
func _kick_apply(p, final_dir, speed, lift_z, reset_cd = true):
	var was_throw = false
	if rules != null and rules.enabled and rules.active:
		if p != rules.taker or rules.phase != "ready":
			return                                 # nobody but the taker plays a dead ball, and not before all is ready
		if rules.kind == "throw_in":
			speed = min(speed, 300.0)              # a throw-in is a throw (adjust_plan adds the animation when kick_system calls it)
			lift_z = max(lift_z, 45.0)
			was_throw = true
			throw_taker = p                          # he is allowed to stay outside the line for a moment while he steps in
			throw_free_t = 0.6
	dribble_owner = null
	if p.is_gk:
		gk_hold_timer[p.team] = 0.0
		gk_human[p.team] = false
	var reach_r = (GK_RADIUS if p.is_gk else PR) + BR + 3.0
	ball.position = p.position + Vector2(final_dir.x * reach_r, final_dir.y * reach_r * (1.0 if final_dir.y > 0.0 else 0.4))
	if was_throw:
		ball.position.y = clamp(ball.position.y, PITCH.position.y + 1.0, PITCH.end.y - 1.0)     # let go over the line, not outside it
	ball.vel = final_dir * min(speed, MAX_BALL_SPEED)
	ball.vel_z= 0.0
	if lift_z > 0.0:
		ball.impulse_z(lift_z)
	ball_ghost_t = 0.10
	if reset_cd:
		p.kick_cd = 0.35
	last_touch = p
	pass_t = 0.0
	pass_target = null
	if not p.is_gk and speed > 150.0 and final_dir.x * _dir_of(p.team) < -0.45:
		TrapAI.note_press_trigger(self, 1 - p.team, "backpass", 2.2)        # a pass back: close him down
	if rules != null:
		rules.on_ball_played(p)                # offside snapshot, double-touch bookkeeping, end of a restart


func _ball_player_contacts():
	if ball_ghost_t > 0.0:
		return

	# Height isolation: Ground players do not touch high airborne balls
	if ball.height_z > 32.0:
		return

	for team in range(2):
		if gk_hold_timer[team] > 0.0:
			var gk = players[team * 11]
			ball.position = gk.position + Vector2(14.0 if team == 0 else -14.0, 0.0)
			ball.vel = Vector2.ZERO
			ball.height_z = 0.0
			ball.vel_z = 0.0
			return

	if dribble_owner != null and is_instance_valid(dribble_owner):
		var owner_dist = dribble_owner.position.distance_to(ball.position)
		if owner_dist <= PR + BR + 22.0 and ball.vel.length() <= 300.0:
			var target_ball_pos = dribble_owner.position + _dribble_offset(dribble_owner)
			ball.position = target_ball_pos
			ball.vel = dribble_owner.vel * 0.12
			ball.height_z = 0.0
			ball.vel_z = 0.0
			return
		dribble_owner = null

	var closest_player = null
	var closest_offset = Vector2.ZERO
	var closest_dist = 1e9
	for p in players:
		var offset = ball.position - p.position
		var dist = offset.length()
		var body_r = GK_RADIUS if p.is_gk else PR
		if dist < body_r + BR and dist < closest_dist:
			closest_dist = dist
			closest_player = p
			closest_offset = offset

	if closest_player == null:
		return

	# two opponents reach a loose ball together: a 50/50, not simply "the closer one" (the scrambles in the box)
	var contest = false
	if scramble != null and contest_cd <= 0.0 and dribble_owner == null and not closest_player.is_gk:
		var cands = [{"p": closest_player, "d": closest_dist}]
		for q in players:
			if q == closest_player or q.is_gk or q.team == closest_player.team:
				continue
			var qd = (ball.position - q.position).length()
			if qd < PR + BR + 8.0:
				cands.append({"p": q, "d": qd})
		if cands.size() > 1:
			var win = scramble.resolve_contest(cands)
			contest = true
			contest_cd = 0.25
			if win != closest_player:
				closest_player = win
				closest_offset = ball.position - win.position
				closest_dist = max(closest_offset.length(), 0.01)
			for c in cands:
				if c["p"] != win:
					c["p"].kick_cd = max(c["p"].kick_cd, 0.30)       # the loser is off balance for a moment

	if rules != null:
		# a keeper bouncing a back-pass he may not handle is not a deliberate play (otherwise he could pick it up next)
		if closest_player.is_gk and not rules.gk_may_handle(closest_player):
			pass
		elif rules.on_touch(closest_player):
			return                                 # offside or a double touch: the referee has stopped play

	# the computer's receivers play it first time; a human's receiver controls it (you decide what happens next)
	if pass_t > 0.0 and pass_target == closest_player and ball.vel.length() > 120.0 and not _is_human_player(closest_player):
		last_touch = closest_player
		pass_t = 0.0
		pass_target = null
		dribble_owner = null
		
		var opp_goal = _attack_goal(closest_player.team)
		var to_goal = opp_goal - closest_player.position
		if to_goal.length() < 450.0 and closest_player.facing.dot(to_goal.normalized()) > 0.2:
			var shot = _evaluate_shot(closest_player, opp_goal)
			if ui_controller:
				ui_controller.record_shot(closest_player.team)
			_try_kick(closest_player, (shot["target"] - ball.position).normalized(), 720.0, 100.0)
		else:
			var redirect_dir = closest_player.facing if closest_player.facing != Vector2.ZERO else ball.vel.normalized()
			if ui_controller:
				ui_controller.record_pass(closest_player.team)
			_try_kick(closest_player, redirect_dir, 480.0, 0.0)
		return

	last_touch = closest_player
	var normal = closest_offset / max(closest_dist, 0.01)
	ball.position = closest_player.position + normal * ((GK_RADIUS if closest_player.is_gk else PR) + BR)
	var pre_vel = ball.vel
	var pre_speed = pre_vel.length()
	_deflect_ball(closest_player, normal)      # off his body in a new direction: a block, a ricochet, a poor touch
	if contest and randf() < 0.6:
		ball.vel += Vector2(1.0, 0.0).rotated(randf() * TAU) * rand_range(80.0, 170.0)    # it squirts out: the scramble goes on

	if closest_player.is_gk:
		return

	var receiving = pass_t > 0.0 and pass_target == closest_player
	var easy = RECEIVER_TRAP_SPEED if receiving else TRAP_SPEED
	if pre_speed > easy * 2.2:
		return                                   # far too hard to bring down: it just comes off him

	# FIRST TOUCH: a gentle pass is killed at once, a hard / bouncing / awkward one is not
	var touch = _first_touch(closest_player, pre_vel, pre_speed, receiving)
	if touch["kind"] == "control":
		ball.vel = pre_vel * 0.1 + closest_player.vel * 0.1
		dribble_owner = closest_player
		ai_decision_timers[_pid(closest_player)] = rand_range(0.15, 0.35)
	elif touch["kind"] == "heavy":
		ball.vel = touch["vel"]                  # he gets a foot to it but it runs on a few yards: he has to get after it
		closest_player.kick_cd = max(closest_player.kick_cd, 0.18)
		TrapAI.note_press_trigger(self, 1 - closest_player.team, "touch", 1.6)     # a heavy touch: pounce
	else:
		closest_player.kick_cd = max(closest_player.kick_cd, 0.30)    # a poor touch: it runs off him and he is off balance
		TrapAI.note_press_trigger(self, 1 - closest_player.team, "touch", 1.6)
	pass_t = 0.0
	pass_target = null


# ------------------------------------------------------------ BALL DEFLECTION, FIRST TOUCH, SHIELDING

# The ball hits a body: the part of its speed that goes INTO him is reflected (a harder ball rebounds more), a little
# is lost sideways, and the exact angle wobbles (the body is not a perfect circle: the wobble grows with pace). A hard
# ball can pop up. So a shot off a defender flies off somewhere new, and a pass off a shin changes direction.
func _deflect_ball(p, normal):
	var vrel = ball.vel - p.vel
	var vn = vrel.dot(normal)
	if vn >= 0.0:
		return
	var speed = vrel.length()
	var e = clamp(0.25 + speed / 2000.0, 0.25, 0.55)
	var out = vrel - normal * vn * (1.0 + e)
	out -= (out - normal * out.dot(normal)) * 0.12
	out = out.rotated(deg2rad(rand_range(-1.0, 1.0) * (5.0 + speed / 70.0)))
	ball.vel = out + p.vel * 0.35
	if speed > 430.0 and randf() < 0.45:
		ball.impulse_z(rand_range(30.0, 90.0))


# How well does he take the ball down? Returns {"kind": "control" / "heavy" / "poor"} (+ "vel" for a heavy touch).
func _first_touch(p, vel, speed, receiving):
	var easy = RECEIVER_TRAP_SPEED if receiving else TRAP_SPEED
	var q = _touch_quality(p, vel, speed, receiving)
	if speed < easy * 0.45 and q > 0.25:
		return {"kind": "control"}                   # a gentle ball: any footballer kills it
	if q >= 0.58:
		return {"kind": "control"}
	if q >= 0.30:
		var heading = p.vel if p.vel.length() > 20.0 else p.facing
		var d = vel.normalized() * 0.6 + (heading.normalized() * 0.4 if heading.length() > 0.01 else Vector2.ZERO)
		d = (d.normalized() if d.length() > 0.01 else Vector2.RIGHT).rotated(rand_range(-0.5, 0.5))
		return {"kind": "heavy", "vel": d * clamp(speed * 0.28, 70.0, 200.0) + p.vel * 0.5}
	return {"kind": "poor"}


# 0..1. Hard passes, bouncing / dropping balls, taking it at full speed, a ball arriving from behind, an opponent
# on his back and a poor technician all make it worse; expecting the ball, a good technician and (a little) you
# being the human make it better.
func _touch_quality(p, vel, speed, receiving):
	var easy = RECEIVER_TRAP_SPEED if receiving else TRAP_SPEED
	var q = 0.85
	q -= clamp((speed - easy * 0.45) / (easy * 1.7), 0.0, 0.65)
	if ball.height_z > 8.0:
		q -= 0.15
	q -= 0.18 * clamp(p.vel.length() / AI_SPEED - 0.6, 0.0, 1.0)
	if speed > 1.0 and p.facing.length() > 0.1:
		q += 0.10 * p.facing.normalized().dot(-vel.normalized())
	var od = _nearest_opp_dist(p.team, p.position)
	if od < 70.0:
		q -= 0.18 * (1.0 - od / 70.0)
	if receiving:
		q += 0.08
	q += _touch_skill(p)
	if _is_human_player(p):
		q += 0.10
	q += rand_range(-0.07, 0.07)
	return clamp(q, 0.0, 1.0)


# technique: the creative players are better on the ball, the defenders less so; every player is a little different
func _touch_skill(p):
	var base = {"AM": 0.14, "WG": 0.14, "ST": 0.10, "CM": 0.10, "DM": 0.05, "FB": 0.04, "CB": 0.0}
	var b = base.get(_role_traits_of(p)["fam"], 0.05)
	var vary = (float(int(abs(hash(str(p.team) + str(int(p.slot))))) % 100) / 100.0 - 0.5) * 0.12
	return b + vary


# Who is shielding the ball? The human holds the shield button; the computer's carrier does it when an opponent is on
# him and he sees nothing good to do (never for long: a second and a half, then he must play it).
func _update_shield(delta):
	for k in shield_rest.keys():
		shield_rest[k] = max(0.0, shield_rest[k] - delta)
	var c = dribble_owner
	shield_p = null
	if c == null or not is_instance_valid(c) or c.is_gk or _dead_ball():
		return
	var opp = null
	var od = 1e9
	for q in players:
		if q.team == c.team or q.is_gk:
			continue
		var d = q.position.distance_to(c.position)
		if d < od:
			od = d
			opp = q
	if opp == null or od > SHIELD_DIST:
		shield_t[_pid(c)] = 0.0
		return
	var pid = _pid(c)
	var want = false
	var human = _is_human_player(c)
	if human:
		want = human_shield[c.team]
	else:
		want = od < 80.0 and shield_hint.get(pid, false) and shield_rest.get(pid, 0.0) <= 0.0
	if want:
		shield_t[pid] = shield_t.get(pid, 0.0) + delta
		if (not human) and shield_t[pid] > 1.5:
			want = false
			shield_t[pid] = 0.0
			shield_rest[pid] = 1.5
	else:
		shield_t[pid] = 0.0
	if want:
		shield_p = c
		shield_away = (c.position - opp.position).normalized()


# ------------------------------------------------------------ CROWD & STADIUM

func _build_crowd():
	var rng = RandomNumberGenerator.new()
	rng.seed = 20261020
	var home_c = Game.team_color(Game.home_id)
	var away_c = Game.team_color(Game.away_id)
	var palette = [Color(0.85, 0.2, 0.2), Color(0.95, 0.85, 0.2), Color(0.2, 0.45, 0.9), Color(0.9, 0.9, 0.9),
		Color(0.2, 0.7, 0.35), Color(0.95, 0.55, 0.15), Color(0.6, 0.3, 0.8), Color(0.15, 0.15, 0.15)]
	var cx = PITCH.position.x + PITCH.size.x / 2.0
	for r in range(4):
		var rect = PITCH.grow(45.0 + r * 14.0)
		var pts = []
		var x = rect.position.x
		while x <= rect.end.x:
			pts.append(Vector2(x, rect.position.y))
			pts.append(Vector2(x, rect.end.y))
			x += 20.0
		var y = rect.position.y + 11.0
		while y < rect.end.y:
			pts.append(Vector2(rect.position.x, y))
			pts.append(Vector2(rect.end.x, y))
			y += 20.0
		for pt in pts:
			crowd_pos.append(pt + Vector2(rng.randf_range(-2.0, 2.0), rng.randf_range(-2.0, 2.0)))
			var roll = rng.randf()
			var c
			if roll < 0.40:
				c = home_c if pt.x < cx else away_c      
			elif roll < 0.55:
				c = away_c if pt.x < cx else home_c
			else:
				c = palette[rng.randi() % palette.size()]
			crowd_col.append(c.darkened(rng.randf_range(0.0, 0.25)))


func _draw_crowd():
	_outline(PITCH.grow(34.0), Color(0.16, 0.16, 0.22), 10.0)   
	var cheer = crowd_t > 0.0
	var tsec = OS.get_ticks_msec() * 0.001
	for i in range(crowd_pos.size()):
		var pt = crowd_pos[i]
		if cheer:
			pt.y -= abs(sin(tsec * 9.0 + pt.x * 0.07 + pt.y * 0.05)) * 5.0
		draw_circle(pt, 3.6, crowd_col[i])


# ------------------------------------------------------------ KEEPER DIVE STEP

func _gk_dive_step(p, team, delta):
	if not gk_shot_seen[team]:
		gk_dived[team] = false
	if gk_shot_seen[team] and gk_react[team] <= 0.0 and not gk_dived[team] and gk_dive_t[team] <= 0.0 \
			and gk_down_t[team] <= 0.0 and gk_hold_timer[team] <= 0.0:
		var dy = gk_read_y[team] - p.position.y
		if abs(dy) >= 12.0:
			gk_dive_dir[team] = Vector2(_dir_of(team) * 0.2, sign(dy)).normalized()
			gk_dive_speed[team] = clamp(abs(dy) / 0.28, 170.0, 380.0)
			gk_dive_t[team] = 0.30
			gk_dived[team] = true
	if gk_dive_t[team] > 0.0:
		gk_dive_t[team] -= delta
		p.vel = gk_dive_dir[team] * gk_dive_speed[team]
		_move(p, delta)
		var cy = PITCH.position.y + PITCH.size.y / 2.0
		p.position.y = clamp(p.position.y, cy - (GOAL_H / 2.0 + 40.0), cy + (GOAL_H / 2.0 + 40.0))
		if gk_dive_t[team] <= 0.0:
			gk_dive_t[team] = 0.0
			gk_down_t[team] = 0.55
			p.vel = Vector2.ZERO
	elif gk_down_t[team] > 0.0:
		gk_down_t[team] = max(0.0, gk_down_t[team] - delta)
		p.vel = Vector2.ZERO
	p.is_diving = gk_dive_t[team] > 0.0 or gk_down_t[team] > 0.0
	p.dive_dir = gk_dive_dir[team]


# ------------------------------------------------------------ DRIBBLE OFFSET

func _dribble_offset(p):
	var f = p.facing
	if f.length() < 0.01:
		f = Vector2.RIGHT
	f = f.normalized()
	var reach = 12.0
	if p == sel[p.team]:
		reach = dribble_len[p.team]       
	var target = Vector2(f.x * reach, f.y * reach if f.y > 0.0 else 0.0)
	if f.y < -0.3:
		var swing = sin(p.walk_phase) * 11.0 if p.vel.length() > 8.0 else 11.0
		target = Vector2(f.x * reach + swing * (-f.y), 2.0 - max(0.0, reach - 15.0) * 2.0)
	if shield_p == p and shield_away.length() > 0.1:
		target = shield_away * (PR + BR + 2.0)        # shielding: his body is between the opponent and the ball
	var pid = _pid(p)
	var cur = ball_off_mem.get(pid, target)
	cur = cur.linear_interpolate(target, 0.35)
	ball_off_mem[pid] = cur
	return cur


func _buildout_target(p, shape):
	var team = p.team
	var dir = _dir_of(team)
	var L = PITCH.size.x
	var cx = PITCH.position.x + L * 0.5
	var cy = PITCH.position.y + PITCH.size.y * 0.5
	var fam = _role_traits_of(p)["fam"]
	var home = p.home_pos
	var adv = 0.15 * L
	if fam == "ST" or fam == "WG" or fam == "CB":
		adv = 0.10 * L
	var t = Vector2(home.x + dir * adv, cy + (home.y - cy) * 1.15)
	if fam == "CB":
		var side = 1.0 if home.y >= cy else -1.0
		t.y = cy + side * PITCH.size.y * 0.22
	if fam != "ST" and fam != "WG":
		t.x = min(t.x, cx + 120.0) if team == 0 else max(t.x, cx - 120.0)   
	return _support_target(p, t)   


func _sprint_update(team, delta, two, touch_on, tc):
	var now = OS.get_ticks_msec() / 1000.0
	var held = false
	if not two:
		held = Input.is_key_pressed(KEY_SHIFT)
	elif team == 0:
		held = Input.is_key_pressed(KEY_Q)
	else:
		held = Input.is_key_pressed(KEY_SLASH)
	if touch_on and tc.get("sprint"):
		held = true

	if held and not sprint_prev[team]:
		if now - sprint_last[team] < 0.35:
			sprint_taps[team] = min(sprint_taps[team] + 1, 3)
		else:
			sprint_taps[team] = 1
		sprint_last[team] = now
		push_level[team] = sprint_taps[team]
		run_until[team] = now + [0.0, 0.6, 1.2, 1.6][sprint_taps[team]]
	sprint_prev[team] = held
	if held:
		run_until[team] = max(run_until[team], now + 0.1)

	var level = 0
	if now < run_until[team]:
		level = max(push_level[team], 1)
	else:
		push_level[team] = 0
	var want = [12.0, 15.0, 22.0, 29.0][level]
	var cur = dribble_len[team]
	if cur < want:
		cur = min(want, cur + 160.0 * delta)
	else:
		cur = max(want, cur - 160.0 * delta)
	dribble_len[team] = cur
	return [1.0, 1.30, 1.36, 1.42][level]


# ------------------------------------------------------------ 2.5D depth

# Players nearer the bottom of the screen are nearer the "camera": draw them in front of the ones behind
# them, and a touch bigger. The ball sits in front of whoever is dribbling it, and above everybody while
# it is high in the air.
func _depth_sort():
	var top = PITCH.position.y
	var span = PITCH.size.y
	for p in players:
		var t = clamp((p.position.y - top) / span, 0.0, 1.0)
		p.z_index = SORT_BASE + int(t * SORT_RANGE)
		var base = GK_SCALE if p.is_gk else 1.0
		var k = base * lerp(PERSP_FAR, PERSP_NEAR, t)
		p.scale = Vector2(k, k)
	if dribble_owner != null and is_instance_valid(dribble_owner):
		ball.z_index = dribble_owner.z_index + 1
	elif ball.height_z > 24.0:
		ball.z_index = SORT_BASE + SORT_RANGE + 2
	else:
		var tb = clamp((ball.position.y - top) / span, 0.0, 1.0)
		ball.z_index = SORT_BASE + int(tb * SORT_RANGE) + 1


func _ball_in_corner():
	var dx = min(ball.position.x - PITCH.position.x, PITCH.end.x - ball.position.x)
	var dy = min(ball.position.y - PITCH.position.y, PITCH.end.y - ball.position.y)
	return dx < CORNER_ZONE and dy < CORNER_ZONE


func _corner_clear_dir():
	var c = PITCH.position + PITCH.size / 2.0
	return (c - ball.position).normalized()


func _update_ball(delta):
	ball_ghost_t = max(0.0, ball_ghost_t - delta)
	ball.vel = ball.vel.clamped(MAX_BALL_SPEED)
	ball.position += ball.vel * delta
	
	if kick_system != null:
		kick_system.physics.apply_curve(delta)     # a bending ball (curlers, crosses)
	var f_rate = clamp(float(active_pitch_data.get("friction", 0.4)), 0.05, 0.98)   # same clamp kick_physics.gd uses
	var air_t = clamp(ball.height_z / AIR_BLEND_H, 0.0, 1.0)
	ball.vel *= pow(f_rate, lerp(1.0, AIR_DRAG, air_t) * delta)   # rolling -> air drag, blended with height
	
	if ball.vel.length() < 4.0:
		ball.vel = Vector2.ZERO
	
	if rules != null and rules.enabled:
		rules.check_ball(delta)                  # the ball leaving the pitch / going into a goal is decided there
		if _dead_ball():
			return
	else:
		_ball_walls_legacy()

	if _ball_in_corner():
		var near = _nearest_to_ball()
		if near.position.distance_to(ball.position) < PR + BR + 12.0:
			ball_stuck_t += delta
			if ball_stuck_t > 0.35:
				ball_stuck_t = 0.0
				ball.vel = _corner_clear_dir() * 320.0
				ball_ghost_t = 0.3
		else:
			ball_stuck_t = 0.0
	else:
		ball_stuck_t = 0.0


# the old behaviour (SET_PIECES = false): the ball bounces off the walls, only the goal mouth lets it out
func _ball_walls_legacy():
	var cy = PITCH.position.y + PITCH.size.y / 2
	var left = PITCH.position.x
	var right = PITCH.end.x
	if ball.position.y < PITCH.position.y + BR:
		ball.position.y = PITCH.position.y + BR
		ball.vel.y = abs(ball.vel.y) * 0.8
	elif ball.position.y > PITCH.end.y - BR:
		ball.position.y = PITCH.end.y - BR
		ball.vel.y = -abs(ball.vel.y) * 0.8
		
	var in_mouth = abs(ball.position.y - cy) < GOAL_H / 2 - 4.0 and ball.height_z <= CROSSBAR_Z   # over the bar = not a goal
	if ball.position.x < left + BR:
		if in_mouth:
			if ball.position.x < left - BR:
				_goal(1)
		else:
			ball.position.x = left + BR
			ball.vel.x = abs(ball.vel.x) * 0.8
	elif ball.position.x > right - BR:
		if in_mouth:
			if ball.position.x > right + BR:
				_goal(0)
		else:
			ball.position.x = right - BR
			ball.vel.x = -abs(ball.vel.x) * 0.8


func _nearest_to_ball():
	var best = players[0]
	var bd = 1e9
	for p in players:
		var d = p.position.distance_to(ball.position)
		if d < bd:
			bd = d
			best = p
	return best


func _ball_carrier_near(p, r):
	for q in players:
		if q.team != p.team and q.position.distance_to(p.position) < r \
				and q.position.distance_to(ball.position) < PR + BR + 12.0:
			return true
	return false


# ------------------------------------------------------------ PENALTY SHOOTOUT

func _start_shootout():
	state = "shootout"
	shootout = PenaltyShootout.new(self)
	add_child(shootout)
	shootout.connect("finished", self, "_on_shootout_done")


func _on_shootout_done(goals):
	state = "over"
	Game.last_home_goals = score[0]
	Game.last_away_goals = score[1]
	Extras.get_it().pens = goals.duplicate()
	Game.goto("res://scenes/Results.tscn")


func refresh_jerseys():
	for p in players:
		var tid = Game.home_id if p.team == 0 else Game.away_id
		p.jersey = Jerseys.get_it().texture_for(tid)
		p.update()
