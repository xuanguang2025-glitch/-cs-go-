extends Control
class_name ShopUI
##
## ShopUI.gd — 商城 / 仓库 / 开箱界面
##
## 全部控件代码生成, 沿用 MainMenu 的写法与配色(项目里 scenes/UI 是空的,
## 所有界面都靠 _build 系列函数搭, 这里保持一致)。
##
## 三个页签共用同一套网格与预览栏, 差别只在数据源和动作按钮语义。
## 预览栏调用 LoadoutCosmetics.apply_item_skin —— 与游戏内挂皮肤同一个函数,
## 所以"预览好看、进图不对"这类偏差在结构上不可能出现。
##

signal closed

const TAB_STORE := 0
const TAB_INVENTORY := 1
const TAB_UNBOX := 2

const TYPE_FILTERS := [
	["全部", ""],
	["武器皮肤", "weapon_skin"],
	["角色皮肤", "character_skin"],
	["配件", "accessory"],
	["击杀特效", "kill_effect"],
	["MVP 动作", "mvp_animation"],
	["语音包", "voice_pack"],
]
const RARITY_FILTERS := [
	["全部", ""],
	["普通", "common"],
	["稀有", "rare"],
	["史诗", "epic"],
	["传说", "legendary"],
]

const COL_TEXT := Color(0.95, 0.97, 1.0)
const COL_DIM := Color(0.6, 0.68, 0.78)
const COL_ACCENT := Color(0.45, 0.7, 0.85)
const COL_BORDER := Color(0.3, 0.38, 0.48, 0.85)
const COL_DANGER := Color(0.95, 0.42, 0.38)

# ---- 节点引用(同时供无头探针断言) ----
var credits_label: Label
var premium_label: Label
var tab_buttons: Array = []
var type_option: OptionButton
var rarity_option: OptionButton
var search_edit: LineEdit
var count_label: Label
var grid: GridContainer
var preview_name: Label
var preview_rarity: Label
var preview_desc: Label
var preview_status: Label
var action_button: Button
var preview_host: SubViewportContainer
var model_root: Node3D
var camera_rig: Node3D
var reveal_layer: Control
var reveal_title: Label
var reveal_detail: Label
var reveal_swatch: ColorRect

var _tab: int = TAB_STORE
var _type_filter: int = 0
var _rarity_filter: int = 0
var _search: String = ""
var _selected: Dictionary = {}
var _cards: Array = []
var _orbit: float = 0.0
var _last_result: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()
	# currency_changed 定义在 EventBus 上, 不是 CurrencyManager —— 接错会静默失效
	EventBus.currency_changed.connect(_on_currency_changed)
	ShopManager.loadout_changed.connect(_rebuild)
	EventBus.inventory_updated.connect(_on_inventory_updated)
	# 联网态下这才是真结果(离线态与 route_* 同源)
	ShopManager.business_response.connect(_on_business_response)
	_refresh()


func _process(delta: float) -> void:
	if not visible or camera_rig == null:
		return
	_orbit += delta * 0.6
	camera_rig.rotation.y = _orbit


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo or k.keycode != KEY_ESCAPE:
		return
	# 揭示层开着时 ESC 只关它, 不顺手把整个商城也关掉
	if reveal_layer.visible:
		reveal_layer.visible = false
	else:
		close_shop()
	get_viewport().set_input_as_handled()


# ================================================================ 对外接口

func open_shop() -> void:
	visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	EventBus.shop_opened.emit()
	_refresh()


func close_shop() -> void:
	visible = false
	EventBus.shop_closed.emit()
	closed.emit()


func activate_tab(i: int) -> void:
	_tab = clampi(i, TAB_STORE, TAB_UNBOX)
	for idx in tab_buttons.size():
		_style_tab(tab_buttons[idx] as Button, idx == _tab)
	_refresh()


func current_tab() -> int:
	return _tab


func card_count() -> int:
	return _cards.size()


func card_ids() -> Array:
	var out: Array = []
	for c in _cards:
		out.append(String(c.ref_id))
	return out


func selected_id() -> String:
	return String(_selected.get("ref_id", ""))


## 选中某张卡片(探针用它代替真实点击)。返回是否命中。
func select_card(id: String) -> bool:
	for c in _cards:
		if String(c.ref_id) == id:
			_select(c.desc)
			return true
	return false


## 执行动作按钮语义(探针直接调用, 不经鼠标事件)。
func press_action() -> Dictionary:
	if action_button == null or action_button.disabled:
		return {}
	return _run_action()


func last_result() -> Dictionary:
	return _last_result


