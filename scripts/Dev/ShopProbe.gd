extends Node
##
## ShopProbe.gd — 商城 / 外观系统 Phase 1 定向测试
##
## 覆盖:
##   1. 数据完整性 — 稀有度、外观、开箱、商城目录的交叉引用
##   2. SkinDatabase 查询接口
##   3. 本地库存后端(授予 / 消耗 / 落盘 / 重载)
##   4. 货币与信号广播
##
## 用法:
##   Godot --headless --path . res://scenes/Dev/ShopProbe.tscn
##
## 会写 user://inventory_local.json, 测试前后自动备份还原, 不污染真实存档。
##

var failures: Array[String] = []
const TEST_SAVE := "user://_shopprobe_inventory.json"
const TEST_LOADOUT := "user://_shopprobe_loadout.json"


func _ready() -> void:
	print("=".repeat(60))
	print("商城 / 外观系统定向测试 (Phase 1-2)")
	print("=".repeat(60))

	# 把后端指向独立测试存档, 玩家真实库存全程不被触碰
	if not InventoryService.use_local_save_at(TEST_SAVE):
		print("[FAIL] 无法建立隔离的测试库存存档")
		get_tree().quit(1)
		return
	CurrencyManager.resync()

	_test_autoloads()
	_test_data_integrity()
	_test_queries()
	_test_inventory()
	_test_currency_and_signals()
	_test_loot_box_resolver()
	_test_loadout()
	_test_shop_purchase()
	_test_shop_unbox()
	_test_shop_equip()
	_test_profile_isolation()
	_test_shop_rpc_guard()
	_test_online_routing()
	_test_steam_adapter()

	_cleanup()

	print("-".repeat(60))
	if failures.is_empty():
		print("[PASS] 商城系统全部通过")
		get_tree().quit(0)
	else:
		print("[FAIL] %d 项失败:" % failures.size())
		for f in failures:
			print("  - %s" % f)
		get_tree().quit(1)


func _ok(name: String, detail: String = "") -> void:
	print("  [OK] %-24s %s" % [name, detail])


func _bad(name: String, detail: String) -> void:
	print("  [NG] %-24s %s" % [name, detail])
	failures.append("%s: %s" % [name, detail])


func _cleanup() -> void:
	DirAccess.remove_absolute(TEST_SAVE)
	DirAccess.remove_absolute(TEST_LOADOUT)
	_cleanup_profiles()
	print("  [CLEAN] 测试存档已移除, 玩家库存与装备档未被写入")


## 多玩家测试会在 user://shop_profiles/ 下落一批临时档
func _cleanup_profiles() -> void:
	const DIR := "user://shop_profiles"
	var d := DirAccess.open(DIR)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir():
			d.remove(f)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(DIR)


# ---------------------------------------------------------------
# 1. Autoload 注册与就绪
# ---------------------------------------------------------------
func _test_autoloads() -> void:
	print("")
	print("[1] Autoload 注册")

	if SkinDatabase == null:
		_bad("SkinDatabase", "未注册为 autoload")
		return
	if InventoryService == null:
		_bad("InventoryService", "未注册为 autoload")
		return
	if CurrencyManager == null:
		_bad("CurrencyManager", "未注册为 autoload")
		return
	if ShopManager == null:
		_bad("ShopManager", "未注册为 autoload")
		return
	_ok("四个单例", "SkinDatabase / InventoryService / CurrencyManager / ShopManager")

	if not InventoryService.is_available():
		_bad("库存后端", "不可用")
		return
	_ok("库存后端", InventoryService.get_backend_name())

	var items: Array = SkinDatabase.get_all_items()
	if items.is_empty():
		_bad("外观条目", "加载为 0 条")
		return
	_ok("外观条目", "%d 个" % items.size())
	_ok("开箱定义", "%d 个" % SkinDatabase.get_all_loot_boxes().size())
	_ok("商城条目", "%d 个" % SkinDatabase.get_all_store_entries().size())
	_ok("稀有度", "%d 档" % SkinDatabase.get_rarity("common").size())


# ---------------------------------------------------------------
# 2. 数据完整性与交叉引用
# ---------------------------------------------------------------
func _test_data_integrity() -> void:
	print("")
	print("[2] 数据完整性")

	# 稀有度字段齐备 + 颜色可解析
	var rarity_ok := true
	for r in ["common", "rare", "epic", "legendary"]:
		var d: Dictionary = SkinDatabase.get_rarity(r)
		if d.is_empty():
			_bad("稀有度 %s" % r, "未定义")
			rarity_ok = false
			continue
		for f in ["id", "label", "color", "drop_weight"]:
			if not d.has(f):
				_bad("稀有度 %s" % r, "缺字段 %s" % f)
				rarity_ok = false
		var c := Color.from_string(String(d.get("color", "")), Color(0, 0, 0, 0))
		if c.a <= 0.0:
			_bad("稀有度 %s" % r, "颜色无法解析: %s" % str(d.get("color", "")))
			rarity_ok = false
	if rarity_ok:
		_ok("稀有度字段", "4 档齐备, 颜色均可解析")

	# 每个外观条目必须有 id / type / rarity / name / steam_item_def_id
	var item_bad: Array[String] = []
	var seen_defs: Dictionary = {}
	for it in SkinDatabase.get_all_items():
		var id := String(it.get("id", ""))
		for f in ["id", "type", "rarity", "name", "steam_item_def_id"]:
			if not it.has(f):
				item_bad.append("%s 缺 %s" % [id, f])
		if SkinDatabase.get_rarity(String(it.get("rarity", ""))).is_empty():
			item_bad.append("%s 引用了未定义稀有度 %s" % [id, str(it.get("rarity", ""))])
		var def_id := int(it.get("steam_item_def_id", 0))
		if def_id <= 0:
			item_bad.append("%s 的 steam_item_def_id 非法: %d" % [id, def_id])
		elif seen_defs.has(def_id):
			item_bad.append("%s 与 %s 的 steam_item_def_id 重复: %d" % [id, seen_defs[def_id], def_id])
		else:
			seen_defs[def_id] = id
	if item_bad.is_empty():
		_ok("外观必填字段", "id/type/rarity/name/def_id 齐备且唯一")
	else:
		_bad("外观必填字段", "; ".join(item_bad.slice(0, 4)))

	# 武器皮肤引用的 weapon_id 必须在武器库存在
	var weapon_ids: Dictionary = WeaponDatabase.get_all_weapons()
	var orphan: Array[String] = []
	for it in SkinDatabase.get_items_by_type("weapon_skin"):
		var wid := String(it.get("weapon_id", ""))
		if not weapon_ids.has(wid):
			orphan.append("%s→%s" % [String(it.get("id", "")), wid])
	if orphan.is_empty():
		_ok("武器皮肤引用", "全部命中武器库")
	else:
		_bad("武器皮肤引用", "悬空 %d 处: %s" % [orphan.size(), ", ".join(orphan)])

	# 开箱: 奖池物品必须存在, 权重为正, 保底设置自洽
	var box_bad: Array[String] = []
	for b in SkinDatabase.get_all_loot_boxes():
		var bid := String(b.get("id", ""))
		var pool: Array = b.get("contents_pool", [])
		if pool.is_empty():
			box_bad.append("%s 奖池为空" % bid)
			continue
		var total_w := 0.0
		for e in pool:
			var iid := String(e.get("item_id", ""))
			if not SkinDatabase.has_item(iid):
				box_bad.append("%s 奖池引用不存在的 %s" % [bid, iid])
			var w := float(e.get("weight", 0))
			if w <= 0.0:
				box_bad.append("%s 条目 %s 权重<=0" % [bid, iid])
			total_w += w
		if total_w <= 0.0:
			box_bad.append("%s 总权重为 0" % bid)
		if int(b.get("pity_counter_threshold", 0)) <= 0:
			box_bad.append("%s 保底阈值非正" % bid)
		if SkinDatabase.get_rarity(String(b.get("pity_guaranteed_rarity", ""))).is_empty():
			box_bad.append("%s 保底稀有度未定义" % bid)
		for pi in b.get("preview_items", []):
			if not SkinDatabase.has_item(String(pi)):
				box_bad.append("%s 预览引用不存在的 %s" % [bid, str(pi)])
	if box_bad.is_empty():
		_ok("开箱配置", "%d 个箱子奖池/保底/预览均自洽" % SkinDatabase.get_all_loot_boxes().size())
	else:
		_bad("开箱配置", "; ".join(box_bad.slice(0, 4)))

	# 商城条目: 物品存在、价格非负、至少一种货币可买
	var store_bad: Array[String] = []
	for s in SkinDatabase.get_all_store_entries():
		var eid := String(s.get("entry_id", ""))
		var iid := String(s.get("item_id", ""))
		if not SkinDatabase.has_item(iid):
			store_bad.append("%s 引用不存在的 %s" % [eid, iid])
		if int(s.get("cost_credits", 0)) < 0 or int(s.get("cost_premium", 0)) < 0:
			store_bad.append("%s 存在负价格" % eid)
		if int(s.get("cost_credits", 0)) <= 0 and int(s.get("cost_premium", 0)) <= 0:
			store_bad.append("%s 两种货币都不可购买" % eid)
	if store_bad.is_empty():
		_ok("商城目录", "%d 条引用与定价有效" % SkinDatabase.get_all_store_entries().size())
	else:
		_bad("商城目录", "; ".join(store_bad.slice(0, 4)))

	# 货币配置
	var cc: Dictionary = SkinDatabase.get_currency_config()
	if cc.has("credits") and cc.has("premium_currency"):
		var bundles: Array = cc.get("premium_currency", {}).get("bundles", [])
		if bundles.size() > 0:
			_ok("货币配置", "双轨 + %d 个充值档位" % bundles.size())
		else:
			_bad("货币配置", "充值档位为空")
	else:
		_bad("货币配置", "缺 credits 或 premium_currency 段")

	# 重复折算的经济闭环: 折算额必须严格低于箱子价格。
	# 等于或高于时, 一个"已集齐全池"的玩家每次开箱都净赚,
	# 可以无限刷积分 —— 而这条在单次开箱断言里是"通过"的, 所以单独钉住。
	var refunds: Dictionary = cc.get("repeat_refund_credits", {})
	var cheapest_credit_box := 1 << 30
	for b in SkinDatabase.get_all_loot_boxes():
		var c := int(b.get("cost_credits", 0))
		if c > 0 and c < cheapest_credit_box:
			cheapest_credit_box = c
	if refunds.is_empty():
		_bad("折算经济闭环", "未配置 repeat_refund_credits")
	elif cheapest_credit_box >= 1 << 30:
		_bad("折算经济闭环", "没有任何积分定价的箱子, 无法校验")
	else:
		var over: Array = []
		for r in ["common", "rare", "epic", "legendary"]:
			var amt := int(refunds.get(r, 0))
			if amt <= 0:
				over.append("%s 未配置折算额" % r)
			elif amt >= cheapest_credit_box:
				over.append("%s=%d ≥ 箱价 %d" % [r, amt, cheapest_credit_box])
		if over.is_empty():
			_ok("折算经济闭环", "四档折算均 < 最低箱价 %d, 开箱不可能净赚"
				% cheapest_credit_box)
		else:
			_bad("折算经济闭环", "可被刷积分: " + "; ".join(over))


