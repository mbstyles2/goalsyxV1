extends CanvasLayer
# Loading screen with a PES 2016 style pre-match lineup/formation intro.
#
# YOUR PICTURE: save it as  res://art/loading_background.png  (.jpg / .jpeg /
# .webp also work). Cropped to cover the screen, never squashed. Until it
# exists a dark green background is used.
#
# Lives on the scene-tree root like the audio manager. From any script:
#   const LoadingScreen = preload("res://scripts/ui/loading_screen.gd")
#   LoadingScreen.get_it(self).boot()

const UIStyle = preload("res://scripts/ui/ui_style.gd")
const SaveData = preload("res://scripts/save/save_data.gd")
const Jerseys = preload("res://scripts/ui/jerseys.gd")

const SELF_PATH = "res://scripts/ui/loading_screen.gd"
const META_KEY = "loading_screen"

const BG_PATHS = [
	"res://art/loading_background.png",
	"res://art/loading_background.jpg",
	"res://art/loading_background.jpeg",
	"res://art/loading_background.webp",
]
const BG_FALLBACK = Color(0.02, 0.12, 0.06)
const BG_DIM = 0.35

const SCENES_DIR = "res://scenes"
const COVER_SCENES = ["Match.tscn"]   # scenes that get the loading screen
const COVER_SECONDS = 1.2             # shortest time it stays up when entering one
const BOOT_MIN_SECONDS = 1.6          # start-up screen is shown at least this long
const FADE_SECONDS = 0.4

const TIPS = [
	"Press ESC or P at any time to pause.",
	"Press M to mute or unmute the sound.",
	"Switch between plain and design jerseys on the team select screen.",
	"Set Match: the winner stays on - keep winning!",
	"Last Team Standing: the bottom team goes home every round.",
	"Level after extra time? It goes to a penalty shootout.",
]

var want_boot = false
var booted = false
var covering = false
var keep = []                 # strong refs so preloaded scenes stay cached

var root
var title_lbl
var tip_lbl
var bar
var lineup_panel              # PES style container for team breakdown
var home_label
var away_label
var vs_label
var shown = 0.0               # progress bar value shown
var target = 0.0              # progress value we are heading to
var dots_t = 0.0
var base_text = "LOADING"
var tween


static func get_it(from):
	if Engine.has_meta(META_KEY):
		var inst = Engine.get_meta(META_KEY)
		if is_instance_valid(inst):
			return inst
	var n = load(SELF_PATH).new()
	n.name = "LoadingScreen"
	Engine.set_meta(META_KEY, n)
	from.get_tree().root.call_deferred("add_child", n)
	return n


func _init():
	layer = 100
	pause_mode = PAUSE_MODE_PROCESS


func _ready():
	randomize()
	_build()
	root.visible = false
	tween = Tween.new()
	add_child(tween)
	if want_boot:
		_boot_run()


# Call once from the main menu. Does nothing after the first time.
func boot():
	if booted or want_boot:
		return
	want_boot = true
	if root != null:
		_boot_run()


# ------------------------------------------------------------------ building

