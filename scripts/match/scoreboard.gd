extends CanvasLayer
# AFCON-style scoreboard overlay for the match scene.
#
#   [chip] NGA [1][0] SEN [chip]  [ 12:34 ]      <- dark bar, top-left
#   [chip] NGA  O O X - -  (2)                   <- penalty rows (shootouts only)
#   +-----------------+
#   |      GOAL!      |  green banner for GOAL! / SAVED! / "<team> WINS!" ...
#   |     NIGERIA     |
#   +-----------------+
#
# Created by match.gd (_build_hud). It reads the match's existing values
# (score, lbl_time, lbl_msg, so_marks ...) and hides the plain labels that
# match.gd keeps as data carriers. Font = the one found by ui_style.gd (assets/fonts).

const UIStyle = preload("res://scripts/ui/ui_style.gd")
const Jerseys = preload("res://scripts/ui/jerseys.gd")

# Force a 3-letter code:  "Team Name": "NGA". Otherwise the first 3 letters are used.
const CODES = {
}

const BAR_DARK = Color(0.08, 0.08, 0.12, 0.92)       # same dark panel as before
const BANNER_GREEN = Color(0.12, 0.55, 0.28, 0.94)   # greenish announcement banner
const STRIP_DARK = Color(0.08, 0.08, 0.12, 0.90)
const WHITE_BOX = Color(0.96, 0.98, 0.96)
const TEXT_DARK = Color(0.02, 0.22, 0.09)
const GOLD = Color(1.0, 0.82, 0.15)
const ORANGE = Color(1.0, 0.55, 0.10)
const SILVER = Color(0.88, 0.90, 0.95)

var match_node
var root
var norm_font
var big_font
var small_font

var home_id = 0
var away_id = 0
var home_score
var away_score
var time_lbl
var time_sb
var chips = []              # [[ColorRect, TextureRect], [ColorRect, TextureRect], ...] bar chips
var pen_chips = []
var pen_rows = []
var pen_lbls = []
var banner
var banner_main
var banner_sub
var banner_text = ""
var banner_t = 1.0
var strip
var strip_lbl
var old_hidden = false
var chips_init = false
var chips_enabled = false


func _init(m = null):
	match_node = m
	layer = 5
	pause_mode = PAUSE_MODE_PROCESS


func _ready():
	home_id = Game.home_id
	away_id = Game.away_id
	norm_font = UIStyle.make_font(UIStyle.FONT_SIZE)
	big_font = UIStyle.make_font(UIStyle.SCORE_FONT_SIZE)
	small_font = UIStyle.make_font(max(8, UIStyle.FONT_SIZE - 4))
	root = Control.new()
	root.rect_scale = Vector2(2, 2)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_bar()
	_build_pen_rows()
	_build_banner()
	_build_strip()


# ----------------------------------------------------------------- building

func _panel(parent, x, y, w, h, fill, border = Color(0, 0, 0, 0), bw = 0, radius = 4):
	var p = Panel.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(radius)
	if bw > 0:
		sb.border_color = border
		sb.set_border_width_all(bw)
	p.add_stylebox_override("panel", sb)
	p.rect_position = Vector2(x, y)
	p.rect_size = Vector2(w, h)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(p)
	return p


func _label(parent, x, y, w, h, align, font, color):
	var l = Label.new()
	l.rect_position = Vector2(x, y)
	l.rect_size = Vector2(w, h)
	l.align = align
	l.valign = Label.VALIGN_CENTER
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		l.add_font_override("font", font)
	l.add_color_override("font_color", color)
	l.add_color_override("font_color_shadow", Color(0, 0, 0, 0))
	parent.add_child(l)
	return l


func _chip(parent, x, y, size):
	var c = ColorRect.new()
	c.rect_position = Vector2(x, y)
	c.rect_size = Vector2(size, size)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(c)
	var pic = TextureRect.new()
	pic.expand = true
	pic.stretch_mode = TextureRect.STRETCH_SCALE
	pic.anchor_right = 1.0
	pic.anchor_bottom = 1.0
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pic.visible = false
	c.add_child(pic)
	return [c, pic]


