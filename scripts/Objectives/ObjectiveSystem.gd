extends Node
class_name ObjectiveSystem
##
## ObjectiveSystem.gd — 目标装置(Core Device)的携带 / 安装 / 拆除 / 引爆
##
## 规则:
##   * 每回合开始随机(或指定)一名 STRIKE 队员携带装置
##   * 携带者死亡 -> 装置掉落在原地, 任何 STRIKE 队员走过自动拾取
##   * 在 A/B 点内按住交互键 6 秒完成安装; 移动、松开、受伤过重会中断
##   * 安装后 40 秒引爆; 防守方持拆弹器 4 秒 / 无工具 7 秒拆除
##   * 装置爆炸 -> STRIKE 胜; 拆除成功 -> GUARD 胜
##

signal plant_progress_changed(progress: float)
signal defuse_progress_changed(progress: float)
signal device_dropped(position: Vector3)

enum DeviceState { NONE, CARRIED, DROPPED, PLANTING, PLANTED, DEFUSING, EXPLODED, DEFUSED }

var state: int = DeviceState.NONE
var carrier: Actor = null
var sites: Array = []
var planted_site: BombSite = null
var planted_position: Vector3 = Vector3.ZERO

var plant_progress: float = 0.0
var defuse_progress: float = 0.0
var bomb_timer: float = GameConfig.BOMB_TIMER
var defuser: Actor = null
var planter: Actor = null

var _dropped_device: Node3D = null
## 装置掉落时的世界坐标; 未掉落时为 null。供 Bot 判断"该去捡"。
var dropped_position: Variant = null
var _beep_accum: float = 0.0
var _beep_interval: float = 1.0
var _pending_planter: Actor = null
var _blocked: bool = false

var fx: FXManager
var sound: Node


func _ready() -> void:
	name = "ObjectiveSystem"
	set_process(true)
	add_to_group("core_device")


func setup(bomb_sites: Array) -> void:
	sites = bomb_sites


# ---------------------------------------------------------------- 回合开始
func reset_round(carriers: Array) -> void:
	state = DeviceState.NONE
	carrier = null
	planter = null
	defuser = null
	planted_site = null
	plant_progress = 0.0
	defuse_progress = 0.0
	bomb_timer = GameConfig.BOMB_TIMER
	_beep_accum = 0.0
	_beep_interval = 1.0
	_pending_planter = null
	_blocked = false
	_remove_dropped_device()

	for s in sites:
		s.set_planted(false)

	# 指定携带者
	var candidates: Array = []
	for a in carriers:
		if is_instance_valid(a) and a.team == GameConfig.Team.STRIKE:
			candidates.append(a)
	if candidates.is_empty():
		return
	var chosen: Actor = candidates[randi() % candidates.size()]
	chosen.loadout.has_bomb = true
	carrier = chosen
	state = DeviceState.CARRIED
	EventBus.bomb_carrier_changed.emit(carrier)
	if chosen.is_local:
		EventBus.announcement.emit("你携带了目标装置", "info")


func drop_from(actor: Actor) -> void:
	if actor == null or not actor.loadout.has_bomb:
		return
	actor.loadout.has_bomb = false
	if carrier == actor:
		carrier = null
	_spawn_dropped_device(actor.global_position)
	state = DeviceState.DROPPED
	dropped_position = actor.global_position
	device_dropped.emit(actor.global_position)
	EventBus.bomb_carrier_changed.emit(null)


func _spawn_dropped_device(pos: Vector3) -> void:
	_remove_dropped_device()
	_dropped_device = Node3D.new()
	_dropped_device.name = "DroppedDevice"
	_dropped_device.global_position = pos + Vector3(0, 0.25, 0)

	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.34, 0.22, 0.44)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.22, 0.26)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.35, 0.1)
	mat.emission_energy_multiplier = 0.85
	mat.roughness = 0.5
	mi.material_override = mat
	mi.position = Vector3(0, 0.12, 0)
	_dropped_device.add_child(mi)

	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = GameConfig.LAYER_PLAYER
	area.monitoring = true
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.1
	shape.shape = sphere
	area.add_child(shape)
	area.body_entered.connect(_on_device_pickup)
	_dropped_device.add_child(area)

	get_tree().current_scene.add_child(_dropped_device)
	_dropped_device.global_position = pos + Vector3(0, 0.05, 0)


