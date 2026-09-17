extends Node
##
## BombTraceProbe.gd — 装置链路诊断 / 攻防平衡测试台
##
## 用法:
##   Godot441_console.exe --headless res://scenes/Dev/BombTraceProbe.tscn \
##       -- --map project_zero --rounds 2 [--aionly] \
##          [--difficulty <0|1|2>] [--max-seconds <秒>]
##
## --difficulty <N>: Bot 难度档, 0=简单 / 1=普通 / 2=困难。超出范围会被
##                   自动夹到 0..2(传 9 等价于 2), 不会崩。不传则沿用
##                   GameManager.bot_difficulty 的默认值 1(普通)。
##                   ⚠ 时序: 该字段必须在 Game.tscn 被加载【之前】写进
##                   GameManager —— MatchManager._make_bot() 是在生成 Bot 时
##                   才去读它(MatchManager.gd:451)。本探针的参数解析就放在
##                   load("res://scenes/Game.tscn") 之前, 不要往下挪。
## --max-seconds <F>: 墙钟超时上限, 默认 900 秒(原 const MAX_SECONDS)。低于
##                   1 秒会被夹到 1 秒。简单难度回合普遍更长, 12 回合长跑很容易
##                   撞上 900s 就被截断、样本作废, 此时必须显式调大。
##
## 三档难度基线(必须同口径对比) 示例:
##   简单 0: ... --map project_zero --rounds 12 --aionly --difficulty 0 --max-seconds 2400
##   普通 1: ... --map project_zero --rounds 12 --aionly --difficulty 1 --max-seconds 1800
##   困难 2: ... --map project_zero --rounds 12 --aionly --difficulty 2 --max-seconds 1800
##
## ⚠ 运行前必须显式设置 APPDATA 指向真实用户目录, 否则 Godot 会退回项目内
##   的 ./Godot 相对数据目录, 在仓库里写出 190MB+ 的引擎数据。
##
## --aionly: 走 dedicated_server 路径启动 —— 只有 10 个 Bot(5v5), 没有本地玩家、
##           没有 HUD。这是唯一能拿到"纯净 AI 对局"的方式: 本地玩家若在场,
##           它会是一个永不移动也永不死亡的木桩, 导致每回合都靠计时结束,
##           回合结束原因完全失真。
##
## 输出(全部可量化, 用于改动前后同口径对比):
##   [1] 携带者状态归因   —— 每 0.1s 归类一次"装置为什么没装上"
##   [2] 携带者最近推进距离 —— 本回合携带者距离目标点最近到过多少米
##   [3] 装置掉落回收     —— 掉了几次、平均多久被捡回、几次没人捡
##   [4] 回合结果分布     —— bomb / defuse / elimination / time
##   [5] 攻防胜率
##   [6] 命中率
##

const SAMPLE_INTERVAL := 0.1
## 每 2 秒打一行存活数时间线 —— 用来看"回合是被什么终结的":
## 如果 alive 数在几秒内同时归零, 说明是集团接火;
## 如果是缓慢此消彼长, 说明是逐个击破。
const REPORT_EVERY := 256
const MAX_SECONDS := 900.0
var _max_seconds: float = MAX_SECONDS   # 可被 --max-seconds 覆盖(默认仍 900s)

var mm: Node = null
var game_root: Node = null
var elapsed: float = 0.0
var _sample_accum: float = 0.0
var _frames: int = 0
var _target_rounds: int = 2
var _map_id: String = "project_zero"
var _ai_only: bool = false
var _finished: bool = false
var _booted: bool = false

# 携带者状态桶(互斥)
var bucket := {
	"no_bomb": 0, "dead": 0, "far": 0,
	"suppressed": 0, "planting": 0, "planted": 0,
}
var carrier_samples: int = 0
var dist_hist: Dictionary = {}

# 每回合指标
var _round_seen: int = 0
var _carrier_min_dist: Dictionary = {}      # round -> 最近距离
var _round_plants: int = 0
var _plants: int = 0
var _defuses: int = 0
var _round_result: Dictionary = {}          # reason -> count
var _wins := {0: 0, 1: 0}                   # team -> wins
var _rounds_played: int = 0

# 装置掉落回收
var _device_on_ground: bool = false
var _drop_time: float = 0.0
var _drops: int = 0
var _unrecovered: int = 0
var _pickup_latency: Array = []

