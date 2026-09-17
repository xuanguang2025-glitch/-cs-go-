extends Node
class_name BotController
##
## BotController.gd — Bot 感知 / 决策 / 导航 / 战斗
##
## 不是"看见就开枪"的简单 AI, 采用分层结构:
##   感知层: 视锥 + 视线(含烟雾遮挡) + 听觉(枪声/脚步半径)
##   决策层: 每回合选择战术(Rush / Default / Hold / Rotate / Retake / Save / Plant / Defuse)
##   执行层: 路点图 A* 寻路 -> 转向 -> 射击(带反应延迟与瞄准误差)
##
## 所有行为最终写入 ActorIntent, 与玩家走完全相同的移动/射击代码路径。
##
## ── 2026-09-11 修订: 修复"进攻方装不上装置" ─────────────────────────
## 实测(纯 AI 5v5, 268 秒): 装置安装 0 次, 攻防胜率 0%:100%。
## 归因与对应修复:
##   R1 携弹者单独冲锋、最先接触敌人 -> _update_carrier_escort() 改为跟在
##      前锋后方 10m, 自己是全队最靠前时后退 20m 等队友
##   R2 交火时前进量被砍到 0.12~0.35, Bot 停在开阔地被打靶
##      -> _steer_to() ENGAGE 分支改为"远则压上(0.9), 近则急停(0.15)"
##   R3 _burst_remaining 按帧递减, 4~9 帧短于 fire_interval, 每次扳机只出 1 发
##      -> 改为按"发"计数(读 WeaponSystem.shot_count)
##   R4 dist>14 才开镜, 14m 内腰射(AR 腰射 3.4° 扩散打不中躯干)
##      -> 步枪/狙击全程开镜, 冲锋枪/霰弹 12m 内腰射
##   R5 手枪局 800 块必然触发 save, 20% 进攻方开局后退
##      -> 排除第 1 回合, 阈值 1100 -> 1000
##   R6 装置掉落后 _am_nearest_to 无人响应, 85.2% 采样点装置在地上
##      -> 改为"最近的存活进攻方必须去捡", 且优先级高于一切
##   R7 安装要求 15m 内无可见敌人, 点内交火时永远不满足
##      -> 放宽到 10m, 并允许"点内待够 2 秒就赌一把强装"
##   R8 五人各自出发 -> 添油战术 -> MatchManager.push_delay 全队集结点
##

const DIFFICULTY := [
	{   # 0 简单
		"reaction": 0.55, "aim_error": 5.5, "turn_speed": 5.0,
		# burst_min/max 是"发数", 不是帧数
		"burst_min": 3, "burst_max": 5, "hearing": 22.0, "fov": 100.0,
		"accuracy_mult": 0.72, "peek_chance": 0.25, "grenade_chance": 0.15,
	},
	{   # 1 普通
		"reaction": 0.32, "aim_error": 2.8, "turn_speed": 9.0,
		"burst_min": 5, "burst_max": 9, "hearing": 32.0, "fov": 118.0,
		"accuracy_mult": 0.88, "peek_chance": 0.45, "grenade_chance": 0.35,
	},
	{   # 2 困难
		"reaction": 0.17, "aim_error": 1.3, "turn_speed": 14.0,
		"burst_min": 8, "burst_max": 14, "hearing": 45.0, "fov": 135.0,
		"accuracy_mult": 1.0, "peek_chance": 0.65, "grenade_chance": 0.55,
	},
]

enum CombatState { IDLE, ENGAGE, REPOSITION, PLANT, DEFUSE, RETREAT, DEAD }

var actor: Actor = null
var difficulty: int = 1
## false 时 poll() 直接返回(测试脚本/暂停用)
var enabled: bool = true

# 感知
var visible_enemies: Array = []
var target: Actor = null
var last_known_enemy_pos: Vector3 = Vector3.ZERO
var last_seen_time: float = -99.0
var _perceive_timer: float = 0.0
var _reaction_timer: float = 0.0

# 导航
var waypoints: Array = []
var nav_graph: Dictionary = {}
var path: Array = []
var path_index: int = 0
var move_goal: Vector3 = Vector3.ZERO
var has_goal: bool = false
var stuck_timer: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _repath_timer: float = 0.0

# 战术
var tactic: String = "default"
var combat_state: int = CombatState.IDLE
var hold_position: Vector3 = Vector3.ZERO
## 本回合锁定的目标炸弹点(一旦选定不再随机变动, 否则会出现"走向 A 却想装 B")
var site_target: Vector3 = Vector3.ZERO
var _tactic_timer: float = 0.0

# 战斗
## 开火串按"发"计数(不是帧)。
## 旧实现每帧 _burst_remaining -= 1, difficulty 1 的 4~9 帧 = 0.03~0.07 秒,
## 而步枪 fire_interval 是 0.1 秒 —— 于是每次扳机最多只出一发,
## 有效射速被压到配额的 1/4, 命中率 6.8%, 谁也打不死谁。
var _burst_shots: int = 0
var _burst_len: int = 6
var _last_shot_count: int = 0
var _burst_pause: float = 0.0
var _aim_noise: Vector2 = Vector2.ZERO
var _aim_noise_timer: float = 0.0
var _strafe_dir: int = 1
var _strafe_timer: float = 0.0
var _grenade_cooldown: float = 0.0
var _stuck_count: int = 0
## 携弹者在点内已停留的秒数(用于"被压制太久就赌一把强装")
var _site_dwell: float = 0.0
## 携弹者"我是全队最靠前"时已原地等待的秒数(见 _update_carrier_escort)
var _escort_wait: float = 0.0
## 本帧是否应该"停住射击"。
##
## AR-17 的数值说明了为什么必须有这个开关:
##   开镜+静止 0.22° 扩散 -> 20m 处命中概率 ≈ 100%
##   开镜+移动 1.68° 扩散 -> 20m 处命中概率 ≈ 26%
##   腰射+静止 3.4° 扩散 -> ≈ 6%
## 也就是"移动"一次就要付 4~5 倍的命中率代价。所以 Bot 必须在开火的
## 0.5~0.9 秒里站定, 在 0.2~0.5 秒的换弹间隙里推进 —— 平均速度不低,
## 射击时却是满精度。这同时也是真人玩家的"急停射击"节奏。
var _hold_to_shoot: bool = false

