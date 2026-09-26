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
	# ---- 新增武器(本次扩充) ----
	await _test_hornet(hs)
	await _test_sable(hs)
	await _test_warden(hs)
	# ---- 倍镜 / 开火退镜语义 ----
	await _test_scope_zoom()
	await _test_unscope_after_shot()
	await _test_ads_spread_holds()
	# ---- 投掷物自伤上限 ----
	await _test_impact_self_damage()
	_test_impact_data_path()
	# ---- 狙击镜视觉(纯几何断言, 不依赖渲染输出) ----
	_test_scope_visual()
	# ---- G1: 准星必须忠实反映真实散布锥 ----
	_test_cone_feedback()

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


# ================================================================ 新增: 武器定向用例
# ---------------------------------------------------------------- 工具
## 与 HitSystem._compute_damage 同式: 基础伤害 * 距离衰减 * 部位倍率
func _expected_damage(wid: String, distance: float, group: int) -> float:
	var d: Dictionary = WeaponDatabase.get_weapon(wid)
	var mult: float = float(d["body_mult"])
	if group == GameConfig.HitGroup.HEAD:
		mult = float(d["headshot_mult"])
	elif group == GameConfig.HitGroup.LEGS:
		mult = float(d["leg_mult"])
	return float(d["damage"]) * WeaponDatabase.damage_falloff(wid, distance) * mult


## 拉高生命上限再打: 高伤武器(如狙击)会把 100 HP 打穿, 扣血量被截断在 100,
## 那样就测不出真实伤害与部位倍率。上限拉到 1000 后可以量到原始数值。
func _set_hp(actor, hp: float) -> void:
	actor.alive = true
	actor.health.max_health = hp
	actor.health.reset_full()
	actor.health.armor = 0
	actor.health.has_helmet = false
	actor.health.has_kevlar = false


func _restore_hp(actor) -> void:
	actor.health.max_health = GameConfig.MAX_HP
	_reset(actor)


## 冻结/解冻角色的物理处理。手动测量期间 Bot 会自己走动(以及被别的 Bot 打死),
## 于是"读取瞄准位置"与"物理服务器里碰撞体的实际位置"会不一致, 表现为部位倍率 /
## 伤害数值偶发失真(我实测见过一次 9 项同时报错、重跑即恢复)。冻结后角色不再
## 调 move_and_slide, 碰撞体不再漂移, 测量就变成确定性的。返回恢复用的凭据。
func _freeze(actors: Array) -> Array:
	var saved: Array = []
	for a in actors:
		var act := a as Actor
		if act == null:
			continue
		saved.append([act, act.is_physics_processing(), act.velocity])
		act.velocity = Vector3.ZERO
		act.set_physics_process(false)
	return saved


func _unfreeze(saved: Array) -> void:
	for e in saved:
		var act = e[0]
		if is_instance_valid(act):
			act.velocity = e[2]
			act.set_physics_process(bool(e[1]))


## 把一对角色钉在指定距离上: 先冻结物理, 再摆位, 再等两帧让物理服务器同步。
## 与 _make_pair 的区别是"摆完之后不会再漂", 因此测量可复现。
func _pin_pair(attacker, victim, distance: float) -> Array:
	var frozen: Array = _freeze([attacker, victim])
	attacker.global_position = Vector3(0, 0.2, 20)
	victim.global_position = Vector3(0, 0.2, 20.0 - distance)
	attacker.base_yaw = 0.0
	attacker.base_pitch = 0.0
	attacker.rotation.y = 0.0
	victim.base_yaw = PI
	victim.rotation.y = PI
	attacker.force_update_transform()
	victim.force_update_transform()
	await get_tree().physics_frame
	await get_tree().physics_frame
	return frozen


## 打一发, 返回 [受害者, 实际扣血]; 瞄准 point = victim_position + (0, aim_offset, 0)
func _shot(hs, wid: String, distance: float, aim_offset: float) -> Array:
	var pair: Array = await _make_pair(distance)
	if pair.is_empty():
		return []
	var attacker = pair[0]
	var victim = pair[1]
	var frozen: Array = await _pin_pair(attacker, victim, distance)
	_reset(attacker)
	_set_hp(victim, 1000.0)
	# 屏蔽无关角色的部位命中盒: Bot 会自由走动, 挡在射线上会吃掉伤害倍率
	var masked: Array = _mask_hitboxes([attacker, victim])
	var o: Vector3 = attacker.get_shoot_origin()
	var aim: Vector3 = victim.global_position + Vector3(0, aim_offset, 0)
	hs.fire_hitscan(attacker, wid, o, (aim - o).normalized())
	var dealt: float = 1000.0 - victim.health.health
	_unmask_hitboxes(masked)
	_unfreeze(frozen)
	return [victim, dealt]


## 临时把"非测试对象"的部位命中盒移出子弹掩码, 保证伤害数值只受被测武器影响
func _mask_hitboxes(keep: Array) -> Array:
	var saved: Array = []
	for a in mm.actors:
		var act := a as Actor
		if act == null or act in keep:
			continue
		for h in act.get_hitboxes():
			saved.append([h, h.collision_layer])
			h.collision_layer = 0
	return saved


func _unmask_hitboxes(saved: Array) -> void:
	for entry in saved:
		var h = entry[0]
		if is_instance_valid(h):
			h.collision_layer = int(entry[1])


## 头/腿同距离对打, 验证部位倍率(倍率越高越要拉高血上限, 见 _set_hp)
func _test_hitgroup_for(hs, wid: String, label: String) -> void:
	var pair: Array = await _make_pair(15.0)
	if pair.is_empty():
		_check("%s 部位倍率" % label, false, "无法取得测试角色")
		return
	var attacker = pair[0]
	var victim = pair[1]
	var frozen: Array = await _pin_pair(attacker, victim, 15.0)
	var masked: Array = _mask_hitboxes([attacker, victim])

	_reset(attacker)
	_set_hp(victim, 1000.0)
	var o: Vector3 = attacker.get_shoot_origin()
	var head_aim: Vector3 = victim.global_position + Vector3(0, 1.68, 0)
	hs.fire_hitscan(attacker, wid, o, (head_aim - o).normalized())
	var head_dmg: float = 1000.0 - victim.health.health

	_set_hp(victim, 1000.0)
	o = attacker.get_shoot_origin()
	var leg_aim: Vector3 = victim.global_position + Vector3(0, 0.42, 0)
	hs.fire_hitscan(attacker, wid, o, (leg_aim - o).normalized())
	var leg_dmg: float = 1000.0 - victim.health.health
	_unmask_hitboxes(masked)
	_unfreeze(frozen)

	var data: Dictionary = WeaponDatabase.get_weapon(wid)
	var want: float = float(data["headshot_mult"]) / float(data["leg_mult"])
	_check("%s 部位倍率" % label,
		leg_dmg > 0.0 and absf(head_dmg / maxf(leg_dmg, 0.01) - want) < 0.35,
		"头 %.1f vs 腿 %.1f (比值 %.2f, 期望 %.2f)" % [
			head_dmg, leg_dmg, head_dmg / maxf(leg_dmg, 0.01), want])
	_restore_hp(victim)