# 命中
var _shots: int = 0
var _hits: int = 0

# 存活时长
var alive_time: Dictionary = {}


func _ready() -> void:
	print("=".repeat(70))
	print("PROJECT STRIKE — 装置链路诊断 / 攻防平衡测试台")
	print("=".repeat(70))

	var uargs := OS.get_cmdline_user_args()
	for i in uargs.size():
		if uargs[i] == "--map" and i + 1 < uargs.size():
			_map_id = uargs[i + 1]
		elif uargs[i] == "--rounds" and i + 1 < uargs.size():
			_target_rounds = int(uargs[i + 1])
		elif uargs[i] == "--aionly":
			_ai_only = true
		elif uargs[i] == "--difficulty" and i + 1 < uargs.size():
			# 必须在这里就写入 GameManager: MatchManager._make_bot() 在 Bot
			# 生成时才读这个字段(MatchManager.gd:451), 而 Bot 是在 Game.tscn
			# 加载之后才生成的。所以参数解析必须留在 load() 之前, 不要下移。
			GameManager.bot_difficulty = clampi(int(uargs[i + 1]), 0, 2)
		elif uargs[i] == "--max-seconds" and i + 1 < uargs.size():
			_max_seconds = maxf(float(uargs[i + 1]), 1.0)

	# 纯 AI 对局: 走专用服务器分支(无本地玩家 / 无 UI)
	if _ai_only:
		NetworkManager.dedicated_server = true

	GameManager.pending_match = {
		"map_id": _map_id, "bot_count": 9, "team": GameConfig.Team.STRIKE,
	}
	# 纯 AI 模式走专用服务器分支, Bot 数量由 dedicated_bots 决定。
	# 必须是偶数(10)才能得到真正的 5v5 —— 9 个会分出一个 5v4 的不对称对局。
	if _ai_only:
		GameManager.pending_match["dedicated_bots"] = 10
	var packed := load("res://scenes/Game.tscn") as PackedScene
	if packed == null:
		print("[FAIL] Game.tscn 加载失败")
		get_tree().quit(1)
		return
	game_root = packed.instantiate()
	add_child(game_root)
	mm = game_root.get_node_or_null("MatchManager")
	if mm == null:
		print("[FAIL] MatchManager 缺失")
		get_tree().quit(1)
		return

	if not _ai_only and mm.player_controller != null:
		# 非纯净模式: 关掉本地玩家输入, 它退化成木桩(回合结束原因会失真)
		mm.player_controller.enabled = false

	print("模式     : %s" % ("纯 AI (5v5, 无本地玩家)" if _ai_only else "含本地木桩"))
	print("地图     : %s" % _map_id)
	print("角色总数 : %d  |  Bot: %d  |  难度档: %d" % [
		mm.actors.size(), mm.bot_controllers.size(), GameManager.bot_difficulty])
	# 把实际生效的运行参数打出来, 避免"以为传了参数但其实没生效"这类静默失败
	print("回合上限 : %d  |  超时上限: %.0f 秒" % [_target_rounds, _max_seconds])
	print("炸弹点   : %d" % mm.sites.size())

	EventBus.bomb_planted.connect(func(_s, _p): _plants += 1; _round_plants += 1)
	EventBus.bomb_defused.connect(func(_d): _defuses += 1)
	EventBus.round_ended.connect(_on_round_ended)
	EventBus.weapon_fired.connect(func(_a, _w): _shots += 1)
	EventBus.hit_confirmed.connect(func(_a, _v, _d, _h, _k): _hits += 1)

	var obj = mm.objective
	if obj != null:
		obj.device_dropped.connect(_on_device_dropped)
	EventBus.bomb_carrier_changed.connect(_on_carrier_changed)

	for a in mm.actors:
		alive_time[a.actor_name] = 0.0

	_round_seen = mm.round_number
	_booted = true


func _on_device_dropped(_pos: Vector3) -> void:
	_device_on_ground = true
	_drop_time = elapsed
	_drops += 1


func _on_carrier_changed(carrier) -> void:
	if carrier != null and _device_on_ground:
		_device_on_ground = false
		_pickup_latency.append(elapsed - _drop_time)


