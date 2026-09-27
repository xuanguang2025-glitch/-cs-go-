class_name LoadoutCosmetics
extends RefCounted
##
## LoadoutCosmetics.gd — 外观装备状态(跨回合 / 跨对局持久)
##
## 与 Loadout.gd 是两回事:
##   Loadout.gd  —— 回合内经济购买的枪械/护甲, 每回合重置
##   本类        —— 已装备的皮肤/特效, 永久保留, 纯视觉
##
## 槽位:
##   "character"        -> 角色皮肤
##   "weapon:<武器 id>"  -> 该武器皮肤(换武器不串装)
##   "kill_effect" / "mvp_animation" / "voice_pack"
##
## 本类只管"装备了什么", 不管"有没有资格装备"。
## 所有权校验在 ShopManager, 免得这里再持有一份库存副本。
##

const SAVE_PATH := "user://cosmetic_loadout.json"

const SLOT_CHARACTER := "character"
const SLOT_KILL_EFFECT := "kill_effect"
const SLOT_MVP := "mvp_animation"
const SLOT_VOICE := "voice_pack"
const WEAPON_PREFIX := "weapon:"

static func weapon_slot(weapon_id: String) -> String:
	return WEAPON_PREFIX + weapon_id


static func is_weapon_slot(slot: String) -> bool:
	return slot.begins_with(WEAPON_PREFIX)


static func weapon_id_of(slot: String) -> String:
	return slot.trim_prefix(WEAPON_PREFIX)


var equipped: Dictionary = {}
var save_path := SAVE_PATH


func _init(path: String = SAVE_PATH) -> void:
	if not path.is_empty():
		save_path = path
	load_loadout()


# ---- 读写 ----

func load_loadout() -> void:
	equipped.clear()
	if not FileAccess.file_exists(save_path):
		return
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		push_warning("[LoadoutCosmetics] 无法读取装备档: %s" % save_path)
		return
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("[LoadoutCosmetics] 装备档解析失败: %s" % json.get_error_message())
		return
	var data = json.data
	if not (data is Dictionary):
		return
	var raw = data.get("equipped", {})
	if raw is Dictionary:
		for k in raw:
			var v := String(raw[k])
			if not v.is_empty():
				equipped[k] = v


