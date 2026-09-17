extends Node
##
## GameConfig.gd — 全局常量、物理层、输入映射注册
## Autoload 名: GameConfig
##
## 设计原则: 所有平衡数值集中在此处或 data/*.json, 禁止散落在逻辑代码中。
##

# ---------------------------------------------------------------- 枚举
enum Team { STRIKE, GUARD, SPECTATOR }
enum RoundState { WARMUP, BUY, LIVE, PLANTED, ROUND_OVER, HALFTIME, MATCH_OVER }
enum SurfaceMat { CONCRETE, WOOD, METAL, GLASS, GRASS, WATER }
enum HitGroup { HEAD, BODY, LEGS }
enum MoveState { IDLE, WALK, RUN, CROUCH, AIR, LANDING }

# ---------------------------------------------------------------- 物理层
const LAYER_WORLD   := 1 << 0
const LAYER_PLAYER  := 1 << 1
const LAYER_HITBOX  := 1 << 2
const LAYER_GRENADE := 1 << 3
const LAYER_DEBRIS  := 1 << 4
const LAYER_SMOKE   := 1 << 5

## 子弹射线检测掩码: 只打世界几何 与 部位 hitbox
##
## 绝不能包含 LAYER_PLAYER —— 角色本体是 CharacterBody3D 的胶囊碰撞体,
## 它不带 hit_group 元数据; 一旦射线先命中胶囊, HitSystem 会把它当墙体处理
## 并扣光穿透力, 表现为"子弹永远打不中人"。部位判定全部交给 LAYER_HITBOX。
const MASK_BULLET := LAYER_WORLD | LAYER_HITBOX

## 特效专用 visual layer(第 3 层, 1-indexed)。主光源 cull mask 排除它,
## 这样曳光弹/弹孔/烟雾等不参与光照与阴影计算, 省下大量 GPU 开销。
const FX_VISUAL_LAYER := 1 << 2

# ---------------------------------------------------------------- 比赛规则
const MAX_ROUNDS       := 24
const WIN_ROUNDS       := 13
const HALF_ROUNDS      := 12
const OT_ROUNDS_PER_SIDE := 3

const BUY_TIME         := 15.0
const FREEZE_TIME      := 10.0
const ROUND_TIME       := 115.0   # 1:55
const PLANT_TIME       := 6.0
const DEFUSE_TIME      := 7.0
const DEFUSE_KIT_TIME  := 4.0
const BOMB_TIMER       := 40.0
const ROUND_END_PAUSE  := 4.0

# ---------------------------------------------------------------- 经济
const START_MONEY      := 800
const MAX_MONEY        := 16000
const PISTOL_ROUND_MONEY := 800

const LOSS_BONUS_BASE  := 1400
const LOSS_BONUS_STEP  := 500
const LOSS_BONUS_MAX   := 3400
const WIN_BONUS_ELIM   := 3250
const WIN_BONUS_PLANT  := 3500
const WIN_BONUS_DEFUSE := 3500
const WIN_BONUS_TIME   := 3250
const LOSER_PLANT_BONUS := 800

const KILL_REWARD_BASE := 300     # 通用击杀奖励
const DEFUSE_REWARD    := 300
const PLANT_REWARD     := 300

const ARMOR_LIGHT_PRICE := 400
const ARMOR_HEAVY_PRICE := 1000
const DEFUSE_KIT_PRICE  := 400

# ---------------------------------------------------------------- 玩家
const MAX_HP           := 100
const MAX_ARMOR        := 100
const ARMOR_ABSORB     := 0.5      # 护甲吸收 50% 伤害(满甲)
const ARMOR_HEAVY_ABSORB := 0.55
const ARMOR_RATIO_MIN  := 0.2      # 护甲低于 20% 时吸收效率衰减

const EYE_HEIGHT       := 1.7
const CROUCH_HEIGHT    := 1.1
const CAPSULE_RADIUS   := 0.4
const WALK_SPEED       := 4.6
const RUN_SPEED        := 6.4
const CROUCH_SPEED     := 2.6
const AIR_ACCEL        := 12.0
const GROUND_ACCEL     := 68.0
const GROUND_FRICTION  := 11.0
const AIR_FRICTION     := 0.4
const JUMP_VELOCITY    := 6.2
const GRAVITY          := 18.0