## 距离衰减: 两点实测都必须吻合数据曲线, 且远端不高于近端。
## 注: 走廊(x=0, 从 z=20 向 -z)在 25m 内首个命中必为受害者本人, 28m 起会先命中
## 一堵墙(world 穿透会把伤害乘以 penetration_damage_mult), 因此远端统一取 25m。
func _check_falloff(hs, wid: String, near_d: float, far_d: float, strict: bool) -> void:
	var near: Array = await _shot(hs, wid, near_d, 1.15)
	var far: Array = await _shot(hs, wid, far_d, 1.15)
	if near.is_empty() or far.is_empty():
		_check("%s 距离衰减" % wid, false, "无法取得测试角色")
		return
	var p_near: float = _expected_damage(wid, near_d, GameConfig.HitGroup.BODY)
	var p_far: float = _expected_damage(wid, far_d, GameConfig.HitGroup.BODY)
	var near_ok: bool = absf(near[1] - p_near) / maxf(p_near, 0.01) < 0.06
	var far_ok: bool = absf(far[1] - p_far) / maxf(p_far, 0.01) < 0.06
	var relation: bool = far[1] < near[1] if strict else far[1] <= near[1] * 1.02
	_check("%s 距离衰减" % wid, near_ok and far_ok and relation,
		"%.0fm %.1f(期望 %.1f) -> %.0fm %.1f(期望 %.1f)" % [
			near_d, near[1], p_near, far_d, far[1], p_far])
	_restore_hp(near[0])
	_restore_hp(far[0])


## 找一个可用角色(必须有 weapon_system)。优先存活者; 全死光则复活一个 —— 
## 状态机用例必须有活体角色, 否则 physics_tick 会直接 return 导致静默漏测。
func _pick_actor() -> Actor:
	var fallback: Actor = null
	for a in mm.actors:
		var act := a as Actor
		if act == null or act.weapon_system == null or not is_instance_valid(act):
			continue
		if fallback == null:
			fallback = act
		if act.alive:
			return act
	if fallback != null:
		_reset(fallback)
	return fallback


# ---------------------------------------------------------------- Hornet
func _test_hornet(hs) -> void:
	print("\n-- Hornet (SMG 1100rpm) --")
	var r: Array = await _shot(hs, "hornet", 12.0, 1.15)
	if r.is_empty():
		_check("Hornet 单发伤害", false, "无法取得测试角色")
		return
	var victim = r[0]
	var dealt: float = r[1]
	var expect: float = _expected_damage("hornet", 12.0, GameConfig.HitGroup.BODY)
	_check("Hornet 单发伤害", absf(dealt - expect) / maxf(expect, 0.01) < 0.06,
		"12m 胸口 实扣 %.1f / 期望 %.1f" % [dealt, expect])
	_restore_hp(victim)

	await _test_hitgroup_for(hs, "hornet", "Hornet")
	# Hornet 衰减曲线陡峭: 25m 内即可观察到明确下降(18.0 -> 13.7)
	await _check_falloff(hs, "hornet", 8.0, 25.0, true)


# ---------------------------------------------------------------- Sable
func _test_sable(hs) -> void:
	print("\n-- Sable (burst 780rpm) --")
	var r: Array = await _shot(hs, "sable", 20.0, 1.15)
	if r.is_empty():
		_check("Sable 单发伤害", false, "无法取得测试角色")
		return
	var victim = r[0]
	var dealt: float = r[1]
	var expect: float = _expected_damage("sable", 20.0, GameConfig.HitGroup.BODY)
	_check("Sable 单发伤害", absf(dealt - expect) / maxf(expect, 0.01) < 0.06,
		"20m 胸口 实扣 %.1f / 期望 %.1f" % [dealt, expect])
	_restore_hp(victim)

	await _test_hitgroup_for(hs, "sable", "Sable")
	# 步枪衰减曲线 24m 后才开始下降(25m 仅 -0.3%), 故既走数据校验也验"远端不更高"
	await _check_falloff(hs, "sable", 20.0, 25.0, false)

	await _test_sable_burst()
	_test_recoil_cycle("sable")
	_test_recoil_cycle("ar17")     # 长曲线(30 组)用来验证"循环末 6 发"规则本身


