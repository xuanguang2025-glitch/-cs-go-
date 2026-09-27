extends Node
##
## ShopManager.gd — 商城业务编排
## Autoload 名: ShopManager
##
## 把购买 / 开箱 / 装备三条流程收在一处, 让 UI 只管展示与点击。
##
## 结算对象是 ShopProfile(某个玩家的库存+余额+保底+装备), 不是本进程单例。
## 原因: 服务器一次要处理 N 个玩家的请求, 若沿用"本机那一份"状态,
## 服务器会拿自己的余额去校验别人的购买 —— 看着像权威校验, 实际形同虚设。
## 所以每个公开业务都能指定 profile; 不带 profile 的老接口一律服务本机玩家。
##
## 顺序约定(防"扣了钱没到货"):
##   先扣款 -> 再发货 -> 发货失败立即退款
## 反过来(先发货再扣款)会在扣款失败时留下白送的物品, 更难收拾。
##

signal loadout_changed
## 业务回执。route_* 的同步返回只覆盖离线/主机态;
## 在线客户端的真正结果一律走这个信号。
signal business_response(action: String, result: Dictionary)

# 远端玩家存档目录。服务器侧使用, 本机玩家的 profile 由 InventoryService 供。
const PROFILE_DIR := "user://shop_profiles"

var loadout: LoadoutCosmetics
var _rng := RandomNumberGenerator.new()
var _profiles: Dictionary = {}
var _self: ShopProfile
var _unbox_count := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	loadout = LoadoutCosmetics.new()
	_rng.randomize()
	# 本机 profile 只建一次: 它的信号要转成 EventBus 广播, 重复创建会漏接或重接。
	# 后端用闭包现取, 这样 InventoryService 换后端(测试隔离/Steam 就绪)时自动跟上。
	_self = ShopProfile.new(
		func() -> IInventoryBackend: return InventoryService.get_backend(),
		"self", loadout)
	_self.currency_changed.connect(
		func(t: String, v: int) -> void: EventBus.currency_changed.emit(t, v))
	_self.items_changed.connect(
		func(ids: Array) -> void: EventBus.inventory_updated.emit(ids))
	_self.cosmetic_pruned.connect(
		func(slot: String) -> void: EventBus.cosmetic_unequipped.emit(slot))
	# 服务器回执: 联网客户端唯一的真结果来源
	NetworkManager.shop_response.connect(_on_shop_response)


## balance 动作的载荷就是快照本身, 直接覆盖本地缓存
func _handle_balance_snapshot(result: Dictionary) -> void:
	if bool(result.get("success", false)):
		apply_server_snapshot(result)


## 本机玩家 profile
func self_profile() -> ShopProfile:
	return _self


# ================================================================ 路由层
## 在线客户端的一切商城业务都必须由服务器结算。
## 光有 server_* 入口而 UI 仍直接调本地 purchase_entry 是不够的 ——
## 那只是把"自己给自己发货"从一层挪到了另一层。
## 所以界面统一走 route_*: 离线/主机同步返回, 联网客户端转发并等回执。
## business_response 的声明在文件头部。


func route_purchase(entry_id: String, currency_type: String) -> Dictionary:
	return _route("purchase", [entry_id, currency_type])


func route_unbox(box_id: String) -> Dictionary:
	return _route("unbox", [box_id])


func route_equip(slot: String, item_id: String) -> Dictionary:
	return _route("equip", [slot, item_id])


func route_unequip(slot: String) -> Dictionary:
	return _route("unequip", [slot])


## 联机时请求以服务器为准回读一次拥有态与余额
func request_sync() -> void:
	if NetworkManager.is_online_client():
		NetworkManager.request_shop("balance")


func _route(action: String, args: Array) -> Dictionary:
	if NetworkManager.is_online_client():
		NetworkManager.request_shop(action, args)
		# 返回"处理中"而不是本地结果: 客户端此时无权断言成功
		return {"pending": true, "success": true, "action": action, "reason": ""}

	var res: Dictionary
	match action:
		"purchase":
			res = purchase_entry(String(args[0]), String(args[1]))
		"unbox":
			res = unbox(String(args[0]))
		"equip":
			res = equip_cosmetic(String(args[0]), String(args[1]))
		"unequip":
			res = unequip_cosmetic(String(args[0]))
		_:
			res = {"success": false, "reason": "unknown_action:%s" % action}
	business_response.emit(action, res)
	return res


