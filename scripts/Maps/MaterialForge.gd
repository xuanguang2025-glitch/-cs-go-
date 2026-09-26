extends RefCounted
class_name MaterialForge
##
## MaterialForge.gd — 运行时 PBR 材质升级器（程序化贴图, 零外部素材）
##
## 为什么需要它
## ------------
## MapBuilder 生成的所有几何体用的是「纯色 StandardMaterial3D」: 只有
## albedo_color + roughness/metallic 两个标量, 没有任何贴图。结果是:
##   * 26m x 5.5m 的整面墙就是一个纯色色块, 看不到任何表面细节与尺度参照;
##   * BoxMesh 每个面的 UV 都是 0..1, 于是 uv1_scale 这种参数**完全无效**
##     （没有贴图可缩放）—— 是"设了但没用"的死参数;
##   * 光照只有 Lambert 逐像素渐变, 没有任何法线扰动 → 一眼"程序化盒子"。
## 后处理堆得再高也救不了纯色盒子 —— 这才是画面问题的根因。
##
## 本模块在**不改动 MapBuilder 一个字符**的前提下, 在地图节点入树后
## 原地把材质升级为带贴图的 PBR:
##   1. 程序化生成 albedo / roughness / normal 三张噪声贴图（FastNoiseLite
##      + NoiseTexture2D, 无外部文件、无授权风险、无下载）;
##   2. 打开 **世界空间三平面映射**(uv1_world_triplanar) —— 这一步同时修掉
##      「BoxMesh UV 拉伸」和「uv1_scale 无效」两个结构性问题, 让 1 米地面
##      和 26 米墙面拥有一致的 texel 密度;
##   3. 按材质特征自动分族(混凝土/金属/木材/沥青), 每族一套参数;
##   4. 同签名材质**共享同一份材质实例** —— 材质数从 ~90 降到 ~12,
##      在提升画质的同时减少渲染状态切换(draw call 也更少)。
##
## 安全边界（为什么不会碰坏玩法）
## ------------------------------
##   * 只改 MeshInstance3D.material_override, 不碰 StaticBody3D、不碰
##     collision、不碰 get_meta("surface")/("impact_color") → HitSystem /
##     FXManager 的材质穿透与命中火花逻辑完全不受影响;
##   * 自发光材质(霓虹/危险标识/炸弹点标记/装置)一律跳过 —— 这些是
##     玩法信息载体, 不做"脏化"处理, 保证竞技可读性;
##   * 透明材质(玻璃)与无光照(unshaded)材质一律跳过;
##   * 只在传入的地图根节点子树内工作。
##
## 档位联动
## --------
##   LOW     : 完全关闭(省显存与带宽)
##   MEDIUM  : albedo + roughness + 三平面(不加法线, 省一次采样)
##   HIGH+   : albedo + roughness + 法线 + 三平面(完整效果)
##   COMPETITIVE: 同 MEDIUM 再降法线, 保轮廓与高帧率
##

const LEVEL_OFF := 0
const LEVEL_BASIC := 1     # albedo + roughness
const LEVEL_FULL := 2      # + normal

const MAP_GROUP := "ps_material_forged"

## 分族参数。tile_m = 贴图一次铺装覆盖的世界尺寸(米) → uv1_scale = 1/tile_m
const FAMILIES := {
	"concrete": {
		"seed": 1101,
		"tile_m": 3.2, "freq": 0.030, "octaves": 4, "lacunarity": 2.15, "gain": 0.52,
		"ramp_lo": 0.88, "albedo_boost": 1.00,
		"rough_lo": 0.90, "rough_hi": 1.0,
		"normal_bump": 1.8, "normal_scale": 0.18,
	},
	"metal": {
		"seed": 2202,
		"tile_m": 2.4, "freq": 0.055, "octaves": 4, "lacunarity": 2.4, "gain": 0.45,
		"ramp_lo": 0.90, "albedo_boost": 1.00,
		"rough_lo": 0.34, "rough_hi": 0.62,
		"normal_bump": 1.5, "normal_scale": 0.14,
	},
	"wood": {
		"seed": 3303,
		"tile_m": 1.5, "freq": 0.045, "octaves": 4, "lacunarity": 3.1, "gain": 0.58,
		"ramp_lo": 0.86, "albedo_boost": 1.00,
		"rough_lo": 0.74, "rough_hi": 0.94,
		"normal_bump": 1.8, "normal_scale": 0.18,
	},
	"asphalt": {
		"seed": 4404,
		"tile_m": 4.5, "freq": 0.045, "octaves": 5, "lacunarity": 2.0, "gain": 0.5,
		"ramp_lo": 0.90, "albedo_boost": 1.00,
		"rough_lo": 0.88, "rough_hi": 1.0,
		"normal_bump": 1.6, "normal_scale": 0.16,
	},
}

static var _roots: Array = []            # 已安装的地图根(WeakRef-like, 直接存引用)
static var _cache: Dictionary = {}       # "level|family|albedo|rough|metal" -> StandardMaterial3D
static var _tex_cache: Dictionary = {}   # "level|family|slot" -> Texture2D
static var _level: int = LEVEL_FULL
static var _installed_roots: Dictionary = {}


