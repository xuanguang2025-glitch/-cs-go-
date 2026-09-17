extends Node
class_name PlayerController
##
## PlayerController.gd — 键盘鼠标输入 -> ActorIntent
##
## 由 Actor 在物理帧开头主动调用 poll(), 而不是各自注册 _physics_process,
## 这样保证"采样输入 -> 消费输入"严格在同一物理帧内完成, 不引入额外延迟。
##
## 鼠标原始输入: 关闭系统指针加速, 使用相对位移累积。
##

var actor: Actor = null
var enabled: bool = true

var _pending_look: Vector2 = Vector2.ZERO
var _pending_fire: bool = false
var _pending_jump: bool = false
var _pending_reload: bool = false
var _pending_cycle: bool = false
var _pending_switch: int = -1
var _pending_grenade: String = ""

var mouse_captured: bool = false


func _ready() -> void:
	set_process_input(true)
	set_process_unhandled_input(true)


func setup(actor_ref: Actor) -> void:
	actor = actor_ref


func set_capture(v: bool) -> void:
	mouse_captured = v
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if v else Input.MOUSE_MODE_VISIBLE)


# ---------------------------------------------------------------- 输入事件
func _input(event: InputEvent) -> void:
	if not enabled or actor == null:
		return

	if event is InputEventMouseMotion and mouse_captured:
		var rel: Vector2 = event.relative
		_pending_look += rel
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_pending_fire = true
			MOUSE_BUTTON_WHEEL_UP:
				_pending_cycle = true
			MOUSE_BUTTON_WHEEL_DOWN:
				_pending_cycle = true
		return

	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return
		match k.physical_keycode:
			KEY_SPACE:
				_pending_jump = true
			KEY_R:
				_pending_reload = true
			KEY_G:
				_pending_cycle = true
			KEY_1:
				_pending_switch = 0
			KEY_2:
				_pending_switch = 1
			KEY_3:
				_pending_switch = 2
			KEY_4:
				_pending_switch = 3
			KEY_Q:
				_pending_switch = -2      # 切回上一把


# ---------------------------------------------------------------- 每帧采样
func poll(delta: float) -> void:
	if not enabled or actor == null or not actor.alive:
		return
	var intent: ActorIntent = actor.intent

	# 视角
	intent.look_delta = _pending_look
	_pending_look = Vector2.ZERO

	# 移动
	var mv := Input.get_vector("mv_left", "mv_right", "mv_back", "mv_forward")
	intent.move_input = mv
	intent.crouch = Input.is_action_pressed("mv_crouch")
	intent.walk = Input.is_action_pressed("mv_walk")
	intent.sprint = not intent.walk

	# 射击
	intent.fire_held = Input.is_action_pressed("wpn_fire")
	intent.fire_pressed = _pending_fire
	_pending_fire = false
	intent.ads = Input.is_action_pressed("wpn_ads")

	# 动作
	intent.jump = _pending_jump
	_pending_jump = false
	intent.reload = _pending_reload
	_pending_reload = false
	intent.cycle_weapon = _pending_cycle
	_pending_cycle = false
	intent.use_held = Input.is_action_pressed("util_plant")

	if _pending_switch >= 0:
		intent.switch_slot = _pending_switch
		_pending_switch = -1
	elif _pending_switch == -2:
		intent.switch_slot = -2
		_pending_switch = -1

	# 投掷物: 选中后按左键投出
	if actor.loadout.grenades.size() > 0 and _should_throw():
		intent.throw_grenade = str(actor.loadout.grenades[0]["id"])
		intent.throw_power = 1.0


func _should_throw() -> bool:
	# G 键循环选择后, 下一次左键投掷。此处简化为: 按住 4 键槽 + 左键
	return Input.is_action_pressed("slot_grenade") and Input.is_action_pressed("wpn_fire")


func reset_pending() -> void:
	_pending_look = Vector2.ZERO
	_pending_fire = false
	_pending_jump = false
	_pending_reload = false
	_pending_cycle = false
	_pending_switch = -1
	_pending_grenade = ""
