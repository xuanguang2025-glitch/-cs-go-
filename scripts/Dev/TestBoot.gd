extends Node
##
## TestBoot.gd — 无头自检入口
##
## 用法:
##   Godot.exe --headless --path . res://scenes/Dev/TestBoot.tscn --quit-after 2400
##
## 用真实场景启动(保证 autoload 全部生效), 跑若干帧后输出比赛状态并退出。
##

## 自检按"真实时长"预算, 而不是帧数 —— 无头模式帧率随机器浮动,
## 帧数固定会导致快机器上回合还没打完就收尾, 慢机器上白等。
## 预算需覆盖: 购买阶段 + 一个完整回合(115s) + 余量。
const TIME_BUDGET := 210.0
const REPORT_EVERY := 600

var frames: int = 0
var elapsed: float = 0.0
var mm: Node = null
var game_root: Node = null
var issues: PackedStringArray = []
var map_id: String = "project_zero"
var shots: int = 0
var hits: int = 0
var plants: int = 0
var grenades: int = 0


func _ready() -> void:
	print("=".repeat(62))
	print("PROJECT STRIKE - 无头运行时自检")
	print("=".repeat(62))

	# 支持 --map <id> 用户参数: Godot.exe --headless scene.tscn -- --map night_harbor
	map_id = "project_zero"
	var uargs := OS.get_cmdline_user_args()
	for i in uargs.size():
		if uargs[i] == "--map" and i + 1 < uargs.size():
			map_id = uargs[i + 1]

	GameManager.pending_match = {
		"map_id": map_id,
		"bot_count": 0 if map_id == "training_range" else 9,
		"team": GameConfig.Team.STRIKE,
	}

	var packed := load("res://scenes/Game.tscn") as PackedScene
	if packed == null:
		print("[FAIL] 无法加载 Game.tscn")
		get_tree().quit(1)
		return

	EventBus.weapon_fired.connect(func(_a, _w): shots += 1)
	EventBus.hit_confirmed.connect(func(_a, _v, _d, _h, _k): hits += 1)
	EventBus.bomb_planted.connect(func(_s, _p): plants += 1)
	EventBus.grenade_thrown.connect(func(_t, _k): grenades += 1)

	game_root = packed.instantiate()
	add_child(game_root)
	mm = game_root.get_node_or_null("MatchManager")
	# 无头测试: 接管本地玩家, 禁掉真实输入源
	if mm != null and mm.player_controller != null:
		mm.player_controller.enabled = false

	if mm == null:
		print("[FAIL] MatchManager 未创建")
		get_tree().quit(1)
		return

	print("[OK] 场景加载完成")
	print("     角色总数 : %d" % mm.actors.size())
	print("     Bot 数量 : %d" % mm.bot_controllers.size())
	print("     地图路点 : %d" % mm.waypoints.size())
	print("     炸弹点   : %d" % mm.sites.size())
	print("     导航图   : %d 个节点 / %d 条边" % [mm.nav_graph.size(), _count_edges()])

	var expected: int = 6 if map_id == "training_range" else 10
	if mm.actors.size() != expected:
		issues.append("角色数量应为 %d, 实际 %d" % [expected, mm.actors.size()])
	if mm.local_player == null:
		issues.append("本地玩家为空")
	if map_id != "training_range" and mm.sites.size() != 2:
		issues.append("炸弹点应为 2 个, 实际 %d" % mm.sites.size())


func _process(delta: float) -> void:
	frames += 1
	elapsed += delta
	if mm == null or not is_instance_valid(mm):
		return

	_drive_local_player()

	if frames % REPORT_EVERY == 0:
		_report()

	# 打完第 2 回合就收尾; 超时则说明回合推进异常, 同样收尾并报错
	if mm.round_number >= 2 or elapsed >= TIME_BUDGET:
		_finish()


func _count_edges() -> int:
	var n: int = 0
	for k in mm.nav_graph:
		n += mm.nav_graph[k].size()
	return n / 2


func _dump_bots() -> void:
	for b in mm.bot_controllers:
		var a = b.actor
		if not is_instance_valid(a):
			continue
		print("       %-9s pos(%5.1f,%5.1f) alive=%s tactic=%s goal=%s path=%d tgt=%s" % [
			a.actor_name, a.global_position.x, a.global_position.z,
			str(a.alive), b.tactic, str(b.has_goal), b.path.size(),
			b.target.actor_name if (b.target != null and is_instance_valid(b.target)) else "-"])