## 三连发状态机: 直接驱动 WeaponSystem.physics_tick, 不依赖输入层,
## 验证"3 发连射 -> 0.32s 停顿 -> 下一串"的确定性节奏。
func _test_sable_burst() -> void:
	var data: Dictionary = WeaponDatabase.get_weapon("sable")
	var mode: String = str(data.get("fire_mode", ""))
	if mode != "burst":
		_check("Sable fire_mode", false, "期望 burst, 实得 '%s'" % mode)
		return
	_check("Sable fire_mode", true, "burst / 弹匣 %d / 射速 %.0frpm / 间隔 %.4fs" % [
		int(data["magazine"]), float(data["rpm"]), float(data["fire_interval"])])

	var actor: Actor = _pick_actor()
	if actor == null:
		_check("Sable 连发行为", false, "没有可用角色")
		return
	var ws = actor.weapon_system
	var saved_id: String = ws.current_id
	var saved_slot: String = ws.current_slot
	var saved_hit = ws.hit_system
	var saved_next: float = ws._next_fire_at
	var saved_state: int = ws.state

	ws.hit_system = null          # 只测状态机, 避免向场上角色真开火
	ws.equip_weapon("sable", "primary", true)
	ws.ammo_in_mag = int(data["magazine"])
	ws.reserve_ammo = int(data["ammo_reserve"])
	ws._clock = 0.0
	ws._next_fire_at = 0.0
	ws._burst_remaining = 0
	ws.shot_count = 0
	ws.state = 0
	actor.intent.reset_all()
	actor.intent.fire_held = true      # 模拟"一直按住扳机"

	var times: Array[float] = []
	var mag: int = ws.ammo_in_mag
	var step: float = 1.0 / 128.0
	for i in 512:                      # 4 秒
		ws.physics_tick(step)
		if ws.ammo_in_mag < mag:
			mag = ws.ammo_in_mag
			times.append(ws._clock)

	var interval: float = float(data["fire_interval"])
	var gap1: float = times[1] - times[0] if times.size() >= 2 else -1.0
	_check("Sable 连发间隔", times.size() >= 2 and absf(gap1 - interval) < 0.01,
		"第 1-2 发间隔 %.4fs (期望 %.4fs)" % [gap1, interval])

	var pause: float = times[3] - times[2] if times.size() >= 4 else -1.0
	_check("Sable 三连发停顿", times.size() >= 4 and pause >= 0.30 and pause <= 0.37,
		"第 3-4 发间隔 %.3fs (期望 ~0.32s)" % pause)

	var group: int = 0
	var group_ok: bool = true
	for i in times.size():
		group += 1
		var gap_next: float = 99.0
		if i + 1 < times.size():
			gap_next = times[i + 1] - times[i]
		if gap_next > 0.2:
			if group != 3:
				group_ok = false
			group = 0
	_check("Sable 每串 3 发", group_ok and times.size() >= 9,
		"4 秒共 %d 发, 每串发数一致=%s" % [times.size(), str(group_ok)])

	print("     备注: 串间停顿 %.2fs 已超过 shot_count 重置窗口 0.28s, 因此每串都从"
		% pause)
	print("           recoil_pattern[0] 起算, pattern[3..5] 在当前节奏下不可达(数据冗余)")

	# 还原现场
	ws.hit_system = saved_hit
	ws._next_fire_at = saved_next
	ws.state = saved_state
	actor.intent.reset_all()
	if saved_id != "":
		ws.equip_weapon(saved_id, saved_slot, true)


## 后坐力曲线: 超出表长后"循环末尾 6 发"
func _test_recoil_cycle(wid: String) -> void:
	var pat: Array = WeaponDatabase.get_weapon(wid)["recoil_pattern"]
	var n: int = pat.size()
	var first: Vector2 = WeaponDatabase.recoil_at(wid, 0)
	var wrapped: Vector2 = WeaponDatabase.recoil_at(wid, n)
	if n > 6:
		# 长曲线: 第 n+1 发应落到"末 6 发"的起点, 而不是回到第 1 发
		var tail: Vector2 = WeaponDatabase.recoil_at(wid, n - 6)
		_check("%s 后坐力循环" % wid, wrapped == tail and wrapped != first,
			"表长 %d, 第 %d 发 == 第 %d 发 %s (循环末 6 发)" % [
				n, n + 1, n - 5, str(wrapped)])
	else:
		# 表长正好 6: 末 6 发就是整表, 循环等价于整表重复
		_check("%s 后坐力循环" % wid,
			n >= 6 and wrapped == first and WeaponDatabase.recoil_at(wid, n - 1) == pat[n - 1],
			"表长 %d, 第 %d 发 == 第 1 发 %s (整表即末 6 发)" % [n, n + 1, str(wrapped)])


# ---------------------------------------------------------------- Warden
func _test_warden(hs) -> void:
	print("\n-- Warden (sniper semi 150rpm) --")
	var r: Array = await _shot(hs, "warden", 15.0, 1.15)
	if r.is_empty():
		_check("Warden 单发伤害", false, "无法取得测试角色")
		return
	var victim = r[0]
	var dealt: float = r[1]
	var expect: float = _expected_damage("warden", 15.0, GameConfig.HitGroup.BODY)
	_check("Warden 单发伤害", absf(dealt - expect) / maxf(expect, 0.01) < 0.06,
		"15m 胸口 实扣 %.1f / 期望 %.1f" % [dealt, expect])
	_restore_hp(victim)

	await _test_hitgroup_for(hs, "warden", "Warden")
	# 狙击衰减曲线 <60m 设计为不衰减(25m 仍为 1.0), 因此这里验数据一致性
	await _check_falloff(hs, "warden", 15.0, 25.0, false)

	await _test_warden_semi()


## semi 语义: 一次"按下"只出一发, 按住不放不会再连发
func _test_warden_semi() -> void:
	var data: Dictionary = WeaponDatabase.get_weapon("warden")
	if str(data.get("fire_mode", "")) != "semi":
		_check("Warden fire_mode", false, "期望 semi, 实得 '%s'" % str(data.get("fire_mode", "")))
		return
	var actor: Actor = _pick_actor()
	if actor == null:
		_check("Warden 单击出一发", false, "没有可用角色")
		return
	var ws = actor.weapon_system
	var saved_id: String = ws.current_id
	var saved_slot: String = ws.current_slot
	var saved_hit = ws.hit_system
	var saved_state: int = ws.state

	ws.hit_system = null
	ws.equip_weapon("warden", "primary", true)
	ws.ammo_in_mag = int(data["magazine"])
	ws.reserve_ammo = int(data["ammo_reserve"])
	ws._clock = 0.0
	ws._next_fire_at = 0.0
	ws.shot_count = 0
	ws.state = 0
	actor.intent.reset_all()

	var mag0: int = ws.ammo_in_mag
	var step: float = 1.0 / 128.0
	# 第 1 次"按下" + 之后 1 秒持续采样(模拟按住不放)
	actor.intent.fire_pressed = true
	ws.physics_tick(step)
	actor.intent.fire_pressed = false
	for i in 128:
		ws.physics_tick(step)
	var shots: int = mag0 - ws.ammo_in_mag
	_check("Warden 单击出一发", shots == 1, "按下 1 次 / 1 秒内共 %d 发 (期望 1)" % shots)

	# 第 2 次"按下" -> 应能再出 1 发(间隔 0.4s 已过)
	actor.intent.fire_pressed = true
	ws.physics_tick(step)
	actor.intent.fire_pressed = false
	var shots2: int = mag0 - ws.ammo_in_mag
	_check("Warden 二次击发", shots2 == 2,
		"再按 1 次 -> 累计 %d 发 (期望 2), 间隔 %.3fs" % [
			shots2, float(data["fire_interval"])])

	ws.hit_system = saved_hit
	ws.state = saved_state
	actor.intent.reset_all()
	if saved_id != "":
		ws.equip_weapon(saved_id, saved_slot, true)