var objective: Node = null
var match_mgr: Node = null


# ================================================================ 生命周期
func _ready() -> void:
	# 由 Actor 主动调用 poll(), 不注册 _physics_process
	_diff = DIFFICULTY[clampi(difficulty, 0, 2)]


var _diff: Dictionary = {}


func setup(actor_ref: Actor, waypoints_ref: Array, graph: Dictionary,
		objective_ref: Node, match_ref: Node) -> void:
	actor = actor_ref
	waypoints = waypoints_ref
	nav_graph = graph
	objective = objective_ref
	match_mgr = match_ref
	_diff = DIFFICULTY[clampi(difficulty, 0, 2)]
	_last_pos = actor.global_position
	if actor != null:
		hold_position = actor.global_position


func on_round_start() -> void:
	target = null
	visible_enemies.clear()
	combat_state = CombatState.IDLE
	_burst_shots = 0
	_last_shot_count = 0
	_burst_pause = 0.0
	_site_dwell = 0.0
	_escort_wait = 0.0
	_burst_len = randi_range(int(_diff.get("burst_min", 5)), int(_diff.get("burst_max", 9)))
	path.clear()
	has_goal = false
	if actor != null:
		_last_pos = actor.global_position
		hold_position = actor.global_position
	_choose_tactic()


# ---------------------------------------------------------------- 战术选择
## 进攻方前沿集结点所在 z。三条 lane 的 z=5~6.5 一带是进点前最后的掩体区,
## 全队在这里汇合再一起压 —— 直接冲向点位只会变成依次送人头。
const STAGE_Z := 6.0


func _choose_tactic() -> void:
	if actor == null:
		return
	_tactic_timer = 0.0
	# 进攻方按队伍主攻计划分摊: 75% 主攻同一侧, 25% 佯攻另一侧
	if actor.team == GameConfig.Team.STRIKE and match_mgr != null \
			and "round_attack_plan" in match_mgr:
		site_target = match_mgr.round_attack_plan if randf() < 0.75 else _pick_site_position()
	else:
		site_target = _pick_site_position()

	# 携带目标装置的人没有"保枪"这个选项 —— 必须推进到点里。
	# 但它也不该当先锋: 见 _update_carrier_escort()。装置是进攻方唯一的
	# 胜利条件载体, 它的期望存活时间必须是全队最长的。
	if actor.loadout.has_bomb:
		tactic = "rush"
		_site_dwell = 0.0
		set_move_goal(site_target)
		return

	var roll := randf()
	var team_money: int = actor.loadout.money
	var round_no: int = 1
	if match_mgr != null and "round_number" in match_mgr:
		round_no = int(match_mgr.round_number)

	if actor.team == GameConfig.Team.STRIKE:
		# 保枪只在"经济真的崩了"且不是手枪局时才考虑。
		# 原判据 team_money < 1100 在手枪局(800) 必然成立, 于是首回合
		# 20% 的进攻方开局就往后退 —— 手枪局是必打的, 没有保枪这回事。
		if round_no > 1 and team_money < 1000 and roll < 0.18:
			tactic = "save"
		elif roll < 0.42:
			tactic = "rush"
		elif roll < 0.82:
			tactic = "default"
		else:
			tactic = "slow"
	else:
		if round_no > 1 and team_money < 1000 and roll < 0.14:
			tactic = "save"
		elif roll < 0.60:
			tactic = "hold"
		else:
			tactic = "rotate"

	_assign_goal_for_tactic()


## 是否还没到"全队发起时刻"。
## 之前每个 Bot 各自出发、各按各的速度推进, 结果是 5 次 1vN 的添油战术。
## 发起时刻之前全队先推进到前沿集结点等齐, 之后一起压上。
func _before_push() -> bool:
	if match_mgr == null:
		return false
	if not match_mgr.has_method("live_elapsed"):
		return false
	var d: float = 6.0
	if "push_delay" in match_mgr:
		d = float(match_mgr.push_delay)
	return float(match_mgr.call("live_elapsed")) < d


func _assign_goal_for_tactic() -> void:
	if actor == null or waypoints.is_empty():
		return
	var team: int = actor.team

	# 发起时刻之前: 全体进攻方(保枪除外)先到前沿集结点汇合
	if team == GameConfig.Team.STRIKE and tactic != "save" and _before_push():
		var lane: int = randi() % 3
		var x_target: float = [-18.0, 0.0, 18.0][lane]
		set_move_goal(Vector3(x_target, 0, STAGE_Z))
		return

	if team == GameConfig.Team.STRIKE:
		match tactic:
			"rush":
				set_move_goal(site_target)
			"save":
				# 退到己方后方, 但保持移动(而不是杵在原地)
				var back_z: float = 24.0
				set_move_goal(Vector3(clampf(actor.global_position.x, -22.0, 22.0), 0.0, back_z))
				hold_position = move_goal
			_:
				# default / slow: 目标就是炸弹点。
				# 之前这里先设一个 lane 中段的临时目标, 再由 _maybe_advance
				# 2.5 秒后改成点位 —— 那个中间态让 Bot 在 z=5 附近来回振荡。
				set_move_goal(site_target)
	else:
		match tactic:
			"hold":
				# 守在点外围
				var outward: Vector3 = (site_target - Vector3(0, 0, -30)).normalized()
				set_move_goal(site_target - outward * 6.0)
				hold_position = site_target - outward * 6.0
			"save":
				set_move_goal(_nearest_waypoint(actor.global_position))
			_:
				set_move_goal(_nearest_waypoint(Vector3(0, 0, -8)))