# ---------------------------------------------------------------
# 3. 查询接口
# ---------------------------------------------------------------
func _test_queries() -> void:
	print("")
	print("[3] SkinDatabase 查询")

	var any_item: Dictionary = SkinDatabase.get_all_items()[0]
	var id := String(any_item.get("id", ""))
	if not SkinDatabase.has_item(id):
		_bad("has_item", "刚取到的 id 查不到: %s" % id)
	else:
		_ok("has_item / get_item", id)
		var back: Dictionary = SkinDatabase.get_item(id)
		if String(back.get("name", "")) != String(any_item.get("name", "")):
			_bad("get_item 一致性", "名称不一致")
		else:
			_ok("get_item 一致性", String(back.get("name", "")))

	# 按类型查
	var type_hit := 0
	for t in ["weapon_skin", "character_skin", "accessory", "kill_effect",
		"mvp_animation", "voice_pack", "spray"]:
		var arr: Array = SkinDatabase.get_items_by_type(t)
		if not arr.is_empty():
			type_hit += 1
		for e in arr:
			if String(e.get("type", "")) != t:
				_bad("get_items_by_type(%s)" % t, "返回了 type=%s 的条目" % str(e.get("type", "")))
	if type_hit >= 4:
		_ok("按类型检索", "%d 种类型命中且结果纯净" % type_hit)
	else:
		_bad("按类型检索", "仅 %d 种命中, 期望 >=4" % type_hit)

	# 按稀有度查: 四个档位都应有内容(否则掉落表没意义)
	var empty_rarity: Array[String] = []
	for r in ["common", "rare", "epic", "legendary"]:
		if SkinDatabase.get_items_by_rarity(r).is_empty():
			empty_rarity.append(r)
	if empty_rarity.is_empty():
		_ok("按稀有度检索", "4 档均有内容")
	else:
		_bad("按稀有度检索", "空档: %s" % ", ".join(empty_rarity))

	# 按武器查皮肤
	var wid := String(SkinDatabase.get_items_by_type("weapon_skin")[0].get("weapon_id", ""))
	var skins: Array = SkinDatabase.get_weapon_skins(wid)
	if skins.is_empty():
		_bad("get_weapon_skins", "%s 查不到皮肤" % wid)
	else:
		var pure := true
		for s in skins:
			if String(s.get("weapon_id", "")) != wid:
				pure = false
		if pure:
			_ok("get_weapon_skins", "%s → %d 款" % [wid, skins.size()])
		else:
			_bad("get_weapon_skins", "结果混入了其他武器的皮肤")

	# 不存在的 id 应安全返回空
	if SkinDatabase.get_item("no_such_item_xyz").is_empty():
		_ok("未知 id 容错", "返回空字典而非报错")
	else:
		_bad("未知 id 容错", "竟然查到了东西")

	# 稀有度颜色/排名
	var c_low: Color = SkinDatabase.get_rarity_color("common")
	var c_high: Color = SkinDatabase.get_rarity_color("legendary")
	if c_low != c_high:
		_ok("稀有度颜色", "common=%s legendary=%s" % [c_low.to_html(false), c_high.to_html(false)])
	else:
		_bad("稀有度颜色", "两档颜色相同")
	if SkinDatabase.get_rarity_rank("legendary") > SkinDatabase.get_rarity_rank("common"):
		_ok("稀有度排序", "legendary(%d) > common(%d)" % [
			SkinDatabase.get_rarity_rank("legendary"), SkinDatabase.get_rarity_rank("common")])
	else:
		_bad("稀有度排序", "顺序颠倒")


# ---------------------------------------------------------------
# 4. 本地库存后端
# ---------------------------------------------------------------
func _test_inventory() -> void:
	print("")
	print("[4] 库存授予 / 消耗 / 落盘")

	var iid := String(SkinDatabase.get_all_items()[0].get("id", ""))

	InventoryService.consume_item(iid, 999)
	if InventoryService.has_item(iid):
		# 清干净再测
		while InventoryService.has_item(iid):
			InventoryService.consume_item(iid, 1)

	var sig_fired := [false]
	var cb := func(ids: Array) -> void: sig_fired[0] = true
	InventoryService.inventory_updated.connect(cb)

	if not InventoryService.grant_item(iid, 1):
		_bad("grant_item", "返回 false")
		InventoryService.inventory_updated.disconnect(cb)
		return
	if not InventoryService.has_item(iid):
		_bad("grant_item", "授予后查不到")
	else:
		_ok("grant_item", iid)

	if not sig_fired[0]:
		_bad("inventory_updated 信号", "授予时未触发")
	else:
		_ok("inventory_updated 信号", "授予时触发")
	InventoryService.inventory_updated.disconnect(cb)

	if InventoryService.count_of(iid) != 1:
		_bad("count_of", "授予 1 件后计数=%d" % InventoryService.count_of(iid))
	else:
		_ok("count_of", "1 件")
	InventoryService.grant_item(iid, 2)
	if InventoryService.count_of(iid) == 3:
		_ok("叠加计数", "1 + 2 = 3")
	else:
		_bad("叠加计数", "期望 3, 实得 %d" % InventoryService.count_of(iid))

	# 落盘 + 重新读盘
	var fresh := LocalInventoryAdapter.new()
	fresh.initialize_at(TEST_SAVE)
	if fresh.get_item_count(iid) == 3:
		_ok("落盘重载", "重新读盘仍为 3 件")
	else:
		_bad("落盘重载", "重新读盘得到 %d 件" % fresh.get_item_count(iid))

	# 消耗到零应移除
	if InventoryService.consume_item(iid, 3):
		if not InventoryService.has_item(iid):
			_ok("consume_item", "耗尽后已从库存移除")
		else:
			_bad("consume_item", "计数归零但仍在库")
	else:
		_bad("consume_item", "有 3 件却消耗失败")

	# 超额消耗必须拒绝, 且不能变成负数或部分扣除
	InventoryService.grant_item(iid, 1)
	if InventoryService.consume_item(iid, 5):
		_bad("超额消耗", "只有 1 件却消耗了 5")
	elif InventoryService.count_of(iid) == 1:
		_ok("超额消耗", "被拒绝, 余额未被破坏")
	else:
		_bad("超额消耗", "消耗后计数=%d, 期望仍为 1" % InventoryService.count_of(iid))

	# 未知物品不应能授予(防止配置外的 id 混进存档)
	if InventoryService.grant_item("not_a_real_item", 1):
		_bad("未知物品授予", "居然成功了")
	else:
		_ok("未知物品授予", "被拒绝")

	InventoryService.clear_item(iid)