func _build():
	var bg = Control.new()
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_STOP     # blocks clicks while shown
	add_child(bg)
	root = bg
	var path = ""
	for p in BG_PATHS:
		if ResourceLoader.exists(p):
			path = p
			break
	if path != "":
		var pic = TextureRect.new()
		pic.texture = load(path)
		pic.expand = true
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_fill(pic)
		bg.add_child(pic)
	else:
		var base = ColorRect.new()
		base.color = BG_FALLBACK
		_fill(base)
		bg.add_child(base)
		
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, BG_DIM)
	_fill(dim)
	bg.add_child(dim)

	# text + bar are laid out in the game's 480x270 space, drawn at 2x
	var ui = Control.new()
	ui.rect_scale = Vector2(2, 2)
	ui.theme = UIStyle.make_theme()
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(ui)

	title_lbl = Label.new()
	title_lbl.text = base_text
	title_lbl.align = Label.ALIGN_CENTER
	title_lbl.rect_min_size = Vector2(480, 0)
	title_lbl.rect_position = Vector2(0, 30)
	title_lbl.add_color_override("font_color", UIStyle.GOLD)
	ui.add_child(title_lbl)

	# --- PES STYLE MATCH PREVIEW / LINEUP PANEL (Hidden during standard loading) ---
	lineup_panel = Control.new()
	lineup_panel.rect_position = Vector2(0, 60)
	lineup_panel.rect_min_size = Vector2(480, 150)
	lineup_panel.visible = false
	ui.add_child(lineup_panel)

	# Home Team Block
	home_label = Label.new()
	home_label.align = Label.ALIGN_CENTER
	home_label.rect_min_size = Vector2(200, 100)
	home_label.rect_position = Vector2(20, 20)
	lineup_panel.add_child(home_label)

	# VS Badge / Center Block
	vs_label = Label.new()
	vs_label.text = "- VS -"
	vs_label.align = Label.ALIGN_CENTER
	vs_label.rect_min_size = Vector2(80, 100)
	vs_label.rect_position = Vector2(200, 50)
	vs_label.add_color_override("font_color", UIStyle.GOLD)
	lineup_panel.add_child(vs_label)

	# Away Team Block
	away_label = Label.new()
	away_label.align = Label.ALIGN_CENTER
	away_label.rect_min_size = Vector2(200, 100)
	away_label.rect_position = Vector2(260, 20)
	lineup_panel.add_child(away_label)

	bar = ProgressBar.new()
	bar.max_value = 1.0
	bar.step = 0.001
	bar.percent_visible = false
	bar.rect_position = Vector2(90, 214)
	bar.rect_min_size = Vector2(300, 10)
	var bg_sb = StyleBoxFlat.new()
	bg_sb.bg_color = Color(0, 0, 0, 0.55)
	bg_sb.set_corner_radius_all(5)
	var fg_sb = StyleBoxFlat.new()
	fg_sb.bg_color = UIStyle.GREEN_HOVER
	fg_sb.set_corner_radius_all(5)
	bar.add_stylebox_override("bg", bg_sb)
	bar.add_stylebox_override("fg", fg_sb)
	ui.add_child(bar)

	tip_lbl = Label.new()
	tip_lbl.align = Label.ALIGN_CENTER
	tip_lbl.rect_min_size = Vector2(480, 0)
	tip_lbl.rect_position = Vector2(0, 236)
	ui.add_child(tip_lbl)


func _fill(c):
	c.anchor_right = 1.0
	c.anchor_bottom = 1.0
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE


# ----------------------------------------------------------------- showing

func _show(text, with_tip = true):
	base_text = text
	title_lbl.text = text
	tip_lbl.text = TIPS[randi() % TIPS.size()] if with_tip else ""
	shown = 0.0
	target = 0.0
	bar.value = 0.0
	bar.visible = true
	lineup_panel.visible = false
	tween.stop_all()
	root.modulate = Color(1, 1, 1, 1)
	root.visible = true


func _fade_out():
	tween.stop_all()
	tween.interpolate_property(root, "modulate", Color(1, 1, 1, 1), Color(1, 1, 1, 0),
			FADE_SECONDS, Tween.TRANS_QUAD, Tween.EASE_OUT)
	tween.start()
	yield(get_tree().create_timer(FADE_SECONDS, true), "timeout")
	root.visible = false


func _process(delta):
	# animate the dots and ease the bar toward its target
	if root.visible and bar.visible:
		dots_t += delta
		title_lbl.text = base_text + "...".substr(0, int(dots_t * 2.5) % 4)
		shown = lerp(shown, target, clamp(delta * 8.0, 0.0, 1.0))
		bar.value = shown


# ------------------------------------------------------- entering a scene

# True for scenes that should be loaded behind the loading screen.
func wants(path):
	for sc in COVER_SCENES:
		if path.ends_with(sc):
			return true
	return false


