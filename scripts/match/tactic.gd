extends Reference
# Tactics for 11-a-side matches: formations, roles, team identities and the
# "team shape" model that tells every outfield player where to stand.
#
# How it fits together
#   get_team_profile(name)  -> formation + tactic + style for a team (by team name)
#   role_for(formation, slot) -> the role of a slot in that formation
#   shape_target(p, ctx)      -> where player p should stand right now
#
# The shape works like a real team block: in possession it follows the ball up
# the pitch and the roles with `push` run beyond it; out of possession the
# defensive line drops to `defensive_line`, the lines behind compress towards
# it and the forwards stay `fwd_gap` ahead of the ball (counter-attackers stay
# high, pressing teams stay close). match.gd adds pressing, marking and the
# passing triangles on top of this.
#
# (No class_name: match.gd preloads this file as TacticSystem.)

const FORMATIONS = {
	"4-3-3": [
		Vector2(0.03, 0.50),   # 0: GK
		Vector2(0.18, 0.15),   # 1: LB
		Vector2(0.15, 0.38),   # 2: CB
		Vector2(0.15, 0.62),   # 3: CB
		Vector2(0.18, 0.85),   # 4: RB
		Vector2(0.38, 0.30),   # 5: LCM
		Vector2(0.35, 0.50),   # 6: CM
		Vector2(0.38, 0.70),   # 7: RCM
		Vector2(0.70, 0.20),   # 8: LW
		Vector2(0.75, 0.50),   # 9: ST
		Vector2(0.70, 0.80)    # 10: RW
	],
	"4-2-3-1": [
		Vector2(0.03, 0.50),   # 0: GK
		Vector2(0.18, 0.15),   # 1: LB
		Vector2(0.15, 0.38),   # 2: CB
		Vector2(0.15, 0.62),   # 3: CB
		Vector2(0.18, 0.85),   # 4: RB
		Vector2(0.32, 0.38),   # 5: CDM
		Vector2(0.32, 0.62),   # 6: CDM
		Vector2(0.55, 0.20),   # 7: LAM
		Vector2(0.50, 0.50),   # 8: CAM
		Vector2(0.55, 0.80),   # 9: RAM
		Vector2(0.78, 0.50)    # 10: ST
	],
	"4-4-2": [
		Vector2(0.03, 0.50),   # 0: GK
		Vector2(0.18, 0.15),   # 1: LB
		Vector2(0.15, 0.38),   # 2: CB
		Vector2(0.15, 0.62),   # 3: CB
		Vector2(0.18, 0.85),   # 4: RB
		Vector2(0.40, 0.15),   # 5: LM
		Vector2(0.38, 0.38),   # 6: CM
		Vector2(0.38, 0.62),   # 7: CM
		Vector2(0.40, 0.85),   # 8: RM
		Vector2(0.72, 0.38),   # 9: ST
		Vector2(0.72, 0.62)    # 10: ST
	],
	"3-5-2": [
		Vector2(0.03, 0.50),   # 0: GK
		Vector2(0.16, 0.25),   # 1: CB
		Vector2(0.14, 0.50),   # 2: CB
		Vector2(0.16, 0.75),   # 3: CB
		Vector2(0.38, 0.10),   # 4: LWB
		Vector2(0.35, 0.35),   # 5: LCM
		Vector2(0.33, 0.50),   # 6: CDM
		Vector2(0.35, 0.65),   # 7: RCM
		Vector2(0.38, 0.90),   # 8: RWB
		Vector2(0.72, 0.38),   # 9: ST
		Vector2(0.72, 0.62)    # 10: ST
	],
	"4-5-1": [
		Vector2(0.03, 0.50),   # 0: GK
		Vector2(0.18, 0.15),   # 1: LB
		Vector2(0.15, 0.38),   # 2: CB
		Vector2(0.15, 0.62),   # 3: CB
		Vector2(0.18, 0.85),   # 4: RB
		Vector2(0.40, 0.12),   # 5: LM
		Vector2(0.38, 0.32),   # 6: CM
		Vector2(0.35, 0.50),   # 7: CDM
		Vector2(0.38, 0.68),   # 8: CM
		Vector2(0.40, 0.88),   # 9: RM
		Vector2(0.76, 0.50)    # 10: ST
	],
	"3-4-3": [
		Vector2(0.03, 0.50),   # 0: GK
		Vector2(0.16, 0.25),   # 1: CB
		Vector2(0.14, 0.50),   # 2: CB
		Vector2(0.16, 0.75),   # 3: CB
		Vector2(0.38, 0.18),   # 4: LM
		Vector2(0.35, 0.40),   # 5: CM
		Vector2(0.35, 0.60),   # 6: CM
		Vector2(0.38, 0.82),   # 7: RM
		Vector2(0.70, 0.20),   # 8: LW
		Vector2(0.75, 0.50),   # 9: ST
		Vector2(0.70, 0.80)    # 10: RW
	]
}

