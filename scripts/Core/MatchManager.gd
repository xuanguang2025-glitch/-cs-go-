extends Node3D
class_name MatchManager
##
## MatchManager.gd — 比赛主状态机
##
## 回合流程:
##   BUY(15s, 可购买) -> LIVE(115s, 战斗) -> ROUND_OVER(4s, 结算) -> BUY ...
##   第 13 回合开始交换攻守; 常规先到 13 分; 12:12 进入加时(先到 16 分, 每 3 回合换边)
##
## 胜负判定:
##   歼灭 / 引爆 / 拆除 / 时间耗尽
##   注意: 炸弹已安装后, 进攻方全灭不立即判负 —— 防守方仍需拆弹,
##         否则炸弹爆炸进攻方依然获胜(与经典竞技规则一致)。
##

enum Phase { WARMUP, BUY, LIVE, ROUND_OVER, HALFTIME, MATCH_OVER }

var phase: int = Phase.WARMUP
var round_number: int = 1
var score: Dictionary = {
	GameConfig.Team.STRIKE: 0,
	GameConfig.Team.GUARD: 0,
}
var phase_timer: float = 0.0
var round_time_remaining: float = GameConfig.ROUND_TIME
var overtime: bool = false
var win_target: int = GameConfig.WIN_ROUNDS

var actors: Array = []
var bot_controllers: Array = []
var local_player: Actor = null
var player_controller: PlayerController = null

var map_root: Node3D = null
var map_data: Dictionary = {}
var sites: Array = []
var waypoints: Array = []
var nav_graph: Dictionary = {}

var economy: EconomyManager = null
var objective: ObjectiveSystem = null
var spectator: SpectatorSystem = null
var fx: FXManager = null
var hit_system: HitSystem = null
var sound: Node = null

## 专用服务器的 Bot 数量。默认 9（带 Bot 的模拟服务器）。
## 传 --bots 0 即纯观察者模式: 场上一个 Bot 都没有, 停在 WARMUP
## 等玩家连进来, 两边各够 warmup_min_per_team 人才开赛。
var dedicated_bot_count: int = 9
## 开赛所需每队最少人数
var warmup_min_per_team: int = 1
## 是否需要热身等待（Bot 不足以自行开局时为真）
var _needs_warmup: bool = false
var _warmup_tick: float = 0.0

## 每个角色的本局统计: actor -> {kills, deaths, assists, damage}
var player_stats: Dictionary = {}

## 本回合进攻方主攻点。Bot 依据它分摊主攻/佯攻, 避免 5 人各选各的点。
var round_attack_plan: Vector3 = Vector3(-20.0, 0.0, -20.0)

## 本回合进攻方"全队发起时刻"(LIVE 开始后多少秒)。
##
## 为什么需要它: 5 个人各自出发、各自以不同速度推进, 结果是 5 次 1vN 的
## 添油战术 —— 每个人都被集火打死, 而且都是死在半路上。真实竞技里进攻方
## 会先占住前沿集结点, 等队友到位再一起压。这个变量就是"等队友"的时间。
## 前半段全队推进到集结点, 到点后一起进点, 交火就变成 5v2 而不是 1v5。
var push_delay: float = 6.0

## 训练场模式: 无回合推进 / 假人自动复活 / 弹药无限
var training_mode: bool = false
## 训练场: 上一发是否尚未判定命中(用于连击统计)
var _training_shot_pending: bool = false
var moving_targets: Array = []
var _respawn_queue: Array = []

## 联机: 客户端从服务器快照同步的比赛状态(供 HUD 读取)
var _client_phase_name: String = ""
var _client_time_text: String = ""

var configured: bool = false
var _pending_map_id: String = "project_zero"
var _pending_bots: int = 9
var _pending_team: int = GameConfig.Team.STRIKE
var _round_end_reason: String = ""
var _last_round_winner: int = -1
var _bomb_was_planted: bool = false
var _stats_this_round: Dictionary = {}
## 本局结束时唯一一次段位结算结果，供结算画面只读展示。
## 避免 MatchResult 重复调用 report_match_result 导致 MMR 被结算两次。
var final_rank_result: Dictionary = {}


# ================================================================ 初始化
func _ready() -> void:
	name = "MatchManager"
	set_process(true)
	GameManager.match_manager = self
	_setup_systems()
	_build_map()
	# 客户端不创建本地角色 —— 角色由服务器广播生成(assign_local 指定本地角色)
	if not NetworkManager.is_client:
		_build_actors()
	_connect_signals()
	if NetworkManager.is_server:
		_net_setup()
	if NetworkManager.is_client:
		# 客户端: 地图照建, 角色等服务器广播生成, 不跑本地状态机
		phase = Phase.LIVE
		round_time_remaining = 99999.0
		EventBus.announcement.emit("已连接服务器", "info")
		return

	# 人数不足（典型场景: 纯观察者服务器, 一个 Bot 都没有）时进热身等待,
	# 不启动回合状态机 —— 否则双方存活数都是 0, 会立刻判平局并空转回合。
	if _warmup_needed():
		_enter_warmup()
		return

	if not training_mode:
		ReplaySystem.start_recording(_pending_map_id)
	if configured:
		start_match_internal()
	else:
		call_deferred("start_match_internal")


