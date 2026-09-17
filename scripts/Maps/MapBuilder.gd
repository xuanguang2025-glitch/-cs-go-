extends RefCounted
class_name MapBuilder
##
## MapBuilder.gd — 程序化生成原创竞技地图 PROJECT ZERO(工业园区)
##
## 布局: 标准 3 Lane + Mid
##   * 进攻方(STRIKE)出生在南侧 Z=+28, 防守方(GUARD)出生在北侧 Z=-30
##   * A 点位于西南 (-20, -21), B 点位于东南 (20, -21)
##   * 左路 / 中路 / 右路 三条纵向通道, 中段各有一条横向连接通道
##   * 中路为长直狙击通道, 两侧高墙; 中央大厅布置可穿透木箱与金属集装箱
##
## 所有几何体由代码生成, 材质与穿透属性通过 metadata 挂载, 供 HitSystem 读取。
##

const MAT_COLORS := {
	"concrete": Color(0.46, 0.47, 0.50),
	"metal":    Color(0.34, 0.39, 0.45),
	"wood":     Color(0.47, 0.33, 0.19),
	"glass":    Color(0.55, 0.72, 0.82),
	"crate":    Color(0.52, 0.40, 0.23),
	"hazard":   Color(0.62, 0.52, 0.16),
	"neon_red":  Color(0.45, 0.08, 0.12),
	"neon_cyan": Color(0.08, 0.35, 0.42),
}

const SURFACE_OF := {
	"concrete": GameConfig.SurfaceMat.CONCRETE,
	"metal":    GameConfig.SurfaceMat.METAL,
	"wood":     GameConfig.SurfaceMat.WOOD,
	"glass":    GameConfig.SurfaceMat.GLASS,
	"crate":    GameConfig.SurfaceMat.WOOD,
	"hazard":   GameConfig.SurfaceMat.CONCRETE,
	"neon_red":  GameConfig.SurfaceMat.CONCRETE,
	"neon_cyan": GameConfig.SurfaceMat.CONCRETE,
}

## impact 火花颜色
const IMPACT_COLOR := {
	"concrete": "#c9c9cc",
	"metal":    "#ffd9a0",
	"wood":     "#d8b078",
	"glass":    "#cfeaff",
	"crate":    "#d8b078",
	"hazard":   "#ffd24a",
	"neon_red":  "#ff3355",
	"neon_cyan": "#33ddff",
}

# [x, z, size_x, size_z, height, material]
const WALLS := [
	# 外墙
	[0, -34.5, 72, 1.2, 9, "concrete"],
	[0, 34.5, 72, 1.2, 9, "concrete"],
	[-34.5, 0, 1.2, 72, 9, "concrete"],
	[34.5, 0, 1.2, 72, 9, "concrete"],

	# 中路两侧高墙(狙击通道)
	[-5.8, 11, 1.4, 26, 5.5, "concrete"],
	[5.8, 11, 1.4, 26, 5.5, "concrete"],

	# 左 / 右路外墙
	[-25.5, 11, 1.4, 26, 5.5, "concrete"],
	[25.5, 11, 1.4, 26, 5.5, "concrete"],

	# 左-中 分隔墙(中段留 4m 横向通道)
	[-11.6, 16.5, 1.4, 15, 5.5, "concrete"],
	[-11.6, 0.5, 1.4, 9, 5.5, "concrete"],
	# 右-中 分隔墙
	[11.6, 16.5, 1.4, 15, 5.5, "concrete"],
	[11.6, 0.5, 1.4, 9, 5.5, "concrete"],

	# A / B 点北侧隔断
	[-20, -27.6, 14, 1.4, 5.5, "concrete"],
	[20, -27.6, 14, 1.4, 5.5, "concrete"],

	# 中央高塔(中路视野控制点)
	[0, -20.5, 9, 1.4, 5.5, "metal"],
	[-4.6, -17.5, 1.4, 7, 5.5, "metal"],
	[4.6, -17.5, 1.4, 7, 5.5, "metal"],
]