func credit_text() -> String:
	return credits_label.text if credits_label != null else ""


func premium_text() -> String:
	return premium_label.text if premium_label != null else ""


func is_built() -> bool:
	return grid != null and preview_name != null and model_root != null


# ================================================================ 数据刷新

func _refresh() -> void:
	_refresh_currency()
	_rebuild()


func _refresh_currency() -> void:
	credits_label.text = "积分 %d" % CurrencyManager.get_balance(CurrencyManager.CREDITS)
	premium_label.text = "钻石 %d" % CurrencyManager.get_balance(CurrencyManager.PREMIUM)


func _on_currency_changed(currency_type: String, _balance: int) -> void:
	# 读单例而不是读信号载荷: 两处真源迟早会对不上
	if currency_type == CurrencyManager.CREDITS:
		credits_label.text = "积分 %d" % CurrencyManager.get_balance(CurrencyManager.CREDITS)
	else:
		premium_label.text = "钻石 %d" % CurrencyManager.get_balance(CurrencyManager.PREMIUM)
	_update_action()


func _on_inventory_updated(_ids: Array) -> void:
	_refresh()


func _rebuild() -> void:
	if grid == null:
		return
	for c in _cards:
		c.queue_free()
	_cards.clear()
	_selected = {}

	var rows := _rows_for_tab()
	count_label.text = "%d 项" % rows.size()
	for r in rows:
		var card := _make_card(r)
		grid.add_child(card)
		_cards.append(card)
	if not rows.is_empty():
		_select(rows[0])
	else:
		_show_placeholder()
	_update_action()


func _rows_for_tab() -> Array:
	var rows: Array = []
	match _tab:
		TAB_STORE:
			for e in SkinDatabase.get_all_store_entries():
				var item: Dictionary = SkinDatabase.get_item(String(e.get("item_id", "")))
				if item.is_empty() or not _passes(String(item.get("id", "")), item):
					continue
				rows.append({
					"kind": "store",
					"ref_id": String(e.get("entry_id", "")),
					"item": item,
					"entry": e,
				})
		TAB_INVENTORY:
			for owned in InventoryService.get_owned_items():
				if not _passes(String(owned.get("id", "")), owned):
					continue
				rows.append({
					"kind": "inventory",
					"ref_id": String(owned.get("id", "")),
					"item": owned,
				})
			rows.sort_custom(_by_rarity_desc)
		TAB_UNBOX:
			for b in SkinDatabase.get_all_loot_boxes():
				rows.append({
					"kind": "box",
					"ref_id": String(b.get("id", "")),
					"box": b,
				})
	return rows


func _by_rarity_desc(a: Dictionary, b: Dictionary) -> bool:
	var ra := SkinDatabase.get_rarity_rank(String((a.get("item", {}) as Dictionary).get("rarity", "")))
	var rb := SkinDatabase.get_rarity_rank(String((b.get("item", {}) as Dictionary).get("rarity", "")))
	return ra > rb


func _passes(id: String, def: Dictionary) -> bool:
	var want_type := String(TYPE_FILTERS[_type_filter][1])
	if not want_type.is_empty() and String(def.get("type", "")) != want_type:
		return false
	var want_rar := String(RARITY_FILTERS[_rarity_filter][1])
	if not want_rar.is_empty() and String(def.get("rarity", "")) != want_rar:
		return false
	if not _search.is_empty():
		var hay := "%s %s %s %s" % [id, String(def.get("name", "")),
			String(def.get("weapon_id", "")), String(def.get("description", ""))]
		if not hay.to_lower().contains(_search.to_lower()):
			return false
	return true


# ================================================================ 预览与动作

func _make_card(desc: Dictionary) -> ShopCard:
	var card := ShopCard.new()
	card.desc = desc
	card.clicked.connect(_select)
	return card