func _on_shop_response(action: String, result: Dictionary) -> void:
	if action == "balance":
		_handle_balance_snapshot(result)
		business_response.emit(action, result)
		return
	# 服务器是唯一真源: 成功后回读快照, 本地那份只是缓存
	if bool(result.get("success", false)):
		request_sync()
	business_response.emit(action, result)


## 用服务器快照覆盖本地缓存(拥有态/余额/装备)。
func apply_server_snapshot(s: Dictionary) -> void:
	var p := self_profile()
	if p == null:
		return
	p.set_balance(ShopProfile.CREDITS, int(s.get("credits", 0)))
	p.set_balance(ShopProfile.PREMIUM, int(s.get("premium", 0)))

	var want: Array = s.get("owned", [])
	for have in p.owned_ids().duplicate():
		if not want.has(have):
			p.clear_item(String(have))
	for id in want:
		if not p.has_item(String(id)):
			p.grant_item(String(id), 1)

	# 直接写 loadout 而非走 equip(): 所有权判定由服务器负责,
	# 本地再判一次会用过期缓存去否决一个合法快照
	var eq: Dictionary = s.get("equipped", {})
	for slot in p.loadout.all_equipped().keys():
		if not eq.has(slot):
			p.loadout.unequip(slot)
	for slot in eq.keys():
		p.loadout.equip(String(slot), String(eq[slot]))
	p.loadout.save_loadout()
	p.notify_changed()


## 服务器: 取(或首次加载)某玩家的权威 profile。
## key 用 SteamID 优先, 退化为 peer id —— 后者重连会变, 只有前者能跨局认人。
func profile_for(peer_id: int, stable_id: String = "") -> ShopProfile:
	var key := stable_id if not stable_id.is_empty() else "peer_%d" % peer_id
	if _profiles.has(key):
		return _profiles[key]
	# 子目录不会自动出现, 缺目录时 FileAccess.open 直接返回 null, 表现为"存档莫名其妙是空的"
	if not DirAccess.dir_exists_absolute(PROFILE_DIR):
		DirAccess.make_dir_recursive_absolute(PROFILE_DIR)
	var adapter := LocalInventoryAdapter.new()
	if adapter.initialize_at(PROFILE_DIR.path_join("%s.json" % key)) != OK:
		push_error("[ShopManager] 无法为玩家 %s 建立存档" % key)
		return null
	var lo := LoadoutCosmetics.new(PROFILE_DIR.path_join("%s_loadout.json" % key))
	var p := ShopProfile.new(adapter, key, lo)
	_profiles[key] = p
	return p


## 本机玩家以外的一律不落 UI 总线, 否则 A 买东西会让 B 的界面重绘
func _is_self(profile: ShopProfile) -> bool:
	return profile == null or profile.profile_id == "self"


# ================================================================ 商店

## 这条目录项本机玩家现在能用哪种货币买。[] 表示买不了(未上架或已拥有)。
func payable_currencies(entry_id: String) -> Array:
	return payable_currencies_for(self_profile(), entry_id)


func payable_currencies_for(profile: ShopProfile, entry_id: String) -> Array:
	var entry: Dictionary = SkinDatabase.get_store_entry(entry_id)
	if entry.is_empty():
		return []
	if profile.has_item(String(entry.get("item_id", ""))):
		return []
	var out: Array = []
	if int(entry.get("cost_credits", 0)) > 0:
		out.append(ShopProfile.CREDITS)
	if int(entry.get("cost_premium", 0)) > 0:
		out.append(ShopProfile.PREMIUM)
	return out


func owns_entry(entry_id: String) -> bool:
	return owns_entry_for(self_profile(), entry_id)


func owns_entry_for(profile: ShopProfile, entry_id: String) -> bool:
	var entry: Dictionary = SkinDatabase.get_store_entry(entry_id)
	return profile.has_item(String(entry.get("item_id", "")))


func purchase_entry(entry_id: String, currency_type: String) -> Dictionary:
	return purchase_entry_for(self_profile(), entry_id, currency_type)