# 掩体与可站立平台 [x, z, size_x, size_z, height, material]
const COVERS := [
	# 中央大厅: 可穿透木箱(提供穿射玩法)
	[-9, -9.5, 2.2, 2.2, 1.3, "crate"],
	[-7.4, -12.2, 2.0, 2.0, 1.3, "crate"],
	[9, -9.5, 2.2, 2.2, 1.3, "crate"],
	[7.4, -12.2, 2.0, 2.0, 1.3, "crate"],
	[0, -6.5, 3.0, 1.6, 1.4, "crate"],

	# 中央大厅: 金属集装箱(不可穿透, 提供硬掩体)
	[-15, -12, 6.0, 2.6, 2.7, "metal"],
	[15, -12, 6.0, 2.6, 2.7, "metal"],
	[-3.2, -13.5, 2.6, 2.6, 2.7, "metal"],
	[3.2, -13.5, 2.6, 2.6, 2.7, "metal"],

	# A 点掩体
	[-24.5, -20, 2.4, 5.0, 2.2, "metal"],
	[-20, -23.5, 5.0, 2.0, 1.2, "crate"],
	[-16.5, -19, 2.2, 2.2, 1.3, "crate"],
	[-20.5, -17.5, 3.0, 1.8, 1.5, "wood"],

	# B 点掩体
	[24.5, -20, 2.4, 5.0, 2.2, "metal"],
	[20, -23.5, 5.0, 2.0, 1.2, "crate"],
	[16.5, -19, 2.2, 2.2, 1.3, "crate"],
	[20.5, -17.5, 3.0, 1.8, 1.5, "wood"],

	# 左路掩体
	[-18, 16, 3.0, 1.8, 1.4, "crate"],
	[-22, 6, 1.8, 3.2, 1.3, "metal"],
	[-16.5, -2, 2.4, 2.4, 1.4, "crate"],

	# 右路掩体
	[18, 16, 3.0, 1.8, 1.4, "crate"],
	[22, 6, 1.8, 3.2, 1.3, "metal"],
	[16.5, -2, 2.4, 2.4, 1.4, "crate"],

	# 中路掩体(半高, 不阻断狙击线)
	[-2.6, 14, 1.6, 2.6, 1.1, "metal"],
	[2.6, 14, 1.6, 2.6, 1.1, "metal"],
	[0, 2.5, 2.4, 1.6, 1.2, "crate"],

	# 进攻出生区掩体
	[-6, 26, 3.0, 1.6, 1.3, "crate"],
	[6, 26, 3.0, 1.6, 1.3, "crate"],
	[0, 23, 2.0, 2.0, 1.4, "metal"],

	# 防守出生区掩体
	[-7, -30, 3.4, 1.8, 1.4, "crate"],
	[7, -30, 3.4, 1.8, 1.4, "crate"],
]

# 玻璃幕墙(可穿透且可看穿) [x, z, size_x, size_z, height]
const GLASS := [
	[-11.6, 6.5, 1.4, 4, 4.5],
	[11.6, 6.5, 1.4, 4, 4.5],
]

## 出生点
const SPAWN_STRIKE := [
	Vector3(-6, 0, 28), Vector3(-3, 0, 30), Vector3(0, 0, 28),
	Vector3(3, 0, 30), Vector3(6, 0, 28),
]
const SPAWN_GUARD := [
	Vector3(-6, 0, -30), Vector3(-3, 0, -32), Vector3(0, 0, -30),
	Vector3(3, 0, -32), Vector3(6, 0, -30),
]

## 导航路点(Bot 寻路用)
const WAYPOINTS := [
	# 进攻出生区
	Vector3(0, 0, 26), Vector3(-6, 0, 26), Vector3(6, 0, 26),
	# 左路(纵向链)
	Vector3(-18, 0, 21), Vector3(-18, 0, 13), Vector3(-18, 0, 5), Vector3(-18, 0, -3),
	# 中路(纵向链)
	Vector3(0, 0, 21), Vector3(0, 0, 13), Vector3(0, 0, 5), Vector3(0, 0, -3),
	# 右路(纵向链)
	Vector3(18, 0, 21), Vector3(18, 0, 13), Vector3(18, 0, 5), Vector3(18, 0, -3),
	# 左-中 横向通道(墙体缺口在 Z 5..9, 两侧各放一点保证连通)
	Vector3(-14, 0, 6.5), Vector3(-11.6, 0, 6.5), Vector3(-9, 0, 6.5),
	# 右-中 横向通道
	Vector3(9, 0, 6.5), Vector3(11.6, 0, 6.5), Vector3(14, 0, 6.5),
	# 中央大厅
	Vector3(-14, 0, -10), Vector3(-7, 0, -10), Vector3(0, 0, -10),
	Vector3(7, 0, -10), Vector3(14, 0, -10), Vector3(0, 0, -6),
	# 大厅 -> A / B 的连接点
	Vector3(-20, 0, -10), Vector3(20, 0, -10),
	# A 点区域
	Vector3(-20, 0, -21), Vector3(-24, 0, -21), Vector3(-16, 0, -21), Vector3(-20, 0, -16),
	# B 点区域
	Vector3(20, 0, -21), Vector3(24, 0, -21), Vector3(16, 0, -21), Vector3(20, 0, -16),
	# 防守出生区与 A/B 的连接
	Vector3(-12, 0, -29), Vector3(0, 0, -29), Vector3(12, 0, -29),
	Vector3(-12, 0, -20), Vector3(12, 0, -20),
]

const WP_LINK_DISTANCE := 20.0

var _materials: Dictionary = {}


# ================================================================ 构建入口
static func build(map_id: String = "project_zero") -> Dictionary:
	match map_id:
		"night_harbor":
			return _build_night_harbor()
		"red_district":
			return _build_red_district()
		"training_range":
			return _build_training_range()
		_:
			return _build_project_zero()


