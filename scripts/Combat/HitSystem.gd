extends Node3D
class_name HitSystem
##
## HitSystem.gd — 服务器权威式命中检测 / 穿透 / 伤害结算
##
## 注意: 必须继承 Node3D —— 需要 get_world_3d() 才能拿到物理空间做射线检测。
##
## 射线流程:
##   1. 从枪口(或相机)沿方向投射, 同时检测世界几何与角色 hitbox, 取最近命中
##   2. 命中角色 -> 结算伤害, 子弹继续(可穿人), 伤害递减
##   3. 命中世界 -> 按材质扣除穿透力, 起点推进到命中点之后继续投射(背面不参与检测,
##      因此子弹自然从墙体内部穿出), 伤害乘以穿透衰减
##   4. 穿透力耗尽或达到最大穿透层数 -> 停止
##
## 伤害公式:
##   final = base_damage * distance_falloff * hitgroup_mult * penetration_mult
##   之后交给 HealthComponent 做护甲吸收
##

const MAX_RANGE := 320.0
const MAX_PENETRATION_STEPS := 5
const BODY_PENETRATION_COST := 0.28
const BODY_DAMAGE_MULT := 0.82
const STEP_EPSILON := 0.02

var fx: FXManager
var friendly_fire: bool = false
var sound: Node          # SoundManager

var _space: PhysicsDirectSpaceState3D


func _ready() -> void:
	call_deferred("_cache_space")


func _cache_space() -> void:
	if get_world_3d() != null:
		_space = get_world_3d().direct_space_state


# ================================================================ 主入口
## muzzle_pos 仅用于绘制曳光弹起点; 命中判定始终使用相机中心射线(origin/dir),
## 这样保证"准星指哪打哪", 视觉上又是从枪口出膛。
func fire_hitscan(shooter: Actor, weapon_id: String, origin: Vector3, dir: Vector3,
		muzzle_pos: Vector3 = Vector3.ZERO, rewind_ms: float = 0.0) -> void:
	if _space == null:
		_cache_space()
	if _space == null:
		return
	if shooter == null or not is_instance_valid(shooter):
		return
	if muzzle_pos == Vector3.ZERO:
		muzzle_pos = origin

	var data := WeaponDatabase.get_weapon(weapon_id)
	if data.is_empty():
		return

	# Lag Compensation: 判定前把其他角色倒回到射击者当时看到的位置, 判定完立刻恢复
	var rewound: bool = false
	if rewind_ms > 0.0 and NetworkManager.is_server:
		var all: Array = shooter.get_tree().get_nodes_in_group("actors")
		LagComp.rewind_all(all, shooter, rewind_ms, Time.get_ticks_msec())
		rewound = LagComp.is_rewound()

	var pellets: int = maxi(int(data["pellets"]), 1)
	for p in pellets:
		_cast_pellet(shooter, weapon_id, data, origin, dir, muzzle_pos)

	if rewound:
		LagComp.restore_all()


