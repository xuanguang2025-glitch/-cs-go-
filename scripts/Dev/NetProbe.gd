extends Node
##
## NetProbe.gd — 联机链路无头测试
##
## 用法(两个进程):
##   进程A(主机):  Godot --headless --path . res://scenes/Dev/NetProbe.tscn -- --host
##   进程B(客户端): Godot --headless --path . res://scenes/Dev/NetProbe.tscn -- --join
##
## 可选参数:
##   --port N      端口(默认 24565), 主机与客户端需一致
##   --bots N      主机端 Bot 数量(默认 9)。
##   --dedicated   用 host_dedicated() 起服务(专用服务器模式, 无本地玩家)。
##                 配合 "--bots 0" 即纯观察者模式: 不生成任何 Bot,
##                 停在热身等待, 等客户端连进来凑够人数才自动开赛。
##   --waits N     运行 N 秒后退出(默认主机 60s / 客户端 35s)
##   --buytest     (仅客户端)加入后自动发起一次服务器权威购买(weapon viper),
##                 13s 时校验购买是否经 请求→服务器结算→配装回执 全链路生效。
##
## 输出: 连接是否成功 / 角色是否下发 / 是否收到快照 / 比赛阶段。
##

var mode: String = "host"
var port: int = 24565
var bots: int = 9
var map_id: String = "project_zero"
var dedicated: bool = false
var buytest: bool = false
var buy_sent: bool = false
var buy_checked: bool = false
var pre_secondary: String = ""
var wait_s: float = -1.0
var frames: int = 0
var start_ms: int = 0
var last_report: float = -10.0
var game_root: Node = null
var mm: Node = null
var snapshots_seen: int = 0
var actors_at_start: int = 0

func _ready() -> void:
	var uargs := OS.get_cmdline_user_args()
	for i in uargs.size():
		match uargs[i]:
			"--host": mode = "host"
			"--join": mode = "join"
			"--dedicated": dedicated = true
			"--buytest": buytest = true
			"--port":
				if i + 1 < uargs.size(): port = int(uargs[i + 1])
			"--bots":
				if i + 1 < uargs.size(): bots = clampi(int(uargs[i + 1]), 0, 10)
			"--map":
				if i + 1 < uargs.size(): map_id = str(uargs[i + 1])
			"--waits":
				if i + 1 < uargs.size(): wait_s = float(uargs[i + 1])

	if wait_s < 0.0:
		wait_s = 60.0 if mode == "host" else 35.0

	print("[NetProbe] mode=%s%s port=%d bots=%d" % [
		mode, " (dedicated)" if dedicated else "", port, bots])
	start_ms = Time.get_ticks_msec()

	if mode == "host":
		var err: int = NetworkManager.host_dedicated(port) if dedicated else NetworkManager.host_game(port)
		if err != OK:
			print("[NetProbe][FAIL] host 失败 ", err)
			get_tree().quit(1)
			return
		print("[NetProbe] 服务器已监听 %d" % port)
		GameManager.pending_match = {
			"map_id": map_id,
			"bot_count": bots,
			"team": GameConfig.Team.STRIKE,
			"dedicated_bots": bots,
		}
		_load_game()
	else:
		NetworkManager.join_succeeded.connect(func():
			print("[NetProbe] 连接成功, 进入比赛场景")
			GameManager.pending_match = {
				"map_id": "project_zero",
				"bot_count": 0,
				"team": GameConfig.Team.STRIKE,
			}
			_load_game())
		NetworkManager.join_failed.connect(func(r): print("[NetProbe][FAIL] ", r); get_tree().quit(1))
		var err: int = NetworkManager.join_game("127.0.0.1", port)
		if err != OK:
			print("[NetProbe][FAIL] join 调用失败 ", err)
			get_tree().quit(1)


func _load_game() -> void:
	var packed := load("res://scenes/Game.tscn") as PackedScene
	game_root = packed.instantiate()
	add_child(game_root)
	mm = game_root.get_node_or_null("MatchManager")
	actors_at_start = mm.actors.size() if mm != null else 0
	print("[NetProbe] 比赛场景加载, 初始角色 %d" % actors_at_start)


func _process(_d: float) -> void:
	frames += 1
	var elapsed: float = (Time.get_ticks_msec() - start_ms) / 1000.0

	# 每 5 秒(真实时间)报告一次状态。第五轮踩过坑: 无头帧率不稳定,
	# 按帧计时会漂移, 这里必须用真实时间。
	if elapsed - last_report >= 5.0:
		last_report = elapsed
		_report(elapsed)

	# 购买链路端到端测试: 8s(本地时间)发起购买, 13s 校验服务器回执。
	if mode == "join" and buytest and not buy_sent and elapsed >= 8.0:
		var lp0 = GameManager.local_player
		if lp0 != null and lp0.loadout != null:
			pre_secondary = lp0.loadout.get_slot_weapon("secondary")
			NetworkManager.request_purchase("weapon", "viper")
			print("[NetProbe][BUYTEST] 已发送购买请求 weapon=viper (发送前 secondary=%s)" % pre_secondary)
			buy_sent = true
	if mode == "join" and buytest and buy_sent and not buy_checked and elapsed >= 13.0:
		buy_checked = true
		var lp1 = GameManager.local_player
		var sec: String = lp1.loadout.get_slot_weapon("secondary") if (lp1 != null and lp1.loadout != null) else ""
		var money: int = lp1.loadout.money if (lp1 != null and lp1.loadout != null) else -1
		if sec == "viper" and sec != pre_secondary:
			print("[NetProbe][PASS] 购买链路端到端 OK: 服务器权威结算并回执, secondary=%s money=%d" % [sec, money])
		else:
			print("[NetProbe][FAIL] 购买链路未生效: secondary=%s money=%d (发送前=%s)" % [sec, money, pre_secondary])

	if elapsed >= wait_s:
		print("[NetProbe] 结束 (%.0fs)" % elapsed)
		get_tree().quit(0)


func _report(elapsed: float) -> void:
	var lp = GameManager.local_player
	var n = NetworkManager.net_actors.size()
	var actors_n: int = mm.actors.size() if mm != null else -1
	var phase_name: String = mm.get_phase_name() if (mm != null and mm.has_method("get_phase_name")) else "?"

	print("[NetProbe %5.1fs] local_player=%s net_actors=%d actors=%d phase=%s" % [
		elapsed, "YES" if lp != null else "null", n, actors_n, phase_name])

	if mode == "join" and lp != null:
		print("[NetProbe][PASS] 客户端本地角色已下发: %s @ %s" % [
			lp.actor_name, str(lp.global_position)])