enum TacticType { COUNTERATTACK, BALANCED, RETAIN_POSSESSION, GEGENPRESS }

# What a whole team is doing right now. The three AI scripts decide per player
# what to do (PlayerDecisionAI) and how (AttackAI / DefendAI) from this state.
enum TeamState { ATTACKING, DEFENDING, TRANSITION_ATTACK, TRANSITION_DEFEND }

# What one player is doing right now (chosen by PlayerDecisionAI).
# REBOUND / CLEAR: a shot has been saved, blocked or spilled - attackers crash the box, defenders clear it (ScrambleAI).
enum Intent { CARRY, RECEIVE, LOOSE_BALL, PRESS, COUNTERPRESS, COVER, BLOCK_LANE, MARK, RECOVER, RUN, SUPPORT, HOLD, REBOUND, CLEAR }

const TRANSITION_WINDOW = 1.6   # seconds the "just won it" burst lasts (x transition_speed)

# press_intensity  how hard the first defender closes down (1.0 = normal)
# support_dist     preferred distance of the short passing options (x 520 px)
# forward_bias     how much the team (and its runners) wants to go forward
# pass_safety      0..1, how much a risky pass lane is punished
# defensive_line   highest the defensive line may stand (fraction of pitch length)
# transition_speed length / aggression of the burst right after winning the ball
# compact          how tightly the lines squeeze together without the ball
# fwd_gap          how far ahead of the ball the forwards stay without the ball (px)
# pressers         how many players hunt the ball without it (1 = only the nearest)
# tempo            speed of decisions and of forward runs (1.0 = normal)
# forward_runs     0..1, how often runners go in behind when the team has the ball
# committed        most players allowed to make a forward run at the same time
# counter_urgency  0..1, extra readiness to run right after winning the ball
# counterpress_time seconds of immediate pressure after LOSING the ball
# recovery         0..1, how readily players who are ahead of the ball run back
# press_depth      the team only presses while the ball is within this fraction of
#                  the pitch from its own goal (counter teams sit back)
# width            how wide the team plays: 1.0 = the formation as drawn, > 1 stretches it
#                  across the pitch with the ball (wing play), < 1 squeezes it (narrow, central);
#                  without the ball a wide team also stays wider and a narrow one tucks in tighter
# zone             0..1 zone discipline: 1 = everybody holds his zone, 0 = free roaming
# spacing          distance wanted between team-mates (1.0 = normal, x 170 px with the ball, x 130 px without)
# trap             how often the back line steps up together to catch an attacker offside
#                  (0 = never: deep blocks, 1 = every time it can)
const TACTIC_PROPERTIES = {
	TacticType.COUNTERATTACK: {
		"name": "Counterattack",
		"press_intensity": 0.8, "support_dist": 0.30, "forward_bias": 0.85,
		"pass_safety": 0.45, "defensive_line": 0.34, "transition_speed": 1.5,
		"compact": 0.80, "fwd_gap": 380.0, "pressers": 1, "press_depth": 0.55,
		"tempo": 1.15, "forward_runs": 0.85, "committed": 3, "counter_urgency": 1.0,
		"counterpress_time": 1.2, "recovery": 1.0,
		"width": 0.92, "zone": 0.85, "spacing": 1.0, "trap": 0.15
	},
	TacticType.BALANCED: {
		"name": "Balanced",
		"press_intensity": 1.0, "support_dist": 0.30, "forward_bias": 0.55,
		"pass_safety": 0.60, "defensive_line": 0.46, "transition_speed": 1.0,
		"compact": 0.85, "fwd_gap": 240.0, "pressers": 2, "press_depth": 0.70,
		"tempo": 1.00, "forward_runs": 0.55, "committed": 2, "counter_urgency": 0.5,
		"counterpress_time": 1.8, "recovery": 0.8,
		"width": 1.00, "zone": 0.75, "spacing": 1.0, "trap": 0.40
	},
	TacticType.RETAIN_POSSESSION: {
		"name": "Retain Possession",
		"press_intensity": 0.7, "support_dist": 0.25, "forward_bias": 0.30,
		"pass_safety": 0.90, "defensive_line": 0.50, "transition_speed": 0.7,
		"compact": 0.90, "fwd_gap": 200.0, "pressers": 2, "press_depth": 0.60,
		"tempo": 0.85, "forward_runs": 0.30, "committed": 1, "counter_urgency": 0.2,
		"counterpress_time": 2.2, "recovery": 0.7,
		"width": 1.12, "zone": 0.65, "spacing": 1.1, "trap": 0.50
	},
	TacticType.GEGENPRESS: {
		"name": "Gegenpress",
		"press_intensity": 1.4, "support_dist": 0.30, "forward_bias": 0.65,
		"pass_safety": 0.50, "defensive_line": 0.64, "transition_speed": 1.8,
		"compact": 0.95, "fwd_gap": 130.0, "pressers": 3, "press_depth": 1.0,
		"tempo": 1.20, "forward_runs": 0.70, "committed": 3, "counter_urgency": 0.8,
		"counterpress_time": 3.0, "recovery": 0.6,
		"width": 1.00, "zone": 0.55, "spacing": 0.9, "trap": 0.70
	}
}