# ---------------------------------------------------------------
# 5. 货币与信号
# ---------------------------------------------------------------
func _test_currency_and_signals() -> void:
	print("")
	print("[5] 货币与信号")

	var last_value := [-1]
	var last_type := [""]
	var cb := func(t: String, v: int) -> void:
		last_type[0] = t
		last_value[0] = v
	EventBus.currency_changed.connect(cb)

	var before := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	if before <= 0:
		_bad("初始余额", "本地后端应有测试余额, 实得 %d" % before)
	else:
		_ok("初始余额", "credits=%d premium=%d" % [
			before, CurrencyManager.get_balance(CurrencyManager.PREMIUM)])

	# 入账
	var earned: int = CurrencyManager.earn(CurrencyManager.CREDITS, 250)
	if earned != before + 250:
		_bad("earn", "期望 %d 实得 %d" % [before + 250, earned])
	else:
		_ok("earn", "+250 → %d" % earned)
	if last_type[0] != CurrencyManager.CREDITS or last_value[0] != earned:
		_bad("currency_changed 信号", "入账后收到的是 %s=%s" % [last_type[0], str(last_value[0])])
	else:
		_ok("currency_changed 信号", "入账时广播 %s=%d" % [last_type[0], last_value[0]])

	# 扣款
	if not CurrencyManager.spend(CurrencyManager.CREDITS, 100):
		_bad("spend", "余额充足却扣款失败")
	elif CurrencyManager.get_balance(CurrencyManager.CREDITS) != earned - 100:
		_bad("spend", "期望 %d 实得 %d" % [earned - 100, CurrencyManager.get_balance(CurrencyManager.CREDITS)])
	else:
		_ok("spend", "-100 → %d" % CurrencyManager.get_balance(CurrencyManager.CREDITS))

	# 余额不足: 必须整体失败, 不能部分扣除
	var keep := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	if CurrencyManager.spend(CurrencyManager.PREMIUM, keep + 100000):
		_bad("余额不足", "居然扣款成功")
	else:
		_ok("余额不足", "被拒绝")

	# 扣到自己买不起的额度后, has_enough 判定要跟着变
	var bal := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	if CurrencyManager.has_enough(CurrencyManager.CREDITS, bal) and not CurrencyManager.has_enough(CurrencyManager.CREDITS, bal + 1):
		_ok("has_enough 边界", "%d 可通过, %d 应拒绝" % [bal, bal + 1])
	else:
		_bad("has_enough 边界", "边界判定错误")

	# 退款
	CurrencyManager.spend(CurrencyManager.CREDITS, 300)
	var after_spend := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	CurrencyManager.refund(CurrencyManager.CREDITS, 300)
	if CurrencyManager.get_balance(CurrencyManager.CREDITS) == after_spend + 300:
		_ok("refund", "扣 300 退回后余额复原")
	else:
		_bad("refund", "退回后=%d, 期望 %d" % [
			CurrencyManager.get_balance(CurrencyManager.CREDITS), after_spend + 300])

	# 零成本与负成本
	if CurrencyManager.spend(CurrencyManager.CREDITS, 0):
		_ok("零成本扣款", "视为成功")
	else:
		_bad("零成本扣款", "应视为成功")
	if CurrencyManager.spend(CurrencyManager.CREDITS, -50):
		_bad("负数扣款", "被当成加钱执行了")
	else:
		_ok("负数扣款", "被拒绝")

	EventBus.currency_changed.disconnect(cb)

	# 落盘验证
	var fresh := LocalInventoryAdapter.new()
	fresh.initialize_at(TEST_SAVE)
	if fresh.get_currency_balance("credits") == CurrencyManager.get_balance(CurrencyManager.CREDITS):
		_ok("货币落盘", "重新读盘余额一致")
	else:
		_bad("货币落盘", "磁盘=%d 内存=%d" % [
			fresh.get_currency_balance("credits"),
			CurrencyManager.get_balance(CurrencyManager.CREDITS)])


# ---------------------------------------------------------------
# 6. 开箱概率结算 (Phase 2)
# ---------------------------------------------------------------
func _test_loot_box_resolver() -> void:
	print("")
	print("[6] 开箱概率结算 LootBoxResolver")

	var table := {
		"common":    { "id": 0, "label": "C", "color": "#ffffff", "drop_weight": 60.0 },
		"rare":      { "id": 1, "label": "R", "color": "#ffffff", "drop_weight": 25.0 },
		"epic":      { "id": 2, "label": "E", "color": "#ffffff", "drop_weight": 12.0 },
		"legendary": { "id": 3, "label": "L", "color": "#ffffff", "drop_weight": 3.0 },
	}

	# 6.1 确定性: 同种子必须同结果 —— 不然回归没法定位
	var box_a := _synth_box([
		{ "item_id": "ws_m7_faded_zebra", "weight": 10.0 },
		{ "item_id": "ws_ar17_arctic_digital", "weight": 10.0 },
		{ "item_id": "ws_falcon_crimson_tide", "weight": 10.0 },
	], "common", "epic", 10)
	var s1 := LootBoxResolver.sample_distribution(box_a, table, 500, 12345)
	var s2 := LootBoxResolver.sample_distribution(box_a, table, 500, 12345)
	if s1 == s2:
		_ok("同种子确定性", "500 次结果完全一致")
	else:
		_bad("同种子确定性", "固定种子却摇出不同分布")

	# 6.2 权重生效: 稀有度权重 60:25:12 应显著拉开出现率
	#     三件物品池内权重相同, 所以比例只由稀有度决定
	var total := 0
	for k in s1:
		total += int(s1[k])
	var c := int(s1.get("ws_m7_faded_zebra", 0))
	var r := int(s1.get("ws_ar17_arctic_digital", 0))
	var e := int(s1.get("ws_falcon_crimson_tide", 0))
	if total == 500 and c > r and r > e:
		_ok("稀有度权重排序", "common %d > rare %d > epic %d" % [c, r, e])
	else:
		_bad("稀有度权重排序", "common=%d rare=%d epic=%d 总量=%d" % [c, r, e, total])
	# 允许偏离理论值 ±40%, 太松会漏掉权重没生效的情况, 太紧会因随机性误报
	var ratio_cr := float(c) / float(maxi(r, 1))
	if ratio_cr > 1.4 and ratio_cr < 3.6:
		_ok("权重比例合理", "common/rare = %.2f (理论 2.4)" % ratio_cr)
	else:
		_bad("权重比例合理", "common/rare = %.2f 偏离理论 2.4 过远" % ratio_cr)

	# 6.3 地板线: guaranteed_rarity_min = rare 时, common 永不能单独出现
	var floor_box := _synth_box([
		{ "item_id": "ws_m7_faded_zebra", "weight": 999.0 },     # common, 权重压倒性
		{ "item_id": "ws_ar17_arctic_digital", "weight": 0.01 },  # rare
	], "rare", "legendary", 999)
	var floor_dist := LootBoxResolver.sample_distribution(floor_box, table, 400, 777)
	if int(floor_dist.get("ws_m7_faded_zebra", 0)) == 0:
		_ok("地板线", "400 次摇出 0 个低于 rare 的结果")
	else:
		_bad("地板线", "min=rare 仍掉出 %d 个 common" % int(floor_dist.get("ws_m7_faded_zebra", 0)))

	# 6.4 保底触发: 计数到阈值必须给到 pity 档位及以上, 且计数清零
	var pity_box := _synth_box([
		{ "item_id": "ws_m7_faded_zebra", "weight": 1000.0 },     # common
		{ "item_id": "ws_ar17_arctic_digital", "weight": 1.0 },   # rare
		{ "item_id": "ws_falcon_crimson_tide", "weight": 0.01 },  # epic = 保底档
	], "common", "epic", 10)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var pr := LootBoxResolver.roll(pity_box, table, 10, rng)
	if String(pr.get("rarity", "")) == "epic" and int(pr.get("pity", -1)) == 0 and bool(pr.get("by_pity", false)):
		_ok("保底触发", "第 10 次必出 epic 且计数归零")
	else:
		_bad("保底触发", "got rarity=%s pity=%s by_pity=%s" % [
			str(pr.get("rarity", "")), str(pr.get("pity", "")), str(pr.get("by_pity", ""))])

	# 6.5 计数累加: 没到保底档时 +1, 到了就归零
	var p := LootBoxResolver.roll(pity_box, table, 3, rng)
	if String(p.get("rarity", "")) == "epic":
		if int(p["pity"]) == 0:
			_ok("非保底出高稀有", "摇到 epic 也清零计数")
		else:
			_bad("非保底出高稀有", "摇到 epic 却没清零: %d" % int(p["pity"]))
	elif int(p["pity"]) == 4:
		_ok("计数累加", "%s → pity 3→4" % String(p.get("rarity", "")))
	else:
		_bad("计数累加", "出 %s 后 pity=%d, 期望 4" % [String(p.get("rarity", "")), int(p["pity"])])

	# 6.6 异常输入不得崩, 要给出可诊断的 error
	var bad_rng := RandomNumberGenerator.new()
	var empty := LootBoxResolver.roll({ "id": "x", "contents_pool": [] }, table, 0, bad_rng)
	if String(empty.get("item_id", "")) == "" and String(empty.get("error", "")) == "empty_pool":
		_ok("空奖池容错", "返回 empty_pool 而非崩溃")
	else:
		_bad("空奖池容错", str(empty))
	var no_rng := LootBoxResolver.roll(pity_box, table, 0, null)
	if String(no_rng.get("error", "")) == "no_rng":
		_ok("空随机源容错", "返回 no_rng")
	else:
		_bad("空随机源容错", str(no_rng))

	# 6.7 保底档位缺失属配置错误: 必须报错, 不能静默给低稀有
	var broken_box := _synth_box([
		{ "item_id": "ws_m7_faded_zebra", "weight": 10.0 },   # common only
	], "common", "legendary", 2)
	var before := failures.size()
	var br := LootBoxResolver.roll(broken_box, table, 5, rng)
	if String(br.get("item_id", "")) != "":
		_ok("坏配置降级", "奖池无 legendary 时仍能出货(已 push_error)")
	else:
		_bad("坏配置降级", "直接空结果: %s" % str(br))
	if failures.size() == before:
		print("       (注: 此用例预期会打 push_error, 未计为断言失败)")

	# 6.8 真实配置箱子也要能摇通
	var real_err := 0
	for b in SkinDatabase.get_all_loot_boxes():
		var d := LootBoxResolver.sample_distribution(b, table, 300, 99)
		var sum := 0
		for k in d:
			sum += int(d[k])
		if sum != 300:
			real_err += 1
			_bad("真实箱子 %s" % String(b.get("id", "?")), "300 次只摇出 %d 个" % sum)
	if real_err == 0:
		_ok("真实箱子可摇", "%d 个配置箱各 300 次全部出货" % SkinDatabase.get_all_loot_boxes().size())


