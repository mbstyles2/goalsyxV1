extends Reference
# Shared look for the menu screens: a background picture + green buttons.
#
# YOUR BACKGROUND PICTURE: put one image at any of these paths (first one found
# is used, in this order):
#
#   res://art/menu_background.png
#   res://art/menu_background.jpg
#   res://art/menu_background.jpeg
#   res://art/menu_background.webp
#
# It is stretched to cover the whole screen (cropped, never squashed). If no
# picture exists yet, a dark green background is used instead.
#
# YOUR FONT: drop it in res://assets/fonts/ . The file whose name contains
# FONT_PREFERRED (batmfa) is used, otherwise the first font found there. It is
# applied to every menu, the pause menu and the new scoreboard.
# Everything is drawn at 2x scale, so FONT_SIZE is in "half pixels": try 8-16.
# (Alternative with no code: Project Settings > GUI > Theme > Custom Font.)
#
# Use from any menu script (first lines of _ready):
#   const UIStyle = preload("res://scripts/ui/ui_style.gd")
#   UIStyle.apply(self)
# For a pop-up that is not a menu scene (e.g. the pause menu) use only:
#   some_control.theme = UIStyle.make_theme()

const BG_PATHS = [
	"res://art/menu_background.png",
	"res://art/menu_background.jpg",
	"res://art/menu_background.jpeg",
	"res://art/menu_background.webp",
]
const FONT_DIR = "res://assets/fonts"
const FONT_PREFERRED = "batmfa"
const FONT_EXTS = ["ttf", "otf", "woff", "fff", "tres"]
const FONT_SIZE = 12           # normal text
const SCORE_FONT_SIZE = 18     # scoreboard numbers
const FONT_FILTER = true       # set false for crisp pixel-art fonts

const BG_FALLBACK = Color(0.05, 0.22, 0.12)
const BG_DIM = 0.35            # 0 = picture as-is, 1 = black. Keeps text readable.

const GREEN = Color(0.13, 0.60, 0.25)
const GREEN_HOVER = Color(0.20, 0.72, 0.33)
const GREEN_PRESSED = Color(0.08, 0.42, 0.17)
const GREEN_DISABLED = Color(0.20, 0.30, 0.22, 0.75)
const GOLD = Color(1.0, 0.86, 0.20)


# Theme + background for a menu scene's root node.
static func apply(node):
	node.theme = make_theme()
	_add_background(node)


static func make_theme():
	var t = Theme.new()
	var f = make_font(FONT_SIZE)
	if f != null:
		t.default_font = f
	t.set_stylebox("normal", "Button", _box(GREEN))
	t.set_stylebox("hover", "Button", _box(GREEN_HOVER))
	t.set_stylebox("pressed", "Button", _box(GREEN_PRESSED, GOLD, 2))
	t.set_stylebox("disabled", "Button", _box(GREEN_DISABLED))
	t.set_stylebox("focus", "Button", _focus_box())
	for c in ["font_color", "font_color_hover", "font_color_pressed", "font_color_focus"]:
		t.set_color(c, "Button", Color.white)
	t.set_color("font_color_disabled", "Button", Color(1, 1, 1, 0.45))
	# white text with a soft shadow so it reads on top of any picture
	t.set_color("font_color", "Label", Color.white)
	t.set_color("font_color_shadow", "Label", Color(0, 0, 0, 0.85))
	t.set_constant("shadow_offset_x", "Label", 1)
	t.set_constant("shadow_offset_y", "Label", 1)
	return t


# Your custom font at the given size, or null if no font file exists yet
# (then Godot's normal font is used).
static func make_font(size):
	var res = _font_res()
	if res == null:
		return null
	if res is DynamicFontData:
		var f = DynamicFont.new()
		f.font_data = res
		f.size = size
		f.use_filter = FONT_FILTER
		return f
	if res is DynamicFont:
		var d = res.duplicate()
		d.size = size
		return d
	return null


# Finds the font file once (cached for the whole run).
static func _font_res():
	if Engine.has_meta("ui_font_cache"):
		return Engine.get_meta("ui_font_cache").res
	var cache = {"res": null}
	Engine.set_meta("ui_font_cache", cache)
	var d = Directory.new()
	if d.open(FONT_DIR) != OK:
		return null
	var names = []
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		if not d.current_is_dir():
			var n = f
			if n.ends_with(".import"):
				n = n.substr(0, n.length() - 7)
			if FONT_EXTS.has(n.get_extension().to_lower()) and not names.has(n):
				names.append(n)
		f = d.get_next()
	d.list_dir_end()
	names.sort()
	var pick = ""
	for n in names:
		if n.to_lower().find(FONT_PREFERRED) != -1:
			pick = n
			break
	if pick == "" and names.size() > 0:
		pick = names[0]
	if pick != "":
		var path = FONT_DIR + "/" + pick
		var res = null
		if ResourceLoader.exists(path):
			res = load(path)
		if res == null:
			# not an imported extension (e.g. .fff): let FreeType read the file directly
			var fd = DynamicFontData.new()
			fd.font_path = path
			res = fd
		cache.res = res
		print("UIStyle: using font ", path)
	return cache.res


static func _box(color, border_color = Color.white, border = 0):
	var s = StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(4)
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 3
	s.content_margin_bottom = 3
	if border > 0:
		s.border_color = border_color
		s.set_border_width_all(border)
	return s


static func _focus_box():
	var s = StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = Color(1, 1, 1, 0.9)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	return s


# Drawn on a CanvasLayer far behind everything, sized to the whole window.
static func _add_background(node):
	var layer = CanvasLayer.new()
	layer.layer = -10
	node.add_child(layer)
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
		layer.add_child(pic)
	else:
		var base = ColorRect.new()
		base.color = BG_FALLBACK
		_fill(base)
		layer.add_child(base)
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, BG_DIM)
	_fill(dim)
	layer.add_child(dim)


static func _fill(c):
	c.anchor_right = 1.0
	c.anchor_bottom = 1.0
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