# ================================================================ 对外接口
## 安装: 在地图根节点入树后自动执行一次材质升级。
## EnvForge 在地图构建最开始就拿到 root, 那时几何体还没生成,
## 因此这里挂 tree_entered 一次性回调 —— 入树时 MapBuilder 已经全部建完了。
static func install(map_root: Node3D) -> void:
	if map_root == null or not is_instance_valid(map_root):
		return
	# 用 instance_id 去重, 但必须清理已失效的节点 —— Godot 会回收 instance_id,
	# 不清的话新地图可能撞上旧 id 而被误判成"已安装"。
	var stale: Array = []
	for id in _installed_roots:
		var n = _installed_roots[id]
		if n == null or not is_instance_valid(n):
			stale.append(id)
	for id in stale:
		_installed_roots.erase(id)
	var id2: int = map_root.get_instance_id()
	if _installed_roots.has(id2):
		return
	_installed_roots[id2] = map_root
	if map_root.is_inside_tree():
		_upgrade_deferred(map_root)
	else:
		map_root.tree_entered.connect(_on_tree_entered.bind(map_root), CONNECT_ONE_SHOT)


static func _on_tree_entered(map_root: Node3D) -> void:
	if map_root != null and is_instance_valid(map_root):
		_upgrade_deferred(map_root)


## 入树当帧几何体可能还在做资源就绪, 延后两帧再扫, 避免漏掉 MeshInstance3D。
static func _upgrade_deferred(map_root: Node3D) -> void:
	await _wait_frames(map_root, 2)
	if map_root == null or not is_instance_valid(map_root):
		return
	upgrade(map_root)


static func _wait_frames(node: Node, n: int) -> void:
	for _i in n:
		if node == null or not is_instance_valid(node) or not node.is_inside_tree():
			return
		await node.get_tree().process_frame


## 走一遍子树, 把所有"可升级"材质换成分族 PBR 材质。返回处理的网格数。
static func upgrade(map_root: Node3D) -> int:
	if map_root == null or not is_instance_valid(map_root):
		return 0
	if _level == LEVEL_OFF:
		return 0
	if not _roots.has(map_root):
		_roots.append(map_root)
	var n := 0
	for mi in _collect_meshes(map_root):
		if _upgrade_one(mi):
			n += 1
	print("[MaterialForge] 材质升级 %d 个网格 / %d 份共享材质 (level=%d)" % [
		n, _cache.size(), _level])
	return n


## 画质档位变化时重新扫一遍所有地图(幂等: 原始材质存在 meta 里, 可反复重算)
static func retune_all() -> void:
	_prune_roots()
	for r in _roots:
		upgrade(r)


static func _prune_roots() -> void:
	var keep: Array = []
	for r in _roots:
		if r != null and is_instance_valid(r):
			keep.append(r)
	_roots = keep


## 由 GraphicsQuality 调用, 设定细节等级; 等级变化时清空缓存并整体重算。
static func set_level(level: int) -> void:
	if level == _level and not _cache.is_empty():
		return
	_level = level
	_cache.clear()
	_tex_cache.clear()
	retune_all()


static func stats() -> Dictionary:
	return {"level": _level, "materials": _cache.size(), "textures": _tex_cache.size()}


