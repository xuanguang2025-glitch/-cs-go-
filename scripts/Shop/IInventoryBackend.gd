class_name IInventoryBackend
extends RefCounted
##
## IInventoryBackend.gd — 库存后端契约
##
## GDScript 没有 interface, 用共同基类约定方法签名。
## SteamInventoryAdapter 与 LocalInventoryAdapter 都实现这一套,
## InventoryService 只认这里的接口, 不关心底层是 Steam 还是本地文件。
##
## 约定:
##   - item_id 是 SkinDatabase 里的字符串 id(如 "ws_falcon_crimson_tide")
##   - 所有方法同步返回; Steam 的异步由适配器内部缓存消化
##


## 初始化后端。返回 OK 表示可用。
func initialize() -> Error:
	return ERR_UNAVAILABLE


## 释放资源 / 断开连接
func shutdown() -> void:
	pass


## 后端是否处于可用状态(Steam 已连接、文件可读等)
func is_available() -> bool:
	return false


## 人类可读的后端名, 用于调试显示
func get_backend_name() -> String:
	return "unknown"


## 当前拥有的全部 item_id
func get_owned_item_ids() -> Array:
	return []


## 是否拥有某件物品
func has_item(item_id: String) -> bool:
	return false


## 授予物品。重复授予由实现决定是否计数量。
func grant_item(item_id: String, quantity: int = 1) -> bool:
	return false


## 消耗物品(开箱钥匙、可消耗饰品)。数量不足必须整体失败。
func consume_item(item_id: String, quantity: int = 1) -> bool:
	return false


## 当前持有数量。Steam 侧按实例数计。
func get_item_count(item_id: String) -> int:
	return 0


## 从库存彻底移除。测试与"拆解/回收"用它, 不要用超大数量的 consume_item ——
## 那会被超额消耗保护拒绝, 变成"以为清掉了其实没清"的假通过。
func clear_item(item_id: String) -> void:
	pass


## 读取货币余额; 后端不管理货币时返回 0
func get_currency_balance(currency_type: String) -> int:
	return 0


## 写入货币余额; 后端不管理货币时返回 false
func set_currency_balance(currency_type: String, amount: int) -> bool:
	return false


## 开箱保底计数。必须持久 —— 计数会随重启清掉的话, 保底承诺就是空的。
func get_pity(box_id: String) -> int:
	return 0


func set_pity(box_id: String, value: int) -> void:
	pass


## 立即落盘(本地后端用); Steam 后端为空实现
func flush() -> void:
	pass