func _on_round_ended(winner: int, reason: String) -> void:
	_round_result[reason] = int(_round_result.get(reason, 0)) + 1
	_rounds_played += 1
	if _wins.has(winner):
		_wins[winner] = int(_wins[winner]) + 1
	if _device_on_ground:
		_unrecovered += 1
		_device_on_ground = false
	# 目标回路: 携带者停在场地上但装置仍在地上 -> 记为"未回收"(上面已处理)
	_round_plants = 0


func _process(delta: float) -> void:
	if not _booted or _finished or mm == null or not is_instance_valid(mm):
		return
	_frames += 1
	elapsed += delta

	for a in mm.actors:
		if a != null and is_instance_valid(a) and a.alive:
			alive_time[a.actor_name] = float(alive_time.get(a.actor_name, 0.0)) + delta

	if mm.round_number != _round_seen:
		_round_seen = mm.round_number

	_sample_accum += delta
	if _sample_accum >= SAMPLE_INTERVAL:
		_sample_accum = 0.0
		_sample()

	if _frames % REPORT_EVERY == 0:
		_live_report()

	if mm.round_number > _target_rounds or elapsed > _max_seconds:
		_finish()


func _carrier():
	var obj = mm.objective
	if obj == null:
		return null
	var c = obj.get_carrier()
	if c != null and is_instance_valid(c) and c.alive:
		return c
	return null


func _sample() -> void:
	var obj = mm.objective
	if obj == null:
		return

	if obj.call("is_planted"):
		bucket["planted"] += 1
		carrier_samples += 1
		return

	var carrier = obj.get_carrier()
	if carrier == null or not is_instance_valid(carrier):
		bucket["no_bomb"] += 1
		carrier_samples += 1
		return

	carrier_samples += 1
	if not carrier.alive:
		bucket["dead"] += 1
		return

	# 读取携带者的战术状态
	var site_target: Vector3 = Vector3(-20.0, 0.0, -20.0)
	var state: int = -1
	for ctl in carrier.controllers:
		if "site_target" in ctl:
			site_target = ctl.site_target
			state = ctl.combat_state
	var d: float = carrier.global_position.distance_to(site_target)

	var prev = _carrier_min_dist.get(_round_seen, INF)
	if d < float(prev):
		_carrier_min_dist[_round_seen] = d

	var bkey: int = int(d / 5.0) * 5
	dist_hist[bkey] = int(dist_hist.get(bkey, 0)) + 1

	if state == 4:          # CombatState.PLANT
		bucket["planting"] += 1
		return
	if d > 6.0:
		bucket["far"] += 1
		return
	bucket["suppressed"] += 1


func _live_report() -> void:
	var sig: Vector2i = mm.get_score()
	var av: Vector2i = mm.get_alive_counts()
	var bar: String = ""
	for i in av.x:
		bar += "#"
	bar += " |"
	for i in av.y:
		bar += "#"
	print("[%5.0fs] R%-2d S%d:G%d %s %-6s %s 安装%d" % [
		elapsed, mm.round_number, sig.x, sig.y, bar.rpad(13, " "),
		mm.get_phase_name(), mm.get_round_time_text(), _plants])


