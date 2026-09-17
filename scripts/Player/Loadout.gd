extends Node
class_name Loadout
##
## Loadout.gd — 玩家装备 / 弹药 / 投掷物 / 金钱
##
## 纯数据容器 + 购买逻辑, 不持有任何节点引用。
##

signal money_changed(new_amount: int)
signal weapon_changed(slot: String, weapon_id: String)
signal grenades_changed()
signal armor_changed(armor: int, helmet: bool)

enum Slot { PRIMARY, SECONDARY, MELEE }

const SLOT_KEY := ["primary", "secondary", "melee"]

var money: int = GameConfig.START_MONEY
var team: int = GameConfig.Team.STRIKE

var weapons: Dictionary = {
	"primary": "",
	"secondary": "",
	"melee": "knife",
}

## weapon_id -> {"mag": int, "reserve": int}
var ammo: Dictionary = {}

## 投掷物: [{"id": String, "count": int}, ...]  最多 4 个槽位
var grenades: Array = []
const MAX_GRENADE_SLOTS := 4

var armor: int = 0
var has_helmet: bool = false
var has_defuse_kit: bool = false
var has_bomb: bool = false

## 购买历史, 用于"再次购买上次装备"
var last_purchase: Array = []


func reset_for_new_match(start_money: int) -> void:
	money = start_money
	weapons = {"primary": "", "secondary": "", "melee": "knife"}
	ammo.clear()
	grenades.clear()
	armor = 0
	has_helmet = false
	has_defuse_kit = false
	has_bomb = false
	last_purchase.clear()
	money_changed.emit(money)


func setup_starting_pistol() -> void:
	var pistol: String = WeaponDatabase.get_starting_pistol(team)
	weapons["secondary"] = pistol
	ammo[pistol] = {
		"mag": int(WeaponDatabase.get_weapon(pistol)["magazine"]),
		"reserve": int(WeaponDatabase.get_weapon(pistol)["ammo_reserve"]),
	}
	weapon_changed.emit("secondary", pistol)


# ---------------------------------------------------------------- 查询
func has_weapon(id: String) -> bool:
	return weapons["primary"] == id or weapons["secondary"] == id


func get_slot_weapon(slot: String) -> String:
	return str(weapons.get(slot, ""))


func get_mag(weapon_id: String) -> int:
	if not ammo.has(weapon_id):
		return 0
	return int(ammo[weapon_id]["mag"])


func get_reserve(weapon_id: String) -> int:
	if not ammo.has(weapon_id):
		return 0
	return int(ammo[weapon_id]["reserve"])


func set_mag(weapon_id: String, v: int) -> void:
	_ensure_ammo(weapon_id)
	ammo[weapon_id]["mag"] = maxi(v, 0)


func set_reserve(weapon_id: String, v: int) -> void:
	_ensure_ammo(weapon_id)
	ammo[weapon_id]["reserve"] = maxi(v, 0)


func _ensure_ammo(weapon_id: String) -> void:
	if not ammo.has(weapon_id):
		ammo[weapon_id] = {"mag": 0, "reserve": 0}


func total_grenade_count() -> int:
	var t := 0
	for g in grenades:
		t += int(g["count"])
	return t


func get_grenade_count(id: String) -> int:
	for g in grenades:
		if str(g["id"]) == id:
			return int(g["count"])
	return 0


## 消耗一个投掷物, 返回是否成功
func consume_grenade(id: String) -> bool:
	for i in grenades.size():
		if str(grenades[i]["id"]) == id:
			var c: int = int(grenades[i]["count"]) - 1
			if c <= 0:
				grenades.remove_at(i)
			else:
				grenades[i]["count"] = c
			grenades_changed.emit()
			return true
	return false


func can_afford(price: int) -> bool:
	return money >= price


func spend(amount: int) -> bool:
	if money < amount:
		return false
	money -= amount
	money_changed.emit(money)
	return true


func add_money(amount: int) -> void:
	money = clampi(money + amount, 0, GameConfig.MAX_MONEY)
	money_changed.emit(money)