func _cast_pellet(shooter: Actor, weapon_id: String, data: Dictionary,
		origin: Vector3, dir: Vector3, muzzle_pos: Vector3) -> void:
	var penetration_left: float = float(data["penetration_power"])
	var damage_mult: float = 1.0
	var start: Vector3 = origin
	var excluded: Array = []
	_self_and_children(shooter, excluded)

	var end_point: Vector3 = origin + dir * MAX_RANGE
	var hit_any_actor := false
	var killed_someone := false
	var headshot := false

	for step in MAX_PENETRATION_STEPS:
		var result := _cast(start, dir, excluded)
		if result.is_empty():
			_draw_tracer(data, muzzle_pos, end_point)
			break

		var hit_pos: Vector3 = result["position"]
		var collider: Object = result["collider"]

		if collider is Area3D and collider.has_meta("hit_group"):
			var victim: Actor = collider.get_meta("actor")
			if not _is_valid_target(shooter, victim):
				# 队友: 阻挡子弹但不造成伤害。
				# 给本地玩家一个明确提示 —— 否则"打队友没反应"会被当成
				# "打人没伤害"的报告上来(实测真实对局里队友就在你旁边)。
				if shooter != null and shooter.is_local and victim != null \
						and is_instance_valid(victim) and victim.team == shooter.team:
					EventBus.friendly_hit.emit(shooter, victim)
				excluded.append(_rid_of(collider))
				start = hit_pos + dir * STEP_EPSILON
				continue

			hit_any_actor = true
			var group: int = int(collider.get_meta("hit_group"))
			var distance: float = origin.distance_to(hit_pos)
			var raw := _compute_damage(data, weapon_id, group, distance, damage_mult)
			var is_hs: bool = group == GameConfig.HitGroup.HEAD
			if is_hs:
				headshot = true

			# 归因必须在 apply_damage 之前写入, 否则死亡事件拿不到凶器
			victim.health.pending_weapon_id = weapon_id
			victim.health.pending_killer = shooter
			var armor_pen: float = float(data["armor_penetration"])
			var dealt: float = victim.health.apply_damage(
				raw, armor_pen, is_hs, group, shooter)

			_emit_hit_feedback(shooter, victim, dealt, is_hs, hit_pos, data)

			# 按"被击中的目标"逐个发射, 而不是整发子弹聚合一次:
			# 穿透后一发子弹可能打中多人, 每人的伤害 / 爆头 / 致死状态都不同,
			# 聚合会丢掉归因, 结算面板的伤害列会永远是 0。
			EventBus.hit_confirmed.emit(shooter, victim, dealt, is_hs,
				not victim.health.alive)

			if not victim.health.alive:
				killed_someone = true

			# 子弹穿过人体继续飞行
			penetration_left -= BODY_PENETRATION_COST
			damage_mult *= BODY_DAMAGE_MULT
			excluded.append(_rid_of(collider))
			start = hit_pos + dir * STEP_EPSILON
			if penetration_left <= 0.0:
				_draw_tracer(data, muzzle_pos, hit_pos)
				break
			continue

		# 命中世界几何
		var surface: int = int(collider.get_meta("surface",
			GameConfig.SurfaceMat.CONCRETE)) if collider.has_meta("surface") \
			else GameConfig.SurfaceMat.CONCRETE
		var color: Color = Color(str(collider.get_meta("impact_color", "#c8c8c8"))) \
			if collider.has_meta("impact_color") else Color(0.78, 0.78, 0.8)

		if fx != null:
			fx.spawn_impact(hit_pos, result.get("normal", Vector3.UP), color, surface)
		if sound != null and shooter != null and shooter.is_local:
			var impact_profile: String = _impact_sound_profile(surface)
			sound.play_3d(impact_profile, hit_pos, -11.0, randf_range(0.92, 1.08), 34.0)

		var cost: float = GameConfig.PENETRATION_COST.get(surface, 1.0)
		penetration_left -= cost
		if penetration_left <= 0.0:
			_draw_tracer(data, muzzle_pos, hit_pos)
			break

		damage_mult *= float(data["penetration_damage_mult"])
		start = hit_pos + dir * STEP_EPSILON
		# 记录该墙体, 避免来回弹跳重复命中
		excluded.append(_rid_of(collider))

	# 准星命中提示: 一发子弹只提示一次, 不管穿中了几个人。
	# 伤害统计走循环里的 hit_confirmed, 按目标逐个发射。
	if hit_any_actor and shooter != null and shooter.is_local:
		EventBus.hitmarker.emit(killed_someone, headshot)


func _is_valid_target(shooter: Actor, victim: Actor) -> bool:
	if victim == null or not is_instance_valid(victim):
		return false
	if not victim.alive:
		return false
	if victim == shooter:
		return false
	if victim.team == shooter.team and not friendly_fire:
		return false
	return true


func _compute_damage(data: Dictionary, weapon_id: String, group: int,
		distance: float, mult: float) -> float:
	var base: float = float(data["damage"])
	var falloff: float = WeaponDatabase.damage_falloff(weapon_id, distance)
	var raw: float = base * falloff * mult
	match group:
		GameConfig.HitGroup.HEAD:
			raw *= float(data["headshot_mult"])
		GameConfig.HitGroup.LEGS:
			raw *= float(data["leg_mult"])
		_:
			raw *= float(data["body_mult"])
	return raw


