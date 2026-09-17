extends Node3D
class_name FireZone
##
## FireZone.gd — 燃烧区域(燃烧弹 / 汽油弹)
##
## 在 spread_time 内从中心扩散到最大半径, 持续对区域内角色施加燃烧伤害,
## 离开火焰后仍有短暂余烬伤害(afterburn)。
##

var dps: float = 42.0
var radius: float = 3.2
var duration: float = 7.0
var spread_time: float = 1.2
var afterburn_duration: float = 2.0
var afterburn_dps: float = 8.0

var thrower: Actor = null
var _elapsed: float = 0.0
var _current_radius: float = 0.3
var _particles: GPUParticles3D
var _material: StandardMaterial3D
var _ground: MeshInstance3D
var _tick: float = 0.0


func _ready() -> void:
	set_process(true)


func setup(center: Vector3, data: Dictionary, source: Actor) -> void:
	dps = float(data.get("dps", 42.0))
	radius = float(data.get("spread_radius", 3.2))
	duration = float(data.get("burn_duration", 7.0))
	spread_time = float(data.get("spread_time", 1.2))
	afterburn_duration = float(data.get("afterburn_duration", 2.0))
	afterburn_dps = float(data.get("afterburn_dps", 8.0))
	thrower = source
	global_position = center
	_build_visuals()


func _build_visuals() -> void:
	# headless(dummy 渲染驱动) 下不建 GPU 粒子, 火焰伤害逻辑仍然完整生效
	if DisplayServer.get_name() == "headless":
		_particles = null
		_build_ground_scorch()
		return
	_particles = GPUParticles3D.new()
	_particles.amount = 110
	_particles.lifetime = 1.1
	_particles.lifetime_randomness = 0.5
	_particles.emitting = true
	_particles.local_coords = true
	_particles.layers = GameConfig.FX_VISUAL_LAYER
	_particles.visibility_aabb = AABB(Vector3(-radius - 1, -0.5, -radius - 1),
		Vector3(radius * 2 + 2, 3.5, radius * 2 + 2))
	add_child(_particles)

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 1.0
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 18.0
	pm.initial_velocity_min = 1.2
	pm.initial_velocity_max = 2.6
	pm.gravity = Vector3(0, 1.4, 0)
	pm.damping_min = 1.4
	pm.damping_max = 2.6
	pm.scale_min = 0.55
	pm.scale_max = 1.35
	pm.color = Color(1.0, 0.45, 0.10)
	pm.color_ramp = _build_color_ramp()
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.6
	pm.turbulence_noise_scale = 2.2
	_particles.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	_particles.draw_pass_1 = quad

	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.depth_draw = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_material.vertex_color_use_as_albedo = true
	_material.albedo_color = Color(1.0, 0.5, 0.15, 0.85)
	_particles.material_override = _material
	_build_ground_scorch()


func _build_ground_scorch() -> void:
	_ground = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0
	cm.bottom_radius = 1.0
	cm.height = 0.03
	cm.radial_segments = 20
	_ground.mesh = cm
	var gm := StandardMaterial3D.new()
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.albedo_color = Color(0.06, 0.05, 0.05, 0.75)
	gm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ground.material_override = gm
	_ground.position = Vector3(0, 0.04, 0)
	add_child(_ground)


func _build_color_ramp() -> GradientTexture1D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.95, 0.55))
	grad.add_point(0.35, Color(1.0, 0.55, 0.12))
	grad.add_point(0.7, Color(0.85, 0.20, 0.05))
	grad.set_color(1, Color(0.15, 0.12, 0.12, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	gt.width = 64
	return gt


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= duration:
		queue_free()
		return

	var spread_k: float = clampf(_elapsed / maxf(spread_time, 0.01), 0.0, 1.0)
	_current_radius = lerpf(0.35, radius, spread_k)

	# 结束前淡出
	var fade: float = 1.0
	var remain: float = duration - _elapsed
	if remain < 1.0:
		fade = clampf(remain, 0.0, 1.0)

	if _ground != null:
		_ground.scale = Vector3(_current_radius, 1.0, _current_radius)
	if _particles != null:
		_particles.process_material.emission_sphere_radius = _current_radius * 0.85
		_particles.amount = int(110 * fade)
	if _material != null:
		_material.albedo_color = Color(1.0, 0.5, 0.15, 0.85 * fade)

	_tick += delta
	if _tick < 0.1:
		return
	_tick = 0.0
	_apply_burn(0.1)


func _apply_burn(step: float) -> void:
	for actor in get_tree().get_nodes_in_group("actors"):
		var a: Actor = actor as Actor
		if a == null or not a.alive:
			continue
		var p: Vector3 = a.global_position
		var dx: float = p.x - global_position.x
		var dz: float = p.z - global_position.z
		var dist2: float = dx * dx + dz * dz
		if dist2 > _current_radius * _current_radius:
			continue
		# 站在火焰高度范围内才受伤
		if p.y > global_position.y + 2.0:
			continue
		var dmg: float = dps * step * fade_factor()
		a.health.pending_weapon_id = "molotov"
		a.health.pending_killer = thrower
		a.health.apply_damage(dmg, 0.35, false, GameConfig.HitGroup.BODY, thrower)


func fade_factor() -> float:
	var remain: float = duration - _elapsed
	if remain < 1.0:
		return clampf(remain, 0.0, 1.0)
	return 1.0