# ================================================================ 倍镜
func _test_scope_zoom() -> void:
	print("\n-- scope_zoom 倍镜 --")
	# 纯数学校验: 用固定的 90° 基准, 与玩家设置无关
	var ref: float = 90.0
	var fov4: float = WeaponSystem.fov_for_zoom(ref, 4.0)
	_check("倍率换算视场角", absf(fov4 - 28.07) < 0.2,
		"90° / 4.0x -> %.2f° (线性近似只有 %.1f°)" % [fov4, ref / 4.0])

	var actor: Actor = _pick_actor()
	if actor == null:
		_check("倍镜数据驱动", false, "没有可用角色")
		return
	var ws = actor.weapon_system
	var saved_id: String = ws.current_id
	var saved_slot: String = ws.current_slot
	# 基准 FOV 取玩家设置(默认 90, 但 user://settings.cfg 里可能是 70~120 的任意值),
	# 所有期望值都必须以 ws.base_fov 为基准推导, 不能写死 90
	var base: float = ws.base_fov
	print("     基准 FOV = %.0f° (来自玩家设置)" % base)

	var scoped: Array = WeaponDatabase.get_all_weapons().keys().filter(
		func(k): return WeaponDatabase.get_weapon(k).has("scope_zoom"))
	scoped.sort()
	var all_narrow: bool = true
	var detail: PackedStringArray = []
	for wid in scoped:
		var d: Dictionary = WeaponDatabase.get_weapon(wid)
		var zoom: float = float(d["scope_zoom"])
		ws.equip_weapon(wid, "primary", true)
		ws.ads_blend = 1.0
		var iron: float = base + float(d["ads_fov_delta"])
		var scoped_fov: float = ws.get_ads_fov()
		if absf(ws.get_scope_zoom() - zoom) > 0.001 or not ws.has_scope() \
				or scoped_fov >= iron or scoped_fov >= base:
			all_narrow = false
		detail.append("%s %.1fx %.1f°(机瞄%.0f°)" % [wid, zoom, scoped_fov, iron])
	_check("倍镜比机瞄更窄", all_narrow and scoped.size() >= 4,
		"%d 把: %s" % [scoped.size(), ", ".join(detail)])

	# 非倍镜武器: ads_fov_delta 语义与灵敏度系数必须与改动前完全一致
	ws.equip_weapon("ar17", "primary", true)
	ws.ads_blend = 1.0
	var d17: Dictionary = WeaponDatabase.get_weapon("ar17")
	_check("非倍镜语义不变",
		not ws.has_scope() \
		and absf(ws.get_ads_fov() - (base + float(d17["ads_fov_delta"]))) < 0.001 \
		and absf(ws.get_scope_sens_scale() - 1.0) < 0.001,
		"ar17 基准 %.0f° + delta %.0f = 开镜 %.0f°, 灵敏度系数 %.3f" % [
			base, float(d17["ads_fov_delta"]), ws.get_ads_fov(), ws.get_scope_sens_scale()])

	# 灵敏度方向: 倍率越高 -> 系数越小(绝不能"越放大越灵敏")
	ws.equip_weapon("warden", "primary", true)
	ws.ads_blend = 1.0
	var s2: float = ws.get_scope_sens_scale()
	ws.equip_weapon("longshot", "primary", true)
	ws.ads_blend = 1.0
	var s4: float = ws.get_scope_sens_scale()
	_check("灵敏度随倍率下降",
		s2 < 1.0 and s4 < s2 and absf(s2 - 0.5) < 0.001 and absf(s4 - 0.25) < 0.001,
		"2.0x -> %.3f ; 4.0x -> %.3f" % [s2, s4])

	# 相机 FOV 真的被驱动(读的是相机属性, 与渲染/GPU 无关, 无头下同样成立)
	ws.equip_weapon("warden", "primary", true)
	ws.ads_blend = 1.0
	ws.state = 0
	actor.intent.reset_all()
	actor.intent.ads = true
	ws.physics_tick(1.0 / 128.0)
	var cam: Camera3D = actor.get_camera()
	var want: float = ws.get_ads_fov()
	var applied: float = cam.fov if cam != null else -1.0
	_check("相机 FOV 生效", cam != null and absf(applied - want) < 0.5,
		"相机 %.2f° / 期望 %.2f°" % [applied, want])

	# 腰射(未开镜)必须回到基准 FOV
	ws.ads_blend = 0.0
	actor.intent.ads = false
	ws.physics_tick(1.0 / 128.0)
	_check("腰射回到基准 FOV", cam != null and absf(cam.fov - ws.base_fov) < 0.01,
		"相机 %.2f° / 基准 %.2f°" % [cam.fov if cam != null else -1.0, ws.base_fov])

	actor.intent.reset_all()
	if saved_id != "":
		ws.equip_weapon(saved_id, saved_slot, true)


## 开火退镜语义: 只有 unscope_after_shot = true 的武器才允许被清空开镜状态
func _test_unscope_after_shot() -> void:
	print("\n-- unscope_after_shot 语义 --")
	# 逐把武器验证: 声明 true 的必须开火后退镜, 其余必须保持开镜。
	# 这条覆盖的是本次修掉的真实缺陷 —— 旧代码写 `if str(...)` 恒为真,
	# 导致所有武器每开一枪都被强制退镜。
	var must_unscope: Array = []
	var must_keep: Array = []
	for wid in WeaponDatabase.get_all_weapons():
		var w: Dictionary = WeaponDatabase.get_weapon(wid)
		if str(w.get("class", "")) == "melee":
			continue          # 近战不能开镜, 不在语义范围内
		if bool(w.get("unscope_after_shot", false)):
			must_unscope.append(wid)
		else:
			must_keep.append(wid)
	must_unscope.sort()
	must_keep.sort()

	var actor: Actor = _pick_actor()
	if actor == null:
		_check("开火退镜语义", false, "没有可用角色")
		return
	var ws = actor.weapon_system
	var saved_id: String = ws.current_id
	var saved_slot: String = ws.current_slot
	var saved_hit = ws.hit_system
	ws.hit_system = null

	var bad_true: Array = []
	for wid in must_unscope:
		if _fire_once_in_ads(ws, actor, wid):
			bad_true.append(wid)
	var bad_false: Array = []
	for wid in must_keep:
		if not _fire_once_in_ads(ws, actor, wid):
			bad_false.append(wid)

	_check("unscope=true 自动退镜",
		bad_true.is_empty() and must_unscope.size() >= 2,
		"%d 把: %s" % [must_unscope.size(), ", ".join(must_unscope)])
	_check("unscope=false 保持开镜",
		bad_false.is_empty() and must_keep.size() >= 15,
		"%d 把全部保持开镜%s" % [must_keep.size(),
			"" if bad_false.is_empty() else " (异常: " + ", ".join(bad_false) + ")"])

	ws.hit_system = saved_hit
	actor.intent.reset_all()
	if saved_id != "":
		ws.equip_weapon(saved_id, saved_slot, true)