static func _build_project_zero() -> Dictionary:
	var root := Node3D.new()
	root.name = "Map_project_zero"

	_build_environment(root)
	_build_ground(root, Color(0.38, 0.39, 0.41))
	for w in WALLS:
		_add_block(root, w[0], w[1], w[2], w[3], w[4], w[5])
	for c in COVERS:
		_add_block(root, c[0], c[1], c[2], c[3], c[4], c[5])
	for g in GLASS:
		_add_block(root, g[0], g[1], g[2], g[3], g[4], "glass")

	var sites := _build_sites(root)
	_build_spawn_markers(root)
	_add_decals(root)
	_add_environment_detail(root, "industrial")

	return {
		"root": root,
		"sites": sites,
		"spawn_strike": SPAWN_STRIKE,
		"spawn_guard": SPAWN_GUARD,
		"waypoints": WAYPOINTS,
		"display_name": "PROJECT ZERO",
	}


# ---------------------------------------------------------------- 环境
static func _build_environment(root: Node3D) -> void:
	# 统一交给 EnvForge: 程序化天空 + SSIL + 体积雾 + ACES + 分级泛光
	EnvForge.build_day(root)

	# 补光, 避免阴面纯黑(竞技地图要求能看清敌人)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.62, 0.72, 0.88)
	fill.light_energy = 0.75
	fill.rotation_degrees = Vector3(-20, -140, 0)
	fill.shadow_enabled = false
	fill.light_cull_mask = ~(GameConfig.FX_VISUAL_LAYER)
	root.add_child(fill)


static func _build_ground(root: Node3D, base_color: Color = Color(0.38, 0.39, 0.41)) -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = GameConfig.LAYER_WORLD
	body.collision_mask = 0
	body.set_meta("surface", GameConfig.SurfaceMat.CONCRETE)
	body.set_meta("impact_color", IMPACT_COLOR["concrete"])

	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(72, 72)
	plane.orientation = PlaneMesh.FACE_Y
	mi.mesh = plane
	var mat := _make_material("concrete")
	mat.albedo_color = base_color
	mat.roughness = 0.94
	mat.metallic = 0.02
	mat.uv1_scale = Vector3(18, 18, 1)
	mi.material_override = mat
	body.add_child(mi)
	_add_ground_detail(root, base_color)

	var shape := CollisionShape3D.new()
	var world_shape := WorldBoundaryShape3D.new()
	world_shape.plane = Plane(Vector3.UP, 0.0)
	shape.shape = world_shape
	body.add_child(shape)
	root.add_child(body)


static func _add_ground_detail(root: Node3D, base_color: Color) -> void:
	# 程序化地面细节：排水缝、维修接缝和低对比导流线，增加尺度感但不改变碰撞。
	var detail_mat := StandardMaterial3D.new()
	detail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	detail_mat.albedo_color = base_color.darkened(0.24)
	detail_mat.roughness = 1.0
	for z in [-30.0, -18.0, -6.0, 6.0, 18.0, 30.0]:
		var seam := MeshInstance3D.new()
		var seam_mesh := BoxMesh.new()
		seam_mesh.size = Vector3(70.0, 0.008, 0.035)
		seam.mesh = seam_mesh
		seam.material_override = detail_mat
		seam.position = Vector3(0, 0.006, z)
		seam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(seam)
	for x in [-28.0, 28.0]:
		var drain := MeshInstance3D.new()
		var drain_mesh := BoxMesh.new()
		drain_mesh.size = Vector3(0.16, 0.012, 68.0)
		drain.mesh = drain_mesh
		drain.material_override = detail_mat
		drain.position = Vector3(x, 0.008, 0)
		drain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(drain)


static func _add_block(root: Node3D, x: float, z: float, sx: float, sz: float,
		height: float, mat_key: String) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = GameConfig.LAYER_WORLD
	body.collision_mask = 0
	body.set_meta("surface", SURFACE_OF.get(mat_key, GameConfig.SurfaceMat.CONCRETE))
	body.set_meta("impact_color", IMPACT_COLOR.get(mat_key, "#c9c9cc"))
	body.position = Vector3(x, height * 0.5, z)

	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(sx, height, sz)
	mi.mesh = box
	mi.material_override = _make_material(mat_key)
	body.add_child(mi)

	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(sx, height, sz)
	shape.shape = bs
	body.add_child(shape)
	_add_block_detail(body, sx, sz, height, mat_key)
	root.add_child(body)


static func _add_block_detail(parent: Node3D, sx: float, sz: float, height: float, key: String) -> void:
	if GraphicsQuality.current() < GraphicsQuality.Tier.HIGH:
		return
	var detail := StandardMaterial3D.new()
	detail.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	detail.roughness = 0.92
	detail.albedo_color = Color(0.045, 0.05, 0.055, 0.72)
	if key == "metal":
		# 金属板的接缝与加固筋，避免集装箱/掩体看起来像无厚度的纯色盒子。
		for x in [-sx * 0.38, sx * 0.38]:
			var rib := MeshInstance3D.new()
			var rib_mesh := BoxMesh.new()
			rib_mesh.size = Vector3(0.045, height * 0.82, 0.035)
			rib.mesh = rib_mesh
			rib.material_override = detail
			rib.position = Vector3(x, 0.0, -sz * 0.505)
			rib.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(rib)
	elif key == "crate" or key == "wood":
		# 木箱正面三道暗色木板缝，保持低对比以免破坏敌人轮廓。
		for y in [-height * 0.25, 0.0, height * 0.25]:
			var slat := MeshInstance3D.new()
			var slat_mesh := BoxMesh.new()
			slat_mesh.size = Vector3(sx * 0.82, 0.025, 0.018)
			slat.mesh = slat_mesh
			slat.material_override = detail
			slat.position = Vector3(0.0, y, -sz * 0.505)
			slat.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(slat)
	elif key == "glass":
		# 玻璃面板边框，增强厚度与反射边缘。
		for x in [-sx * 0.44, sx * 0.44]:
			var frame := MeshInstance3D.new()
			var frame_mesh := BoxMesh.new()
			frame_mesh.size = Vector3(0.055, height, 0.045)
			frame.mesh = frame_mesh
			frame.material_override = detail
			frame.position = Vector3(x, 0.0, -sz * 0.505)
			frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(frame)


