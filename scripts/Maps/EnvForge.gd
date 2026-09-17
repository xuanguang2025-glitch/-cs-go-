extends RefCounted
class_name EnvForge
##
## EnvForge.gd — 全局画面环境(光照 / 天空 / 雾 / 泛光 / 色调)统一构建器
##
## 设计要点:
##  1. 三张地图的环境原本各写一份, 参数分散难调; 这里收敛成 day/night/dusk
##     三套调色板, 共用同一套"现代渲染管线"模板(程序化天空 + SSIL + 体积雾
##     + ACES 色调映射 + 分级泛光 + 色调调整)。
##  2. 所有环境节点加入 "ps_world_env" 分组, 画质档位切换时可原地重新调校。
##  3. 竞技优先: 暗图(NIGHT)的亮度下限有硬约束, 环境光/补光必须保证敌人
##     轮廓可辨, 氛围服从可玩性。
##
##  注: 本引擎(Godot 4.4.1 custom)的色调调整属性名为单数 adjustment_*,
##      不是上游默认的 adjustments_* —— 用 _try_set() 双写兼容。
##

const ENV_GROUP := "ps_world_env"


# ================================================================ 对外接口
## 白昼(PROJECT ZERO): 高对比晴天, 冷蓝天光 + 暖阳光
static func build_day(root: Node3D) -> void:
	var env := _make_env(root, "day")
	_apply_day(env)
	_sun(root, Color(1.0, 0.96, 0.88), 2.35, Vector3(-48, 38, 0), 1.1, 95.0)
	_apply_quality(env)


## 夜间(NIGHT HARBOR): 深蓝夜空 + 冷月光, 靠暖色吊灯提供局部照明
static func build_night(root: Node3D) -> void:
	var env := _make_env(root, "night")
	_apply_night(env)
	_sun(root, Color(0.66, 0.76, 1.0), 0.95, Vector3(-55, -30, 0), 2.0, 80.0)
	_fill(root, Color(0.30, 0.38, 0.58), 0.42, Vector3(-20, 150, 0))
	_apply_quality(env)


## 黄昏(RED DISTRICT): 低角度橙色夕阳 + 暖雾, 体积雾承担光束
static func build_dusk(root: Node3D) -> void:
	var env := _make_env(root, "dusk")
	_apply_dusk(env)
	_sun(root, Color(1.0, 0.58, 0.32), 2.05, Vector3(-13, 42, 0), 1.4, 95.0)
	_fill(root, Color(0.45, 0.42, 0.58), 0.55, Vector3(-30, -135, 0))
	_apply_quality(env)


## 画质档位变化时原地重新调校场景内所有已建环境
static func retune_all() -> void:
	var st := Engine.get_main_loop() as SceneTree
	if st == null:
		return
	var tree: SceneTree = st
	for node in tree.get_nodes_in_group(ENV_GROUP):
		if node is WorldEnvironment:
			var e: Environment = (node as WorldEnvironment).environment
			if e != null:
				_apply_quality(e)


