extends Node
class_name FXManager
##
## FXManager.gd — 特效对象池: 曳光弹 / 弹孔 / 火花 / 枪口火焰 / 弹壳 / 爆炸
##
## 所有临时对象全部池化复用, 运行期零分配, 避免粒子/爆炸造成掉帧。
## 手动积分物理(不创建 RigidBody), 只对少量对象做更新。
##

const POOL_TRACER := 64
const POOL_IMPACT := 96
const POOL_SHELL := 48
const POOL_SPARK := 160
const POOL_FLASH := 12
const POOL_MUZZLE_SMOKE := 24

const IMPACT_LIFETIME := 14.0
const SHELL_LIFETIME := 3.0
const TRACER_LIFETIME := 0.055
const SPARK_LIFETIME := 0.42
const FLASH_LIFETIME := 0.055
const MUZZLE_SMOKE_LIFETIME := 0.62

var _tracers: Array = []
var _impacts: Array = []
var _shells: Array = []
var _sparks: Array = []
var _flashes: Array = []
var _muzzle_smoke: Array = []

var _impact_cursor: int = 0
var _tracer_cursor: int = 0
var _muzzle_light: OmniLight3D
var _muzzle_smoke_clock: float = 0.0

var quality: int = 1   # 0=低 1=中 2=高


class FXItem:
	var node: Node3D
	var life: float = 0.0
	var max_life: float = 1.0
	var velocity: Vector3 = Vector3.ZERO
	var angular: Vector3 = Vector3.ZERO
	var active: bool = false
	var gravity: float = 0.0
	var fade: bool = true
	var drag: float = 0.0
	var base_scale: Vector3 = Vector3.ONE


func _ready() -> void:
	_build_pools()
	quality = int(GraphicsQuality.preset().get("fx_quality", 1))
	EventBus.graphics_changed.connect(_on_graphics_changed)
	set_process(true)


func _on_graphics_changed(_tier: int) -> void:
	quality = int(GraphicsQuality.preset().get("fx_quality", 1))


func _build_pools() -> void:
	for i in POOL_TRACER:
		var mi := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.022, 0.022, 1.0)
		mi.mesh = mesh
		mi.material_override = _mat(Color(1, 0.82, 0.42), true)
		mi.layers = GameConfig.FX_VISUAL_LAYER
		mi.visible = false
		add_child(mi)
		_tracers.append(_mk(mi, TRACER_LIFETIME))

	for i in POOL_IMPACT:
		var node := Node3D.new()
		var decal := MeshInstance3D.new()
		var dmesh := PlaneMesh.new()
		dmesh.size = Vector2(0.13, 0.13)
		decal.mesh = dmesh
		decal.material_override = _mat(Color(0.05, 0.05, 0.06), true)
		decal.layers = GameConfig.FX_VISUAL_LAYER
		decal.position = Vector3(0, 0, 0.004)
		node.add_child(decal)
		node.visible = false
		add_child(node)
		_impacts.append(_mk(node, IMPACT_LIFETIME))

	for i in POOL_SHELL:
		var mi := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.008
		mesh.bottom_radius = 0.008
		mesh.height = 0.036
		mesh.radial_segments = 6
		mi.mesh = mesh
		mi.material_override = _mat(Color(0.78, 0.62, 0.24), false)
		mi.layers = GameConfig.FX_VISUAL_LAYER
		mi.visible = false
		add_child(mi)
		_shells.append(_mk(mi, SHELL_LIFETIME))

	for i in POOL_SPARK:
		var mi := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.028, 0.028, 0.028)
		mi.mesh = mesh
		mi.material_override = _mat(Color(1.0, 0.72, 0.28), true)
		mi.layers = GameConfig.FX_VISUAL_LAYER
		mi.visible = false
		add_child(mi)
		_sparks.append(_mk(mi, SPARK_LIFETIME))

	for i in POOL_FLASH:
		var mi := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.09
		mesh.height = 0.18
		mesh.radial_segments = 8
		mesh.rings = 4
		mi.mesh = mesh
		mi.material_override = _mat(Color(1.0, 0.86, 0.5), true)
		mi.layers = GameConfig.FX_VISUAL_LAYER
		mi.visible = false
		add_child(mi)
		_flashes.append(_mk(mi, FLASH_LIFETIME))

	for i in POOL_MUZZLE_SMOKE:
		var smoke := MeshInstance3D.new()
		var smoke_mesh := SphereMesh.new()
		smoke_mesh.radius = 0.05
		smoke_mesh.height = 0.10
		smoke_mesh.radial_segments = 8
		smoke_mesh.rings = 4
		smoke.mesh = smoke_mesh
		smoke.material_override = _mat(Color(0.34, 0.34, 0.32, 0.28), true)
		smoke.layers = GameConfig.FX_VISUAL_LAYER
		smoke.visible = false
		add_child(smoke)
		_muzzle_smoke.append(_mk(smoke, MUZZLE_SMOKE_LIFETIME))

	_muzzle_light = OmniLight3D.new()
	_muzzle_light.light_energy = 2.2
	_muzzle_light.omni_range = 5.5
	_muzzle_light.light_color = Color(1.0, 0.82, 0.45)
	_muzzle_light.visible = false
	_muzzle_light.shadow_enabled = false
	add_child(_muzzle_light)


