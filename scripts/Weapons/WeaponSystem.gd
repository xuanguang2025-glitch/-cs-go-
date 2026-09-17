extends Node
class_name WeaponSystem
##
## WeaponSystem.gd — 武器持有 / 射击 / 后坐力 / 扩散 / 换弹 / 视图模型
##
## 拆分成两个更新频率:
##   physics_tick(delta)  由 Actor 在 128Hz 物理帧调用 —— 射击、换弹、扩散、ADS 状态
##   _process(delta)      渲染帧调用 —— 只做视图模型插值动画, 保证视觉平滑
##
## 后坐力模型(可学习):
##   recoil_pattern 是每发的确定性偏移量, 玩家下拉鼠标改变 base_pitch,
##   停止射击后 recoil 平滑归零 -> 形成标准"压枪"手感。
##

enum State { IDLE, RELOADING, SWITCHING, THROWING }

const SLOT_BY_INDEX := ["primary", "secondary", "melee"]

var actor: Actor
var state: int = State.IDLE

var current_slot: String = "secondary"
var current_id: String = ""
var current_data: Dictionary = {}

var ammo_in_mag: int = 0
var reserve_ammo: int = 0

var dynamic_spread: float = 0.0
var ads_blend: float = 0.0
var aiming: bool = false

var shot_count: int = 0
var recoil_recovery: float = 8.0
var move_speed_mult: float = 1.0

var fx: FXManager
var hit_system: HitSystem
var sound: Node

var _clock: float = 0.0
var _next_fire_at: float = 0.0
var _state_end: float = 0.0
var _time_since_shot: float = 99.0
var _pending_weapon: String = ""
var _pending_grenade: String = ""
var _burst_remaining: int = 0

# 视图模型
var _viewmodels: Dictionary = {}       # weapon_id -> Node3D
var _viewmodel: Node3D
var _muzzle: Node3D
var _shell_eject: Node3D
var _base_vm_pos: Vector3 = Vector3(0.155, -0.135, -0.30)
var _ads_vm_pos: Vector3 = Vector3(0.0, -0.052, -0.185)
var _recoil_kick: float = 0.0
var _bob_time: float = 0.0
var _sprint_blend: float = 0.0

# 鼠标视角惯性摆动: 武器滞后于视角转动, 大幅提升第一人称"手感"
var _last_neck_rot: Vector2 = Vector2.ZERO
var _sway: Vector2 = Vector2.ZERO
var _sway_init: bool = false

var base_fov: float = 90.0


# ================================================================ 初始化
func _ready() -> void:
	set_process(true)


func refresh_weapons() -> void:
	current_id = ""
	current_data = {}
	ammo_in_mag = 0
	reserve_ammo = 0
	equip_slot("secondary", true)


func equip_slot(slot: String, instant: bool = false) -> void:
	if actor == null or actor.loadout == null:
		return
	var id: String = actor.loadout.get_slot_weapon(slot)
	if id == "":
		if slot == "melee":
			id = "knife"
		else:
			return
	if id == current_id and state == State.IDLE:
		return
	equip_weapon(id, slot, instant)


func equip_weapon(id: String, slot: String, instant: bool = false) -> void:
	if not WeaponDatabase.has_weapon(id):
		push_warning("[WeaponSystem] 未知道具: " + id)
		return
	current_id = id
	current_slot = slot
	current_data = WeaponDatabase.get_weapon(id)
	recoil_recovery = float(current_data["recoil_recovery"])
	move_speed_mult = float(current_data["move_speed_mult"])

	ammo_in_mag = actor.loadout.get_mag(id)
	reserve_ammo = actor.loadout.get_reserve(id)
	shot_count = 0
	dynamic_spread = 0.0
	_burst_remaining = 0

	if instant:
		_finish_switch()
	else:
		state = State.SWITCHING
		_state_end = _clock + float(current_data["equip_time"])
		if sound != null:
			sound.play_2d("dryfire", -18.0, randf_range(1.4, 1.7))


func cycle_weapon() -> void:
	var order := ["primary", "secondary", "melee"]
	var idx: int = order.find(current_slot)
	for i in order.size():
		var next_slot: String = order[(idx + 1 + i) % order.size()]
		var wid: String = actor.loadout.get_slot_weapon(next_slot)
		if next_slot == "melee" or wid != "":
			equip_slot(next_slot)
			return