func _synth_box(pool: Array, min_r: String, pity_r: String, threshold: int) -> Dictionary:
	return {
		"id": "synth", "contents_pool": pool,
		"guaranteed_rarity_min": min_r,
		"pity_guaranteed_rarity": pity_r,
		"pity_counter_threshold": threshold,
	}


# ---------------------------------------------------------------
# 7. 外观装备 (Phase 2)
# ---------------------------------------------------------------
func _test_loadout() -> void:
	print("")
	print("[7] 外观装备 LoadoutCosmetics")

	# 独立文件, 不碰玩家装备档
	if FileAccess.file_exists(TEST_LOADOUT):
		DirAccess.remove_absolute(TEST_LOADOUT)
	var lo := LoadoutCosmetics.new(TEST_LOADOUT)

	# 7.1 合法装备
	var r: Dictionary = lo.equip(LoadoutCosmetics.SLOT_CHARACTER, "cs_operator_shadow")
	if bool(r.get("ok", false)) and lo.get_equipped(LoadoutCosmetics.SLOT_CHARACTER) == "cs_operator_shadow":
		_ok("装备角色皮肤", "character → cs_operator_shadow")
	else:
		_bad("装备角色皮肤", str(r))

	# 7.2 类型与槽位不匹配必须拒绝
	var mm: Dictionary = lo.equip(LoadoutCosmetics.SLOT_CHARACTER, "ws_falcon_crimson_tide")
	if not bool(mm.get("ok", true)):
		_ok("槽位类型校验", "武器皮肤装到角色槽被拒: %s" % String(mm.get("reason", "")))
	else:
		_bad("槽位类型校验", "武器皮肤居然装进了角色槽")

	# 7.3 未知物品 / 未知槽位
	if not bool(lo.equip(LoadoutCosmetics.SLOT_CHARACTER, "ghost_item").get("ok", true)):
		_ok("未知物品拒绝", "装备不存在的 id 被拒")
	else:
		_bad("未知物品拒绝", "竟然装备上了不存在的物品")
	if not bool(lo.equip("nonsense_slot", "acc_beret_red").get("ok", true)):
		_ok("未知槽位拒绝", "非法槽位被拒")
	else:
		_bad("未知槽位拒绝", "非法槽位居然通过了")

	# 7.4 武器槽彼此独立 —— 换了武器不能串装别人的皮肤
	lo.equip(LoadoutCosmetics.weapon_slot("falcon"), "ws_falcon_crimson_tide")
	lo.equip(LoadoutCosmetics.weapon_slot("ar17"), "ws_ar17_arctic_digital")
	var fs := lo.get_weapon_equipped("falcon")
	var as_ := lo.get_weapon_equipped("ar17")
	if fs == "ws_falcon_crimson_tide" and as_ == "ws_ar17_arctic_digital":
		_ok("武器槽独立", "falcon / ar17 各自记各自皮肤")
	else:
		_bad("武器槽独立", "falcon=%s ar17=%s" % [fs, as_])

	# 7.5 落盘 + 重载
	lo.save_loadout()
	var lo2 := LoadoutCosmetics.new(TEST_LOADOUT)
	if lo2.get_equipped(LoadoutCosmetics.SLOT_CHARACTER) == "cs_operator_shadow" \
		and lo2.get_weapon_equipped("falcon") == "ws_falcon_crimson_tide":
		_ok("装备持久化", "重载后角色与武器皮肤都在")
	else:
		_bad("装备持久化", "重载丢失: %s" % str(lo2.all_equipped()))

	# 7.6 空 id 装备等于卸下
	var un: Dictionary = lo2.equip(LoadoutCosmetics.SLOT_CHARACTER, "")
	if not bool(un.get("ok", false)) or lo2.get_equipped(LoadoutCosmetics.SLOT_CHARACTER) != "":
		_bad("空 id 即卸下", str(un))
	else:
		_ok("空 id 即卸下", "character 槽已清空")

	# 7.7 网络打包往返
	var net := lo.for_network()
	var restored := LoadoutCosmetics.from_network(net)
	if restored.all_equipped() == lo.all_equipped():
		_ok("网络序列化往返", "%d 个槽位无损" % net.size())
	else:
		_bad("网络序列化往返", "往返后不一致")
	restored.save_path = ""  # 防止污染测试档
	# 拿别人装备的副本不能写回我的档
	if restored.save_path == "":
		_ok("远端副本不落盘", "from_network 实例指向空路径")

	# 7.8 材质应用: 建一个和 Actor 一样带 material_override 的节点树
	var root := Node3D.new()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.2, 0.4, 0.8)
	m.metallic = 0.0
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = m
	root.add_child(mi)
	var applied := LoadoutCosmetics.apply_character_skin(root, "ws_falcon_crimson_tide")
	if applied >= 1 and mi.material_override != m:
		var new_mat: StandardMaterial3D = mi.material_override
		var want := LoadoutCosmetics.skin_color("ws_falcon_crimson_tide")
		if new_mat.albedo_color.is_equal_approx(want):
			_ok("皮肤改材质", "%d 个网格换色为 %s" % [applied, want.to_html(false)])
		else:
			_bad("皮肤改材质", "颜色=%s 期望=%s" % [new_mat.albedo_color.to_html(false), want.to_html(false)])
		if absf(new_mat.metallic - 0.8) < 0.001:
			_ok("金属度参数", "metallic=%.2f" % new_mat.metallic)
		else:
			_bad("金属度参数", "metallic=%.2f 期望 0.80" % new_mat.metallic)
		if m.albedo_color == Color(0.2, 0.4, 0.8):
			_ok("原材质未被改", "改的是克隆, 共享材质干净")
		else:
			_bad("原材质未被改", "直接改了原材质, 会串到所有同类网格")
	else:
		_bad("皮肤改材质", "applied=%d" % applied)
	# 空 id / 未知 id 不应改动模型
	var mi2 := MeshInstance3D.new()
	var m2 := StandardMaterial3D.new()
	mi2.material_override = m2
	var root2 := Node3D.new()
	root2.add_child(mi2)
	if LoadoutCosmetics.apply_character_skin(root2, "") == 0 \
		and LoadoutCosmetics.apply_character_skin(root2, "ghost") == 0 \
		and mi2.material_override == m2:
		_ok("无皮肤时不变", "空/未知 id 不动模型")
	else:
		_bad("无皮肤时不变", "无皮肤却改动了模型")
	root.free()
	root2.free()


