extends RefCounted
class_name WeaponViewModel
##
## WeaponViewModel.gd — 程序化生成第一人称武器模型
##
## 不加载任何外部模型资源, 全部由基础几何体拼装, 保持原创且零依赖。
## 返回结构: Node3D 下包含 "Muzzle" 标记点(枪口位置) 与 "ShellEject" 标记点。
##

const BODY_COLOR := Color(0.16, 0.17, 0.19)
const ACCENT_COLOR := Color(0.28, 0.30, 0.34)
const GRIP_COLOR := Color(0.10, 0.11, 0.12)
# 第一人称手套 / 衣袖(无皮肤色, 全手套风格, 避免恐怖谷)
const GLOVE_COLOR := Color(0.105, 0.10, 0.105)
const SLEEVE_COLOR := Color(0.155, 0.145, 0.13)


static func build(kind: String, team_color: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "WeaponModel"

	var mat_body := _make_material(BODY_COLOR)
	var mat_accent := _make_material(ACCENT_COLOR)
	var mat_grip := _make_material(GRIP_COLOR)
	var mat_team := _make_material(team_color)

	# 先建 Muzzle / ShellEject 标记点, 各 *_build_* 会去设置它们的位置
	_ensure_markers(root)

	match kind:
		"pistol":  _build_pistol(root, mat_body, mat_accent, mat_grip)
		"smg":     _build_smg(root, mat_body, mat_accent, mat_grip, mat_team)
		"rifle":   _build_rifle(root, mat_body, mat_accent, mat_grip, mat_team)
		"sniper":  _build_sniper(root, mat_body, mat_accent, mat_grip, mat_team)
		"shotgun": _build_shotgun(root, mat_body, mat_accent, mat_grip, mat_team)
		"lmg":     _build_lmg(root, mat_body, mat_accent, mat_grip, mat_team)
		"knife":   _build_knife(root, mat_body, mat_accent, mat_grip, mat_team)
		_:         _build_rifle(root, mat_body, mat_accent, mat_grip, mat_team)

	# 双手 + 前臂: 第一人称里"漂浮的枪"观感很差, 必须有持握感
	_add_hands(root, kind)

	return root


static func _make_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	m.roughness = 0.46
	m.metallic = 0.62
	m.clearcoat_enabled = true
	m.clearcoat = 0.12
	m.clearcoat_roughness = 0.28
	return m


static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material,
		rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


static func _cyl(parent: Node3D, radius: float, height: float, pos: Vector3,
		mat: Material, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


# ---------------------------------------------------------------- 双手
## 各枪型的 [右手握把位置, 左手托位]。左手为 null 表示单手持(手枪副手
## 收在主手下方, 刀只有一手)。坐标与 *_build_* 的握把/护木几何对齐。
static func _hand_anchors(kind: String) -> Array:
	match kind:
		"pistol":
			return [Vector3(0.012, -0.075, 0.045), Vector3(-0.05, -0.105, 0.02)]
		"smg":
			return [Vector3(0.012, -0.095, 0.085), Vector3(0.0, -0.06, -0.235)]
		"rifle":
			return [Vector3(0.012, -0.10, 0.11), Vector3(0.0, -0.04, -0.335)]
		"sniper":
			return [Vector3(0.012, -0.105, 0.13), Vector3(0.0, -0.045, -0.355)]
		"shotgun":
			return [Vector3(0.012, -0.09, 0.12), Vector3(0.0, -0.025, -0.275)]
		"lmg":
			return [Vector3(0.014, -0.11, 0.13), Vector3(0.0, -0.045, -0.30)]
		"knife":
			return [Vector3(0.0, 0.0, 0.07), null]
		_:
			return [Vector3(0.012, -0.10, 0.11), Vector3(0.0, -0.04, -0.335)]


## 构造一个"Y 轴对齐到 dir"的基, 用来摆前臂圆柱
static func _align_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var x := Vector3.UP.cross(y)
	if x.length_squared() < 0.0001:
		x = Vector3.RIGHT.cross(y)
	x = x.normalized()
	var z := x.cross(y)
	return Basis(x, y, z)


## 前臂: 圆柱沿 dir 摆放, pos 为圆柱中心
static func _limb(parent: Node3D, radius: float, length: float, pos: Vector3,
		dir: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius * 0.85
	mesh.height = length
	mesh.radial_segments = 10
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = Transform3D(_align_y(dir), pos)
	parent.add_child(mi)


static func _add_hands(root: Node3D, kind: String) -> void:
	var anchors := _hand_anchors(kind)
	var mat_glove := _make_material(GLOVE_COLOR)
	mat_glove.roughness = 0.8
	var mat_sleeve := _make_material(SLEEVE_COLOR)
	mat_sleeve.roughness = 0.9

	# 右手(主手): 握把处 + 前臂伸向画面右下(相机近旁)
	var r: Vector3 = anchors[0]
	_box(root, Vector3(0.062, 0.075, 0.095), r + Vector3(0.006, -0.012, 0.02),
		mat_glove, Vector3(deg_to_rad(-10), 0, 0))
	var r_dir := Vector3(0.10, -0.62, 0.78).normalized()
	_limb(root, 0.036, 0.30, r + r_dir * 0.17, r_dir, mat_sleeve)

	# 左手(副手): 护木/弹匣处 + 前臂伸向画面左下
	var l = anchors[1]
	if l != null:
		_box(root, Vector3(0.062, 0.07, 0.10), l + Vector3(-0.008, -0.018, 0.01),
			mat_glove, Vector3(deg_to_rad(-8), 0, deg_to_rad(6)))
		var l_dir := Vector3(-0.20, -0.68, 0.70).normalized()
		_limb(root, 0.034, 0.28, l + l_dir * 0.16, l_dir, mat_sleeve)


static func _ensure_markers(root: Node3D) -> void:
	if root.has_node("Muzzle"):
		return
	var muzzle := Node3D.new()
	muzzle.name = "Muzzle"
	root.add_child(muzzle)
	var eject := Node3D.new()
	eject.name = "ShellEject"
	root.add_child(eject)


# ---------------------------------------------------------------- 各类型
static func _build_pistol(root: Node3D, body: Material, accent: Material, grip: Material) -> void:
	# 滑套
	_box(root, Vector3(0.055, 0.055, 0.30), Vector3(0, 0.012, -0.10), body)
	# 枪管口
	_cyl(root, 0.017, 0.05, Vector3(0, 0.012, -0.265), accent, Vector3(deg_to_rad(90), 0, 0))
	# 握把
	_box(root, Vector3(0.048, 0.16, 0.075), Vector3(0, -0.085, 0.035), grip,
		Vector3(deg_to_rad(-14), 0, 0))
	# 扳机护圈
	_box(root, Vector3(0.036, 0.012, 0.055), Vector3(0, -0.045, -0.005), accent)
	# 准星
	_box(root, Vector3(0.010, 0.016, 0.010), Vector3(0, 0.048, -0.235), accent)
	# 照门
	_box(root, Vector3(0.026, 0.012, 0.010), Vector3(0, 0.046, -0.02), accent)
	root.get_node("Muzzle").position = Vector3(0, 0.012, -0.30)
	root.get_node("ShellEject").position = Vector3(0.035, 0.03, -0.05)


static func _build_smg(root: Node3D, body: Material, accent: Material, grip: Material,
		team: Material) -> void:
	# 机匣
	_box(root, Vector3(0.062, 0.075, 0.34), Vector3(0, 0, -0.10), body)
	# 枪管 + 消焰器
	_cyl(root, 0.019, 0.20, Vector3(0, 0.005, -0.33), accent, Vector3(deg_to_rad(90), 0, 0))
	_cyl(root, 0.026, 0.06, Vector3(0, 0.005, -0.42), accent, Vector3(deg_to_rad(90), 0, 0))
	# 弹匣
	_box(root, Vector3(0.045, 0.22, 0.075), Vector3(0, -0.15, -0.02), grip)
	# 握把
	_box(root, Vector3(0.046, 0.15, 0.070), Vector3(0, -0.105, 0.075), grip,
		Vector3(deg_to_rad(-12), 0, 0))
	# 前握把
	_box(root, Vector3(0.040, 0.11, 0.055), Vector3(0, -0.085, -0.235), grip)
	# 折叠托
	_box(root, Vector3(0.030, 0.045, 0.20), Vector3(0, -0.005, 0.17), accent)
	# 顶部导轨 + 红点
	_box(root, Vector3(0.030, 0.016, 0.20), Vector3(0, 0.046, -0.13), accent)
	_box(root, Vector3(0.040, 0.040, 0.030), Vector3(0, 0.068, -0.20), team)
	root.get_node("Muzzle").position = Vector3(0, 0.005, -0.46)
	root.get_node("ShellEject").position = Vector3(0.045, 0.02, -0.06)


static func _build_rifle(root: Node3D, body: Material, accent: Material, grip: Material,
		team: Material) -> void:
	# 机匣
	_box(root, Vector3(0.066, 0.085, 0.42), Vector3(0, 0, -0.08), body)
	# 枪管
	_cyl(root, 0.020, 0.30, Vector3(0, 0.008, -0.42), accent, Vector3(deg_to_rad(90), 0, 0))
	# 消焰器
	_cyl(root, 0.028, 0.07, Vector3(0, 0.008, -0.60), accent, Vector3(deg_to_rad(90), 0, 0))
	# 护木
	_box(root, Vector3(0.072, 0.070, 0.26), Vector3(0, -0.012, -0.34), grip)
	# 弹匣
	_box(root, Vector3(0.050, 0.26, 0.085), Vector3(0, -0.18, -0.04), grip,
		Vector3(deg_to_rad(6), 0, 0))
	# 握把
	_box(root, Vector3(0.048, 0.16, 0.075), Vector3(0, -0.11, 0.10), grip,
		Vector3(deg_to_rad(-14), 0, 0))
	# 枪托
	_box(root, Vector3(0.056, 0.090, 0.26), Vector3(0, -0.012, 0.26), body)
	_box(root, Vector3(0.062, 0.12, 0.055), Vector3(0, -0.03, 0.40), accent)
	# 导轨 + 瞄具
	_box(root, Vector3(0.032, 0.018, 0.34), Vector3(0, 0.052, -0.12), accent)
	_box(root, Vector3(0.012, 0.030, 0.012), Vector3(0, 0.078, -0.42), team)
	_box(root, Vector3(0.046, 0.030, 0.014), Vector3(0, 0.078, -0.02), accent)
	# 拉机柄
	_box(root, Vector3(0.055, 0.016, 0.045), Vector3(0.045, 0.01, 0.02), accent)
	root.get_node("Muzzle").position = Vector3(0, 0.008, -0.64)
	root.get_node("ShellEject").position = Vector3(0.048, 0.02, -0.02)


static func _build_sniper(root: Node3D, body: Material, accent: Material, grip: Material,
		team: Material) -> void:
	# 机匣
	_box(root, Vector3(0.070, 0.090, 0.40), Vector3(0, 0, -0.05), body)
	# 长枪管
	_cyl(root, 0.021, 0.52, Vector3(0, 0.008, -0.50), accent, Vector3(deg_to_rad(90), 0, 0))
	# 制退器
	_cyl(root, 0.032, 0.09, Vector3(0, 0.008, -0.79), accent, Vector3(deg_to_rad(90), 0, 0))
	# 护木
	_box(root, Vector3(0.078, 0.075, 0.30), Vector3(0, -0.014, -0.36), grip)
	# 弹匣
	_box(root, Vector3(0.048, 0.13, 0.080), Vector3(0, -0.115, -0.02), grip)
	# 握把
	_box(root, Vector3(0.048, 0.17, 0.075), Vector3(0, -0.115, 0.12), grip,
		Vector3(deg_to_rad(-16), 0, 0))
	# 枪托(带腮托)
	_box(root, Vector3(0.060, 0.095, 0.30), Vector3(0, -0.015, 0.30), body)
	_box(root, Vector3(0.066, 0.055, 0.14), Vector3(0, 0.048, 0.26), accent)
	# 瞄准镜筒
	_cyl(root, 0.034, 0.30, Vector3(0, 0.090, -0.10), body, Vector3(deg_to_rad(90), 0, 0))
	_cyl(root, 0.040, 0.05, Vector3(0, 0.090, -0.26), accent, Vector3(deg_to_rad(90), 0, 0))
	_cyl(root, 0.030, 0.03, Vector3(0, 0.090, 0.05), team, Vector3(deg_to_rad(90), 0, 0))
	# 镜座
	_box(root, Vector3(0.056, 0.030, 0.05), Vector3(0, 0.055, -0.20), accent)
	_box(root, Vector3(0.056, 0.030, 0.05), Vector3(0, 0.055, 0.0), accent)
	# 拉栓
	_cyl(root, 0.010, 0.09, Vector3(0.062, 0.010, 0.02), accent, Vector3(0, 0, deg_to_rad(90)))
	root.get_node("Muzzle").position = Vector3(0, 0.008, -0.84)
	root.get_node("ShellEject").position = Vector3(0.05, 0.02, 0.0)


static func _build_shotgun(root: Node3D, body: Material, accent: Material, grip: Material,
		team: Material) -> void:
	# 机匣
	_box(root, Vector3(0.072, 0.090, 0.34), Vector3(0, 0, -0.06), body)
	# 粗枪管(双管并列)
	_cyl(root, 0.026, 0.34, Vector3(-0.022, 0.010, -0.38), accent, Vector3(deg_to_rad(90), 0, 0))
	_cyl(root, 0.026, 0.34, Vector3(0.022, 0.010, -0.38), accent, Vector3(deg_to_rad(90), 0, 0))
	# 泵动护木
	_box(root, Vector3(0.088, 0.070, 0.20), Vector3(0, -0.035, -0.28), grip)
	# 管式弹仓
	_cyl(root, 0.019, 0.30, Vector3(0, -0.045, -0.34), accent, Vector3(deg_to_rad(90), 0, 0))
	# 握把
	_box(root, Vector3(0.050, 0.15, 0.075), Vector3(0, -0.10, 0.11), grip,
		Vector3(deg_to_rad(-14), 0, 0))
	# 枪托
	_box(root, Vector3(0.058, 0.095, 0.28), Vector3(0, -0.015, 0.30), body)
	# 准星珠
	_box(root, Vector3(0.012, 0.012, 0.012), Vector3(0, 0.048, -0.54), team)
	root.get_node("Muzzle").position = Vector3(0, 0.010, -0.57)
	root.get_node("ShellEject").position = Vector3(0.05, 0.02, 0.02)


static func _build_lmg(root: Node3D, body: Material, accent: Material, grip: Material,
		team: Material) -> void:
	# 机匣
	_box(root, Vector3(0.080, 0.100, 0.50), Vector3(0, 0, -0.06), body)
	# 重枪管
	_cyl(root, 0.026, 0.34, Vector3(0, 0.010, -0.44), accent, Vector3(deg_to_rad(90), 0, 0))
	# 两脚架
	_cyl(root, 0.008, 0.22, Vector3(-0.045, -0.10, -0.44), accent, Vector3(0, 0, deg_to_rad(22)))
	_cyl(root, 0.008, 0.22, Vector3(0.045, -0.10, -0.44), accent, Vector3(0, 0, deg_to_rad(-22)))
	# 弹鼓
	_cyl(root, 0.115, 0.075, Vector3(0, -0.14, -0.02), grip, Vector3(deg_to_rad(90), 0, 0))
	# 握把
	_box(root, Vector3(0.052, 0.16, 0.078), Vector3(0, -0.12, 0.12), grip,
		Vector3(deg_to_rad(-14), 0, 0))
	# 枪托
	_box(root, Vector3(0.060, 0.10, 0.28), Vector3(0, -0.015, 0.32), body)
	# 提把
	_box(root, Vector3(0.035, 0.045, 0.20), Vector3(0, 0.075, -0.10), accent)
	root.get_node("Muzzle").position = Vector3(0, 0.010, -0.62)
	root.get_node("ShellEject").position = Vector3(0.055, 0.02, 0.0)


static func _build_knife(root: Node3D, body: Material, accent: Material, grip: Material,
		team: Material) -> void:
	# 刀柄
	_box(root, Vector3(0.030, 0.036, 0.145), Vector3(0, -0.01, 0.06), grip)
	# 护手
	_box(root, Vector3(0.075, 0.014, 0.016), Vector3(0, -0.005, -0.018), accent)
	# 刀刃(带斜面: 用两块错位的长方体近似)
	_box(root, Vector3(0.016, 0.052, 0.20), Vector3(0, 0.012, -0.13), body)
	_box(root, Vector3(0.008, 0.030, 0.19), Vector3(0, 0.030, -0.135), accent)
	# 刀尖
	_box(root, Vector3(0.014, 0.022, 0.06), Vector3(0, 0.016, -0.25), body,
		Vector3(deg_to_rad(12), 0, 0))
	# 队伍色缠绳
	_box(root, Vector3(0.034, 0.038, 0.030), Vector3(0, -0.01, 0.11), team)
	root.get_node("Muzzle").position = Vector3(0, 0.01, -0.30)
	root.get_node("ShellEject").position = Vector3(0, 0, 0)
