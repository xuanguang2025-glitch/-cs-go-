extends RefCounted
class_name AntiCheat
##
## AntiCheat.gd — 服务器端校验(提示词 27 条)
##
## 原则: 安全逻辑绝不在客户端。所有校验只在服务器(权威端)执行,
## 校验失败不踢人、只回退到上一个合法状态 —— 避免误伤高延迟玩家。
##

## 每个远端 actor 的上一个合法状态
var _last_valid: Dictionary = {}     # actor -> {"pos": Vector3, "time": float}

# 可调阈值
const MAX_SPEED_MULT := 1.6          # 超过理论最大速度 1.6 倍视为异常
const TELEPORT_DIST := 12.0          # 单帧位移超过此值视为瞬移(传送/回档)
const MAX_FIRE_RATE_MULT := 1.25     # 射速超限容差(网络抖动)
const STRIKE_COUNT_TO_ACT := 5       # 连续异常 N 次才回退

var _strike_counts: Dictionary = {}  # actor -> int


## 位置校验: 服务器在应用远端玩家的移动结果前调用
## 返回 true = 合法; false = 异常(调用方应回退到 _last_valid 位置)
func validate_move(actor: Actor, new_pos: Vector3, dt: float) -> bool:
	if actor == null or dt <= 0.0:
		return true

	var max_speed: float = actor.current_max_speed() * MAX_SPEED_MULT
	# 空中/下落额外放宽
	max_speed += 4.0

	var last: Dictionary = _last_valid.get(actor, {})
	var ok := true
	if not last.is_empty():
		var last_pos: Vector3 = last["pos"]
		var dist: float = last_pos.distance_to(new_pos)
		var allowed: float = max_speed * dt + 1.0
		if dist > allowed and dist < TELEPORT_DIST:
			ok = false
		elif dist >= TELEPORT_DIST:
			# 大距离可能是合法传送(spawn/respawn), 只在极短时间内才算异常
			var t: float = float(last.get("time", 0.0))
			if Time.get_ticks_msec() - t < 200:
				ok = false

	if ok:
		_strike_counts[actor] = 0
		_last_valid[actor] = {"pos": new_pos, "time": Time.get_ticks_msec()}
		return true

	_strike_counts[actor] = int(_strike_counts.get(actor, 0)) + 1
	if int(_strike_counts.get(actor, 0)) >= STRIKE_COUNT_TO_ACT:
		push_warning("[AntiCheat] %s 连续移动校验失败, 回退位置" % actor.actor_name)
		return false
	# 容忍少量抖动
	_last_valid[actor] = {"pos": new_pos, "time": Time.get_ticks_msec()}
	return true


## 射速校验: 服务器在处理 fire 请求前调用
## last_shot_ms 由调用方(WeaponSystem 服务器侧)记录
func validate_fire(last_shot_ms: int, fire_interval: float) -> bool:
	if last_shot_ms < 0:
		return true
	var min_interval_ms: float = fire_interval * 1000.0 / MAX_FIRE_RATE_MULT
	return float(Time.get_ticks_msec() - last_shot_ms) >= min_interval_ms - 30.0


## 血量一致性校验: 客户端上报的伤害永远不接受 —— 伤害只在服务器结算。
## 此函数存在仅为文档化该原则; 任何"客户端报伤害"的路径都应直接丢弃。
static func reject_client_damage() -> void:
	push_error("[AntiCheat] 收到了客户端上报的伤害, 已拒绝")


func forget(actor: Actor) -> void:
	_last_valid.erase(actor)
	_strike_counts.erase(actor)