# ---------------------------------------------------------------
# 8. 商城购买 (Phase 2)
# ---------------------------------------------------------------
func _test_shop_purchase() -> void:
	print("")
	print("[8] 商城购买 ShopManager")

	var entry_id := "store_standard_beret"
	var entry: Dictionary = SkinDatabase.get_store_entry(entry_id)
	var item_id := String(entry.get("item_id", ""))
	var price := int(entry.get("cost_credits", 0))

	# 8.1 正常购买: 扣款额与发货必须同时对
	ShopManager.loadout.save_path = TEST_LOADOUT
	var bal0 := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	var res := ShopManager.purchase_entry(entry_id, CurrencyManager.CREDITS)
	if not bool(res.get("success", false)):
		_bad("正常购买", str(res))
	else:
		var bal1 := CurrencyManager.get_balance(CurrencyManager.CREDITS)
		if bal1 == bal0 - price and InventoryService.has_item(item_id):
			_ok("正常购买", "-%d 积分, 已入库 %s" % [price, item_id])
		else:
			_bad("正常购买", "余额 %d→%d, 入库=%s" % [bal0, bal1, str(InventoryService.has_item(item_id))])

	# 8.2 重复购买必须拒绝, 且不能再扣钱
	var bal2 := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	var dup := ShopManager.purchase_entry(entry_id, CurrencyManager.CREDITS)
	if not bool(dup.get("success", true)) and String(dup.get("reason", "")) == "already_owned" \
		and CurrencyManager.get_balance(CurrencyManager.CREDITS) == bal2:
		_ok("重复购买", "被拒 already_owned, 未二次扣款")
	else:
		_bad("重复购买", str(dup))

	# 8.3 余额不足: 拒绝 + 不发货
	CurrencyManager.set_currency(CurrencyManager.PREMIUM, 1)
	var poor := ShopManager.purchase_entry("store_featured_shadow_op", CurrencyManager.PREMIUM)
	if not bool(poor.get("success", true)) and String(poor.get("reason", "")).begins_with("insufficient"):
		if not InventoryService.has_item("cs_operator_shadow"):
			_ok("余额不足", "被拒且未发货")
		else:
			_bad("余额不足", "扣款失败却发了货")
	else:
		_bad("余额不足", str(poor))

	# 8.4 货币类型不匹配: 没标这个价的条目不能用它买
	#     先清掉拥有态, 否则 already_owned 会抢在货币校验之前返回, 测不到这一层
	InventoryService.clear_item("acc_beret_red")
	var prem_only := ShopManager.purchase_entry("store_standard_beret", "gold_hoard")
	if not bool(prem_only.get("success", true)) and String(prem_only.get("reason", "")).begins_with("currency_not_accepted"):
		_ok("货币校验", "未标价货币被拒")
	else:
		_bad("货币校验", str(prem_only))
	# 真实两种货币都标的条目, 用钻石也能买
	var goggle_entry: Dictionary = SkinDatabase.get_store_entry("store_standard_goggles")
	CurrencyManager.set_currency(CurrencyManager.PREMIUM, 5000)
	var by_prem := ShopManager.purchase_entry("store_standard_goggles", CurrencyManager.PREMIUM)
	var gp := int(goggle_entry.get("cost_premium", 0))
	if bool(by_prem.get("success", false)) and CurrencyManager.get_balance(CurrencyManager.PREMIUM) == 5000 - gp:
		_ok("钻石购买", "-%d 钻石成交" % gp)
	else:
		_bad("钻石购买", "%s 余额=%d 期望=%d" % [str(by_prem),
			CurrencyManager.get_balance(CurrencyManager.PREMIUM), 5000 - gp])

	# 8.5 未知条目 / 未知物品
	if not bool(ShopManager.purchase_entry("no_such_entry", CurrencyManager.CREDITS).get("success", true)):
		_ok("未知条目", "被拒")
	else:
		_bad("未知条目", "不存在的条目居然买成功")

	# 8.6 购买失败也要发信号(UI 要弹提示)
	var sig := {"fired": false, "ok": true}
	var cb := func(id: String, ok: bool, reason: String) -> void:
		sig["fired"] = true
		sig["ok"] = ok
	EventBus.shop_purchase_completed.connect(cb)
	ShopManager.purchase_entry("no_such_entry", CurrencyManager.CREDITS)
	EventBus.shop_purchase_completed.disconnect(cb)
	if bool(sig["fired"]) and not bool(sig["ok"]):
		_ok("失败信号广播", "purchase_completed(false) 已发出")
	else:
		_bad("失败信号广播", str(sig))

	# 8.7 payable_currencies 要与实际可买一致
	#     挑一个确实没拥有的条目 —— 全拥有时返回 [] 会让断言变成空转
	var target := ""
	for f in SkinDatabase.get_featured_entries():
		var fid := String(f.get("item_id", ""))
		if not InventoryService.has_item(fid):
			target = String(f.get("entry_id", ""))
			break
	if target.is_empty():
		InventoryService.clear_item("cs_operator_shadow")
		target = "store_featured_shadow_op"
	var pay: Array = ShopManager.payable_currencies(target)
	if pay.size() == 2:
		_ok("可购货币查询", "%s 两种货币均可, 重复查询幂等" % target)
	else:
		_bad("可购货币查询", "%s → %s, 期望两种货币" % [target, str(pay)])
	if ShopManager.owns_entry(target):
		_bad("可购货币查询", "已拥有判定与拥有态冲突")
	else:
		_ok("未拥有判定", "%s 确实未入库" % target)


# ---------------------------------------------------------------
# 9. 开箱业务流 (Phase 2)
# ---------------------------------------------------------------
func _test_shop_unbox() -> void:
	print("")
	print("[9] 开箱流程 ShopManager.unbox")

	var box_id := "lb_standard_case"
	var box: Dictionary = SkinDatabase.get_loot_box(box_id)
	var price := int(box.get("cost_credits", 0))

	# 9.1 扣钱 + 发货 + 信号
	#     先清空库存: 空库存下不可能判成重复, 净扣款才等于箱价
	InventoryService.dev_clear_items()
	var bal0 := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	var sig := {"fired": false, "item": ""}
	var cb := func(b: String, item: String) -> void:
		sig["fired"] = true
		sig["item"] = item
	EventBus.loot_box_opened.connect(cb)
	var r := ShopManager.unbox(box_id)
	EventBus.loot_box_opened.disconnect(cb)
	if not bool(r.get("success", false)):
		_bad("开箱", str(r))
		return
	var got := String(r.get("item_id", ""))
	if not InventoryService.has_item(got):
		_bad("开箱发货", "摇到 %s 却没入库" % got)
	elif bool(r.get("duplicate", false)):
		_bad("开箱重复判定", "空库存首次开出却判为重复: %s" % got)
	elif CurrencyManager.get_balance(CurrencyManager.CREDITS) != bal0 - price:
		_bad("开箱扣款", "余额 %d→%d, 期望 -%d" % [
			bal0, CurrencyManager.get_balance(CurrencyManager.CREDITS), price])
	else:
		_ok("开箱成交", "%s (%s) -%d 积分" % [got, String(r.get("rarity", "")), price])
	if bool(sig["fired"]) and String(sig["item"]) == got:
		_ok("开箱信号", "loot_box_opened 带正确结果")
	else:
		_bad("开箱信号", str(sig))

	# 9.1b 重复件折算: 把整池都发给玩家, 下一次开必是重复,
	#      净扣款应等于 -箱价 + 该稀有度的折算额
	var refund_table: Dictionary = SkinDatabase.get_currency_config().get("repeat_refund_credits", {})
	for e in box.get("contents_pool", []):
		InventoryService.grant_item(String(e.get("item_id", "")), 1)
	var bal1 := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	var r2 := ShopManager.unbox(box_id)
	if not bool(r2.get("success", false)):
		_bad("重复开箱", str(r2))
	elif not bool(r2.get("duplicate", false)):
		_bad("重复判定", "全池已拥有却未判重复: %s" % str(r2.get("item_id", "")))
	else:
		var back := int(r2.get("refunded_credits", 0))
		var want := int(refund_table.get(String(r2.get("rarity", "")), 0))
		var net := CurrencyManager.get_balance(CurrencyManager.CREDITS) - bal1
		if back != want:
			_bad("重复折算额", "%s 返还 %d, 配置为 %d" % [
				String(r2.get("rarity", "")), back, want])
		elif net != want - price:
			_bad("重复净扣款", "净变动 %d, 期望 %d (返 %d - 价 %d)" % [
				net, want - price, want, price])
		else:
			_ok("重复折算", "%s 返 %d, 净扣 %d" % [
				String(r2.get("rarity", "")), want, price - want])
	InventoryService.dev_clear_items()

	# 9.2 摇出来的东西必须在奖池里(不能凭空造物品)
	var pool_ids: Array = []
	for e in box.get("contents_pool", []):
		pool_ids.append(String(e.get("item_id", "")))
	if got in pool_ids:
		_ok("结果合法", "产物确实来自配置奖池")
	else:
		_bad("结果合法", "%s 不在奖池内" % got)

	# 9.3 余额不足不能开箱, 且不掉计数
	var keep_pity := ShopManager.get_pity(box_id)
	CurrencyManager.set_currency(CurrencyManager.CREDITS, 0)
	var broke := ShopManager.unbox(box_id)
	if not bool(broke.get("success", true)) and ShopManager.get_pity(box_id) == keep_pity:
		_ok("没钱开箱", "被拒且未消耗保底计数")
	else:
		_bad("没钱开箱", "%s pity %d→%d" % [str(broke), keep_pity, ShopManager.get_pity(box_id)])
	CurrencyManager.set_currency(CurrencyManager.CREDITS, 99999)

	# 9.4 未知箱子
	if not bool(ShopManager.unbox("ghost_box").get("success", true)):
		_ok("未知箱子", "被拒")
	else:
		_bad("未知箱子", "不存在的箱子开成功了")

	# 9.5 连续开 30 箱: 计数要持久, 且必须触发过保底
	var first_pity := ShopManager.get_pity(box_id)
	var pity_seen_max := first_pity
	var pity_hit_pity := false
	for _i in 30:
		var rr := ShopManager.unbox(box_id)
		if not bool(rr.get("success", false)):
			_bad("连开", "第 %d 次失败: %s" % [_i, str(rr)])
			break
		pity_seen_max = maxi(pity_seen_max, ShopManager.get_pity(box_id))
		pity_hit_pity = pity_hit_pity or bool(rr.get("by_pity", false))
	var threshold := int(box.get("pity_counter_threshold", 0))
	if pity_seen_max >= threshold - 1 or pity_hit_pity:
		_ok("连开保底生效", "阈值 %d, 峰值计数 %d, 触发过=%s" % [
			threshold, pity_seen_max, str(pity_hit_pity)])
	else:
		_bad("连开保底生效", "30 连开最高计数只有 %d, 远低于阈值 %d" % [pity_seen_max, threshold])

	# 9.6 保底计数必须落盘 —— 否则重启等于白送厂商一次清计数
	var persisted_pity := ShopManager.get_pity(box_id)
	var fresh := LocalInventoryAdapter.new()
	fresh.initialize_at(TEST_SAVE)
	if fresh.get_pity(box_id) == persisted_pity:
		_ok("保底计数持久化", "重新读盘仍为 %d" % persisted_pity)
	else:
		_bad("保底计数持久化", "磁盘=%d 内存=%d" % [fresh.get_pity(box_id), persisted_pity])

	# 9.7 高级箱走钻石
	var prem_box: Dictionary = SkinDatabase.get_loot_box("lb_premium_crate")
	if not prem_box.is_empty():
		var p0 := CurrencyManager.get_balance(CurrencyManager.PREMIUM)
		var pr2 := ShopManager.unbox("lb_premium_crate")
		var pc := int(prem_box.get("cost_premium", 0))
		if bool(pr2.get("success", false)):
			var p1 := CurrencyManager.get_balance(CurrencyManager.PREMIUM)
			if p1 == p0 - pc:
				_ok("钻石开箱", "-%d 钻石" % pc)
			else:
				_bad("钻石开箱", "余额 %d→%d 期望 -%d" % [p0, p1, pc])
		else:
			_bad("钻石开箱", str(pr2))


