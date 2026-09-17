extends Node3D
class_name SmokeVolume
##
## SmokeVolume.gd — 体积烟雾
##
## 渲染: GPUParticles3D + 程序化噪声贴图(无外部资源), 粒子从地面涌出并膨胀。
## 遮挡: 不是透明贴图糊弄, 而是参与真实的视线判定 —— 线段采样检测是否穿过
##       烟雾圆柱体, Bot 的"能否看见敌人"与玩家的射线都受它影响。
##

const SAMPLES := 10

var radius: float = 4.2
var height: float = 5.0
var duration: float = 18.0
var build_time: float = 2.0
var fade_time: float = 2.5

var _elapsed: float = 0.0
var _intensity: float = 0.0
var _particles: GPUParticles3D
var _material: StandardMaterial3D
var _center: Vector3
var _noise_texture: NoiseTexture2D


func _ready() -> void:
	set_process(true)
	_center = global_position


func setup(center: Vector3, data: Dictionary) -> void:
	radius = float(data.get("radius", 4.2))
	height = float(data.get("height", 5.0))
	duration = float(data.get("duration", 18.0))
	build_time = float(data.get("build_time", 2.0))
	fade_time = float(data.get("fade_time", 2.5))
	global_position = center
	_center = center
	_build_particles()
	_name_unique()


func _name_unique() -> void:
	name = "Smoke_%d" % randi_range(1000, 9999)


func _make_noise_texture() -> NoiseTexture2D:
	if _noise_texture != null:
		return _noise_texture
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.035
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.45
	var tex := NoiseTexture2D.new()
	tex.width = 96
	tex.height = 96
	tex.seamless = true
	tex.as_normal_map = false
	tex.noise = noise
	_noise_texture = tex
	return tex


func _build_particles() -> void:
	# headless(dummy 渲染驱动) 下不建 GPU 粒子: 该驱动对粒子支持不完整。
	# 烟雾的视线遮挡与生命周期逻辑仍然完整生效。
	if DisplayServer.get_name() == "headless":
		return
	_particles = GPUParticles3D.new()
	_particles.amount = 180
	_particles.lifetime = 6.5
	_particles.lifetime_randomness = 0.55
	_particles.preprocess = 0.0
	_particles.emitting = true
	_particles.one_shot = false
	_particles.local_coords = true
	_particles.visibility_aabb = AABB(Vector3(-radius - 2, -1, -radius - 2),
		Vector3(radius * 2 + 4, height + 4, radius * 2 + 4))
	_particles.layers = GameConfig.FX_VISUAL_LAYER
	add_child(_particles)

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius * 0.72
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 42.0
	pm.initial_velocity_min = 0.35
	pm.initial_velocity_max = 1.25
	pm.gravity = Vector3(0, 0.28, 0)          # 轻微上浮
	pm.linear_accel_min = 0.0
	pm.linear_accel_max = 0.3
	pm.damping_min = 0.9
	pm.damping_max = 2.2
	pm.scale_min = 3.2
	pm.scale_max = 6.4
	pm.scale_curve = _build_scale_curve()
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.9
	pm.turbulence_noise_scale = 1.4
	pm.turbulence_influence_min = 0.3
	pm.turbulence_influence_max = 1.0
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
	_material.albedo_texture = _make_noise_texture()
	_material.albedo_color = Color(0.72, 0.75, 0.79, 0.0)
	_material.vertex_color_use_as_albedo = true
	_material.emission_enabled = false
	_particles.material_override = _material


func _build_scale_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.45))
	curve.add_point(Vector2(0.25, 1.0))
	curve.add_point(Vector2(0.7, 1.15))
	curve.add_point(Vector2(1.0, 0.6))
	var ct := CurveTexture.new()
	ct.curve = curve
	return ct


func _process(delta: float) -> void:
	_elapsed += delta

	if _elapsed < build_time:
		_intensity = _elapsed / maxf(build_time, 0.01)
	elif _elapsed < duration:
		_intensity = 1.0
	elif _elapsed < duration + fade_time:
		_intensity = 1.0 - (_elapsed - duration) / maxf(fade_time, 0.01)
	else:
		_intensity = 0.0
		queue_free()
		return

	_intensity = clampf(_intensity, 0.0, 1.0)

	if _material != null:
		var a: float = _intensity * 0.82
		_material.albedo_color = Color(0.72, 0.75, 0.79, a)

	if _particles != null:
		_particles.emitting = _elapsed < duration
		_particles.amount = int(lerpf(70.0, 180.0, _intensity))


# ---------------------------------------------------------------- 视线遮挡
func is_active() -> bool:
	return _intensity > 0.35


## 线段是否穿过烟雾(采样法, 兼顾精度与开销)
func blocks_line(from: Vector3, to: Vector3) -> bool:
	if not is_active():
		return false
	var eff_radius: float = radius * (0.55 + 0.45 * _intensity)
	var steps: int = SAMPLES
	for i in range(1, steps):
		var t: float = float(i) / float(steps)
		var p: Vector3 = from.lerp(to, t)
		if _contains_point(p, eff_radius):
			return true
	return false


func _contains_point(p: Vector3, eff_radius: float) -> bool:
	if p.y < _center.y - 0.15 or p.y > _center.y + height:
		return false
	var dx: float = p.x - _center.x
	var dz: float = p.z - _center.z
	return (dx * dx + dz * dz) < eff_radius * eff_radius


func get_center() -> Vector3:
	return _center + Vector3(0, height * 0.4, 0)
