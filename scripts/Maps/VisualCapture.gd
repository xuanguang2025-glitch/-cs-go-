extends Node
##
## VisualCapture.gd — 画面 A/B 取证 + 性能采样（QA 专用，纯命令行驱动）
##
## 为什么存在:
##   1. 验收要求「前后对比截图必须同机位」。所有机位写死在 VANTAGES 里,
##      同一台机器、同一分辨率、同一画质档位 -> 前后两张图严格可比。
##   2. 验收要求「帧率不得低于历史基线」。这里在同一进程里同时采样
##      平均/最低 FPS、draw call、可见对象数、静态内存, 口径统一。
##
## 用法（必须窗口模式; --headless 用 dummy 驱动, 不出图也没有真实光照）:
##   "D:/.../.tools/GodotSteam_Editor.exe" --path . \
##       res://scenes/Dev/VisualCapture.tscn -- \
##       --map project_zero --tier 2 --tag before \
##       --outdir "D:/.../PROJECT_STRIKE/outputs" \
##       --warmup 4 --sample 8 --actors 0
##
## 参数:
##   --map     project_zero | night_harbor | red_district | training_range
##   --tier    0..5 (对应 GraphicsQuality.Tier), 只改内存不落盘
##   --tag     输出文件名前缀, 例如 before / after
##   --outdir  绝对路径输出目录
##   --warmup  采样前预热秒数（让 SDFGI/TAA/着色器编译收敛）
##   --sample  采样秒数
##   --shots   机位数量, 默认全部; 1 = 只拍 hero
##   --actors  1 = 保留可见角色（游戏化截图）, 0 = 隐藏（隔离画面本身）
##   --hud     1 = 保留 HUD, 0 = 隐藏（默认 0）
##   --fov     覆盖 hero 机位 FOV
##   --suffix  额外文件名后缀（如 _tier1）, 便于同 tag 多档位出图
##   --nosec   跳过预热+采样（只出图, 用于快速试拍）
##
## 为什么不用 --script 跑: MainLoop 脚本编译早于 autoload 注册,
##   GraphicsQuality/EnvForge 依赖 GameManager 全局标识符会编译失败。
##   因此本工具走标准场景（scenes/Dev/VisualCapture.tscn）。
##
## 关键实现说明:
##   * 截图必须等 RenderingServer.frame_post_draw, 否则拿到的是半帧/空帧。
##   * Engine.max_fps 若被画质档位压低, 这里如实报告 —— 不做任何美化。
##

const VANTAGES: Array = [
	# hero: 中路走廊平视 —— 最接近真实对局观感（地面/掩体/雾/GI/反射全在画面里）
	{"name": "hero", "pos": Vector3(0.0, 2.1, 26.0), "look": Vector3(0.0, 1.9, -20.0), "fov": 90.0},
	# over: 高空 3/4 俯视 —— 看整体 GI、阴影方向、材质铺装密度
	{"name": "over", "pos": Vector3(31.0, 16.0, 30.0), "look": Vector3(0.0, 0.0, -8.0), "fov": 68.0},
	# site: A 点进攻视角 —— 掩体近景, 看接触阴影与高光
	{"name": "site", "pos": Vector3(-6.0, 2.2, -6.0), "look": Vector3(-20.0, 1.0, -21.0), "fov": 90.0},
]

var _map: String = "project_zero"
var _tier: int = 2
var _tag: String = "shot"
var _suffix: String = ""
var _outdir: String = "."
var _warmup: float = 4.0
var _sample: float = 8.0
var _shots: int = -1
var _want_actors: bool = false
var _want_hud: bool = false
var _fov_override: float = -1.0
var _skip_stats: bool = false
var _vsync: int = -1
var _fps_cap: int = -1
var _perf_vantage: String = "over"
var _ablate: bool = false
var _abl_warm: float = 1.2
var _abl_sample: float = 3.0
## 只关掉这一项, 然后正常采样 —— 每项跑一次独立进程。
## 为什么不用同进程循环: 连续 40 秒 100% GPU 负载后笔记本 GPU 会降频,
## 后测的项目会被前面"烤"出来的热衰减污染(实测同进程循环里 baseline 从
## 39ms 漂到 61ms)。冷进程逐项测量才是可信的。
var _only: String = ""