## 两边是否都有足够的人开赛
func _warmup_needed() -> bool:
	if training_mode:
		return false
	return (_team_size(GameConfig.Team.STRIKE) < warmup_min_per_team
		or _team_size(GameConfig.Team.GUARD) < warmup_min_per_team)


func _team_size(team: int) -> int:
	var c: int = 0
	for a in actors:
		if a.team == team:
			c += 1
	return c


## 热身: 世界照常运转, 但不推进回合。人够了自动开赛。
func _enter_warmup() -> void:
	_needs_warmup = true
	phase = Phase.WARMUP
	round_time_remaining = 99999.0
	_spawn_all()
	objective.reset_round(actors)
	for a in actors:
		a.loadout.reset_for_new_match(GameConfig.START_MONEY)
		a.loadout.setup_starting_pistol()
	EventBus.announcement.emit("等待玩家加入", "info")
	GameManager.log_line("热身等待中: %d 人 (每队至少 %d 人开赛)" % [
		actors.size(), warmup_min_per_team])


## 热身中有人加入/离开后重新判定
func _warmup_recheck() -> void:
	if phase != Phase.WARMUP:
		return
	if _warmup_needed():
		return
	_needs_warmup = false
	GameManager.log_line("人数足够, 开始比赛 (%d 人)" % actors.size())
	EventBus.announcement.emit("比赛开始", "go")
	if not training_mode:
		ReplaySystem.start_recording(_pending_map_id)
	start_match_internal()


func _setup_systems() -> void:
	fx = FXManager.new()
	fx.name = "FX"
	add_child(fx)
	GameManager.fx = fx

	sound = load("res://scripts/Audio/SoundManager.gd").new()
	sound.name = "Sound"
	add_child(sound)
	sound.call("_ensure_bus")
	GameManager.sound_manager = sound

	hit_system = HitSystem.new()
	hit_system.name = "HitSystem"
	hit_system.fx = fx
	hit_system.sound = sound
	hit_system.friendly_fire = false
	add_child(hit_system)
	GameManager.hit_system = hit_system

	var gm := GrenadeManager.new()
	gm.name = "GrenadeManager"
	add_child(gm)

	objective = ObjectiveSystem.new()
	objective.name = "ObjectiveSystem"
	objective.fx = fx
	objective.sound = sound
	add_child(objective)

	economy = EconomyManager.new()
	economy.name = "EconomyManager"
	add_child(economy)

	spectator = SpectatorSystem.new()
	spectator.name = "SpectatorSystem"
	add_child(spectator)
	GameManager.spectator = spectator


func configure(map_id: String, bot_count: int, player_team: int) -> void:
	_pending_map_id = map_id
	training_mode = map_id == "training_range"
	if training_mode:
		_pending_bots = 0
	_pending_bots = bot_count
	_pending_team = player_team
	configured = true


func _build_map() -> void:
	map_data = MapBuilder.build(_pending_map_id)
	map_root = map_data["root"]
	add_child(map_root)
	sites = map_data["sites"]
	waypoints = map_data["waypoints"]
	objective.setup(sites)
	# 导航图需要物理世界就绪
	call_deferred("_build_nav")


func _build_nav() -> void:
	var world := get_world_3d()
	if world == null:
		push_warning("[MatchManager] get_world_3d() 为空, 导航图未生成")
		return
	if world.direct_space_state == null:
		push_warning("[MatchManager] direct_space_state 为空, 导航图未生成")
		return
	nav_graph = MapBuilder.build_nav_graph(waypoints, world)
	var edges: int = 0
	for k in nav_graph:
		edges += nav_graph[k].size()
	GameManager.log_line("导航图: %d 节点 / %d 条边" % [nav_graph.size(), edges / 2])
	for b in bot_controllers:
		b.nav_graph = nav_graph


