extends CharacterBody3D
class_name Actor
##
## Actor.gd — 角色本体: 移动 / 视角 / 命中盒 / 生命周期
##
## 设计要点:
##   * 只消费 ActorIntent, 不关心输入来自玩家、Bot 还是网络。
##   * 移动采用 Quake/CS 风格的 accelerate + friction, 保证急停与侧身加速手感。
##   * 后坐力是"叠加在视角上的偏移量", 停止射击后平滑归零 —— 玩家下拉鼠标会
##     改变 base_pitch, 因此自然形成"压枪"手感。
##

signal spawned(actor: Node)
signal actor_died(actor: Node, killer: Node, weapon_id: String, is_headshot: bool)
signal stance_changed(crouching: bool)
signal footstep(actor: Node, surface: int, volume_db: float)

# ---------------------------------------------------------------- 属性
@export var actor_name: String = "Actor"
@export var team: int = GameConfig.Team.STRIKE
@export var is_bot: bool = false
@export var is_local: bool = false
@export var mouse_sensitivity: float = 1.0

var intent: ActorIntent = ActorIntent.new()
var health: HealthComponent
var loadout: Loadout
var weapon_system: Node   # WeaponSystem

## 驱动源(PlayerController 或 BotController)。由 Actor 主动 poll,
## 保证"采样 -> 消费"在同一物理帧内闭环, 不依赖节点树遍历顺序。
var controllers: Array = []

var alive: bool = false
var spawn_protection: float = 0.0

## 程序化肢体(第一人称看不到自己, 但别人眼中的移动姿态很关键)
var _leg_l: Node3D = null
var _leg_r: Node3D = null
var _arm_l: Node3D = null
var _arm_r: Node3D = null
var _walk_phase: float = 0.0

# ---------------------------------------------------------------- 视角
var base_yaw: float = 0.0
var base_pitch: float = 0.0
var recoil_pitch: float = 0.0    # 度, 正 = 枪口上抬
var recoil_yaw: float = 0.0      # 度
var view_punch: Vector2 = Vector2.ZERO
var view_punch_vel: Vector2 = Vector2.ZERO

# ---------------------------------------------------------------- 姿态
var is_crouching: bool = false
var is_walking: bool = false
var stance_blend: float = 0.0    # 0=站立 1=蹲伏
var move_state: int = GameConfig.MoveState.IDLE
var horizontal_speed: float = 0.0

# 致盲状态(由闪光弹施加, HUD 读取后渲染白屏)
var flash_intensity: float = 0.0
var flash_remaining: float = 0.0
var flash_duration: float = 0.0

# 目标装置交互
var is_planting: bool = false
var is_defusing: bool = false
var action_progress: float = 0.0

# ---------------------------------------------------------------- 节点引用
var _neck: Node3D
var _camera: Camera3D
var _viewmodel_root: Node3D
var _hitboxes: Node3D
var _head_box: Area3D
var _body_box: Area3D
var _legs_box: Area3D
var _collision: CollisionShape3D
var _capsule: CapsuleShape3D
var _model_root: Node3D          # 第三人称模型
var _held_weapon: Node3D = null  # 第三人称持枪模型(远端角色可见)

# 队伍配色材质(换边时只需改这几张, 不必遍历节点重建)
var _mat_cloth: StandardMaterial3D = null
var _mat_armor: StandardMaterial3D = null
var _mat_helmet: StandardMaterial3D = null
var _mat_pants: StandardMaterial3D = null

var _footstep_accum: float = 0.0
var _last_surface: int = GameConfig.SurfaceMat.CONCRETE

const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.25
const STAND_CENTER := 0.9
const CROUCH_CENTER := 0.625
const FOOTSTEP_DISTANCE := 2.1


