extends RefCounted
class_name GraphicsQuality
##
## GraphicsQuality.gd - 六档画质统一调度
##
## 画质档位同时控制：抗锯齿、阴影、各向异性过滤、SSIL/SSAO、体积雾、
## 泛光、后处理、特效密度与竞技模式的可读性约束。所有参数集中在 preset，
## 地图、HUD、武器和玩法系统不依赖具体档位，方便后续替换真实资源。
##

enum Tier {
	LOW = 0,
	MEDIUM = 1,
	HIGH = 2,
	ULTRA = 3,
	CINEMATIC = 4,
	COMPETITIVE = 5,
}

const TIER_NAMES: Array = ["低", "中", "高", "超高", "电影", "竞技"]
const TIER_DESCRIPTIONS: Array = [
	"低配置优先",
	"平衡画质与性能",
	"高质量环境光照",
	"高端硬件推荐",
	"最大化视觉表现",
	"清晰轮廓与高帧率",
]
const TIER_COUNT := 6


static func current() -> int:
	return clampi(int(GameManager.get_setting("graphics_quality", Tier.MEDIUM)), 0, TIER_COUNT - 1)


static func tier_name(t: int = -1) -> String:
	if t < 0:
		t = current()
	return str(TIER_NAMES[clampi(t, 0, TIER_COUNT - 1)])


static func tier_description(t: int = -1) -> String:
	if t < 0:
		t = current()
	return str(TIER_DESCRIPTIONS[clampi(t, 0, TIER_COUNT - 1)])


static func set_tier(t: int) -> void:
	t = clampi(t, 0, TIER_COUNT - 1)
	GameManager.set_setting("graphics_quality", t)
	apply(t)
	EventBus.graphics_changed.emit(t)


static func cycle() -> int:
	var next: int = (current() + 1) % TIER_COUNT
	set_tier(next)
	return next


static func apply(t: int = -1) -> void:
	if t < 0:
		t = current()
	var p := preset(t)
	var st := Engine.get_main_loop() as SceneTree
	var root: Viewport = st.root if st != null else null

	if root != null:
		_vp_set(root, "msaa_3d", p["msaa"])
		_vp_set(root, "screen_space_aa", p["ssaa"])
		_vp_set(root, "use_debanding", p["deband"])
		_vp_set(root, "mesh_lod_threshold", p["lod"])

	_set_project("rendering/anti_aliasing/quality/msaa_3d", p["msaa"])
	_set_project("rendering/anti_aliasing/quality/screen_space_aa", p["ssaa"])
	_set_project("rendering/anti_aliasing/quality/use_debanding", p["deband"])
	_set_project("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", p["shadow_filter"])
	_set_project("rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality", p["shadow_filter"])
	_set_project("rendering/textures/default_filters/anisotropic_filtering_level", p["aniso"])
	_set_project("rendering/occlusion_culling/build_quality", p["occlusion_quality"])
	_set_project("rendering/renderer/rendering_method", "gl_compatibility" if p["compatibility"] else "forward_plus")
	Engine.max_fps = int(p["target_fps"])

	if GameManager.fx != null and is_instance_valid(GameManager.fx):
		GameManager.fx.quality = int(p["fx_quality"])

	EnvForge.retune_all()


static func preset(t: int = -1) -> Dictionary:
	if t < 0:
		t = current()
	t = clampi(t, 0, TIER_COUNT - 1)

	match t:
		Tier.LOW:
			return _make_preset(t, 0, 0, false, 1, 4, 4.0, 0.0, false, 0.0,
				[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], 0.25, 0.18, 0.0, 0.0, 0, 1, false, 60)
		Tier.MEDIUM:
			return _make_preset(t, 1, 1, true, 1, 8, 2.0, 0.78, true, 0.75,
				[1.0, 0.50, 0.22, 0.0, 0.0, 0.0, 0.0], 0.36, 0.25, 0.0, 0.008, 1, 1, false, 90)
		Tier.HIGH:
			return _make_preset(t, 1, 1, true, 2, 16, 1.0, 1.0, true, 1.0,
				[1.0, 0.68, 0.42, 0.22, 0.10, 0.04, 0.0], 0.48, 0.30, 0.0, 0.012, 2, 2, false, 120)
		Tier.ULTRA:
			return _make_preset(t, 2, 1, true, 3, 16, 0.65, 1.0, true, 1.15,
				[1.0, 0.78, 0.56, 0.34, 0.20, 0.10, 0.04], 0.52, 0.34, 0.05, 0.016, 3, 2, false, 144)
		Tier.CINEMATIC:
			return _make_preset(t, 2, 1, true, 3, 16, 0.45, 1.0, true, 1.35,
				[1.0, 0.86, 0.68, 0.48, 0.30, 0.18, 0.08], 0.46, 0.38, 0.08, 0.022, 3, 3, false, 120)
		Tier.COMPETITIVE:
			return _make_preset(t, 1, 1, true, 2, 16, 0.8, 0.0, false, 0.0,
				[1.0, 0.18, 0.0, 0.0, 0.0, 0.0, 0.0], 0.42, 0.12, 0.0, 0.0, 2, 2, false, 165)
	return _make_preset(Tier.MEDIUM, 1, 1, true, 1, 8, 2.0, 0.78, true, 0.75,
		[1.0, 0.50, 0.22, 0.0, 0.0, 0.0, 0.0], 0.36, 0.25, 0.0, 0.008, 1, 1, false, 90)


static func _make_preset(t: int, msaa: int, ssaa: int, deband: bool, shadow_filter: int,
		aniso: int, lod: float, fog_scale: float, volumetric_fog: bool, ssil: float,
		glow_levels: Array, sharpen: float, vignette: float, chromatic: float, grain: float,
		fx_quality: int, occlusion_quality: int, compatibility: bool, target_fps: int) -> Dictionary:
	return {
		"tier": t,
		"msaa": msaa,
		"ssaa": ssaa,
		"deband": deband,
		"shadow_filter": shadow_filter,
		"aniso": aniso,
		"lod": lod,
		"ssil": ssil,
		"fog_scale": fog_scale,
		"volumetric_fog": volumetric_fog,
		"glow_levels": glow_levels,
		"sharpen": sharpen,
		"vignette": vignette,
		"chromatic": chromatic,
		"grain": grain,
		"fx_quality": fx_quality,
		"occlusion_quality": occlusion_quality,
		"compatibility": compatibility,
		"target_fps": target_fps,
		"competitive": t == Tier.COMPETITIVE,
	}


static func _vp_set(vp: Viewport, prop: String, value: Variant) -> void:
	if vp == null:
		return
	if prop in vp:
		vp.set(prop, value)


static func _set_project(key: String, value: Variant) -> void:
	if ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, value)