## 满开镜状态下开一枪, 返回"是否仍处于开镜状态"
func _fire_once_in_ads(ws, actor: Actor, wid: String) -> bool:
	var d: Dictionary = WeaponDatabase.get_weapon(wid)
	ws.equip_weapon(wid, "primary", true)
	ws.ammo_in_mag = int(d["magazine"])
	ws.reserve_ammo = int(d["ammo_reserve"])
	ws.ads_blend = 1.0
	ws.state = 0
	ws._next_fire_at = 0.0
	actor.intent.reset_all()
	actor.intent.ads = true
	actor.intent.fire_pressed = true
	ws.physics_tick(1.0 / 128.0)
	actor.intent.fire_pressed = false
	return ws.ads_blend > 0.5 and actor.intent.ads


## 连续射击一段时间, 返回稳定段内的观测量:
##   spread  最大实际扩散(度)
##   min_blend / min_fov  稳定段内 ads_blend 的最小值 / 相机 FOV 的最大值
func _sustained_fire_worst(ws, actor: Actor, aiming: bool, seconds: float) -> Dictionary:
	var d: Dictionary = WeaponDatabase.get_weapon(ws.current_id)
	ws.ammo_in_mag = int(d["magazine"])
	ws.reserve_ammo = 999
	ws.state = 0
	ws.dynamic_spread = 0.0
	ws._clock = 0.0
	ws._next_fire_at = 0.0
	ws._burst_remaining = 0
	ws.ads_blend = 1.0 if aiming else 0.0
	actor.intent.reset_all()
	actor.intent.crouch = true
	actor.intent.ads = aiming
	actor.intent.fire_held = true
	var worst: float = 0.0
	var min_blend: float = 1.0
	var max_fov: float = 0.0
	var step: float = 1.0 / 128.0
	for i in int(seconds / step):
		ws.physics_tick(step)
		if i > 16:                     # 跳过起手过渡, 只统计稳定段
			worst = maxf(worst, ws.get_current_spread())
			min_blend = minf(min_blend, ws.ads_blend)
			var cam := actor.get_camera()
			if cam != null:
				max_fov = maxf(max_fov, cam.fov)
	return {"spread": worst, "min_blend": min_blend, "max_fov": max_fov}


## 退镜缺陷的回归断言。
## 旧代码 `if str(data.get("unscope_after_shot", false))` 恒为真 -> 每开一枪把
## ads_blend 清零, 于是"按住开镜连续射击"时开镜状态被反复打断:
##   - 视野每枪弹回腰射 FOV(视觉上镜筒来回抽动)
##   - is_aiming() 恒为假 -> 开镜灵敏度/移速惩罚/开镜精度全部失效
## 这很可能就是 "瞄得准打不中" 的成因之一(G1)。
## 判定拆成三条, 前两条与角色姿态无关(不受移动/空中惩罚与 spread_max 上限影响):
##   1. 稳定连射期间 ads_blend 不得掉下来
##   2. 稳定连射期间相机 FOV 不得弹回腰射
##   3. 腰射与开镜的扩散差必须保住(本条目受 spread_max 截断影响, 故先把姿态钉死)
func _test_ads_spread_holds() -> void:
	print("\n-- 持续连射的开镜状态(退镜缺陷回归) --")
	var d: Dictionary = WeaponDatabase.get_weapon("ar17")
	var actor: Actor = mm.local_player
	if actor == null or actor.weapon_system == null:
		actor = _pick_actor()
	if actor == null:
		_check("开镜连射不掉镜", false, "没有可用角色")
		return
	var ws = actor.weapon_system
	var saved_id: String = ws.current_id
	var saved_slot: String = ws.current_slot
	var saved_hit = ws.hit_system
	var saved_speed: float = actor.horizontal_speed
	var saved_crouch: bool = actor.is_crouching
	ws.hit_system = null                 # 只测扩散, 不向场上开火
	ws.equip_weapon("ar17", "primary", true)

	# 姿态钉死: 手动驱动 physics_tick 不会推进角色物理, 因此把水平速度与蹲姿
	# 直接固定下来, 让"腰射/开镜"成为两次测量之间唯一的变量。空中/移动惩罚
	# 是叠加在两侧的基础扩散上再乘蹲姿系数的, 不钉死的话腰射侧会被 spread_max
	# 截断, 差值被压缩到无法判定(实测未钉死时差值仅 0.92°)。
	actor.horizontal_speed = 0.0
	actor.is_crouching = true
	actor.intent.reset_all()

	var hip: Dictionary = _sustained_fire_worst(ws, actor, false, 1.0)
	var ads: Dictionary = _sustained_fire_worst(ws, actor, true, 1.0)

	var ads_fov: float = ws.get_ads_fov()
	_check("开镜连射不掉镜", float(ads["min_blend"]) > 0.99,
		"稳定连射期间 ads_blend 最低 %.3f (旧缺陷为 0.000)" % float(ads["min_blend"]))
	_check("开镜连射视野稳定", ads_fov > 0.0 and float(ads["max_fov"]) <= ads_fov + 0.6,
		"稳定连射期间相机最大 %.2f° / 开镜目标 %.2f° (腰射基准 %.2f°)" % [
			float(ads["max_fov"]), ads_fov, ws.base_fov])

	# 蹲姿系数 0.72 会把"基础扩散差"等比缩小, 因此期望差值也乘 0.72;
	# 取 50% 作为下限, 只要求"优势确实存在且量级正确"。
	var expect: float = (float(d["spread_hip"]) - float(d["spread_ads"])) * 0.72
	var gap: float = float(hip["spread"]) - float(ads["spread"])
	_check("开镜连射扩散优势", gap > expect * 0.5,
		"腰射最大 %.2f° 开镜最大 %.2f° (差 %.2f°, 期望 %.2f°)" % [
			float(hip["spread"]), float(ads["spread"]), gap, expect])

	ws.hit_system = saved_hit
	actor.horizontal_speed = saved_speed
	actor.is_crouching = saved_crouch
	actor.intent.reset_all()
	if saved_id != "":
		ws.equip_weapon(saved_id, saved_slot, true)


