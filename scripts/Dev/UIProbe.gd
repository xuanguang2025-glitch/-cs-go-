extends Node
##
## UIProbe.gd — 商城界面的结构与交互定向测试
##
## 无头环境不做真实渲染, 这里验的是"接线对不对":
##   节点树建全 / 页签与筛选真的改变列表 / 选中项驱动预览文本
##   动作按钮真的走到 ShopManager 并改变余额与库存 / 预览模型真的被改色
##
## 视觉表现(配色好不好看、排版会不会挤、3D 转得顺不顺)测不出来,
## 必须开编辑器实跑一遍。见报告里的"未验证项"。
##
## 用法:
##   Godot --headless --path . res://scenes/Dev/UIProbe.tscn
##

var failures: Array[String] = []
const TEST_SAVE := "user://_uiprobe_inventory.json"
const TEST_LOADOUT := "user://_uiprobe_loadout.json"
var _shop: ShopUI


func _ready() -> void:
	print("=".repeat(60))
	print("商城界面定向测试 (Phase 3)")
	print("=".repeat(60))

	if not InventoryService.use_local_save_at(TEST_SAVE):
		print("[FAIL] 无法建立隔离库存存档")
		get_tree().quit(1)
		return
	CurrencyManager.resync()
	ShopManager.loadout.save_path = TEST_LOADOUT
	ShopManager.loadout.clear_all()

	var scene: PackedScene = load("res://scenes/UI/ShopUI.tscn")
	if scene == null:
		print("[FAIL] 无法加载 ShopUI.tscn")
		get_tree().quit(1)
		return
	_shop = scene.instantiate()
	add_child(_shop)
	# _ready 里会连信号并建 UI; 等一帧让它跑完
	await get_tree().process_frame

	_test_structure()
	_test_tabs()
	_test_filters()
	# 这节内部要 await 帧让 queue_free 生效, 不 await 会让后续节与它抢状态
	await _test_selection_and_preview()
	# 这几节内部都 await 过帧, 调用方必须等它们跑完再走下一节
	await _test_store_action()
	await _test_inventory_action()
	await _test_unbox_action()
	await _test_live_refresh()
	await _test_mainmenu_entry()

	_cleanup()

	print("-".repeat(60))
	if failures.is_empty():
		print("[PASS] 商城界面全部通过")
		print("")
		print("  未验证: 实际渲染观感(配色/排版/3D 预览效果), 无头环境测不到")
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


## 直接触发真实控件信号, 而不是给生产类开"测试专用"接口 ——
## 走同一条信号链, 才测得到那条链本身有没有接上。
func _pick_type(i: int) -> void:
	_shop.type_option.select(i)
	_shop.type_option.item_selected.emit(i)


func _pick_rarity(i: int) -> void:
	_shop.rarity_option.select(i)
	_shop.rarity_option.item_selected.emit(i)


func _type_search(t: String) -> void:
	_shop.search_edit.text = t
	_shop.search_edit.text_changed.emit(t)


func _cleanup() -> void:
	InventoryService.dev_clear_items()
	ShopManager.loadout.clear_all()
	ShopManager.loadout.save_path = "user://cosmetic_loadout.json"
	DirAccess.remove_absolute(TEST_SAVE)
	DirAccess.remove_absolute(TEST_LOADOUT)
	print("  [CLEAN] 测试产物已移除")


# ---------------------------------------------------------------
func _test_structure() -> void:
	print("")
	print("[1] 节点树构建")

	if not _shop.is_built():
		_bad("is_built", "关键节点缺失, 后续全部跳过")
		return
	_ok("关键节点", "grid / preview / model_root 均存在")

	if _shop.visible:
		_bad("初始可见性", "构造完就显示了, 应默认隐藏")
	else:
		_ok("初始可见性", "默认隐藏")

	_shop.open_shop()
	if not _shop.visible:
		_bad("open_shop", "调用后仍不可见")
	else:
		_ok("open_shop", "已显示")

	# 预览视口必须是独立世界, 否则商城会把主菜单场景的灯光/相机搅进来
	var vp := _shop.preview_host.get_node_or_null("Viewport3D")
	if vp != null and vp.own_world_3d:
		_ok("预览独立世界", "own_world_3d=true")
	else:
		_bad("预览独立世界", "未启用独立 World3D")

	var cam := _shop.camera_rig.get_node_or_null("PreviewCamera") as Camera3D
	if cam != null and cam.current:
		_ok("预览相机", "已 current")
	else:
		_bad("预览相机", "相机未激活, 预览会是黑的")