func equip_slot_index(idx: int) -> void:
	if idx < 0 or idx >= SLOT_BY_INDEX.size():
		return
	# 4 号键循环投掷物
	if idx == 3:
		select_grenade()
		return
	equip_slot(SLOT_BY_INDEX[idx])


# ================================================================ 主循环
func physics_tick(delta: float) -> void:
	_clock += delta
	_time_since_shot += delta
	if actor == null or not is_instance_valid(actor) or not actor.alive:
		return

	_update_ads(delta)
	_update_spread(delta)

	match state:
		State.IDLE:
			_process_idle()
		State.RELOADING:
			if _clock >= _state_end:
				_finish_reload()
		State.SWITCHING:
			if _clock >= _state_end:
				_finish_switch()
		State.THROWING:
			if _clock >= _state_end:
				state = State.IDLE

	if _time_since_shot > 0.28:
		shot_count = 0


func _process_idle() -> void:
	var intent: ActorIntent = actor.intent

	if intent.switch_slot >= 0:
		equip_slot_index(intent.switch_slot)
		return
	if intent.cycle_weapon:
		cycle_weapon()
		return
	if intent.throw_grenade != "":
		_throw_grenade(intent.throw_grenade, intent.throw_power)
		return
	if intent.reload:
		start_reload()
		return

	if current_data.is_empty():
		return

	var mode: String = str(current_data["fire_mode"])
	var want_fire := false
	match mode:
		"auto":
			want_fire = intent.fire_held
		"semi", "bolt", "pump", "melee":
			want_fire = intent.fire_pressed
		"burst":
			want_fire = intent.fire_held or intent.fire_pressed
			if _burst_remaining > 0:
				want_fire = true

	if want_fire and _clock >= _next_fire_at:
		_fire()


# ---------------------------------------------------------------- 射击
func _fire() -> void:
	if str(current_data["class"]) == "melee":
		_do_melee()
		return

	if ammo_in_mag <= 0:
		_dry_fire()
		return

	var mode: String = str(current_data["fire_mode"])
	if mode == "burst":
		if _burst_remaining <= 0:
			_burst_remaining = 3

	ammo_in_mag -= 1
	actor.loadout.set_mag(current_id, ammo_in_mag)
	shot_count += 1
	_time_since_shot = 0.0

	var spread: float = get_current_spread()
	var origin: Vector3 = actor.get_shoot_origin()
	var dir: Vector3 = actor.get_shoot_direction()
	# 服务器权威 + 回溯: 按射击者的网络延迟倒回其他角色再判定命中
	var rewind_ms: float = 0.0
	if NetworkManager.is_server:
		rewind_ms = NetworkManager.estimate_rewind_for(actor)
	dir = apply_spread(dir, spread)

	# 确定性后坐力
	var rec: Vector2 = WeaponDatabase.recoil_at(current_id, shot_count - 1)
	var ads_scale: float = lerpf(1.0, 0.82, ads_blend)
	actor.add_recoil(rec.y * ads_scale, rec.x * ads_scale)
	actor.add_view_punch(rec.y * 0.30, rec.x * 0.24)

	dynamic_spread = minf(
		dynamic_spread + float(current_data["spread_per_shot"]),
		float(current_data["spread_max"]))

	# 命中判定(相机中心射线), 曳光弹从枪口绘制
	var muzzle_pos: Vector3 = origin
	if _muzzle != null and _viewmodel != null and _viewmodel.visible:
		muzzle_pos = _muzzle.global_position
	if hit_system != null:
		hit_system.fire_hitscan(actor, current_id, origin, dir, muzzle_pos, rewind_ms)

	_play_shot_fx()

	_next_fire_at = _clock + float(current_data["fire_interval"])

	if str(current_data.get("unscope_after_shot", false)):
		ads_blend = 0.0
		actor.intent.ads = false

	if mode == "burst":
		_burst_remaining -= 1
		if _burst_remaining <= 0:
			_next_fire_at = _clock + 0.32

	EventBus.weapon_fired.emit(actor, current_id)