func _code(id):
	var n = Game.team_name(id)
	if CODES.has(n):
		return CODES[n]
	var first = n.strip_edges().split(" ")[0]
	return first.substr(0, 3).to_upper()


func _build_bar():
	_panel(root, 6, 5, 300, 26, BAR_DARK, GOLD, 1, 5)
	chips.append(_chip(root, 11, 12, 12))
	_label(root, 27, 5, 42, 26, Label.ALIGN_LEFT, norm_font, Color.white).text = _code(home_id)
	_panel(root, 70, 8, 26, 20, WHITE_BOX, Color(0, 0, 0, 0), 0, 3)
	home_score = _label(root, 70, 8, 26, 20, Label.ALIGN_CENTER, big_font, TEXT_DARK)
	_panel(root, 99, 8, 26, 20, WHITE_BOX, Color(0, 0, 0, 0), 0, 3)
	away_score = _label(root, 99, 8, 26, 20, Label.ALIGN_CENTER, big_font, TEXT_DARK)
	_label(root, 129, 5, 42, 26, Label.ALIGN_LEFT, norm_font, Color.white).text = _code(away_id)
	chips.append(_chip(root, 171, 12, 12))
	var tb = _panel(root, 188, 8, 112, 20, GOLD, Color(0, 0, 0, 0), 0, 3)
	time_sb = tb.get_stylebox("panel")
	time_lbl = _label(root, 188, 8, 112, 20, Label.ALIGN_CENTER, small_font, TEXT_DARK)
	home_score.text = "0"
	away_score.text = "0"


func _build_pen_rows():
	for i in range(2):
		var y = 35 + i * 17
		var row = _panel(root, 6, y, 190, 15, STRIP_DARK, Color(0, 0, 0, 0), 0, 3)
		row.visible = false
		pen_rows.append(row)
		pen_chips.append(_chip(row, 4, 2, 11))
		var l = _label(row, 19, 0, 168, 15, Label.ALIGN_LEFT, small_font, Color.white)
		pen_lbls.append(l)


func _build_banner():
	banner = _panel(root, 0, 96, 200, 46, BANNER_GREEN, GOLD, 2, 6)
	banner.visible = false
	banner_main = _label(banner, 0, 3, 200, 24, Label.ALIGN_CENTER, big_font, Color.white)
	banner_sub = _label(banner, 0, 27, 200, 15, Label.ALIGN_CENTER, norm_font, GOLD)


func _build_strip():
	strip = _panel(root, 20, 240, 440, 22, STRIP_DARK, GOLD, 1, 4)
	strip.visible = false
	strip_lbl = _label(strip, 0, 0, 440, 22, Label.ALIGN_CENTER, norm_font, Color.white)


# ------------------------------------------------------------------ updating

func _process(delta):
	var m = match_node
	if m == null or not is_instance_valid(m):
		return
	_hide_old(m)
	var sc = m.get("score")
	if sc != null:
		_set_text(home_score, str(sc[0]))
		_set_text(away_score, str(sc[1]))
	var lt = m.get("lbl_time")
	if lt != null:
		_update_time(lt.text)
	_update_chips()
	_update_pens(m)
	_update_banner(m, delta)
	_update_strip(m)


func _set_text(l, t):
	if l.text != t:
		l.text = t


# Hide the original plain labels / swatches (and the shootout ones when they appear).
func _hide_old(m):
	var ls = m.get("lbl_score")
	if ls != null and not old_hidden:
		ls.visible = false
		var lt = m.get("lbl_time")
		if lt != null:
			lt.visible = false
		var lm = m.get("lbl_msg")
		if lm != null:
			lm.visible = false
		for c in ls.get_parent().get_children():
			if c is ColorRect:
				c.visible = false
		old_hidden = true
	var lp = m.get("lbl_pens")
	if lp != null and lp.visible:
		lp.visible = false
	var lq = m.get("lbl_prompt")
	if lq != null and lq.visible:
		lq.visible = false