func _remove_dropped_device() -> void:
	if _dropped_device != null and is_instance_valid(_dropped_device):
		_dropped_device.queue_free()
	_dropped_device = null
	dropped_position = null


func _on_device_pickup(body: Node) -> void:
	var a := body as Actor
	if a == null or not a.alive:
		return
	if a.team != GameConfig.Team.STRIKE:
		return
	if state != DeviceState.DROPPED:
		return
	a.loadout.has_bomb = true
	carrier = a
	state = DeviceState.CARRIED
	_remove_dropped_device()
	EventBus.bomb_carrier_changed.emit(carrier)
	if sound != null:
		sound.play_3d("beep", a.global_position, -8.0, 1.4, 20.0)


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	match state:
		DeviceState.PLANTING:
			_tick_planting(delta)
		DeviceState.DEFUSING:
			_tick_defusing(delta)
		DeviceState.PLANTED:
			_tick_bomb(delta)


func can_plant(actor: Actor) -> bool:
	if actor == null or not actor.alive:
		return false
	if actor.team != GameConfig.Team.STRIKE:
		return false
	if not actor.loadout.has_bomb:
		return false
	if state != DeviceState.CARRIED and state != DeviceState.PLANTING:
		return false
	return _site_under_actor(actor) != null


func can_defuse(actor: Actor) -> bool:
	if actor == null or not actor.alive:
		return false
	if actor.team != GameConfig.Team.GUARD:
		return false
	if state != DeviceState.PLANTED and state != DeviceState.DEFUSING:
		return false
	if planted_site == null:
		return false
	return planted_site.contains(actor)


func _site_under_actor(actor: Actor) -> BombSite:
	for s in sites:
		if s.contains(actor):
			return s
	return null


# ---------------------------------------------------------------- 安装
func begin_plant(actor: Actor) -> void:
	if not can_plant(actor):
		return
	var site := _site_under_actor(actor)
	if site == null:
		return
	_pending_planter = actor
	state = DeviceState.PLANTING
	plant_progress = 0.0
	actor.is_planting = true
	EventBus.plant_started.emit(actor, site.site_name)
	if sound != null:
		sound.play_3d("plant", actor.global_position, -4.0, 1.0, 30.0)


func _tick_planting(delta: float) -> void:
	var actor := _pending_planter
	if actor == null or not actor.alive:
		abort_plant()
		return
	if not actor.intent.use_held:
		abort_plant()
		return
	if actor.horizontal_speed > 0.35 or not actor.is_on_floor():
		abort_plant()
		return
	if _site_under_actor(actor) == null:
		abort_plant()
		return

	plant_progress += delta / GameConfig.PLANT_TIME
	actor.action_progress = plant_progress
	plant_progress_changed.emit(plant_progress)

	if plant_progress >= 1.0:
		_complete_plant(actor)


func abort_plant() -> void:
	if _pending_planter != null:
		_pending_planter.is_planting = false
		_pending_planter.action_progress = 0.0
		EventBus.plant_aborted.emit(_pending_planter)
	plant_progress = 0.0
	_pending_planter = null
	if state == DeviceState.PLANTING:
		state = DeviceState.CARRIED if carrier != null else DeviceState.DROPPED


func _complete_plant(actor: Actor) -> void:
	var site := _site_under_actor(actor)
	if site == null:
		abort_plant()
		return
	actor.loadout.has_bomb = false
	actor.is_planting = false
	actor.action_progress = 0.0
	carrier = null
	planter = actor
	planted_site = site
	planted_position = actor.global_position
	site.set_planted(true)
	state = DeviceState.PLANTED
	bomb_timer = GameConfig.BOMB_TIMER
	_beep_accum = 0.0
	EventBus.bomb_planted.emit(site.site_name, actor)
	SteamManager.unlock_achievement(SteamManager.ACH_BOMB)
	EventBus.bomb_carrier_changed.emit(null)
	if sound != null:
		sound.play_3d("beep", planted_position, 2.0, 1.6, 60.0)