static func _make_material(key: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var c: Color = MAT_COLORS.get(key, Color.GRAY)
	m.albedo_color = c
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	m.roughness = 0.82
	m.metallic = 0.12
	m.uv1_scale = Vector3(2.5, 2.5, 2.5)
	if key == "concrete":
		m.roughness = 0.94
		m.metallic = 0.02
		m.uv1_scale = Vector3(1.8, 1.8, 1.8)
	elif key == "metal":
		m.metallic = 0.86
		m.roughness = 0.42
		m.uv1_scale = Vector3(3.0, 3.0, 3.0)
		m.clearcoat_enabled = true
		m.clearcoat = 0.18
		m.clearcoat_roughness = 0.24
	elif key == "wood" or key == "crate":
		m.roughness = 0.88
		m.metallic = 0.0
		m.uv1_scale = Vector3(3.8, 3.8, 3.8)
	elif key == "glass":
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(c.r, c.g, c.b, 0.28)
		m.metallic = 0.18
		m.roughness = 0.06
		m.refraction_enabled = true
		m.refraction_scale = 0.035
	elif key == "hazard":
		m.roughness = 0.62
		m.metallic = 0.32
		m.emission_enabled = true
		m.emission = Color(0.9, 0.7, 0.1)
		m.emission_energy_multiplier = 0.28
	elif key == "neon_red":
		m.emission_enabled = true
		m.emission = Color(1.0, 0.12, 0.22)
		m.emission_energy_multiplier = 2.4
		m.albedo_color = Color(0.45, 0.08, 0.12)
		m.roughness = 0.32
	elif key == "neon_cyan":
		m.emission_enabled = true
		m.emission = Color(0.12, 0.85, 1.0)
		m.emission_energy_multiplier = 2.2
		m.albedo_color = Color(0.08, 0.35, 0.42)
		m.roughness = 0.32
	return m


static func _build_sites(root: Node3D) -> Array:
	var sites: Array = []
	var a_site := BombSite.new()
	a_site.site_name = "A"
	a_site.site_size = Vector2(13.0, 13.0)
	a_site.position = Vector3(-20, 0, -21)
	root.add_child(a_site)
	sites.append(a_site)

	var b_site := BombSite.new()
	b_site.site_name = "B"
	b_site.site_size = Vector2(13.0, 13.0)
	b_site.position = Vector3(20, 0, -21)
	root.add_child(b_site)
	sites.append(b_site)
	return sites


static func _build_spawn_markers(root: Node3D) -> void:
	# 出生区地面标记(纯视觉)
	for team in [GameConfig.Team.STRIKE, GameConfig.Team.GUARD]:
		var mi := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(16, 8)
		plane.orientation = PlaneMesh.FACE_Y
		mi.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(
			GameConfig.TEAM_COLOR[team].r,
			GameConfig.TEAM_COLOR[team].g,
			GameConfig.TEAM_COLOR[team].b, 0.18)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		mi.position = Vector3(0, 0.02, 29 if team == GameConfig.Team.STRIKE else -30)
		root.add_child(mi)


static func _add_decals(root: Node3D) -> void:
	# 危险区黄色条纹(工业风标识), 纯视觉
	for pos in [Vector3(-20, 0.03, -14.6), Vector3(20, 0.03, -14.6)]:
		var mi := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(13, 0.6)
		plane.orientation = PlaneMesh.FACE_Y
		mi.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.85, 0.68, 0.12)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		mi.position = pos
		root.add_child(mi)