func _select(desc: Dictionary) -> void:
	_selected = desc
	for c in _cards:
		c.mark_selected(String(c.ref_id) == String(desc.get("ref_id", "")))
	var kind := String(desc.get("kind", ""))
	if kind == "box":
		var box: Dictionary = desc.get("box", {})
		preview_name.text = String(box.get("name", box.get("id", "?")))
		preview_rarity.text = String(box.get("rarity", ""))
		preview_rarity.add_theme_color_override("font_color",
			rarity_color(String(box.get("rarity", "common"))))
		var lines: Array = []
		for e in box.get("contents_pool", []):
			var d: Dictionary = SkinDatabase.get_item(String(e.get("item_id", "")))
			if not d.is_empty():
				lines.append("· %s  [%s]" % [String(d.get("name", "?")),
					String(get_rarity_label(String(d.get("rarity", ""))))])
		preview_desc.text = "可开出:\n" + "\n".join(lines)
		preview_status.text = "保底进度 %d / %d" % [
			ShopManager.get_pity(String(box.get("id", ""))),
			int(box.get("pity_counter_threshold", 0))]
		_build_model("box")
	else:
		var item: Dictionary = desc.get("item", {})
		var iid := String(item.get("id", ""))
		preview_name.text = String(item.get("name", "?"))
		preview_rarity.text = String(get_rarity_label(String(item.get("rarity", ""))))
		preview_rarity.add_theme_color_override("font_color",
			rarity_color(String(item.get("rarity", "common"))))
		var subtitle := ""
		if String(item.get("weapon_id", "")) != "":
			var w: Dictionary = WeaponDatabase.get_weapon(String(item.get("weapon_id", "")))
			subtitle = "适配武器: %s\n" % String(w.get("name", item.get("weapon_id")))
		preview_desc.text = subtitle + String(item.get("description", ""))
		if kind == "inventory":
			var slot := slot_for_item(item)
			preview_status.text = "已装备" if ShopManager.loadout.get_equipped(slot) == iid else "未装备"
		else:
			preview_status.text = "未拥有"
		_build_model(String(item.get("type", "")))
		_apply_preview_skin(iid)
	_update_action()


func _show_placeholder() -> void:
	_selected = {}
	preview_name.text = "无可显示内容"
	preview_rarity.text = ""
	preview_desc.text = "调整筛选条件试试。"
	preview_status.text = ""
	action_button.text = "—"
	action_button.disabled = true
	_build_model("none")


## 预览用模型按类型现搭。项目全部是程序化几何, 这里也用同一套做法。
func _build_model(type_name: String) -> void:
	if model_root == null:
		return
	for ch in model_root.get_children():
		ch.queue_free()

	var base := _mk_preview_mat(Color(0.62, 0.65, 0.70))

	match type_name:
		"weapon_skin":
			_add_part(Vector3(0, 0, -0.10), Vector3(0.10, 0.11, 0.92), base)
			_add_part(Vector3(0, 0.02, -0.86), Vector3(0.05, 0.05, 0.62), base)
			_add_part(Vector3(0, -0.16, 0.18), Vector3(0.07, 0.20, 0.16), base)
			_add_part(Vector3(0, 0.13, 0.28), Vector3(0.05, 0.10, 0.34), base)
			_add_part(Vector3(0, -0.05, 0.62), Vector3(0.08, 0.17, 0.30), base)
		"character_skin":
			_add_part(Vector3(0, 0.24, 0), Vector3(0.44, 0.62, 0.26), base)
			_add_part(Vector3(0, 0.74, 0), Vector3(0.24, 0.24, 0.24), base)
			_add_part(Vector3(0, 0.88, 0), Vector3(0.29, 0.12, 0.30), base)
			_add_part(Vector3(-0.27, 0.24, 0), Vector3(0.14, 0.52, 0.16), base)
			_add_part(Vector3(0.27, 0.24, 0), Vector3(0.14, 0.52, 0.16), base)
			_add_part(Vector3(-0.11, -0.44, 0), Vector3(0.16, 0.60, 0.18), base)
			_add_part(Vector3(0.11, -0.44, 0), Vector3(0.16, 0.60, 0.18), base)
		"accessory", "spray":
			_add_part(Vector3(0, -0.22, 0), Vector3(0.70, 0.06, 0.70),
				_mk_preview_mat(Color(0.16, 0.18, 0.22)))
			_add_part(Vector3(0, 0.02, 0), Vector3(0.34, 0.16, 0.42), base)
		"kill_effect":
			_add_part(Vector3(0, -0.18, 0), Vector3(0.60, 0.05, 0.60),
				_mk_preview_mat(Color(0.16, 0.18, 0.22)))
			_add_sphere(Vector3(0, 0.16, 0), 0.24, base)
		"mvp_animation":
			_add_part(Vector3(0, -0.30, 0), Vector3(0.66, 0.06, 0.66),
				_mk_preview_mat(Color(0.16, 0.18, 0.22)))
			_add_part(Vector3(0, 0.10, 0), Vector3(0.10, 0.62, 0.10), base)
			_add_part(Vector3(0.22, 0.26, 0.10), Vector3(0.34, 0.05, 0.06), base)
		"voice_pack":
			_add_part(Vector3(0, 0.0, 0), Vector3(0.34, 0.44, 0.14), base)
			_add_part(Vector3(0, 0.30, 0.02), Vector3(0.05, 0.20, 0.05),
				_mk_preview_mat(Color(0.2, 0.22, 0.26)))
		"box":
			_add_part(Vector3(0, 0, 0), Vector3(0.74, 0.46, 0.54),
				_mk_preview_mat(Color(0.28, 0.32, 0.38)))
			_add_part(Vector3(0, 0.25, 0), Vector3(0.78, 0.06, 0.58),
				_mk_preview_mat(Color(0.42, 0.48, 0.56)))
			_add_part(Vector3(0, 0.02, 0.29), Vector3(0.12, 0.12, 0.06),
				_mk_preview_mat(Color(0.85, 0.68, 0.2)))
		_:
			pass


