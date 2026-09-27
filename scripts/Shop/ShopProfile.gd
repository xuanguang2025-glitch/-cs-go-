class_name ShopProfile
extends RefCounted
##
## ShopProfile.gd — 一个玩家的商城状态
##
## 把"库存 + 余额 + 保底计数 + 已装备外观"打包成一个实例。
##
## 为什么要这一层: 之前这四样分散在 InventoryService / CurrencyManager /
## LocalInventoryAdapter 三个单例里, 隐式假设"全进程只有一个玩家"。
## 服务器要做权威校验时, 一次要处理 N 个玩家的请求 —— 若沿用单例,
## 服务器会拿自己的库存去校验别人的购买, 看起来是校验, 实际形同虚设。
##
## 本类不含任何网络逻辑, 也不直接碰 EventBus: 只有"本机玩家"那一份
## profile 的信号会被 InventoryService 转发到总线上, 远端玩家的变更
## 不该触发本地 UI 重绘。
##

signal items_changed(owned_ids: Array)
signal currency_changed(currency_type: String, new_balance: int)
signal loadout_changed
## 因失去所有权而被自动摘下的槽位
signal cosmetic_pruned(slot: String)

const CREDITS := "credits"
const PREMIUM := "premium"

var profile_id: String = ""
var loadout: LoadoutCosmetics

# 后端用取值函数而非固定引用: InventoryService 会在测试隔离、Steam 就绪时
# 整体换掉后端。抓住旧引用会让本 profile 一直读写已被废弃的存档对象,
# 而 profile 又需要是稳定对象(上层要一次性连接它的信号), 两者只能靠闭包调和。
var _direct: IInventoryBackend
var _getter: Callable


## p_backend 允许直接给实例(远端玩家), 也可给 Callable(本机玩家, 见下)。
func _init(p_backend, id: String = "", p_loadout: LoadoutCosmetics = null) -> void:
	if p_backend is Callable:
		_getter = p_backend
	else:
		_direct = p_backend
	profile_id = id
	loadout = p_loadout if p_loadout != null else LoadoutCosmetics.new("")
	# 库存一变就复核装备: 失去所有权的皮肤必须自动摘掉
	items_changed.connect(_on_items_changed)


func backend() -> IInventoryBackend:
	if _getter.is_valid():
		return _getter.call()
	return _direct


# ---- 库存 ----

func has_item(item_id: String) -> bool:
	var b := backend()
	return b != null and b.has_item(item_id)


func owned_ids() -> Array:
	var b := backend()
	return [] if b == null else b.get_owned_item_ids()


func count_of(item_id: String) -> int:
	var b := backend()
	return 0 if b == null else b.get_item_count(item_id)


## 只接受 SkinDatabase 里真实存在的 id, 挡住配置外/伪造的条目
func grant_item(item_id: String, quantity: int = 1) -> bool:
	var b := backend()
	if b == null or quantity <= 0:
		return false
	if not SkinDatabase.has_item(item_id):
		push_warning("[ShopProfile:%s] 授予了未知物品: %s" % [profile_id, item_id])
		return false
	if not b.grant_item(item_id, quantity):
		return false
	items_changed.emit(owned_ids())
	return true


func consume_item(item_id: String, quantity: int = 1) -> bool:
	var b := backend()
	if b == null:
		return false
	if not b.consume_item(item_id, quantity):
		return false
	items_changed.emit(owned_ids())
	return true


## 彻底移除。不要用 consume_item(id, 巨大值) 代替, 那会被超额消耗保护拒绝。
func clear_item(item_id: String) -> void:
	var b := backend()
	if b == null:
		return
	b.clear_item(item_id)
	items_changed.emit(owned_ids())


## 后端整体被换掉时(测试隔离、Steam 就绪重连)通知一次:
## 等价于"整个库存都变了", 但没有任何单件增删可指。
func notify_changed() -> void:
	items_changed.emit(owned_ids())


# ---- 货币 ----

func balance(currency_type: String) -> int:
	var b := backend()
	return 0 if b == null else b.get_currency_balance(currency_type)


func has_enough(currency_type: String, amount: int) -> bool:
	return balance(currency_type) >= amount


## 扣款。余额不足整体失败, 绝不部分扣除。amount<=0 视为无需付款。
func spend(currency_type: String, amount: int) -> bool:
	if amount < 0:
		return false
	if amount == 0:
		return true
	if not has_enough(currency_type, amount):
		return false
	return _write_balance(currency_type, balance(currency_type) - amount)


func earn(currency_type: String, amount: int) -> int:
	if amount <= 0:
		return balance(currency_type)
	_write_balance(currency_type, balance(currency_type) + amount)
	return balance(currency_type)


func refund(currency_type: String, amount: int) -> void:
	if amount > 0:
		earn(currency_type, amount)


func set_balance(currency_type: String, amount: int) -> bool:
	return _write_balance(currency_type, amount)


func _write_balance(currency_type: String, amount: int) -> bool:
	var b := backend()
	if b == null:
		return false
	if not b.set_currency_balance(currency_type, amount):
		return false
	currency_changed.emit(currency_type, b.get_currency_balance(currency_type))
	return true


# ---- 开箱保底 ----

func pity_of(box_id: String) -> int:
	var b := backend()
	return 0 if b == null else b.get_pity(box_id)


func set_pity(box_id: String, value: int) -> void:
	var b := backend()
	if b != null:
		b.set_pity(box_id, value)


# ---- 装备 ----

## 装备前必须验拥有态: 否则改一行存档就能穿上没买过的皮肤。
func equip(slot: String, item_id: String) -> Dictionary:
	if not has_item(item_id):
		return { "ok": false, "reason": "not_owned" }
	var r := loadout.equip(slot, item_id)
	if bool(r.get("ok", false)):
		loadout.save_loadout()
		loadout_changed.emit()
	return r


func unequip(slot: String) -> Dictionary:
	var r := loadout.unequip(slot)
	if bool(r.get("ok", false)):
		loadout.save_loadout()
		loadout_changed.emit()
	return r


## 失去所有权的已装备项要自动摘掉, 否则身上挂着不存在的皮肤。
## 返回被摘掉的槽位列表, 供上层逐个广播 cosmetic_unequipped ——
## 静默改状态会让 UI 停在"还穿着"的画面上。
func prune_equipment() -> Array:
	var dropped: Array = []
	for slot in loadout.all_equipped().keys():
		var item_id := loadout.get_equipped(slot)
		if not has_item(item_id) or SkinDatabase.get_item(item_id).is_empty():
			loadout.unequip(slot)
			dropped.append(slot)
	if not dropped.is_empty():
		loadout.save_loadout()
		loadout_changed.emit()
	return dropped


func _on_items_changed(_owned: Array) -> void:
	for slot in prune_equipment():
		cosmetic_pruned.emit(String(slot))
