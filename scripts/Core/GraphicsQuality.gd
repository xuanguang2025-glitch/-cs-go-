extends RefCounted
class_name GraphicsQuality
##
## GraphicsQuality.gd - 六档画质统一调度
##
## 画质档位同时控制：抗锯齿(TAA/MSAA/FXAA)、阴影、各向异性过滤、
## SDFGI 全局光照、SSIL/SSAO、SSR、体积雾、反射探针、泛光、后处理、
## 材质细节等级、特效密度与竞技模式的可读性约束。
##
## ── 2026-09 画质重做要点（A1）────────────────────────────────────
##  1. **档位必须真的不一样**。改造前 LOW/MEDIUM/HIGH 三档的 msaa 与 ssaa
##     取值完全相同(都是 2x MSAA + FXAA), 差异只落在"运行期改 ProjectSettings"
##     的那几项上 —— 而运行期改阴影滤波质量/各向异性/阴影图尺寸是**无效**的
##     （这些值在渲染管线初始化时已读取完毕）。结果就是实测三档帧时间差
##     <0.5%, 玩家切档看不到任何区别。现在每一项都改成"运行期真正生效"的
##     参数（Viewport 属性 + Environment 属性 + 材质等级）。
##  2. **去掉人为帧率上限**。改造前 MEDIUM 把 Engine.max_fps 压到 90,
##     HIGH 压到 120, 而机器实测能跑 300+ FPS —— 等于用户花钱买的高刷屏
##     被我们自己锁死了。现在上限只作为"功耗地板"(LOW=60), 其余档位放到
##     180(vsync 上限), 不再成为瓶颈。
##  3. **新增 SDFGI**。本引擎没有硬件光追; SDFGI 是唯一能在运行期提供
##     「动态、多次弹射、被真实几何遮挡」的全局光照的手段, 是"光追级质感"
##     最主要的近似。但它单项实测约 11ms —— 比 141 FPS 的全部预算(7.09ms)
##     还多。因此它只作为**超高/电影**档的旗舰特效, 不进默认可玩档位。
##  4. **新增反射探针与材质等级**。反射探针提供真实空间反射(近似光追反射),
##     材质等级控制 MaterialForge 的程序化 PBR 细节深度。
##  5. 需要重启才生效的项目级设置(阴影图尺寸/软阴影滤波)仍然写入
##     ProjectSettings, 但**不再当作运行期可调项**宣传 —— 见 RESTART_REQUIRED。
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
	"低配置优先：无 TAA/GI，材质仅纯色",
	"平衡画质与性能：TAA + 接触阴影 + 程序化材质",
	"高质量画面：4x MSAA + 反射探针 + 最强体积雾",
	"旗舰展示：SDFGI 实时全局光照 + 法线细节 + SSR",
	"最大化视觉表现：最远 SDFGI + 最强分级与体积雾",
	"清晰轮廓与高帧率：关 GI/体积雾，保 TAA 与材质",
]
const TIER_COUNT := 6

