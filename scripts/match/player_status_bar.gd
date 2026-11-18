extends CanvasLayer
# Player status bar along the bottom of the screen (like the broadcast "14 FELIX" bar):
#   [club crest]  number  name
# One bar per human player: player 1 bottom-left, player 2 bottom-right (two-player games).
# It slides in whenever the player you control changes. The on-pitch indicator is the arrow over his head
# (drawn by player.gd). This script also hands every player his jersey number, which player.gd prints
# on the back of the shirt.
#
# match.gd adds it as a child: add_child(PlayerStatusBar.new(self)).
#
# Club crests: put a PNG per club in res://assets/logos/ named after the team in lower case with
# underscores for spaces (e.g. red.png, blue_stars.png). Without one a shield in the kit colours with the
# club's initials is drawn.

const FONT_PATH = "res://assets/fonts/Roboto-Bold.ttf"
const LOGO_DIR = "res://assets/logos/"
const MARGIN = 14.0              # distance from the screen edge (on a 960-wide screen; scales with it)
const BAR_W = 236.0
const BAR_H = 28.0

var m
var canvas
var font_num
var font_name
var font_tag
var numbers = {}                 # player index (team * 11 + slot) -> jersey number
var numbers_ready = false
var slide = [1.0, 1.0]           # 0..1 slide-in progress per team
var last_sel = [null, null]
var logos = {}


class BarCanvas extends Node2D:
	var host

	func _draw():
		if host != null:
			host.draw_bars(self)


func _init(match_node):
	m = match_node
	layer = 5


func _ready():
	font_num = _font(16)
	font_name = _font(12)
	font_tag = _font(9)
	canvas = BarCanvas.new()
	canvas.host = self
	add_child(canvas)


func _font(size):
	var f = DynamicFont.new()
	f.font_data = load(FONT_PATH)
	f.size = size
	return f


# ------------------------------------------------------------ public: other scripts can ask for these

func number_of(p):
	if not numbers_ready:
		_assign_numbers()
	return numbers.get(_pid(p), p.slot + 1)


# player names will plug in here later (the bar already shows one when it is not empty)
func name_of(_p):
	return ""


# ------------------------------------------------------------ jersey numbers

func _pid(p):
	return p.team * 11 + p.slot


func _by_y(a, b):
	return a.home_pos.y < b.home_pos.y


# Classic numbering by position: 1 keeper, 2 / 3 full-backs, 4 / 5 centre-backs, 6 holding midfielder,
# 7 / 11 wingers, 8 midfielder, 9 striker, 10 playmaker. Players of the same kind are ordered top to
# bottom of the pitch; anyone left over gets 12, 13, 14...
# Every player is also told his number (player.number) so it can be printed on his shirt.
func _assign_numbers():
	var pref = {
		"FB": [2, 3], "CB": [5, 4, 15], "DM": [6, 14], "CM": [8, 16, 18],
		"AM": [10, 17], "WG": [7, 11, 20], "ST": [9, 19, 21]
	}
	for team in range(2):
		var used = {1: true}
		var wanted = []                       # [player, preferred number]
		for p in m.players:
			if p.team == team and p.is_gk:
				numbers[_pid(p)] = 1
		var groups = {}
		for p in m.players:
			if p.team != team or p.is_gk:
				continue
			var fam = m._role_traits_of(p)["fam"]
			if not groups.has(fam):
				groups[fam] = []
			groups[fam].append(p)
		for fam in groups.keys():
			var list = groups[fam]
			list.sort_custom(self, "_by_y")
			var nums = pref.get(fam, [])
			for i in range(list.size()):
				wanted.append([list[i], nums[i] if i < nums.size() else 0])
		var left = []
		for w in wanted:
			var n = w[1]
			if n != 0 and not used.has(n):
				used[n] = true
				numbers[_pid(w[0])] = n
			else:
				left.append(w[0])
		var spare = 12
		for p in left:
			while used.has(spare):
				spare += 1
			used[spare] = true
			numbers[_pid(p)] = spare
	for p in m.players:
		p.set("number", numbers.get(_pid(p), 0))     # (ignored by a player.gd without a number)
	numbers_ready = true


# ------------------------------------------------------------ the bars

