extends Node
##
## InventoryService.gd — 本机玩家库存入口 + 后端选择
## Autoload 名: InventoryService
##
## 屏蔽后端差异: 有 Steam 走 SteamInventoryAdapter, 否则走 LocalInventoryAdapter。
##
## 本单例只负责两件事: (1) 挑并持有后端实例, (2) 提供只读查询。
## 一切写操作都转发给 ShopManager.self_profile(), 由 ShopProfile 发 items_changed,
## 再由 ShopManager 转成 EventBus.inventory_updated。
## 以前这里和 profile 各发一份通知, 一次授予会触发两次 UI 全量重建;
## 更要紧的是两处各自维护拥有态副本, 迟早对不上 —— 现在不存副本。
##

signal backend_changed(backend_name: String)

const LOCAL_START_CREDITS := 5000
const LOCAL_START_PREMIUM := 1000

var _backend: IInventoryBackend


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_select_backend()


func _select_backend() -> void:
	_backend = _try_steam_backend()
	if _backend == null:
		var l := LocalInventoryAdapter.new()
		if l.initialize() == OK:
			_backend = l
			if not l.had_existing_save():
				l.set_currency_balance("credits", LOCAL_START_CREDITS)
				l.set_currency_balance("premium", LOCAL_START_PREMIUM)
	if _backend == null:
		push_error("[InventoryService] 没有可用的库存后端, 商城功能将不可用")
		return
	print("[InventoryService] 库存后端 = %s" % _backend.get_backend_name())
	backend_changed.emit(_backend.get_backend_name())


## Steam 后端接入点。
##
## 只有同时满足"Steam 已连上"和"适配器首次快照已到位"才启用, 否则返回 null
## 走本地文件。这个门槛不是保守, 而是必需: SteamInventoryAdapter 的读全部走缓存,
## 缓存要等异步回调才有内容, 在它 ready 之前接管后端会让商城显示成空库存,
## 更糟的是 subsequent 的扣款会打在一份没有余额的后端上。
##
## 已知限制: 只在启动时选一次后端。Steam 若晚于本单例才就绪, 本次会话仍用本地,
## 需要重启才切到 Steam —— 中途换源要把已加载的 ShopProfile 一起迁移,
## 属于未做也未验证的路径。
func _try_steam_backend() -> IInventoryBackend:
	if SteamManager == null or not SteamManager.is_steam_active():
		return null
	var a := SteamInventoryAdapter.new()
	if a.initialize() != OK:
		push_warning("[InventoryService] Steam 库存初始化失败, 回退本地后端")
		return null
	if not a.is_available():
		# 没拿到首次快照就别接管, 但别把资源吊着
		a.shutdown()
		return null
	print("[InventoryService] 采用 Steam 库存后端")
	return a


func is_available() -> bool:
	return _backend != null and _backend.is_available()


func get_backend_name() -> String:
	return "none" if _backend == null else _backend.get_backend_name()


func get_backend() -> IInventoryBackend:
	return _backend


# ---- 查询(直接读后端, 不缓存拥有态) ----

func has_item(item_id: String) -> bool:
	return _backend != null and _backend.has_item(item_id)


func get_owned_ids() -> Array:
	return [] if _backend == null else _backend.get_owned_item_ids()


func get_owned_items() -> Array:
	var out: Array = []
	for id in get_owned_ids():
		var def: Dictionary = SkinDatabase.get_item(String(id))
		if not def.is_empty():
			out.append(def)
	return out


func count_of(item_id: String) -> int:
	return 0 if _backend == null else _backend.get_item_count(item_id)


## 当前玩家的 profile。ShopManager 尚未就绪时兜底, 避免 autoload 顺序踩空。
func _profile() -> ShopProfile:
	if ShopManager == null:
		return null
	return ShopManager.self_profile()


# ---- 写操作: 一律交给 profile ----

func grant_item(item_id: String, quantity: int = 1) -> bool:
	var p := _profile()
	return p != null and p.grant_item(item_id, quantity)


func consume_item(item_id: String, quantity: int = 1) -> bool:
	var p := _profile()
	return p != null and p.consume_item(item_id, quantity)


func clear_item(item_id: String) -> bool:
	var p := _profile()
	if p == null:
		return false
	p.clear_item(item_id)
	return true


# ---- 测试隔离: 把后端临时指到另一个存档路径 ----

## 换用独立存档文件作为本地后端, 避免测试污染玩家真实库存。
## 与正式后端一致: 全新档会写入一笔开发余额。
func use_local_save_at(path: String) -> bool:
	var l := LocalInventoryAdapter.new()
	if l.initialize_at(path) != OK:
		return false
	if not l.had_existing_save():
		l.set_currency_balance("credits", LOCAL_START_CREDITS)
		l.set_currency_balance("premium", LOCAL_START_PREMIUM)
	_backend = l
	# 换后端等同于"整个库存变了", 必须通知一次; UI 与装备复核都挂在这个信号上
	var p := _profile()
	if p != null:
		p.notify_changed()
	return true


## 本地后端从当前存档文件重读(用于丢弃测试期内存态)。
func reload_local() -> void:
	if _backend is LocalInventoryAdapter:
		_backend.reload()
		var p := _profile()
		if p != null:
			p.notify_changed()


## 清掉测试档里的全部物品。
## 探针用它隔离节与节之间的状态 —— 开箱会随机发到某件皮肤,
## 下一节如果假设"我没拥有它", 就会变成偶发失败。
func dev_clear_items() -> void:
	if _backend == null:
		return
	# keys() 要先复制: 遍历中 clear_item 会改动后端内部字典
	for id in get_owned_ids().duplicate():
		clear_item(String(id))