# ================================================================ 生命周期
func _ready() -> void:
	_build_nodes()
	health = HealthComponent.new()
	health.name = "Health"
	add_child(health)
	loadout = Loadout.new()
	loadout.name = "Loadout"
	loadout.team = team
	add_child(loadout)
	# 第三人称持枪模型: 远端角色(Bot/网络玩家)在别人屏幕上必须"有枪"。
	# 本地玩家跳过 —— 第一人称武器走 WeaponSystem 的 viewmodel。
	loadout.weapon_changed.connect(_on_held_weapon_changed)

	weapon_system = load("res://scripts/Weapons/WeaponSystem.gd").new()
	weapon_system.name = "WeaponSystem"
	weapon_system.actor = self
	add_child(weapon_system)

	health.died.connect(_on_health_died)
	health.health_changed.connect(_on_health_changed)
	set_physics_process(true)
	set_process(true)
	add_to_group("actors")


func _build_nodes() -> void:
	collision_layer = GameConfig.LAYER_PLAYER
	collision_mask = GameConfig.LAYER_WORLD
	# 玩家之间不做刚体碰撞(避免 Bot 互相卡死), 靠软分离力推开
	# 但保留彼此可被子弹命中(hitbox 在 LAYER_HITBOX)

	_capsule = CapsuleShape3D.new()
	_capsule.radius = GameConfig.CAPSULE_RADIUS
	_capsule.height = STAND_HEIGHT
	_collision = CollisionShape3D.new()
	_collision.shape = _capsule
	_collision.position = Vector3(0, STAND_CENTER, 0)
	add_child(_collision)

	_neck = Node3D.new()
	_neck.name = "Neck"
	_neck.position = Vector3(0, GameConfig.EYE_HEIGHT, 0)
	add_child(_neck)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.fov = 90.0
	_camera.near = 0.06
	_camera.far = 600.0
	_neck.add_child(_camera)

	_viewmodel_root = Node3D.new()
	_viewmodel_root.name = "ViewModel"
	_neck.add_child(_viewmodel_root)

	_model_root = Node3D.new()
	_model_root.name = "BodyModel"
	add_child(_model_root)
	_build_body_model()

	_build_hitboxes()

	# 第一人称下必须藏掉自己的第三人称身体:
	# 相机在眼睛位置, 距"鼻锥"只有 0.18m, 距头顶球体只有 0.02m,
	# 不藏的话视野里会出现自己的鼻子/手臂/躯干, 第一人称观感极差。
	# 其他机器上的远端角色 is_local=false, 仍然可见 —— 可见性按机器区分, 正确。
	_model_root.visible = not is_local
	# cast_shadow 是 GeometryInstance3D 的属性, Node3D 没有; 遍历所有网格子节点关闭投影,
	# 避免第一人称下自己身体在地面投出影子(穿墙可见的暗影)。
	for child in _model_root.get_children():
		if child is GeometryInstance3D:
			child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_hitboxes() -> void:
	_hitboxes = Node3D.new()
	_hitboxes.name = "Hitboxes"
	add_child(_hitboxes)

	_head_box = _make_hitbox("Head", GameConfig.HitGroup.HEAD)
	var head_shape := SphereShape3D.new()
	head_shape.radius = 0.17
	_head_box.get_child(0).shape = head_shape
	_head_box.position = Vector3(0, 1.68, 0)

	_body_box = _make_hitbox("Body", GameConfig.HitGroup.BODY)
	var body_shape := CapsuleShape3D.new()
	body_shape.radius = 0.30
	body_shape.height = 0.80
	_body_box.get_child(0).shape = body_shape
	_body_box.position = Vector3(0, 1.15, 0)

	_legs_box = _make_hitbox("Legs", GameConfig.HitGroup.LEGS)
	var legs_shape := CapsuleShape3D.new()
	legs_shape.radius = 0.26
	legs_shape.height = 0.70
	_legs_box.get_child(0).shape = legs_shape
	_legs_box.position = Vector3(0, 0.42, 0)


func _make_hitbox(node_name: String, group: int) -> Area3D:
	var area := Area3D.new()
	area.name = node_name
	area.collision_layer = GameConfig.LAYER_HITBOX
	area.collision_mask = 0
	area.monitorable = true
	area.monitoring = false
	area.set_meta("hit_group", group)
	area.set_meta("actor", self)
	var shape := CollisionShape3D.new()
	area.add_child(shape)
	_hitboxes.add_child(area)
	return area