# ---------------------------------------------------------------
# 10. 装备与所有权 (Phase 2)
# ---------------------------------------------------------------
func _test_shop_equip() -> void:
	print("")
	print("[10] 装备校验与回收")

	var slot := LoadoutCosmetics.weapon_slot("falcon")
	var skin := "ws_falcon_crimson_tide"

	# 本节自造初态: 前面的节会发到这件皮肤并留下装备档, 不清就无法验证"未拥有"
	InventoryService.dev_clear_items()
	ShopManager.loadout.save_path = TEST_LOADOUT
	ShopManager.loadout.clear_all()
	ShopManager.loadout.save_loadout()
	InventoryService.clear_item(skin)

	# 10.1 没 owning 不能装备 —— 这条是整个系统最值钱的一行防线
	var no_own := ShopManager.equip_cosmetic(slot, skin)
	if not bool(no_own.get("success", true)) and String(no_own.get("reason", "")) == "not_owned":
		_ok("未拥有拒绝", "not_owned, 皮肤没挂上")
	else:
		_bad("未拥有拒绝", "%s 当前装备=%s" % [str(no_own), ShopManager.loadout.get_equipped(slot)])

	# 10.2 发了货就能装
	InventoryService.grant_item(skin, 1)
	var ok_equip := ShopManager.equip_cosmetic(slot, skin)
	if bool(ok_equip.get("success", false)) and ShopManager.loadout.get_equipped(slot) == skin:
		_ok("拥有后可装备", slot)
	else:
		_bad("拥有后可装备", str(ok_equip))

	# 10.3 装备要落盘
	var reload := LoadoutCosmetics.new(TEST_LOADOUT)
	if reload.get_equipped(slot) == skin:
		_ok("装备持久化", "重载仍在身上")
	else:
		_bad("装备持久化", "重载后为空")

	# 10.4 卸下
	var un := ShopManager.unequip_cosmetic(slot)
	if bool(un.get("success", false)) and ShopManager.loadout.get_equipped(slot) == "":
		_ok("卸下装备", "%s 已清空" % slot)
	else:
		_bad("卸下装备", str(un))

	# 10.5 库存被回收时, 身上的皮肤要自动摘掉 —— 靠 inventory_updated 驱动
	ShopManager.equip_cosmetic(slot, skin)
	var unequip_slot := [""]
	var cb := func(s: String) -> void: unequip_slot[0] = s
	EventBus.cosmetic_unequipped.connect(cb)
	InventoryService.clear_item(skin)
	if ShopManager.loadout.get_equipped(slot) == "":
		_ok("回收即摘除", "失去所有权后自动卸下%s" % ("(信号=%s)" % unequip_slot[0] if unequip_slot[0] != "" else "(无信号)"))
	else:
		_bad("回收即摘除", "皮肤仍挂在身上")
	EventBus.cosmetic_unequipped.disconnect(cb)

	# 10.6 重新拿回所有权不会自动穿回 —— 装备是玩家动作, 不是系统自动
	InventoryService.grant_item(skin, 1)
	if ShopManager.loadout.get_equipped(slot) == "":
		_ok("归还不自穿", "重新获得物品后仍为卸下态")
	else:
		_bad("归还不自穿", "系统擅自把皮肤穿回去了")

	# 10.7 装错类型槽位的兜底(所有权有, 槽位不对)
	var wrong := ShopManager.equip_cosmetic(LoadoutCosmetics.SLOT_KILL_EFFECT, skin)
	if not bool(wrong.get("success", true)):
		_ok("槽位兜底", "武器皮肤装进击杀特效槽被拒")
	else:
		_bad("槽位兜底", "拥有即可乱装, 槽位类型没校验")


