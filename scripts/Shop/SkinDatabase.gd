extends Node
##
## SkinDatabase.gd — 皮肤 / 商城数据加载与查询
## Autoload 名: SkinDatabase
##
## 所有外观与商城配置来自 data/skins/*.json 与 data/shop/*.json。
## 代码里不允许出现硬编码的皮肤定义。
##

const RARITY_PATH := "res://data/rarity_tiers.json"
const WEAPON_SKIN_PATH := "res://data/skins/weapon_skins.json"
const CHARACTER_SKIN_PATH := "res://data/skins/character_skins.json"
const ACCESSORY_PATH := "res://data/skins/accessories.json"
const EFFECT_PATH := "res://data/skins/effects.json"
const CURRENCY_PATH := "res://data/shop/currency_config.json"
const LOOT_BOX_PATH := "res://data/shop/loot_boxes.json"
const STORE_PATH := "res://data/shop/store_catalog.json"

# 稀有度定义: key -> { id, label, color, drop_weight }
var _rarities: Dictionary = {}
# 全部外观条目: item_id -> 定义
var _items: Dictionary = {}
# 按 type 分组: type -> [item_id]
var _by_type: Dictionary = {}
# 按 rarity 分组: rarity -> [item_id]
var _by_rarity: Dictionary = {}
# 武器皮肤按 weapon_id 分组: weapon_id -> [item_id]
var _weapon_skins_by_weapon: Dictionary = {}
# 开箱定义: box_id -> 定义
var _loot_boxes: Dictionary = {}
# 商城条目: entry_id -> 定义
var _store_entries: Dictionary = {}
# 货币配置
var _currency_config: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_all()


## 重新加载全部数据(支持热更新商城配置)
func load_all() -> bool:
	var ok := _load_rarities()
	ok = _load_currency() and ok
	ok = _load_item_file(WEAPON_SKIN_PATH) and ok
	ok = _load_item_file(CHARACTER_SKIN_PATH) and ok
	ok = _load_item_file(ACCESSORY_PATH) and ok
	ok = _load_item_file(EFFECT_PATH) and ok
	ok = _load_loot_boxes() and ok
	ok = _load_store_entries() and ok
	print("[SkinDatabase] 已加载 %d 个外观条目 / %d 个开箱 / %d 个商城条目"
		% [_items.size(), _loot_boxes.size(), _store_entries.size()])
	return ok


func _load_rarities() -> bool:
	var raw = _read_json(RARITY_PATH)
	if raw == null:
		push_error("[SkinDatabase] 无法加载稀有度定义: " + RARITY_PATH)
		return false
	_rarities.clear()
	for key in raw:
		_rarities[key] = raw[key]
	return _rarities.size() > 0


func _load_currency() -> bool:
	var raw = _read_json(CURRENCY_PATH)
	if raw == null:
		push_error("[SkinDatabase] 无法加载货币配置: " + CURRENCY_PATH)
		return false
	_currency_config = raw
	return true


## 加载一个外观 JSON 数组文件, 建立 id / type / rarity / weapon 索引
func _load_item_file(path: String) -> bool:
	var raw = _read_json(path)
	if raw == null:
		push_error("[SkinDatabase] 无法加载外观数据: " + path)
		return false
	if not (raw is Array):
		push_error("[SkinDatabase] 外观数据应为数组: " + path)
		return false
	var count := 0
	for entry in raw:
		if not (entry is Dictionary):
			continue
		var id: String = str(entry.get("id", ""))
		if id.is_empty():
			push_warning("[SkinDatabase] 跳过无 id 条目: " + path)
			continue
		if _items.has(id):
			push_warning("[SkinDatabase] 重复 id 已忽略: " + id)
			continue
		_items[id] = entry
		var type: String = str(entry.get("type", "unknown"))
		var rarity: String = str(entry.get("rarity", "common"))
		if not _by_type.has(type):
			_by_type[type] = []
		_by_type[type].append(id)
		if not _by_rarity.has(rarity):
			_by_rarity[rarity] = []
		_by_rarity[rarity].append(id)
		if type == "weapon_skin":
			var wid: String = str(entry.get("weapon_id", ""))
			if not wid.is_empty():
				if not _weapon_skins_by_weapon.has(wid):
					_weapon_skins_by_weapon[wid] = []
				_weapon_skins_by_weapon[wid].append(id)
		count += 1
	return count > 0


func _load_loot_boxes() -> bool:
	var raw = _read_json(LOOT_BOX_PATH)
	if raw == null:
		push_error("[SkinDatabase] 无法加载开箱配置: " + LOOT_BOX_PATH)
		return false
	_loot_boxes.clear()
	for entry in raw:
		if not (entry is Dictionary):
			continue
		var id: String = str(entry.get("id", ""))
		if id.is_empty():
			continue
		_loot_boxes[id] = entry
	return true


func _load_store_entries() -> bool:
	var raw = _read_json(STORE_PATH)
	if raw == null:
		push_error("[SkinDatabase] 无法加载商城目录: " + STORE_PATH)
		return false
	_store_entries.clear()
	for entry in raw:
		if not (entry is Dictionary):
			continue
		var id: String = str(entry.get("entry_id", ""))
		if id.is_empty():
			continue
		_store_entries[id] = entry
	return true


# ---- 查询接口 ----

func has_item(item_id: String) -> bool:
	return _items.has(item_id)


func get_item(item_id: String) -> Dictionary:
	return _items.get(item_id, {})


func get_all_items() -> Array:
	return _items.values()


func get_items_by_type(type_name: String) -> Array:
	var ids: Array = _by_type.get(type_name, [])
	return _resolve_ids(ids)


func get_items_by_rarity(rarity: String) -> Array:
	var ids: Array = _by_rarity.get(rarity, [])
	return _resolve_ids(ids)


## 某把武器可用皮肤(含未拥有, 供商城/仓库过滤使用)
func get_weapon_skins(weapon_id: String) -> Array:
	var ids: Array = _weapon_skins_by_weapon.get(weapon_id, [])
	return _resolve_ids(ids)


func get_rarity(rarity: String) -> Dictionary:
	return _rarities.get(rarity, {})


func get_rarity_color(rarity: String) -> Color:
	var r := get_rarity(rarity)
	if r.is_empty():
		return Color(0.7, 0.7, 0.7)
	return Color.from_string(String(r.get("color", "#B0B0B0")), Color(0.7, 0.7, 0.7))


## 稀有度排序权重, 数值越大越稀有
func get_rarity_rank(rarity: String) -> int:
	return int(get_rarity(rarity).get("id", 0))


func get_loot_box(box_id: String) -> Dictionary:
	return _loot_boxes.get(box_id, {})


func get_all_loot_boxes() -> Array:
	return _loot_boxes.values()


func get_store_entry(entry_id: String) -> Dictionary:
	return _store_entries.get(entry_id, {})


func get_all_store_entries() -> Array:
	return _store_entries.values()


func get_featured_entries() -> Array:
	var out: Array = []
	for e in _store_entries.values():
		if bool(e.get("is_featured", false)):
			out.append(e)
	return out


func get_currency_config() -> Dictionary:
	return _currency_config


func _resolve_ids(ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		if _items.has(id):
			out.append(_items[id])
	return out


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("[SkinDatabase] 文件不存在: " + path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[SkinDatabase] 无法打开文件: " + path)
		return null
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_error("[SkinDatabase] JSON 解析失败: %s -> %s (第 %d 行)"
			% [path, json.get_error_message(), json.get_error_line()])
		return null
	return json.data