# ---------------------------------------------------------------
func _test_tabs() -> void:
	print("")
	print("[2] 页签切换")

	_shop.activate_tab(ShopUI.TAB_STORE)
	var store_n := _shop.card_count()
	var store_expect: Array = []
	for e in SkinDatabase.get_all_store_entries():
		var item: Dictionary = SkinDatabase.get_item(String(e.get("item_id", "")))
		if not item.is_empty():
			store_expect.append(String(e.get("entry_id", "")))
	if store_n == store_expect.size() and store_n > 0:
		_ok("商店页签", "%d 张卡片 = 目录条目数" % store_n)
	else:
		_bad("商店页签", "卡片 %d, 目录 %d" % [store_n, store_expect.size()])

	_shop.activate_tab(ShopUI.TAB_INVENTORY)
	if _shop.card_count() == 0:
		_ok("仓库页签", "空库存时列表为空(不是残留商店项)")
	else:
		_bad("仓库页签", "空库存却有 %d 张卡片" % _shop.card_count())

	_shop.activate_tab(ShopUI.TAB_UNBOX)
	var boxes: Array = SkinDatabase.get_all_loot_boxes()
	if _shop.card_count() == boxes.size() and _shop.current_tab() == ShopUI.TAB_UNBOX:
		_ok("开箱页签", "%d 个箱子" % boxes.size())
	else:
		_bad("开箱页签", "卡片 %d, 箱子 %d" % [_shop.card_count(), boxes.size()])

	# 切页签不能串数据: 箱子页的 ref_id 必须是箱子 id
	var leaked := 0
	for id in _shop.card_ids():
		if SkinDatabase.get_loot_box(id).is_empty():
			leaked += 1
	if leaked == 0:
		_ok("页签数据隔离", "卡片全部来自当前页签数据源")
	else:
		_bad("页签数据隔离", "%d 张卡片不属于箱子页" % leaked)

	_shop.activate_tab(ShopUI.TAB_STORE)
	# 越界索引要夹住而不是崩
	_shop.activate_tab(99)
	if _shop.current_tab() == ShopUI.TAB_UNBOX:
		_ok("越界页签", "夹到最后一页而非崩溃")
	else:
		_bad("越界页签", "索引 99 得到 %d" % _shop.current_tab())
	_shop.activate_tab(ShopUI.TAB_STORE)


# ---------------------------------------------------------------
func _test_filters() -> void:
	print("")
	print("[3] 筛选")

	var total := _shop.card_count()
	# 类型筛选: 选"武器皮肤"(索引 1)
	_pick_type(1)
	var weapon_only := _shop.card_count()
	var real_weapon := 0
	for cid in _shop.card_ids():
		var e: Dictionary = SkinDatabase.get_store_entry(cid)
		var item: Dictionary = SkinDatabase.get_item(String(e.get("item_id", "")))
		if String(item.get("type", "")) == "weapon_skin":
			real_weapon += 1
	if weapon_only == real_weapon and weapon_only <= total:
		_ok("类型筛选", "武器皮肤 %d 项, 结果纯净" % weapon_only)
	else:
		_bad("类型筛选", "显示 %d, 实际武器皮肤 %d" % [weapon_only, real_weapon])

	_pick_type(0)
	# 稀有度筛选
	_pick_rarity(4)  # 传说
	var leg := _shop.card_count()
	var leg_real := 0
	for cid in _shop.card_ids():
		var e: Dictionary = SkinDatabase.get_store_entry(cid)
		var item: Dictionary = SkinDatabase.get_item(String(e.get("item_id", "")))
		if String(item.get("rarity", "")) == "legendary":
			leg_real += 1
	if leg == leg_real:
		_ok("稀有度筛选", "传说 %d 项" % leg)
	else:
		_bad("稀有度筛选", "显示 %d 实际 %d" % [leg, leg_real])
	_pick_rarity(0)

	# 搜索
	_type_search("zzz_不存在")
	if _shop.card_count() == 0:
		_ok("搜索无命中", "列表清空且未崩")
	else:
		_bad("搜索无命中", "仍有 %d 张卡片" % _shop.card_count())
	_type_search("crimson")
	var hits := _shop.card_count()
	if hits >= 1 and hits < total:
		_ok("搜索命中", "'crimson' → %d 项 (全量 %d)" % [hits, total])
	else:
		_bad("搜索命中", "'crimson' → %d 项, 全量 %d" % [hits, total])
	# 大小写不敏感
	_type_search("CRIMSON")
	if _shop.card_count() == hits:
		_ok("搜索忽略大小写", "CRIMSON 与 crimson 结果一致")
	else:
		_bad("搜索忽略大小写", "%d vs %d" % [_shop.card_count(), hits])
	_type_search("")
	if _shop.card_count() == total:
		_ok("清空搜索", "恢复 %d 项" % total)
	else:
		_bad("清空搜索", "恢复后 %d 项, 期望 %d" % [_shop.card_count(), total])