## 按目录项购买。currency_type 必须是该条目支持的一种。
func purchase_entry_for(profile: ShopProfile, entry_id: String, currency_type: String) -> Dictionary:
	var mine := _is_self(profile)
	var entry: Dictionary = SkinDatabase.get_store_entry(entry_id)
	if entry.is_empty():
		return _reject(mine, "", "unknown_entry:%s" % entry_id)

	var item_id := String(entry.get("item_id", ""))
	if SkinDatabase.get_item(item_id).is_empty():
		return _reject(mine, item_id, "item_gone")
	if profile.has_item(item_id):
		return _reject(mine, item_id, "already_owned")

	if not currency_type in payable_currencies_for(profile, entry_id):
		return _reject(mine, item_id, "currency_not_accepted:%s" % currency_type)

	var price := 0
	if currency_type == ShopProfile.CREDITS:
		price = int(entry.get("cost_credits", 0))
	elif currency_type == ShopProfile.PREMIUM:
		price = int(entry.get("cost_premium", 0))
	if price < 0:
		return _reject(mine, item_id, "negative_price")

	if price > 0 and not profile.spend(currency_type, price):
		return _reject(mine, item_id, "insufficient_%s" % currency_type)

	if not profile.grant_item(item_id, 1):
		if price > 0:
			profile.refund(currency_type, price)
		return _reject(mine, item_id, "grant_failed")

	if mine:
		EventBus.shop_purchase_completed.emit(item_id, true, "")
	return {
		"success": true, "reason": "", "item_id": item_id,
		"spent": price, "currency": currency_type, "entry_id": entry_id,
	}


func _reject(mine: bool, item_id: String, reason: String) -> Dictionary:
	if mine:
		EventBus.shop_purchase_completed.emit(item_id, false, reason)
	return {
		"success": false, "reason": reason, "item_id": item_id,
		"spent": 0, "currency": "", "entry_id": "",
	}


# ================================================================ 开箱

func get_pity(box_id: String) -> int:
	return get_pity_for(self_profile(), box_id)


func get_pity_for(profile: ShopProfile, box_id: String) -> int:
	return profile.pity_of(box_id)


func unbox(box_id: String) -> Dictionary:
	return unbox_for(self_profile(), box_id)


## 开一个箱子。返回 { success, item_id, rarity, pity, by_pity, duplicate, reason }
func unbox_for(profile: ShopProfile, box_id: String) -> Dictionary:
	var mine := _is_self(profile)
	var box: Dictionary = SkinDatabase.get_loot_box(box_id)
	if box.is_empty():
		return _box_fail(box_id, "unknown_box", 0)

	var cred := int(box.get("cost_credits", 0))
	var prem := int(box.get("cost_premium", 0))
	if cred <= 0 and prem <= 0:
		return _box_fail(box_id, "free_box_not_supported", profile.pity_of(box_id))

	var currency := ShopProfile.CREDITS if cred > 0 else ShopProfile.PREMIUM
	var price := cred if cred > 0 else prem

	# 先确认摇得出东西, 再扣钱 —— 免得配置坏掉时白扣一次
	var pity := profile.pity_of(box_id)
	var roll := LootBoxResolver.roll(box, _rarity_table(), pity, _rng)
	if String(roll.get("item_id", "")).is_empty():
		return _box_fail(box_id, "roll_failed:%s" % String(roll.get("error", "")), pity)

	if price > 0 and not profile.spend(currency, price):
		return _box_fail(box_id, "insufficient_%s" % currency, pity)

	var rolled_id := String(roll["item_id"])
	# 拥有态必须在发货之前问 —— 先发再问, 每件都会被判成"重复"
	var duplicate := profile.has_item(rolled_id)

	if not profile.grant_item(rolled_id, 1):
		if price > 0:
			profile.refund(currency, price)
		return _box_fail(box_id, "grant_failed", pity)

	profile.set_pity(box_id, int(roll["pity"]))

	# 开出已拥有的东西折算成积分返还, 否则箱子越开越亏且没有任何反馈
	var refunded := 0
	if duplicate:
		refunded = int(_refund_table().get(String(roll["rarity"]), 0))
		if refunded > 0:
			profile.earn(ShopProfile.CREDITS, refunded)

	_unbox_count += 1
	if mine and _unbox_count == 1:
		push_warning("[ShopManager] 开箱在本机结算; 联机付费箱子必须由服务器代摇")

	if mine:
		EventBus.loot_box_opened.emit(box_id, rolled_id)
	return {
		"success": true, "reason": "", "box_id": box_id,
		"item_id": rolled_id, "rarity": String(roll["rarity"]),
		"pity": int(roll["pity"]), "by_pity": bool(roll["by_pity"]),
		"duplicate": duplicate, "refunded_credits": refunded,
		"spent": price, "currency": currency,
	}


