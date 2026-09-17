extends Node
class_name SpectatorSystem
##
## SpectatorSystem.gd — 死亡玩家观战
##
## 直接把渲染相机切换到被观战者的相机上, 保证第一人称视角与本人所见完全一致
## (包括后坐力、开镜、致盲), 而不是另建一套摄像机去近似。
##

signal target_changed(target: Node)

var target: Actor = null
var enabled: bool = false
var mode: int = 0        # 0=第一人称队友 1=自由观察
var candidates: Array = []
var _switch_cooldown: float = 0.0


func _ready() -> void:
	name = "SpectatorSystem"
	set_process(true)


func start(dead_player: Actor, all_actors: Array) -> void:
	enabled = true
	candidates.clear()
	for a in all_actors:
		var act: Actor = a as Actor
		if act == null or act == dead_player:
			continue
		if act.team == dead_player.team:
			candidates.append(act)
	# 队友全灭则观察任何人
	if candidates.is_empty():
		candidates = all_actors.duplicate()
	next_target()


func stop() -> void:
	enabled = false
	target = null


func next_target() -> void:
	if candidates.is_empty():
		return
	var idx: int = candidates.find(target)
	idx = (idx + 1) % candidates.size()
	_set_target(candidates[idx])


func prev_target() -> void:
	if candidates.is_empty():
		return
	var idx: int = candidates.find(target)
	idx = (idx - 1 + candidates.size()) % candidates.size()
	_set_target(candidates[idx])


func _set_target(a) -> void:
	target = a as Actor
	if target == null or not is_instance_valid(target) or not target.alive:
		return
	var cam := target.get_camera()
	if cam != null:
		cam.make_current()
	target_changed.emit(target)
	EventBus.spectate_target_changed.emit(target)


func _process(delta: float) -> void:
	if not enabled:
		return
	_switch_cooldown -= delta
	# 目标死亡则自动切换
	if target == null or not is_instance_valid(target) or not target.alive:
		if _switch_cooldown <= 0.0:
			_switch_cooldown = 0.6
			_refresh_candidates()
			next_target()
		return
	if Input.is_action_just_pressed("mv_jump") and _switch_cooldown <= 0.0:
		_switch_cooldown = 0.25
		_refresh_candidates()
		next_target()


func _refresh_candidates() -> void:
	var alive_now: Array = []
	for a in candidates:
		if is_instance_valid(a) and a.alive:
			alive_now.append(a)
	if not alive_now.is_empty():
		candidates = alive_now


func get_spectate_info() -> Dictionary:
	if target == null or not is_instance_valid(target):
		return {}
	var ws = target.weapon_system
	return {
		"name": target.actor_name,
		"health": target.health.health,
		"armor": target.health.armor,
		"team": target.team,
		"alive": target.alive,
		"weapon": ws.get_weapon_display_name() if ws != null else "",
		"ammo": ws.get_hud_ammo() if ws != null else Vector2i(0, 0),
		"money": target.loadout.money,
	}