# ================================================================ 投掷物自伤上限
## 在固定位置引爆一颗雷, 返回 {self, other, raw_self, raw_other, cap}
func _explode_case(gid: String, thrower: Actor, victim: Actor,
		pos: Vector3, self_dist: float, other_dist: float) -> Dictionary:
	var d: Dictionary = WeaponDatabase.get_grenade(gid)
	var radius: float = float(d["damage_radius"])
	var dmg0: float = float(d["damage"])
	var cap: float = float(d.get("max_safe_damage", 0.0))

	# 三者同高摆成一条线, 保证水平视线无遮挡; 距离即 3D 距离
	thrower.global_position = pos + Vector3(0, 0, self_dist)
	victim.global_position = pos + Vector3(0, 0, -other_dist)
	_set_hp(thrower, 1000.0)
	_set_hp(victim, 1000.0)

	var g := GrenadeBase.new()
	add_child(g)
	g.init_grenade(gid, thrower, pos, Vector3.ZERO, null)
	var fx_backup = GameManager.fx
	var snd_backup = GameManager.sound_manager
	GameManager.fx = null            # 无头下不需要爆炸特效/音效
	GameManager.sound_manager = null
	g.explode()
	GameManager.fx = fx_backup
	GameManager.sound_manager = snd_backup

	var raw_self: float = dmg0 * pow(1.0 - self_dist / radius, 2.0)
	var raw_other: float = dmg0 * pow(1.0 - other_dist / radius, 2.0)
	return {
		"self": 1000.0 - thrower.health.health,
		"other": 1000.0 - victim.health.health,
		"raw_self": raw_self,
		"raw_other": raw_other,
		"cap": cap,
	}


func _test_impact_self_damage() -> void:
	print("\n-- 爆炸自伤上限 (max_safe_damage) --")
	var pair: Array = await _make_pair(15.0)
	if pair.is_empty():
		_check("爆炸自伤上限", false, "无法取得测试角色")
		return
	var thrower: Actor = pair[0]
	var victim: Actor = pair[1]

	# 爆炸按 "actors" 组遍历, 临时把旁观者移出组, 避免误伤影响后续判定
	var bystanders: Array = []
	for a in mm.actors:
		var act := a as Actor
		if act != null and act != thrower and act != victim:
			act.remove_from_group("actors")
			bystanders.append(act)

	# impact: 1.0m 起爆(贴身), 自伤应被封顶; 0.5m 的对手吃满原始伤害
	var imp: Dictionary = _explode_case("impact", thrower, victim,
		Vector3(0, 1.2, 20), 1.0, 0.5)
	var want_self: float = imp["raw_self"] if float(imp["cap"]) <= 0.0 \
		else minf(imp["raw_self"], float(imp["cap"]))
	_check("impact 自伤封顶",
		absf(float(imp["self"]) - want_self) < 0.05 and float(imp["cap"]) > 0.0,
		"1.0m 原始 %.1f -> 实扣 %.1f (cap %.0f)" % [
			float(imp["raw_self"]), float(imp["self"]), float(imp["cap"])])
	_check("impact 对他人不封顶",
		absf(float(imp["other"]) - float(imp["raw_other"])) < 0.05 \
		and float(imp["raw_other"]) > float(imp["cap"]),
		"0.5m 非投掷者实扣 %.1f (原始 %.1f > cap %.0f)" % [
			float(imp["other"]), float(imp["raw_other"]), float(imp["cap"])])

	# he: 同样按各自声明的 max_safe_damage 封顶, 对他人不封顶
	var he: Dictionary = _explode_case("he", thrower, victim,
		Vector3(0, 1.2, 20), 0.5, 0.5)
	var he_self: float = he["raw_self"] if float(he["cap"]) <= 0.0 \
		else minf(he["raw_self"], float(he["cap"]))
	_check("he 自伤按声明封顶",
		absf(float(he["self"]) - he_self) < 0.05,
		"0.5m 原始 %.1f -> 实扣 %.1f (cap %.0f)" % [
			float(he["raw_self"]), float(he["self"]), float(he["cap"])])
	_check("he 对他人不封顶",
		absf(float(he["other"]) - float(he["raw_other"])) < 0.05,
		"0.5m 非投掷者实扣 %.1f" % float(he["other"]))

	for act in bystanders:
		act.add_to_group("actors")
	_restore_hp(thrower)
	_restore_hp(victim)
	# 等一帧让 GrenadeBase.queue_free() 真正回收, 否则退出时会报实例泄漏
	await get_tree().process_frame