# Personality on top of the tactic (all 0..1):
#   directness  long / vertical passes and runs in behind (0 = patient short game)
#   dribble     readiness to carry the ball instead of passing
#   wide        play down the flanks and cross
#   shoot       readiness to shoot from distance
#   risk        how much a congested pass lane is tolerated
const DEFAULT_STYLE = {"directness": 0.40, "dribble": 0.40, "wide": 0.50, "shoot": 0.50, "risk": 0.50}

# One identity per team, keyed by the team NAME in Game.TEAMS.
# "tune" overrides single tactic numbers for that team only.
const TEAM_IDENTITIES = {
	"Red": {
		"formation": "4-2-3-1", "tactic": TacticType.RETAIN_POSSESSION,
		"style_desc": "Tiki-taka: short safe passing, patient build-up",
		"style": {"directness": 0.10, "dribble": 0.25, "wide": 0.35, "shoot": 0.35, "risk": 0.25},
		"tune": {"width": 1.15, "spacing": 1.15}
	},
	"Blue": {
		"formation": "4-3-3", "tactic": TacticType.GEGENPRESS,
		"style_desc": "The Machine: high press, structured shape, wide wingers",
		"style": {"directness": 0.45, "dribble": 0.45, "wide": 0.70, "shoot": 0.50, "risk": 0.55},
		"tune": {"width": 1.15, "zone": 0.80}
	},
	"White": {
		"formation": "4-4-2", "tactic": TacticType.COUNTERATTACK,
		"style_desc": "Compact block, rapid vertical counters",
		"style": {"directness": 0.85, "dribble": 0.40, "wide": 0.50, "shoot": 0.55, "risk": 0.60},
		"tune": {"width": 0.90}
	},
	"Green": {
		"formation": "3-5-2", "tactic": TacticType.BALANCED,
		"style_desc": "Wing-backs: width, overlaps and crosses",
		"style": {"directness": 0.40, "dribble": 0.35, "wide": 0.95, "shoot": 0.40, "risk": 0.50},
		"tune": {"width": 1.30}
	},
	"Yellow": {
		"formation": "4-3-3", "tactic": TacticType.BALANCED,
		"style_desc": "Flair: dribblers who take defenders on",
		"style": {"directness": 0.35, "dribble": 0.85, "wide": 0.60, "shoot": 0.55, "risk": 0.65},
		"tune": {"zone": 0.60}
	},
	"Orange": {
		"formation": "4-5-1", "tactic": TacticType.COUNTERATTACK,
		"style_desc": "Low block: deep, narrow, hit on the break",
		"style": {"directness": 0.70, "dribble": 0.30, "wide": 0.40, "shoot": 0.30, "risk": 0.35},
		"tune": {"defensive_line": 0.30, "pressers": 1, "width": 0.82, "zone": 0.85, "trap": 0.0}
	},
	"Purple": {
		"formation": "3-4-3", "tactic": TacticType.GEGENPRESS,
		"style_desc": "Total attack: high line, many forwards, all-in",
		"style": {"directness": 0.50, "dribble": 0.55, "wide": 0.60, "shoot": 0.65, "risk": 0.75},
		"tune": {"width": 1.10, "zone": 0.45}
	},
	"Black": {
		"formation": "4-4-2", "tactic": TacticType.BALANCED,
		"style_desc": "Direct play: long balls to the big men",
		"style": {"directness": 0.85, "dribble": 0.20, "wide": 0.55, "shoot": 0.60, "risk": 0.50},
		"tune": {"width": 0.95}
	},
	"default": {
		"formation": "4-4-2", "tactic": TacticType.BALANCED,
		"style_desc": "Balanced shape setup",
		"style": {}
	}
}