static func _add_environment_detail(root: Node3D, style: String) -> void:
	# 轻量程序化环境叙事：管线、设备箱和检修支架，不参与碰撞与命中判定。
	# 低档跳过，竞技档保留轮廓级设备但不增加高频阴影。
	if GraphicsQuality.current() == GraphicsQuality.Tier.LOW:
		return
	var metal := _make_material("metal")
	metal.albedo_color = Color(0.18, 0.20, 0.23)
	var dark := StandardMaterial3D.new()
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dark.albedo_color = Color(0.035, 0.04, 0.045)

	var pipe_positions: Array = []
	match style:
		"harbor":
			pipe_positions = [Vector3(-31.0, 4.2, 21.0), Vector3(-31.0, 4.2, 3.0), Vector3(31.0, 4.2, -8.0)]
		"district":
			pipe_positions = [Vector3(-30.5, 3.8, 17.0), Vector3(30.5, 3.8, 4.0), Vector3(-30.5, 3.8, -13.0)]
		_:
			pipe_positions = [Vector3(-31.0, 4.6, 18.0), Vector3(31.0, 4.6, 5.0), Vector3(-31.0, 4.6, -14.0)]

	for pos in pipe_positions:
		var pipe := MeshInstance3D.new()
		var pipe_mesh := CylinderMesh.new()
		pipe_mesh.top_radius = 0.10
		pipe_mesh.bottom_radius = 0.10
		pipe_mesh.height = 7.0
		pipe_mesh.radial_segments = 10
		pipe.mesh = pipe_mesh
		pipe.material_override = metal
		pipe.position = pos
		pipe.rotation_degrees = Vector3(90, 0, 0)
		pipe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(pipe)

		for z_offset in [-2.8, 2.8]:
			var clamp := MeshInstance3D.new()
			var clamp_mesh := BoxMesh.new()
			clamp_mesh.size = Vector3(0.30, 0.16, 0.18)
			clamp.mesh = clamp_mesh
			clamp.material_override = dark
			clamp.position = pos + Vector3(0, 0, z_offset)
			clamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(clamp)

	for pos in [Vector3(-30.8, 1.4, 11.0), Vector3(30.8, 1.4, -3.0), Vector3(0, 1.3, 31.8)]:
		var box := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(0.85, 1.1, 0.26)
		box.mesh = box_mesh
		box.material_override = metal
		box.position = pos
		root.add_child(box)
		var indicator := MeshInstance3D.new()
		var indicator_mesh := BoxMesh.new()
		indicator_mesh.size = Vector3(0.24, 0.06, 0.018)
		indicator.mesh = indicator_mesh
		indicator.material_override = _make_material("neon_cyan" if style != "district" else "neon_red")
		indicator.position = pos + Vector3(0, 0.16, -0.14)
		indicator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(indicator)


# ================================================================ 导航图
## 在物理世界就绪后调用: 依据距离 + 视线可达性自动连边
static func build_nav_graph(waypoints: Array, world: World3D) -> Dictionary:
	var graph: Dictionary = {}
	for i in waypoints.size():
		graph[i] = []
	var space := world.direct_space_state
	for i in waypoints.size():
		for j in range(i + 1, waypoints.size()):
			var a: Vector3 = waypoints[i]
			var b: Vector3 = waypoints[j]
			var dist: float = a.distance_to(b)
			if dist > WP_LINK_DISTANCE:
				continue
			if not _walkable(space, a, b):
				continue
			graph[i].append(j)
			graph[j].append(i)
	return graph