func _build_actors() -> void:
	# 专用服务器: 不创建本地玩家(纯观察), 只生成 Bot 供连接的客户端对战。
	# Bot 数量由 --bots N 控制, 0 = 纯观察者模式(停在 WARMUP 等玩家)。
	if NetworkManager.dedicated_server:
		var n: int = clampi(dedicated_bot_count, 0, 10)
		for i in n:
			var half: int = i % 2
			var t: int = GameConfig.Team.STRIKE if half == 0 else GameConfig.Team.GUARD
			var dn: String = "BOT-%02d" % (i + 1)
			var a := _make_actor(dn, t, true)
			_make_bot(a)
		return
	# 本地玩家
	local_player = _make_actor(GameManager.player_name, _pending_team, false)
	local_player.is_local = true
	local_player.mouse_sensitivity = float(GameManager.get_setting("mouse_sensitivity", 1.0))
	player_controller = PlayerController.new()
	player_controller.name = "PlayerController"
	local_player.add_controller(player_controller)
	player_controller.setup(local_player)
	GameManager.local_player = local_player

	# _pending_bots 是 Bot 总数(玩家 + Bot = 10 人)。
	# 优先把玩家所在队伍补满 5 人, 剩下的全部作为对手。
	# 训练场允许 0 个 Bot(假人单独生成)
	var total_bots: int = 0 if training_mode else clampi(_pending_bots, 1, 9)
	var teammate_count: int = 0 if training_mode else mini(4, total_bots)
	var enemy_count: int = 0 if training_mode else clampi(total_bots - teammate_count, 1, 5)

	# 队友 Bot
	for i in teammate_count:
		var a := _make_actor("ALLY-%02d" % (i + 1), _pending_team, true)
		_make_bot(a)
	# 敌方 Bot
	for i in enemy_count:
		var a2 := _make_actor("ENEMY-%02d" % (i + 1), GameConfig.opponent(_pending_team), true)
		_make_bot(a2)

	# 训练场: 用无 AI 的假人当靶子(静态 + 移动), 追加在敌方队列之后
	if training_mode:
		_build_training_targets()


## 网络远端角色: 由服务器创建, 不挂本地控制器
func spawn_network_actor(net_id: int, display_name: String, team: int) -> Actor:
	var a := _make_actor(display_name, team, true)
	a.name = "NET-%d" % net_id
	return a


## 服务器: 比赛开始后广播所有 Bot; 之后加入的 peer 走 _on_net_peer_joined
func _net_setup() -> void:
	NetworkManager.peer_joined.connect(_on_net_peer_joined)
	NetworkManager.peer_left.connect(_on_net_peer_left)
	var nid: int = 1000
	for a in actors:
		if a == local_player:
			continue
		NetworkManager.net_actors[nid] = a
		a.set_meta("net_id", nid)
		NetworkManager.broadcast_spawn(nid, a.actor_name, a.team, a.global_position)
		NetworkManager.broadcast_loadout(nid, a.loadout)
		nid += 1


func _on_net_peer_joined(peer_id: int) -> void:
	if not NetworkManager.is_server:
		return
	# 把对局里已有的角色(Bot 等)也下发给新加入者, 否则晚加入的玩家看不到 Bot
	for a in actors:
		if a.has_meta("net_id"):
			NetworkManager.broadcast_spawn(
				int(a.get_meta("net_id")), a.actor_name, a.team, a.global_position)
	var base_team: int = local_player.team if local_player != null else _pending_team
	# 加入者进入人少的一边
	var strike_n: int = 0
	var guard_n: int = 0
	for a in actors:
		if a.team == GameConfig.Team.STRIKE: strike_n += 1
		else: guard_n += 1
	var team: int = GameConfig.Team.STRIKE if strike_n <= guard_n else GameConfig.Team.GUARD
	var a := spawn_network_actor(peer_id, "PLAYER-%d" % (peer_id % 1000), team)
	var spawns: Array = map_data["spawn_strike"] if team == GameConfig.Team.STRIKE else map_data["spawn_guard"]
	var sp: Vector3 = spawns[peer_id % spawns.size()]
	a.spawn_at(sp + Vector3(0, 0.1, 0), PI if team == GameConfig.Team.STRIKE else 0.0)
	NetworkManager.net_actors[peer_id] = a
	a.set_meta("net_id", peer_id)
	NetworkManager.broadcast_spawn(peer_id, a.actor_name, team, sp)
	NetworkManager.broadcast_loadout(peer_id, a.loadout)
	NetworkManager.assign_local(peer_id)
	EventBus.announcement.emit("玩家加入对局", "info")
	# 纯观察者服务器: 人够了就开赛
	if phase == Phase.WARMUP:
		_warmup_recheck()


func _on_net_peer_left(peer_id: int) -> void:
	var a: Actor = NetworkManager.net_actors.get(peer_id)
	if a != null and is_instance_valid(a):
		a.queue_free()
		actors.erase(a)
		player_stats.erase(a)
	NetworkManager.net_actors.erase(peer_id)


