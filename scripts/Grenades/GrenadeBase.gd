extends RigidBody3D
class_name GrenadeBase
##
## GrenadeBase.gd — 投掷物物理与引爆
##
## 使用 RigidBody3D 让引擎处理墙面/地面反弹, 物理材质参数来自 grenades.json。
## 引爆后按 kind 分派到 HE / Flash / Smoke / Molotov 四种效果。
##

var grenade_id: String = ""
var data: Dictionary = {}
var thrower: Actor = null
var kind: String = "he"
var fuse: float = 2.0
var _exploded: bool = false
var _bounce_count: int = 0

var _manager: Node = null


func _ready() -> void:
	collision_layer = GameConfig.LAYER_GRENADE
	collision_mask = GameConfig.LAYER_WORLD
	contact_monitor = true
	max_contacts_reported = 8
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body_entered.connect(_on_body_entered)
	set_physics_process(true)


func init_grenade(id: String, thrower_actor: Actor, spawn_pos: Vector3,
		velocity: Vector3, manager: Node) -> void:
	grenade_id = id
	data = WeaponDatabase.get_grenade(id)
	thrower = thrower_actor
	_manager = manager
	kind = str(data.get("kind", "he"))
	fuse = float(data.get("fuse_time", 2.0))

	global_position = spawn_pos
	linear_velocity = velocity
	angular_velocity = Vector3(
		randf_range(-12, 12), randf_range(-12, 12), randf_range(-12, 12))

	mass = float(data.get("mass", 0.6))
	gravity_scale = float(data.get("gravity_scale", 1.0))

	var pm := PhysicsMaterial.new()
	pm.bounce = float(data.get("bounce", 0.35))
	pm.friction = float(data.get("friction", 0.6))
	physics_material_override = pm

	_build_visual()


## 程序化投掷物外形(不同种类不同颜色/尺寸, 便于识别)
func _build_visual() -> void:
	var color := Color(str(data.get("color", "#888888")))
	var mi := MeshInstance3D.new()
	var mesh: Mesh
	match kind:
		"flash":
			var c := CapsuleMesh.new()
			c.radius = 0.045
			c.height = 0.12
			mesh = c
		"smoke":
			var c := CylinderMesh.new()
			c.top_radius = 0.05
			c.bottom_radius = 0.05
			c.height = 0.15
			c.radial_segments = 10
			mesh = c
		"molotov":
			var b := SphereMesh.new()
			b.radius = 0.075
			b.height = 0.15
			mesh = b
		_:
			var s := SphereMesh.new()
			s.radius = 0.062
			s.height = 0.124
			s.radial_segments = 8
			s.rings = 5
			mesh = s
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.65
	mi.material_override = mat
	add_child(mi)

	var shape := CollisionShape3D.new()
	var ss := SphereShape3D.new()
	ss.radius = 0.07
	shape.shape = ss
	add_child(shape)


func _physics_process(delta: float) -> void:
	if _exploded:
		return
	fuse -= delta
	if fuse <= 0.0:
		explode()


func _on_body_entered(body: Node) -> void:
	if _exploded:
		return
	_bounce_count += 1
	_play_bounce()
	# 燃烧弹触地即燃
	if kind == "molotov":
		explode()


func _play_bounce() -> void:
	if GameManager.sound_manager == null:
		return
	var pitch: float = randf_range(0.9, 1.15)
	GameManager.sound_manager.play_3d("dryfire", global_position, -16.0, pitch * 1.6, 14.0)


func explode() -> void:
	if _exploded:
		return
	_exploded = true
	set_physics_process(false)
	var pos := global_position

	match kind:
		"he":
			_explode_he(pos)
		"flash":
			_explode_flash(pos)
		"smoke":
			_explode_smoke(pos)
		"molotov":
			_explode_molotov(pos)
		_:
			_explode_he(pos)

	EventBus.grenade_exploded.emit(kind, pos)
	if _manager != null and _manager.has_method("on_grenade_exploded"):
		_manager.on_grenade_exploded(self)
	queue_free()