# ---------------------------------------------------------------- 购买
func buy_weapon(id: String) -> bool:
	if not WeaponDatabase.has_weapon(id):
		return false
	var data := WeaponDatabase.get_weapon(id)
	var price: int = int(data["price"])
	if price <= 0 and str(data["class"]) != "melee":
		return false
	if not can_afford(price):
		return false

	var slot: String = str(data["slot"])
	# 同槽位已有武器 -> 视为换枪, 旧枪的弹药清除
	var existing: String = get_slot_weapon(slot)
	if existing != "" and existing != id:
		ammo.erase(existing)

	weapons[slot] = id
	ammo[id] = {
		"mag": int(data["magazine"]),
		"reserve": int(data["ammo_reserve"]),
	}
	spend(price)
	weapon_changed.emit(slot, id)
	return true


func buy_grenade(id: String) -> bool:
	var data := WeaponDatabase.get_grenade(id)
	if data.is_empty():
		return false
	var price: int = int(data["price"])
	var max_carry: int = int(data["max_carry"])
	if get_grenade_count(id) >= max_carry:
		return false
	if not can_afford(price):
		return false

	var found := false
	for g in grenades:
		if str(g["id"]) == id:
			g["count"] = int(g["count"]) + 1
			found = true
			break
	if not found:
		if grenades.size() >= MAX_GRENADE_SLOTS and total_grenade_count() >= 4:
			return false
		grenades.append({"id": id, "count": 1})

	spend(price)
	grenades_changed.emit()
	return true


func buy_armor(heavy: bool) -> bool:
	var price: int = GameConfig.ARMOR_HEAVY_PRICE if heavy else GameConfig.ARMOR_LIGHT_PRICE
	if armor >= GameConfig.MAX_ARMOR and (not heavy or has_helmet):
		return false
	if not can_afford(price):
		return false
	armor = GameConfig.MAX_ARMOR
	has_helmet = heavy or has_helmet
	spend(price)
	armor_changed.emit(armor, has_helmet)
	return true


func buy_defuse_kit() -> bool:
	if has_defuse_kit:
		return false
	if not can_afford(GameConfig.DEFUSE_KIT_PRICE):
		return false
	has_defuse_kit = true
	spend(GameConfig.DEFUSE_KIT_PRICE)
	return true


func buy_ammo() -> bool:
	# 为当前所有武器补满备弹
	var cost := 0
	var targets: Array = []
	for slot in SLOT_KEY:
		var wid: String = get_slot_weapon(slot)
		if wid == "" or wid == "knife":
			continue
		var data := WeaponDatabase.get_weapon(wid)
		var reserve_max: int = int(data["ammo_reserve"])
		if get_reserve(wid) < reserve_max:
			targets.append(wid)
			cost += 60
	if targets.is_empty():
		return false
	if not can_afford(cost):
		return false
	for wid in targets:
		var data := WeaponDatabase.get_weapon(wid)
		set_reserve(wid, int(data["ammo_reserve"]))
	spend(cost)
	return true


func record_purchase(purchase_list: Array) -> void:
	last_purchase = purchase_list.duplicate(true)


## 一键复购上次的装备序列
func rebuy_last() -> bool:
	if last_purchase.is_empty():
		return false
	var ok := true
	for entry in last_purchase:
		var kind: String = str(entry["kind"])
		var id: String = str(entry["id"])
		match kind:
			"weapon":
				ok = ok and buy_weapon(id)
			"grenade":
				ok = ok and buy_grenade(id)
			"armor":
				ok = ok and buy_armor(bool(entry.get("heavy", false)))
			"kit":
				ok = ok and buy_defuse_kit()
	return ok


## 回合结束时把弹匣补满(不消耗金钱)
func refill_for_new_round() -> void:
	for slot in SLOT_KEY:
		var wid: String = get_slot_weapon(slot)
		if wid == "" or wid == "knife":
			continue
		var data := WeaponDatabase.get_weapon(wid)
		set_mag(wid, int(data["magazine"]))
		set_reserve(wid, int(data["ammo_reserve"]))
