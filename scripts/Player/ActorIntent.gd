extends RefCounted
class_name ActorIntent
##
## ActorIntent.gd — 角色意图数据
##
## 玩家输入、Bot AI、网络远端三者都只往这里填数据, Actor 统一消费。
## 这样做的好处: 移动/射击逻辑只有一份, 天然支持本地玩家、Bot、联网三种驱动源。
##

## 移动输入: x = 左右(strafe), y = 前后(forward)
var move_input: Vector2 = Vector2.ZERO
## 视角增量(度): x = yaw, y = pitch
var look_delta: Vector2 = Vector2.ZERO

var jump: bool = false
var crouch: bool = false
var walk: bool = false          # 静步(Shift)
var sprint: bool = false

var fire_held: bool = false
var fire_pressed: bool = false   # 本帧刚按下(单发武器用)
var ads: bool = false
var reload: bool = false
var drop: bool = false

## -1 表示无切换请求; 0=primary 1=secondary 2=melee 3=grenade
var switch_slot: int = -1
var cycle_weapon: bool = false

## 要投掷的投掷物 id, 空串表示不投
var throw_grenade: String = ""
var throw_power: float = 1.0

## 交互(安装/拆除/拾取)
var use_held: bool = false


func clear_frame_flags() -> void:
	fire_pressed = false
	jump = false
	reload = false
	drop = false
	switch_slot = -1
	cycle_weapon = false
	throw_grenade = ""
	look_delta = Vector2.ZERO


func reset_all() -> void:
	move_input = Vector2.ZERO
	look_delta = Vector2.ZERO
	jump = false
	crouch = false
	walk = false
	sprint = false
	fire_held = false
	fire_pressed = false
	ads = false
	reload = false
	drop = false
	switch_slot = -1
	cycle_weapon = false
	throw_grenade = ""
	throw_power = 1.0
	use_held = false