func _drive_local_player() -> void:
	var p = mm.local_player
	if p == null or not is_instance_valid(p) or not p.alive:
		return
	var intent = p.intent

	# 训练场: 固定朝 -Z 靶道射击, 验证命中/复活链路
	if mm.get("training_mode") == true:
		p.base_yaw = 0.0
		p.base_pitch = 0.0
		intent.look_delta = Vector2.ZERO
		intent.move_input = Vector2.ZERO
		intent.fire_held = (frames % 100) < 20
		intent.fire_pressed = (frames % 100) == 0
		intent.reload = (frames % 150) == 0
		return

	# 携带装置 -> 像真人一样直奔炸弹点, 到点按住 E
	if p.loadout.has_bomb:
		var target := Vector3(-20.0, 0.0, -20.0)
		var to: Vector3 = target - p.global_position
		to.y = 0.0
		if to.length() < 5.0:
			intent.use_held = true
			intent.move_input = Vector2.ZERO
			intent.fire_held = false
			return
		var dir: Vector3 = to.normalized()
		p.base_yaw = atan2(-dir.x, -dir.z)
		p.base_pitch = 0.0
		var fwd: Vector3 = -p.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right: Vector3 = p.global_transform.basis.x
		right.y = 0.0
		right = right.normalized()
		intent.move_input = Vector2(dir.dot(right), dir.dot(fwd)).normalized()
		intent.fire_held = false
		return

	intent.move_input = Vector2(sin(frames * 0.011) * 0.55, 0.7)
	intent.fire_held = (frames % 120) < 30
	intent.fire_pressed = (frames % 120) == 0
	intent.reload = (frames % 500) == 0
	intent.jump = (frames % 300) == 0
	intent.look_delta = Vector2(sin(frames * 0.02) * 7.0, 0.0)


func _report() -> void:
	var s: Vector2i = mm.get_score()
	var alive: Vector2i = mm.get_alive_counts()
	print("[%4d] 回合 %-2d | 比分 %d:%d | 存活 %dv%d | %s | %s" % [
		frames, mm.round_number, s.x, s.y, alive.x, alive.y,
		mm.get_phase_name(), mm.get_round_time_text()])
	var obj = mm.objective
	if obj != null and obj.is_planted():
		print("        >> 装置已安装, 倒计时 %.1fs" % obj.get_bomb_timer())
	var car = obj.get_carrier() if obj != null else null
	if car != null and is_instance_valid(car):
		var st := Vector3.ZERO
		var tac := "?"
		for c in car.controllers:
			if "site_target" in c:
				st = c.site_target
				tac = c.tactic
		print("        携带者 %-8s pos(%5.1f,%5.1f) 距目标%5.1fm 战术=%s 有弹=%s" % [
			car.actor_name, car.global_position.x, car.global_position.z,
			car.global_position.distance_to(st), tac, str(car.alive)])
	elif obj != null and obj.get("dropped_position") != null:
		var dp: Vector3 = obj.dropped_position
		print("        !! 装置掉落在 (%.0f, %.0f)" % [dp.x, dp.z])
	_dump_bots()


func _finish() -> void:
	print("-".repeat(62))
	print("自检结束 · 共 %d 帧 / %.0f 秒" % [frames, elapsed])
	if mm != null and is_instance_valid(mm):
		var s: Vector2i = mm.get_score()
		print("最终比分 : STRIKE %d : %d GUARD" % [s.x, s.y])
		print("进行回合 : %d" % mm.round_number)
		print("存活情况 : %dv%d" % [mm.get_alive_counts().x, mm.get_alive_counts().y])
		print("开火 %d 次  |  命中 %d 次  |  命中率 %.1f%%" % [
			shots, hits, (float(hits) / float(maxi(shots, 1)) * 100.0)])
		print("投掷物 %d 次  |  装置安装 %d 次" % [grenades, plants])
		print("")
		print("  玩家          队伍      K   D   伤害    金钱   状态")
		for a in mm.actors:
			var st: Dictionary = mm.get_actor_stats(a)
			print("  %-12s %-7s %3d %3d  %6.0f  $%-6d %s" % [
				a.actor_name, GameConfig.team_name(a.team),
				int(st["kills"]), int(st["deaths"]), float(st["damage"]),
				a.loadout.money, "存活" if a.alive else "阵亡"])
		if map_id != "training_range" and mm.round_number <= 1 and s.x == 0 and s.y == 0:
			issues.append("%.0f 秒内没打完第 1 回合, 回合推进异常" % elapsed)
		if shots == 0:
			issues.append("全程没有任何 Bot 开火")
		elif hits == 0:
			issues.append("有开火但零命中, 命中检测可疑")

	print("-".repeat(62))
	if issues.is_empty():
		print("[PASS] 未发现结构性问题")
	else:
		print("[ISSUES] %d 项:" % issues.size())
		for i in issues:
			print("  - %s" % i)
	get_tree().quit(0 if issues.is_empty() else 1)