const MOUSE_SENS_BASE  := 0.0022
const ADS_SENS_MULT    := 0.78     # 开镜灵敏度倍率(降低)

const MAX_PITCH        := 89.0     # 垂直视角限制(度)

# ---------------------------------------------------------------- 穿透系数
const PENETRATION := {
	SurfaceMat.WOOD:     0.70,
	SurfaceMat.GLASS:    0.90,
	SurfaceMat.METAL:    0.40,
	SurfaceMat.CONCRETE: 0.15,
	SurfaceMat.GRASS:    0.95,
	SurfaceMat.WATER:    0.50,
}
## 各类材质的"厚度成本", 穿透消耗 = 厚度 / 穿透力
const PENETRATION_COST := {
	SurfaceMat.WOOD:     0.35,
	SurfaceMat.GLASS:    0.10,
	SurfaceMat.METAL:    0.55,
	SurfaceMat.CONCRETE: 1.20,
	SurfaceMat.GRASS:    0.05,
	SurfaceMat.WATER:    0.80,
}

# ---------------------------------------------------------------- 队伍配色
const TEAM_COLOR := {
	Team.STRIKE: Color(0.95, 0.45, 0.25),   # 橙红 - 进攻方
	Team.GUARD:  Color(0.30, 0.62, 0.95),   # 蓝 - 防守方
}
const TEAM_NAME := {
	Team.STRIKE: "STRIKE",
	Team.GUARD:  "GUARD",
}

# ---------------------------------------------------------------- 输入动作定义
## [action_name, keycode, [alt_keycode]]
const INPUT_BINDINGS: Array = [
	["mv_forward",   KEY_W, []],
	["mv_back",      KEY_S, []],
	["mv_left",      KEY_A, []],
	["mv_right",     KEY_D, []],
	["mv_jump",      KEY_SPACE, []],
	["mv_crouch",    KEY_CTRL, [KEY_C]],
	["mv_walk",      KEY_SHIFT, []],
	["wpn_fire",     MOUSE_BUTTON_LEFT, []],
	["wpn_ads",      MOUSE_BUTTON_RIGHT, []],
	["wpn_reload",   KEY_R, []],
	["slot_primary", KEY_1, []],
	["slot_secondary", KEY_2, []],
	["slot_knife",   KEY_3, []],
	["slot_grenade", KEY_4, []],
	["slot_cycle",   KEY_G, [MOUSE_BUTTON_WHEEL_DOWN]],
	["util_plant",   KEY_E, [KEY_F]],
	["ui_buy",       KEY_B, []],
	["ui_scoreboard", KEY_TAB, []],
	["ui_pause",     KEY_ESCAPE, []],
	["ui_teamchat",  KEY_ENTER, []],
	["dbg_toggle_ai", KEY_F3, []],
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_register_inputs()


func _register_inputs() -> void:
	for b in INPUT_BINDINGS:
		var action: String = b[0]
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.15)
		var main_key = b[1]
		if main_key >= 0:
			_bind_key(action, main_key)
		for alt in b[2]:
			_bind_key(action, alt)


func _bind_key(action: String, code: int) -> void:
	var ev: InputEvent
	if code >= MOUSE_BUTTON_LEFT and code <= MOUSE_BUTTON_WHEEL_RIGHT:
		var m := InputEventMouseButton.new()
		m.button_index = code
		ev = m
	else:
		var k := InputEventKey.new()
		k.physical_keycode = code
		k.keycode = 0
		ev = k
	# 避免重复绑定
	for existing in InputMap.action_get_events(action):
		if existing is InputEventMouseButton and ev is InputEventMouseButton:
			if existing.button_index == ev.button_index:
				return
		elif existing is InputEventKey and ev is InputEventKey:
			if existing.physical_keycode == ev.physical_keycode:
				return
	InputMap.action_add_event(action, ev)


# ---------------------------------------------------------------- 工具
static func team_name(t: int) -> String:
	return TEAM_NAME.get(t, "SPEC")


static func is_valid_team(t: int) -> bool:
	return t == Team.STRIKE or t == Team.GUARD


static func opponent(t: int) -> int:
	return Team.GUARD if t == Team.STRIKE else Team.STRIKE