## 服务器每帧: 反作弊移动校验
func _net_server_checks() -> void:
	if not NetworkManager.is_server:
		return
	for a in actors:
		if a.is_bot:
			continue
		NetworkManager.server_check_move(a)
	# 维护位置历史, 供 Lag Compensation 回溯
	NetworkManager.record_history(actors)


## 生成训练假人: 不挂 controller, 完全静止(或由 _training_tick 驱动移动)
func _build_training_targets() -> void:
	var idx: int = 0
	for pos in MapBuilder.TARGET_STATIC:
		var d := _make_actor("TARGET-%d" % (idx + 1), GameConfig.opponent(_pending_team), true)
		d.set_physics_process(false)
		d.set_meta("home", pos)
		idx += 1
	for track in MapBuilder.TARGET_MOVING:
		var m := _make_actor("MOVING-%d" % (idx + 1), GameConfig.opponent(_pending_team), true)
		m.set_physics_process(false)
		m.set_meta("home", track[0])
		m.set_meta("track", track)
		m.set_meta("phase", randf() * TAU)
		moving_targets.append(m)
		idx += 1


func _make_actor(display_name: String, team: int, is_bot: bool) -> Actor:
	var a := Actor.new()
	a.name = display_name
	a.actor_name = display_name
	a.team = team
	a.is_bot = is_bot
	a.is_local = not is_bot
	add_child(a)
	actors.append(a)
	player_stats[a] = {"kills": 0, "deaths": 0, "assists": 0, "damage": 0.0}
	# 配装一变(买枪/发枪)就广播给所有客户端 —— 客户端 HUD 弹药的唯一来源
	a.loadout.weapon_changed.connect(_on_actor_loadout_changed.bind(a))
	if a.weapon_system != null:
		a.weapon_system.fx = fx
		a.weapon_system.hit_system = hit_system
		a.weapon_system.sound = sound
		a.weapon_system.base_fov = float(GameManager.get_setting("fov", 90.0))
	return a


## 服务器: 角色配装变化 -> 广播(仅对已分配 net_id 的角色)
func _on_actor_loadout_changed(_slot: String, _wid: String, actor: Node) -> void:
	if not NetworkManager.is_server:
		return
	if not actor.has_meta("net_id"):
		return
	NetworkManager.broadcast_loadout(int(actor.get_meta("net_id")), actor.loadout)


## 服务器: 回合复活后全员配装各广播一遍(补弹匣/补备弹不会触发 weapon_changed)
func _broadcast_all_loadouts() -> void:
	if not NetworkManager.is_server:
		return
	for a in actors:
		if a.has_meta("net_id"):
			NetworkManager.broadcast_loadout(int(a.get_meta("net_id")), a.loadout)


## 服务器: 处理客户端上行购买请求(BuyMenu 在客户端只是转发, 不改本地数据)
func apply_network_purchase(actor: Node, kind: String, payload: String) -> void:
	if not NetworkManager.is_server or actor == null:
		return
	var lo: Loadout = actor.loadout
	var ok := false
	match kind:
		"weapon":
			ok = lo.buy_weapon(payload)
		"grenade":
			ok = lo.buy_grenade(payload)
		"armor":
			ok = lo.buy_armor(payload == "heavy")
			if ok:
				actor.health.armor = lo.armor
				actor.health.has_helmet = lo.has_helmet
				actor.health.has_kevlar = true
		"kit":
			ok = lo.buy_defuse_kit()
		"ammo":
			ok = lo.buy_ammo()
	if not ok:
		# 静默拒绝: 客户端 UI 状态随下一次配装广播自然校正
		return
	if actor.has_meta("net_id"):
		NetworkManager.broadcast_loadout(int(actor.get_meta("net_id")), lo)


func _make_bot(a: Actor) -> BotController:
	var bot := BotController.new()
	bot.name = "BotController"
	bot.difficulty = GameManager.bot_difficulty
	bot.setup(a, waypoints, nav_graph, objective, self)
	a.add_controller(bot)
	bot_controllers.append(bot)
	return bot


func _connect_signals() -> void:
	EventBus.bomb_exploded.connect(func(): _end_round(GameConfig.Team.STRIKE, "bomb"))
	EventBus.bomb_defused.connect(func(_defuser): _end_round(GameConfig.Team.GUARD, "defuse"))
	EventBus.player_died.connect(_on_player_died)
	EventBus.hit_confirmed.connect(_on_hit_confirmed)


# ================================================================ 比赛流程
func start_match_internal() -> void:
	final_rank_result = {}
	if training_mode:
		_start_training()
		return
	round_number = 1
	score[GameConfig.Team.STRIKE] = 0
	score[GameConfig.Team.GUARD] = 0
	overtime = false
	win_target = GameConfig.WIN_ROUNDS
	economy.reset_match()
	for a in actors:
		a.loadout.reset_for_new_match(GameConfig.START_MONEY)
		a.loadout.setup_starting_pistol()
	_start_round()