## 对单个 Environment 应用当前画质档位(重头戏: 开销大的效果在低档位关掉)
static func _apply_quality(env: Environment) -> void:
	var p: Dictionary = GraphicsQuality.preset()
	var tier: int = int(p.get("tier", GraphicsQuality.Tier.MEDIUM))
	var mid: bool = tier >= GraphicsQuality.Tier.MEDIUM
	var high: bool = tier >= GraphicsQuality.Tier.HIGH and tier != GraphicsQuality.Tier.COMPETITIVE
	var competitive: bool = bool(p.get("competitive", false))

	# 记录基础值，避免玩家反复切换画质时密度被重复乘除造成画面漂移。
	if not env.has_meta("ps_base_volumetric_density"):
		env.set_meta("ps_base_volumetric_density", env.volumetric_fog_density)
	if not env.has_meta("ps_base_fog_density"):
		env.set_meta("ps_base_fog_density", env.fog_density)

	# SSIL/SSAO 提供接触阴影和间接光，但竞技档关闭体积效果以保持轮廓稳定。
	env.ssil_enabled = mid and not competitive
	if env.ssil_enabled:
		env.ssil_radius = 2.8 if high else 1.8
		env.ssil_intensity = float(p.get("ssil", 1.0))
		env.ssil_sharpness = 0.98
		env.ssil_normal_rejection = 0.25

	env.ssao_enabled = true
	env.ssao_radius = 0.68 if high else 0.52
	env.ssao_intensity = 1.0 if competitive else (1.2 if mid else 0.82)
	env.ssao_power = 1.45
	env.ssao_detail = 0.72 if high else (0.45 if mid else 0.22)
	env.ssao_horizon = 0.08
	env.ssao_sharpness = 0.98
	env.ssao_light_affect = 0.0

	# 体积雾只在中高档开启，竞技档和低档关闭；密度以基础值为基准计算。
	var fog_enabled: bool = bool(p.get("volumetric_fog", false)) and not competitive
	env.volumetric_fog_enabled = fog_enabled
	var base_vol_density: float = float(env.get_meta("ps_base_volumetric_density", 0.0))
	env.volumetric_fog_density = base_vol_density * float(p.get("fog_scale", 0.0))
	if fog_enabled:
		env.volumetric_fog_length = 78.0 if tier >= GraphicsQuality.Tier.ULTRA else 42.0
		env.volumetric_fog_detail_spread = 1.65 if high else 3.2
		env.volumetric_fog_temporal_reprojection_enabled = tier >= GraphicsQuality.Tier.HIGH
		env.volumetric_fog_temporal_reprojection_amount = 0.88

	# 普通距离雾保持远景层次；竞技档降低而不是完全清空，避免地图失去空间感。
	var base_fog_density: float = float(env.get_meta("ps_base_fog_density", env.fog_density))
	env.fog_density = base_fog_density * (0.55 if competitive else 1.0)

	# 泛光分级: 只让枪火、灯具和霓虹等 HDR 光源产生光晕，避免廉价全屏发白。
	var levels: Array = p.get("glow_levels", [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	if env.has_method("set_glow_level"):
		for i in 7:
			env.set_glow_level(i, float(levels[i]))
	env.glow_enabled = not competitive or tier == GraphicsQuality.Tier.COMPETITIVE
	env.glow_intensity = 0.34 if competitive else (0.56 if high else 0.46)
	env.glow_strength = 0.72 if competitive else 0.9
	env.glow_hdr_threshold = 1.15 if competitive else 1.0
	_try_set(env, "ssr_enabled", tier >= GraphicsQuality.Tier.ULTRA and not competitive)
	_try_set(env, "ssr_max_steps", 48 if tier >= GraphicsQuality.Tier.CINEMATIC else 24)
	_try_set(env, "ssr_fade_in", 0.55)
	_try_set(env, "ssr_fade_out", 0.72)


# ================================================================ 环境模板
static func _make_env(root: Node3D, preset: String) -> Environment:
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnv"
	var env := Environment.new()

	env.background_mode = Environment.BG_SKY
	env.sky = _make_sky(preset)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.85
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# 色调映射: ACES 比 Filmic 对比更足、高光滚降更自然, 是 FPS 的主流选择
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.15

	# 泛光: 加色混合 + HDR 阈值 —— 只有真正的亮源(枪口火光/灯具/霓虹)起晕
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 1.0
	env.glow_hdr_luminance_cap = 12.0
	env.glow_normalized = true
	env.glow_mix = 0.06

	world_env.environment = env
	world_env.add_to_group(ENV_GROUP)
	root.add_child(world_env)
	return env


## 程序化天空: 零资源开销, 三套配色(晴/夜/黄昏)
static func _make_sky(preset: String) -> Sky:
	var psm := ProceduralSkyMaterial.new()
	psm.use_debanding = true
	match preset:
		"night":
			psm.sky_top_color = Color(0.012, 0.018, 0.045)
			psm.sky_horizon_color = Color(0.055, 0.08, 0.14)
			psm.sky_curve = 0.06
			psm.ground_bottom_color = Color(0.012, 0.014, 0.02)
			psm.ground_horizon_color = Color(0.05, 0.06, 0.09)
			psm.ground_curve = 0.02
			psm.sun_angle_max = 8.0
			psm.sun_curve = 0.04
			psm.energy_multiplier = 0.5
		"dusk":
			psm.sky_top_color = Color(0.10, 0.11, 0.28)
			psm.sky_horizon_color = Color(0.78, 0.36, 0.22)
			psm.sky_curve = 0.18
			psm.ground_bottom_color = Color(0.10, 0.07, 0.07)
			psm.ground_horizon_color = Color(0.34, 0.21, 0.17)
			psm.ground_curve = 0.06
			psm.sun_angle_max = 14.0
			psm.sun_curve = 0.03
			psm.energy_multiplier = 1.0
		_:  # day
			psm.sky_top_color = Color(0.16, 0.33, 0.62)
			psm.sky_horizon_color = Color(0.66, 0.75, 0.85)
			psm.sky_curve = 0.12
			psm.ground_bottom_color = Color(0.20, 0.20, 0.22)
			psm.ground_horizon_color = Color(0.44, 0.45, 0.47)
			psm.ground_curve = 0.03
			psm.sun_angle_max = 26.0
			psm.sun_curve = 0.06
			psm.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = psm
	return sky


static func _apply_day(env: Environment) -> void:
	env.ambient_light_energy = 0.85
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.15

	env.fog_enabled = true
	env.fog_light_color = Color(0.58, 0.66, 0.74)
	env.fog_light_energy = 1.0
	env.fog_density = 0.0022
	env.fog_aerial_perspective = 0.5
	env.fog_sun_scatter = 0.18
	env.fog_sky_affect = 1.0
	# 贴地薄雾: 让远景有层次, 又不遮挡中距离交战
	env.fog_height_density = 0.02

	env.volumetric_fog_density = 0.010
	env.volumetric_fog_albedo = Color(0.62, 0.68, 0.75)
	env.volumetric_fog_emission = Color(1.0, 0.94, 0.84)
	env.volumetric_fog_emission_energy = 0.35
	env.volumetric_fog_anisotropy = 0.35
	env.volumetric_fog_sky_affect = 0.35

	env.glow_intensity = 0.5
	env.glow_strength = 0.9
	env.glow_bloom = 0.11
	env.glow_hdr_threshold = 1.0
	_set_adjustment(env, 1.02, 1.06, 1.08)


static func _apply_night(env: Environment) -> void:
	# 夜图亮度下限: 环境光偏冷但保持 0.55 以上, 保证阴面人物仍可辨认
	env.ambient_light_energy = 0.6
	env.ambient_light_sky_contribution = 0.55
	env.tonemap_exposure = 1.12
	env.tonemap_white = 1.0

	env.fog_enabled = true
	env.fog_light_color = Color(0.04, 0.06, 0.11)
	env.fog_light_energy = 1.0
	env.fog_density = 0.0032
	env.fog_aerial_perspective = 0.6
	env.fog_sun_scatter = 0.35
	env.fog_height_density = 0.03

	env.volumetric_fog_density = 0.020
	env.volumetric_fog_albedo = Color(0.10, 0.14, 0.22)
	env.volumetric_fog_emission = Color(0.42, 0.58, 0.9)
	env.volumetric_fog_emission_energy = 0.5
	env.volumetric_fog_anisotropy = 0.25
	env.volumetric_fog_ambient_inject = 0.6

	# 霓虹/枪火/吊灯的辉光是夜图的灵魂, 阈值压低 + 强度拉高
	env.glow_intensity = 0.65
	env.glow_strength = 0.95
	env.glow_bloom = 0.16
	env.glow_hdr_threshold = 0.85
	_set_adjustment(env, 1.06, 1.12, 1.12)


static func _apply_dusk(env: Environment) -> void:
	env.ambient_light_energy = 0.7
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.2

	env.fog_enabled = true
	env.fog_light_color = Color(0.40, 0.24, 0.25)
	env.fog_light_energy = 1.0
	env.fog_density = 0.0028
	env.fog_aerial_perspective = 0.55
	env.fog_sun_scatter = 0.55   # 夕阳光束
	env.fog_height_density = 0.015

	env.volumetric_fog_density = 0.022
	env.volumetric_fog_albedo = Color(0.45, 0.30, 0.28)
	env.volumetric_fog_emission = Color(1.0, 0.56, 0.30)
	env.volumetric_fog_emission_energy = 0.8
	env.volumetric_fog_anisotropy = 0.55   # 前向散射越强, 光束越明显
	env.volumetric_fog_sky_affect = 0.5

	env.glow_intensity = 0.7
	env.glow_strength = 0.95
	env.glow_bloom = 0.15
	env.glow_hdr_threshold = 0.95
	_set_adjustment(env, 1.0, 1.08, 1.10)


# ================================================================ 灯光
static func _sun(root: Node3D, color: Color, energy: float, rot: Vector3,
		blur: float, max_dist: float) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "SunLight"
	sun.light_color = color
	sun.light_energy = energy
	sun.rotation_degrees = rot
	sun.shadow_enabled = true
	sun.shadow_blur = blur
	sun.directional_shadow_max_distance = max_dist
	sun.directional_shadow_split_1 = 0.03
	sun.directional_shadow_split_2 = 0.12
	sun.directional_shadow_split_3 = 0.35
	sun.directional_shadow_fade_start = 0.85
	sun.light_cull_mask = ~(GameConfig.FX_VISUAL_LAYER)
	_try_set(sun, "shadow_opacity", 0.92)
	_try_set(sun, "shadow_normal_bias", 1.0)
	_try_set(sun, "light_angular_distance", 0.45)
	root.add_child(sun)


static func _fill(root: Node3D, color: Color, energy: float, rot: Vector3) -> void:
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.light_color = color
	fill.light_energy = energy
	fill.rotation_degrees = rot
	fill.shadow_enabled = false
	fill.light_cull_mask = ~(GameConfig.FX_VISUAL_LAYER)
	root.add_child(fill)


# ================================================================ 工具
## 色调调整: 本引擎属性名为单数 adjustment_*, 上游默认为 adjustments_*,
## 两套都试一遍, 保证跨版本可用。
static func _set_adjustment(env: Environment, brightness: float,
		contrast: float, saturation: float) -> void:
	for prefix in ["adjustment", "adjustments"]:
		var n: String = prefix + "_enabled"
		if n in env:
			env.set(prefix + "_enabled", true)
			env.set(prefix + "_brightness", brightness)
			env.set(prefix + "_contrast", contrast)
			env.set(prefix + "_saturation", saturation)
			return


static func _try_set(target: Object, property_name: String, value: Variant) -> void:
	if target == null:
		return
	if property_name in target:
		target.set(property_name, value)