static func _walkable(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	# 在膝盖和胸口两个高度检测, 避免低矮掩体被误判为通路
	for h in [0.6, 1.5]:
		var q := PhysicsRayQueryParameters3D.create(
			a + Vector3(0, h, 0), b + Vector3(0, h, 0))
		q.collision_mask = GameConfig.LAYER_WORLD
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			return false
	return true


# ================================================================ NIGHT HARBOR(夜间港口)
## 布局与 PROJECT ZERO 相同坐标系(可复用出生点/路点), 但掩体与视觉完全不同:
##   左路 = 集装箱堆场(高箱夹道, 可跳上矮箱)
##   中路 = 码头栈桥(直道长走廊, 两侧高护栏)
##   右路 = 仓库建筑(室内走廊 + 天窗)
## 环境: 低照度夜间 + 冷月光 + 沿途暖色吊灯 —— 保证"能看清敌人"的前提下做暗。

const WALLS_NH := [
	# 外墙
	[0, -34.5, 72, 1.2, 9, "concrete"],
	[0, 34.5, 72, 1.2, 9, "concrete"],
	[-34.5, 0, 1.2, 72, 9, "concrete"],
	[34.5, 0, 1.2, 72, 9, "concrete"],

	# 中路栈桥两侧高护栏(狙击通道)
	[-7.2, 11, 1.0, 26, 3.8, "metal"],
	[7.2, 11, 1.0, 26, 3.8, "metal"],

	# 左-中 / 右-中 分隔墙(中段留横向通道)
	[-14.4, 16.5, 1.2, 15, 4.2, "concrete"],
	[-14.4, 0.5, 1.2, 9, 4.2, "concrete"],
	[14.4, 16.5, 1.2, 15, 4.2, "concrete"],
	[14.4, 0.5, 1.2, 9, 4.2, "concrete"],

	# A / B 点北侧隔断
	[-20, -27.6, 14, 1.2, 4.2, "concrete"],
	[20, -27.6, 14, 1.2, 4.2, "concrete"],

	# 中央吊车塔架(中路视野控制)
	[0, -20.5, 8, 1.2, 5.2, "metal"],
	[-4.4, -17.5, 1.2, 7, 5.2, "metal"],
	[4.4, -17.5, 1.2, 7, 5.2, "metal"],

	# 右路仓库建筑外壳
	[20.5, -8, 2.6, 22, 5.0, "metal"],
	[20.5, 13, 2.6, 22, 5.0, "metal"],
	[31.5, 2.5, 2.6, 28, 5.0, "metal"],
]

# 集装箱(6.0 x 2.7 底, 高 2.7, 金属材质, 可跳上矮箱)
const CONTAINERS_NH := [
	# 左路集装箱堆场: 两列夹出弯曲通道
	[-24.5, 24, 6.2, 2.7, 2.7, "metal"],
	[-24.5, 17, 6.2, 2.7, 2.7, "metal"],
	[-24.5, 10, 6.2, 2.7, 2.7, "metal"],
	[-24.5, 3, 6.2, 2.7, 2.7, "metal"],
	[-24.5, -4, 6.2, 2.7, 2.7, "metal"],
	[-18.0, 20.5, 6.2, 2.7, 2.7, "metal"],
	[-18.0, 13.5, 6.2, 2.7, 2.7, "metal"],
	[-18.0, 6.5, 6.2, 2.7, 2.7, "metal"],
	[-18.0, -0.5, 6.2, 2.7, 2.7, "metal"],
	# 叠一层矮箱(1.35 高, 可跳上)
	[-21.2, 21.5, 6.2, 2.7, 1.35, "metal"],
	[-21.2, 7.5, 6.2, 2.7, 1.35, "metal"],

	# A 点集装箱掩体
	[-24.5, -20, 6.2, 2.7, 2.7, "metal"],
	[-20, -24, 6.2, 2.7, 1.35, "metal"],
	[-16, -19.5, 6.2, 2.7, 2.7, "metal"],

	# B 点集装箱掩体
	[24.5, -20, 6.2, 2.7, 2.7, "metal"],
	[20, -24, 6.2, 2.7, 1.35, "metal"],
	[16, -19.5, 6.2, 2.7, 2.7, "metal"],

	# 中央大厅掩体
	[-10, -10, 6.2, 2.7, 2.7, "metal"],
	[10, -10, 6.2, 2.7, 2.7, "metal"],
	[0, -7, 6.2, 2.7, 1.35, "metal"],
]

# 木箱(可穿透)
const CRATES_NH := [
	[-21, 16, 2.2, 2.2, 1.3, "crate"],
	[-19.4, 9, 2.0, 2.0, 1.3, "crate"],
	[-22, -1.5, 2.4, 2.4, 1.4, "crate"],
	[19, 16, 2.2, 2.2, 1.3, "crate"],
	[21, 9, 2.0, 2.0, 1.3, "crate"],
	[22, 2, 2.4, 2.4, 1.4, "crate"],
	[-6, 14, 1.6, 2.6, 1.1, "crate"],
	[6, 14, 1.6, 2.6, 1.1, "crate"],
	[-3, 2.5, 2.4, 1.6, 1.2, "crate"],
	[3, 2.5, 2.4, 1.6, 1.2, "crate"],
	[-6, 26, 3.0, 1.6, 1.3, "crate"],
	[6, 26, 3.0, 1.6, 1.3, "crate"],
	[-7, -30, 3.4, 1.8, 1.4, "crate"],
	[7, -30, 3.4, 1.8, 1.4, "crate"],
]

# 仓库天窗(玻璃, 可穿透可看穿)
const GLASS_NH := [
	[20.5, -3, 2.6, 5.5, 3.2],
	[20.5, 8, 2.6, 5.5, 3.2],
]


static func _build_night_harbor() -> Dictionary:
	var root := Node3D.new()
	root.name = "Map_night_harbor"

	_build_environment_night(root)
	_build_ground(root, Color(0.13, 0.15, 0.18))
	for w in WALLS_NH:
		_add_block(root, w[0], w[1], w[2], w[3], w[4], w[5])
	for c in CONTAINERS_NH:
		_add_block(root, c[0], c[1], c[2], c[3], c[4], c[5])
	for c in CRATES_NH:
		_add_block(root, c[0], c[1], c[2], c[3], c[4], c[5])
	for g in GLASS_NH:
		_add_block(root, g[0], g[1], g[2], g[3], g[4], "glass")

	_add_harbor_lights(root)

	var sites := _build_sites(root)
	_build_spawn_markers(root)
	_add_decals(root)
	_add_environment_detail(root, "harbor")

	return {
		"root": root,
		"sites": sites,
		"spawn_strike": SPAWN_STRIKE,
		"spawn_guard": SPAWN_GUARD,
		"waypoints": WAYPOINTS,
		"display_name": "NIGHT HARBOR",
	}


## 夜间环境: 深蓝黑天空 + 冷月光 + 低环境光, 但关键通道用暖色吊灯照明,
## 保证"暗得有氛围, 但不黑到看不见人"(竞技要求)。
static func _build_environment_night(root: Node3D) -> void:
	EnvForge.build_night(root)


## 码头吊灯: 沿主路径放置暖色点光源, 照亮交战区域
static func _add_harbor_lights(root: Node3D) -> void:
	var positions := [
		Vector3(0, 5.5, 22), Vector3(0, 5.5, 13), Vector3(0, 5.5, 4), Vector3(0, 5.5, -5),
		Vector3(-21, 5.0, 20), Vector3(-21, 5.0, 8), Vector3(21, 5.0, 20), Vector3(21, 5.0, 8),
		Vector3(-14, 5.0, -12), Vector3(14, 5.0, -12),
		Vector3(-20, 5.0, -21), Vector3(20, 5.0, -21),
	]
	for pos in positions:
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.82, 0.55)
		lamp.light_energy = 3.2
		lamp.omni_range = 14.0
		lamp.position = pos
		lamp.shadow_enabled = GraphicsQuality.current() >= GraphicsQuality.Tier.ULTRA and GraphicsQuality.current() != GraphicsQuality.Tier.COMPETITIVE
		lamp.light_cull_mask = ~(GameConfig.FX_VISUAL_LAYER)
		root.add_child(lamp)
		# 灯体(小金属盒, 让光源有"存在感")
		_add_block(root, pos.x, pos.z, 0.5, 0.5, 0.3, "hazard")