# ---------------------------------------------------------------
func _test_selection_and_preview() -> void:
	print("")
	print("[4] 选中与 3D 预览")

	var ids: Array = _shop.card_ids()
	if ids.is_empty():
		_bad("选中", "无卡片可选")
		return

	if not _shop.select_card(String(ids[0])):
		_bad("select_card", "第一张卡片选不中")
		return
	_ok("select_card", String(_shop.selected_id()))

	if _shop.preview_name.text.is_empty():
		_bad("预览标题", "为空")
	else:
		_ok("预览标题", _shop.preview_name.text)

	# 选一个不存在的 id 不应改变当前选中
	var before := _shop.selected_id()
	if not _shop.select_card("no_such_card") and _shop.selected_id() == before:
		_ok("无效选中容错", "保持原选中项")
	else:
		_bad("无效选中容错", "选中项被破坏了")

	# 找一个武器皮肤, 验预览模型真的被改色
	_pick_type(1)
	_type_search("")
	var weapon_entry := ""
	var weapon_skin := ""
	for cid in _shop.card_ids():
		var e: Dictionary = SkinDatabase.get_store_entry(cid)
		var item: Dictionary = SkinDatabase.get_item(String(e.get("item_id", "")))
		if not item.is_empty():
			weapon_entry = cid
			weapon_skin = String(item.get("id", ""))
			break
	if weapon_entry.is_empty():
		_bad("预览模型", "商店里没有武器皮肤")
		_pick_type(0)
		return
	_shop.select_card(weapon_entry)

	await get_tree().process_frame  # 让上一批模型节点真正 free 掉
	var parts := model_child_count()
	if parts > 0:
		_ok("预览模型搭建", "%d 个网格部件" % parts)
	else:
		_bad("预览模型搭建", "ModelRoot 是空的")

	var tinted := tinted_part_count(LoadoutCosmetics.skin_color(weapon_skin))
	if tinted >= 1:
		_ok("预览走实机路径", "%d 个部件被 apply_item_skin 改色" % tinted)
	else:
		_bad("预览走实机路径", "没有任何部件被改色, 预览与实机脱节")

	# 切到无皮肤条目时不应残留上一件的颜色
	_pick_type(0)
	_shop.activate_tab(ShopUI.TAB_UNBOX)
	await get_tree().process_frame
	var box_tinted := tinted_part_count(LoadoutCosmetics.skin_color(weapon_skin))
	if box_tinted == 0:
		_ok("预览无残留", "换页后模型未沿用旧皮肤色")
	else:
		_bad("预览无残留", "%d 个部件仍是旧皮肤颜色" % box_tinted)
	_shop.activate_tab(ShopUI.TAB_STORE)


func model_child_count() -> int:
	var n := 0
	for ch in _shop.model_root.get_children():
		if ch is MeshInstance3D:
			n += 1
	return n


func tinted_part_count(want: Color) -> int:
	var n := 0
	for ch in _shop.model_root.get_children():
		if ch is MeshInstance3D:
			var m := (ch as MeshInstance3D).material_override as StandardMaterial3D
			if m != null and m.albedo_color.is_equal_approx(want):
				n += 1
	return n


