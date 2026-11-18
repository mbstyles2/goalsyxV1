extends CanvasLayer
# Pause menu for the match scene. ESC or P opens it; ESC / P / Resume closes it.
#
# Created by match.gd:  add_child(PauseMenu.new(self))
#
# Works by pausing the whole scene tree (this node and the audio manager keep
# running). Resuming waits until ESC / P are released, so the match's own
# "ESC = quit to menu" check can never fire from the key that closed the menu.

const GameAudio = preload("res://scripts/audio/game_audio.gd")
const SaveData = preload("res://scripts/save/save_data.gd")
const UIStyle = preload("res://scripts/ui/ui_style.gd")
const LoadingScreen = preload("res://scripts/ui/loading_screen.gd")
const Jerseys = preload("res://scripts/ui/jerseys.gd")

var match_node
var is_open = false
var resume_pending = false
var root
var sound_btn
var jersey_btn
var camera_btn


func _init(m = null):
	match_node = m
	layer = 20
	pause_mode = PAUSE_MODE_PROCESS


func _ready():
	root = Control.new()
	root.rect_scale = Vector2(2, 2)
	root.theme = UIStyle.make_theme()
	root.visible = false
	add_child(root)

	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.rect_min_size = Vector2(480, 270)
	root.add_child(dim)

	var title = Label.new()
	title.text = "PAUSED"
	title.align = Label.ALIGN_CENTER
	title.rect_min_size = Vector2(480, 0)
	title.rect_position = Vector2(0, 24)
	root.add_child(title)

	var box = VBoxContainer.new()
	box.rect_position = Vector2(130, 52)
	box.rect_min_size = Vector2(220, 0)
	root.add_child(box)

	var ga = GameAudio.get_it(self)
	_button(box, "Resume", "_on_resume")
	if Game.mode == Game.Mode.EXHIBITION:
		_button(box, "Restart match", "_on_restart")
	_slider_row(box, "Music", ga.music_scale, "_on_music_volume")
	_slider_row(box, "Effects", ga.sfx_scale, "_on_sfx_volume")
	var row = HBoxContainer.new()
	box.add_child(row)
	sound_btn = _button(row, "", "_on_sound")
	sound_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jersey_btn = _button(row, "", "_on_jersey")
	jersey_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_refresh_sound()
	_refresh_jersey()
	_button(box, "Quit to main menu", "_on_quit")

	
	
	# --- ADD CAMERA BUTTON HERE ---
	camera_btn = _button(box, "", "_on_camera")
	
	_refresh_sound()
	_refresh_jersey()
	_refresh_camera()
	
	_button(box, "Quit to main menu", "_on_quit")

	var hint = Label.new()
	hint.text = "ESC or P to resume"
	hint.align = Label.ALIGN_CENTER
	hint.rect_min_size = Vector2(480, 0)
	hint.rect_position = Vector2(0, 248)
	root.add_child(hint)

func _on_camera():
	if match_node != null and match_node.camera_controller != null:
		match_node.camera_controller.cycle_mode()
		_refresh_camera()

func _refresh_camera():
	if camera_btn != null and match_node != null and match_node.camera_controller != null:
		camera_btn.text = "Camera: " + match_node.camera_controller.get_mode_name()
		
func _button(parent, text, method):
	var b = Button.new()
	b.text = text
	b.connect("pressed", self, method)
	parent.add_child(b)
	return b


func _slider_row(parent, text, value, method):
	var row = HBoxContainer.new()
	var l = Label.new()
	l.text = text
	l.rect_min_size = Vector2(60, 0)
	row.add_child(l)
	var s = HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.1
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.rect_min_size = Vector2(110, 0)
	s.connect("value_changed", self, method)
	row.add_child(s)
	parent.add_child(row)


func _input(event):
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.scancode != KEY_ESCAPE and event.scancode != KEY_P:
		return
	get_tree().set_input_as_handled()
	if is_open:
		resume_pending = true
	elif match_node != null and match_node.state != "over" and not LoadingScreen.get_it(self).covering:
		_open()


func _process(_delta):
	if is_open and resume_pending:
		if not Input.is_key_pressed(KEY_ESCAPE) and not Input.is_key_pressed(KEY_P):
			_close()


func _open():
	is_open = true
	resume_pending = false
	root.visible = true
	get_tree().paused = true
	GameAudio.get_it(self).set_match_paused(true)


func _close():
	is_open = false
	resume_pending = false
	root.visible = false
	get_tree().paused = false
	GameAudio.get_it(self).set_match_paused(false)
	SaveData.get_it().save()


func _leave():
	# marking the match "over" also stops its ESC check from firing again
	match_node.state = "over"
	is_open = false
	get_tree().paused = false
	GameAudio.get_it(self).set_match_paused(false)
	SaveData.get_it().save()


func _label(parent, y):
	var l = Label.new()
	l.align = Label.ALIGN_CENTER
	l.rect_min_size = Vector2(480, 0)
	l.rect_position = Vector2(0, y)
	
	# Add your custom font here:
	var custom_font = DynamicFont.new()
	custom_font.font_data = load("res://assets/fonts/batmfa.ttf") 
	custom_font.size = 18
	l.add_font_override("font", custom_font)
	
	parent.add_child(l)
	return l

func _on_resume():
	resume_pending = true


func _on_restart():
	_leave()
	get_tree().reload_current_scene()


func _on_quit():
	_leave()
	Game.goto("res://scenes/MainMenu.tscn")


func _on_music_volume(v):
	GameAudio.get_it(self).set_music_volume(v)


func _on_sfx_volume(v):
	GameAudio.get_it(self).set_sfx_volume(v)


func _on_sound():
	GameAudio.get_it(self).toggle_mute()
	_refresh_sound()


func _on_jersey():
	Jerseys.get_it().toggle()
	match_node.refresh_jerseys()
	_refresh_jersey()


func _refresh_jersey():
	var jz = Jerseys.get_it()
	jersey_btn.visible = jz.designs_available()
	jersey_btn.text = "Jersey: Design" if jz.enabled() else "Jersey: Plain"


func _refresh_sound():
	sound_btn.text = "Sound: OFF" if AudioServer.is_bus_mute(0) else "Sound: ON"