func _start_training() -> void:
	SteamManager.unlock_achievement(SteamManager.ACH_TRAINING)
	GameManager.reset_training_session()
	round_number = 1
	phase = Phase.LIVE
	round_time_remaining = 99999.0
	for a in actors:
		var home: Vector3 = a.get_meta("home", Vector3(0, 0.1, 5)) if a.has_meta("home") else Vector3(0, 0.1, 5)
		var yaw: float = 0.0
		if a == local_player:
			home = Vector3(0, 0.1, 5)
			yaw = 0.0
		a.loadout.reset_for_new_match(GameConfig.START_MONEY)
		a.loadout.setup_starting_pistol()
		a.spawn_at(home + Vector3(0, 0.1, 0), yaw)
		if a.weapon_system != null:
			a.weapon_system.reset_for_round()
	if player_controller != null:
		player_controller.set_capture(true)
		player_controller.reset_pending()
	EventBus.announcement.emit("训练场 - 自由射击 (B 可换枪)", "info")


func _start_round() -> void:
	_bomb_was_planted = false
	# 70% 概率主攻计划点, Bot 内部再按个人随机佯攻另一个点
	round_attack_plan = Vector3([-20.0, 20.0][randi() % 2], 0.0, -20.0)
	# 全队发起时刻: 4~8 秒。给足时间让 5 个人都走到前沿集结点,
	# 再一起压上去 —— 这是把"添油战术"改成"集团推进"的唯一开关。
	push_delay = randf_range(4.0, 8.0)
	_stats_this_round = {"kills": 0, "damage": 0.0}
	round_time_remaining = GameConfig.ROUND_TIME

	# 半场/加时换边
	_check_side_swap()

	# 生成
	_spawn_all()

	# 分配目标装置
	objective.reset_round(actors)

	# Bot 自动购买
	for b in bot_controllers:
		b.on_round_start()
		_bot_auto_buy(b.actor)

	# 本地玩家补满弹药
	for a in actors:
		if not a.is_bot:
			a.loadout.refill_for_new_round()

	# 补弹匣/买枪都不会对客户端可见 —— 回合开始时全员配装广播一遍
	_broadcast_all_loadouts()

	phase = Phase.BUY
	phase_timer = GameConfig.BUY_TIME
	EventBus.round_started.emit(round_number)
	EventBus.round_state_changed.emit(phase, round_number)
	EventBus.announcement.emit("第 %d 回合 - 购买阶段" % round_number, "round")


func _spawn_all() -> void:
	var sp_strike: Array = map_data["spawn_strike"]
	var sp_guard: Array = map_data["spawn_guard"]
	var i_strike: int = 0
	var i_guard: int = 0

	for a in actors:
		var pos: Vector3
		var yaw: float
		if a.team == GameConfig.Team.STRIKE:
			pos = sp_strike[i_strike % sp_strike.size()]
			i_strike += 1
			yaw = PI          # 面朝 -Z(北侧)
		else:
			pos = sp_guard[i_guard % sp_guard.size()]
			i_guard += 1
			yaw = 0.0         # 面朝 +Z(南侧)
		a.spawn_at(pos + Vector3(randf_range(-0.8, 0.8), 0.05, randf_range(-0.8, 0.8)), yaw)
		if a.weapon_system != null:
			a.weapon_system.reset_for_round()

	# 本地玩家恢复相机
	if local_player != null:
		var cam := local_player.get_camera()
		if cam != null:
			cam.make_current()
		if player_controller != null:
			player_controller.set_capture(true)
			player_controller.reset_pending()
	spectator.stop()


func _check_side_swap() -> void:
	if overtime:
		# 加时赛每 3 回合换边
		if round_number > 1 and ((round_number - GameConfig.MAX_ROUNDS - 1) % GameConfig.OT_ROUNDS_PER_SIDE == 0):
			_swap_sides()
		return
	if round_number == GameConfig.HALF_ROUNDS + 1:
		_swap_sides()
		EventBus.halftime_reached.emit()
		EventBus.announcement.emit("半场交换攻守", "halftime")


func _swap_sides() -> void:
	for a in actors:
		a.call("set_team", GameConfig.opponent(a.team))