func _process(delta):
	if not numbers_ready and not m.players.empty() and m.players[0].home_pos != Vector2.ZERO:
		_assign_numbers()
	for team in range(2):
		var p = m.sel[team]
		if p != last_sel[team]:
			last_sel[team] = p
			slide[team] = 0.0
		slide[team] = min(1.0, slide[team] + delta * 4.0)
	var hidden = m.state == "shootout" or (m.ui_controller != null and m.ui_controller.intro_active)
	canvas.visible = not hidden
	canvas.update()


func _ease(t):
	t = clamp(t, 0.0, 1.0)
	return 1.0 - pow(1.0 - t, 3.0)


func draw_bars(c):
	var vp = get_viewport().get_visible_rect().size
	var ui = vp.x / 960.0
	for team in range(2):
		var p = m.sel[team]
		if p == null or not is_instance_valid(p):
			continue
		if team == 1 and not Game.two_player:
			continue
		_bar(c, team, p, vp, ui, team == 0 or not Game.two_player)


func _bar(c, team, p, vp, ui, left_side):
	var w = BAR_W * ui
	var h = BAR_H * ui
	var t = _ease(slide[team])
	var off = (1.0 - t) * (w + 40.0 * ui)
	var x = MARGIN * ui - off if left_side else vp.x - MARGIN * ui - w + off
	var y = vp.y - MARGIN * ui - h
	var kit = p.color
	var accent = p.ring

	# bar body with a coloured top line
	c.draw_rect(Rect2(x + 2.0 * ui, y + 3.0 * ui, w, h), Color(0, 0, 0, 0.35))
	c.draw_rect(Rect2(x, y, w, h), Color(0.05, 0.07, 0.06, 0.90))
	c.draw_rect(Rect2(x, y, w, 2.5 * ui), kit)

	# crest at the outer end, number and name next to it
	var crest_r = 17.0 * ui
	var crest_c = Vector2(x + (crest_r + 2.0 * ui) if left_side else x + w - crest_r - 2.0 * ui, y + h * 0.5)
	_crest(c, team, crest_c, crest_r, ui)
	var num = str(number_of(p))
	var nm = name_of(p)
	var tx = x + (crest_r * 2.0 + 12.0 * ui) if left_side else x + 14.0 * ui
	var by = y + h * 0.5 + (font_num.get_ascent() - font_num.get_descent()) * 0.5
	_text(c, font_num, num, Vector2(tx, by), accent, ui)
	if nm != "":
		var nx = tx + font_num.get_string_size(num).x + 10.0 * ui
		var ny = y + h * 0.5 + (font_name.get_ascent() - font_name.get_descent()) * 0.5
		_text(c, font_name, nm.to_upper(), Vector2(nx, ny), Color.white, ui)


func _text(c, font, text, pos, col, ui):
	c.draw_string(font, pos + Vector2(1.0, 1.0) * ui, text, Color(0, 0, 0, 0.8))
	c.draw_string(font, pos, text, col)


# the club crest: a PNG from res://assets/logos/ if there is one, else a shield in the kit colours
func _crest(c, team, center, r, ui):
	var tex = _logo(team)
	if tex != null:
		c.draw_texture_rect(tex, Rect2(center - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), false)
		return
	var kit = m.players[team * 11].color
	var lum = kit.r * 0.3 + kit.g * 0.59 + kit.b * 0.11
	var ink = Color(0.05, 0.05, 0.1) if lum > 0.55 else Color.white
	var pts = PoolVector2Array([
		center + Vector2(-0.85, -1.0) * r, center + Vector2(0.85, -1.0) * r, center + Vector2(0.85, 0.15) * r,
		center + Vector2(0.0, 1.0) * r, center + Vector2(-0.85, 0.15) * r])
	c.draw_colored_polygon(pts, kit)
	var closed = PoolVector2Array(pts)
	closed.append(pts[0])
	c.draw_polyline(closed, Color(1, 1, 1, 0.9), 1.6 * ui)
	var tag = _team_tag(team)
	var wtxt = font_tag.get_string_size(tag).x
	c.draw_string(font_tag, center + Vector2(-wtxt * 0.5, (font_tag.get_ascent() - font_tag.get_descent()) * 0.5 - 1.0 * ui), tag, ink)


func _team_name(team):
	return Game.team_name(Game.home_id if team == 0 else Game.away_id)


func _team_tag(team):
	return _team_name(team).substr(0, 3).to_upper()


func _logo(team):
	if logos.has(team):
		return logos[team]
	var path = LOGO_DIR + _team_name(team).to_lower().replace(" ", "_") + ".png"
	var tex = load(path) if ResourceLoader.exists(path) else null
	logos[team] = tex
	return tex