func save_loadout() -> bool:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		push_error("[LoadoutCosmetics] 无法写入装备档: %s (err=%d)" % [save_path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify({ "equipped": equipped }, "\t"))
	f.close()
	return true


# ---- 装备操作 ----

## 装上。item_id 传空字符串等于卸下。slot 必须合法, 物品必须存在。
## 返回 { ok: bool, reason: String }
func equip(slot: String, item_id: String) -> Dictionary:
	if slot.is_empty():
		return _fail("empty_slot")
	if not _slot_valid(slot):
		return _fail("bad_slot:%s" % slot)
	if item_id.is_empty():
		return unequip(slot)
	var def: Dictionary = SkinDatabase.get_item(item_id)
	if def.is_empty():
		return _fail("unknown_item:%s" % item_id)
	if not _type_matches_slot(slot, String(def.get("type", ""))):
		return _fail("type_mismatch:%s!%s" % [slot, String(def.get("type", ""))])
	equipped[slot] = item_id
	return { "ok": true, "reason": "" }


func unequip(slot: String) -> Dictionary:
	if not equipped.has(slot):
		return { "ok": true, "reason": "already_empty" }
	equipped.erase(slot)
	return { "ok": true, "reason": "" }


func get_equipped(slot: String) -> String:
	return String(equipped.get(slot, ""))


func get_weapon_equipped(weapon_id: String) -> String:
	return get_equipped(weapon_slot(weapon_id))


func all_equipped() -> Dictionary:
	return equipped.duplicate(true)


func clear_all() -> void:
	equipped.clear()


## 打包给其他客户端用。只传 id, 不传配置本体。
func for_network() -> Dictionary:
	return equipped.duplicate(true)


## 从网络数据还原某个远端玩家的外观(不写本地存档)。
static func from_network(data: Dictionary) -> LoadoutCosmetics:
	var l := LoadoutCosmetics.new("")
	l.equipped = data.duplicate(true)
	return l


# ---- 校验 ----

func _slot_valid(slot: String) -> bool:
	if slot in [SLOT_CHARACTER, SLOT_KILL_EFFECT, SLOT_MVP, SLOT_VOICE]:
		return true
	if is_weapon_slot(slot):
		return not WeaponDatabase.get_weapon(weapon_id_of(slot)).is_empty()
	return false


func _type_matches_slot(slot: String, type_name: String) -> bool:
	match slot:
		SLOT_CHARACTER:
			return type_name == "character_skin"
		SLOT_KILL_EFFECT:
			return type_name == "kill_effect"
		SLOT_MVP:
			return type_name == "mvp_animation"
		SLOT_VOICE:
			return type_name == "voice_pack"
	if is_weapon_slot(slot):
		return type_name == "weapon_skin"
	return false


func _fail(reason: String) -> Dictionary:
	return { "ok": false, "reason": reason }


# ---- 应用到模型 ----

## 给角色身体套上皮肤。root 是 _model_root 之类的可视节点。
static func apply_character_skin(root: Node, item_id: String) -> int:
	return apply_item_skin(root, item_id)


## 给某把武器的可视节点套皮肤
static func apply_weapon_skin(root: Node, weapon_id: String, loadout: LoadoutCosmetics) -> int:
	if loadout == null:
		return 0
	return apply_item_skin(root, loadout.get_weapon_equipped(weapon_id))


## 通用应用: 预览面板和实机走这一个函数, 避免"预览好看、进图不对"。
static func apply_item_skin(root: Node, item_id: String) -> int:
	if root == null or item_id.is_empty():
		return 0
	var def: Dictionary = SkinDatabase.get_item(item_id)
	if def.is_empty():
		return 0
	var applied := 0
	if not String(def.get("mesh_override", "")).is_empty():
		applied += _swap_mesh(root, String(def["mesh_override"]))
	applied += _tint_list(_collect_mesh_instances(root), def)
	return applied


## 别名: 调用方拿到的往往是某个具体可视节点(持枪模型)而非"角色根"。
static func apply_to_node(node: Node, item_id: String) -> int:
	return apply_item_skin(node, item_id)


## 给一份显式的网格列表上皮肤。
## Actor 用它: 身体网格和胸前挂的枪同在 _model_root 下,
## 整棵子树一起染会把枪也染成衣服颜色, 所以身体那批要单独记账、单独染。
static func apply_tint_to_meshes(meshes: Array, item_id: String) -> int:
	if item_id.is_empty():
		return 0
	var def: Dictionary = SkinDatabase.get_item(item_id)
	if def.is_empty():
		return 0
	return _tint_list(meshes, def)


## 按 id 取皮肤主色, 供 UI 卡片画色块用
static func skin_color(item_id: String, fallback: Color = Color(0.6, 0.6, 0.6)) -> Color:
	var def: Dictionary = SkinDatabase.get_item(item_id)
	if def.is_empty():
		return fallback
	return _tint_of(def, fallback)


static func _tint_of(def: Dictionary, fallback: Color = Color(0.6, 0.6, 0.6)) -> Color:
	var raw = def.get("tint", null)
	if raw is Array and (raw as Array).size() >= 3:
		var a: Array = raw
		return Color(clampf(float(a[0]), 0, 1), clampf(float(a[1]), 0, 1), clampf(float(a[2]), 0, 1))
	return fallback


## 遍历网格列表, 把 StandardMaterial3D 的 material_override 换成改过色的克隆。
## 只给"本来有材质覆盖"的网格加皮肤 —— 皮肤是改外观, 不是凭空造几何体。
static func _tint_list(meshes: Array, def: Dictionary) -> int:
	var tint := _tint_of(def)
	var count := 0
	var params: Dictionary = def.get("material_params", {})
	for mi in meshes:
		if not (mi is MeshInstance3D):
			continue
		var src := (mi as MeshInstance3D).material_override as StandardMaterial3D
		if src == null:
			continue
		var clone: StandardMaterial3D = src.duplicate(true) as StandardMaterial3D
		if clone == null:
			continue
		clone.albedo_color = tint
		if params.has("metallic"):
			clone.metallic = clampf(float(params["metallic"]), 0.0, 1.0)
		if params.has("roughness"):
			clone.roughness = clampf(float(params["roughness"]), 0.0, 1.0)
		(mi as MeshInstance3D).material_override = clone
		count += 1
	return count


static func _swap_mesh(root: Node, res_path: String) -> int:
	# 项目当前为纯程序化几何, 没有外部模型资源; 接入 .glb 皮肤时在这里挂。
	if res_path.is_empty() or not ResourceLoader.exists(res_path):
		return 0
	return 0


static func _collect_mesh_instances(root: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.push_back(c)
	return out