func _pick_site_position() -> Vector3:
	var sites := [-20.0, 20.0]
	var idx: int = randi() % 2
	return Vector3(sites[idx], 0, -20.0)


## 视野内最近敌人的距离; 没有可见敌人时返回一个很大的值
func _nearest_visible_enemy_dist() -> float:
	var best: float = INF
	for e in visible_enemies:
		if e == null or not is_instance_valid(e) or not e.alive:
			continue
		var d: float = actor.global_position.distance_to(e.global_position)
		if d < best:
			best = d
	return best


## 目标装置携带者的位置(用于队友跟随掩护)
func _carrier_position() -> Vector3:
	if objective == null or actor == null:
		return Vector3.ZERO
	if not objective.has_method("get_carrier"):
		return Vector3.ZERO
	var c = objective.get_carrier()
	if c == null or not is_instance_valid(c) or c == actor:
		return Vector3.ZERO
	return c.global_position


# ================================================================ 主循环
## 由 Actor 在物理帧开头调用
func poll(delta: float) -> void:
	if not enabled:
		return
	if actor == null or not is_instance_valid(actor) or not actor.alive:
		return

	_perceive_timer -= delta
	if _perceive_timer <= 0.0:
		_perceive_timer = 0.12
		_perceive()

	_tactic_timer += delta
	_grenade_cooldown -= delta
	_update_combat_state(delta)
	_pickup_bomb_if_dropped()
	_maybe_advance(delta)
	_update_carrier_escort(delta)
	_update_aim(delta)
	_navigate(delta)
	_update_fire(delta)
	_update_utility(delta)


# ---------------------------------------------------------------- 携弹者护送
## 携弹者不当先锋 —— 但也绝不能被锁死在点位之外。
##
## 第一版实现(跟在队尾 10m / 自己最靠前就退到 20m)被实测证伪:
## 携带者在 15-20m 处一停就是 44 秒, 一整局零安装。原因是"跟随点"会随着
## 前锋推进而被推得离点位越来越远, 携带者永远到不了 6m 的安装半径。
##
## 现在只保留原始目标, 用"时间"而不是"位置"来表达:
##   * 队里有人比我更靠近点位 -> 正常推进, 不干预
##   * 我是全队最靠前的 -> 原地待命最多 3 秒, 然后照常进点
## 这样既不会第一个撞进交叉火力, 也不会干等到回合结束。
func _update_carrier_escort(delta: float) -> void:
	if actor == null or not actor.loadout.has_bomb:
		return
	if actor.team != GameConfig.Team.STRIKE:
		return
	if combat_state == CombatState.PLANT or combat_state == CombatState.DEFUSE:
		return
	# 已经贴近点位: 交给安装逻辑
	if actor.global_position.distance_to(site_target) <= 9.0:
		_escort_wait = 0.0
		return
	# 集结阶段不干预(全队本来就该一起走)
	if _before_push():
		_escort_wait = 0.0
		return
	if not has_goal:
		return

	# 有没有人顶在我前面
	var d_site: float = actor.global_position.distance_to(site_target)
	var someone_ahead: bool = false
	for other in get_tree().get_nodes_in_group("actors"):
		var o := other as Actor
		if o == null or o == actor or not o.is_inside_tree() or not o.alive:
			continue
		if o.team != actor.team or o.loadout.has_bomb:
			continue
		if o.global_position.distance_to(site_target) < d_site - 3.0:
			someone_ahead = true
			break
	if someone_ahead:
		_escort_wait = 0.0
		return

	# 我是全队最靠前的: 原地待命一小会儿, 让队友先上
	_escort_wait += delta
	if _escort_wait < ESCORT_WAIT_MAX:
		has_goal = false            # 让 _navigate 清空移动输入 -> 站定(交火照常)
		return
	_escort_wait = 0.0
	# 等够了: 再等下去就是干等到回合结束, 自己进
	set_move_goal(site_target)


## 最长原地等待秒数。
## 3 秒 = 一次交火的典型时长; 再长, 进攻方的"窗口期"就过去了,
## 而且携带者站桩本身就是在送(它是最有价值的目标)。
const ESCORT_WAIT_MAX := 3.0