# ---------------------------------------------------------------- 拆除
func begin_defuse(actor: Actor) -> void:
	if not can_defuse(actor):
		return
	defuser = actor
	state = DeviceState.DEFUSING
	defuse_progress = 0.0
	actor.is_defusing = true
	var with_kit: bool = actor.loadout.has_defuse_kit
	EventBus.defuse_started.emit(actor, with_kit)
	if sound != null:
		sound.play_3d("defuse", actor.global_position, -4.0, 1.0, 30.0)


func _tick_defusing(delta: float) -> void:
	var actor := defuser
	if actor == null or not actor.alive:
		abort_defuse()
		return
	if not actor.intent.use_held:
		abort_defuse()
		return
	if actor.horizontal_speed > 0.35 or not actor.is_on_floor():
		abort_defuse()
		return

	var dur: float = GameConfig.DEFUSE_KIT_TIME if actor.loadout.has_defuse_kit \
		else GameConfig.DEFUSE_TIME
	defuse_progress += delta / dur
	actor.action_progress = defuse_progress
	defuse_progress_changed.emit(defuse_progress)

	if defuse_progress >= 1.0:
		_complete_defuse(actor)


func abort_defuse() -> void:
	if defuser != null:
		defuser.is_defusing = false
		defuser.action_progress = 0.0
		EventBus.defuse_aborted.emit(defuser)
	defuse_progress = 0.0
	defuser = null
	if state == DeviceState.DEFUSING:
		state = DeviceState.PLANTED


func _complete_defuse(actor: Actor) -> void:
	actor.is_defusing = false
	actor.action_progress = 0.0
	state = DeviceState.DEFUSED
	bomb_timer = 0.0
	if planted_site != null:
		planted_site.set_planted(false)
	if sound != null:
		sound.play_3d("beep", planted_position, 6.0, 0.8, 60.0)
	EventBus.bomb_defused.emit(actor)
	defuser = null


# ---------------------------------------------------------------- 引爆
func _tick_bomb(delta: float) -> void:
	bomb_timer -= delta
	if bomb_timer <= 0.0:
		_explode()
		return

	# 滴滴声随倒计时加快
	_beep_accum += delta
	_beep_interval = lerpf(0.28, 1.0, clampf(bomb_timer / GameConfig.BOMB_TIMER, 0.0, 1.0))
	if _beep_accum >= _beep_interval:
		_beep_accum = 0.0
		if sound != null:
			sound.play_3d("beep", planted_position, 4.0, 1.5, 90.0)


func _explode() -> void:
	state = DeviceState.EXPLODED
	if fx != null:
		fx.spawn_explosion(planted_position + Vector3(0, 0.6, 0), 12.0)
	if sound != null:
		sound.play_3d("explosion", planted_position, 8.0, 0.75, 180.0)

	# 爆炸对范围内所有人造成致命伤害
	for a in get_tree().get_nodes_in_group("actors"):
		var actor: Actor = a as Actor
		if actor == null or not actor.alive:
			continue
		var d: float = actor.global_position.distance_to(planted_position)
		if d > 14.0:
			continue
		actor.health.pending_weapon_id = "bomb"
		actor.health.pending_killer = planter
		actor.health.apply_damage(400.0, 1.0, false, GameConfig.HitGroup.BODY, planter)

	if planted_site != null:
		planted_site.set_planted(false)
	EventBus.bomb_exploded.emit()


# ---------------------------------------------------------------- 查询
func is_planted() -> bool:
	return state == DeviceState.PLANTED or state == DeviceState.DEFUSING


func get_bomb_timer() -> float:
	return maxf(bomb_timer, 0.0)


func get_planted_position() -> Vector3:
	return planted_position


func get_carrier() -> Actor:
	return carrier