func _do_melee() -> void:
	if hit_system != null:
		hit_system.fire_melee(actor, current_id)
	_next_fire_at = _clock + float(current_data["fire_interval"])
	_recoil_kick = 0.055
	if sound != null:
		sound.play_3d("knife", actor.global_position, -6.0, randf_range(0.95, 1.05), 18.0)
	_play_swing_anim()
	EventBus.weapon_fired.emit(actor, current_id)


func _dry_fire() -> void:
	_next_fire_at = _clock + 0.22
	if sound != null:
		sound.play_3d("dryfire", actor.global_position, -10.0, randf_range(0.95, 1.08), 18.0)
	# 自动换弹(可在设置里关闭)
	if reserve_ammo > 0:
		start_reload()


# ---------------------------------------------------------------- 换弹
## 训练场模式: 备弹无限
func _training_mode() -> bool:
	return GameManager.match_manager != null and GameManager.match_manager.get("training_mode") == true


func start_reload() -> void:
	if state != State.IDLE or current_data.is_empty():
		return
	if str(current_data["class"]) == "melee":
		return
	var mag_size: int = int(current_data["magazine"])
	if ammo_in_mag >= mag_size:
		return
	if reserve_ammo <= 0 and not _training_mode():
		return
	state = State.RELOADING
	_state_end = _clock + float(current_data["reload_time"])
	ads_blend = 0.0
	if sound != null:
		sound.play_3d("reload", actor.global_position, -4.0, randf_range(0.96, 1.04), 22.0)


func _finish_reload() -> void:
	var mag_size: int = int(current_data["magazine"])
	if _training_mode():
		reserve_ammo = int(current_data["ammo_reserve"])
	var need: int = mag_size - ammo_in_mag
	var take: int = mini(need, reserve_ammo)
	ammo_in_mag += take
	reserve_ammo -= take
	actor.loadout.set_mag(current_id, ammo_in_mag)
	actor.loadout.set_reserve(current_id, reserve_ammo)
	state = State.IDLE
	shot_count = 0


func _finish_switch() -> void:
	state = State.IDLE
	_hide_all_viewmodels()
	_ensure_viewmodel(current_id)
	if _viewmodel != null:
		# 只有本地玩家显示第一人称 viewmodel。远端角色一旦意外走到
		# 装备流程(如配装同步触发), 会在其身体旁渲染出漂浮的枪。
		_viewmodel.visible = actor.is_local
		var sniper_scoped: bool = str(current_data.get("viewmodel", "")) == "sniper"
		_ads_vm_pos = Vector3(0.0, -0.052, -0.185)
		if sniper_scoped:
			_ads_vm_pos = Vector3(0.0, -0.30, -0.10)   # 开镜时把枪压到视野外
	_next_fire_at = maxf(_next_fire_at, _clock + 0.05)


# ---------------------------------------------------------------- 投掷物
var _grenade_index: int = 0


func select_grenade() -> void:
	if actor == null or actor.loadout.grenades.is_empty():
		return
	_grenade_index = (_grenade_index + 1) % actor.loadout.grenades.size()
	var g: Dictionary = actor.loadout.grenades[_grenade_index]
	EventBus.announcement.emit(str(WeaponDatabase.get_grenade(g["id"]).get("display_name", "")), "equip")


func _throw_grenade(id: String, power: float) -> void:
	if actor.loadout.get_grenade_count(id) <= 0:
		return
	if state != State.IDLE:
		return
	state = State.THROWING
	_state_end = _clock + 0.55
	actor.loadout.call("consume_grenade", id)
	if GameManager.grenade_manager != null:
		GameManager.grenade_manager.throw_grenade(actor, id, power)
	_play_throw_anim()
	EventBus.grenade_thrown.emit(actor, id)


# ---------------------------------------------------------------- ADS / 扩散
func _update_ads(delta: float) -> void:
	if current_data.is_empty():
		return
	var can: bool = bool(current_data["can_ads"])
	var want: bool = actor.intent.ads and can and state == State.IDLE
	var target: float = 1.0 if want else 0.0
	var t: float = maxf(float(current_data["ads_time"]), 0.01)
	ads_blend = move_toward(ads_blend, target, delta / t)
	aiming = ads_blend > 0.62

	var cam := actor.get_camera()
	if cam != null:
		var delta_fov: float = float(current_data["ads_fov_delta"])
		cam.fov = base_fov + delta_fov * ads_blend