func _emit_hit_feedback(shooter: Actor, victim: Actor, dealt: float,
		is_hs: bool, pos: Vector3, data: Dictionary) -> void:
	EventBus.player_damaged.emit(victim, shooter, dealt, is_hs)
	if victim != null and victim.is_local:
		var dir: Vector3 = (victim.global_position - shooter.global_position).normalized()
		victim.on_hit_received(dealt, dir)
	if sound != null and shooter != null and shooter.is_local:
		sound.play_2d("hitmarker" if not is_hs else "headshot", -6.0, randf_range(0.94, 1.06))
	# 命中血雾(用小火花复用)
	if fx != null:
		var c := Color(0.72, 0.10, 0.10)
		fx.spawn_impact(pos, Vector3.UP, c)


func _draw_tracer(data: Dictionary, from: Vector3, to: Vector3) -> void:
	if fx == null:
		return
	fx.spawn_tracer(from, to, Color(data["tracer_color"]))


func _impact_sound_profile(surface: int) -> String:
	match surface:
		GameConfig.SurfaceMat.METAL:
			return "impact_metal"
		GameConfig.SurfaceMat.WOOD:
			return "impact_wood"
		GameConfig.SurfaceMat.GLASS:
			return "impact_glass"
		_:
			return "impact_concrete"


func _cast(from: Vector3, dir: Vector3, excluded: Array) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * MAX_RANGE)
	q.collision_mask = GameConfig.MASK_BULLET
	q.collide_with_bodies = true
	q.collide_with_areas = true
	q.hit_from_inside = false
	q.hit_back_faces = false
	if not excluded.is_empty():
		q.exclude = excluded
	return _space.intersect_ray(q)


func _self_and_children(node: Node, out: Array) -> void:
	out.append(_rid_of(node))
	for c in node.get_children():
		if c is CollisionObject3D:
			out.append(_rid_of(c))


func _rid_of(obj: Object) -> RID:
	if obj == null:
		return RID()
	if obj is CollisionObject3D:
		return obj.get_rid()
	if obj.has_method("get_rid"):
		return obj.call("get_rid")
	return RID()


# ================================================================ 近战
func fire_melee(shooter: Actor, weapon_id: String) -> void:
	if _space == null:
		_cache_space()
	if _space == null or shooter == null:
		return
	var data := WeaponDatabase.get_weapon(weapon_id)
	var reach: float = float(data.get("melee_range", 2.4))
	var origin: Vector3 = shooter.get_shoot_origin()
	var dir: Vector3 = shooter.get_shoot_direction()

	var excluded: Array = []
	_self_and_children(shooter, excluded)
	var result := _cast(origin, dir, excluded)
	if result.is_empty():
		return
	var hit_pos: Vector3 = result["position"]
	if origin.distance_to(hit_pos) > reach:
		return
	var collider: Object = result["collider"]
	if collider is Area3D and collider.has_meta("hit_group"):
		var victim: Actor = collider.get_meta("actor")
		if not _is_valid_target(shooter, victim):
			return
		var group: int = int(collider.get_meta("hit_group"))
		var raw := _compute_damage(data, weapon_id, group, origin.distance_to(hit_pos), 1.0)
		# 背刺判定: 从背后攻击
		var victim_facing: Vector3 = -victim.global_transform.basis.z
		if victim_facing.dot(dir) > 0.55:
			raw *= float(data.get("backstab_mult", 2.0))
		victim.health.pending_weapon_id = weapon_id
		victim.health.pending_killer = shooter
		var is_hs: bool = group == GameConfig.HitGroup.HEAD
		# 取 apply_damage 的返回值 = 护甲吸收后的真实伤害, 不能用穿透前的 raw
		var dealt: float = victim.health.apply_damage(raw,
			float(data["armor_penetration"]), is_hs, group, shooter)
		_emit_hit_feedback(shooter, victim, dealt, is_hs, hit_pos, data)
		EventBus.hit_confirmed.emit(shooter, victim, dealt, is_hs,
			not victim.health.alive)
		if shooter.is_local:
			EventBus.hitmarker.emit(not victim.health.alive, is_hs)
	elif fx != null:
		fx.spawn_impact(hit_pos, result.get("normal", Vector3.UP), Color(0.8, 0.8, 0.85))