## 程序化生成第三人称身体(纯几何体, 不使用任何外部模型资源)
## 目标: 更接近真实人体比例的战术士兵, 而非"胶囊+球+鼻锥"。
## 分层材质(皮肤/作战服/护甲/头盔/战靴)让轮廓有体积与装备感; 命中盒独立于外观, 不受影响。
func _build_body_model() -> void:
	var base: Color = GameConfig.TEAM_COLOR.get(team, Color.WHITE)
	var skin := _mk_mat(Color(0.72, 0.56, 0.44), 0.9)
	_mat_cloth = _mk_mat(base.darkened(0.28), 0.82)
	_mat_armor = _mk_mat(base.darkened(0.52), 0.6, 0.12)
	_mat_helmet = _mk_mat(base.darkened(0.42), 0.5, 0.18)
	var gear := _mk_mat(Color(0.11, 0.11, 0.12), 0.7)   # 手套 / 战靴 / 腰带
	var pants := _mk_mat(base.darkened(0.62), 0.85)
	_mat_pants = pants

	# ---- 躯干: 胸腔 + 腹部 + 战术背心 + 腰带 ----
	var chest := BoxMesh.new(); chest.size = Vector3(0.36, 0.34, 0.22)
	_add_mesh(_model_root, chest, _mat_cloth, Vector3(0, 1.28, 0))
	var belly := BoxMesh.new(); belly.size = Vector3(0.30, 0.22, 0.19)
	_add_mesh(_model_root, belly, _mat_cloth, Vector3(0, 1.03, 0))
	var vest := BoxMesh.new(); vest.size = Vector3(0.38, 0.32, 0.26)
	_add_mesh(_model_root, vest, _mat_armor, Vector3(0, 1.27, 0))
	var belt := BoxMesh.new(); belt.size = Vector3(0.33, 0.07, 0.21)
	_add_mesh(_model_root, belt, gear, Vector3(0, 0.93, 0))

	# ---- 颈 / 头 / 头盔 ----
	var neck := CylinderMesh.new()
	neck.top_radius = 0.055; neck.bottom_radius = 0.06; neck.height = 0.10
	_add_mesh(_model_root, neck, skin, Vector3(0, 1.49, 0))
	var head := SphereMesh.new(); head.radius = 0.115; head.height = 0.23
	_add_mesh(_model_root, head, skin, Vector3(0, 1.61, 0))
	var helmet := SphereMesh.new(); helmet.radius = 0.135; helmet.height = 0.27
	_add_mesh(_model_root, helmet, _mat_helmet, Vector3(0, 1.645, 0),
		Vector3.ZERO, Vector3(1.0, 0.86, 1.05))

	# ---- 肩 ----
	var sh_mesh := SphereMesh.new(); sh_mesh.radius = 0.085; sh_mesh.height = 0.17
	for sx in [-1, 1]:
		_add_mesh(_model_root, sh_mesh, _mat_armor, Vector3(0.20 * sx, 1.40, 0))

	# ---- 骨盆 ----
	var pelvis := BoxMesh.new(); pelvis.size = Vector3(0.30, 0.16, 0.19)
	_add_mesh(_model_root, pelvis, pants, Vector3(0, 0.86, 0))

	# ---- 腿(单枢轴: 大腿+小腿+战靴, 由动画整体摆动) ----
	var leg_pivot_height := 0.86
	for side in [-1, 1]:
		var pivot := Node3D.new()
		pivot.name = "LegPivot" + ("L" if side < 0 else "R")
		pivot.position = Vector3(0.11 * side, leg_pivot_height, 0)
		_model_root.add_child(pivot)
		var thigh := CylinderMesh.new()
		thigh.top_radius = 0.095; thigh.bottom_radius = 0.08; thigh.height = 0.42
		thigh.radial_segments = 10
		_add_mesh(pivot, thigh, pants, Vector3(0, -0.21, 0))
		var shin := CylinderMesh.new()
		shin.top_radius = 0.075; shin.bottom_radius = 0.06; shin.height = 0.40
		shin.radial_segments = 10
		_add_mesh(pivot, shin, pants, Vector3(0, -0.61, 0))
		var boot := BoxMesh.new(); boot.size = Vector3(0.12, 0.10, 0.26)
		_add_mesh(pivot, boot, gear, Vector3(0, -0.82, -0.035))
		if side < 0: _leg_l = pivot
		else: _leg_r = pivot

	# ---- 手臂(单枢轴: 上臂+前臂+手, 由动画整体前伸持枪) ----
	for side2 in [-1, 1]:
		var sh := Node3D.new()
		sh.name = "ArmPivot" + ("L" if side2 < 0 else "R")
		sh.position = Vector3(0.22 * side2, 1.40, 0)
		_model_root.add_child(sh)
		var upper := CylinderMesh.new()
		upper.top_radius = 0.065; upper.bottom_radius = 0.055; upper.height = 0.28
		upper.radial_segments = 10
		_add_mesh(sh, upper, _mat_cloth, Vector3(0, -0.15, 0))
		var fore := CylinderMesh.new()
		fore.top_radius = 0.052; fore.bottom_radius = 0.045; fore.height = 0.26
		fore.radial_segments = 10
		_add_mesh(sh, fore, _mat_cloth, Vector3(0, -0.40, 0))
		var hand := SphereMesh.new(); hand.radius = 0.058; hand.height = 0.116
		_add_mesh(sh, hand, gear, Vector3(0, -0.55, 0))
		if side2 < 0: _arm_l = sh
		else: _arm_r = sh


