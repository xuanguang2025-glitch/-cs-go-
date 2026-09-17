extends Node
##
## CombatProbe.gd — 战斗系统定向测试
##
## 用法:
##   Godot.exe --headless --path . res://scenes/Dev/CombatProbe.tscn --quit-after 200
##
## 直接调用 HitSystem 对固定距离的目标打射线, 验证:
##   命中判定 / 部位倍率 / 护甲吸收 / 距离衰减 / 穿透
##

var mm: Node = null
var game_root: Node = null
var done: bool = false
var failures: PackedStringArray = []


func _ready() -> void:
	GameManager.pending_match = {
		"map_id": "project_zero", "bot_count": 9, "team": GameConfig.Team.STRIKE,
	}
	var packed := load("res://scenes/Game.tscn") as PackedScene
	game_root = packed.instantiate()
	add_child(game_root)
	mm = game_root.get_node_or_null("MatchManager")
	# 等一帧让物理与导航就绪
	await get_tree().physics_frame
	await _run_probes()
	done = true
	get_tree().quit(0 if failures.is_empty() else 1)


func _run_probes() -> void:
	if mm == null:
		print("[FAIL] MatchManager 缺失")
		return
	var hs = mm.hit_system
	if hs == null:
		print("[FAIL] HitSystem 缺失")
		return

	print("=" .repeat(60))
	print("战斗系统定向测试")
	print("=" .repeat(60))

	await _test_raw_raycast(hs)
	await _test_internal_cast(hs)
	await _test_hitscan_basic(hs)
	await _test_hitgroup(hs)
	await _test_armor(hs)
	await _test_falloff(hs)
	await _test_penetration(hs)

	print("-".repeat(60))
	if failures.is_empty():
		print("[PASS] 战斗系统全部通过")
	else:
		print("[FAIL] %d 项未通过:" % failures.size())
		for f in failures:
			print("   - ", f)


# ---------------------------------------------------------------- 工具
func _make_pair(distance: float) -> Array:
	# 取两名不同队伍的角色, 摆到空旷区域面对面
	var attacker = null
	var victim = null
	for a in mm.actors:
		var act = a as Actor
		if act == null:
			continue
		if attacker == null:
			attacker = act
		elif act.team != attacker.team and victim == null:
			victim = act
	if attacker == null or victim == null:
		return []
	# 放到地图中央空地(中央大厅), 高度 0
	attacker.global_position = Vector3(0, 0.2, 20)
	victim.global_position = Vector3(0, 0.2, 20 - distance)
	# 攻击者朝 -Z (面向 victim)
	attacker.base_yaw = 0.0
	attacker.base_pitch = 0.0
	attacker.rotation.y = 0.0
	victim.base_yaw = PI
	victim.rotation.y = PI
	# 强制刷新 transform
	attacker.force_update_transform()
	victim.force_update_transform()
	# 关键: 变换改完要等物理帧, 物理服务器里的碰撞体位置才会同步
	await get_tree().physics_frame
	await get_tree().physics_frame
	return [attacker, victim]


func _reset(actor) -> void:
	actor.alive = true
	actor.health.reset_full()
	actor.health.armor = 0
	actor.health.has_helmet = false
	actor.health.has_kevlar = false


func _check(name: String, cond: bool, detail: String) -> void:
	print("  [%s] %-28s %s" % ["OK" if cond else "XX", name, detail])
	if not cond:
		failures.append(name + " -> " + detail)