## 预览皮肤走的是实机同一条应用路径
func _apply_preview_skin(item_id: String) -> void:
	LoadoutCosmetics.apply_item_skin(model_root, item_id)


func _add_part(pos: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = pos
	mi.material_override = mat
	model_root.add_child(mi)


func _add_sphere(pos: Vector3, radius: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	mi.mesh = s
	mi.position = pos
	mi.material_override = mat
	model_root.add_child(mi)


func _mk_preview_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.5
	m.metallic = 0.2
	return m


func _update_action() -> void:
	if action_button == null:
		return
	var kind := String(_selected.get("kind", ""))
	action_button.disabled = true
	match kind:
		"store":
			var item_id := String((_selected.get("item", {}) as Dictionary).get("id", ""))
			if InventoryService.has_item(item_id):
				action_button.text = "已拥有"
			else:
				var e: Dictionary = _selected.get("entry", {})
				var best := _preferred_payable(String(_selected.get("ref_id", "")))
				if best.is_empty():
					action_button.text = "余额不足"
				else:
					action_button.text = "购买 · %d %s" % [
						int(best["amount"]), _currency_name(String(best["type"]))]
					action_button.disabled = false
		"inventory":
			var iid := String((_selected.get("item", {}) as Dictionary).get("id", ""))
			var slot := slot_for_item(_selected.get("item", {}) as Dictionary)
			if slot.is_empty():
				action_button.text = "该外观无需装备"
			elif ShopManager.loadout.get_equipped(slot) == iid:
				action_button.text = "卸 下"
				action_button.disabled = false
			else:
				action_button.text = "装 备"
				action_button.disabled = false
		"box":
			var b: Dictionary = _selected.get("box", {})
			var c := int(b.get("cost_credits", 0))
			var p := int(b.get("cost_premium", 0))
			var ctype := CurrencyManager.CREDITS if c > 0 else CurrencyManager.PREMIUM
			var price := c if c > 0 else p
			if CurrencyManager.has_enough(ctype, price):
				action_button.text = "开启 · %d %s" % [price, _currency_name(ctype)]
				action_button.disabled = false
			else:
				action_button.text = "余额不足"
		_:
			action_button.text = "—"
	if not action_button.pressed.is_connected(_run_action):
		action_button.pressed.connect(_run_action)


## 选一种实际付得起的货币。
## 固定优先扣积分, 积分不够才动钻石 —— 钻石是真钱买的,
## 按"折算价更低"去自动选钻石, 会在玩家没察觉时把充值得来的余额花掉。
func _preferred_payable(entry_id: String) -> Dictionary:
	var e: Dictionary = SkinDatabase.get_store_entry(entry_id)
	var payable := ShopManager.payable_currencies(entry_id)
	for ct in [CurrencyManager.CREDITS, CurrencyManager.PREMIUM]:
		if not payable.has(ct):
			continue
		var amt := int(e.get("cost_credits", 0)) if String(ct) == CurrencyManager.CREDITS \
			else int(e.get("cost_premium", 0))
		if amt <= 0:
			continue
		if CurrencyManager.has_enough(String(ct), amt):
			return {"type": String(ct), "amount": amt}
	return {}


func _currency_name(t: String) -> String:
	return "积分" if t == CurrencyManager.CREDITS else "钻石"


## 动作按钮入口。一律经 ShopManager.route_* 发出:
## 离线/主机态同步拿到真结果; 联网客户端只拿到 pending, 真结果稍后由
## ShopManager.business_response 送回 —— 客户端无权自己宣布购买成功。
func _run_action() -> Dictionary:
	var kind := String(_selected.get("kind", ""))
	match kind:
		"store":
			var best := _preferred_payable(String(_selected.get("ref_id", "")))
			if best.is_empty():
				return _local_fail("insufficient")
			return _submit(ShopManager.route_purchase(
				String(_selected.get("ref_id", "")), String(best["type"])))
		"inventory":
			var item: Dictionary = _selected.get("item", {})
			var slot := slot_for_item(item)
			var iid := String(item.get("id", ""))
			if slot.is_empty():
				return _local_fail("no_slot")
			if ShopManager.loadout.get_equipped(slot) == iid:
				return _submit(ShopManager.route_unequip(slot))
			return _submit(ShopManager.route_equip(slot, iid))
		"box":
			return _submit(ShopManager.route_unbox(String(_selected.get("ref_id", ""))))
		_:
			return _local_fail("no_action")


## 本地就能判定的失败(没选到可付货币、该类型无装备槽), 不必走结算
func _local_fail(reason: String) -> Dictionary:
	var res := {"success": false, "reason": reason}
	_last_result = res
	_show_failure(reason)
	return res


func _submit(res: Dictionary) -> Dictionary:
	_last_result = res
	if bool(res.get("pending", false)):
		# 锁住按钮防连点: 回执到达前再点一次就是重放同一笔请求
		action_button.disabled = true
		preview_status.text = "处 理 中 …"
		preview_status.add_theme_color_override("font_color", COL_ACCENT)
	return res


func _show_failure(reason: String) -> void:
	preview_status.text = "✗ %s" % _human_reason(reason)
	preview_status.add_theme_color_override("font_color", COL_DANGER)


func _on_business_response(action: String, result: Dictionary) -> void:
	if not visible:
		return
	if bool(result.get("success", false)):
		if action == "unbox":
			_show_reveal(result)
		_refresh()
	else:
		_show_failure(String(result.get("reason", "?")))
		_update_action()


func _human_reason(r: String) -> String:
	if r.begins_with("insufficient"):
		return "余额不足"
	match r:
		"already_owned":
			return "已拥有该外观"
		"not_owned":
			return "尚未拥有该外观"
		"":
			return "完成"
	return r


func _show_reveal(result: Dictionary) -> void:
	var item: Dictionary = SkinDatabase.get_item(String(result.get("item_id", "")))
	var rcol := rarity_color(String(result.get("rarity", "common")))
	reveal_swatch.color = rcol
	reveal_title.text = String(item.get("name", "?"))
	reveal_title.add_theme_color_override("font_color", rcol)
	var extra := ""
	if bool(result.get("duplicate", false)):
		extra = "\n重复外观 · 折算 +%d 积分" % int(result.get("refunded_credits", 0))
	reveal_detail.text = String(get_rarity_label(String(result.get("rarity", "")))) + extra
	reveal_layer.visible = true
	reveal_layer.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(reveal_layer, "modulate:a", 1.0, 0.22)


# ================================================================ 构建

func _build() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(1220, 780)
	panel.add_theme_stylebox_override("panel",
		card_style(COL_ACCENT.darkened(0.3), Color(0.07, 0.085, 0.11, 0.96), 2))
	center.add_child(panel)

	var margin := MarginContainer.new()
	for k in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(k, 20)
	for k in ["margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(k, 14)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	_build_top_bar(vbox)
	_build_tab_bar(vbox)
	_build_body(vbox)
	_build_reveal(panel)


func _build_top_bar(parent: Control) -> void:
	var bar := HBoxContainer.new()
	bar.name = "TopBar"
	bar.add_theme_constant_override("separation", 14)
	parent.add_child(bar)

	var title := Label.new()
	title.name = "Title"
	title.text = "S T R I K E   M A R K E T"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", COL_TEXT)
	bar.add_child(title)

	var hint := Label.new()
	hint.text = "外观不改变任何数值"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", COL_DIM)
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(hint)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var row := HBoxContainer.new()
	row.name = "CurrencyRow"
	row.add_theme_constant_override("separation", 10)
	bar.add_child(row)
	credits_label = _currency_chip(row, "credits", COL_ACCENT)
	premium_label = _currency_chip(row, "premium", Color(0.85, 0.65, 1.0))

	var close := Button.new()
	close.name = "CloseButton"
	close.text = "关闭 (ESC)"
	close.custom_minimum_size = Vector2(104, 34)
	close.add_theme_font_size_override("font_size", 15)
	close.pressed.connect(close_shop)
	bar.add_child(close)


func _currency_chip(parent: Control, key: String, col: Color) -> Label:
	var box := PanelContainer.new()
	box.name = "chip_" + key
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.03, 0.04, 0.06, 0.9)
	st.set_corner_radius_all(6)
	st.border_color = Color(col.r, col.g, col.b, 0.5)
	st.set_border_width_all(1)
	st.content_margin_left = 12
	st.content_margin_right = 12
	st.content_margin_top = 5
	st.content_margin_bottom = 5
	box.add_theme_stylebox_override("panel", st)
	parent.add_child(box)

	var l := Label.new()
	l.name = key
	l.text = "0"
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", col)
	box.add_child(l)
	return l


func _build_tab_bar(parent: Control) -> void:
	var bar := HBoxContainer.new()
	bar.name = "TabBar"
	bar.add_theme_constant_override("separation", 8)
	parent.add_child(bar)

	var labels := ["商 店", "我的仓库", "开启补给箱"]
	for i in labels.size():
		var b := Button.new()
		b.name = "tab_%d" % i
		b.text = labels[i]
		b.custom_minimum_size = Vector2(168, 36)
		b.add_theme_font_size_override("font_size", 16)
		var idx := i
		b.pressed.connect(func() -> void: activate_tab(idx))
		bar.add_child(b)
		tab_buttons.append(b)
		_style_tab(b, i == _tab)


func _style_tab(b: Button, active: bool) -> void:
	var st := card_style(COL_ACCENT if active else Color(0.24, 0.30, 0.38),
		Color(0.10, 0.13, 0.18, 0.95) if active else Color(0.05, 0.06, 0.08, 0.9))
	b.add_theme_stylebox_override("normal", st)
	b.add_theme_stylebox_override("hover", st)
	b.add_theme_stylebox_override("pressed", st)
	b.add_theme_color_override("font_color", COL_TEXT if active else COL_DIM)


func _build_body(parent: Control) -> void:
	var body := HBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 16)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(body)

	var left := VBoxContainer.new()
	left.name = "Left"
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 10)
	body.add_child(left)

	var fbar := HBoxContainer.new()
	fbar.name = "FilterBar"
	fbar.add_theme_constant_override("separation", 8)
	left.add_child(fbar)

	type_option = OptionButton.new()
	type_option.name = "TypeOption"
	type_option.custom_minimum_size = Vector2(140, 32)
	for s in TYPE_FILTERS:
		type_option.add_item(String(s[0]))
	fbar.add_child(type_option)

	rarity_option = OptionButton.new()
	rarity_option.name = "RarityOption"
	rarity_option.custom_minimum_size = Vector2(110, 32)
	for s in RARITY_FILTERS:
		rarity_option.add_item(String(s[0]))
	fbar.add_child(rarity_option)

	search_edit = LineEdit.new()
	search_edit.name = "SearchEdit"
	search_edit.placeholder_text = "搜索名称 / 武器"
	search_edit.custom_minimum_size = Vector2(200, 32)
	search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fbar.add_child(search_edit)

	count_label = Label.new()
	count_label.name = "CountLabel"
	count_label.custom_minimum_size = Vector2(64, 0)
	count_label.add_theme_font_size_override("font_size", 14)
	count_label.add_theme_color_override("font_color", COL_DIM)
	fbar.add_child(count_label)

	type_option.item_selected.connect(func(i: int) -> void:
		_type_filter = i
		_rebuild())
	rarity_option.item_selected.connect(func(i: int) -> void:
		_rarity_filter = i
		_rebuild())
	search_edit.text_changed.connect(func(t: String) -> void:
		_search = t
		_rebuild())

	var scroll := ScrollContainer.new()
	scroll.name = "GridScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)

	grid = GridContainer.new()
	grid.name = "ItemGrid"
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)

	var dock := VBoxContainer.new()
	dock.name = "PreviewDock"
	dock.custom_minimum_size = Vector2(360, 0)
	dock.add_theme_constant_override("separation", 8)
	body.add_child(dock)

	preview_host = SubViewportContainer.new()
	preview_host.name = "PreviewHost"
	preview_host.custom_minimum_size = Vector2(360, 286)
	preview_host.stretch = true
	dock.add_child(preview_host)

	var vp := SubViewport.new()
	vp.name = "Viewport3D"
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.size = Vector2i(360, 286)
	preview_host.add_child(vp)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.84, 0.95)
	env.ambient_light_energy = 0.6
	we.environment = env
	vp.add_child(we)

	var light := DirectionalLight3D.new()
	light.name = "KeyLight"
	light.rotation_degrees = Vector3(-42, 38, 0)
	light.light_energy = 1.2
	vp.add_child(light)

	camera_rig = Node3D.new()
	camera_rig.name = "CameraRig"
	vp.add_child(camera_rig)

	var cam := Camera3D.new()
	cam.name = "PreviewCamera"
	cam.position = Vector3(0, 0.28, 2.05)
	cam.fov = 58.0
	cam.current = true
	camera_rig.add_child(cam)

	model_root = Node3D.new()
	model_root.name = "ModelRoot"
	vp.add_child(model_root)

	preview_name = Label.new()
	preview_name.name = "PreviewName"
	preview_name.text = "—"
	preview_name.add_theme_font_size_override("font_size", 22)
	preview_name.add_theme_color_override("font_color", COL_TEXT)
	dock.add_child(preview_name)

	preview_rarity = Label.new()
	preview_rarity.name = "PreviewRarity"
	preview_rarity.add_theme_font_size_override("font_size", 14)
	dock.add_child(preview_rarity)

	preview_desc = Label.new()
	preview_desc.name = "PreviewDesc"
	preview_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_desc.add_theme_font_size_override("font_size", 13)
	preview_desc.add_theme_color_override("font_color", COL_DIM)
	dock.add_child(preview_desc)

	preview_status = Label.new()
	preview_status.name = "PreviewStatus"
	preview_status.add_theme_font_size_override("font_size", 14)
	preview_status.add_theme_color_override("font_color", COL_ACCENT)
	dock.add_child(preview_status)

	action_button = Button.new()
	action_button.name = "ActionButton"
	action_button.custom_minimum_size = Vector2(0, 44)
	action_button.add_theme_font_size_override("font_size", 18)
	dock.add_child(action_button)


