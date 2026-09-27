class_name LocalInventoryAdapter
extends IInventoryBackend
##
## LocalInventoryAdapter.gd — 本地文件库存后端
##
## 无 Steam 环境(开发、离线、专用服务器测试)下的回退实现。
## 存档写在 user://inventory_local.json。
##
## 注意: 本地存档不做防篡改。它只用于开发验证与离线试玩,
##       正式多人环境的权威库存走服务器 + Steam Inventory。
##

const SAVE_PATH := "user://inventory_local.json"

var _items: Dictionary = {}
var _currency: Dictionary = {}
var _pity: Dictionary = {}
var _path := SAVE_PATH
var _loaded := false
var _existed := false


static func exists_at(path: String = SAVE_PATH) -> bool:
	return FileAccess.file_exists(path)


## 用非默认路径初始化, 供测试隔离真实存档。
func initialize_at(path: String) -> Error:
	_path = path
	return initialize()


func initialize() -> Error:
	_existed = FileAccess.file_exists(_path)
	_load()
	_loaded = true
	return OK


## 本次 initialize 之前是否已有存档。用于区分"新玩家"和"余额真是 0 的老玩家"。
func had_existing_save() -> bool:
	return _existed


## 丢弃内存状态, 从 _path 重新读取。
func reload() -> void:
	_load()


func shutdown() -> void:
	if _loaded:
		_save()
	_loaded = false


func is_available() -> bool:
	return _loaded


func get_backend_name() -> String:
	return "local"


func get_owned_item_ids() -> Array:
	return _items.keys()


func has_item(item_id: String) -> bool:
	return _items.has(item_id)


func grant_item(item_id: String, quantity: int = 1) -> bool:
	if quantity <= 0:
		return false
	var rec: Dictionary = _items.get(item_id, { "count": 0, "acquired_at": "" })
	rec["count"] = int(rec.get("count", 0)) + quantity
	if String(rec.get("acquired_at", "")).is_empty():
		rec["acquired_at"] = Time.get_datetime_string_from_system(false, true)
	_items[item_id] = rec
	_save()
	return true


func consume_item(item_id: String, quantity: int = 1) -> bool:
	if not _items.has(item_id):
		return false
	var rec: Dictionary = _items[item_id]
	var have := int(rec.get("count", 0))
	if have < quantity:
		return false
	have -= quantity
	if have <= 0:
		_items.erase(item_id)
	else:
		rec["count"] = have
		_items[item_id] = rec
	_save()
	return true


func get_item_count(item_id: String) -> int:
	return int(_items.get(item_id, {}).get("count", 0))


## 从库存彻底移除某物品。
## 不能用 consume_item(id, 很大的数) 代替 —— 那个调用会被超额消耗保护拒掉,
## 于是"以为清掉了其实没清", 是最难查的一类假通过。
func clear_item(item_id: String) -> void:
	if _items.erase(item_id):
		_save()


# ---- 货币(本地模式下由本后端持有) ----

func get_currency_balance(currency_type: String) -> int:
	return int(_currency.get(currency_type, 0))


func set_currency_balance(currency_type: String, amount: int) -> bool:
	_currency[currency_type] = maxi(amount, 0)
	_save()
	return true


func add_currency_balance(currency_type: String, delta: int) -> int:
	var v: int = maxi(get_currency_balance(currency_type) + delta, 0)
	_currency[currency_type] = v
	_save()
	return v


# ---- 开箱保底计数(跟着库存一起存, 保证重启后玩家没被清计数) ----

func get_pity(box_id: String) -> int:
	return int(_pity.get(box_id, 0))


func set_pity(box_id: String, value: int) -> void:
	_pity[box_id] = maxi(value, 0)
	_save()


# ---- 开发调试 ----

func dev_reset() -> void:
	_items.clear()
	_currency.clear()
	_pity.clear()
	_save()


# ---- 读写 ----

func _load() -> void:
	_items.clear()
	_currency.clear()
	_pity.clear()
	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		push_warning("[LocalInventory] 无法打开存档: %s (err=%d)" % [_path, FileAccess.get_open_error()])
		return
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("[LocalInventory] 存档解析失败, 已忽略: %s" % json.get_error_message())
		return
	var data = json.data
	if not (data is Dictionary):
		return
	var raw_items = data.get("items", {})
	if raw_items is Dictionary:
		for k in raw_items:
			var v = raw_items[k]
			if v is Dictionary:
				_items[k] = v
			else:
				_items[k] = { "count": int(v), "acquired_at": "" }
	var raw_cur = data.get("currency", {})
	if raw_cur is Dictionary:
		for k in raw_cur:
			_currency[k] = int(raw_cur[k])
	var raw_pity = data.get("pity", {})
	if raw_pity is Dictionary:
		for k in raw_pity:
			_pity[k] = int(raw_pity[k])


func _save() -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_error("[LocalInventory] 无法写入存档: %s (err=%d)" % [_path, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(
		{ "items": _items, "currency": _currency, "pity": _pity }, "\t"))
	f.close()
