extends Node3D
class_name GrenadeManager
##
## GrenadeManager.gd — 投掷物生成 / 烟雾与火焰区域管理
##
## 对外提供 blocks_line(), 供 Bot 视线判定与命中反馈使用 —— 烟雾是真正参与
## 玩法计算的体积, 不只是视觉特效。
##

var smokes: Array = []
var fires: Array = []
var active_grenades: Array = []

var max_smokes: int = 6


func _ready() -> void:
	name = "GrenadeManager"
	GameManager.grenade_manager = self
	set_process(true)


func throw_grenade(actor: Actor, grenade_id: String, power: float) -> void:
	var data := WeaponDatabase.get_grenade(grenade_id)
	if data.is_empty():
		return
	var g := GrenadeBase.new()
	g.name = "Grenade_%s" % grenade_id
	add_child(g)
	active_grenades.append(g)

	var dir: Vector3 = actor.get_shoot_direction()
	var origin: Vector3 = actor.get_shoot_origin() + dir * 0.45 + Vector3(0, -0.12, 0)
	var speed: float = float(data.get("throw_velocity", 15.0)) * clampf(power, 0.35, 1.0)
	var up: float = float(data.get("throw_up_bias", 3.0))
	# 继承了投掷者的移动速度(真实感)
	var velocity: Vector3 = dir * speed + Vector3.UP * up + actor.velocity * 0.55
	g.init_grenade(grenade_id, actor, origin, velocity, self)


func add_smoke(center: Vector3, data: Dictionary, _thrower: Actor = null) -> void:
	if smokes.size() >= max_smokes:
		# 淘汰最老的一团
		var oldest = smokes.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
	var smoke := SmokeVolume.new()
	add_child(smoke)
	smoke.setup(center, data)
	smokes.append(smoke)


func add_fire(center: Vector3, data: Dictionary, thrower: Actor = null) -> void:
	var fire := FireZone.new()
	add_child(fire)
	fire.setup(center, data, thrower)
	fires.append(fire)


func on_grenade_exploded(g: Node) -> void:
	active_grenades.erase(g)


## 全局视线遮挡查询: 任意一团烟雾挡住线段即返回 true
func blocks_line(from: Vector3, to: Vector3) -> bool:
	for s in smokes:
		if not is_instance_valid(s):
			continue
		if s.blocks_line(from, to):
			return true
	return false


## 结合几何遮挡与烟雾遮挡的完整可见性判定
func has_visibility(from: Vector3, to: Vector3, exclude: Array = []) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	if blocks_line(from, to):
		return false
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = GameConfig.LAYER_WORLD
	if not exclude.is_empty():
		q.exclude = exclude
	var hit := space.intersect_ray(q)
	return hit.is_empty()


func clear_all() -> void:
	for s in smokes:
		if is_instance_valid(s):
			s.queue_free()
	smokes.clear()
	for f in fires:
		if is_instance_valid(f):
			f.queue_free()
	fires.clear()
	for g in active_grenades:
		if is_instance_valid(g):
			g.queue_free()
	active_grenades.clear()