func _build_reveal(parent: Control) -> void:
	reveal_layer = Control.new()
	reveal_layer.name = "RevealLayer"
	reveal_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	reveal_layer.visible = false
	parent.add_child(reveal_layer)

	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.88)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	reveal_layer.add_child(shade)

	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	reveal_layer.add_child(cc)

	var box := PanelContainer.new()
	box.name = "RevealCard"
	box.custom_minimum_size = Vector2(440, 300)
	box.add_theme_stylebox_override("panel",
		card_style(COL_BORDER, Color(0.07, 0.085, 0.11, 0.99), 2))
	cc.add_child(box)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(v)

	reveal_swatch = ColorRect.new()
	reveal_swatch.name = "RevealSwatch"
	reveal_swatch.custom_minimum_size = Vector2(0, 8)
	v.add_child(reveal_swatch)

	var cap := Label.new()
	cap.text = "获 得 新 外 观"
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 14)
	cap.add_theme_color_override("font_color", COL_DIM)
	v.add_child(cap)

	reveal_title = Label.new()
	reveal_title.name = "RevealTitle"
	reveal_title.text = "—"
	reveal_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reveal_title.add_theme_font_size_override("font_size", 30)
	v.add_child(reveal_title)

	reveal_detail = Label.new()
	reveal_detail.name = "RevealDetail"
	reveal_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reveal_detail.add_theme_font_size_override("font_size", 14)
	reveal_detail.add_theme_color_override("font_color", COL_DIM)
	v.add_child(reveal_detail)

	var wb := CenterContainer.new()
	v.add_child(wb)
	var ok := Button.new()
	ok.name = "RevealClose"
	ok.text = "确 认"
	ok.custom_minimum_size = Vector2(168, 40)
	ok.pressed.connect(func() -> void: reveal_layer.visible = false)
	wb.add_child(ok)