## 瞬爆弹的数据 / 可达性
func _test_impact_data_path() -> void:
	print("\n-- 瞬爆弹数据与可达性 --")
	var d: Dictionary = WeaponDatabase.get_grenade("impact")
	if d.is_empty():
		_check("impact 数据", false, "WeaponDatabase 找不到 impact")
		return
	var kind: String = str(d.get("kind", ""))
	# BuyMenu._build_grenades 遍历 get_all_grenades() 并读 kind 做提示文案
	_check("impact 可购买枚举",
		WeaponDatabase.get_all_grenades().has("impact") and kind == "impact",
		"kind=%s / 售价 %d / 携带上限 %d" % [
			kind, int(d["price"]), int(d["max_carry"])])
	# BotController 投掷分支的谓词 (kind == "he" or kind == "impact") 对该数据成立
	_check("impact Bot 分支谓词", kind == "he" or kind == "impact",
		"谓词可满足(但不等于可达, 见交付说明)")
	_check("impact 手感参数",
		float(d["fuse_time"]) > 0.0 and float(d["fuse_time"]) <= 0.5 \
		and float(d["bounce"]) < float(WeaponDatabase.get_grenade("he")["bounce"]) \
		and float(d["throw_velocity"]) >= float(WeaponDatabase.get_grenade("he")["throw_velocity"]) \
		and float(d["throw_up_bias"]) <= float(WeaponDatabase.get_grenade("he")["throw_up_bias"]),
		"引信 %.2fs / 弹跳 %.2f / 摩擦 %.2f / 出手 %.1fm·s⁻¹ / 上抬 %.1f" % [
			float(d["fuse_time"]), float(d["bounce"]), float(d["friction"]),
			float(d["throw_velocity"]), float(d["throw_up_bias"])])

	# 玩家购买路径真的能走通(BuyMenu._buy_grenade -> Loadout.buy_grenade)
	var actor: Actor = _pick_actor()
	if actor == null:
		_check("impact 购买链路", false, "没有可用角色")
		return
	var lo = actor.loadout
	var money0: int = lo.money
	lo.money = maxi(money0, int(d["price"]) + 100)
	var bought: bool = lo.buy_grenade("impact")
	var owned: int = lo.get_grenade_count("impact")
	var consumed: bool = lo.consume_grenade("impact")
	lo.money = money0
	_check("impact 购买链路", bought and owned == 1 and consumed,
		"buy_grenade -> 持有 %d -> 消耗 %s" % [owned, str(consumed)])


# ================================================================ 狙击镜视觉(纯几何)
## 镜筒遮罩是纯 _draw 绘制的, 渲染输出在无头环境里看不见, 因此直接断言几何:
## 内圈必须是半径 r 的正圆, 外圈必须落在屏幕边界上, 且四边环带无退化。
func _test_scope_visual() -> void:
	print("\n-- 狙击镜遮罩几何(不依赖渲染) --")
	var view := Vector2(1920.0, 1080.0)
	var center: Vector2 = view * 0.5
	var r: float = 400.0
	var seg: int = 72
	var ring: Array = HudCanvas.build_scope_ring(center, r, view, seg)
	var inner: PackedVector2Array = ring[0]
	var outer: PackedVector2Array = ring[1]
	if inner.size() != seg or outer.size() != seg:
		_check("镜筒遮罩采样", false, "采样点数 %d/%d" % [inner.size(), outer.size()])
		return

	var circle_ok: bool = true
	var boundary_ok: bool = true
	var quad_ok: bool = true
	for i in seg:
		var din: float = inner[i].distance_to(center)
		if absf(din - r) > 0.05:
			circle_ok = false
		# 外圈点必须贴在屏幕边界上(到最近边的距离 ~0)。
		# 注意不能用 Rect2.has_point: 它是半开区间, 落在右/下边线上的点会被判为"不在矩形内"。
		var edge: float = minf(minf(outer[i].x, view.x - outer[i].x),
			minf(outer[i].y, view.y - outer[i].y))
		var inside: bool = outer[i].x >= -0.05 and outer[i].x <= view.x + 0.05 \
			and outer[i].y >= -0.05 and outer[i].y <= view.y + 0.05
		if edge > 0.05 or not inside:
			boundary_ok = false
		# 每个四边形环带必须非退化(面积 > 0), 且外圈严格包住内圈
		var j: int = (i + 1) % seg
		var a: Vector2 = inner[i]
		var b: Vector2 = inner[j]
		var c: Vector2 = outer[j]
		var d: Vector2 = outer[i]
		var area: float = absf((b - a).cross(d - a)) + absf((c - b).cross(a - b))
		if area <= 0.001 or outer[i].distance_to(center) <= din:
			quad_ok = false
	_check("镜筒遮罩采样", circle_ok, "%d 段内圈全部落在半径 %.0f 的圆上" % [seg, r])
	_check("镜筒遮罩贴合屏幕", boundary_ok, "外圈全部贴在 %.0fx%.0f 边界" % [view.x, view.y])
	_check("镜筒环带无退化", quad_ok, "%d 个环形四边形面积为正且外圈包住内圈" % seg)