# Called by Game.goto(): load `path` behind the loading screen, then switch to it.
# Optional parameters added for PES-style match presentation (home/away names & formations)
func go(path, home_team = "", away_team = "", home_form = "4-4-2", away_form = "4-3-3"):
	if covering:
		return
	covering = true
	get_tree().paused = true       # nothing happens underneath while it is shown
	_show("LOADING MATCH")
	var t0 = OS.get_ticks_msec()
	var loader = ResourceLoader.load_interactive(path)
	var packed = null
	var loaded = loader == null
	var real = 0.0
	while true:
		if not loaded:
			var err = loader.poll()
			if err == ERR_FILE_EOF:
				packed = loader.get_resource()
				loaded = true
				real = 1.0
			elif err != OK:
				loaded = true
				real = 1.0
			else:
				real = float(loader.get_stage()) / max(1, loader.get_stage_count())
		var timed = clamp((OS.get_ticks_msec() - t0) / 1000.0 / COVER_SECONDS, 0.0, 1.0)
		target = min(real if not loaded else 1.0, timed)
		yield(get_tree(), "idle_frame")
		if loaded and timed >= 1.0:
			break
			
	target = 1.0
	
	# --- PES 2016 STYLE MATCH INTRO SEQUENCE ---
	bar.visible = false
	tip_lbl.text = ""
	
	if home_team != "" and away_team != "":
		title_lbl.text = "MATCHDAY PREVIEW"
		
		# Format clean PES-style team blocks
		home_label.text = "%s\n\nFormation\n[ %s ]" % [home_team.to_upper(), home_form]
		away_label.text = "%s\n\nFormation\n[ %s ]" % [away_team.to_upper(), away_form]
		
		lineup_panel.visible = true
		
		# Cinematic delay / wait for player input to experience the presentation screen
		var intro_time = 0.0
		while intro_time < 3.5:
			intro_time += get_process_delta_time()
			# Allow player to skip intro screen early with Jump/Action key or Click
			if Input.is_action_pressed("ui_accept") or Input.is_mouse_button_pressed(BUTTON_LEFT):
				break
			yield(get_tree(), "idle_frame")
	else:
		# Brief pause fallback if no names were provided
		yield(get_tree().create_timer(0.8, true), "timeout")

	# --- SWAP SCENE ---
	if packed != null:
		get_tree().change_scene_to(packed)
	else:
		get_tree().change_scene(path)
		
	yield(get_tree(), "idle_frame")   # let the new scene run its _ready()
	yield(get_tree(), "idle_frame")
	
	lineup_panel.visible = false
	_fade_out()
	yield(get_tree().create_timer(FADE_SECONDS * 0.6, true), "timeout")
	covering = false
	get_tree().paused = false


# ---------------------------------------------------------------- start-up

func _scene_paths():
	var out = []
	var d = Directory.new()
	if d.open(SCENES_DIR) != OK:
		return out
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		if not d.current_is_dir():
			var n = f
			if n.ends_with(".remap"):
				n = n.substr(0, n.length() - 6)
			if n.ends_with(".tscn") or n.ends_with(".scn"):
				if not out.has(SCENES_DIR + "/" + n):
					out.append(SCENES_DIR + "/" + n)
		f = d.get_next()
	d.list_dir_end()
	return out


func _boot_run():
	want_boot = false
	covering = true
	get_tree().paused = true
	_show("LOADING")
	var started = OS.get_ticks_msec()
	var jobs = _scene_paths()
	var total = jobs.size() + 2
	var done = 0
	# prime the shared modules (fonts, save file, jersey pictures)
	yield(get_tree(), "idle_frame")
	SaveData.get_it()
	UIStyle.make_font(UIStyle.FONT_SIZE)
	done += 1
	target = float(done) / total
	yield(get_tree(), "idle_frame")
	Jerseys.get_it()
	done += 1
	target = float(done) / total
	# preload scenes with real progress
	for path in jobs:
		var loader = ResourceLoader.load_interactive(path)
		if loader != null:
			while true:
				var err = loader.poll()
				var stages = max(1, loader.get_stage_count())
				target = (done + float(loader.get_stage()) / stages) / total
				yield(get_tree(), "idle_frame")
				if err == ERR_FILE_EOF:
					keep.append(loader.get_resource())
					break
				if err != OK:
					break
		done += 1
		target = float(done) / total
	# keep the screen up long enough to be seen
	target = 1.0
	while (OS.get_ticks_msec() - started) / 1000.0 < BOOT_MIN_SECONDS or shown < 0.99:
		yield(get_tree(), "idle_frame")
	booted = true
	_fade_out()
	yield(get_tree().create_timer(FADE_SECONDS * 0.6, true), "timeout")
	covering = false
	get_tree().paused = false