## 运行期改了也不生效、必须重启游戏的项目级设置。集中列在这里,
## 避免以后又有人把这些当成"切档即时生效"来用。
const RESTART_REQUIRED: Array = [
	"rendering/lights_and_shadows/directional_shadow/size",
	"rendering/lights_and_shadows/positional_shadow/atlas_size",
	"rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality",
	"rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality",
	"rendering/textures/default_filters/anisotropic_filtering_level",
	"rendering/occlusion_culling/bvh_build_quality",
	"rendering/world/occlusion_culling/build_quality",
	"rendering/anti_aliasing/quality/use_taa",
	"rendering/global_illumination/sdfgi/probe_ray_count",
	"rendering/global_illumination/sdfgi/frames_to_converge",
]


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
		# 以下全部是 Viewport 属性 —— 切档即时生效, 无需重启。
		_vp_set(root, "msaa_3d", p["msaa"])
		_vp_set(root, "screen_space_aa", p["ssaa"])
		_vp_set(root, "use_taa", p["taa"])
		_vp_set(root, "use_debanding", p["deband"])
		_vp_set(root, "mesh_lod_threshold", p["lod"])
		_vp_set(root, "use_occlusion_culling", p["occlusion_enabled"])
		_vp_set(root, "positional_shadow_atlas_size", p["shadow_atlas"])
		_vp_set(root, "scaling_3d_mode", p["scaling_mode"])
		_vp_set(root, "scaling_3d_scale", p["scaling"])

	# 项目级设置: 只对"下次启动"有意义, 但写进去能让编辑器/导出包里保持
	# 与当前档位一致的默认值, 因此保留。真正的即时生效靠上面的 Viewport 属性。
	_set_project("rendering/anti_aliasing/quality/msaa_3d", p["msaa"])
	_set_project("rendering/anti_aliasing/quality/screen_space_aa", p["ssaa"])
	_set_project("rendering/anti_aliasing/quality/use_taa", p["taa"])
	_set_project("rendering/anti_aliasing/quality/use_debanding", p["deband"])
	_set_project("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", p["shadow_filter"])
	_set_project("rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality", p["shadow_filter"])
	_set_project("rendering/lights_and_shadows/directional_shadow/size", p["shadow_size"])
	_set_project("rendering/lights_and_shadows/positional_shadow/atlas_size", p["shadow_atlas"])
	_set_project("rendering/textures/default_filters/anisotropic_filtering_level", p["aniso"])
	_set_project("rendering/occlusion_culling/bvh_build_quality", p["occlusion_quality"])
	_set_project("rendering/world/occlusion_culling/build_quality", p["occlusion_quality"])
	_set_project("rendering/occlusion_culling/use_occlusion_culling", p["occlusion_enabled"])
	_set_project("rendering/renderer/rendering_method", "gl_compatibility" if p["compatibility"] else "forward_plus")
	Engine.max_fps = int(p["target_fps"])

	if GameManager.fx != null and is_instance_valid(GameManager.fx):
		GameManager.fx.quality = int(p["fx_quality"])

	# 材质细节等级(程序化 PBR)。放在 EnvForge 之前: 材质先换好, 环境再按新
	# 档位调曝光/雾/GI, 避免出现"旧材质 + 新环境"的中间态。
	MaterialForge.set_level(int(p["material_level"]))

	EnvForge.retune_all()


static func preset(t: int = -1) -> Dictionary:
	if t < 0:
		t = current()
	t = clampi(t, 0, TIER_COUNT - 1)
	var p: Dictionary = _PRESETS[t].duplicate()
	p["tier"] = t
	p["competitive"] = t == Tier.COMPETITIVE
	return p


