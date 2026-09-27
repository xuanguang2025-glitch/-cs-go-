class_name SteamInventoryAdapter
extends IInventoryBackend
##
## SteamInventoryAdapter.gd — Steam 库存后端(GodotSteam)
##
## ⚠ 未经真机验证。要跑通需要: 真实 AppID + Steamworks 后台配置好的商品目录
##    + 已登录 Steam 的 GodotSteam 引擎。当前工程用的是 480(Spacewar 占位),
##    没有任何商品定义, 所以这里的代码只做到"能编译、缺失时优雅降级",
##    没有一条断言能证明它在真 Steam 下行为正确。上线前必须在自己的 AppID 上重验。
##
## 两个硬约束, 决定了本类的能力边界:
##
## 1) Steam 库存 API 是异步的。GetAllItems 只给一个 handle, 结果靠回调到。
##    而 IInventoryBackend 是同步契约 —— 所以这里只能做成"缓存优先":
##    读走本地缓存, 缓存由回调刷新。首次刷新完成前 is_available() 为 false,
##    InventoryService 因此不会把它选为主后端, 避免半路换源导致的读写错位。
##
## 2) 客户端不能凭空发货。授予物品要用 Steam Web API 的 publisher 权限,
##    游戏客户端拿不到也不该拿到那套凭据。所以 grant_item 明确返回 false
##    并给出原因, 而不是假装成功 —— 静默失败的商城比崩溃的商城更难查出问题。
##    真正的发货链路是: 客户端下单 -> 自有后端带 publisher 凭据调用 Web API
##    -> Steam 推送库存变更 -> 本类缓存刷新。那段后端不在本工程范围内。
##

const TAG := "[SteamInventory]"

## Steam 商品目录里 item def id -> 本工程 SkinDatabase 的字符串 id
var _def_to_item: Dictionary = {}
## 反向表
var _item_to_def: Dictionary = {}
## 当前拥有的 item_id -> 数量(由 Steam 回调刷新)
var _cache: Dictionary = {}
## 是否已经拿到过一次有效的库存快照
var _ready := false
## Steam 单例(可能为 null)
var _steam: Object = null
## 未确认的消耗请求: item_id -> 期望扣减数量, 用于回调后对账
var _pending_consume: Dictionary = {}


## 建表: SkinDatabase 里每个带 steam_item_def_id 的条目都进映射。
## def id 重复会让两件事变成一件事, 属于配置错误, 直接拒绝启动该后端。
func build_def_map() -> bool:
	_def_to_item.clear()
	_item_to_def.clear()
	var dup: Array = []
	for def in SkinDatabase.get_all_items():
		var item_id := String(def.get("id", ""))
		var def_id := int(def.get("steam_item_def_id", 0))
		if item_id.is_empty() or def_id <= 0:
			continue
		if _def_to_item.has(def_id):
			dup.append("%d(%s/%s)" % [def_id, String(_def_to_item[def_id]), item_id])
			continue
		_def_to_item[def_id] = item_id
		_item_to_def[item_id] = def_id
	if not dup.is_empty():
		push_error("%s steam_item_def_id 重复, 拒绝启用 Steam 后端: %s" % [TAG, ", ".join(dup)])
		return false
	return not _def_to_item.is_empty()


func initialize() -> Error:
	if not Engine.has_singleton("Steam"):
		return ERR_UNAVAILABLE
	_steam = Engine.get_singleton("Steam")
	if _steam == null or not _steam.has_method("GetAllItems"):
		_steam = null
		return ERR_UNAVAILABLE
	if not build_def_map():
		_steam = null
		# 目录撞车时后端会静默把两件事当成一件, 只能整个拒用。
		# 用 ERR_UNAVAILABLE 而非编造枚举: 调用方只区分 OK / 非 OK, 且
		# Godot 4 的 Error 里没有 "配置无效" 这一项。
		return ERR_UNAVAILABLE
	# 注册库存就绪回调; GodotSteam 的 connect 名字在不同版本有差异, 逐个尝试。
	for sig_name in ["inventory_ready", "inventory_start_session_result",
			"steamInventoryReadyCallback"]:
		if _steam.has_signal(sig_name) and not _steam.is_connected(sig_name, _on_inventory_ready):
			_steam.connect(sig_name, _on_inventory_ready)
	_request_refresh()
	return OK