# 消融实验状态
var _abl_steps: Array = []
var _abl_index: int = -1
var _abl_phase: int = 0
var _abl_t: float = 0.0
var _abl_frames: int = 0
var _abl_results: Array = []

## 逐个关掉单项特性, 测出每一项的真实帧时间成本。
## 这是唯一能回答"这 22ms 到底花在哪"的办法 —— 靠猜会把画质做废。
const ABLATIONS: Array = [
	"baseline",
	"no_sdfgi",
	"no_ssao",
	"no_ssil",
	"no_volfog",
	"no_glow",
	"no_taa",
	"no_msaa",
	"no_shadow",
	"no_probe",
	"no_material",
	"no_occlusion",
]

var _game: Node = null
var _mm: Node = null
var _cam: Camera3D = null

var _state: int = 0            # 0=预热 1=采样 2=拍照 3=收尾
var _elapsed: float = 0.0
var _frames: int = 0

var _sample_frames: int = 0
var _sample_time: float = 0.0
var _fps_min: float = 99999.0
var _fps_max: float = 0.0
var _fps_sum: float = 0.0
var _fps_samples: int = 0
var _draw_calls: int = 0
var _objects: int = 0
var _prims: int = 0

var _shot_index: int = 0
var _shot_wait: int = 0
var _pending_path: String = ""
var _pending: bool = false
var _written: Array = []


func _ready() -> void:
	_parse_args()
	DirAccess.make_dir_recursive_absolute(_outdir)
	RenderingServer.frame_post_draw.connect(_on_post_draw)

	# 画质档位只写内存（set_setting 不落盘），不污染玩家真实 settings.cfg
	GameManager.set_setting("graphics_quality", _tier)
	GameManager.pending_match = {
		"map_id": _map,
		"bot_count": 9,
		"team": GameConfig.Team.STRIKE,
	}

	var packed := load("res://scenes/Game.tscn") as PackedScene
	if packed == null:
		printerr("[cap] 无法加载 res://scenes/Game.tscn")
		get_tree().quit(1)
		return
	_game = packed.instantiate()
	add_child(_game)
	_mm = _game.get_node_or_null("MatchManager")
	if _mm == null:
		printerr("[cap] MatchManager 未创建")
		get_tree().quit(1)
		return

	get_window().size = Vector2i(1920, 1080)
	_setup_camera()
	_apply_visibility()

	# 预热与采样必须发生在"指定性能机位"上, 否则测的是相机默认位置(世界原点,
	# 埋在地面里)那一帧的开销, 数字没有意义。默认取 over 机位 —— 俯视全图,
	# 可见对象最多, 是最坏情况, 适合当性能预算口径。
	var pi := _perf_vantage_index()
	if pi >= 0:
		_shot_index = pi
		_aim(VANTAGES[pi])
		_shot_index = 0
		print("[cap] perf vantage = %s" % str(VANTAGES[pi]["name"]))

	if _only != "":
		_apply_ablation(_only, false)
		print("[cap] ablation-only: %s" % _only)

	print("[cap] map=%s tier=%d(%s) actors=%s hud=%s res=%dx%d engine_max_fps=%d" % [
		_map, _tier, GraphicsQuality.tier_name(_tier),
		"on" if _want_actors else "off", "on" if _want_hud else "off",
		get_window().size.x, get_window().size.y, Engine.max_fps])


func _perf_vantage_index() -> int:
	for i in VANTAGES.size():
		if str(VANTAGES[i]["name"]) == _perf_vantage:
			return i
	return -1