# ---------------------------------------------------------------- 感知
func _perceive() -> void:
	visible_enemies.clear()
	var space := actor.get_world_3d().direct_space_state
	if space == null:
		return

	var eye: Vector3 = actor.get_shoot_origin()
	var facing: Vector3 = actor.get_shoot_direction()
	var fov_cos: float = cos(deg_to_rad(float(_diff["fov"]) * 0.5))

	for other in get_tree().get_nodes_in_group("actors"):
		var e: Actor = other as Actor
		if e == null or e == actor or not e.alive:
			continue
		if e.team == actor.team:
			continue
		var to_e: Vector3 = (e.global_position + Vector3(0, 1.1, 0)) - eye
		var dist: float = to_e.length()
		if dist > 70.0:
			continue
		var dir: Vector3 = to_e.normalized()
		# 视锥判定
		if dir.dot(facing) < fov_cos and dist > 3.0:
			# 视锥外: 只有极近距离才"察觉"
			if dist > 6.0:
				continue
		# 烟雾遮挡
		if GameManager.grenade_manager != null:
			if GameManager.grenade_manager.blocks_line(eye, e.global_position + Vector3(0, 1.1, 0)):
				continue
		# 几何遮挡
		if not _has_clear_line(space, eye, e):
			continue
		visible_enemies.append(e)

	if visible_enemies.is_empty():
		return

	# 选最近的目标
	var best: Actor = null
	var best_dist: float = INF
	for e in visible_enemies:
		var d: float = actor.global_position.distance_to(e.global_position)
		if d < best_dist:
			best_dist = d
			best = e

	if best != target:
		target = best
		_reaction_timer = float(_diff["reaction"]) * randf_range(0.75, 1.35)
	if target != null:
		last_known_enemy_pos = target.global_position
		last_seen_time = Time.get_ticks_msec() / 1000.0


func _has_clear_line(space: PhysicsDirectSpaceState3D, eye: Vector3, e: Actor) -> bool:
	# 三点采样: 头 / 胸 / 腿, 任一可见即判定可见
	var points := [
		e.global_position + Vector3(0, 1.62, 0),
		e.global_position + Vector3(0, 1.15, 0),
		e.global_position + Vector3(0, 0.55, 0),
	]
	for p in points:
		var q := PhysicsRayQueryParameters3D.create(eye, p)
		q.collision_mask = GameConfig.LAYER_WORLD
		q.exclude = [actor]
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return true
	return false


# ---------------------------------------------------------------- 战斗状态
func _update_combat_state(delta: float) -> void:
	if actor == null:
		return

	# 死亡
	if not actor.alive:
		combat_state = CombatState.DEAD
		return

	# 拆除优先
	#
	# 触发半径从 3.0 放宽到 4.5: 真实拆弹是"走到炸弹旁边按住 E",
	# can_defuse() 真正要求的是"人在炸弹点区域里"(BombSite 半径 6.5m),
	# 3m 的距离门槛比区域判定更严, 卡在点边缘的防守方会一直进不了拆除。
	if objective != null and objective.call("is_planted") and actor.team == GameConfig.Team.GUARD:
		var planted_pos: Vector3 = objective.call("get_planted_position")
		if actor.global_position.distance_to(planted_pos) < 4.5:
			combat_state = CombatState.DEFUSE
			return

	# 安装
	#
	# 旧条件: 距点 <6m 且 15m 内无可见敌人。实战中 A/B 点几乎总有防守方,
	# 于是"到了点也永远装不上" —— 探针实测有 2.5% 的采样点卡在这个分支。
	#
	# 现条件(按"有没有人正在看见我"判断, 更接近真人下包逻辑):
	#   * 无可见敌人, 或最近可见敌人 > 10m  -> 立刻装
	#   * 已进点并存活 2 秒, 且最近可见敌人 > 6m -> 赌一把强装
	#     (这是"躲在掩体后下包"的行为; 完全不赌等于进攻方没有胜利条件)
	if actor.loadout.has_bomb and actor.team == GameConfig.Team.STRIKE:
		if actor.global_position.distance_to(site_target) < 6.0:
			_site_dwell += delta
			var nearest: float = _nearest_visible_enemy_dist()
			if nearest > 10.0 or (nearest > 6.0 and _site_dwell > 2.0):
				combat_state = CombatState.PLANT
				return
		else:
			_site_dwell = 0.0
	else:
		_site_dwell = 0.0

	if target != null and target.alive:
		combat_state = CombatState.ENGAGE
	elif Time.get_ticks_msec() / 1000.0 - last_seen_time < 4.0:
		combat_state = CombatState.REPOSITION
	else:
		if tactic == "save":
			combat_state = CombatState.RETREAT
		else:
			combat_state = CombatState.IDLE


# ---------------------------------------------------------------- 瞄准
func _update_aim(delta: float) -> void:
	if actor == null:
		return
	var intent: ActorIntent = actor.intent

	_aim_noise_timer -= delta
	if _aim_noise_timer <= 0.0:
		_aim_noise_timer = randf_range(0.18, 0.45)
		var err: float = float(_diff["aim_error"]) * (1.0 if combat_state == CombatState.ENGAGE else 2.2)
		_aim_noise = Vector2(randf_range(-err, err), randf_range(-err, err))

	var desired_yaw: float = actor.base_yaw
	var desired_pitch: float = actor.base_pitch
	var turn_rate: float = float(_diff["turn_speed"])

	if target != null and target.alive and _reaction_timer <= 0.0:
		var eye: Vector3 = actor.get_shoot_origin()
		var aim_point: Vector3 = target.global_position + Vector3(0, 1.35, 0)
		# 远距离瞄胸, 近距离爆头线
		var dist: float = eye.distance_to(aim_point)
		if dist < 18.0 and randf() < 0.55 / float(_diff["accuracy_mult"] + 0.5):
			aim_point.y = target.global_position.y + 1.66
		# 预判移动
		var lead: float = clampf(dist / 90.0, 0.0, 0.22)
		aim_point += target.velocity * lead

		var dir: Vector3 = (aim_point - eye).normalized()
		# 加入瞄准误差
		dir = _rotate_dir(dir, _aim_noise)

		desired_yaw = atan2(-dir.x, -dir.z)
		desired_pitch = clampf(asin(clampf(dir.y, -1.0, 1.0)),
			-deg_to_rad(GameConfig.MAX_PITCH), deg_to_rad(GameConfig.MAX_PITCH))
		turn_rate *= 1.6
	elif path_index < path.size() and path.size() > 0:
		var next_wp: Vector3 = waypoints[path[path_index]]
		var to_wp: Vector3 = (next_wp - actor.global_position)
		to_wp.y = 0.0
		if to_wp.length_squared() > 0.01:
			var dir: Vector3 = to_wp.normalized()
			desired_yaw = atan2(-dir.x, -dir.z)
			desired_pitch = 0.0
	elif has_goal:
		var to_goal: Vector3 = move_goal - actor.global_position
		to_goal.y = 0.0
		if to_goal.length_squared() > 0.01:
			var dir: Vector3 = to_goal.normalized()
			desired_yaw = atan2(-dir.x, -dir.z)

	actor.base_yaw = _angle_lerp(actor.base_yaw, desired_yaw, turn_rate * delta)
	actor.base_pitch = lerpf(actor.base_pitch, desired_pitch, turn_rate * delta)

	if _reaction_timer > 0.0:
		_reaction_timer -= delta