func _box_fail(box_id: String, reason: String, pity: int) -> Dictionary:
	return {
		"success": false, "reason": reason, "box_id": box_id,
		"item_id": "", "rarity": "", "pity": pity, "by_pity": false,
		"duplicate": false, "refunded_credits": 0, "spent": 0, "currency": "",
	}


## 重复外观折算表。缺配置时按 0 处理(即不返还), 不猜一个默认值。
func _refund_table() -> Dictionary:
	var cc: Dictionary = SkinDatabase.get_currency_config()
	var t = cc.get("repeat_refund_credits", {})
	return t if t is Dictionary else {}


func _rarity_table() -> Dictionary:
	var t := {}
	for r in ["common", "rare", "epic", "legendary"]:
		var d: Dictionary = SkinDatabase.get_rarity(r)
		if not d.is_empty():
			t[r] = d
	return t


# ================================================================ 装备

func equip_cosmetic(slot: String, item_id: String) -> Dictionary:
	return equip_cosmetic_for(self_profile(), slot, item_id)


## 装备前必须真的拥有 —— 否则改改存档就能白穿别人的皮肤
func equip_cosmetic_for(profile: ShopProfile, slot: String, item_id: String) -> Dictionary:
	var mine := _is_self(profile)
	var r := profile.equip(slot, item_id)
	if not bool(r.get("ok", false)):
		return { "success": false, "reason": String(r.get("reason", "")),
			"slot": slot, "item_id": item_id }
	if mine:
		EventBus.cosmetic_equipped.emit(slot, item_id)
		loadout_changed.emit()
	return { "success": true, "reason": "", "slot": slot, "item_id": item_id }


func unequip_cosmetic(slot: String) -> Dictionary:
	return unequip_cosmetic_for(self_profile(), slot)


func unequip_cosmetic_for(profile: ShopProfile, slot: String) -> Dictionary:
	var mine := _is_self(profile)
	var prev := profile.loadout.get_equipped(slot)
	var r := profile.unequip(slot)
	if not bool(r.get("ok", false)):
		return { "success": false, "reason": String(r.get("reason", "")), "slot": slot }
	if mine:
		EventBus.cosmetic_unequipped.emit(slot)
		loadout_changed.emit()
	return { "success": true, "reason": "", "slot": slot, "item_id": prev }


# ================================================================ 服务器入口
## 供 NetworkManager 转发的三个服务端权威入口。统一带上调用者的 profile,
## 并且永远以 multiplayer.get_remote_sender_id() 反查出的身份为准 ——
## 客户端在参数里自报"我是谁"没有任何意义。

func server_purchase(sender_peer: int, entry_id: String, currency_type: String) -> Dictionary:
	return purchase_entry_for(_server_profile(sender_peer), entry_id, currency_type)


func server_unbox(sender_peer: int, box_id: String) -> Dictionary:
	return unbox_for(_server_profile(sender_peer), box_id)


func server_equip(sender_peer: int, slot: String, item_id: String) -> Dictionary:
	return equip_cosmetic_for(_server_profile(sender_peer), slot, item_id)


func server_unequip(sender_peer: int, slot: String) -> Dictionary:
	return unequip_cosmetic_for(_server_profile(sender_peer), slot)


func _server_profile(peer_id: int) -> ShopProfile:
	var p := profile_for(peer_id)
	if p == null:
		push_error("[ShopManager] peer %d 无法建立 profile" % peer_id)
	return p


## 某玩家当前装备快照, 供生成包下发给其他客户端
func cosmetic_snapshot_for(peer_id: int, stable_id: String = "") -> Dictionary:
	var p := profile_for(peer_id, stable_id)
	return {} if p == null else p.loadout.for_network()


## 玩家离开时丢弃缓存实例。存档已在磁盘上, 下次进来照样能读回。
## 缓存清不掉会让专用服务器的内存随历史玩家数单调增长。
func forget_profile(peer_id: int, stable_id: String = "") -> void:
	var key := stable_id if not stable_id.is_empty() else "peer_%d" % peer_id
	_profiles.erase(key)


func cached_profile_count() -> int:
	return _profiles.size()