func _mk_mat(color: Color, rough: float, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	return m


func _add_mesh(parent: Node, mesh: Mesh, mat: Material, pos: Vector3,
		rot: Vector3 = Vector3.ZERO, scl: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	mi.scale = scl
	parent.add_child(mi)
	return mi


# ================================================================ 生成 / 死亡

func spawn_at(pos: Vector3, yaw: float) -> void:
	alive = true
	spawn_protection = 1.5
	global_position = pos
	base_yaw = yaw
	base_pitch = 0.0
	recoil_pitch = 0.0
	recoil_yaw = 0.0
	view_punch = Vector2.ZERO
	velocity = Vector3.ZERO
	health.reset_full()
	health.armor = loadout.armor
	health.has_helmet = loadout.has_helmet
	health.has_kevlar = loadout.armor > 0
	loadout.refill_for_new_round()
	show()
	set_physics_process(true)
	set_process(true)
	weapon_system.call("refresh_weapons")
	weapon_system.call("equip_slot", "secondary")
	spawned.emit(self)
	EventBus.player_spawned.emit(self)


func kill(killer: Node, weapon_id: String, is_headshot: bool) -> void:
	if not alive:
		return
	health.health = 0.0
	health.alive = false
	_on_health_died(self, killer, weapon_id, is_headshot)


func _on_health_died(_victim: Node, killer: Node, weapon_id: String, is_headshot: bool) -> void:
	if not alive:
		return
	alive = false
	intent.reset_all()
	velocity = Vector3.ZERO
	# 交出目标装置
	if loadout.has_bomb:
		get_tree().call_group("core_device", "drop_from", self)

	actor_died.emit(self, killer, weapon_id, is_headshot)
	EventBus.player_died.emit(self, killer, weapon_id, is_headshot)

	if is_local:
		# 本地玩家: 相机下沉 + 倒地, 随后交给观战系统
		_start_death_camera()


func _start_death_camera() -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_neck, "position:y", 0.45, 0.55).set_trans(Tween.TRANS_QUAD)
	tween.tween_property(_neck, "rotation:z", deg_to_rad(28.0), 0.65).set_trans(Tween.TRANS_QUAD)
	tween.tween_property(_camera, "fov", 82.0, 0.5)


func _on_health_changed(_new_value: float, _max_value: float) -> void:
	pass


func despawn() -> void:
	alive = false
	hide()
	set_physics_process(false)


# ================================================================ 主循环
func _process(delta: float) -> void:
	_update_flash(delta)


func add_controller(c: Node) -> void:
	if c != null and not controllers.has(c):
		controllers.append(c)
		if not c.is_inside_tree():
			add_child(c)


func _physics_process(delta: float) -> void:
	if not alive:
		return
	if spawn_protection > 0.0:
		spawn_protection -= delta

	# 1. 采样意图
	for c in controllers:
		if is_instance_valid(c) and c.has_method("poll"):
			c.poll(delta)

	# 2. 消费意图
	_update_look(delta)
	_update_stance(delta)
	_move(delta)
	_update_recoil(delta)
	_update_view_punch(delta)
	_update_footsteps(delta)
	_update_limb_animation(delta)
	_update_surface_probe()

	if weapon_system != null:
		weapon_system.call("physics_tick", delta)

	horizontal_speed = Vector2(velocity.x, velocity.z).length()
	move_state = _compute_move_state()

	# 3. 清除单帧标志
	intent.clear_frame_flags()


func _compute_move_state() -> int:
	if not is_on_floor():
		return GameConfig.MoveState.AIR
	if horizontal_speed < 0.4:
		return GameConfig.MoveState.CROUCH if is_crouching else GameConfig.MoveState.IDLE
	if is_crouching:
		return GameConfig.MoveState.CROUCH
	if is_walking:
		return GameConfig.MoveState.WALK
	return GameConfig.MoveState.RUN


# ---------------------------------------------------------------- 视角
func _update_look(_delta: float) -> void:
	if intent.look_delta != Vector2.ZERO:
		# 本地玩家的灵敏度属于客户端设置；服务器端远端角色使用固定基准，
		# 避免把服务器玩家的设置错误地套到所有网络客户端身上。
		var look_sens: float = GameConfig.ADS_SENS_MULT
		var invert_y: bool = false
		if is_local:
			look_sens = clampf(float(GameManager.get_setting("ads_sensitivity_mult", GameConfig.ADS_SENS_MULT)), 0.1, 1.5)
			invert_y = bool(GameManager.get_setting("invert_y", false))
		var sens: float = GameConfig.MOUSE_SENS_BASE * mouse_sensitivity
		if weapon_system != null and weapon_system.call("is_aiming"):
			sens *= look_sens
			# 倍镜补偿: 沿用同一条开镜灵敏度路径(不另起一套), 按光学倍率线性压低
			# 转动速度 —— 放大越多, 灵敏度越低。非倍镜武器该系数恒为 1.0,
			# 既有机瞄手感完全不变。
			sens *= float(weapon_system.call("get_scope_sens_scale"))
		base_yaw -= intent.look_delta.x * sens
		var pitch_input: float = -intent.look_delta.y if invert_y else intent.look_delta.y
		base_pitch -= pitch_input * sens
		var limit: float = deg_to_rad(GameConfig.MAX_PITCH)
		base_pitch = clampf(base_pitch, -limit, limit)

	rotation.y = base_yaw
	_neck.rotation.x = base_pitch - deg_to_rad(recoil_pitch) + view_punch.x
	_neck.rotation.y = -deg_to_rad(recoil_yaw) + view_punch.y
	_neck.rotation.z = 0.0


func add_recoil(pitch_deg: float, yaw_deg: float) -> void:
	recoil_pitch += pitch_deg
	recoil_yaw += yaw_deg


func add_view_punch(pitch_deg: float, yaw_deg: float) -> void:
	view_punch_vel.x += deg_to_rad(pitch_deg) * 22.0
	view_punch_vel.y += deg_to_rad(yaw_deg) * 22.0


func _update_recoil(delta: float) -> void:
	var recovery: float = 8.0
	if weapon_system != null:
		recovery = float(weapon_system.call("get_recoil_recovery"))
	# 后坐力回正速度随残余量增大而加快, 手感更"干脆"
	var k: float = 1.0 - exp(-recovery * delta)
	recoil_pitch = lerpf(recoil_pitch, 0.0, k)
	recoil_yaw = lerpf(recoil_yaw, 0.0, k)
	if absf(recoil_pitch) < 0.005:
		recoil_pitch = 0.0
	if absf(recoil_yaw) < 0.005:
		recoil_yaw = 0.0


func _update_view_punch(delta: float) -> void:
	# 弹簧-阻尼回正
	var stiffness := 140.0
	var damping := 16.0
	var force: Vector2 = -stiffness * view_punch - damping * view_punch_vel
	view_punch_vel += force * delta
	view_punch += view_punch_vel * delta
	if view_punch.length() < 0.00002 and view_punch_vel.length() < 0.0002:
		view_punch = Vector2.ZERO
		view_punch_vel = Vector2.ZERO


# ---------------------------------------------------------------- 姿态
func _update_stance(delta: float) -> void:
	var want_crouch: bool = intent.crouch
	if want_crouch != is_crouching:
		if not want_crouch and _ceiling_blocked():
			pass           # 头顶有障碍, 保持蹲伏
		else:
			is_crouching = want_crouch
			stance_changed.emit(is_crouching)
	is_walking = intent.walk

	var target: float = 1.0 if is_crouching else 0.0
	var rate: float = 12.0
	stance_blend = move_toward(stance_blend, target, rate * delta)

	var height: float = lerpf(STAND_HEIGHT, CROUCH_HEIGHT, stance_blend)
	_capsule.height = height
	_collision.position.y = lerpf(STAND_CENTER, CROUCH_CENTER, stance_blend)
	_neck.position.y = lerpf(GameConfig.EYE_HEIGHT, GameConfig.CROUCH_HEIGHT, stance_blend)

	_head_box.position.y = lerpf(1.68, 1.06, stance_blend)
	_body_box.position.y = lerpf(1.15, 0.74, stance_blend)
	_legs_box.position.y = lerpf(0.42, 0.26, stance_blend)

	_model_root.scale.y = lerpf(1.0, 0.66, stance_blend)


func _ceiling_blocked() -> bool:
	var space := get_world_3d().direct_space_state
	var from: Vector3 = global_position + Vector3(0, CROUCH_CENTER + 0.1, 0)
	var to: Vector3 = global_position + Vector3(0, STAND_CENTER + 0.35, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = GameConfig.LAYER_WORLD
	q.exclude = [self]
	var hit := space.intersect_ray(q)
	return not hit.is_empty()


# ---------------------------------------------------------------- 移动
func current_max_speed() -> float:
	var base: float = GameConfig.RUN_SPEED
	if is_crouching:
		base = GameConfig.CROUCH_SPEED
	elif is_walking:
		base = GameConfig.WALK_SPEED
	if weapon_system != null:
		base *= float(weapon_system.call("get_move_speed_multiplier"))
	return base


func _move(delta: float) -> void:
	var wish_dir := _wish_direction()
	var max_speed := current_max_speed()

	if is_on_floor():
		if intent.jump:
			velocity.y = GameConfig.JUMP_VELOCITY
			_footstep_accum = FOOTSTEP_DISTANCE   # 起跳时给一次脚步声
		_apply_friction(delta, GameConfig.GROUND_FRICTION)
		if wish_dir.length_squared() > 0.0:
			_accelerate(wish_dir, max_speed, GameConfig.GROUND_ACCEL, delta)
		# 贴地: 保证下坡时不会持续离地
		if velocity.y < 0.0:
			velocity.y = -1.0
	else:
		velocity.y -= GameConfig.GRAVITY * delta
		if wish_dir.length_squared() > 0.0:
			_accelerate(wish_dir, max_speed, GameConfig.AIR_ACCEL, delta)
		_apply_friction(delta, GameConfig.AIR_FRICTION)

	# 水平限速(空中不强制限制, 保留连跳手感)
	var horiz := Vector2(velocity.x, velocity.z)
	if is_on_floor() and horiz.length() > max_speed * 1.35:
		horiz = horiz.normalized() * max_speed * 1.35
		velocity.x = horiz.x
		velocity.z = horiz.y

	move_and_slide()
	_separate_from_others()


func _wish_direction() -> Vector3:
	if intent.move_input == Vector2.ZERO:
		return Vector3.ZERO
	var forward: Vector3 = -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right: Vector3 = global_transform.basis.x
	right.y = 0.0
	right = right.normalized()
	var dir: Vector3 = forward * intent.move_input.y + right * intent.move_input.x
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	return dir


func _accelerate(wish_dir: Vector3, wish_speed: float, accel: float, delta: float) -> void:
	var current_speed: float = velocity.dot(wish_dir)
	var add_speed: float = wish_speed - current_speed
	if add_speed <= 0.0:
		return
	var accel_speed: float = minf(accel * wish_speed * delta, add_speed)
	velocity += wish_dir * accel_speed


func _apply_friction(delta: float, friction: float) -> void:
	var horiz := Vector2(velocity.x, velocity.z)
	var speed: float = horiz.length()
	if speed < 0.05:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var drop: float = speed * friction * delta
	var new_speed: float = maxf(speed - drop, 0.0)
	var scale: float = new_speed / speed
	velocity.x *= scale
	velocity.z *= scale


## 玩家之间软分离: 不做刚体碰撞, 用位移推开, 避免 AI 卡死
func _separate_from_others() -> void:
	var radius: float = GameConfig.CAPSULE_RADIUS * 2.0
	for other in get_tree().get_nodes_in_group("actors"):
		if other == self or not is_instance_valid(other):
			continue
		var o: Actor = other as Actor
		if o == null or not o.alive:
			continue
		var diff: Vector3 = global_position - o.global_position
		diff.y = 0.0
		var d: float = diff.length()
		if d < radius and d > 0.001:
			var push: float = (radius - d) * 0.5
			global_position += diff.normalized() * push
			o.global_position -= diff.normalized() * push


# ---------------------------------------------------------------- 脚步 / 材质
func _update_footsteps(delta: float) -> void:
	if not is_on_floor():
		_footstep_accum = FOOTSTEP_DISTANCE * 0.6
		return
	var speed: float = Vector2(velocity.x, velocity.z).length()
	if speed < 0.6:
		_footstep_accum = FOOTSTEP_DISTANCE * 0.5
		return
	_footstep_accum += speed * delta
	if _footstep_accum >= FOOTSTEP_DISTANCE:
		_footstep_accum = 0.0
		var vol: float = -5.0
		if is_walking:
			vol = -17.0
		if is_crouching:
			vol = -27.0
		# 材质用音高区分(程序化音效, 无需额外素材)
		var pitch: float = _surface_pitch(_last_surface)
		footstep.emit(self, _last_surface, vol)
		if GameManager.sound_manager != null:
			GameManager.sound_manager.play_3d("footstep", global_position, vol, pitch, 22.0)


func _surface_pitch(surface: int) -> float:
	match surface:
		GameConfig.SurfaceMat.METAL:   return 1.38
		GameConfig.SurfaceMat.WOOD:    return 0.80
		GameConfig.SurfaceMat.GRASS:   return 0.62
		GameConfig.SurfaceMat.GLASS:   return 1.55
		GameConfig.SurfaceMat.WATER:   return 0.70
		_:                             return 1.0


## 程序化肢体动画: 走路摆腿摆臂, 蹲伏时收腿, 空中张腿
func _update_limb_animation(delta: float) -> void:
	if _leg_l == null or _arm_l == null:
		return
	var speed_ratio: float = clampf(horizontal_speed / GameConfig.RUN_SPEED, 0.0, 1.3)
	_walk_phase += delta * (5.0 + 9.0 * speed_ratio)
	var swing: float = sin(_walk_phase) * 0.55 * speed_ratio
	if not is_on_floor():
		swing = 0.35          # 空中双腿微张
	var air_extra: float = 0.25 if not is_on_floor() else 0.0

	_leg_l.rotation.x = swing + air_extra
	_leg_r.rotation.x = -swing + air_extra * 0.5

	# 持枪姿态: 手臂前伸; 走路时轻微反向摆动保持自然
	var arm_base: float = -1.25
	_arm_l.rotation.x = arm_base - swing * 0.35
	_arm_r.rotation.x = arm_base + swing * 0.35
	# 蹲伏时手臂略抬
	if is_crouching:
		_arm_l.rotation.x -= 0.12
		_arm_r.rotation.x -= 0.12


func _update_surface_probe() -> void:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0, 0.4, 0),
		global_position - Vector3(0, 0.6, 0))
	q.collision_mask = GameConfig.LAYER_WORLD
	q.exclude = [self]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var collider: Object = hit["collider"]
	if collider.has_meta("surface"):
		_last_surface = int(collider.get_meta("surface"))


