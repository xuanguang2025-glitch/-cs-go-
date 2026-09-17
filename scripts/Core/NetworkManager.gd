extends Node
##
## NetworkManager.gd — 网络层(Autoload): ENet 服务器权威模型
##
## 架构(提示词 25-26 条):
##   * 服务器运行完整模拟(与单机同一套 Actor/WeaponSystem/HitSystem 代码)
##   * 客户端只上行输入意图, 不上报伤害 —— 命中/伤害全部由服务器判定
##   * 客户端的本地角色做"预测 + 快照校正"(简化版 Client Prediction +
##     Server Reconciliation): 本地立即模拟, 收到服务器快照后向权威位置收敛
##   * 远端角色纯快照驱动(30Hz 插值由 Actor 本身的渲染帧平滑承担)
##
## 启动方式:
##   局域网建房  : 主菜单 -> 建立主机 (host_game)
##   加入游戏    : 主菜单 -> 加入 (join_game "127.0.0.1")
##   专用服务器  : Godot.exe --headless -- --server   (占位角色版, 见 73 条说明)
##

signal server_started(port: int)
signal join_succeeded()
signal join_failed(reason: String)
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal server_closed()

const DEFAULT_PORT := 24565
const MAX_PEERS := 10
const SNAPSHOT_HZ := 30.0

## peer_id -> 输入缓冲(RemoteController 消费)
var _input_buffers: Dictionary = {}
## peer_id -> Actor(服务器侧; 客户端侧是所有远端 actor)
var net_actors: Dictionary = {}
## 本地客户端自己的 peer id(服务器上恒为 1)
var my_peer_id: int = 1

var is_server: bool = false
var is_client: bool = false
var dedicated_server: bool = false
var active: bool = false

var _snapshot_accum: float = 0.0
var _anti_cheat: AntiCheat = null

## 断线自动重连(5 分钟窗口)
var reconnect_enabled: bool = false
var _reconnect_ip: String = ""
var _reconnect_port: int = DEFAULT_PORT
var _reconnect_until_ms: int = 0
var _reconnect_next_ms: int = 0
const RECONNECT_WINDOW_MS := 5 * 60 * 1000
const RECONNECT_RETRY_MS := 3000


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_anti_cheat = AntiCheat.new()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _process(delta: float) -> void:
	# 断线重连
	if reconnect_enabled and not active and not is_server:
		var now: int = Time.get_ticks_msec()
		if now >= _reconnect_until_ms:
			reconnect_enabled = false
			join_failed.emit("重连超时")
			return
		if now >= _reconnect_next_ms:
			_reconnect_next_ms = now + RECONNECT_RETRY_MS
			join_game(_reconnect_ip, _reconnect_port)
	if not active:
		return
	# 服务器: 定时广播快照
	if is_server:
		_snapshot_accum += delta
		if _snapshot_accum >= 1.0 / SNAPSHOT_HZ:
			_snapshot_accum = 0.0
			_broadcast_snapshot()


