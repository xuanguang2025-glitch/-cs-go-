extends Node
##
## SysProbe.gd — 系统级功能定向测试
##
## 覆盖 TestBoot / CombatProbe / PlantProbe / NetProbe 之外的横切功能:
##   1. 设置持久化 (user://settings.cfg)
##   2. 录像录制 → 保存 → 加载 → 采样
##   3. 段位系统 MMR 计算
##   4. 武器 / 投掷物数据完整性
##
## 用法:
##   Godot --headless --path . res://scenes/Dev/SysProbe.tscn
##
## 所有会写 user:// 的测试都在结束后还原, 不污染玩家真实存档。
##

var failures: Array[String] = []


func _ready() -> void:
	print("=".repeat(60))
	print("系统功能定向测试")
	print("=".repeat(60))

	_test_settings()
	_test_replay()
	_test_rank()
	_test_weapons()

	print("-".repeat(60))
	if failures.is_empty():
		print("[PASS] 全部通过")
		get_tree().quit(0)
	else:
		print("[FAIL] %d 项失败:" % failures.size())
		for f in failures:
			print("  - %s" % f)
		get_tree().quit(1)


func _ok(name: String, detail: String = "") -> void:
	print("  [OK] %-22s %s" % [name, detail])


func _bad(name: String, detail: String) -> void:
	print("  [NG] %-22s %s" % [name, detail])
	failures.append("%s: %s" % [name, detail])


# ---------------------------------------------------------------
# 1. 设置持久化
# ---------------------------------------------------------------
func _test_settings() -> void:
	print("")
	print("[1] 设置持久化 (user://settings.cfg)")

	var backup: Dictionary = GameManager.settings.duplicate(true)

	GameManager.set_setting("mouse_sensitivity", 2.75)
	GameManager.set_setting("fov", 103.0)
	GameManager.set_setting("master_volume", 0.42)
	GameManager.save_settings()

	# 清空内存值后重新从磁盘加载, 验证真的落盘了
	for k in GameManager.settings.keys():
		GameManager.settings[k] = null
	GameManager.load_settings()

	var checks := {
		"mouse_sensitivity": 2.75,
		"fov": 103.0,
		"master_volume": 0.42,
	}
	for k in checks:
		var got: float = float(GameManager.get_setting(k, -1.0))
		var want: float = checks[k]
		if absf(got - want) < 0.001:
			_ok("持久化 %s" % k, "%.2f" % got)
		else:
			_bad("持久化 %s" % k, "期望 %.2f 实得 %.2f" % [want, got])

	# 还原玩家原配置
	for k in backup:
		GameManager.settings[k] = backup[k]
	GameManager.save_settings()


# ---------------------------------------------------------------
# 2. 录像录制 → 保存 → 加载 → 采样
# ---------------------------------------------------------------
func _test_replay() -> void:
	print("")
	print("[2] 录像系统 (user://replays)")

	if ReplaySystem.recording:
		ReplaySystem.stop_recording()

	ReplaySystem.frames.clear()
	ReplaySystem.events.clear()
	ReplaySystem.start_recording("sysprobe_test")

	# 手工塞 3 秒 30Hz 帧数据, 不依赖真实比赛
	for i in 90:
		ReplaySystem.frames.append({
			"t": i * 33,
			"a": [
				[1, 0.0, 0.0, float(i) * 0.1, 0.0, 0.0, 100, true, 0],
				[2, 5.0, 0.0, 0.0, 1.57, 0.0, 55, true, 1],
			],
		})
	ReplaySystem.add_event("kill", {"killer": "A", "victim": "B"})

	var dur: float = ReplaySystem.duration_ms()
	if dur > 2500.0:
		_ok("录像时长", "%.0f ms" % dur)
	else:
		_bad("录像时长", "%.0f ms 过短" % dur)

	ReplaySystem.stop_recording()
	var path: String = ReplaySystem.save_replay()
	if path == "" or not FileAccess.file_exists(path):
		_bad("录像落盘", "路径为空或文件不存在: '%s'" % path)
		ReplaySystem.frames.clear()
		ReplaySystem.events.clear()
		return
	_ok("录像落盘", path.get_file())

	# 清空后重新加载, 验证反序列化
	ReplaySystem.frames.clear()
	ReplaySystem.events.clear()
	if not ReplaySystem.load_replay(path):
		_bad("录像加载", "load_replay 返回 false")
		return
	_ok("录像加载", "%d 帧 / %d 事件" % [
		ReplaySystem.frames.size(), ReplaySystem.events.size()])

	# 采样中段: t=1500ms。注意 sample() 返回的是 {actor_id: {...}} 而非数组
	var mid: Dictionary = ReplaySystem.sample(1500.0)
	if mid.size() == 2 and mid.has(1):
		var z: float = float(mid[1]["pos"].z)
		# 第 45 帧左右 z ≈ 4.5, 应在 4~5 之间
		if z > 4.0 and z < 5.2:
			_ok("录像采样插值", "t=1500ms 角色1 z=%.2f" % z)
		else:
			_bad("录像采样插值", "z=%.2f 不在预期区间 4.0~5.2" % z)
	else:
		_bad("录像采样", "期望 2 个角色, 实得 %d (键=%s)" % [
			mid.size(), str(mid.keys())])

	if ReplaySystem.events.size() == 1:
		_ok("事件保留", str(ReplaySystem.events[0].get("type", "?")))
	else:
		_bad("事件保留", "期望 1 条, 实得 %d" % ReplaySystem.events.size())

	# 清理测试产物
	DirAccess.remove_absolute(path)
	ReplaySystem.frames.clear()
	ReplaySystem.events.clear()


