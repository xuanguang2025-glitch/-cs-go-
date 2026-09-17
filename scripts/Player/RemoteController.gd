extends Node
class_name RemoteController
##
## RemoteController.gd — 远端玩家驱动(服务器侧)
##
## 与 PlayerController / BotController 同级: poll() 时从 NetworkManager 的
## 输入缓冲读取该 peer 最新上报的意图, 写入 ActorIntent。
## 服务器权威模型下, 远端玩家的移动/射击全部在服务器模拟, 客户端只上行输入。
##

var actor: Actor = null
var peer_id: int = -1

## 缓冲: NetworkManager 收到 submit_intent 时按 peer_id 写入这里
var latest_input: Dictionary = {}


func setup(actor_ref: Actor, peer: int) -> void:
	actor = actor_ref
	peer_id = peer
	latest_input = NetworkManager.get_or_create_input_buffer(peer)


func poll(_delta: float) -> void:
	if actor == null or peer_id < 0:
		return
	var inp: Dictionary = NetworkManager.get_or_create_input_buffer(peer_id)
	if inp.is_empty():
		return

	var intent: ActorIntent = actor.intent
	intent.move_input = inp.get("move", Vector2.ZERO)
	intent.look_delta = inp.get("look", Vector2.ZERO)
	intent.crouch = bool(inp.get("crouch", false))
	intent.walk = bool(inp.get("walk", false))
	intent.jump = bool(inp.get("jump", false))
	intent.fire_held = bool(inp.get("fire_held", false))
	intent.fire_pressed = bool(inp.get("fire_pressed", false))
	intent.ads = bool(inp.get("ads", false))
	intent.reload = bool(inp.get("reload", false))
	intent.use_held = bool(inp.get("use", false))
	intent.switch_slot = int(inp.get("switch", -1))
	# 单帧标志只消费一次
	inp["jump"] = false
	inp["fire_pressed"] = false
	inp["reload"] = false
	inp["switch"] = -1