# ================================================================ 内部
static func _collect_meshes(map_root: Node3D) -> Array:
	var out: Array = []
	var stack: Array = [map_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			out.append(node)
		for c in node.get_children():
			stack.append(c)
	return out


static func _upgrade_one(mi: MeshInstance3D) -> bool:
	if mi.mesh == null:
		return false
	# 原始材质只记录一次; 之后无论切多少次档位, 都从原始值重新推导,
	# 避免"升级过的材质再升级"导致参数漂移。
	var orig: StandardMaterial3D = null
	if mi.has_meta("ps_orig_mat"):
		orig = mi.get_meta("ps_orig_mat") as StandardMaterial3D
	else:
		var cur := mi.material_override
		if cur == null or not (cur is StandardMaterial3D):
			return false
		orig = cur as StandardMaterial3D
		if not _is_upgradable(orig):
			return false
		mi.set_meta("ps_orig_mat", orig)

	var fam := _classify(orig, mi)
	if fam == "":
		return false
	var key := _signature(fam, orig)
	var mat: StandardMaterial3D = _cache.get(key)
	if mat == null:
		mat = _build_material(fam, orig)
		_cache[key] = mat
	mi.material_override = mat
	return true


## 只升级"实心、受光、不透明、非玩法标识"的材质。
static func _is_upgradable(m: StandardMaterial3D) -> bool:
	if m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
		return false
	if m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return false
	# 自发光 = 霓虹/危险标识/炸弹点标记/装置 → 玩法信息载体, 不做脏化
	if m.emission_enabled:
		return false
	if m.refraction_enabled:
		return false
	if m.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED:
		return false
	return true


## 按 PBR 特征分族。不依赖 MapBuilder 的常量表, 纯靠材质本身判断,
## 这样 MapBuilder 以后改配色也不会把这里弄坏。
static func _classify(m: StandardMaterial3D, mi: MeshInstance3D) -> String:
	var c := m.albedo_color
	# 地面: 大面积水平面, 给更大的铺装尺度, 避免出现"地毯式"重复
	if mi.name == "Ground" or (mi.mesh is PlaneMesh and mi.get_parent() != null
			and String(mi.get_parent().name) == "Ground"):
		return "asphalt"
	if m.metallic >= 0.55:
		return "metal"
	# 暖色偏黄 + 低金属 → 木料(crate / wood, 以及黄褐色的木箱)
	if c.r > c.b + 0.06 and c.r >= c.g and m.metallic < 0.25:
		return "wood"
	if m.metallic < 0.25:
		return "concrete"
	return ""


static func _signature(fam: String, m: StandardMaterial3D) -> String:
	var c := m.albedo_color
	return "%d|%s|%.3f|%.3f|%.3f|%.3f|%.2f|%.2f" % [
		_level, fam, c.r, c.g, c.b, m.roughness, m.metallic, m.clearcoat]


static func _build_material(fam: String, src: StandardMaterial3D) -> StandardMaterial3D:
	var f: Dictionary = FAMILIES[fam]
	var m := StandardMaterial3D.new()

	# 基础色保留原色调, 只做轻微提亮 —— 噪声贴图整体是 <1 的乘数,
	# 不提亮的话整张图会明显变暗, 破坏已有的曝光平衡。
	var c := src.albedo_color
	var boost: float = float(f["albedo_boost"])
	m.albedo_color = Color(minf(c.r * boost, 1.0), minf(c.g * boost, 1.0),
			minf(c.b * boost, 1.0), c.a)
	m.albedo_texture = _texture(fam, "albedo")

	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.specular_mode = src.specular_mode
	m.roughness = clampf(src.roughness, 0.0, 1.0)
	m.roughness_texture = _texture(fam, "rough")
	m.metallic = src.metallic

	if _level >= LEVEL_FULL:
		m.normal_enabled = true
		m.normal_texture = _texture(fam, "normal")
		m.normal_scale = float(f["normal_scale"])

	# 世界空间三平面: 修掉 BoxMesh UV 拉伸 + 让 uv1_scale 真正生效
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	var inv: float = 1.0 / float(f["tile_m"])
	m.uv1_scale = Vector3(inv, inv, inv)
	m.uv1_triplanar_sharpness = 2.0

	# 注意: 这里**故意不用** TEXTURE_FILTER_*_ANISOTROPIC。三平面本身就是 3 次
	# 采样, 再乘上 16x 各向异性, 掠射角的大面积墙面/地面会把纹理采样开销
	# 放大一个数量级(实测这一项就是帧时间从 3ms 冲到 25ms 的主因)。
	# 三平面 + mipmap 在掠射角本来就不依赖各向异性来抗闪烁。
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# texture_repeat 默认即 ENABLED(=1); 本引擎未导出该枚举常量, 故不改动。

	# 保留原材质的金属清漆(集装箱的涂层感), 以及自发光之外的其它语义
	m.clearcoat_enabled = src.clearcoat_enabled
	m.clearcoat = src.clearcoat
	m.clearcoat_roughness = src.clearcoat_roughness
	m.ao_light_affect = 0.0
	return m


static func _texture(fam: String, slot: String) -> Texture2D:
	var key := "%d|%s|%s" % [_level, fam, slot]
	var t: Texture2D = _tex_cache.get(key)
	if t != null:
		return t
	var f: Dictionary = FAMILIES[fam]

	# 同一族的 albedo / roughness / normal 共用一份噪声, 只换映射方式 ——
	# 法线由粗糙度场推导出来天然自洽(凹凸和明暗是同一块表面)。
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = int(f["seed"])
	n.frequency = float(f["freq"])
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = int(f["octaves"])
	n.fractal_lacunarity = float(f["lacunarity"])
	n.fractal_gain = float(f["gain"])

	var nt := NoiseTexture2D.new()
	nt.noise = n
	nt.width = 128
	nt.height = 128
	nt.seamless = true
	nt.generate_mipmaps = true
	nt.normalize = true

	match slot:
		"albedo":
			# 灰度乘数贴图: 0 -> ramp_lo(最暗处压到多少), 1 -> 纯白(不变)
			var g := Gradient.new()
			g.set_color(0, Color(float(f["ramp_lo"]), float(f["ramp_lo"]), float(f["ramp_lo"]), 1.0))
			g.set_color(1, Color(1.0, 1.0, 1.0, 1.0))
			nt.color_ramp = g
		"rough":
			var g2 := Gradient.new()
			g2.set_color(0, Color(float(f["rough_lo"]), float(f["rough_lo"]), float(f["rough_lo"]), 1.0))
			g2.set_color(1, Color(float(f["rough_hi"]), float(f["rough_hi"]), float(f["rough_hi"]), 1.0))
			nt.color_ramp = g2
		"normal":
			nt.as_normal_map = true
			nt.bump_strength = float(f["normal_bump"])
	_tex_cache[key] = nt
	return nt