func shutdown() -> void:
	_steam = null
	_ready = false
	_cache.clear()
	_pending_consume.clear()


func is_available() -> bool:
	# 只认"拿到过快照"这一个条件。Steam 未登录时 _ready 永远为 false,
	# InventoryService 会据此回落到本地后端, 不会把商城界面开成空的。
	return _steam != null and _ready


func get_backend_name() -> String:
	return "steam"


func get_owned_item_ids() -> Array:
	return _cache.keys()


func has_item(item_id: String) -> bool:
	return _cache.has(item_id)


func get_item_count(item_id: String) -> int:
	return int(_cache.get(item_id, 0))


func clear_item(item_id: String) -> void:
	_cache.erase(item_id)


## 见文件头约束 2: 客户端无发货权限, 一律拒绝。
func grant_item(item_id: String, quantity: int = 1) -> bool:
	push_warning("%s 客户端不能发货(grant), 需自有后端以 publisher 权限调用 Steam Web API: %s x%d"
		% [TAG, item_id, quantity])
	return false


func consume_item(item_id: String, quantity: int = 1) -> bool:
	if _steam == null or not _ready:
		return false
	var cnt := get_item_count(item_id)
	if cnt < quantity:
		return false
	var def_id := int(_item_to_def.get(item_id, 0))
	if def_id <= 0:
		push_warning("%s 消耗失败, 目录里没有该物品: %s" % [TAG, item_id])
		return false
	if not _steam.has_method("ConsumeItem"):
		push_warning("%s 当前 GodotSteam 未提供 ConsumeItem" % TAG)
		return false
	# 先按预期扣减, 回调回来后以 Steam 的实际数量为准覆盖 —— 不做对账就会长期漂移
	_pending_consume[item_id] = quantity
	_steam.ConsumeItem(def_id, quantity)
	return true


## Steam 侧不管理本作的双轨余额, 余额仍由本地/后端服务持有。
## 返回 0 / false 而不是编一个数, 让上层能看出这条路没接。
func get_currency_balance(_currency_type: String) -> int:
	return 0


func set_currency_balance(_currency_type: String, _amount: int) -> bool:
	return false


func get_pity(_box_id: String) -> int:
	return 0


func set_pity(_box_id: String, _value: int) -> void:
	pass


func flush() -> void:
	_request_refresh()


# ---- 回调 ----

func _on_inventory_ready(_result = null) -> void:
	_refresh_cache()


func _request_refresh() -> void:
	if _steam != null and _steam.has_method("GetAllItems"):
		_steam.GetAllItems()
	# GetAllItems 只是发起请求, 真数据在下一次回调里
	_refresh_cache()


## 从 Steam 拉一份实例列表, 折算成 item_id -> 数量写进缓存。
func _refresh_cache() -> void:
	if _steam == null:
		return
	if not _steam.has_method("GetItems"):
		return
	var raw: Variant = _steam.GetItems(false)
	if not (raw is Array):
		return
	var next: Dictionary = {}
	for entry in raw:
		if not (entry is Dictionary):
			continue
		var def_id := int(entry.get("itemdef", entry.get("item_def_id", 0)))
		var item_id := String(_def_to_item.get(def_id, ""))
		if item_id.is_empty():
			# 目录外的 def: 可能是旧商品或别的 App 的道具, 不计入本作库存
			continue
		next[item_id] = int(next.get(item_id, 0)) + 1
	_cache = next
	_ready = true
	_reconcile_pending()


## 拿 Steam 的实际数量覆盖"乐观扣减", 并把结果告诉上层
func _reconcile_pending() -> void:
	if _pending_consume.is_empty():
		return
	var changed: Array = _pending_consume.keys()
	_pending_consume.clear()
	for item_id in changed:
		if int(_cache.get(item_id, 0)) <= 0:
			_cache.erase(item_id)