# ================================================================ 每帧
func _process(delta: float) -> void:
	if NetworkManager.is_server:
		_net_server_checks()
	if NetworkManager.is_server and Engine.get_process_frames() % 30 == 0:
		NetworkManager.broadcast_match_state(round_number,
			score[GameConfig.Team.STRIKE], score[GameConfig.Team.GUARD],
			get_phase_name(), get_round_time_text())
	if training_mode:
		_training_tick(delta)
		_handle_interactions()
		return
	_handle_interactions()
	match phase:
		Phase.WARMUP:
			# 世界正常运转(能跑能打), 只是不推进回合。
			# 玩家从网络加入后由 _on_net_peer_joined 触发 _warmup_recheck。
			_refresh_warmup_actors(delta)
		Phase.BUY:
			phase_timer -= delta
			if phase_timer <= 0.0:
				phase = Phase.LIVE
				EventBus.round_state_changed.emit(phase, round_number)
				EventBus.freezetime_ended.emit()
				EventBus.announcement.emit("战斗开始", "go")
		Phase.LIVE:
			round_time_remaining -= delta
			if objective.is_planted():
				phase = Phase.LIVE   # 时间由炸弹接管
			elif round_time_remaining <= 0.0:
				_end_round(GameConfig.Team.GUARD, "time")
			else:
				_check_alive_condition()
		Phase.ROUND_OVER:
			phase_timer -= delta
			if phase_timer <= 0.0:
				_advance_round()
		Phase.MATCH_OVER:
			pass


## 热身期: 让角色自由活动, 死掉的重生, 并周期性重判是否可以开赛
func _refresh_warmup_actors(delta: float) -> void:
	_warmup_tick += delta
	for a in actors:
		if not a.alive:
			a.spawn_at(a.get_meta("home", Vector3(0, 0.1, 5)), 0.0)
	# 每 0.5 秒重判一次, 不用每帧算
	if _warmup_tick >= 0.5:
		_warmup_tick = 0.0
		if not _warmup_needed():
			_warmup_recheck()


func _training_tick(delta: float) -> void:
	# 移动靶巡逻
	var t: float = Time.get_ticks_msec() / 1000.0
	for m in moving_targets:
		if not is_instance_valid(m) or not m.alive:
			continue
		var track: Array = m.get_meta("track")
		var ph: float = float(m.get_meta("phase"))
		var k: float = (sin(t * 1.1 + ph) + 1.0) * 0.5
		m.global_position = track[0].lerp(track[1], k) + Vector3(0, 0.05, 0)
		m.rotation.y = PI * 0.5 if cos(t * 1.1 + ph) > 0.0 else -PI * 0.5
	# 复活队列
	var now: int = Time.get_ticks_msec()
	for entry in _respawn_queue.duplicate():
		if now >= int(entry["time"]):
			_respawn_queue.erase(entry)
			var a: Actor = entry["actor"]
			if is_instance_valid(a):
				var home: Vector3 = a.get_meta("home", Vector3(0, 0.1, 5)) if a.has_meta("home") else Vector3(0, 0.1, 5)
				a.spawn_at(home + Vector3(0, 0.1, 0), 0.0)
				if a.weapon_system != null:
					a.weapon_system.reset_for_round()


## 统一处理"按住交互键"的安装 / 拆除请求(玩家与 Bot 走同一条路径)
func _handle_interactions() -> void:
	if phase != Phase.BUY and phase != Phase.LIVE:
		return
	for a in actors:
		var actor: Actor = a as Actor
		if actor == null or not actor.alive:
			continue
		if not actor.intent.use_held:
			if actor.is_planting:
				objective.abort_plant()
			if actor.is_defusing:
				objective.abort_defuse()
			continue
		if actor.team == GameConfig.Team.STRIKE:
			if not actor.is_planting and objective.can_plant(actor):
				objective.begin_plant(actor)
		elif actor.team == GameConfig.Team.GUARD:
			if not actor.is_defusing and objective.can_defuse(actor):
				objective.begin_defuse(actor)


func _check_alive_condition() -> void:
	var strike_alive: int = _alive_count(GameConfig.Team.STRIKE)
	var guard_alive: int = _alive_count(GameConfig.Team.GUARD)

	if strike_alive == 0 and guard_alive == 0:
		_end_round(GameConfig.Team.GUARD, "draw")
	elif strike_alive == 0:
		_end_round(GameConfig.Team.GUARD, "elimination")
	elif guard_alive == 0:
		_end_round(GameConfig.Team.STRIKE, "elimination")


func _alive_count(team: int) -> int:
	var c: int = 0
	for a in actors:
		if a.team == team and a.alive:
			c += 1
	return c