# ================================================================ 静态工具
# ShopCard 与 MainMenu 都要用, 所以是 static

static func is_owned_item(item_id: String) -> bool:
	return InventoryService.has_item(item_id)


static func rarity_color(r: String) -> Color:
	return SkinDatabase.get_rarity_color(r)


static func get_rarity_label(r: String) -> String:
	return String(SkinDatabase.get_rarity(r).get("label", r))


static func skin_tint(item_id: String) -> Color:
	return LoadoutCosmetics.skin_color(item_id)


## 物品对应的装备槽; 空串表示该类型不需要装备(本期配件/喷漆尚无挂点)
static func slot_for_item(def: Dictionary) -> String:
	match String(def.get("type", "")):
		"character_skin":
			return LoadoutCosmetics.SLOT_CHARACTER
		"weapon_skin":
			return LoadoutCosmetics.weapon_slot(String(def.get("weapon_id", "")))
		"kill_effect":
			return LoadoutCosmetics.SLOT_KILL_EFFECT
		"mvp_animation":
			return LoadoutCosmetics.SLOT_MVP
		"voice_pack":
			return LoadoutCosmetics.SLOT_VOICE
	return ""


static func card_style(border: Color, bg: Color, width: int = 2) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = bg
	st.set_corner_radius_all(8)
	st.border_color = border
	st.set_border_width_all(width)
	st.content_margin_left = 10
	st.content_margin_right = 10
	st.content_margin_top = 8
	st.content_margin_bottom = 8
	return st