# ================================================================ 对外查询
func get_shoot_origin() -> Vector3:
	if _camera == null or not _camera.is_inside_tree():
		return (global_position if is_inside_tree() else position) + Vector3(0, GameConfig.EYE_HEIGHT, 0)
	return _camera.global_position


func get_shoot_direction() -> Vector3:
	if _camera == null or not _camera.is_inside_tree():
		return -(global_transform.basis.z if is_inside_tree() else transform.basis.z)
	return -_camera.global_transform.basis.z


func get_camera() -> Camera3D:
	return _camera


func get_neck() -> Node3D:
	return _neck


func get_viewmodel_root() -> Node3D:
	return _viewmodel_root


func get_hitboxes() -> Array:
	return [_head_box, _body_box, _legs_box]


func get_team_color() -> Color:
	return GameConfig.TEAM_COLOR.get(team, Color.WHITE)


## 第三人称持枪模型随配装更新(配装广播也会在客户端触发)
func _on_held_weapon_changed(slot: String, wid: String) -> void:
	if is_local or _model_root == null:
		return
	if slot != "primary" and slot != "secondary":
		return
	if _held_weapon != null:
		_held_weapon.queue_free()
		_held_weapon = null
	if wid == "":
		return
	var kind: String = str(WeaponDatabase.get_weapon(wid).get("viewmodel", "rifle"))
	if kind == "":
		return
	_held_weapon = WeaponViewModel.build(kind, get_team_color())
	# 挂在胸前偏右, 枪口朝前(几何体自带 -Z 朝向与手部)
	_held_weapon.position = Vector3(0.18, 1.28, -0.22)
	_held_weapon.rotation.y = deg_to_rad(-5)
	_model_root.add_child(_held_weapon)