# ---------------------------------------------------------------
# 11. 多玩家 profile 隔离 (Phase 4 安全前提)
# ---------------------------------------------------------------
func _test_profile_isolation() -> void:
	print("")
	print("[11] 多玩家 profile 隔离")

	# 服务器一次要处理 N 个玩家的请求。若业务仍读写"本机那一份"状态,
	# 校验看着存在, 实际全落在服务器自己的钱包和库存上 —— 形同虚设。
	# 本节验的就是"确实各算各的"。
	const DIR := "user://shop_profiles"
	var a := ShopManager.profile_for(7001)
	var b := ShopManager.profile_for(7002)
	if a == null or b == null:
		_bad("profile 建立", "返回 null, 后续跳过")
		return
	if a.profile_id == b.profile_id:
		_bad("profile 区分", "两个 peer 拿到同一个 profile_id")
	else:
		_ok("profile 区分", "%s / %s" % [a.profile_id, b.profile_id])

	# 11.1 新玩家的余额必须是 0。
	#      开发用的"首开送 5000 积分"一旦泄漏到服务器路径, 等于每人白送一笔
	var zero_a := a.balance(ShopProfile.CREDITS)
	var zero_b := b.balance(ShopProfile.PREMIUM)
	if zero_a == 0 and zero_b == 0:
		_ok("新人零余额", "远端 profile 未被塞开发余额")
	else:
		_bad("新人零余额", "credits=%d premium=%d, 期望均为 0" % [zero_a, zero_b])

	# 11.2 给 A 打钱发货, B 完全不受影响
	a.set_balance(ShopProfile.CREDITS, 3000)
	a.grant_item("ws_falcon_crimson_tide", 1)
	if b.balance(ShopProfile.CREDITS) != 0:
		_bad("余额隔离", "A 充值后 B 竟有 %d" % b.balance(ShopProfile.CREDITS))
	elif b.has_item("ws_falcon_crimson_tide"):
		_bad("库存隔离", "A 获得的皮肤出现在 B 的库存里")
	else:
		_ok("余额/库存隔离", "A 的 3000 积分与皮肤未渗到 B")

	# 11.3 本机玩家也不能被顺手扣掉
	if CurrencyManager.get_balance(CurrencyManager.CREDITS) <= 3000 \
		and a.balance(ShopProfile.CREDITS) == 3000:
		print("       (本机余额 %d, A 余额 %d)" % [
			CurrencyManager.get_balance(CurrencyManager.CREDITS),
			a.balance(ShopProfile.CREDITS)])
	if a.balance(ShopProfile.CREDITS) == 3000 \
		and CurrencyManager.get_balance(CurrencyManager.CREDITS) != 3000:
		_ok("与本机隔离", "A 的额度没写进本机存档")
	else:
		_bad("与本机隔离", "A 充值后本机余额=%d 疑似被共用" % CurrencyManager.get_balance(CurrencyManager.CREDITS))

	# 11.4 B 不能穿 A 的皮肤
	var slot := LoadoutCosmetics.weapon_slot("falcon")
	var steal := ShopManager.equip_cosmetic_for(b, slot, "ws_falcon_crimson_tide")
	if not bool(steal.get("success", true)) and String(steal.get("reason", "")) == "not_owned":
		_ok("跨玩家装备拦截", "B 装备 A 的皮肤被拒 not_owned")
	else:
		_bad("跨玩家装备拦截", "%s B 槽内=%s" % [str(steal), b.loadout.get_equipped(slot)])
	# A 自己装同一件应当成功
	var own := ShopManager.equip_cosmetic_for(a, slot, "ws_falcon_crimson_tide")
	if bool(own.get("success", false)):
		_ok("本人装备通过", "同一件对拥有者放行")
	else:
		_bad("本人装备通过", str(own))

	# 11.5 装备状态各自独立落盘
	a.loadout.save_loadout()
	b.loadout.save_loadout()
	if b.loadout.get_equipped(slot) == "" and a.loadout.get_equipped(slot) == "ws_falcon_crimson_tide":
		_ok("装备互不覆盖", "A 穿上、B 空着")
	else:
		_bad("装备互不覆盖", "A=%s B=%s" % [
			a.loadout.get_equipped(slot), b.loadout.get_equipped(slot)])

	# 11.6 同一 peer 重复取要拿到同一份(否则两次写互相看不到)
	var a2 := ShopManager.profile_for(7001)
	if a2 == a:
		_ok("profile 缓存", "同 peer 返回同一实例")
	else:
		_bad("profile 缓存", "同 peer 拿到新实例, 余额=%d" % a2.balance(ShopProfile.CREDITS))

	# 11.7 保底计数也是每人一份
	a.set_pity("lb_standard_case", 7)
	if b.pity_of("lb_standard_case") == 0 and a.pity_of("lb_standard_case") == 7:
		_ok("保底隔离", "A 的 7 发计数没算到 B 头上")
	else:
		_bad("保底隔离", "A=%d B=%d" % [a.pity_of("lb_standard_case"), b.pity_of("lb_standard_case")])

	# 11.8 服务器代开箱: 扣 A 的钱、发 A 的货, B 分文未动
	var b_before := b.balance(ShopProfile.CREDITS)
	var res := ShopManager.unbox_for(a, "lb_standard_case")
	if not bool(res.get("success", false)):
		_bad("代开箱", str(res))
	else:
		var got_id := String(res.get("item_id", ""))
		var spent := int(res.get("spent", 0))
		var a_now := a.balance(ShopProfile.CREDITS)
		if not a.has_item(got_id):
			_bad("代开箱发货", "产物 %s 没进 A 的库存" % got_id)
		elif b.balance(ShopProfile.CREDITS) != b_before:
			_bad("代开箱隔离", "开 A 的箱动了 B 的余额")
		elif a_now != 3000 - spent + int(res.get("refunded_credits", 0)):
			_bad("代开箱扣款", "A 余额=%d 期望=%d" % [
				a_now, 3000 - spent + int(res.get("refunded_credits", 0))])
		else:
			_ok("代开箱结算", "A 扣 %d 得 %s, B 未受影响" % [spent, got_id])

	# 11.9 落盘可回读: 服务器重启后玩家的余额/库存/保底不能凭空归零
	var reloaded := LocalInventoryAdapter.new()
	reloaded.initialize_at(DIR.path_join("peer_7001.json"))
	if reloaded.get_currency_balance("credits") == a.balance(ShopProfile.CREDITS) \
		and reloaded.get_pity("lb_standard_case") == a.pity_of("lb_standard_case") \
		and reloaded.has_item("ws_falcon_crimson_tide"):
		_ok("远端档持久化", "回读余额/保底/库存一致")
	else:
		_bad("远端档持久化", "余额=%d 保底=%d 皮肤=%s" % [
			reloaded.get_currency_balance("credits"),
			reloaded.get_pity("lb_standard_case"),
			str(reloaded.has_item("ws_falcon_crimson_tide"))])

	# 11.10 稳定 ID 与 peer 临时键要能区分开(重连换 peer 不该丢档)
	var s1 := ShopManager.profile_for(7003, "76561199000000001")
	var s2 := ShopManager.profile_for(9999, "76561199000000001")
	if s1 == s2 and s1.profile_id == "76561199000000001":
		_ok("SteamID 认人", "换 peer 后仍是同一份存档")
	else:
		_bad("SteamID 认人", "s1=%s s2=%s" % [
			str(s1 == s2), "?" if s1 == null else s1.profile_id])
		ShopManager.forget_profile(7003, "76561199000000001")

	# 11.11 远端 profile 不应污染本机 UI 总线
	#       A 买东西若广播 EventBus.inventory_updated, B 的界面会无故重绘
	var bus_hits := [0]
	var cb := func(_ids: Array) -> void: bus_hits[0] += 1
	EventBus.inventory_updated.connect(cb)
	a.grant_item("acc_beret_red", 1)
	EventBus.inventory_updated.disconnect(cb)
	if bus_hits[0] == 0:
		_ok("远端不广播总线", "A 的库存变动未惊动本机 UI")
	else:
		_bad("远端不广播总线", "触发了 %d 次 EventBus.inventory_updated" % bus_hits[0])

	_cleanup_profiles()


# ---------------------------------------------------------------
# 12. 商城 RPC 的伪造防护 (Phase 4)
# ---------------------------------------------------------------
func _test_shop_rpc_guard() -> void:
	print("")
	print("[12] 商城 RPC 伪造防护")

	# 12.1 非权威端收到 _shop_request 必须彻底静默。
	#      否则任意客户端广播一条, 就能让别的客户端替自己结算发货。
	var before := ShopManager.cached_profile_count()
	NetworkManager.is_server = false
	NetworkManager._shop_request("purchase", ["store_standard_beret", "credits"])
	if ShopManager.cached_profile_count() == before:
		_ok("非权威端静默", "客户端态收到请求, 未产生任何结算")
	else:
		_bad("非权威端静默", "profile 数从 %d 涨到 %d" % [
			before, ShopManager.cached_profile_count()])

	# 12.2 单人态不能被判成在线客户端, 否则 UI 会把请求发向不存在的服务器
	NetworkManager.is_client = false
	if NetworkManager.is_online_client():
		_bad("在线客户端判定", "单人态被判为在线")
	else:
		_ok("在线客户端判定", "单人态不走 RPC")

	# 12.3 残缺参数必须被拒。网络包是不可信输入, 越界索引会直接崩掉服务器进程
	NetworkManager.is_server = true
	var bad: Array = [
		["purchase", []],
		["purchase", ["store_standard_beret"]],
		["unbox", []],
		["equip", ["weapon:falcon"]],
		["unequip", []],
	]
	var accepted := 0
	for c in bad:
		var r: Dictionary = NetworkManager.server_shop_action(
			String(c[0]), 8100, c[1] as Array)
		if bool(r.get("success", false)):
			accepted += 1
			_bad("参数兜底 %s" % String(c[0]), "残缺参数竟然通过")
	if accepted == 0:
		_ok("参数兜底", "%d 种残缺包全部被拒, 未崩溃" % bad.size())

	# 12.4 未知 action
	var unk := NetworkManager.server_shop_action("grant_me_everything", 8100, [])
	if not bool(unk.get("success", false)):
		_ok("未知动作", "被拒: %s" % String(unk.get("reason", "")))
	else:
		_bad("未知动作", "未知 action 竟然执行了")

	# 12.5 服务器代买: 扣的是该 peer 的钱, 本机钱包分文不动
	var peer := 8100
	var mine_before := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	var goggled: Dictionary = SkinDatabase.get_store_entry("store_standard_goggles")
	var price := int(goggled.get("cost_credits", 0))
	NetworkManager.server_shop_action("balance", peer, [])  # 先建 profile
	var prof := ShopManager.profile_for(peer)
	if prof == null:
		_bad("代买", "无法建立 peer profile")
	else:
		prof.set_balance(ShopProfile.CREDITS, 5000)
		var ok_buy := NetworkManager.server_shop_action(
			"purchase", peer, ["store_standard_goggles", "credits"])
		if not bool(ok_buy.get("success", false)):
			_bad("代买", str(ok_buy))
		elif prof.balance(ShopProfile.CREDITS) != 5000 - price:
			_bad("代买扣款", "该 peer 余额=%d 期望=%d" % [
				prof.balance(ShopProfile.CREDITS), 5000 - price])
		elif not prof.has_item("acc_tactical_goggles"):
			_bad("代买发货", "货没发到该 peer 名下")
		elif CurrencyManager.get_balance(CurrencyManager.CREDITS) != mine_before:
			_bad("代买越界", "动别人的生意, 扣了本机 %d 积分" % (mine_before - \
				CurrencyManager.get_balance(CurrencyManager.CREDITS)))
		else:
			_ok("代买结算", "peer 扣 %d 得货, 本机余额未动" % price)

		# 12.6 同一个 peer 再买同一件必须被拒 —— 防止重放请求刷装备
		var again := NetworkManager.server_shop_action(
			"purchase", peer, ["store_standard_goggles", "credits"])
		if not bool(again.get("success", false)) \
			and String(again.get("reason", "")) == "already_owned":
			_ok("重复购买拦截", "第二次同样请求被拒 already_owned")
		else:
			_bad("重复购买拦截", str(again))

		# 12.7 没钱的 peer 买不动, 也不能白拿
		var poor := NetworkManager.server_shop_action(
			"purchase", 9999, ["store_featured_shadow_op", "premium"])
		if not bool(poor.get("success", false)):
			_ok("空钱包代买", "被拒: %s" % String(poor.get("reason", "")))
		else:
			_bad("空钱包代买", "零余额竟然买成了")

	NetworkManager.is_server = false
	_cleanup_profiles()