func _rotate_dir(dir: Vector3, noise: Vector2) -> Vector3:
	var yaw_off: float = deg_to_rad(noise.x)
	var pitch_off: float = deg_to_rad(noise.y)
	return dir.rotated(Vector3.UP, yaw_off).rotated(
		dir.cross(Vector3.UP).normalized(), pitch_off).normalized()


func _angle_lerp(from: float, to: float, t: float) -> float:
	var diff: float = wrapf(to - from, -PI, PI)
	return from + diff * clampf(t, 0.0, 1.0)


# ---------------------------------------------------------------- 导航
## 到达判定半径。默认 2.2m 对"走到某个区域"够用, 但装置拾取是靠
## ObjectiveSystem 里半径 1.1m 的 Area3D 触发的 —— 用 2.2m 的到达半径
## 去走去捡装置, Bot 会在 2.2m 处停下, 永远触发不到拾取。这是"掉落回收 0 次"
## 的第二层原因(第一层是 _am_nearest_to 的判定)。
const ARRIVE_DEFAULT := 2.2
const ARRIVE_PICKUP := 0.75

var _arrive_radius: float = ARRIVE_DEFAULT


func set_move_goal(pos: Vector3, arrive: float = ARRIVE_DEFAULT) -> void:
	move_goal = pos
	_arrive_radius = arrive
	has_goal = true
	_repath_timer = 0.0
	_compute_path()


func _compute_path() -> void:
	if waypoints.is_empty() or actor == null:
		return
	var start_idx: int = _nearest_waypoint_index(actor.global_position)
	var goal_idx: int = _nearest_waypoint_index(move_goal)
	path = _a_star(start_idx, goal_idx)
	path_index = 0
	# 如果目标点比最后一个路点更近, 直接走过去
	if path.is_empty():
		path = [goal_idx]
		path_index = 0


func _a_star(start: int, goal: int) -> Array:
	if start == goal:
		return [goal]
	if not nav_graph.has(start) or not nav_graph.has(goal):
		return [goal]

	var open_set: Array = [start]
	var came_from: Dictionary = {}
	var g_score: Dictionary = {start: 0.0}
	var f_score: Dictionary = {start: _wp_dist(start, goal)}

	var guard: int = 0
	while not open_set.is_empty() and guard < 400:
		guard += 1
		# 取 f 最小
		var current: int = open_set[0]
		var best_f: float = f_score.get(current, INF)
		for n in open_set:
			var fv: float = f_score.get(n, INF)
			if fv < best_f:
				best_f = fv
				current = n
		if current == goal:
			return _reconstruct(came_from, current)

		open_set.erase(current)
		for neighbor in nav_graph.get(current, []):
			var tentative: float = float(g_score.get(current, INF)) + _wp_dist(current, neighbor)
			if tentative < float(g_score.get(neighbor, INF)):
				came_from[neighbor] = current
				g_score[neighbor] = tentative
				f_score[neighbor] = tentative + _wp_dist(neighbor, goal)
				if not open_set.has(neighbor):
					open_set.append(neighbor)

	return _reconstruct(came_from, goal)


func _reconstruct(came_from: Dictionary, current: int) -> Array:
	var total: Array = [current]
	while came_from.has(current):
		current = came_from[current]
		total.insert(0, current)
	return total


func _wp_dist(a: int, b: int) -> float:
	if a < 0 or a >= waypoints.size() or b < 0 or b >= waypoints.size():
		return INF
	return waypoints[a].distance_to(waypoints[b])


func _nearest_waypoint_index(pos: Vector3) -> int:
	var best_i: int = 0
	var best_d: float = INF
	for i in waypoints.size():
		var d: float = waypoints[i].distance_to(pos)
		if d < best_d:
			best_d = d
			best_i = i
	return best_i


func _nearest_waypoint(pos: Vector3) -> Vector3:
	return waypoints[_nearest_waypoint_index(pos)]


func _navigate(delta: float) -> void:
	if actor == null:
		return
	var intent: ActorIntent = actor.intent

	# 站桩射击/安装/拆除时停止移动
	if combat_state == CombatState.PLANT or combat_state == CombatState.DEFUSE:
		intent.move_input = Vector2.ZERO
		intent.crouch = true
		intent.use_held = true
		return

	intent.use_held = false

	if not has_goal:
		intent.move_input = Vector2.ZERO
		return

	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_repath_timer = 1.4
		_compute_path()

	if path.is_empty() or path_index >= path.size():
		# 直接走向目标
		_steer_to(move_goal, delta)
		if actor.global_position.distance_to(move_goal) < _arrive_radius:
			has_goal = false
			intent.move_input = Vector2.ZERO
			_on_goal_reached()
		return

	var wp: Vector3 = waypoints[path[path_index]]
	var dist_to_wp: float = actor.global_position.distance_to(wp)
	if dist_to_wp < 2.4:
		path_index += 1
		if path_index >= path.size():
			_steer_to(move_goal, delta)
			if actor.global_position.distance_to(move_goal) < _arrive_radius:
				has_goal = false
				_on_goal_reached()
			return
		wp = waypoints[path[path_index]]

	_steer_to(wp, delta)
	_check_stuck(delta)