## 半场交换攻守时调用
func set_team(new_team: int) -> void:
	team = new_team
	if loadout != null:
		loadout.team = new_team
		# 交换后补发对应阵营的制式手枪
		if loadout.get_slot_weapon("secondary") == "":
			loadout.setup_starting_pistol()
	_update_team_colors()


func _update_team_colors() -> void:
	if _mat_cloth == null:
		return
	var base: Color = GameConfig.TEAM_COLOR.get(team, Color.WHITE)
	_mat_cloth.albedo_color = base.darkened(0.28)
	_mat_armor.albedo_color = base.darkened(0.52)
	_mat_helmet.albedo_color = base.darkened(0.42)
	if _mat_pants != null:
		_mat_pants.albedo_color = base.darkened(0.62)


## 供武器系统查询当前精度惩罚因子
func get_accuracy_state() -> Dictionary:
	return {
		"moving": horizontal_speed > 0.8,
		"airborne": not is_on_floor(),
		"crouching": is_crouching,
		"speed": horizontal_speed,
	}


## 命中反馈: 让被击中者视角抖动(仅本地玩家可见效果)
func on_hit_received(damage: float, direction: Vector3) -> void:
	if not is_local:
		return
	var punch: float = clampf(damage * 0.06, 0.05, 0.5)
	add_view_punch(-punch, randf_range(-punch * 0.4, punch * 0.4))


func apply_flash(intensity: float, duration: float) -> void:
	# 取较强的一次致盲, 时间取较长的一次
	if intensity >= flash_intensity:
		flash_intensity = clampf(intensity, 0.0, 1.0)
	flash_remaining = maxf(flash_remaining, duration)
	flash_duration = maxf(flash_duration, duration)


func _update_flash(delta: float) -> void:
	if flash_remaining <= 0.0:
		return
	flash_remaining -= delta
	if flash_remaining <= 0.0:
		flash_remaining = 0.0
		flash_intensity = 0.0
		flash_duration = 0.0
	else:
		# 后段快速消退, 前段维持强致盲
		var k: float = flash_remaining / maxf(flash_duration, 0.01)
		flash_intensity = clampf(flash_intensity * (0.35 + 0.65 * k), 0.0, 1.0)
		if k < 0.35:
			flash_intensity *= k / 0.35


func get_flash_alpha() -> float:
	if flash_remaining <= 0.0:
		return 0.0
	return clampf(flash_intensity, 0.0, 1.0)