func _mk(node: Node3D, life: float) -> FXItem:
	var it := FXItem.new()
	it.node = node
	it.max_life = life
	it.base_scale = node.scale
	return it


func _mat(color: Color, transparent: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = transparent
	m.emission = color
	m.emission_energy_multiplier = 1.6
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if transparent:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = false
	return m


# ================================================================ 生成接口
func spawn_tracer(from: Vector3, to: Vector3, color: Color) -> void:
	var it: FXItem = _take(_tracers, _tracer_cursor)
	if it == null:
		return
	_tracer_cursor = (_tracer_cursor + 1) % _tracers.size()
	var mi: MeshInstance3D = it.node
	var dist: float = from.distance_to(to)
	mi.global_position = (from + to) * 0.5
	# 垂直方向时 look_at 会失败(up 与方向共线), 换一个参考轴
	if dist > 0.001:
		var dir: Vector3 = (to - from) / dist
		if absf(dir.dot(Vector3.UP)) > 0.999:
			mi.look_at(to, Vector3.RIGHT)
		else:
			mi.look_at(to, Vector3.UP)
	mi.scale = Vector3(1.0, 1.0, maxf(dist, 0.2))
	var mat: StandardMaterial3D = mi.material_override
	mat.albedo_color = color
	mat.emission = color
	mat.albedo_color.a = 0.85
	mi.visible = true
	it.active = true
	it.life = it.max_life
	it.fade = true


func spawn_impact(pos: Vector3, normal: Vector3, color: Color, surface: int = -1) -> void:
	var it: FXItem = _take(_impacts, _impact_cursor)
	if it == null:
		return
	_impact_cursor = (_impact_cursor + 1) % _impacts.size()
	var node: Node3D = it.node
	node.global_position = pos
	if normal.length_squared() > 0.0001:
		var n: Vector3 = normal.normalized()
		if absf(n.dot(Vector3.UP)) > 0.999:
			node.look_at(pos + n, Vector3.RIGHT)
		else:
			node.look_at(pos + n, Vector3.UP)
	node.rotate_object_local(Vector3(1, 0, 0), deg_to_rad(randf_range(0, 360)))
	var decal: MeshInstance3D = node.get_child(0)
	var mat: StandardMaterial3D = decal.material_override
	mat.albedo_color = Color(0.04, 0.04, 0.05, 0.92)
	node.scale = Vector3.ONE * randf_range(0.85, 1.25)
	node.visible = true
	it.active = true
	it.life = it.max_life
	it.fade = true
	it.velocity = Vector3.ZERO
	var spark_count: int = _impact_spark_count(surface)
	_spawn_sparks(pos, normal, color, spark_count, surface)


func _impact_spark_count(surface: int) -> int:
	if quality <= 0:
		return 1
	match surface:
		GameConfig.SurfaceMat.METAL:
			return 7 if quality >= 2 else 4
		GameConfig.SurfaceMat.GLASS:
			return 6 if quality >= 2 else 3
		GameConfig.SurfaceMat.WOOD:
			return 3 if quality >= 2 else 2
		GameConfig.SurfaceMat.CONCRETE:
			return 4 if quality >= 2 else 2
		_:
			return 3 if quality >= 2 else 1


func _spawn_sparks(pos: Vector3, normal: Vector3, color: Color, count: int, surface: int = -1) -> void:
	for i in count:
		var it: FXItem = _take_free(_sparks)
		if it == null:
			return
		var mi: MeshInstance3D = it.node
		mi.global_position = pos
		mi.visible = true
		mi.scale = Vector3.ONE * randf_range(0.5, 1.1)
		var mat: StandardMaterial3D = mi.material_override
		mat.albedo_color = color
		mat.emission = color
		it.active = true
		it.life = it.max_life * randf_range(0.6, 1.0)
		it.fade = true
		var dir: Vector3 = (normal + Vector3(
			randf_range(-0.9, 0.9), randf_range(-0.2, 1.0), randf_range(-0.9, 0.9))).normalized()
		var speed_min: float = 2.2
		var speed_max: float = 5.4
		var gravity: float = 12.0
		var drag: float = 2.4
		match surface:
			GameConfig.SurfaceMat.METAL:
				speed_min = 4.0
				speed_max = 8.0
				gravity = 8.0
				drag = 1.8
			GameConfig.SurfaceMat.GLASS:
				speed_min = 3.2
				speed_max = 7.0
				gravity = 10.0
				drag = 2.0
			GameConfig.SurfaceMat.WOOD:
				speed_min = 1.6
				speed_max = 4.0
				gravity = 14.0
		it.velocity = dir * randf_range(speed_min, speed_max)
		it.gravity = gravity
		it.drag = drag


func spawn_shell(pos: Vector3, right: Vector3, up: Vector3) -> void:
	if quality <= 0:
		return
	var it: FXItem = _take_free(_shells)
	if it == null:
		return
	var mi: MeshInstance3D = it.node
	mi.global_position = pos
	mi.visible = true
	it.active = true
	it.life = it.max_life
	it.fade = false
	it.gravity = 14.0
	it.velocity = right * randf_range(1.6, 2.8) + up * randf_range(1.4, 2.4) \
		+ Vector3(randf_range(-0.4, 0.4), 0, randf_range(-0.4, 0.4))
	it.angular = Vector3(randf_range(-18, 18), randf_range(-18, 18), randf_range(-18, 18))


func spawn_muzzle_flash(pos: Vector3, scale: float, color: Color) -> void:
	if quality <= 0:
		return
	var it: FXItem = _take_free(_flashes)
	if it == null:
		return
	var mi: MeshInstance3D = it.node
	mi.global_position = pos
	mi.scale = Vector3.ONE * scale * randf_range(0.85, 1.2)
	mi.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
	mi.visible = true
	var mat: StandardMaterial3D = mi.material_override
	mat.albedo_color = color
	mat.emission = color
	it.active = true
	it.life = it.max_life
	it.fade = true

	if is_local_flash(pos):
		_muzzle_light.global_position = pos
		_muzzle_light.light_energy = 2.4 * scale
		_muzzle_light.visible = true
		_muzzle_light.light_color = color
		if not _muzzle_light.has_meta("lit"):
			_muzzle_light.set_meta("lit", true)
		_muzzle_light.set_meta("timer", 0.05)

	# 枪口烟雾在高档位才逐渐累积，避免一发一团烟遮挡准星。
	if quality >= 2:
		spawn_muzzle_smoke(pos, scale, color)


func spawn_muzzle_smoke(pos: Vector3, scale: float, color: Color) -> void:
	var it: FXItem = _take_free(_muzzle_smoke)
	if it == null:
		return
	var smoke: MeshInstance3D = it.node
	smoke.global_position = pos
	smoke.scale = Vector3.ONE * scale * randf_range(0.45, 0.78)
	smoke.visible = true
	var mat: StandardMaterial3D = smoke.material_override
	mat.albedo_color = Color(0.30, 0.31, 0.30, 0.26)
	mat.emission = Color(0.04, 0.04, 0.035)
	it.active = true
	it.life = it.max_life * randf_range(0.72, 1.0)
	it.fade = true
	it.velocity = Vector3(randf_range(-0.08, 0.08), randf_range(0.12, 0.28), randf_range(-0.08, 0.08))
	it.gravity = -0.06
	it.drag = 0.18


func is_local_flash(_pos: Vector3) -> bool:
	# 只让距离本地玩家最近的枪口火焰使用实时光源, 避免大量动态光照。
	# 无头测试或场景切换瞬间可能拿到尚未入树的 Camera3D，不能读取其 global_transform。
	var cam := get_viewport().get_camera_3d()
	if cam == null or not cam.is_inside_tree():
		return false
	return cam.global_position.distance_to(_pos) < 12.0


func spawn_explosion(pos: Vector3, radius: float) -> void:
	var count: int = 14 if quality >= 2 else (9 if quality == 1 else 5)
	for i in count:
		var it: FXItem = _take_free(_sparks)
		if it == null:
			break
		var mi: MeshInstance3D = it.node
		mi.global_position = pos + Vector3(
			randf_range(-0.4, 0.4), randf_range(0, 0.5), randf_range(-0.4, 0.4))
		mi.visible = true
		mi.scale = Vector3.ONE * randf_range(1.4, 3.2)
		var mat: StandardMaterial3D = mi.material_override
		var c := Color(1.0, lerpf(0.35, 0.75, randf()), 0.12)
		mat.albedo_color = c
		mat.emission = c
		it.active = true
		it.life = it.max_life * randf_range(0.9, 1.6)
		it.fade = true
		it.gravity = 9.0
		it.drag = 1.6
		it.velocity = Vector3(
			randf_range(-1, 1), randf_range(0.1, 1.2), randf_range(-1, 1)
		).normalized() * randf_range(4.0, 11.0) * (radius / 4.5)


# ================================================================ 帧更新
func _process(delta: float) -> void:
	_update_pool(_tracers, delta)
	_update_pool(_impacts, delta)
	_update_pool(_shells, delta)
	_update_pool(_sparks, delta)
	_update_pool(_flashes, delta)
	_update_pool(_muzzle_smoke, delta)

	if _muzzle_light != null and is_instance_valid(_muzzle_light) and _muzzle_light.visible:
		var t: float = float(_muzzle_light.get_meta("timer", 0.0)) - delta
		if t <= 0.0:
			_muzzle_light.visible = false
		else:
			_muzzle_light.set_meta("timer", t)


func _update_pool(pool: Array, delta: float) -> void:
	for it in pool:
		if not it.active:
			continue
		it.life -= delta
		if it.life <= 0.0:
			_release(it)
			continue
		var node: Node3D = it.node
		if it.velocity != Vector3.ZERO or not is_zero_approx(it.gravity):
			it.velocity.y -= it.gravity * delta
			if it.drag > 0.0:
				it.velocity -= it.velocity * it.drag * delta
			node.global_position += it.velocity * delta
		if it.angular != Vector3.ZERO:
			node.rotate_x(it.angular.x * delta)
			node.rotate_y(it.angular.y * delta)
			node.rotate_z(it.angular.z * delta)
		if it.fade:
			var k: float = clampf(it.life / it.max_life, 0.0, 1.0)
			_apply_alpha(node, k)


func _apply_alpha(node: Node3D, k: float) -> void:
	var mi := node as MeshInstance3D
	var target: MeshInstance3D = mi if mi != null else (node.get_child(0) as MeshInstance3D)
	if target == null:
		return
	var mat: StandardMaterial3D = target.material_override
	if mat == null:
		return
	var c: Color = mat.albedo_color
	c.a = k
	mat.albedo_color = c


func _release(it: FXItem) -> void:
	it.active = false
	it.node.visible = false
	it.velocity = Vector3.ZERO
	it.angular = Vector3.ZERO
	it.gravity = 0.0
	it.fade = true
	it.drag = 0.0


func _take(pool: Array, cursor: int) -> FXItem:
	var it: FXItem = pool[cursor]
	return it


func _take_free(pool: Array) -> FXItem:
	for it in pool:
		if not it.active:
			return it
	return null


func reset() -> void:
	for pool in [_tracers, _impacts, _shells, _sparks, _flashes, _muzzle_smoke]:
		for it in pool:
			_release(it)
	_impact_cursor = 0
	_tracer_cursor = 0