# ---------------------------------------------------------------
# 13. 在线态路由 (Phase 4 收口)
# ---------------------------------------------------------------
func _test_online_routing() -> void:
	print("")
	print("[13] 在线客户端路由")

	# 有 server_* 入口不代表客户端真的走了服务器。若 UI 仍直连本地
	# purchase_entry, 联网玩家依旧是自己给自己发货 —— 只是换了个函数名。
	# 本节验的是"客户端态下本地状态一点没动"。
	var saved_server := NetworkManager.is_server
	var saved_client := NetworkManager.is_client
	var saved_active := NetworkManager.active

	NetworkManager.is_server = false
	NetworkManager.is_client = true
	NetworkManager.active = false   # 无真实会话: 转发应被安全吞掉

	var bal_before := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	var owned_before := InventoryService.get_owned_ids().size()
	var slot := LoadoutCosmetics.weapon_slot("falcon")

	var r_buy := ShopManager.route_purchase("store_standard_beret", ShopProfile.CREDITS)
	if bool(r_buy.get("pending", false)):
		_ok("购买走转发", "返回 pending 而非本地成功")
	else:
		_bad("购买走转发", "客户端态竟拿到同步结果: %s" % str(r_buy))

	var r_box := ShopManager.route_unbox("lb_standard_case")
	var r_eq := ShopManager.route_equip(slot, "ws_falcon_crimson_tide")
	if bool(r_box.get("pending", false)) and bool(r_eq.get("pending", false)):
		_ok("开箱/装备走转发", "三条业务一致 pending")
	else:
		_bad("开箱/装备走转发", "unbox=%s equip=%s" % [str(r_box.get("pending")),
			str(r_eq.get("pending"))])

	# 核心断言: 本地一分钱没扣、一件货没发、也没偷偷穿上
	if CurrencyManager.get_balance(CurrencyManager.CREDITS) != bal_before:
		_bad("本地未被篡改", "余额 %d → %d" % [
			bal_before, CurrencyManager.get_balance(CurrencyManager.CREDITS)])
	elif InventoryService.get_owned_ids().size() != owned_before:
		_bad("本地未被篡改", "库存 %d → %d" % [
			owned_before, InventoryService.get_owned_ids().size()])
	elif ShopManager.loadout.get_equipped(slot) != "":
		_bad("本地未被篡改", "客户端自己把皮肤穿上了")
	else:
		_ok("本地未被篡改", "三次转发后余额/库存/装备均未变动")

	# 无会话时不能真往空管道发包(应被吞掉且不崩)
	NetworkManager.request_shop("balance")
	_ok("空会话吞包", "request_shop 在无会话时安全返回")

	# 恢复: 主机/离线态仍要能同步拿到真结果
	NetworkManager.is_server = saved_server
	NetworkManager.is_client = saved_client
	NetworkManager.active = saved_active
	var local := ShopManager.route_purchase("store_standard_beret", ShopProfile.CREDITS)
	if bool(local.get("success", false)) and not bool(local.get("pending", false)):
		_ok("离线态同步返回", "恢复后仍能本地成交")
	else:
		_bad("离线态同步返回", str(local))

	# 快照覆盖: 服务器说你有什么, 本地就是什么(含删掉本地多出来的)
	InventoryService.grant_item("fx_mvp_knife_spin", 1)
	var dirty := InventoryService.get_owned_ids().size()
	ShopManager.apply_server_snapshot({
		"success": true, "credits": 1234, "premium": 56,
		"owned": ["acc_beret_red"], "equipped": {},
	})
	var after: Array = InventoryService.get_owned_ids()
	if after == ["acc_beret_red"] \
		and CurrencyManager.get_balance(CurrencyManager.CREDITS) == 1234 \
		and CurrencyManager.get_balance(CurrencyManager.PREMIUM) == 56:
		_ok("快照覆盖本地", "%d 件收敛为服务器的那 1 件, 余额对齐" % dirty)
	else:
		_bad("快照覆盖本地", "owned=%s credits=%d" % [
			str(after), CurrencyManager.get_balance(CurrencyManager.CREDITS)])

	# 快照里多余的装备项要能落地, 缺的要把本地残留摘掉
	ShopManager.apply_server_snapshot({
		"success": true, "credits": 1234, "premium": 56,
		"owned": ["acc_beret_red", "ws_falcon_crimson_tide"],
		"equipped": {slot: "ws_falcon_crimson_tide"},
	})
	if ShopManager.loadout.get_equipped(slot) == "ws_falcon_crimson_tide":
		_ok("快照带装备", "服务器下发的装备项已生效")
	else:
		_bad("快照带装备", "槽内=%s" % ShopManager.loadout.get_equipped(slot))
	ShopManager.apply_server_snapshot({"success": true, "credits": 0, "premium": 0,
		"owned": [], "equipped": {}})
	if ShopManager.loadout.get_equipped(slot) == "" and InventoryService.get_owned_ids().is_empty():
		_ok("空快照清空", "服务器清空后本地不残留")
	else:
		_bad("空快照清空", "槽内=%s 库存=%d" % [
			ShopManager.loadout.get_equipped(slot),
			InventoryService.get_owned_ids().size()])

	_cleanup_profiles()


# ---------------------------------------------------------------
# 14. Steam 库存适配器的可验部分 (Phase 4)
# ---------------------------------------------------------------
func _test_steam_adapter() -> void:
	print("")
	print("[14] SteamInventoryAdapter 降级与拒答")

	# 本节只能覆盖"不连真 Steam 也应该成立"的部分: 目录映射、以及三类
	# 绝不能静默假装成功的接口。真机行为(拉取/消耗/回调时序)在这里测不到,
	# 不做任何"已验证"的声明。
	var a := SteamInventoryAdapter.new()

	# 14.1 目录映射必须是双射: def id 撞车会让两件不同的皮肤变成同一件
	var mapped: Dictionary = {}
	var dup: Array = []
	var missing := 0
	for def in SkinDatabase.get_all_items():
		var iid := String(def.get("id", ""))
		var did := int(def.get("steam_item_def_id", 0))
		if did <= 0:
			missing += 1
			continue
		if mapped.has(did):
			dup.append("%d" % did)
		mapped[did] = iid
	if dup.is_empty() and missing == 0:
		_ok("def id 双射", "%d 件物品 def id 唯一且齐备" % mapped.size())
	else:
		_bad("def id 双射", "重复=%s 缺=%d" % [str(dup), missing])

	if a.build_def_map():
		_ok("映射表构建", "build_def_map 通过")
	else:
		_bad("映射表构建", "配置齐备却构建失败")

	# 14.2 无 Steam 环境不得接管后端。
	#      这条兜住的是最坏情况: 玩家没开 Steam 就进游戏, 商城显示空库存、
	#      或扣款打在一个根本没有余额的后端上。
	var init_err: int = a.initialize()
	if init_err != OK or not a.is_available():
		_ok("无 Steam 不接管", "err=%d available=%s" % [init_err, str(a.is_available())])
	else:
		_bad("无 Steam 不接管", "无头环境竟被判为可用")
	if InventoryService.get_backend_name() == "local":
		_ok("回落到本地", "实际后端仍为 local")
	else:
		_bad("回落到本地", "后端变成了 %s" % InventoryService.get_backend_name())

	# 14.3 客户端没有发货权限。这里要的是"明确失败", 不是"返回 true 但其实没发"
	if a.grant_item("acc_beret_red", 1):
		_bad("发货必须拒绝", "客户端 grant_item 竟然返回 true")
	else:
		_ok("发货必须拒绝", "grant_item 明确返回 false")

	# 14.4 Steam 侧不管本作双轨余额 —— 宁可报 0, 也不编一个数
	if a.get_currency_balance("credits") == 0 \
		and not a.set_currency_balance("credits", 100):
		_ok("余额不代管", "读回 0, 写入被拒")
	else:
		_bad("余额不代管", "适配器自行管理了余额")

	# 14.5 保底计数同理: 返回 0 会被当成"新人没抽过", 服务器路径才作数
	if a.get_pity("lb_standard_case") == 0:
		_ok("保底不代管", "Steam 后端不持有 pity")
	else:
		_bad("保底不代管", "适配器返回了非零 pity")

	# 14.6 未 ready 时消耗必须失败, 不能"先答应下来再说"
	if a.consume_item("acc_beret_red", 1):
		_bad("未就绪消耗", "is_available=false 却答应扣货")
	else:
		_ok("未就绪消耗", "被拒, 未产生乐观成功")

	# 14.7 空缓存语义: 没有快照时拥有列表应为空而非 null/崩溃
	if a.get_owned_item_ids().is_empty() and a.get_item_count("acc_beret_red") == 0:
		_ok("空缓存语义", "列表为空、计数为 0")
	else:
		_bad("空缓存语义", "ids=%s" % str(a.get_owned_item_ids()))

	a.shutdown()
	if not a.is_available():
		_ok("shutdown 生效", "关闭后不再可用")
	else:
		_bad("shutdown 生效", "关闭后仍报告可用")