func _update_time(t):
	var s = t.replace("PENALTY SHOOTOUT", "PENALTIES").replace("EXTRA TIME  ", "ET ").replace("- SUDDEN DEATH", "SD")
	_set_text(time_lbl, s)
	if s.begins_with("ET"):
		time_sb.bg_color = ORANGE
	elif s.begins_with("PENALT"):
		time_sb.bg_color = SILVER
	else:
		time_sb.bg_color = GOLD


func _update_chips():
	var jz = Jerseys.get_it()
	var en = jz.enabled()
	if chips_init and en == chips_enabled:
		return
	chips_init = true
	chips_enabled = en
	var ids = [home_id, away_id]
	for i in range(2):
		var tex = jz.texture_for(ids[i])
		var col = Game.team_color(ids[i])
		for pair in [chips[i], pen_chips[i]]:
			pair[0].color = col
			pair[1].texture = tex
			pair[1].visible = tex != null


func _marks(m, team):
	var marks = m.get("so_marks")
	var goals = m.get("so_goals")
	var parts = []
	var n = 5
	if marks[team].size() > n:
		n = marks[team].size()
	for i in range(n):
		if i < marks[team].size():
			parts.append(marks[team][i])
		else:
			parts.append("-")
	var id = home_id if team == 0 else away_id
	return "%s  %s  (%d)" % [_code(id), PoolStringArray(parts).join(" "), goals[team]]


func _update_pens(m):
	var marks = m.get("so_marks")
	var st = m.get("state")
	var show = false
	if marks != null:
		show = st == "shootout" or (st == "over" and (marks[0].size() + marks[1].size()) > 0)
	for i in range(2):
		pen_rows[i].visible = show
		if show:
			_set_text(pen_lbls[i], _marks(m, i))


func _update_banner(m, delta):
	var lm = m.get("lbl_msg")
	var t = ""
	if lm != null:
		t = lm.text
	if t != banner_text:
		banner_text = t
		banner_t = 0.0
		if t == "":
			banner.visible = false
		else:
			var cut = t.find("  ")
			var main = t
			var sub = ""
			if cut != -1:
				main = t.substr(0, cut)
				sub = t.substr(cut).strip_edges()
			banner_main.text = main
			banner_sub.text = sub
			var w = banner_main.get_font("font").get_string_size(main).x + 44
			var sw = banner_sub.get_font("font").get_string_size(sub).x + 44
			w = clamp(max(w, sw), 150, 440)
			banner.rect_size = Vector2(w, 46)
			banner.rect_position = Vector2((480 - w) / 2, 96)
			banner.rect_pivot_offset = Vector2(w / 2, 23)
			banner_main.rect_size = Vector2(w, 24 if sub != "" else 46)
			banner_main.rect_position = Vector2(0, 3 if sub != "" else 0)
			banner_sub.rect_size = Vector2(w, 15)
			banner_sub.visible = sub != ""
			banner.visible = true
	if banner.visible and banner_t < 1.0:
		banner_t = min(1.0, banner_t + delta / 0.18)
		var k = 1.0 - (1.0 - banner_t) * (1.0 - banner_t)
		banner.rect_scale = Vector2(0.85 + 0.15 * k, 0.85 + 0.15 * k)
		banner.modulate = Color(1, 1, 1, k)


func _update_strip(m):
	var lq = m.get("lbl_prompt")
	var t = ""
	if lq != null:
		t = lq.text
	if t == "":
		strip.visible = false
		return
	if strip_lbl.text != t:
		strip_lbl.text = t
		var lines = t.split("\n").size()
		var h = lines * (strip_lbl.get_font("font").get_height() + 2) + 6
		strip.rect_size = Vector2(440, h)
		strip.rect_position = Vector2(20, 264 - h)
		strip_lbl.rect_size = Vector2(440, h)
	strip.visible = true