func _update_spread(delta: float) -> void:
	if current_data.is_empty():
		return
	var recovery: float = float(current_data["spread_recovery"])
	dynamic_spread = move_toward(dynamic_spread, 0.0, recovery * delta)


func get_current_spread() -> float:
	if current_data.is_empty():
		return 0.0
	var base: float = lerpf(
		float(current_data["spread_hip"]),
		float(current_data["spread_ads"]),
		ads_blend)

	if actor != null:
		var st: Dictionary = actor.get_accuracy_state()
		if bool(st["moving"]):
			var ratio: float = clampf(float(st["speed"]) / GameConfig.RUN_SPEED, 0.0, 1.3)
			base += float(current_data["spread_move_add"]) * ratio
		if bool(st["airborne"]):
			base += float(current_data["spread_air_add"])
		if bool(st["crouching"]):
			base *= 0.72

	return minf(base + dynamic_spread, float(current_data["spread_max"]))


## 在圆锥内均匀采样偏移方向
func apply_spread(dir: Vector3, spread_deg: float) -> Vector3:
	if spread_deg <= 0.0001:
		return dir
	var angle: float = deg_to_rad(spread_deg)
	var theta: float = randf() * TAU
	var r: float = sqrt(randf()) * tan(angle)
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.RIGHT
	var right: Vector3 = dir.cross(up).normalized()
	var up2: Vector3 = right.cross(dir).normalized()
	return (dir + right * (cos(theta) * r) + up2 * (sin(theta) * r)).normalized()


# ---------------------------------------------------------------- 表现
func _play_shot_fx() -> void:
	if sound != null:
		var profile: String = str(current_data["sound_profile"])
		var vol: float = -2.0
		if actor.is_local:
			vol = -4.0
		sound.play_3d(profile, actor.global_position, vol,
			randf_range(0.94, 1.06), 85.0)

	if _muzzle != null and fx != null and _muzzle.is_inside_tree():
		var flash_scale: float = float(current_data["muzzle_flash"])
		if flash_scale > 0.0:
			var color: Color = Color(current_data["tracer_color"]).lightened(0.35)
			fx.spawn_muzzle_flash(_muzzle.global_position, flash_scale, color)
		_recoil_kick = 0.016 + flash_scale * 0.014

	if _shell_eject != null and fx != null and _shell_eject.is_inside_tree() and actor.is_inside_tree():
		var right: Vector3 = actor.global_transform.basis.x
		var up: Vector3 = actor.global_transform.basis.y
		fx.spawn_shell(_shell_eject.global_position, right, up)


func _play_swing_anim() -> void:
	_recoil_kick = 0.05
	if _viewmodel != null:
		_viewmodel.rotation.z = -0.9


func _play_throw_anim() -> void:
	_recoil_kick = 0.04