## 绕过 HitSystem, 直接做一次原始射线, 看物理层到底能不能打中 hitbox
func _test_raw_raycast(hs) -> void:
	print("
-- 原始射线诊断 --")
	var pair: Array = await _make_pair(15.0)
	if pair.is_empty():
		print("   无法取得测试角色")
		return
	var attacker = pair[0]
	var victim = pair[1]
	_reset(attacker); _reset(victim)

	var space: PhysicsDirectSpaceState3D = hs.get_world_3d().direct_space_state
	if space == null:
		print("   [XX] direct_space_state 为 null")
		failures.append("物理空间为 null")
		return

	var origin: Vector3 = attacker.get_shoot_origin()
	var aim: Vector3 = victim.global_position + Vector3(0, 1.15, 0)
	var dir: Vector3 = (aim - origin).normalized()
	var to: Vector3 = origin + dir * 60.0

	print("   起点 %s  方向 %s" % [str(origin), str(dir)])
	print("   目标身体中心 %s" % str(victim.global_position + Vector3(0, 1.15, 0)))

	# A: 只打 hitbox 层
	var qa := PhysicsRayQueryParameters3D.create(origin, to)
	qa.collision_mask = GameConfig.LAYER_HITBOX
	qa.collide_with_areas = true
	qa.collide_with_bodies = false
	var ra: Dictionary = space.intersect_ray(qa)
	print("   A 仅 hitbox 层: %s" % ("命中 " + str(ra.get("collider").name) if not ra.is_empty() else "未命中"))

	# B: 只打世界层
	var qb := PhysicsRayQueryParameters3D.create(origin, to)
	qb.collision_mask = GameConfig.LAYER_WORLD
	qb.collide_with_areas = false
	qb.collide_with_bodies = true
	var rb: Dictionary = space.intersect_ray(qb)
	print("   B 仅世界层  : %s" % ("命中 " + str(rb.get("position")) if not rb.is_empty() else "未命中"))

	# C: 完整子弹掩码
	var qc := PhysicsRayQueryParameters3D.create(origin, to)
	qc.collision_mask = GameConfig.MASK_BULLET
	qc.collide_with_areas = true
	qc.collide_with_bodies = true
	var rc: Dictionary = space.intersect_ray(qc)
	print("   C 子弹掩码  : %s" % ("命中 " + str(rc.get("collider").name) if not rc.is_empty() else "未命中"))

	# D: hitbox 自身状态
	var hb: Array = victim.get_hitboxes()
	for h in hb:
		print("   hitbox %-5s layer=%d mask=%d monitorable=%s pos=%s" % [
			h.name, h.collision_layer, h.collision_mask,
			str(h.monitorable), str(h.global_position)])
	var shape = hb[1].get_child(0)
	print("   body shape=%s  disabled=%s" % [shape.shape.get_class(), str(shape.disabled)])

	var ok: bool = not ra.is_empty()
	_check("原始射线命中hitbox", ok, "A 测试结果")


## 直接调 HitSystem 内部的 _cast, 看它的 _space 与排除列表是否正常
func _test_internal_cast(hs) -> void:
	print("
-- HitSystem 内部射线 --")
	var pair: Array = await _make_pair(15.0)
	if pair.is_empty():
		return
	var attacker = pair[0]
	var victim = pair[1]
	_reset(attacker); _reset(victim)

	print("   _space = ", hs._space)
	if hs._space == null:
		failures.append("HitSystem._space 为 null")
		return

	var origin: Vector3 = attacker.get_shoot_origin()
	var aim: Vector3 = victim.global_position + Vector3(0, 1.15, 0)
	var dir: Vector3 = (aim - origin).normalized()

	# 不排除任何东西
	var r1: Dictionary = hs._cast(origin, dir, [])
	print("   _cast 无排除   : ", "命中 " + str(r1.get("collider").name) if not r1.is_empty() else "未命中")

	# 用 HitSystem 自己的排除逻辑
	var excluded: Array = []
	hs._self_and_children(attacker, excluded)
	print("   排除列表大小  : ", excluded.size())
	var r2: Dictionary = hs._cast(origin, dir, excluded)
	print("   _cast 带排除  : ", "命中 " + str(r2.get("collider").name) if not r2.is_empty() else "未命中")

	# 目标有效性
	if not r2.is_empty():
		var col = r2.get("collider")
		var vic = col.get_meta("actor", null)
		print("   目标 = ", vic.actor_name if vic != null else "null",
			"  alive=", str(vic.alive) if vic != null else "?",
			"  team_ok=", str(vic.team != attacker.team) if vic != null else "?")
		print("   _is_valid_target = ", str(hs._is_valid_target(attacker, vic)))


# ---------------------------------------------------------------- 用例
func _test_hitscan_basic(hs) -> void:
	print("\n-- 基础命中 --")
	var pair: Array = await _make_pair(15.0)
	if pair.is_empty():
		_check("基础命中", false, "无法取得测试角色")
		return
	var attacker = pair[0]
	var victim = pair[1]
	_reset(attacker)
	_reset(victim)

	var hp_before: float = victim.health.health
	var origin: Vector3 = attacker.get_shoot_origin()
	# 瞄准 victim 胸口
	var aim: Vector3 = victim.global_position + Vector3(0, 1.15, 0)
	var dir: Vector3 = (aim - origin).normalized()
	hs.fire_hitscan(attacker, "p01", origin, dir)
	var dealt: float = hp_before - victim.health.health

	_check("基础命中", dealt > 0.0, "15m 胸口造成 %.1f 伤害" % dealt)


func _test_hitgroup(hs) -> void:
	print("\n-- 部位倍率 --")
	var pair: Array = await _make_pair(15.0)
	if pair.is_empty():
		return
	var attacker = pair[0]
	var victim = pair[1]

	# 头部
	_reset(attacker); _reset(victim)
	var o: Vector3 = attacker.get_shoot_origin()
	var head_aim: Vector3 = victim.global_position + Vector3(0, 1.68, 0)
	hs.fire_hitscan(attacker, "p01", o, (head_aim - o).normalized())
	var head_dmg: float = 100.0 - victim.health.health

	# 腿部
	_reset(attacker); _reset(victim)
	o = attacker.get_shoot_origin()
	var leg_aim: Vector3 = victim.global_position + Vector3(0, 0.42, 0)
	hs.fire_hitscan(attacker, "p01", o, (leg_aim - o).normalized())
	var leg_dmg: float = 100.0 - victim.health.health

	var ratio: float = head_dmg / maxf(leg_dmg, 0.01)
	# 爆头 4.0 / 腿 0.75 = 5.33 倍
	_check("爆头倍率", head_dmg > leg_dmg * 4.0,
		"头 %.1f vs 腿 %.1f (比值 %.2f)" % [head_dmg, leg_dmg, ratio])
	_check("腿部减伤", leg_dmg > 0.0 and leg_dmg < head_dmg,
		"腿 %.1f" % leg_dmg)


func _test_armor(hs) -> void:
	print("\n-- 护甲吸收 --")
	var pair: Array = await _make_pair(15.0)
	if pair.is_empty():
		return
	var attacker = pair[0]
	var victim = pair[1]

	_reset(attacker); _reset(victim)
	var o: Vector3 = attacker.get_shoot_origin()
	var aim: Vector3 = victim.global_position + Vector3(0, 1.15, 0)
	hs.fire_hitscan(attacker, "p01", o, (aim - o).normalized())
	var no_armor: float = 100.0 - victim.health.health

	_reset(attacker); _reset(victim)
	victim.health.armor = 100
	victim.health.has_kevlar = true
	o = attacker.get_shoot_origin()
	hs.fire_hitscan(attacker, "p01", o, (aim - o).normalized())
	var with_armor: float = 100.0 - victim.health.health

	_check("护甲减伤", with_armor < no_armor,
		"无甲 %.1f -> 有甲 %.1f (护甲剩 %d)" % [
			no_armor, with_armor, victim.health.armor])
	_check("护甲被消耗", victim.health.armor < 100,
		"护甲 %d" % victim.health.armor)


func _test_falloff(hs) -> void:
	print("\n-- 距离衰减 --")
	var near: Array = await _make_pair(8.0)
	if near.is_empty():
		return
	var attacker = near[0]
	var victim = near[1]

	_reset(attacker); _reset(victim)
	var o: Vector3 = attacker.get_shoot_origin()
	var aim: Vector3 = victim.global_position + Vector3(0, 1.15, 0)
	hs.fire_hitscan(attacker, "p01", o, (aim - o).normalized())
	var d_near: float = 100.0 - victim.health.health

	var far: Array = await _make_pair(30.0)
	if far.is_empty():
		return
	attacker = far[0]
	victim = far[1]
	_reset(attacker); _reset(victim)
	o = attacker.get_shoot_origin()
	aim = victim.global_position + Vector3(0, 1.15, 0)
	hs.fire_hitscan(attacker, "p01", o, (aim - o).normalized())
	var d_far: float = 100.0 - victim.health.health

	_check("距离衰减", d_far < d_near and d_far > 0.0,
		"8m %.1f -> 30m %.1f" % [d_near, d_far])


func _test_penetration(hs) -> void:
	print("\n-- 穿透 --")
	var pair: Array = await _make_pair(15.0)
	if pair.is_empty():
		return
	var attacker = pair[0]
	var victim = pair[1]
	_reset(attacker); _reset(victim)

	# 用高穿透的步枪与低穿透的 SMG 对比, 中间不设障碍(直接命中)
	var o: Vector3 = attacker.get_shoot_origin()
	var aim: Vector3 = victim.global_position + Vector3(0, 1.15, 0)
	var dir: Vector3 = (aim - o).normalized()

	_reset(victim)
	hs.fire_hitscan(attacker, "ar17", o, dir)
	var rifle: float = 100.0 - victim.health.health

	_reset(victim)
	hs.fire_hitscan(attacker, "vector_x", o, dir)
	var smg: float = 100.0 - victim.health.health

	_check("武器伤害差异", rifle > smg, "AR-17 %.1f vs Vector-X %.1f" % [rifle, smg])
	_check("穿透参数可读",
		WeaponDatabase.get_weapon("ar17").get("penetration_power", 0.0) > 0.0,
		"AR-17 穿透力 %.2f" % float(
			WeaponDatabase.get_weapon("ar17").get("penetration_power", 0.0)))