enum Role {
	CB_DEFENSIVE, CB_BALL_PLAYING, CB_COVERING, CB_AGGRESSIVE,
	FB_DEFENSIVE, FB_ATTACKING, FB_INVERTED, FB_BALANCED,
	DM_ANCHOR, DM_BALL_WINNING, DM_DEEP_PLAYMAKER, DM_HALF_BACK, DM_SEGUNDO_VOLANTE,
	CM_BOX_TO_BOX, CM_MEZZALA, CM_CENTRAL_PLAYMAKER, CM_CARRILERO, CM_ADVANCED,
	AM_ADVANCED_PLAYMAKER, AM_SHADOW_STRIKER, AM_TREQUARTISTA, AM_ATTACKING_MID, AM_ENGANCHE,
	WG_TRADITIONAL, WG_INVERTED_WINGER, WG_INSIDE_FORWARD, WG_WIDE_PLAYMAKER, WG_DEFENSIVE_WINGER, WG_WIDE_TARGET,
	ST_ADVANCED_FORWARD, ST_POACHER, ST_TARGET_FORWARD, ST_DEEP_LYING, ST_FALSE_NINE, ST_COMPLETE, ST_PRESSING
}

# The role of every slot, per formation (slot 0 = goalkeeper, handled by match.gd).
const FORMATION_ROLES = {
	"4-3-3": [
		Role.CB_DEFENSIVE,
		Role.FB_BALANCED, Role.CB_BALL_PLAYING, Role.CB_DEFENSIVE, Role.FB_ATTACKING,
		Role.CM_BOX_TO_BOX, Role.DM_HALF_BACK, Role.CM_CENTRAL_PLAYMAKER,
		Role.WG_INVERTED_WINGER, Role.ST_ADVANCED_FORWARD, Role.WG_TRADITIONAL
	],
	"4-2-3-1": [
		Role.CB_DEFENSIVE,
		Role.FB_BALANCED, Role.CB_BALL_PLAYING, Role.CB_DEFENSIVE, Role.FB_BALANCED,
		Role.DM_ANCHOR, Role.DM_DEEP_PLAYMAKER,
		Role.WG_INSIDE_FORWARD, Role.AM_ADVANCED_PLAYMAKER, Role.WG_INSIDE_FORWARD,
		Role.ST_FALSE_NINE
	],
	"4-4-2": [
		Role.CB_DEFENSIVE,
		Role.FB_BALANCED, Role.CB_BALL_PLAYING, Role.CB_DEFENSIVE, Role.FB_BALANCED,
		Role.WG_TRADITIONAL, Role.CM_CENTRAL_PLAYMAKER, Role.CM_BOX_TO_BOX, Role.WG_TRADITIONAL,
		Role.ST_TARGET_FORWARD, Role.ST_POACHER
	],
	"3-5-2": [
		Role.CB_DEFENSIVE,
		Role.CB_COVERING, Role.CB_BALL_PLAYING, Role.CB_COVERING,
		Role.FB_ATTACKING, Role.CM_BOX_TO_BOX, Role.DM_ANCHOR, Role.CM_MEZZALA, Role.FB_ATTACKING,
		Role.ST_TARGET_FORWARD, Role.ST_POACHER
	],
	"4-5-1": [
		Role.CB_DEFENSIVE,
		Role.FB_DEFENSIVE, Role.CB_BALL_PLAYING, Role.CB_DEFENSIVE, Role.FB_DEFENSIVE,
		Role.WG_TRADITIONAL, Role.CM_BOX_TO_BOX, Role.DM_ANCHOR, Role.CM_CARRILERO, Role.WG_TRADITIONAL,
		Role.ST_TARGET_FORWARD
	],
	"3-4-3": [
		Role.CB_DEFENSIVE,
		Role.CB_COVERING, Role.CB_BALL_PLAYING, Role.CB_COVERING,
		Role.FB_ATTACKING, Role.CM_BOX_TO_BOX, Role.CM_CENTRAL_PLAYMAKER, Role.FB_ATTACKING,
		Role.WG_INSIDE_FORWARD, Role.ST_COMPLETE, Role.WG_INSIDE_FORWARD
	]
}