# ---------------------------------------------------------------
func _test_store_action() -> void:
	print("")
	print("[5] 商店动作按钮")

	_shop.activate_tab(ShopUI.TAB_STORE)
	_type_search("beret")
	_pick_type(3)  # 配件
	await get_tree().process_frame
	var entry := "store_standard_beret"
	if not _shop.select_card(entry):
		_bad("选中商店条目", "找不到 %s" % entry)
		return
	var item_id := String((SkinDatabase.get_store_entry(entry) as Dictionary).get("item_id", ""))
	InventoryService.clear_item(item_id)

	if _shop.action_button.disabled:
		_bad("动作按钮可用态", "买得起却禁用")
	else:
		_ok("动作按钮可用态", _shop.action_button.text)

	var price := int((SkinDatabase.get_store_entry(entry) as Dictionary).get("cost_credits", 0))
	var bal0 := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	var res := _shop.press_action()
	if not bool(res.get("success", false)):
		_bad("按钮触发购买", str(res))
	else:
		var bal1 := CurrencyManager.get_balance(CurrencyManager.CREDITS)
		if bal1 == bal0 - price and InventoryService.has_item(item_id):
			_ok("按钮触发购买", "-%d 积分并入库" % price)
		else:
			_bad("按钮触发购买", "余额 %d→%d 入库=%s" % [
				bal0, bal1, str(InventoryService.has_item(item_id))])

	# 已拥有后按钮要变成不可点的"已拥有", 不能重复扣钱
	await get_tree().process_frame
	_shop.activate_tab(ShopUI.TAB_STORE)
	_type_search("beret")
	_pick_type(3)
	await get_tree().process_frame
	if _shop.select_card(entry):
		var bal2 := CurrencyManager.get_balance(CurrencyManager.CREDITS)
		if _shop.action_button.disabled and _shop.action_button.text.contains("已拥有"):
			_ok("已拥有态按钮", "禁用且文案正确")
		else:
			_bad("已拥有态按钮", "disabled=%s text=%s" % [
				str(_shop.action_button.disabled), _shop.action_button.text])
		var r2 := _shop.press_action()
		if r2.is_empty() or not bool(r2.get("success", true)):
			_ok("重复购买拦截", "按钮层就挡住了")
		else:
			_bad("重复购买拦截", "又买了一次: %s" % str(r2))
		if CurrencyManager.get_balance(CurrencyManager.CREDITS) != bal2:
			_bad("重复购买拦截", "余额被二次扣除")

	_pick_type(0)
	_type_search("")


# ---------------------------------------------------------------
func _test_inventory_action() -> void:
	print("")
	print("[6] 仓库装备按钮")

	_shop.activate_tab(ShopUI.TAB_INVENTORY)
	await get_tree().process_frame
	if _shop.card_count() == 0:
		_bad("仓库列表", "上一节买的东西没出现")
		return
	_ok("仓库列表", "%d 件" % _shop.card_count())

	var target := ""
	for cid in _shop.card_ids():
		var item: Dictionary = SkinDatabase.get_item(cid)
		if String(item.get("type", "")) == "weapon_skin":
			target = cid
			break
	if target.is_empty():
		# 仓库里只装了贝雷帽(无装备槽), 补一件武器皮肤进来再测
		InventoryService.grant_item("ws_falcon_crimson_tide", 1)
		_shop.activate_tab(ShopUI.TAB_STORE)
		_shop.activate_tab(ShopUI.TAB_INVENTORY)
		await get_tree().process_frame
		target = "ws_falcon_crimson_tide"
	_ok("测试件就绪", target)

	if not _shop.select_card(target):
		_bad("选中仓库件", target)
		return
	var slot := ShopUI.slot_for_item(SkinDatabase.get_item(target))
	InventoryService.clear_item(target)
	InventoryService.grant_item(target, 1)
	_shop.activate_tab(ShopUI.TAB_STORE)
	_shop.activate_tab(ShopUI.TAB_INVENTORY)
	await get_tree().process_frame
	if not _shop.select_card(target):
		_bad("选中仓库件", "刷新后选不中")
		return

	if _shop.action_button.disabled:
		_bad("装备按钮", "拥有却禁用")
		return
	var eq := _shop.press_action()
	if bool(eq.get("success", false)) and ShopManager.loadout.get_equipped(slot) == target:
		_ok("按钮触发装备", "%s → %s" % [slot, target])
	else:
		_bad("按钮触发装备", "%s 槽内=%s" % [str(eq), ShopManager.loadout.get_equipped(slot)])

	# 装备后按钮应翻成"卸下"
	await get_tree().process_frame
	_shop.activate_tab(ShopUI.TAB_STORE)
	_shop.activate_tab(ShopUI.TAB_INVENTORY)
	await get_tree().process_frame
	_shop.select_card(target)
	if _shop.action_button.text.contains("卸"):
		_ok("按钮文案翻转", _shop.action_button.text)
	else:
		_bad("按钮文案翻转", "仍是 %s" % _shop.action_button.text)
	var un := _shop.press_action()
	if bool(un.get("success", false)) and ShopManager.loadout.get_equipped(slot) == "":
		_ok("按钮触发卸下", slot)
	else:
		_bad("按钮触发卸下", str(un))