# ================================================================ RED DISTRICT(未来都市旧城区)
## 提示词要求的元素: 街道 / 商店 / 公寓 / 地铁入口 / 屋顶 / 霓虹。
##   * 商店排(2.5m 高)屋顶可跳上 —— 垂直交火层
##   * 公寓楼(6m)作为 lane 分隔, 底层玻璃橱窗可穿透
##   * 中路两侧是"地铁入口亭", 中央大厅连接 A/B
## 环境: 黄昏霓虹 —— 低角度橙色夕阳 + 红/青霓虹招牌。

const WALLS_RD := [
	[0, -34.5, 72, 1.2, 9, "concrete"],
	[0, 34.5, 72, 1.2, 9, "concrete"],
	[-34.5, 0, 1.2, 72, 9, "concrete"],
	[34.5, 0, 1.2, 72, 9, "concrete"],
	[-16, 16, 8, 12, 6, "concrete"],
	[16, 16, 8, 12, 6, "concrete"],
	[-16, -2, 8, 10, 6, "concrete"],
	[16, -2, 8, 10, 6, "concrete"],
	[-20, -27.6, 14, 1.2, 5, "concrete"],
	[20, -27.6, 14, 1.2, 5, "concrete"],
]

const COVERS_RD := [
	[-9.5, 14, 5, 5, 2.5, "concrete"],
	[-9.5, 3, 5, 5, 2.5, "concrete"],
	[9.5, 14, 5, 5, 2.5, "concrete"],
	[9.5, 3, 5, 5, 2.5, "concrete"],
	[-9, -17, 3.5, 3.5, 3.5, "concrete"],
	[9, -17, 3.5, 3.5, 3.5, "concrete"],
	[-4.5, 22, 3.5, 1.8, 1.5, "metal"],
	[4.5, 22, 3.5, 1.8, 1.5, "metal"],
	[-4.5, -4, 3.5, 1.8, 1.5, "metal"],
	[4.5, -4, 3.5, 1.8, 1.5, "metal"],
	[-12, -10, 2.2, 2.2, 1.3, "crate"],
	[12, -10, 2.2, 2.2, 1.3, "crate"],
	[0, -7, 3, 1.8, 1.4, "crate"],
	[-20, -13, 2.4, 2.4, 1.4, "crate"],
	[20, -13, 2.4, 2.4, 1.4, "crate"],
	[-24.5, -20, 2.4, 5, 2.2, "concrete"],
	[-20, -23.5, 5, 2, 1.2, "crate"],
	[-16.5, -19, 2.2, 2.2, 1.3, "crate"],
	[24.5, -20, 2.4, 5, 2.2, "concrete"],
	[20, -23.5, 5, 2, 1.2, "crate"],
	[16.5, -19, 2.2, 2.2, 1.3, "crate"],
	[-6, 26, 3, 1.6, 1.3, "crate"],
	[6, 26, 3, 1.6, 1.3, "crate"],
	[0, 23, 2, 2, 1.4, "metal"],
	[-7, -30, 3.4, 1.8, 1.4, "crate"],
	[7, -30, 3.4, 1.8, 1.4, "crate"],
]

const GLASS_RD := [
	[6.9, 14, 0.6, 4, 2.5],
	[-6.9, 14, 0.6, 4, 2.5],
	[6.9, 3, 0.6, 4, 2.5],
	[-6.9, 3, 0.6, 4, 2.5],
]

const NEONS_RD := [
	[7.6, 18, 0.4, 0.4, 4.5, "neon_red"],
	[-7.6, 18, 0.4, 0.4, 4.5, "neon_cyan"],
	[7.6, 7, 0.4, 0.4, 4.5, "neon_cyan"],
	[-7.6, 7, 0.4, 0.4, 4.5, "neon_red"],
	[0, -20.5, 0.6, 0.6, 6, "neon_red"],
	[-9, -19, 0.4, 0.4, 4.2, "neon_cyan"],
	[9, -19, 0.4, 0.4, 4.2, "neon_cyan"],
]