# [family, push, width, drop, run, press]
#   push   how far the role advances beyond the shape when his team has the ball
#   width  how strongly he holds the touchline lane
#   drop   drops towards the ball to receive (false nine, deep playmakers)
#   run    makes forward runs in behind the defence
#   press  how keen he is to win the ball back
const ROLE_TRAITS = {
	Role.CB_DEFENSIVE: ["CB", 0.05, 0.0, 0.0, false, 0.6],
	Role.CB_BALL_PLAYING: ["CB", 0.20, 0.0, 0.0, false, 0.7],
	Role.CB_COVERING: ["CB", 0.00, 0.0, 0.0, false, 0.5],
	Role.CB_AGGRESSIVE: ["CB", 0.25, 0.0, 0.0, false, 1.2],
	Role.FB_DEFENSIVE: ["FB", 0.25, 0.6, 0.0, false, 0.8],
	Role.FB_ATTACKING: ["FB", 0.90, 0.85, 0.0, true, 0.9],
	Role.FB_INVERTED: ["FB", 0.35, 0.1, 0.0, false, 0.8],
	Role.FB_BALANCED: ["FB", 0.55, 0.7, 0.0, false, 0.9],
	Role.DM_ANCHOR: ["DM", 0.05, 0.0, 0.0, false, 0.8],
	Role.DM_BALL_WINNING: ["DM", 0.15, 0.0, 0.0, false, 1.3],
	Role.DM_DEEP_PLAYMAKER: ["DM", 0.15, 0.0, 0.3, false, 0.7],
	Role.DM_HALF_BACK: ["DM", 0.00, 0.0, 0.5, false, 0.8],
	Role.DM_SEGUNDO_VOLANTE: ["DM", 0.45, 0.0, 0.0, true, 1.0],
	Role.CM_BOX_TO_BOX: ["CM", 0.65, 0.0, 0.0, true, 1.0],
	Role.CM_MEZZALA: ["CM", 0.70, 0.3, 0.0, true, 0.9],
	Role.CM_CENTRAL_PLAYMAKER: ["CM", 0.45, 0.0, 0.2, false, 0.8],
	Role.CM_CARRILERO: ["CM", 0.50, 0.5, 0.0, false, 1.0],
	Role.CM_ADVANCED: ["CM", 0.80, 0.0, 0.0, true, 0.9],
	Role.AM_ADVANCED_PLAYMAKER: ["AM", 0.75, 0.0, 0.2, false, 0.8],
	Role.AM_SHADOW_STRIKER: ["AM", 1.00, 0.0, 0.0, true, 0.9],
	Role.AM_TREQUARTISTA: ["AM", 0.80, 0.2, 0.2, false, 0.5],
	Role.AM_ATTACKING_MID: ["AM", 0.85, 0.0, 0.0, true, 0.9],
	Role.AM_ENGANCHE: ["AM", 0.60, 0.0, 0.3, false, 0.4],
	Role.WG_TRADITIONAL: ["WG", 0.85, 1.0, 0.0, true, 0.8],
	Role.WG_INVERTED_WINGER: ["WG", 0.90, 0.35, 0.0, true, 0.9],
	Role.WG_INSIDE_FORWARD: ["WG", 0.95, 0.30, 0.0, true, 1.0],
	Role.WG_WIDE_PLAYMAKER: ["WG", 0.70, 0.8, 0.2, false, 0.8],
	Role.WG_DEFENSIVE_WINGER: ["WG", 0.50, 0.9, 0.0, false, 1.2],
	Role.WG_WIDE_TARGET: ["WG", 0.80, 1.0, 0.0, false, 0.7],
	Role.ST_ADVANCED_FORWARD: ["ST", 1.00, 0.0, 0.0, true, 1.0],
	Role.ST_POACHER: ["ST", 1.00, 0.0, 0.0, true, 0.6],
	Role.ST_TARGET_FORWARD: ["ST", 0.90, 0.0, 0.0, false, 0.8],
	Role.ST_DEEP_LYING: ["ST", 0.70, 0.0, 0.4, false, 0.9],
	Role.ST_FALSE_NINE: ["ST", 0.70, 0.0, 0.6, false, 0.8],
	Role.ST_COMPLETE: ["ST", 1.00, 0.0, 0.1, true, 1.0],
	Role.ST_PRESSING: ["ST", 1.00, 0.0, 0.0, true, 1.5]
}