# ================================================================ 回合结束
func _end_round(winner: int, reason: String) -> void:
	if phase == Phase.ROUND_OVER or phase == Phase.MATCH_OVER:
		return
	phase = Phase.ROUND_OVER
	phase_timer = GameConfig.ROUND_END_PAUSE
	_round_end_reason = reason
	_last_round_winner = winner
	_bomb_was_planted = objective.is_planted() or reason == "bomb"

	if reason != "draw":
		score[winner] += 1
		economy.award_round(winner, reason, _bomb_was_planted)

	# 拆除奖励
	if reason == "defuse":
		var defuser := objective.defuser
		if defuser != null:
			economy.award_defuse(defuser)

	EventBus.round_ended.emit(winner, reason)
	EventBus.score_changed.emit(score[GameConfig.Team.STRIKE], score[GameConfig.Team.GUARD])
	EventBus.round_state_changed.emit(phase, round_number)

	var win_name: String = GameConfig.team_name(winner)
	EventBus.announcement.emit("%s 拿下本回合 (%s)" % [win_name, _reason_text(reason)], "round_end")


func _reason_text(reason: String) -> String:
	match reason:
		"bomb": return "装置引爆"
		"defuse": return "装置拆除"
		"time": return "时间耗尽"
		"draw": return "同归于尽"
		_: return "歼灭对手"


func _advance_round() -> void:
	# 比赛结束判定
	var s_strike: int = score[GameConfig.Team.STRIKE]
	var s_guard: int = score[GameConfig.Team.GUARD]

	if not overtime:
		if s_strike >= win_target or s_guard >= win_target:
			_finish_match(s_strike >= win_target)
			return
		if s_strike == GameConfig.HALF_ROUNDS and s_guard == GameConfig.HALF_ROUNDS:
			# 12:12 进入加时
			overtime = true
			win_target = GameConfig.HALF_ROUNDS + 4   # 先到 16
			EventBus.announcement.emit("12:12 进入加时赛", "overtime")
	else:
		if s_strike >= win_target or s_guard >= win_target:
			_finish_match(s_strike >= win_target)
			return

	round_number += 1
	_start_round()


func _finish_match(strike_won: bool) -> void:
	phase = Phase.MATCH_OVER
	var winner: int = GameConfig.Team.STRIKE if strike_won else GameConfig.Team.GUARD
	EventBus.match_ended.emit(winner, score[GameConfig.Team.STRIKE], score[GameConfig.Team.GUARD])
	EventBus.announcement.emit("%s 赢得比赛" % GameConfig.team_name(winner), "match_end")

	var i_won: bool = local_player != null and local_player.team == winner
	if i_won:
		GameManager.record_stat("wins")
		SteamManager.unlock_achievement(SteamManager.ACH_FIRST_WIN)
	else:
		GameManager.record_stat("losses")
	# 录像收尾存档
	if ReplaySystem.recording:
		ReplaySystem.stop_recording()
		var path: String = ReplaySystem.save_replay()
		if path != "":
			GameManager.log_line("录像已保存: " + path)
	# 段位结算(客户端不做, 服务器统一结算后下发; 第一阶段本地直接算)
	if not NetworkManager.is_client:
		final_rank_result = RankSystem.report_match_result(i_won)
		EventBus.announcement.emit("MMR %+d  ·  %s" % [int(final_rank_result["delta"]), str(final_rank_result["tier"])], "rank")
		if RankSystem.tier_index() >= 2:
			SteamManager.unlock_achievement(SteamManager.ACH_RANK)

	# 6 秒后返回主菜单
	await get_tree().create_timer(6.0).timeout
	if is_instance_valid(self):
		GameManager.return_to_menu()


# ================================================================ 事件
func _on_player_died(victim: Node, killer: Node, weapon_id: String, is_headshot: bool) -> void:
	var v := victim as Actor
	var k := killer as Actor
	if v == null:
		return

	ReplaySystem.add_event("kill", {"killer": k.actor_name if k != null else "",
		"victim": v.actor_name, "weapon": weapon_id, "hs": is_headshot})
	# 训练场: 一切从简, 2.5 秒后原地复活
	if training_mode:
		var home: Vector3 = v.get_meta("home", Vector3(0, 0.1, 5)) if v.has_meta("home") else Vector3(0, 0.1, 5)
		_respawn_queue.append({"actor": v, "time": Time.get_ticks_msec() + 2500})
		return

	# 击杀奖励
	if k != null and k != v and k.team != v.team:
		economy.award_kill(k, weapon_id)
		_incr_stat(k, "kills", 1)
		if v.is_local:
			GameManager.record_stat("deaths")
		if k.is_local:
			GameManager.record_stat("kills")
			SteamManager.unlock_achievement(SteamManager.ACH_FIRST_KILL)
			if is_headshot:
				GameManager.record_stat("headshots")
				SteamManager.unlock_achievement(SteamManager.ACH_HEADSHOT)
	_incr_stat(v, "deaths", 1)

	EventBus.killfeed_request.emit(
		k.actor_name if k != null else "世界",
		v.actor_name, weapon_id, is_headshot,
		k.team if k != null else -1, v.team)

	# 装置掉落由 Actor 内部处理
	if v == local_player:
		spectator.start(v, actors)
	elif spectator.enabled and spectator.target == v:
		spectator.next_target()

	# 安装/拆除中断
	if v.is_planting:
		objective.abort_plant()
	if v.is_defusing:
		objective.abort_defuse()