func _steer_to(pos: Vector3, delta: float) -> void:
	var to: Vector3 = pos - actor.global_position
	to.y = 0.0
	if to.length_squared() < 0.02:
		actor.intent.move_input = Vector2.ZERO
		return
	var dir: Vector3 = to.normalized()
	var forward: Vector3 = -actor.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right: Vector3 = actor.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()

	var fwd_amount: float = dir.dot(forward)
	var right_amount: float = dir.dot(right)
	actor.intent.move_input = Vector2(right_amount, fwd_amount).normalized()

	# 战斗中的走位
	if combat_state == CombatState.ENGAGE:
		_strafe_timer -= delta
		if _strafe_timer <= 0.0:
			_strafe_timer = randf_range(0.5, 1.3)
			_strafe_dir = -_strafe_dir if randf() < 0.6 else _strafe_dir

		# 走位方向用"目标点在自身坐标系里的方向"表达, 而不是用当前朝向。
		# 旧实现直接乘 fwd_amount(朝路点方向与朝敌人方向的点积), 于是当
		# 敌人出现在侧面时 fwd_amount 会掉到 0 甚至变负, Bot 就停在原地
		# 或往后跑 —— 而在 hitscan 游戏里静止恰好是命中率最高的姿势,
		# 结果进攻方全队停在开阔地被逐个打死。
		var to_goal: Vector3 = move_goal - actor.global_position
		to_goal.y = 0.0
		var toward := Vector2.ZERO
		if to_goal.length_squared() > 0.01:
			var gn: Vector3 = to_goal.normalized()
			toward = Vector2(gn.dot(right), gn.dot(forward))

		var remain: float = actor.global_position.distance_to(move_goal)
		# 停住射击 / 间隙推进:
		#   正要开火 -> 站定(满精度), 只留小幅横向摆动干扰对方瞄准
		#   不在开火 -> 全速压上(此时扩散再大也无所谓, 反正没开枪)
		var push: float = 0.95
		var lateral: float = 0.30
		if _hold_to_shoot:
			push = 0.12
			lateral = 0.28

		var mv: Vector2 = toward * push + Vector2(_strafe_dir * lateral, 0.0)
		if mv.length() > 1.0:
			mv = mv.normalized()
		actor.intent.move_input = mv

	# 静步与蹲伏策略
	actor.intent.walk = (tactic == "slow" and combat_state != CombatState.ENGAGE)
	actor.intent.crouch = (combat_state == CombatState.ENGAGE and randf() < 0.12)


func _check_stuck(delta: float) -> void:
	var moved: float = actor.global_position.distance_to(_last_pos)
	_last_pos = actor.global_position
	if moved < 0.02 * 60.0 * delta:
		stuck_timer += delta
		if stuck_timer > 0.6:
			stuck_timer = 0.0
			_stuck_count += 1
			# 随机侧移 + 重算路径
			actor.intent.move_input = Vector2(randf_range(-1.0, 1.0), -0.6)
			actor.intent.jump = randf() < 0.3
			_compute_path()
			# 连续卡住说明这条路走不通, 换一个战术目标
			if _stuck_count >= 3:
				_stuck_count = 0
				_choose_tactic()
				_advance_objective()
	else:
		stuck_timer = 0.0
		if moved > 0.25:
			_stuck_count = 0


## 装置掉在地上时, 最近的进攻方队员必须去捡 —— 这是"装置还能不能装上"的关键。
##
## 旧实现有两个致命点:
##   1) _am_nearest_to 要求"比场上每一个存活友军都近 2m"才算最近。只要有一个
##      队友站得稍近一点, 全场就没有人负责回收, 装置一直躺到回合结束。
##   2) 没有距离上限, 也没有优先级 —— 装置掉在 40m 外时最近的 Bot 依然在
##      按自己的战术目标推点。
## 探针实测: 3 回合内装置掉落 2 次, 回收 0 次。
##
## 现在: 只要装置在地上, 且自己是"半径内最近的活着的进攻方", 就放弃一切
## 当前目标去捡。拾取优先于推点、优先于交火 —— 不捡回来就永远没有胜利条件。
func _pickup_bomb_if_dropped() -> void:
	if actor == null or actor.team != GameConfig.Team.STRIKE:
		return
	if actor.loadout.has_bomb:
		return
	if objective == null:
		return
	var dropped: Variant = objective.get("dropped_position")
	if dropped == null or not (dropped is Vector3):
		return
	var drop_pos: Vector3 = dropped
	var my_d: float = actor.global_position.distance_to(drop_pos)
	if my_d > RECOVER_RADIUS:
		return
	if not _am_recovery_owner(drop_pos):
		return
	# 目标变了才重算路径, 避免每帧重规划
	if not has_goal or move_goal.distance_to(drop_pos) > 2.0 \
			or not is_equal_approx(_arrive_radius, ARRIVE_PICKUP):
		set_move_goal(drop_pos, ARRIVE_PICKUP)


## 回收半径: 超过这个距离就不再是"顺手捡一下", 而是全队战略转移,
## 交给最近的队友处理更合理。
const RECOVER_RADIUS := 38.0