# how far each family slides sideways towards the ball when its team has not got it
const SHIFT_Y = {"CB": 0.40, "FB": 0.45, "DM": 0.40, "CM": 0.40, "AM": 0.35, "WG": 0.30, "ST": 0.25}
# average depth of the back line in every formation (fraction of pitch length)
const HOME_LINE = 0.16

# his zone: how far (px) a player may be pulled away from his place in the team shape by a job (a man to mark,
# a pass to offer ...) before the shape pulls him back. Vector2(along the pitch, across it); the tactic's `zone`
# number scales it (strict teams: smaller).
const ZONE_LEASH = {
	"CB": Vector2(170.0, 200.0), "FB": Vector2(260.0, 170.0), "DM": Vector2(230.0, 220.0), "CM": Vector2(320.0, 280.0),
	"AM": Vector2(340.0, 300.0), "WG": Vector2(360.0, 200.0), "ST": Vector2(400.0, 320.0)
}


# ------------------------------------------------------------------ lookups

static func get_team_profile(team_name):
	var ident = TEAM_IDENTITIES.get(team_name, TEAM_IDENTITIES["default"])
	var tactic = ident["tactic"]
	var tac = TACTIC_PROPERTIES[tactic].duplicate()
	var tune = ident.get("tune", {})
	for k in tune.keys():
		tac[k] = tune[k]
	var style = DEFAULT_STYLE.duplicate()
	var over = ident.get("style", {})
	for k in over.keys():
		style[k] = over[k]
	return {
		"name": team_name, "formation": ident["formation"], "tactic": tactic,
		"style_desc": ident["style_desc"], "label": tac["name"], "tac": tac, "style": style
	}


# The team state from possession (already smoothed by the match) and how long ago
# it was won / lost.
static func compute_state(has_ball, gain_t, loss_t, tac):
	if has_ball:
		if gain_t < TRANSITION_WINDOW * float(tac.get("transition_speed", 1.0)):
			return TeamState.TRANSITION_ATTACK
		return TeamState.ATTACKING
	if loss_t < float(tac.get("counterpress_time", 1.8)):
		return TeamState.TRANSITION_DEFEND
	return TeamState.DEFENDING


static func is_attack_state(st):
	return st == TeamState.ATTACKING or st == TeamState.TRANSITION_ATTACK


static func is_defend_state(st):
	return st == TeamState.DEFENDING or st == TeamState.TRANSITION_DEFEND


static func zone_leash(fam):
	return ZONE_LEASH.get(fam, Vector2(300.0, 250.0))


static func get_tactical_behavior(tactic_enum):
	return TACTIC_PROPERTIES.get(tactic_enum, TACTIC_PROPERTIES[TacticType.BALANCED])