# ================================================================ G1: 准星忠实度
## "瞄得准打不中" 有两个来源, 这条覆盖第二个:
##   1) 机械缺陷 —— 开火退镜把连射的开镜扩散抬回腰射水平(已在 _test_ads_spread_holds 覆盖)
##   2) 反馈缺陷 —— 准星是静态的, 玩家看不到子弹其实落在一个很大的圆里
##
## 这里用**引擎自己的投影**(Camera3D.unproject_position)去校验 HUD 的换算函数,
## 而不是拿同一套公式自我验证 —— 这才算独立证据。
func _test_cone_feedback() -> void:
	print("\n-- G1 准星忠实度(屏幕投影 vs 引擎投影) --")
	var actor: Actor = mm.local_player
	if actor == null:
		actor = _pick_actor()
	if actor == null:
		_check("准星投影换算", false, "没有可用角色")
		return
	var cam := actor.get_camera()
	if cam == null:
		_check("准星投影换算", false, "角色没有相机")
		return
	var view: Vector2 = cam.get_viewport().get_visible_rect().size
	if view.x <= 0.0 or view.y <= 0.0:
		view = Vector2(1920.0, 1080.0)

	# --- 1. 逐角度对照引擎投影 ---
	var worst_err: float = 0.0
	var detail: String = ""
	for spread in [1.0, 2.4, 3.4, 7.0, 12.0]:
		var hud_r: float = HudCanvas.cone_radius_px(float(spread), view, cam.fov)
		# 引擎侧: 在相机前方 20m 处、横向偏移 20*tan(spread) 的点, 投影到屏幕
		var d: float = 20.0
		var fwd: Vector3 = -cam.global_transform.basis.z
		var right: Vector3 = cam.global_transform.basis.x
		var p: Vector3 = cam.global_position + fwd * d \
			+ right * (d * tan(deg_to_rad(float(spread))))
		var sx: float = cam.unproject_position(p).x
		var engine_r: float = absf(sx - view.x * 0.5)
		var err: float = absf(engine_r - hud_r)
		worst_err = maxf(worst_err, err)
		detail += "%.1f°:HUD %.1fpx/引擎 %.1fpx  " % [float(spread), hud_r, engine_r]
	_check("准星投影换算", worst_err < 0.5,
		"视口 %.0fx%.0f fov %.1f°, 与引擎 unproject 最大偏差 %.3fpx | %s" % [
			view.x, view.y, cam.fov, worst_err, detail])

	# --- 2. 留白必须随散布单调增大, 且下限/上限有效 ---
	var mono_ok: bool = true
	var prev: float = -1.0
	for spread in [0.0, 0.5, 2.0, 5.0, 9.0, 14.0]:
		var r: float = HudCanvas.cone_radius_px(float(spread), view, cam.fov)
		if r < prev - 0.0001:
			mono_ok = false
		prev = r
	_check("准星留白单调", mono_ok and
		HudCanvas.cone_radius_px(0.0, view, cam.fov) < 0.001,
		"0→14° 单调不减, 且 0° 时半径为 0")

	# --- 3. 把"看不见的散布"变成可读数字(证据打印), 并断言一条数据层不变量 ---
	var ws = actor.weapon_system
	var saved_id: String = ws.current_id
	var saved_slot: String = ws.current_slot
	if ws.current_data.is_empty() or str(ws.current_data.get("class", "")) == "melee":
		ws.equip_weapon("ar17", "primary", true)
	# 复刻 get_current_spread() 的最终角度, 供人读; 不参与断言
	var d: Dictionary = WeaponDatabase.get_weapon("ar17")
	var hip: float = float(d["spread_hip"])
	var ads: float = float(d["spread_ads"])
	var mv: float = float(d["spread_move_add"])
	var air: float = float(d["spread_air_add"])
	var cap: float = float(d["spread_max"])
	print("    散布半径(米) @ ar17 —— 目标轮廓: 躯干半径 0.30m, 全高约 1.78m")
	print("    %-14s %6s %6s %6s %6s   %s" % [
		"姿态", "10m", "20m", "30m", "倍率", "准星正中胸口时的一发命中率 10/20/30m"])
	var rows := [
		["腰射 静止", hip],
		["腰射 走", hip + mv * 0.719],
		["腰射 跑", hip + mv],
		["腰射 空中", hip + air],
		["开镜 静止", ads],
		["开镜 走", (ads + mv * 0.719) * 0.72],
		["开镜 跑", (ads + mv) * 0.72],
		["开镜 空中", (ads + air) * 0.72],
	]
	for row in rows:
		var deg: float = minf(float(row[1]), cap)
		var r10: float = _tan_offset(deg, 10.0)
		var r20: float = _tan_offset(deg, 20.0)
		var r30: float = _tan_offset(deg, 30.0)
		print("    %-14s %6.2f %6.2f %6.2f %6.1fx   %.0f%% / %.0f%% / %.0f%%" % [
			str(row[0]), r10, r20, r30, r20 / 0.30,
			_hit_ratio(r10) * 100.0, _hit_ratio(r20) * 100.0, _hit_ratio(r30) * 100.0])
	# 不变量: 开镜的命中率不得低于同姿态的腰射(点估计, 会受数值再平衡影响, 只做方向断言)
	_check("开镜命中率不低于腰射",
		_hit_ratio(_tan_offset(minf(ads, cap), 20.0)) > _hit_ratio(_tan_offset(hip, 20.0)),
		"20m 静止: 开镜 %.0f%% > 腰射 %.0f%%" % [
			_hit_ratio(_tan_offset(minf(ads, cap), 20.0)) * 100.0,
			_hit_ratio(_tan_offset(hip, 20.0)) * 100.0])

	# 不变量: 开镜一定不差于腰射(数据层), 对全部非近战武器成立
	var bad: Array = []
	var counted: int = 0
	for wid in WeaponDatabase.get_all_weapons():
		var w: Dictionary = WeaponDatabase.get_weapon(wid)
		if str(w.get("class", "")) == "melee":
			continue
		counted += 1
		if float(w["spread_ads"]) > float(w["spread_hip"]):
			bad.append(str(wid))
	_check("数据层: 开镜不差于腰射", bad.is_empty(),
		"全部 %d 把非近战武器 spread_ads <= spread_hip%s" % [
			counted, "" if bad.is_empty() else " (异常: " + ", ".join(bad) + ")"])

	if saved_id != "":
		ws.equip_weapon(saved_id, saved_slot, true)


## 把角度换算成给定距离上的横向偏移(米), 即"子弹可能偏多远"。
func _tan_offset(deg: float, distance: float) -> float:
	return tan(deg_to_rad(maxf(deg, 0.0))) * distance


## 准星**正中胸口**时, 一发的命中概率。
##
## apply_spread 是在圆锥内**均匀采样圆盘**, 所以落点在半径 R 的圆盘上均匀分布,
## 于是 P(命中) = area(轮廓 ∩ 圆盘) / (π R²)。
## 轮廓按 Actor 里真实的三个 hitbox 取(y 以胸口 1.15 为原点):
##   躯干 CapsuleShape3D r=0.30 h=0.80 @1.15 -> 线段 (-0.10, +0.10), 半径 0.30
##   腿部 CapsuleShape3D r=0.26 h=0.70 @0.42 -> 线段 (-0.82, -0.64), 半径 0.26
##   头部 SphereShape3D   r=0.17          @1.68 -> 圆 (0, +0.53), 半径 0.17
## 用面积比而不是打射线, 是为了不依赖物理世界与角色是否存活。
func _hit_ratio(radius_m: float) -> float:
	if radius_m <= 0.0001:
		return 1.0
	var step: float = 0.006
	var hits: int = 0
	var r2: float = radius_m * radius_m
	var x: float = -0.36
	while x <= 0.36:
		var y: float = -1.06
		while y <= 0.72:
			if _in_silhouette(Vector2(x, y)) and x * x + y * y <= r2:
				hits += 1
			y += step
		x += step
	var area: float = float(hits) * step * step
	return clampf(area / (PI * radius_m * radius_m), 0.0, 1.0)


func _in_silhouette(p: Vector2) -> bool:
	if p.distance_to(Vector2(0.0, 0.53)) <= 0.17:
		return true
	return _dist_to_vertical_segment(p, -0.10, 0.10) <= 0.30 \
		or _dist_to_vertical_segment(p, -0.82, -0.64) <= 0.26


func _dist_to_vertical_segment(p: Vector2, y0: float, y1: float) -> float:
	var cy: float = clampf(p.y, y0, y1)
	return Vector2(p.x, p.y - cy).length()