## 我是不是"负责去捡装置的那个人"。
## 判据: 在能赶到的人里我最近; 若我正被近距离敌人压制, 让次近的人去。
func _am_recovery_owner(pos: Vector3) -> bool:
	var my_d: float = actor.global_position.distance_to(pos)
	# 我正在近身交火: 脱不开身, 让队友去捡
	if combat_state == CombatState.ENGAGE and target != null and target.alive:
		if actor.global_position.distance_to(target.global_position) < 12.0:
			return false
	for other in get_tree().get_nodes_in_group("actors"):
		var o := other as Actor
		if o == null or o == actor or not o.is_inside_tree() or not o.alive:
			continue
		if o.team != actor.team or o.loadout.has_bomb:
			continue
		if o.global_position.distance_to(pos) < my_d - 1.0:
			return false
	return true


## 抵达目标后不要站着发呆: 隔一会儿继续向前推进
func _maybe_advance(delta: float) -> void:
	if actor == null:
		return
	if has_goal or combat_state == CombatState.ENGAGE:
		return
	if combat_state == CombatState.PLANT or combat_state == CombatState.DEFUSE:
		return
	# 携弹者的目标由 _update_carrier_escort 接管, 不能被这里改掉
	if actor.loadout.has_bomb and actor.team == GameConfig.Team.STRIKE:
		return
	# 装置在地上而我负责回收 —— 回收优先于推点
	if _is_recovering() :
		return
	# 还没到全队发起时刻: 留在集结点, 不要提前一个人冲上去
	if actor.team == GameConfig.Team.STRIKE and _before_push():
		return
	if _tactic_timer < (5.0 if tactic == "save" else 2.5):
		return
	_tactic_timer = 0.0
	if tactic == "save":
		# 保枪: 在己方后方来回换位, 不至于完全静止
		var back_z: float = 24.0 if actor.team == GameConfig.Team.STRIKE else -28.0
		set_move_goal(Vector3(randf_range(-18.0, 18.0), 0.0, back_z + randf_range(-3.0, 3.0)))
		return
	_advance_objective()


## 我此刻是否正负责回收掉落的装置
func _is_recovering() -> bool:
	if actor == null or objective == null:
		return false
	if actor.team != GameConfig.Team.STRIKE or actor.loadout.has_bomb:
		return false
	var dropped: Variant = objective.get("dropped_position")
	if dropped == null or not (dropped is Vector3):
		return false
	return actor.global_position.distance_to(dropped as Vector3) <= RECOVER_RADIUS


func _advance_objective() -> void:
	if actor == null:
		return
	if actor.team == GameConfig.Team.STRIKE:
		# 目标始终是炸弹点, 走哪条路交给 A*。之前按 z 阈值分段推进,
		# Bot 会在阈值线附近来回振荡, 永远走不进点。
		set_move_goal(site_target)
		return

	# ── 防守方 ──
	# 装置已安装: 全员回防, 不再有"55% 去点 / 45% 去中路"的随机游走。
	# 实测 4 次安装全部引爆得分、拆除 0 次, 根因就在这里 —— 炸弹响了
	# 一半防守方还在地图另一头巡逻。回防是防守方唯一的胜利条件。
	if objective != null and objective.call("is_planted"):
		set_move_goal(objective.call("get_planted_position"))
		return

	# 未安装: 回到主防守点, 偶尔前压中路做地图控制
	if randf() < 0.72:
		set_move_goal(site_target)
	else:
		set_move_goal(_nearest_waypoint(Vector3(0.0, 0.0, -12.0)))



func _on_goal_reached() -> void:
	if actor == null:
		return
	if actor.team == GameConfig.Team.STRIKE:
		if actor.loadout.has_bomb:
			# 只有真的站进了点位才进入安装状态。
			# 携弹者的 move_goal 可能是"跟在队友后方 10m"的护送点(见
			# _update_carrier_escort), 那里离点位还很远, 进 PLANT 只会
			# 原地蹲下一秒后立刻被 _update_combat_state 推翻。
			if actor.global_position.distance_to(site_target) < 6.0:
				combat_state = CombatState.PLANT
			else:
				hold_position = actor.global_position
				_tactic_timer = 0.0
		else:
			# 就地警戒
			hold_position = actor.global_position
			_tactic_timer = 0.0
	else:
		hold_position = actor.global_position