func _process(delta: float) -> void:
	if _viewmodel == null or actor == null:
		return

	# 死亡后收枪, 不让武器跟着死亡相机一起乱转
	if not actor.alive:
		if _viewmodel.visible:
			_viewmodel.visible = false
		return

	var speed: float = actor.horizontal_speed
	_bob_time += delta * speed * 2.1

	var bob_amount: float = clampf(speed / GameConfig.RUN_SPEED, 0.0, 1.0)
	bob_amount *= (1.0 - ads_blend * 0.85)
	var bob_x: float = sin(_bob_time) * 0.010 * bob_amount
	var bob_y: float = absf(cos(_bob_time)) * 0.008 * bob_amount

	# 视角摆动: 采样脖子转动增量, 平滑后反向作用于武器 —— 甩头时武器
	# 像被"拖"着一样滞后, 停下来时回弹。开镜时按比例抑制。
	var neck := actor.get_neck()
	if neck != null:
		var cur := Vector2(neck.rotation.x, neck.rotation.y)
		if not _sway_init:
			_last_neck_rot = cur
			_sway_init = true
		var d := cur - _last_neck_rot
		_last_neck_rot = cur
		_sway = _sway.lerp(d, 1.0 - exp(-9.0 * delta))
		_sway = _sway.limit_length(0.045)

	# 冲刺/静步时的枪身姿态
	var target_sprint: float = 1.0 if (speed > GameConfig.RUN_SPEED * 0.92 and not aiming) else 0.0
	_sprint_blend = move_toward(_sprint_blend, target_sprint, delta * 6.0)

	var target_pos: Vector3 = _base_vm_pos.lerp(_ads_vm_pos, ads_blend)
	target_pos.x += bob_x
	target_pos.y += bob_y
	target_pos.z += _recoil_kick
	# 冲刺时枪身下压外偏
	target_pos.y -= _sprint_blend * 0.045
	target_pos.x += _sprint_blend * 0.055
	# 视角摆动位移(转向右→武器向左拖; 抬头→武器下沉)
	var sway_scale: float = 1.0 - ads_blend * 0.85
	target_pos.x += _sway.y * 1.6 * sway_scale
	target_pos.y -= _sway.x * 0.8 * sway_scale

	var k: float = 1.0 - exp(-24.0 * delta)
	_viewmodel.position = _viewmodel.position.lerp(target_pos, k)

	var target_rot := Vector3.ZERO
	if state == State.RELOADING:
		var t: float = 1.0 - clampf((_state_end - _clock) / maxf(float(current_data["reload_time"]), 0.01), 0.0, 1.0)
		target_rot.x = sin(t * PI) * 0.85
		target_rot.z = sin(t * PI) * 0.35
	elif _sprint_blend > 0.01:
		target_rot.z = _sprint_blend * 0.42
		target_rot.y = _sprint_blend * 0.30
	# 视角摆动旋转(幅度克制, 只求"活", 不求夸张)
	target_rot.y += _sway.y * 1.8 * sway_scale
	target_rot.x -= _sway.x * 1.2 * sway_scale
	_viewmodel.rotation = _viewmodel.rotation.lerp(target_rot, 1.0 - exp(-18.0 * delta))

	_recoil_kick = move_toward(_recoil_kick, 0.0, delta * 0.9)


# ================================================================ 视图模型
func _ensure_viewmodel(weapon_id: String) -> void:
	if _viewmodels.has(weapon_id):
		_viewmodel = _viewmodels[weapon_id]
		_muzzle = _viewmodel.get_node_or_null("Muzzle")
		_shell_eject = _viewmodel.get_node_or_null("ShellEject")
		return
	var data := WeaponDatabase.get_weapon(weapon_id)
	if data.is_empty():
		return
	var kind: String = str(data.get("viewmodel", "rifle"))
	var vm := WeaponViewModel.build(kind, actor.get_team_color())
	vm.visible = false
	actor.get_viewmodel_root().add_child(vm)
	_viewmodels[weapon_id] = vm
	_viewmodel = vm
	_muzzle = vm.get_node_or_null("Muzzle")
	_shell_eject = vm.get_node_or_null("ShellEject")


func _hide_all_viewmodels() -> void:
	for key in _viewmodels:
		var vm: Node3D = _viewmodels[key]
		vm.visible = false


# ================================================================ 对外查询
func is_aiming() -> bool:
	return aiming


func get_move_speed_multiplier() -> float:
	if current_data.is_empty():
		return 1.0
	# ADS 时额外减速
	var ads_penalty: float = lerpf(1.0, 0.62, ads_blend)
	return move_speed_mult * ads_penalty


func get_recoil_recovery() -> float:
	return recoil_recovery


func get_weapon_display_name() -> String:
	if current_data.is_empty():
		return ""
	return str(current_data["display_name"])


func get_hud_ammo() -> Vector2i:
	return Vector2i(ammo_in_mag, reserve_ammo)


func reset_for_round() -> void:
	state = State.IDLE
	shot_count = 0
	dynamic_spread = 0.0
	ads_blend = 0.0
	_burst_remaining = 0
	if not current_id.is_empty():
		ammo_in_mag = actor.loadout.get_mag(current_id)
		reserve_ammo = actor.loadout.get_reserve(current_id)