# ================================================================ 卡片

class ShopCard extends PanelContainer:
	## 商店 / 仓库 / 箱子共用的"一行可点条目", 区别只在 desc.kind。
	signal clicked(desc: Dictionary)

	var desc: Dictionary = {}
	var ref_id: String = ""
	var swatch: ColorRect
	var name_label: Label
	var rarity_label: Label
	var price_label: Label
	var _normal: StyleBoxFlat
	var _hover: StyleBoxFlat
	var _selected_style: StyleBoxFlat
	var _locked: bool = false

	func _ready() -> void:
		custom_minimum_size = Vector2(214, 182)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var kind := String(desc.get("kind", ""))
		var title := "?"
		var rarity := "common"
		var tint := Color(0.28, 0.32, 0.4)
		var price := ""
		var equipped := false

		if kind == "box":
			var box: Dictionary = desc.get("box", {})
			title = String(box.get("name", box.get("id", "?")))
			rarity = String(box.get("rarity", "common"))
			var c := int(box.get("cost_credits", 0))
			var p := int(box.get("cost_premium", 0))
			price = ("%d 积分" % c) if c > 0 else ("%d 钻石" % p)
			var th := maxi(int(box.get("pity_counter_threshold", 1)), 1)
			price += "  ·  保底 %d/%d" % [ShopManager.get_pity(String(box.get("id", ""))), th]
		else:
			var item: Dictionary = desc.get("item", {})
			title = String(item.get("name", "?"))
			rarity = String(item.get("rarity", "common"))
			tint = ShopUI.skin_tint(String(item.get("id", "")))
			if kind == "store":
				var e: Dictionary = desc.get("entry", {})
				var parts: Array = []
				if int(e.get("cost_credits", 0)) > 0:
					parts.append("%d 积分" % int(e.get("cost_credits", 0)))
				if int(e.get("cost_premium", 0)) > 0:
					parts.append("%d 钻石" % int(e.get("cost_premium", 0)))
				price = " / ".join(parts)
				if ShopUI.is_owned_item(String(item.get("id", ""))):
					price += "  ·  已拥有"
			else:
				var slot := ShopUI.slot_for_item(item)
				equipped = slot != "" and \
					ShopManager.loadout.get_equipped(slot) == String(item.get("id", ""))
				price = "已装备" if equipped else String(item.get("type", ""))

		ref_id = String(desc.get("ref_id", ""))
		var rcol: Color = ShopUI.rarity_color(rarity)
		_normal = ShopUI.card_style(rcol.darkened(0.5), Color(0.055, 0.07, 0.09, 0.95))
		_hover = ShopUI.card_style(rcol, Color(0.08, 0.10, 0.13, 0.98))
		_selected_style = ShopUI.card_style(Color(0.45, 0.85, 1.0),
			Color(0.08, 0.12, 0.15, 0.98), 3)
		_locked = equipped
		add_theme_stylebox_override("panel", _selected_style if equipped else _normal)

		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 4)
		add_child(v)

		swatch = ColorRect.new()
		swatch.name = "Swatch"
		swatch.color = tint
		swatch.custom_minimum_size = Vector2(0, 68)
		v.add_child(swatch)

		name_label = Label.new()
		name_label.name = "CardName"
		name_label.text = title
		name_label.clip_text = true
		name_label.add_theme_font_size_override("font_size", 16)
		name_label.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
		v.add_child(name_label)

		rarity_label = Label.new()
		rarity_label.name = "CardRarity"
		rarity_label.text = String(ShopUI.get_rarity_label(rarity))
		rarity_label.add_theme_font_size_override("font_size", 12)
		rarity_label.add_theme_color_override("font_color", rcol)
		v.add_child(rarity_label)

		price_label = Label.new()
		price_label.name = "CardPrice"
		price_label.text = price
		price_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		price_label.add_theme_font_size_override("font_size", 12)
		price_label.add_theme_color_override("font_color", Color(0.6, 0.68, 0.78))
		v.add_child(price_label)

		mouse_entered.connect(func() -> void:
			if not _locked:
				add_theme_stylebox_override("panel", _hover))
		mouse_exited.connect(func() -> void:
			if not _locked:
				add_theme_stylebox_override("panel", _normal))
		gui_input.connect(_on_gui)

	func mark_selected(on: bool) -> void:
		if _locked:
			return
		add_theme_stylebox_override("panel", _hover if on else _normal)

	func _on_gui(ev: InputEvent) -> void:
		if ev is InputEventMouseButton:
			var b := ev as InputEventMouseButton
			if b.button_index == MOUSE_BUTTON_LEFT and b.pressed:
				clicked.emit(desc)