# ================================================================ 连接管理
func host_game(port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PEERS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_server = true
	is_client = false
	dedicated_server = false
	active = true
	my_peer_id = 1
	server_started.emit(port)
	return OK


func host_dedicated(port: int = DEFAULT_PORT) -> Error:
	var err := host_game(port)
	if err == OK:
		dedicated_server = true
	return err


## 客户端: 启用断线自动重连(5 分钟窗口)
func enable_reconnect(ip: String, port: int) -> void:
	reconnect_enabled = true
	_reconnect_ip = ip
	_reconnect_port = port


func disable_reconnect() -> void:
	reconnect_enabled = false


func join_game(ip: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_server = false
	is_client = true
	dedicated_server = false
	active = true
	return OK


func close() -> void:
	if multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_server = false
	is_client = false
	dedicated_server = false
	active = false
	_input_buffers.clear()
	net_actors.clear()
	server_closed.emit()


func is_online() -> bool:
	return active


func connection_summary() -> String:
	if is_server:
		return "服务器 · %d 客户端" % multiplayer.get_peers().size()
	if is_client:
		return "客户端 · 已连接" if active else "客户端 · 连接中"
	return "离线"


func peer_count() -> int:
	if is_server:
		return multiplayer.get_peers().size() + 1
	if is_client:
		return net_actors.size() + 1 if active else 0
	return 0


func _on_peer_connected(peer_id: int) -> void:
	if not is_server:
		return
	peer_joined.emit(peer_id)
	# 服务器通知所有客户端: 这个 peer 的角色信息由 MatchManager 创建后广播
	_notify_spawn_all.rpc_id(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_input_buffers.erase(peer_id)
	peer_left.emit(peer_id)


func _on_connected() -> void:
	my_peer_id = multiplayer.get_unique_id()
	join_succeeded.emit()


func _on_connect_failed() -> void:
	join_failed.emit("无法连接到服务器")
	active = false


func _on_server_disconnected() -> void:
	active = false
	net_actors.clear()
	LagComp.clear()
	server_closed.emit()
	# 客户端: 自动重连(5 分钟窗口, 每 3 秒重试)
	if reconnect_enabled:
		_reconnect_until_ms = Time.get_ticks_msec() + RECONNECT_WINDOW_MS
		_reconnect_next_ms = Time.get_ticks_msec() + 1000
		EventBus.announcement.emit("与服务器断开, 正在尝试重连...", "warn")
	else:
		join_failed.emit("与服务器断开连接")


# ================================================================ 输入上行
## 输入缓冲(服务器侧按 peer 存储; 客户端侧不需要)
func get_or_create_input_buffer(peer_id: int) -> Dictionary:
	if not _input_buffers.has(peer_id):
		_input_buffers[peer_id] = {}
	return _input_buffers[peer_id]


## 客户端每物理帧调用: 把本地意图打包上行
func send_intent(intent: ActorIntent) -> void:
	if not is_client:
		return
	var buttons: int = 0
	if intent.jump: buttons |= 1
	if intent.crouch: buttons |= 2
	if intent.walk: buttons |= 4
	if intent.fire_held: buttons |= 8
	if intent.fire_pressed: buttons |= 16
	if intent.ads: buttons |= 32
	if intent.reload: buttons |= 64
	if intent.use_held: buttons |= 128
	_submit_intent.rpc_id(1, intent.move_input, intent.look_delta, buttons,
		intent.switch_slot)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _submit_intent(move: Vector2, look: Vector2, buttons: int,
		switch_slot: int) -> void:
	if not is_server:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var buf := get_or_create_input_buffer(sender)
	buf["move"] = move
	buf["look"] = look
	buf["crouch"] = (buttons & 2) != 0
	buf["walk"] = (buttons & 4) != 0
	buf["jump"] = (buttons & 1) != 0
	buf["fire_held"] = (buttons & 8) != 0
	buf["fire_pressed"] = (buttons & 16) != 0
	buf["ads"] = (buttons & 32) != 0
	buf["reload"] = (buttons & 64) != 0
	buf["use"] = (buttons & 128) != 0
	buf["switch"] = switch_slot


# ================================================================ 角色生成同步
## 服务器: peer 加入后由 MatchManager 调用 —— 请求所有端创建该 peer 的角色
func broadcast_spawn(net_id: int, display_name: String, team: int, home: Vector3) -> void:
	for p in _active_peers():
		_do_spawn.rpc_id(p, net_id, display_name, team, home)


## 活跃 peer 列表(只含 SceneMultiplayer 认可的 peer)。
## 全体 .rpc() 广播会遍历 ENet 底层轮询到的 peer(含客户端断线后的残影),
## 残影触发 enet "!peers.has(p_id)" 错误刷屏; 遍历 get_peers() 定向发送天然规避,
## 且无客户端时返回空列表, 调用方零开销。
func _active_peers() -> Array:
	return multiplayer.get_peers()


@rpc("authority", "call_remote", "reliable")
func _do_spawn(net_id: int, display_name: String, team: int, home: Vector3) -> void:
	if multiplayer.get_unique_id() == 1:
		return   # 服务器自己已在本侧创建
	if GameConfig == null or GameManager == null:
		return
	var mm = GameManager.match_manager
	if mm == null or net_actors.has(net_id):
		return
	var a: Actor = mm.call("spawn_network_actor", net_id, display_name, team)
	if a == null:
		return
	a.global_position = home
	a.force_update_transform()
	# 该角色是否属于"我"? 服务器随后会下发 assign_local
	net_actors[net_id] = a


## 服务器: 告诉某客户端"你操控的角色是 net_id"
func assign_local(net_id: int) -> void:
	_do_assign_local.rpc_id(net_id, net_id, my_peer_id)


@rpc("authority", "call_remote", "reliable")
func _do_assign_local(net_id: int, _server_id: int) -> void:
	if multiplayer.get_unique_id() == 1:
		return
	var a: Actor = net_actors.get(net_id)
	if a == null:
		return
	# 把这个快照驱动的角色转为本地预测角色
	a.is_local = true
	var pc := PlayerController.new()
	pc.name = "PlayerController"
	a.add_controller(pc)
	pc.setup(a)
	GameManager.local_player = a
	var mm = GameManager.match_manager
	if mm != null:
		mm.set("local_player", a)
	# HUD 重绑到本地角色
	if GameManager.hud != null and mm != null:
		GameManager.hud.call("setup", a, mm, mm.get("objective"))
	# 配装广播可能在 assign_local 之前到达(可靠信道保序但当时还不是
	# 本地角色, 没刷新武器系统) —— 这里补一次, HUD 弹药/持枪立刻正确
	if a.weapon_system != null:
		a.weapon_system.call("refresh_weapons")


@rpc("authority", "call_remote", "reliable")
func _notify_spawn_all() -> void:
	# 客户端连上后, 服务器会把已有角色逐个重新广播(由 MatchManager 处理)
	pass


# ================================================================ 快照下行
func _broadcast_snapshot() -> void:
	if net_actors.is_empty():
		return
	var snap: Array = []
	for net_id in net_actors:
		var a: Actor = net_actors[net_id]
		if a == null or not is_instance_valid(a):
			continue
		snap.append([
			net_id,
			a.global_position,
			a.base_yaw,
			a.base_pitch,
			a.health.health,
			a.health.armor,
			a.alive,
		])
	# 逐 peer 定向发送, 不用 .rpc() 全体广播:
	# 1) 没有客户端时直接跳过(单机房主 30Hz 白发);
	# 2) ENet 残影 peer(客户端被杀后未超时清理)会让全体广播打出
	#    "!peers.has(p_id)" 噪音; get_peers() 只含 SceneMultiplayer 认可的
	#    活跃 peer, 是 ENet peer_map 的子集, 定向发送永远不会踩到残影。
	var peers: Array = multiplayer.get_peers()
	if peers.is_empty():
		return
	for p in peers:
		_receive_snapshot.rpc_id(p, snap)


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_snapshot(snap: Array) -> void:
	if not is_client:
		return
	var mm = GameManager.match_manager
	if mm == null:
		return
	for entry in snap:
		var net_id: int = int(entry[0])
		var a: Actor = net_actors.get(net_id)
		if a == null or not is_instance_valid(a):
			continue
		var pos: Vector3 = entry[1]
		a.base_yaw = float(entry[2])
		a.base_pitch = float(entry[3])
		a.health.health = float(entry[4])
		a.health.armor = int(entry[5])
		if bool(entry[6]) != a.alive:
			# 生死状态以服务器为准
			a.alive = bool(entry[6])
			a.visible = a.alive

		if a.is_local:
			# 本地预测角色: 向权威位置收敛(简化版 reconciliation)
			var err: Vector3 = pos - a.global_position
			if err.length() > 6.0:
				a.global_position = pos       # 大偏差直接对齐(传送/复活)
			else:
				a.global_position += err * 0.25
		else:
			# 远端角色: 快照驱动 + 渲染帧平滑
			a.global_position = a.global_position.lerp(pos, 0.5)


## 客户端: 比赛状态同步(比分/阶段/回合)
func broadcast_match_state(round_number: int, s_strike: int, s_guard: int,
		phase_name: String, time_text: String) -> void:
	# 与快照同理: 逐活跃 peer 定向发送, 无 peer 直接跳过, 规避残影噪音
	var peers: Array = multiplayer.get_peers()
	if peers.is_empty():
		return
	for p in peers:
		_receive_match_state.rpc_id(p, round_number, s_strike, s_guard,
			phase_name, time_text)


@rpc("authority", "call_remote", "reliable")
func _receive_match_state(round_number: int, s_strike: int, s_guard: int,
		phase_name: String, time_text: String) -> void:
	if not is_client:
		return
	var mm = GameManager.match_manager
	if mm == null:
		return
	mm.set("round_number", round_number)
	mm.score[GameConfig.Team.STRIKE] = s_strike
	mm.score[GameConfig.Team.GUARD] = s_guard
	mm.set("_client_phase_name", phase_name)
	mm.set("_client_time_text", time_text)
	EventBus.score_changed.emit(s_strike, s_guard)


# ================================================================ 配装同步
## 服务器: 广播某角色的完整配装(金钱 + 三槽武器 + 弹药)。
## 触发点(MatchManager): 加入 / 回合复活 / 服务器侧任何成功购买。
## 客户端本地角色的 HUD 弹药、金钱、持枪模型全靠这条消息。
func broadcast_loadout(net_id: int, lo: Loadout) -> void:
	var data: Array = []
	for slot in Loadout.SLOT_KEY:
		var wid: String = lo.get_slot_weapon(slot)
		data.append([slot, wid,
			lo.get_mag(wid) if wid != "" else 0,
			lo.get_reserve(wid) if wid != "" else 0])
	for p in _active_peers():
		_receive_loadout.rpc_id(p, net_id, lo.money, data)


@rpc("authority", "call_remote", "reliable")
func _receive_loadout(net_id: int, money: int, data: Array) -> void:
	if multiplayer.get_unique_id() == 1:
		return
	var a: Actor = net_actors.get(net_id)
	if a == null or not is_instance_valid(a):
		return
	var lo: Loadout = a.loadout
	if lo == null:
		return
	for entry in data:
		var slot: String = str(entry[0])
		var wid: String = str(entry[1])
		if wid == "":
			continue
		lo.weapons[slot] = wid
		lo.set_mag(wid, int(entry[2]))
		lo.set_reserve(wid, int(entry[3]))
		# 补发本地信号: BuyMenu 刷新按钮状态、Actor 更新第三人称持枪模型
		lo.weapon_changed.emit(slot, wid)
	if lo.money != money:
		lo.money = money
		lo.money_changed.emit(money)
	# 只刷新本地角色: 远端角色刷新会把第一人称 viewmodel 置为可见,
	# 在其他玩家身边渲染出一把"漂浮的枪"
	if a.is_local and a.weapon_system != null:
		a.weapon_system.call("refresh_weapons")


# ================================================================ 购买请求
## 客户端: 买任何东西都上行给服务器, 由服务器权威结算后经
## broadcast_loadout 回发结果 —— 客户端直接改本地 loadout 是假购买,
## 服务器权威角色根本拿不到枪。
func request_purchase(kind: String, payload: String) -> void:
	_request_purchase.rpc_id(1, kind, payload)


@rpc("any_peer", "call_remote", "reliable")
func _request_purchase(kind: String, payload: String) -> void:
	if not is_server:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	var mm = GameManager.match_manager
	if mm == null:
		return
	var a: Actor = net_actors.get(sender)
	if a == null or not is_instance_valid(a):
		return
	mm.call("apply_network_purchase", a, kind, payload)


# ================================================================ 反作弊钩子
## 服务器: 移动结果提交前校验
func server_check_move(actor: Actor) -> void:
	if not is_server or actor == null:
		return
	if not _anti_cheat.validate_move(actor, actor.global_position, 1.0 / 128.0):
		var last: Dictionary = _anti_cheat._last_valid.get(actor, {})
		if not last.is_empty():
			actor.global_position = last["pos"]


## 估算某角色的回溯量(ms): RTT/2 + 插值缓冲(30Hz 快照约 33ms)
## 主机本地玩家/训练模式/单机一律返回 0 —— 不需要回溯
func estimate_rewind_for(actor: Actor) -> float:
	if not is_server or actor == null:
		return 0.0
	var nid: int = int(actor.get_meta("net_id", -1))
	# 只有真正连线的客户端 peer 才查 RTT; 机器人/主机本地角色虽然有 net_id,
	# 但不在 ENet peer_map 里, get_peer() 会打出 "!peers.has(p_id)" 错误刷屏。
	# 机器人由服务器权威模拟, 射击本来就不需要回溯。
	if nid <= 1 or not multiplayer.get_peers().has(nid):
		return 0.0
	var peer = multiplayer.multiplayer_peer
	if peer != null and peer.has_method("get_peer"):
		var p = peer.call("get_peer", nid)
		if p != null and p.has_method("get_statistic"):
			var rtt: float = float(p.call("get_statistic", ENetPacketPeer.PEER_ROUND_TRIP_TIME))
			if rtt > 0.0:
				return clampf(rtt * 0.5 + 33.0, 0.0, LagComp.MAX_REWIND_MS)
	# 拿不到 RTT 时用保守估计
	return 50.0


## 服务器: 记录位置历史(供 Lag Compensation 回溯)
func record_history(actors: Array) -> void:
	if not is_server:
		return
	var now: float = Time.get_ticks_msec()
	for a in actors:
		LagComp.record(a, now)


## 服务器: 射速校验
func server_check_fire(last_shot_ms: int, fire_interval: float) -> bool:
	if not is_server:
		return true
	return _anti_cheat.validate_fire(last_shot_ms, fire_interval)