func _on_hit_confirmed(attacker: Node, _victim: Node, damage: float, _is_hs: bool, _killed: bool) -> void:
	var a := attacker as Actor
	if a != null:
		_incr_stat(a, "damage", damage)
	if attacker == local_player:
		GameManager.record_stat("hits")
		GameManager.record_stat("damage", damage)
		if training_mode:
			GameManager.training_hit()
			_training_shot_pending = false


func record_shot() -> void:
	GameManager.record_stat("shots")
	if training_mode:
		# 上一发若仍未命中, 判定为空枪并重置连击
		if _training_shot_pending:
			GameManager.training_miss()
		_training_shot_pending = true


func _incr_stat(actor: Actor, key: String, amount: float) -> void:
	if actor == null or not player_stats.has(actor):
		return
	player_stats[actor][key] = float(player_stats[actor].get(key, 0.0)) + amount


func get_actor_stats(actor: Actor) -> Dictionary:
	if not player_stats.has(actor):
		return {"kills": 0, "deaths": 0, "assists": 0, "damage": 0.0}
	return player_stats[actor]


# ================================================================ Bot 购买
func _bot_auto_buy(bot: Actor) -> void:
	if bot == null:
		return
	var lo := bot.loadout
	var money: int = lo.money
	var pistol: String = WeaponDatabase.get_starting_pistol(bot.team)

	# 手枪局保底: 买甲 +  upgraded pistol
	if money < 2200:
		if money >= 650 and lo.get_slot_weapon("secondary") == pistol:
			lo.buy_weapon("viper")
		if money >= 400:
			lo.buy_armor(false)
		if money >= 500:
			lo.buy_grenade("flash")
		return

	# 强起 / 半买
	if money < 4200:
		lo.buy_armor(false)
		if money >= 3000:
			lo.buy_weapon(["raptor9", "specter", "vector_x"][randi() % 3])
		elif money >= 2000:
			lo.buy_weapon("bulldog")
		lo.buy_grenade("flash")
		return

	# 全买
	lo.buy_armor(true)
	var rifle: String = ["ar17", "falcon", "r42", "titan"][randi() % 4]
	if randf() < 0.18:
		rifle = ["longshot", "m90", "vega"][randi() % 3]
	elif randf() < 0.12:
		rifle = ["atlas", "cyclone"][randi() % 2]
	lo.buy_weapon(rifle)

	if bot.team == GameConfig.Team.GUARD:
		lo.buy_defuse_kit()
	for g in ["flash", "smoke", "he"]:
		if randf() < 0.7:
			lo.buy_grenade(g)
	lo.buy_ammo()


# ================================================================ 查询
func get_score() -> Vector2i:
	return Vector2i(score[GameConfig.Team.STRIKE], score[GameConfig.Team.GUARD])


func get_phase_name() -> String:
	if NetworkManager.is_client and _client_phase_name != "":
		return _client_phase_name
	match phase:
		Phase.WARMUP: return "热身等待"
		Phase.BUY: return "购买阶段"
		Phase.LIVE: return "进行中"
		Phase.ROUND_OVER: return "回合结束"
		Phase.MATCH_OVER: return "比赛结束"
		_: return "准备"


func is_buy_phase() -> bool:
	return phase == Phase.BUY


## 本回合 LIVE 阶段已进行的秒数(购买阶段返回 0)。
## 装置已安装后时间由炸弹接管, 此时沿用最后的取值。
func live_elapsed() -> float:
	if training_mode:
		return 0.0
	return maxf(GameConfig.ROUND_TIME - round_time_remaining, 0.0)


func get_round_time_text() -> String:
	# 训练场无时限: round_time_remaining 不会初始化, 格式化出来会是一个
	# 毫无意义的巨大哨兵值(如 1666:39), 直接显示 --:--
	if training_mode:
		return "--:--"
	if NetworkManager.is_client and _client_time_text != "":
		return _client_time_text
	var t: int = maxi(int(round_time_remaining), 0)
	return "%d:%02d" % [t / 60, t % 60]


func get_bomb_time_text() -> String:
	var t: float = objective.get_bomb_timer()
	return "%.1f" % t


func get_alive_counts() -> Vector2i:
	return Vector2i(_alive_count(GameConfig.Team.STRIKE), _alive_count(GameConfig.Team.GUARD))