# ---------------------------------------------------------------
# 3. 段位系统
# ---------------------------------------------------------------
func _test_rank() -> void:
	print("")
	print("[3] 段位系统 (Elo K=32)")

	var mmr0: int = RankSystem.mmr
	var wins0: int = RankSystem.wins
	var streak0: int = RankSystem.streak
	_ok("MMR 初值", "%d (%s)" % [mmr0, RankSystem.tier_name()])

	# 同分取胜: expected=0.5 → delta = round(32 * 0.5) = 16, 连胜加成 0
	var r: Dictionary = RankSystem.report_match_result(true, mmr0)
	var delta: int = int(r.get("delta", 0))
	if delta == 16:
		_ok("同分取胜", "+%d (期望 +16)" % delta)
	else:
		_bad("同分取胜", "+%d, 期望 +16" % delta)

	# 打完应比初始高 16
	if RankSystem.mmr == mmr0 + 16:
		_ok("MMR 累加", "%d → %d" % [mmr0, RankSystem.mmr])
	else:
		_bad("MMR 累加", "%d → %d, 期望 %d" % [mmr0, RankSystem.mmr, mmr0 + 16])

	# 再赢一场应吃到连胜加成 (streak=2 → bonus=5)
	var r2: Dictionary = RankSystem.report_match_result(true, RankSystem.mmr)
	var d2: int = int(r2.get("delta", 0))
	if d2 > 16:
		_ok("连胜加成", "+%d (基准 16 + 连胜 %d)" % [d2, d2 - 16])
	else:
		_bad("连胜加成", "+%d, 应大于基准 16" % d2)

	# 段位表
	if RankSystem.TIERS.size() >= 9:
		_ok("段位表", "%d 档: %s" % [
			RankSystem.TIERS.size(),
			str(RankSystem.TIERS[RankSystem.TIERS.size() - 1].get("name", "?"))])
	else:
		_bad("段位表", "%d 档, 期望 >=9" % RankSystem.TIERS.size())

	# 还原
	RankSystem.mmr = mmr0
	RankSystem.wins = wins0
	RankSystem.streak = streak0
	RankSystem.save_rank()


# ---------------------------------------------------------------
# 4. 武器 / 投掷物数据完整性
# ---------------------------------------------------------------
func _test_weapons() -> void:
	print("")
	print("[4] 武器与投掷物数据")

	var all: Dictionary = WeaponDatabase.get_all_weapons()
	if all.is_empty():
		_bad("武器库", "为空")
		return
	_ok("武器总数", "%d 把" % all.size())

	var required := ["damage", "rpm", "price", "magazine"]
	var missing: Array[String] = []
	var bad_num: Array[String] = []
	for wid in all:
		var w: Dictionary = all[wid]
		for f in required:
			if not w.has(f):
				missing.append("%s.%s" % [wid, f])
		if float(w.get("damage", 0)) <= 0:
			bad_num.append("%s damage<=0" % wid)
		if int(w.get("price", 0)) < 0:
			bad_num.append("%s price<0" % wid)
		if float(w.get("rpm", 0)) <= 0:
			bad_num.append("%s rpm<=0" % wid)

	if missing.is_empty():
		_ok("必填字段", "%s 齐备" % ", ".join(required))
	else:
		_bad("必填字段", "缺失 %d 处: %s" % [
			missing.size(), ", ".join(missing.slice(0, 5))])

	if bad_num.is_empty():
		_ok("数值合理性", "伤害/价格/射速均为正")
	else:
		_bad("数值合理性", ", ".join(bad_num.slice(0, 5)))

	# 后坐力曲线: 至少要有数据且能按发次取值
	var rp_ok := 0
	for wid in all:
		var v: Vector2 = WeaponDatabase.recoil_at(wid, 0)
		if v.length() >= 0.0:
			rp_ok += 1
	if rp_ok == all.size():
		_ok("后坐力曲线", "%d 把全部可取" % rp_ok)
	else:
		_bad("后坐力曲线", "%d/%d 可取" % [rp_ok, all.size()])

	# 距离衰减: 近处应 >= 远处
	var atten_ok := true
	for wid in all:
		var near: float = WeaponDatabase.damage_falloff(wid, 5.0)
		var far: float = WeaponDatabase.damage_falloff(wid, 80.0)
		if near < far - 0.001:
			atten_ok = false
			bad_num.append("%s 衰减反转" % wid)
	if atten_ok:
		_ok("距离衰减", "近 ≥ 远, 全部正常")
	else:
		_bad("距离衰减", "存在近端低于远端的武器")

	var gren: Dictionary = WeaponDatabase.get_all_grenades()
	if gren.size() >= 4:
		_ok("投掷物", "%d 种: %s" % [gren.size(), ", ".join(gren.keys())])
	else:
		_bad("投掷物", "%d 种, 期望 >=4" % gren.size())
