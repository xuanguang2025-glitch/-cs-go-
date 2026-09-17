extends Node
##
## PlantProbe.gd — 目标装置全流程定向测试
##
## 用法:
##   Godot.exe --headless --path . res://scenes/Dev/PlantProbe.tscn --quit-after 900
##
## 验证: 携带 -> 进入 A/B 点 -> 安装 6s -> 40s 倒计时 -> 拆除 / 引爆
## 这是"能不能完整打完一个回合"的关键路径, 单独拎出来测。
##

var mm: Node = null
var game_root: Node = null
var failures: PackedStringArray = []
var frame: int = 0

var phase: String = "init"
var carrier = null
var planter_ok: bool = false
var defuse_ok: bool = false
var explode_ok: bool = false


func _ready() -> void:
	GameManager.pending_match = {
		"map_id": "project_zero", "bot_count": 9, "team": GameConfig.Team.STRIKE,
	}
	EventBus.bomb_planted.connect(func(_s, _p): planter_ok = true)
	EventBus.bomb_defused.connect(func(_d): defuse_ok = true)
	EventBus.bomb_exploded.connect(func(): explode_ok = true)

	var packed := load("res://scenes/Game.tscn") as PackedScene
	game_root = packed.instantiate()
	add_child(game_root)
	mm = game_root.get_node_or_null("MatchManager")
	if mm == null:
		print("[FAIL] MatchManager 缺失")
		get_tree().quit(1)
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	_setup()


func _setup() -> void:
	print("=".repeat(60))
	print("目标装置全流程测试")
	print("=".repeat(60))

	var obj = mm.objective
	carrier = obj.get_carrier()
	if carrier == null:
		_check("装置分配", false, "没有角色携带装置")
		_finish()
		return
	_check("装置分配", true, "携带者 = %s" % carrier.actor_name)

	# 把携带者直接送进 A 点, 防守方远远拉开, 制造安装窗口
	carrier.global_position = Vector3(-20, 0.2, -20)
	carrier.base_yaw = 0.0
	carrier.rotation.y = 0.0
	for a in mm.actors:
		if a == carrier:
			continue
		if a.team != carrier.team:
			a.global_position = Vector3(0, 0.2, 30)     # 防守方全部拉到南端
			a.alive = true
		else:
			a.global_position = Vector3(-24, 0.2, -12)  # 队友在旁边掩护
	# 真正关掉携带者的 AI(poll 由 Actor 驱动, 必须用 enabled 开关)
	for c in carrier.controllers:
		if "enabled" in c:
			c.enabled = false
	# 清掉传送残留的速度, 否则 hspeed>0.35 会立刻中断安装
	carrier.velocity = Vector3.ZERO
	# 把它的战术目标点对齐到 A 点, 排除"人在 A 想去 B"的干扰
	var bot_ctrl = null
	for c in carrier.controllers:
		if "site_target" in c:
			bot_ctrl = c
	if bot_ctrl != null:
		bot_ctrl.site_target = Vector3(-20.0, 0.0, -20.0)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var inside: bool = false
	for s in mm.sites:
		if s.contains(carrier):
			inside = true
	_check("进入炸弹点区域", inside, "A/B 点 Area3D 是否检测到携带者")
	_check("can_plant 判定", obj.can_plant(carrier), "安装前置条件")

	phase = "planting"


func _process(delta: float) -> void:
	frame += 1
	if mm == null or carrier == null or not is_instance_valid(carrier):
		return

	if phase == "planting":
		# 模拟真人按住 E
		carrier.intent.use_held = true
		carrier.intent.move_input = Vector2.ZERO
		if frame % 60 == 0:
			var obj = mm.objective
			print("   [诊断] 进度=%.2f  on_floor=%s  hspeed=%.3f  y=%.3f  state=%d  is_planting=%s" % [
				carrier.action_progress, str(carrier.is_on_floor()),
				carrier.horizontal_speed, carrier.global_position.y,
				obj.state, str(carrier.is_planting)])
		if planter_ok:
			phase = "planted"
			print("   >> 安装完成, 进入倒计时")
			# 换一个防守方角色来拆
			_start_defuse()
		elif frame > 9000:
			_check("安装完成", false, "10 秒内没装上")
			_finish()
			return

	elif phase == "planted":
		if defuse_ok:
			phase = "done"
			_check("拆除成功", true, "装置被拆除")
			_finish()
			return
		if explode_ok:
			phase = "done"
			_check("引爆流程", true, "装置爆炸(拆除方没赶到)")
			_finish()
			return
		if frame > 55000:
			_check("拆除/引爆", false, "50 秒内没有触发任一结局")
			_finish()
			return


func _start_defuse() -> void:
	# 让一名防守方角色站到装置旁并持续按住 E
	var obj = mm.objective
	var pos: Vector3 = obj.get_planted_position()
	for a in mm.actors:
		if a.team == carrier.team or not a.alive:
			continue
		for c in a.controllers:
			c.set_process(false)
			if c.has_method("set_physics_process"):
				c.set_physics_process(false)
		a.global_position = pos + Vector3(0.8, 0.2, 0.8)
		a.intent.use_held = true
		a.intent.move_input = Vector2.ZERO
		# 持续按住
		_keep_defusing(a)
		return


func _keep_defusing(a) -> void:
	# 每帧维持 use_held, 直到拆除完成
	while is_instance_valid(a) and not defuse_ok and a.alive:
		a.intent.use_held = true
		a.intent.move_input = Vector2.ZERO
		await get_tree().physics_frame


func _check(name: String, cond: bool, detail: String) -> void:
	print("  [%s] %-22s %s" % ["OK" if cond else "XX", name, detail])
	if not cond:
		failures.append(name + " -> " + detail)


func _finish() -> void:
	print("-".repeat(60))
	if failures.is_empty():
		print("[PASS] 装置全流程通过")
	else:
		print("[FAIL] %d 项:" % failures.size())
		for f in failures:
			print("   - ", f)
	get_tree().quit(0 if failures.is_empty() else 1)