func _finish() -> void:
	if _finished:
		return
	_finished = true

	print("-".repeat(70))
	print("诊断结束 · %.0f 秒 / %d 采样点 / 打满 %d 回合" % [elapsed, carrier_samples, _rounds_played])
	print("")

	print("[1] 携带者状态归因 (每 0.1s 归类一次, 合计 = 采样点)")
	var total: int = maxi(carrier_samples, 1)
	var order := ["no_bomb", "dead", "far", "suppressed", "planting", "planted"]
	var label := {
		"no_bomb": "无人携带(未分配 / 掉落后无人捡)",
		"dead": "携带者阵亡",
		"far": "活着但距点 > 6m (推进不到位)",
		"suppressed": "已到点但被压制 (装不上)",
		"planting": "★ 正在安装",
		"planted": "★ 装置已放下",
	}
	for k in order:
		print("   %-32s %6d  %5.1f%%" % [label[k], bucket[k],
			float(bucket[k]) / float(total) * 100.0])
	print("")

	print("[2] 携带者本回合最近推进到距点多少米 (越小越好, 入点需 <= 6m)")
	var ks: Array = _carrier_min_dist.keys()
	ks.sort()
	if ks.is_empty():
		print("   (无数据)")
	for k in ks:
		var v: float = _carrier_min_dist[k]
		var mark: String = "✓ 已进点" if v <= 6.0 else ("△ 接近" if v <= 12.0 else "✗ 远未到达")
		print("   回合 %-2d  %6.1fm   %s" % [int(k), v, mark])
	print("")

	print("[3] 距点距离分布 (仅统计活着的携带者)")
	var dk: Array = dist_hist.keys()
	dk.sort()
	if dk.is_empty():
		print("   (无数据 — 携带者从未活着被采样到)")
	for k in dk:
		var bar: String = "#".repeat(mini(int(dist_hist[k]) / 10, 50))
		print("   %3d-%3dm %6d  %s" % [int(k), int(k) + 5, dist_hist[k], bar])
	print("")

	print("[4] 装置掉落回收")
	print("   掉落次数      : %d" % _drops)
	print("   成功回收      : %d" % _pickup_latency.size())
	print("   回合结束时仍在地上: %d" % _unrecovered)
	if not _pickup_latency.is_empty():
		var sum: float = 0.0
		for v in _pickup_latency:
			sum += float(v)
		print("   平均回收耗时  : %.1fs" % (sum / _pickup_latency.size()))
	print("")

	print("[5] 回合结果分布")
	var rk: Array = _round_result.keys()
	rk.sort()
	if rk.is_empty():
		print("   (无回合完成)")
	var rname := {
		"bomb": "装置引爆(进攻胜)", "defuse": "装置拆除(防守胜)",
		"elimination": "歼灭", "time": "时间耗尽(防守胜)", "draw": "同归于尽",
	}
	for k in rk:
		print("   %-22s %d" % [rname.get(k, k), _round_result[k]])
	print("")

	print("[6] 攻防胜率")
	var ws: int = int(_wins[GameConfig.Team.STRIKE])
	var wg: int = int(_wins[GameConfig.Team.GUARD])
	var tot: int = maxi(ws + wg, 1)
	print("   STRIKE 胜 %2d  (%.0f%%)     GUARD 胜 %2d  (%.0f%%)" % [
		ws, float(ws) / float(tot) * 100.0,
		wg, float(wg) / float(tot) * 100.0])
	print("")

	print("[7] 战斗")
	print("   开火 %d 发 | 命中 %d 发 | 命中率 %.1f%%" % [
		_shots, _hits, float(_hits) / float(maxi(_shots, 1)) * 100.0])
	print("   装置安装 %d 次 | 拆除 %d 次" % [_plants, _defuses])
	print("")

	print("[8] 存活时长 (秒, 越高越会保命)")
	var names: Array = alive_time.keys()
	names.sort()
	for n in names:
		print("   %-12s %6.1fs" % [n, float(alive_time[n])])
	print("-".repeat(70))

	# 判定
	var verdicts: Array = []
	if _plants == 0:
		verdicts.append("T1 FAIL 全程零安装 — 核心循环未闭环")
	else:
		verdicts.append("T1 PASS 出现安装 %d 次" % _plants)
	if _rounds_played > 0:
		var sr: float = float(_wins[GameConfig.Team.STRIKE]) / float(_rounds_played)
		if sr < 0.35 or sr > 0.65:
			verdicts.append("T2 FAIL 攻防失衡 STRIKE 胜率 %.0f%% (目标 40~60%%)" % (sr * 100.0))
		else:
			verdicts.append("T2 PASS 攻防平衡 STRIKE 胜率 %.0f%%" % (sr * 100.0))
	if _round_result.size() < 2:
		verdicts.append("T3 WARN 回合结束原因只有 %d 种, 玩法单一" % _round_result.size())
	else:
		verdicts.append("T3 PASS 回合结束原因 %d 种" % _round_result.size())
	var acc: float = float(_hits) / float(maxi(_shots, 1)) * 100.0
	if acc < 12.0:
		verdicts.append("T4 FAIL 命中率 %.1f%% 过低 (目标 18~28%%)" % acc)
	else:
		verdicts.append("T4 PASS 命中率 %.1f%%" % acc)

	print("")
	for v in verdicts:
		print("   " + v)
	print("=".repeat(70))
	get_tree().quit(0)