func _parse_args() -> void:
	var a := OS.get_cmdline_user_args()
	var i := 0
	while i < a.size():
		var k: String = a[i]
		var v: String = a[i + 1] if i + 1 < a.size() else ""
		match k:
			"--map": _map = v
			"--tier": _tier = int(v)
			"--tag": _tag = v
			"--suffix": _suffix = v
			"--outdir": _outdir = v
			"--warmup": _warmup = float(v)
			"--sample": _sample = float(v)
			"--shots": _shots = int(v)
			"--actors": _want_actors = int(v) != 0
			"--hud": _want_hud = int(v) != 0
			"--fov": _fov_override = float(v)
			"--vsync": _vsync = int(v)
			"--fpscap": _fps_cap = int(v)
			"--pervv": _perf_vantage = v
			"--ablate": _ablate = int(v) != 0
			"--only": _only = v
			"--ablwarm": _abl_warm = float(v)
			"--ablsample": _abl_sample = float(v)
			"--nosec": _skip_stats = int(v) != 0
		i += 2
	if _skip_stats:
		_warmup = 1.5
		_sample = 0.0
	# 性能取证时把 vsync / 帧率上限完全交给命令行控制, 便于区分
	# 「被限幅」和「真的跑不动」这两种完全不同的情况。
	if _vsync >= 0:
		DisplayServer.window_set_vsync_mode(_vsync)
	if _fps_cap >= 0:
		Engine.max_fps = _fps_cap


func _setup_camera() -> void:
	# 自己的取证相机: 与玩家视角解耦, 保证机位绝对可复现
	_cam = Camera3D.new()
	_cam.name = "CaptureCam"
	_cam.near = 0.1
	_cam.far = 600.0
	_cam.fov = 90.0
	get_tree().root.add_child(_cam)
	_cam.current = true
	var lp: Node = _mm.get("local_player")
	if lp != null and is_instance_valid(lp) and lp.has_method("get_camera"):
		var c: Camera3D = lp.call("get_camera")
		if c != null:
			c.current = false


func _apply_visibility() -> void:
	# 隔离变量: 隐藏 HUD / 角色, 只留下地图本体 (材质/光照/后处理)
	# 只保留 PostFX 这一层 —— 后处理属于"画面"的一部分, 必须留在对比里。
	if not _want_hud:
		for n in get_tree().root.get_children():
			if n is CanvasLayer and String(n.name) != "PostFX":
				(n as CanvasLayer).visible = false
	if not _want_actors and _mm != null:
		for a in _mm.get("actors"):
			if a != null and is_instance_valid(a):
				a.visible = false


func _aim(v: Dictionary) -> void:
	var pos: Vector3 = v["pos"]
	var look: Vector3 = v["look"]
	var fov: float = float(v["fov"])
	if _fov_override > 0.0 and _shot_index == 0:
		fov = _fov_override
	_cam.fov = fov
	_cam.current = true
	_cam.look_at_from_position(pos, look, Vector3.UP)
	# look_at 在接近垂直时会引入 roll, 这里强制扶正
	var r: Vector3 = _cam.rotation
	r.z = 0.0
	_cam.rotation = r


func _process(delta: float) -> void:
	# GameRoot._ready() 里的 GraphicsQuality.apply() 会改写 Engine.max_fps,
	# 所以取证时每帧重新压住, 否则测到的永远是档位上限而不是真实性能。
	if _vsync >= 0 and DisplayServer.window_get_vsync_mode() != _vsync:
		DisplayServer.window_set_vsync_mode(_vsync)
	if _fps_cap >= 0 and Engine.max_fps != _fps_cap:
		Engine.max_fps = _fps_cap

	_elapsed += delta
	_frames += 1

	match _state:
		0:   # 预热: 让 SDFGI 收敛、着色器编译完成, 不采样
			if _elapsed >= _warmup:
				_state = 1
				_elapsed = 0.0
				print("[cap] warmup done, frames=%d" % _frames)
		1:   # 采样
			_sample_frames += 1
			_sample_time += delta
			var f := float(Engine.get_frames_per_second())
			_fps_sum += f
			_fps_samples += 1
			_fps_min = minf(_fps_min, f)
			_fps_max = maxf(_fps_max, f)
			_draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			_objects = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
			_prims = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
			if _elapsed >= _sample:
				_report_stats()
				_abl_index = -1
				_state = 4 if _ablate else 2
				_elapsed = 0.0
				_shot_wait = 6
		2:   # 拍照: 每机位等 6 帧稳定后抓帧
			if _shot_index >= _vantage_count():
				_state = 3
				return
			_aim(VANTAGES[_shot_index])
			_shot_wait -= 1
			if _shot_wait <= 0 and not _pending:
				_request_shot(_shot_name(_shot_index))
				_shot_wait = 6
			# 抓帧回调(_on_post_draw)里推进 index
		3:
			_finish()
		4:
			_tick_ablation(delta)