static func _build_red_district() -> Dictionary:
	var root := Node3D.new()
	root.name = "Map_red_district"

	_build_environment_dusk(root)
	_build_ground(root, Color(0.16, 0.15, 0.17))
	for w in WALLS_RD:
		_add_block(root, w[0], w[1], w[2], w[3], w[4], w[5])
	for c in COVERS_RD:
		_add_block(root, c[0], c[1], c[2], c[3], c[4], c[5])
	for g in GLASS_RD:
		_add_block(root, g[0], g[1], g[2], g[3], g[4], "glass")
	for n in NEONS_RD:
		_add_block(root, n[0], n[1], n[2], n[3], n[4], n[5])

	_add_street_lights(root)

	var sites := _build_sites(root)
	_build_spawn_markers(root)
	_add_decals(root)
	_add_environment_detail(root, "district")

	return {
		"root": root,
		"sites": sites,
		"spawn_strike": SPAWN_STRIKE,
		"spawn_guard": SPAWN_GUARD,
		"waypoints": WAYPOINTS,
		"display_name": "RED DISTRICT",
	}


## 黄昏环境: 低角度橙色夕阳 + 暖灰雾, 霓虹招牌自发光承担点缀
static func _build_environment_dusk(root: Node3D) -> void:
	EnvForge.build_dusk(root)


static func _add_street_lights(root: Node3D) -> void:
	var positions := [
		Vector3(0, 4.5, 20), Vector3(0, 4.5, 8), Vector3(0, 4.5, -4),
		Vector3(-14, 4.5, -12), Vector3(14, 4.5, -12),
		Vector3(-20, 4.5, -21), Vector3(20, 4.5, -21),
	]
	for pos in positions:
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.70, 0.45)
		lamp.light_energy = 2.6
		lamp.omni_range = 13.0
		lamp.position = pos
		lamp.shadow_enabled = GraphicsQuality.current() >= GraphicsQuality.Tier.ULTRA and GraphicsQuality.current() != GraphicsQuality.Tier.COMPETITIVE
		lamp.light_cull_mask = ~(GameConfig.FX_VISUAL_LAYER)
		root.add_child(lamp)


# ================================================================ TRAINING RANGE(训练场/靶场)
## 提示词第 37-38 条: 100m 靶场 / 静态靶 / 移动靶 / 材质穿透测试区。
## 训练模式由 MatchManager.training_mode 驱动: 无回合推进、假人自动复活、弹药无限。

const TARGET_STATIC := [
	Vector3(0, 0, -30), Vector3(5, 0, -60), Vector3(-4, 0, -90),
]
const TARGET_MOVING := [
	[Vector3(-8, 0, -45), Vector3(8, 0, -45)],
	[Vector3(-8, 0, -75), Vector3(8, 0, -75)],
]

const WALLS_TR := [
	[0, -104.5, 80, 1.2, 9, "concrete"],
	[0, 14.5, 80, 1.2, 9, "concrete"],
	[-19.5, -45, 1.2, 120, 9, "concrete"],
	[19.5, -45, 1.2, 120, 9, "concrete"],
	[-14, 8, 1.0, 3, 2.6, "concrete"],
	[14, 8, 1.0, 3, 2.6, "concrete"],
]

const COVERS_TR := [
	[-13.5, -15, 4, 0.6, 2.4, "wood"],
	[-4.5, -15, 4, 0.6, 2.4, "glass"],
	[4.5, -15, 4, 0.6, 2.4, "metal"],
	[13.5, -15, 4, 0.6, 2.4, "concrete"],
	[-17, -20, 0.6, 0.6, 1.2, "hazard"],
	[-17, -30, 0.6, 0.6, 1.2, "hazard"],
	[-17, -40, 0.6, 0.6, 1.2, "hazard"],
	[-17, -50, 0.6, 0.6, 1.2, "hazard"],
	[-17, -60, 0.6, 0.6, 1.2, "hazard"],
	[-17, -70, 0.6, 0.6, 1.2, "hazard"],
	[-17, -80, 0.6, 0.6, 1.2, "hazard"],
	[-17, -90, 0.6, 0.6, 1.2, "hazard"],
	[-17, -100, 0.6, 0.6, 1.2, "hazard"],
	[-8, 2, 2.2, 2.2, 1.3, "crate"],
	[8, 2, 2.2, 2.2, 1.3, "crate"],
	[0, -1, 2.4, 2.4, 1.2, "metal"],
]


static func _build_training_range() -> Dictionary:
	var root := Node3D.new()
	root.name = "Map_training_range"

	_build_environment(root)
	_build_ground(root, Color(0.30, 0.31, 0.33))
	for w in WALLS_TR:
		_add_block(root, w[0], w[1], w[2], w[3], w[4], w[5])
	for c in COVERS_TR:
		_add_block(root, c[0], c[1], c[2], c[3], c[4], c[5])

	for pos in TARGET_STATIC:
		var disc := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(2.4, 2.4)
		plane.orientation = PlaneMesh.FACE_Y
		disc.mesh = plane
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0.9, 0.25, 0.2, 0.35)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		disc.material_override = m
		disc.position = pos + Vector3(0, 0.03, 0)
		root.add_child(disc)

	return {
		"root": root,
		"sites": [],
		"spawn_strike": [Vector3(0, 0, 5)],
		"spawn_guard": [Vector3(0, 0, 5)],
		"waypoints": [],
		"display_name": "TRAINING RANGE",
	}