static func role_for(formation_name, slot):
	var roles = FORMATION_ROLES.get(formation_name, FORMATION_ROLES["4-4-2"])
	return roles[clamp(slot, 0, roles.size() - 1)]


# {"fam", "push", "width", "drop", "run", "press"}
static func role_traits(role):
	var r = ROLE_TRAITS.get(role, ROLE_TRAITS[Role.CM_BOX_TO_BOX])
	return {"fam": r[0], "push": r[1], "width": r[2], "drop": r[3], "run": r[4], "press": r[5]}


static func get_formation_pos(formation_name, slot, team, pitch_rect):
	var layout = FORMATIONS.get(formation_name, FORMATIONS["4-4-2"])
	var f = layout[slot]
	var x = f.x * pitch_rect.size.x
	if team == 1:
		x = pitch_rect.size.x - x
	return Vector2(pitch_rect.position.x + x, pitch_rect.position.y + f.y * pitch_rect.size.y)


# --------------------------------------------------------------- shape model
# "depth" = distance from the player's OWN goal line along the pitch.

static func _depth(x, pitch, dir):
	return (x - pitch.position.x) if dir > 0.0 else (pitch.end.x - x)


static func _x_from_depth(d, pitch, dir):
	return (pitch.position.x + d) if dir > 0.0 else (pitch.end.x - d)


# ctx: {pitch, ball, dir (+1 = attacks to the right), tac, style, poss (bool),
#       trans (bool, just won the ball), opp_last_d (depth of the last opposing
#       outfield player, measured from OUR goal)}
static func shape_target(p, ctx):
	var pitch = ctx["pitch"]
	var ball = ctx["ball"]
	var dir = ctx["dir"]
	var tac = ctx["tac"]
	var st = ctx["style"]
	var L = pitch.size.x
	var H = pitch.size.y
	var tr = role_traits(p.role)
	var fam = tr["fam"]
	var home = p.home_pos
	var home_d = _depth(home.x, pitch, dir)
	var ball_d = _depth(ball.x, pitch, dir)
	var mid_y = pitch.position.y + H * 0.5
	var d = home_d
	var y = home.y

	if ctx["poss"]:
		# in possession: the block follows the ball, runners go beyond it
		d = home_d + (ball_d - L * 0.45) * 0.45 + tr["push"] * tac["forward_bias"] * 150.0
		if ctx["trans"] and tr["run"]:
			d += 120.0                                       # break quickly after winning it
		if fam == "CB" or fam == "DM":
			d = min(d, ball_d - 70.0)                        # stay behind the ball
		elif fam == "FB":
			d = min(d, ball_d + 90.0 * tr["push"])
		elif fam == "CM":
			d = min(d, ball_d + 120.0)
		if tr["run"] and ball_d > L * 0.35:
			var run_d = min(ctx["opp_last_d"] - 40.0, L - 140.0)   # on the last defender's shoulder
			d = max(d, lerp(d, run_d, 0.65))
		if tr["drop"] > 0.0 and ball_d > L * 0.40:
			d = min(d, ball_d - 40.0 - 60.0 * tr["drop"])
		d = clamp(d, L * 0.05, L - 110.0)
		if tr["width"] > 0.0:
			var edge = (pitch.position.y + 75.0) if home.y < mid_y else (pitch.end.y - 75.0)
			y = lerp(home.y, edge, tr["width"] * 0.5 * (0.6 + 0.8 * st["wide"]))
		else:
			y = home.y + (ball.y - home.y) * 0.22
	else:
		# out of possession: defensive line follows the ball down to `defensive_line`
		var line_d = clamp(ball_d - 250.0, L * 0.10, tac["defensive_line"] * L)
		d = line_d + (home_d - HOME_LINE * L) * tac["compact"]
		if fam == "ST" or fam == "WG" or fam == "AM":
			d = min(d, ball_d + tac["fwd_gap"])
		elif ball_d > L * 0.12:
			d = min(d, ball_d - 30.0)                        # goal-side of the ball
		d = clamp(d, L * 0.04, L - 110.0)
		y = home.y + (ball.y - home.y) * SHIFT_Y.get(fam, 0.35)

	return Vector2(_x_from_depth(d, pitch, dir),
		clamp(y, pitch.position.y + 30.0, pitch.end.y - 30.0))