# ---------------------------------------------------------------- HE
func _explode_he(pos: Vector3) -> void:
	var radius: float = float(data.get("damage_radius", 4.5))
	var max_damage: float = float(data.get("damage", 98.0))
	var armor_pen: float = float(data.get("armor_penetration", 0.55))
	var impulse: float = float(data.get("impulse", 7.0))

	if GameManager.sound_manager != null:
		GameManager.sound_manager.play_3d("explosion", pos, 2.0, randf_range(0.92, 1.08), 110.0)
	if GameManager.fx != null:
		GameManager.fx.spawn_explosion(pos, radius)

	for actor in get_tree().get_nodes_in_group("actors"):
		var a: Actor = actor as Actor
		if a == null or not a.alive:
			continue
		var dist: float = a.global_position.distance_to(pos)
		if dist > radius:
			continue
		if not _has_line_of_sight(pos, a):
			continue
		# 线性衰减
		var falloff: float = 1.0 - clampf(dist / radius, 0.0, 1.0)
		var dmg: float = max_damage * falloff * falloff
		if dmg <= 1.0:
			continue
		# 爆炸伤害无视队伍归属(对自己的雷也生效)
		a.health.pending_weapon_id = "he"
		a.health.pending_killer = thrower
		a.health.apply_damage(dmg, armor_pen, false, GameConfig.HitGroup.BODY, thrower)
		# 击退
		if a.is_on_floor():
			var dir: Vector3 = (a.global_position - pos)
			dir.y = 0.0
			if dir.length_squared() > 0.0001:
				a.velocity += dir.normalized() * impulse * falloff
				a.velocity.y += impulse * 0.35 * falloff


func _has_line_of_sight(from: Vector3, target: Actor) -> bool:
	var space := get_world_3d().direct_space_state
	var chest: Vector3 = target.global_position + Vector3(0, 1.2, 0)
	var q := PhysicsRayQueryParameters3D.create(from, chest)
	q.collision_mask = GameConfig.LAYER_WORLD
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	# 命中点接近目标身体, 视为可见
	var hit_pos: Vector3 = hit["position"]
	return hit_pos.distance_to(chest) < 0.9


# ---------------------------------------------------------------- 闪光
func _explode_flash(pos: Vector3) -> void:
	var radius: float = float(data.get("effective_radius", 22.0))
	var base_dur: float = float(data.get("base_duration", 2.4))
	var min_dur: float = float(data.get("min_duration", 0.35))
	var max_dot: float = float(data.get("max_angle_dot", -0.25))
	var occl_penalty: float = float(data.get("occlusion_penalty", 0.55))

	if GameManager.sound_manager != null:
		GameManager.sound_manager.play_3d("flashbang", pos, 1.0, randf_range(0.95, 1.05), 120.0)
	if GameManager.fx != null:
		GameManager.fx.spawn_explosion(pos, radius * 0.25)

	for actor in get_tree().get_nodes_in_group("actors"):
		var a: Actor = actor as Actor
		if a == null or not a.alive:
			continue
		var dist: float = a.global_position.distance_to(pos)
		if dist > radius:
			continue

		var to_actor: Vector3 = (a.global_position + Vector3(0, 1.6, 0) - pos).normalized()
		var eye_pos: Vector3 = a.get_shoot_origin()
		var facing: Vector3 = a.get_shoot_direction()
		# 角度衰减: 背对闪光 -> 效果降低
		var facing_dot: float = facing.dot(-to_actor)
		var angle_factor: float = clampf((facing_dot + 0.4) / 1.4, 0.0, 1.0)

		var visible: bool = _has_line_of_sight(pos, a)
		var occl: float = 1.0 if visible else occl_penalty

		var dist_factor: float = 1.0 - clampf(dist / radius, 0.0, 1.0)
		var duration: float = lerpf(min_dur, base_dur, dist_factor) * angle_factor * occl
		if duration < 0.12:
			continue
		var intensity: float = clampf(duration / base_dur, 0.0, 1.0)
		EventBus.player_flashed.emit(a, intensity, duration)
		a.call("apply_flash", intensity, duration)


# ---------------------------------------------------------------- 烟雾
func _explode_smoke(pos: Vector3) -> void:
	if _manager == null:
		return
	# 落地: 贴着地面生成
	var ground_y: float = _probe_ground(pos)
	var center := Vector3(pos.x, ground_y, pos.z)
	if GameManager.sound_manager != null:
		GameManager.sound_manager.play_3d("smoke_emit", center, 0.0, 1.0, 60.0)
	_manager.call("add_smoke", center, data, thrower)


func _probe_ground(pos: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		pos + Vector3(0, 2.0, 0), pos - Vector3(0, 6.0, 0))
	q.collision_mask = GameConfig.LAYER_WORLD
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return pos.y
	return float(hit["position"].y) + 0.1


# ---------------------------------------------------------------- 燃烧
func _explode_molotov(pos: Vector3) -> void:
	if _manager == null:
		return
	var ground_y: float = _probe_ground(pos)
	var center := Vector3(pos.x, ground_y, pos.z)
	if GameManager.sound_manager != null:
		GameManager.sound_manager.play_3d("fire_burn", center, 0.0, 1.0, 45.0)
	_manager.call("add_fire", center, data, thrower)