func _vantage_count() -> int:
	if _shots <= 0:
		return VANTAGES.size()
	return mini(_shots, VANTAGES.size())


func _shot_name(i: int) -> String:
	return "%s/%s_%s%s.png" % [_outdir, _tag, str(VANTAGES[i]["name"]), _suffix]


func _request_shot(path: String) -> void:
	_pending_path = path
	_pending = true


func _on_post_draw() -> void:
	if not _pending:
		return
	_pending = false
	var tex := get_viewport().get_texture()
	if tex == null:
		printerr("[cap] viewport texture 为空, 抓帧失败")
		_advance()
		return
	var img := tex.get_image()
	if img == null:
		printerr("[cap] get_image() 为空: %s" % _pending_path)
		_advance()
		return
	var err := img.save_png(_pending_path)
	if err != OK:
		printerr("[cap] save_png 失败(%d): %s" % [err, _pending_path])
	else:
		_written.append(_pending_path)
		print("[cap] wrote %s (%dx%d)" % [_pending_path, img.get_width(), img.get_height()])
	_advance()


func _advance() -> void:
	_shot_index += 1
	_shot_wait = 6


func _report_stats() -> void:
	var fps_avg := float(_sample_frames) / maxf(_sample_time, 0.0001)
	print("========================================================")
	print("[cap] STATS map=%s tier=%d(%s) tag=%s" % [
		_map, _tier, GraphicsQuality.tier_name(_tier), _tag + _suffix])
	print("  fps_avg(帧数/时长)  = %.1f" % fps_avg)
	print("  fps_avg(引擎上报)   = %.1f" % (_fps_sum / maxf(float(_fps_samples), 1.0)))
	print("  fps_min / fps_max   = %.0f / %.0f" % [_fps_min, _fps_max])
	print("  frame_ms_avg        = %.2f" % (_sample_time / maxf(float(_sample_frames), 1.0) * 1000.0))
	print("  draw_calls          = %d" % _draw_calls)
	print("  visible_objects     = %d" % _objects)
	print("  primitives          = %d" % _prims)
	print("  static_mem_MB       = %.1f" % (float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0))
	print("  node_count          = %d" % int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
	print("  engine_max_fps      = %d   (0 = 不限, 由 vsync 决定)" % Engine.max_fps)
	print("  vsync_mode          = %d   (0=off 1=on 2=mailbox 3=adaptive)" % DisplayServer.window_get_vsync_mode())
	print("  screen_refresh_Hz   = %.1f" % DisplayServer.screen_get_refresh_rate())
	var vp := get_viewport()
	print("  msaa_3d=%d  ssaa=%d  taa=%s  deband=%s  scaling=%.2f mode=%d" % [
		vp.msaa_3d, vp.screen_space_aa, str(vp.use_taa),
		str(vp.use_debanding), vp.scaling_3d_scale, vp.scaling_3d_mode])
	var env: Environment = null
	for n in get_tree().get_nodes_in_group(EnvForge.ENV_GROUP):
		if n is WorldEnvironment:
			env = (n as WorldEnvironment).environment
			break
	if env != null:
		print("  env: tonemap=%d exposure=%.2f sdfgi=%s ssao=%s ssil=%s ssr=%s volfog=%s glow=%s" % [
			env.tonemap_mode, env.tonemap_exposure, str(env.sdfgi_enabled),
			str(env.ssao_enabled), str(env.ssil_enabled), str(env.ssr_enabled),
			str(env.volumetric_fog_enabled), str(env.glow_enabled)])
		print("  env: ssao_half=%s ssil_half=%s dir_shadow_size=%d pos_atlas=%d taa=%s" % [
			str(ProjectSettings.get_setting("rendering/environment/ssao/half_size")),
			str(ProjectSettings.get_setting("rendering/environment/ssil/half_size")),
			int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size")),
			int(ProjectSettings.get_setting("rendering/lights_and_shadows/positional_shadow/atlas_size")),
			str(ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_taa"))])
	print("========================================================")


func _finish() -> void:
	print("[cap] SHOTS %d:" % _written.size())
	for w in _written:
		print("  " + str(w))
	get_tree().quit(0)


# ================================================================ 消融实验
func _tick_ablation(delta: float) -> void:
	_abl_t += delta
	match _abl_phase:
		0:   # 准备下一步
			_abl_index += 1
			if _abl_index >= ABLATIONS.size():
				_report_ablation()
				_shot_index = 0
				_shot_wait = 6
				_state = 2
				return
			_apply_ablation(str(ABLATIONS[_abl_index]), false)
			_abl_t = 0.0
			_abl_frames = 0
			_abl_phase = 1
		1:   # 预热, 丢弃
			if _abl_t >= _abl_warm:
				_abl_t = 0.0
				_abl_frames = 0
				_abl_phase = 2
		2:   # 计时
			_abl_frames += 1
			if _abl_t >= _abl_sample:
				var ms := _abl_t / maxf(float(_abl_frames), 1.0) * 1000.0
				_abl_results.append({"name": str(ABLATIONS[_abl_index]), "ms": ms,
					"fps": float(_abl_frames) / maxf(_abl_t, 0.0001)})
				_apply_ablation(str(ABLATIONS[_abl_index]), true)
				_abl_phase = 0
				_abl_t = 0.0


func _apply_ablation(key: String, restore: bool) -> void:
	var vp := get_viewport()
	var env: Environment = _find_env()
	match key:
		"baseline":
			return
		"no_sdfgi":
			if env != null:
				env.sdfgi_enabled = restore
		"no_ssao":
			if env != null:
				env.ssao_enabled = restore
		"no_ssil":
			if env != null:
				env.ssil_enabled = restore
		"no_volfog":
			if env != null:
				env.volumetric_fog_enabled = restore
		"no_glow":
			if env != null:
				env.glow_enabled = restore
		"no_taa":
			vp.use_taa = restore
		"no_msaa":
			vp.msaa_3d = Viewport.MSAA_4X if restore else Viewport.MSAA_DISABLED
		"no_shadow":
			for l in _find_lights():
				l.shadow_enabled = restore
		"no_probe":
			for n in get_tree().get_nodes_in_group(EnvForge.PROBE_GROUP):
				if n is ReflectionProbe:
					(n as ReflectionProbe).intensity = 1.0 if restore else 0.0
		"no_material":
			MaterialForge.set_level(MaterialForge.LEVEL_FULL if restore
					else MaterialForge.LEVEL_OFF)
		"no_occlusion":
			vp.use_occlusion_culling = restore


func _find_env() -> Environment:
	for n in get_tree().get_nodes_in_group(EnvForge.ENV_GROUP):
		if n is WorldEnvironment:
			return (n as WorldEnvironment).environment
	return null


func _find_lights() -> Array:
	var out: Array = []
	var stack: Array = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Light3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _report_ablation() -> void:
	var base := 0.0
	for r in _abl_results:
		if str(r["name"]) == "baseline":
			base = float(r["ms"])
	print("########################################################")
	print("[cap] ABLATION map=%s tier=%d(%s) vantage=%s  (逐项关闭)" % [
		_map, _tier, GraphicsQuality.tier_name(_tier), _perf_vantage])
	for r in _abl_results:
		var ms: float = float(r["ms"])
		print("  %-14s %7.2f ms  %6.1f fps   Δcost=%+6.2f ms" % [
			str(r["name"]), ms, float(r["fps"]),
			(base - ms) if str(r["name"]) != "baseline" else 0.0])
	print("  (Δcost = 关掉这一项后省下的毫秒数; baseline 是全开)")
	print("########################################################")