# ---------------------------------------------------------------- 开火
func _update_fire(delta: float) -> void:
	if actor == null:
		return
	var intent: ActorIntent = actor.intent
	var ws = actor.weapon_system
	if ws == null:
		return

	# 换弹判定
	var mag: int = ws.ammo_in_mag
	var reserve: int = ws.reserve_ammo
	if mag <= 0 and reserve > 0:
		_hold_to_shoot = false
		intent.reload = true
		intent.fire_held = false
		intent.fire_pressed = false
		return
	if combat_state != CombatState.ENGAGE and mag > 0 and reserve > 0:
		var mag_max: int = int(WeaponDatabase.get_weapon(ws.current_id).get("magazine", 30))
		if mag < mag_max * 0.4:
			intent.reload = true

	if target == null or not target.alive:
		_hold_to_shoot = false
		intent.fire_held = false
		intent.fire_pressed = false
		intent.ads = false
		return
	if _reaction_timer > 0.0:
		_hold_to_shoot = false       # 反应窗口里不该站桩, 继续接近
		intent.fire_held = false
		intent.fire_pressed = false
		intent.ads = true
		return

	# 是否真的对准目标
	var eye: Vector3 = actor.get_shoot_origin()
	var to_target: Vector3 = (target.global_position + Vector3(0, 1.2, 0) - eye).normalized()
	var facing: Vector3 = actor.get_shoot_direction()
	var alignment: float = facing.dot(to_target)
	var dist: float = eye.distance_to(target.global_position)

	# 超出有效交战距离就别开枪(泼水只会暴露位置并浪费子弹)
	var wclass: String = str(WeaponDatabase.get_weapon(ws.current_id).get("class", "rifle"))
	var max_engage: float = 42.0
	match wclass:
		"pistol": max_engage = 26.0
		"smg": max_engage = 30.0
		"shotgun": max_engage = 12.0
		"sniper": max_engage = 70.0
	if dist > max_engage:
		_hold_to_shoot = false       # 打不着: 别傻站, 继续接近
		intent.fire_held = false
		intent.fire_pressed = false
		intent.ads = true
		return

	# ADS 策略:
	#   步枪/狙击 -> 全程开镜。AR 的腰射扩散是 3.4°, 在 10m 处是 0.6m 半径
	#   的散布圆, 打不中 0.6m 宽的躯干 —— 旧实现"dist > 14 才开镜"等于
	#   让 Bot 在 14m 内用腰射对枪, 而那正是交火最密集的距离。
	#   冲锋枪/霰弹 -> 12m 内腰射(开镜收益低, 且贴身需要视野)。
	var can_ads: bool = bool(WeaponDatabase.get_weapon(ws.current_id).get("can_ads", false))
	if wclass == "smg" or wclass == "shotgun":
		intent.ads = can_ads and dist > 12.0
	else:
		intent.ads = can_ads

	# 开火串: 按"发"计数。
	# WeaponSystem.shot_count 在停火 0.28s 后归零, 所以 shot_count 回落
	# 说明这一串已经结束, 计数器同步清零。
	var sc: int = int(ws.shot_count)
	if sc > _last_shot_count:
		_burst_shots += (sc - _last_shot_count)
	elif sc < _last_shot_count:
		_burst_shots = 0
	_last_shot_count = sc

	if _burst_pause > 0.0:
		_burst_pause -= delta
		_hold_to_shoot = false       # 换弹/歇气间隙: 推进
		intent.fire_held = false
		intent.fire_pressed = false
		return

	# 对准了才开火(避免乱扫)。
	# 旧门限 6° + aim_error: 配合 ±aim_error 的瞄准噪声, Bot 会在目标
	# 明明没对准时照样扣扳机。射速提高后放宽门限只会更浪费弹药。
	var tolerance: float = cos(deg_to_rad(4.0 + float(_diff["aim_error"]) * 0.7))
	if alignment > tolerance:
		if _burst_shots >= _burst_len:
			# 这串打完了: 进入停火间隙, 并重掷下一串长度
			_burst_shots = 0
			_burst_len = randi_range(int(_diff["burst_min"]), int(_diff["burst_max"]))
			_burst_pause = randf_range(0.18, 0.55)
			_hold_to_shoot = false
			intent.fire_held = false
			intent.fire_pressed = false
			return
		# 正要开火: 站住, 把扩散压到最低
		_hold_to_shoot = true
		var mode: String = str(WeaponDatabase.get_weapon(ws.current_id).get("fire_mode", "auto"))
		if mode == "auto":
			intent.fire_held = true
			intent.fire_pressed = false
		else:
			intent.fire_held = false
			intent.fire_pressed = true
	else:
		# 没对准: 一边转枪一边继续接近, 别站着挨打
		_hold_to_shoot = false
		intent.fire_held = false
		intent.fire_pressed = false


# ---------------------------------------------------------------- 道具
func _update_utility(delta: float) -> void:
	if actor == null or _grenade_cooldown > 0.0:
		return
	if actor.loadout.grenades.is_empty():
		return

	# 进攻方压到点位附近 -> 往点里砸烟雾。
	# 不只给携弹者: 烟雾是进攻方进入点位唯一稳定的"遮蔽手段", 也是给
	# 安装创造窗口的手段。整个进攻队都应该参与。
	# 面向点位再投 —— 烟雾沿视线方向飞, 朝别处扔等于浪费。
	if actor.team == GameConfig.Team.STRIKE:
		var to_site: Vector3 = site_target - actor.global_position
		to_site.y = 0.0
		if to_site.length() < 26.0 and not _before_push():
			var fwd2: Vector3 = -actor.global_transform.basis.z
			fwd2.y = 0.0
			if fwd2.length() > 0.1 and fwd2.normalized().dot(to_site.normalized()) > 0.55:
				for g in actor.loadout.grenades:
					if str(WeaponDatabase.get_grenade(str(g["id"])).get("kind", "")) == "smoke":
						actor.intent.throw_grenade = str(g["id"])
						_grenade_cooldown = 30.0
						return

	if combat_state != CombatState.ENGAGE and combat_state != CombatState.REPOSITION:
		return
	if randf() > float(_diff["grenade_chance"]) * 0.02:
		return

	var g: Dictionary = actor.loadout.grenades[randi() % actor.loadout.grenades.size()]
	var gid: String = str(g["id"])
	var kind: String = str(WeaponDatabase.get_grenade(gid).get("kind", "he"))

	# 只在合理情形使用
	if kind == "he" and target != null and target.alive:
		actor.intent.throw_grenade = gid
		_grenade_cooldown = 8.0
	elif kind == "flash" and combat_state == CombatState.ENGAGE:
		actor.intent.throw_grenade = gid
		_grenade_cooldown = 10.0
	elif kind == "smoke" and combat_state == CombatState.REPOSITION:
		actor.intent.throw_grenade = gid
		_grenade_cooldown = 14.0
	elif kind == "molotov" and target != null:
		actor.intent.throw_grenade = gid
		_grenade_cooldown = 16.0