# ---------------------------------------------------------------
func _test_unbox_action() -> void:
	print("")
	print("[7] 开箱按钮与揭示层")

	_shop.activate_tab(ShopUI.TAB_UNBOX)
	await get_tree().process_frame
	if _shop.card_count() == 0:
		_bad("箱子列表", "为空")
		return
	var box_id := String(_shop.card_ids()[0])
	_shop.select_card(box_id)
	if _shop.action_button.disabled:
		_bad("开箱按钮", "有钱却禁用")
		return
	if not _shop.reveal_layer.visible:
		_ok("揭示层初始", "未打开")
	else:
		_bad("揭示层初始", "还没开箱就显示了")

	var r := _shop.press_action()
	if not bool(r.get("success", false)):
		_bad("按钮触发开箱", str(r))
		return
	_ok("按钮触发开箱", "%s (%s)" % [String(r.get("item_id", "")), String(r.get("rarity", ""))])

	if not _shop.reveal_layer.visible:
		_bad("揭示层弹出", "开箱成功却没弹")
	else:
		_ok("揭示层弹出", _shop.reveal_title.text)

	# 揭示层要能被关掉, 关不掉会把玩家锁死在弹窗里
	# (运行时 new() 出来的中间节点名带 @ 前缀, 所以按名字找而不是写死路径)
	var close_btn := _shop.reveal_layer.find_child("RevealClose", true, false) as Button
	if close_btn == null:
		_bad("揭示关闭按钮", "找不到节点")
	else:
		close_btn.pressed.emit()
		if not _shop.reveal_layer.visible:
			_ok("揭示层关闭", "按钮可关闭")
		else:
			_bad("揭示层关闭", "关不掉")

	# 重复开出已拥有件时应折算积分。
	# 必须先把整池发一遍: 只发一件的话开箱大概率摇到别的, 这条断言就变成
	# 偶尔跳过 —— 断言总数随 RNG 漂移, 文档里写的数字下次复跑就对不上。
	var box_full: Dictionary = SkinDatabase.get_loot_box(box_id)
	for e in box_full.get("contents_pool", []):
		InventoryService.grant_item(String(e.get("item_id", "")), 1)
	var bal_before := CurrencyManager.get_balance(CurrencyManager.CREDITS)
	var dup := ShopManager.unbox(box_id)
	if not bool(dup.get("success", false)):
		_bad("重复开箱", str(dup))
	elif not bool(dup.get("duplicate", false)):
		_bad("重复判定", "全池已拥有却未判重复: %s" % str(dup.get("item_id", "")))
	else:
		var back := int(dup.get("refunded_credits", 0))
		var after := CurrencyManager.get_balance(CurrencyManager.CREDITS)
		var cost := int(box_full.get("cost_credits", 0))
		var refund: int = int((SkinDatabase.get_currency_config()
			.get("repeat_refund_credits", {}) as Dictionary)
			.get(String(dup.get("rarity", "")), 0))
		if back == refund and after == bal_before - cost + back:
			_ok("重复折算", "%s 返 %d, 净扣 %d" % [
				String(dup.get("rarity", "")), back, cost - back])
		else:
			_bad("重复折算", "返还=%d(配置 %d) 余额 %d→%d (箱价 %d)" % [
				back, refund, bal_before, after, cost])
	InventoryService.dev_clear_items()