# msaa: 0=off 1=2x 2=4x        ssaa: 0=off 1=FXAA (开 TAA 时 FXAA 冗余 → 关)
# shadow_filter: 0..3 (Soft/High/Ultra)   aniso: 0=off 1=2x 2=4x 3=8x 4=16x
# shadow_atlas: 2048/4096/8192 (位置光源阴影图集, 夜图 12 盏点光靠它)
# material_level: MaterialForge.LEVEL_OFF/BASIC/FULL
# sdfgi_y_scale: Environment.SDFGI_Y_SCALE_* (地图扁平时压缩垂直体素)
const _PRESETS: Array = [
	# ---------------------------------------------------------- LOW
	{
		"msaa": 0, "ssaa": 1, "taa": false, "deband": false,
		"shadow_filter": 1, "shadow_size": 2048, "shadow_atlas": 2048,
		"aniso": 1, "lod": 3.0,
		"ssil": 0.0, "fog_scale": 0.0, "volumetric_fog": false,
		"sdfgi": false, "sdfgi_cascades": 2, "sdfgi_occlusion": false,
		"sdfgi_y_scale": Environment.SDFGI_Y_SCALE_75_PERCENT, "sdfgi_energy": 1.0,
		"reflection_probe": false, "probe_energy": 0.0,
		"material_level": MaterialForge.LEVEL_OFF,
		"glow_levels": [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
		"sharpen": 0.30, "vignette": 0.18, "chromatic": 0.0, "grain": 0.0,
		"grade_gain": 1.00, "grade_gamma": 1.00, "grade_lift": 0.0,
		"grade_sat": 1.00, "grade_contrast": 1.00,
		"fx_quality": 0, "occlusion_quality": 1, "occlusion_enabled": false,
		"scaling": 1.0, "scaling_mode": Viewport.SCALING_3D_MODE_BILINEAR,
		"compatibility": false, "target_fps": 60,
	},
	# ---------------------------------------------------------- MEDIUM (默认)
	# 这一档必须"看起来就像换了个游戏": TAA 消锯齿 + SSIL 接触阴影 +
	# 体积雾 + 反射探针 + 程序化 PBR 材质(albedo/roughness/三平面)。
	{
		"msaa": 1, "ssaa": 0, "taa": true, "deband": true,
		"shadow_filter": 2, "shadow_size": 4096, "shadow_atlas": 4096,
		"aniso": 2, "lod": 1.6,
		"ssil": 0.9, "fog_scale": 0.8, "volumetric_fog": true,
		"sdfgi": false, "sdfgi_cascades": 3, "sdfgi_occlusion": false,
		"sdfgi_y_scale": Environment.SDFGI_Y_SCALE_75_PERCENT, "sdfgi_energy": 1.0,
		"reflection_probe": true, "probe_energy": 0.40,
		"material_level": MaterialForge.LEVEL_BASIC,
		"glow_levels": [1.0, 0.50, 0.22, 0.0, 0.0, 0.0, 0.0],
		"sharpen": 0.34, "vignette": 0.24, "chromatic": 0.0, "grain": 0.006,
		# 分级只做"影调"(饱和/对比), 不叠加整体提亮 —— 提亮交给 Environment
		# 的曝光, 否则两处叠加会把水泥面推成惨白。
		"grade_gain": 1.00, "grade_gamma": 1.00, "grade_lift": 0.0,
		"grade_sat": 1.06, "grade_contrast": 1.04,
		"fx_quality": 1, "occlusion_quality": 1, "occlusion_enabled": true,
		"scaling": 1.0, "scaling_mode": Viewport.SCALING_3D_MODE_BILINEAR,
		"compatibility": false, "target_fps": 165,
	},
	# ---------------------------------------------------------- HIGH
	# 4x MSAA + 最强体积雾/泛光 + 反射探针 + 程序化材质。**不含 SDFGI 与法线贴图**
	# —— 这两项实测代价过大(11ms / 不稳定), 只给旗舰档。见 D3 成本表。
	{
		"msaa": 2, "ssaa": 0, "taa": true, "deband": true,
		"shadow_filter": 3, "shadow_size": 4096, "shadow_atlas": 4096,
		"aniso": 3, "lod": 1.0,
		"ssil": 1.0, "fog_scale": 1.0, "volumetric_fog": true,
		"sdfgi": false, "sdfgi_cascades": 3, "sdfgi_occlusion": false,
		"sdfgi_y_scale": Environment.SDFGI_Y_SCALE_75_PERCENT, "sdfgi_energy": 1.0,
		# 反射探针强度刻意压低: 盒式探针覆盖整张图时, 两份探针叠加会给粗糙
		# 表面补上可观的间接能量, 实测把墙面/地面整体抬亮约一档曝光
		# (天空亮度不变 → 说明是表面补光而不是色调映射问题)。0.4 左右只留下
		# 金属/玻璃该有的空间反光, 不再影响水泥面的明度平衡。
		"reflection_probe": true, "probe_energy": 0.40,
		# 法线贴图(LEVEL_FULL)实测在三平面映射下不稳定且开销显著, 只给旗舰档。
		# 高/中档用 LEVEL_BASIC(albedo + roughness + 三平面), 已能去掉"纯色盒子"。
		"material_level": MaterialForge.LEVEL_BASIC,
		"glow_levels": [1.0, 0.68, 0.42, 0.22, 0.10, 0.04, 0.0],
		"sharpen": 0.42, "vignette": 0.30, "chromatic": 0.0, "grain": 0.010,
		"grade_gain": 1.00, "grade_gamma": 1.00, "grade_lift": 0.0,
		"grade_sat": 1.08, "grade_contrast": 1.05,
		"fx_quality": 2, "occlusion_quality": 2, "occlusion_enabled": true,
		"scaling": 1.0, "scaling_mode": Viewport.SCALING_3D_MODE_BILINEAR,
		"compatibility": false, "target_fps": 180,
	},
	# ---------------------------------------------------------- ULTRA
	{
		"msaa": 3, "ssaa": 0, "taa": true, "deband": true,
		"shadow_filter": 3, "shadow_size": 4096, "shadow_atlas": 8192,
		"aniso": 4, "lod": 0.65,
		"ssil": 1.15, "fog_scale": 1.15, "volumetric_fog": true,
		"sdfgi": true, "sdfgi_cascades": 4, "sdfgi_occlusion": true,
		"sdfgi_y_scale": Environment.SDFGI_Y_SCALE_50_PERCENT, "sdfgi_energy": 1.05,
		"reflection_probe": true, "probe_energy": 0.55,
		"material_level": MaterialForge.LEVEL_FULL,
		"glow_levels": [1.0, 0.78, 0.56, 0.34, 0.20, 0.10, 0.04],
		"sharpen": 0.46, "vignette": 0.34, "chromatic": 0.05, "grain": 0.014,
		"grade_gain": 1.00, "grade_gamma": 1.01, "grade_lift": 0.0,
		"grade_sat": 1.10, "grade_contrast": 1.06,
		"fx_quality": 3, "occlusion_quality": 2, "occlusion_enabled": true,
		"scaling": 1.0, "scaling_mode": Viewport.SCALING_3D_MODE_BILINEAR,
		"compatibility": false, "target_fps": 180,
	},
	# ---------------------------------------------------------- CINEMATIC
	{
		"msaa": 2, "ssaa": 0, "taa": true, "deband": true,
		"shadow_filter": 3, "shadow_size": 4096, "shadow_atlas": 8192,
		"aniso": 4, "lod": 0.45,
		"ssil": 1.35, "fog_scale": 1.35, "volumetric_fog": true,
		"sdfgi": true, "sdfgi_cascades": 4, "sdfgi_occlusion": true,
		"sdfgi_y_scale": Environment.SDFGI_Y_SCALE_50_PERCENT, "sdfgi_energy": 1.1,
		"reflection_probe": true, "probe_energy": 0.60,
		"material_level": MaterialForge.LEVEL_FULL,
		"glow_levels": [1.0, 0.86, 0.68, 0.48, 0.30, 0.18, 0.08],
		"sharpen": 0.40, "vignette": 0.38, "chromatic": 0.08, "grain": 0.018,
		"grade_gain": 1.00, "grade_gamma": 1.02, "grade_lift": 0.004,
		"grade_sat": 1.12, "grade_contrast": 1.07,
		"fx_quality": 3, "occlusion_quality": 3, "occlusion_enabled": true,
		"scaling": 1.0, "scaling_mode": Viewport.SCALING_3D_MODE_BILINEAR,
		"compatibility": false, "target_fps": 180,
	},
	# ---------------------------------------------------------- COMPETITIVE
	# 关 GI 与体积雾保轮廓稳定与高帧率, 但**保留 TAA 与程序化材质** ——
	# 旧的竞技档连材质细节都退化成纯色, 那是"更丑"而不是"更清晰"。
	{
		"msaa": 1, "ssaa": 1, "taa": true, "deband": true,
		"shadow_filter": 2, "shadow_size": 4096, "shadow_atlas": 4096,
		"aniso": 2, "lod": 0.8,
		"ssil": 0.0, "fog_scale": 0.0, "volumetric_fog": false,
		"sdfgi": false, "sdfgi_cascades": 2, "sdfgi_occlusion": false,
		"sdfgi_y_scale": Environment.SDFGI_Y_SCALE_75_PERCENT, "sdfgi_energy": 1.0,
		"reflection_probe": false, "probe_energy": 0.0,
		"material_level": MaterialForge.LEVEL_BASIC,
		"glow_levels": [1.0, 0.18, 0.0, 0.0, 0.0, 0.0, 0.0],
		"sharpen": 0.50, "vignette": 0.12, "chromatic": 0.0, "grain": 0.0,
		# 竞技档: 提饱和与对比是为了拉开阵营色与背景的差, 不是审美偏好
		"grade_gain": 1.00, "grade_gamma": 1.00, "grade_lift": 0.0,
		"grade_sat": 1.12, "grade_contrast": 1.06,
		"fx_quality": 2, "occlusion_quality": 2, "occlusion_enabled": true,
		"scaling": 1.0, "scaling_mode": Viewport.SCALING_3D_MODE_BILINEAR,
		"compatibility": false, "target_fps": 180,
	},
]


static func _vp_set(vp: Viewport, prop: String, value: Variant) -> void:
	if vp == null:
		return
	if prop in vp:
		vp.set(prop, value)


static func _set_project(key: String, value: Variant) -> void:
	if ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, value)