# ---------------------------------------------------------------
func _test_live_refresh() -> void:
	print("")
	print("[8] 余额与列表实时刷新")

	_shop.activate_tab(ShopUI.TAB_STORE)
	CurrencyManager.earn(CurrencyManager.CREDITS, 1234)
	var shown := _shop.credit_text()
	if shown.contains(str(CurrencyManager.get_balance(CurrencyManager.CREDITS))):
		_ok("余额标签跟随信号", shown)
	else:
		_bad("余额标签跟随信号", "%s 与真实余额 %d 不符" % [
			shown, CurrencyManager.get_balance(CurrencyManager.CREDITS)])

	CurrencyManager.set_currency(CurrencyManager.PREMIUM, 777)
	if _shop.premium_text().contains("777"):
		_ok("钻石标签跟随", _shop.premium_text())
	else:
		_bad("钻石标签跟随", _shop.premium_text())

	# 库存变动要刷新列表
	_shop.activate_tab(ShopUI.TAB_INVENTORY)
	# 先清掉: 已拥有的件再授予不会新增一行, 断言会变成空转
	InventoryService.clear_item("acc_spray_stripe_logo")
	await get_tree().process_frame
	var n0 := _shop.card_count()
	InventoryService.grant_item("acc_spray_stripe_logo", 1)
	await get_tree().process_frame
	_shop.activate_tab(ShopUI.TAB_STORE)
	_shop.activate_tab(ShopUI.TAB_INVENTORY)
	if _shop.card_count() == n0 + 1:
		_ok("库存驱动列表", "%d → %d" % [n0, _shop.card_count()])
	else:
		_bad("库存驱动列表", "授予后 %d → %d 未刷新" % [n0, _shop.card_count()])

	_shop.close_shop()
	if _shop.visible:
		_bad("close_shop", "调用后仍可见")
	else:
		_ok("close_shop", "已隐藏")
	# 关店后 ESC 不该再被商城吃掉
	_shop.open_shop()
	await get_tree().process_frame
	if _shop.visible:
		_ok("重复开关", "可反复打开, 节点树未损坏")


# ---------------------------------------------------------------
func _test_mainmenu_entry() -> void:
	print("")
	print("[9] 主菜单入口接线")

	# 玩家是从主菜单点进来的, 这一段验的是"能不能走到商城", 前面各节都没覆盖到
	var menu_scene: PackedScene = load("res://scenes/Main.tscn")
	if menu_scene == null:
		_bad("主菜单场景", "无法加载 Main.tscn")
		return
	var menu := menu_scene.instantiate()
	add_child(menu)
	await get_tree().process_frame

	var btn := menu.find_child("ShopButton", true, false) as Button
	if btn == null:
		_bad("商城入口按钮", "主菜单里找不到 ShopButton")
		return
	if btn.text.contains("积分") or not btn.text.contains("件"):
		_bad("入口按钮文案", "未显示拥有数: %s" % btn.text)
	else:
		_ok("入口按钮文案", btn.text)

	# 点按钮 → 商城应作为覆盖层出现
	btn.pressed.emit()
	await get_tree().process_frame
	var overlay: ShopUI = null
	for ch in menu.get_children():
		if ch is ShopUI:
			overlay = ch
	if overlay == null:
		_bad("点按钮后", "没有实例化出 ShopUI")
		return
	if not overlay.visible:
		_bad("点按钮后", "ShopUI 已创建但不可见")
	else:
		_ok("点按钮开店", "覆盖层已显示")
	if not overlay.is_built():
		_bad("入口建的店", "节点树不完整")
	else:
		_ok("入口建的店", "grid / 预览 / 模型均在")

	# 拥有数变了, 按钮文案要跟着变(靠 inventory_updated 驱动)
	# 先确保这件没被前面的节发过 —— 按钮显示的是"去重后的件数",
	# 重复授予同一件不会改变它, 那样测等于空转
	var probe_item := "acc_spray_stripe_logo"
	InventoryService.clear_item(probe_item)
	await get_tree().process_frame
	var n_before := InventoryService.get_owned_ids().size()
	var before := btn.text
	InventoryService.grant_item(probe_item, 1)
	await get_tree().process_frame
	if btn.text != before:
		_ok("按钮计数联动", "%s → %s" % [before, btn.text])
	else:
		_bad("按钮计数联动", "库存 %d→%d 文案仍是 %s" % [
			n_before, InventoryService.get_owned_ids().size(), btn.text])

	# 再点一次不应再开第二个商城实例(懒加载没做好就会叠加)
	btn.pressed.emit()
	await get_tree().process_frame
	var count := 0
	for ch in menu.get_children():
		if ch is ShopUI:
			count += 1
	if count == 1:
		_ok("懒加载单例", "重复点击仍只有一个 ShopUI")
	else:
		_bad("懒加载单例", "叠了 %d 个 ShopUI" % count)

	overlay.close_shop()
	if overlay.visible:
		_bad("覆盖层关闭", "关不掉")
	else:
		_ok("覆盖层关闭", "已关闭, 可回主菜单继续操作")
