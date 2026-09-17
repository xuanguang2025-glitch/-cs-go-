extends CanvasLayer
class_name BuyMenu
##
## BuyMenu.gd — 购买菜单
##
## 分类: 手枪 / 冲锋枪 / 步枪 / 狙击 / 重型 / 装备 / 投掷物
## 支持鼠标点击购买与数字键快捷购买, 买不起的物品置灰。
## 数据全部来自 WeaponDatabase, 不硬编码任何价格或属性。
##

signal closed()

const CATEGORIES := [
	{"key": "pistol", "label": "手枪", "slot": "secondary"},
	{"key": "smg",    "label": "冲锋枪", "slot": "primary"},
	{"key": "rifle",  "label": "步枪", "slot": "primary"},
	{"key": "sniper", "label": "狙击枪", "slot": "primary"},
	{"key": "shotgun", "label": "霰弹枪", "slot": "primary"},
	{"key": "lmg",    "label": "轻机枪", "slot": "primary"},
	{"key": "gear",   "label": "装备", "slot": ""},
	{"key": "grenade", "label": "投掷物", "slot": ""},
]

## 数字键快捷购买映射(键位 -> [类别, 序号])
const QUICK_BUY := {
	KEY_1: ["pistol", 0], KEY_2: ["pistol", 1], KEY_3: ["pistol", 2], KEY_4: ["pistol", 3],
	KEY_5: ["smg", 0], KEY_6: ["smg", 1], KEY_7: ["smg", 2],
	KEY_8: ["rifle", 0], KEY_9: ["rifle", 1], KEY_0: ["rifle", 2],
}

var actor: Actor = null
var mm: MatchManager = null
var is_open: bool = false
var current_category: String = "rifle"

var panel: PanelContainer
var category_bar: HBoxContainer
var grid: GridContainer
var money_label: Label
var info_label: Label
var _buttons: Array = []


func _ready() -> void:
	layer = 20
	set_process_unhandled_input(true)
	_build_ui()
	visible = false


func setup(a: Actor, m: MatchManager) -> void:
	actor = a
	mm = m
	if a != null and a.loadout != null:
		a.loadout.money_changed.connect(_on_money_changed)
		# 联机客户端: 服务器结算后的配装广播会改本地 loadout,
		# 据此刷新购买按钮的"已拥有/买不起"状态
		a.loadout.weapon_changed.connect(func(_s, _w): _refresh_grid())


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# 背景遮罩
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(860, 560)
	panel.position = Vector2(-430, -280)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11, 0.96)
	style.border_color = Color(0.35, 0.42, 0.5, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", style)
	root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	# 标题栏
	var header := HBoxContainer.new()
	vbox.add_child(header)
	var title := Label.new()
	title.text = "购买菜单"
	title.add_theme_font_size_override("font_size", 28)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	money_label = Label.new()
	money_label.text = "$800"
	money_label.add_theme_font_size_override("font_size", 26)
	money_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
	header.add_child(money_label)

	# 分类栏
	category_bar = HBoxContainer.new()
	category_bar.add_theme_constant_override("separation", 6)
	vbox.add_child(category_bar)

	# 物品网格
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 340)
	vbox.add_child(scroll)
	grid = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)

	# 底部说明
	info_label = Label.new()
	info_label.text = "数字键快捷购买  |  B 或 ESC 关闭"
	info_label.add_theme_font_size_override("font_size", 16)
	info_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.82))
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(info_label)

	_build_categories()


func _build_categories() -> void:
	for c in category_bar.get_children():
		c.queue_free()
	for cat in CATEGORIES:
		var btn := Button.new()
		btn.text = cat["label"]
		btn.custom_minimum_size = Vector2(96, 34)
		btn.toggle_mode = true
		btn.set_pressed_no_signal(str(cat["key"]) == current_category)
		btn.pressed.connect(func(): _select_category(str(cat["key"])))
		category_bar.add_child(btn)


func _select_category(key: String) -> void:
	current_category = key
	_build_categories()
	_refresh_grid()


# ================================================================ 打开关闭
func open_menu() -> void:
	if actor == null or not actor.alive:
		return
	if mm != null and not mm.is_buy_phase() and mm.get("training_mode") != true:
		EventBus.announcement.emit("购买阶段已结束", "warn")
		return
	is_open = true
	visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_on_money_changed(actor.loadout.money)
	_refresh_grid()
	EventBus.buy_menu_toggled.emit(true)


func close_menu() -> void:
	is_open = false
	visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	EventBus.buy_menu_toggled.emit(false)
	closed.emit()


func toggle() -> void:
	if is_open:
		close_menu()
	else:
		open_menu()


# ================================================================ 内容
func _refresh_grid() -> void:
	for c in grid.get_children():
		c.queue_free()
	_buttons.clear()
	if actor == null:
		return
	for btn in category_bar.get_children():
		btn.set_pressed_no_signal(btn.text == _label_of_category(current_category))

	if current_category == "gear":
		_build_gear()
	elif current_category == "grenade":
		_build_grenades()
	else:
		_build_weapons()


func _label_of_category(key: String) -> String:
	for c in CATEGORIES:
		if str(c["key"]) == key:
			return str(c["label"])
	return ""


func _build_weapons() -> void:
	var ids: Array = WeaponDatabase.get_by_class(current_category)
	for id in ids:
		var data := WeaponDatabase.get_weapon(id)
		var price: int = int(data["price"])
		var owned: bool = actor.loadout.has_weapon(id)
		_add_item(
			str(data["display_name"]),
			price,
			owned,
			"%d 伤害 / %d 发 / RPM %d" % [
				int(data["damage"]), int(data["magazine"]), int(data["rpm"])],
			func(): _buy_weapon(id))


func _build_gear() -> void:
	_add_item("轻甲 (无头盔)", GameConfig.ARMOR_LIGHT_PRICE,
		actor.loadout.armor > 0, "吸收 50% 伤害", func(): _buy_armor(false))
	_add_item("重甲 + 头盔", GameConfig.ARMOR_HEAVY_PRICE,
		actor.loadout.has_helmet, "吸收 55% 伤害, 防爆头",
		func(): _buy_armor(true))
	if actor.team == GameConfig.Team.GUARD:
		_add_item("拆弹器", GameConfig.DEFUSE_KIT_PRICE,
			actor.loadout.has_defuse_kit, "拆除时间 7s -> 4s",
			func(): _buy_kit())
	_add_item("补充弹药", 60, false, "所有武器备弹补满", func(): _buy_ammo())
	_add_item("复购上次装备", 0, false, "重复上一回合的购买序列", func(): _rebuy())


func _build_grenades() -> void:
	var all: Dictionary = WeaponDatabase.get_all_grenades()
	for key in all:
		var data: Dictionary = all[key]
		var owned: int = actor.loadout.get_grenade_count(key)
		var max_carry: int = int(data["max_carry"])
		_add_item(
			str(data["display_name"]),
			int(data["price"]),
			owned >= max_carry,
			"携带 %d / %d" % [owned, max_carry],
			func(): _buy_grenade(key))


func _add_item(title_text: String, price: int, owned: bool,
		desc: String, callback: Callable) -> void:
	var container := PanelContainer.new()
	container.custom_minimum_size = Vector2(260, 78)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.14, 0.18, 0.9)
	style.set_corner_radius_all(5)
	style.border_color = Color(0.3, 0.36, 0.44, 0.6)
	style.set_border_width_all(1)
	container.add_theme_stylebox_override("panel", style)
	grid.add_child(container)

	var btn := Button.new()
	btn.flat = true
	btn.custom_minimum_size = Vector2(260, 78)
	container.add_child(btn)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(vbox)

	var row := HBoxContainer.new()
	vbox.add_child(row)
	var name_label := Label.new()
	name_label.text = title_text
	name_label.add_theme_font_size_override("font_size", 19)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var price_label := Label.new()
	price_label.text = ("已拥有" if owned else ("$%d" % price)) if price > 0 else "免费"
	price_label.add_theme_font_size_override("font_size", 18)
	price_label.add_theme_color_override("font_color",
		Color(0.5, 0.5, 0.55) if owned else Color(0.45, 0.9, 0.55))
	row.add_child(price_label)

	var desc_label := Label.new()
	desc_label.text = desc
	desc_label.add_theme_font_size_override("font_size", 14)
	desc_label.add_theme_color_override("font_color", Color(0.68, 0.73, 0.8))
	vbox.add_child(desc_label)

	var affordable: bool = price <= 0 or actor.loadout.can_afford(price)
	if owned or not affordable:
		btn.modulate = Color(0.55, 0.55, 0.58)
		btn.disabled = owned
	if not affordable and not owned:
		btn.disabled = true

	btn.pressed.connect(callback)
	_buttons.append({"btn": btn, "price": price, "owned": owned})


# ================================================================ 购买动作
## 客户端联机时: 购买一律上行给服务器权威结算, 本地 loadout 不动。
## 服务器成功后会广播配装回来(money_changed / weapon_changed),
## HUD 与本菜单随之刷新。返回 true 表示已转发, 调用方直接 return。
func _route_to_server(kind: String, payload: String) -> bool:
	if not NetworkManager.is_client:
		return false
	NetworkManager.request_purchase(kind, payload)
	return true


func _buy_weapon(id: String) -> void:
	if _route_to_server("weapon", id):
		return
	var purchases := [{"kind": "weapon", "id": id}]
	if actor.loadout.buy_weapon(id):
		actor.loadout.record_purchase(purchases)
		_after_purchase("已购买 %s" % WeaponDatabase.get_weapon_name(id))
	else:
		EventBus.announcement.emit("金钱不足或无法购买", "warn")


func _buy_armor(heavy: bool) -> void:
	if _route_to_server("armor", "heavy" if heavy else "light"):
		return
	if actor.loadout.buy_armor(heavy):
		actor.health.armor = actor.loadout.armor
		actor.health.has_helmet = actor.loadout.has_helmet
		actor.health.has_kevlar = true
		_after_purchase("已购买护甲")
	else:
		EventBus.announcement.emit("金钱不足", "warn")


func _buy_kit() -> void:
	if _route_to_server("kit", ""):
		return
	if actor.loadout.buy_defuse_kit():
		_after_purchase("已购买拆弹器")
	else:
		EventBus.announcement.emit("金钱不足或已拥有", "warn")


func _buy_grenade(id: String) -> void:
	if _route_to_server("grenade", id):
		return
	if actor.loadout.buy_grenade(id):
		_after_purchase("已购买 %s" % WeaponDatabase.get_grenade(id).get("display_name", ""))
	else:
		EventBus.announcement.emit("金钱不足或已达携带上限", "warn")


func _buy_ammo() -> void:
	if _route_to_server("ammo", ""):
		return
	if actor.loadout.buy_ammo():
		_after_purchase("备弹已补充")
	else:
		EventBus.announcement.emit("无需补充或金钱不足", "warn")


func _rebuy() -> void:
	# 复购序列只存在本地(购买历史不下发), 联机时逐条上行
	if NetworkManager.is_client:
		for entry in actor.loadout.last_purchase:
			match str(entry["kind"]):
				"weapon":
					_route_to_server("weapon", str(entry["id"]))
				"grenade":
					_route_to_server("grenade", str(entry["id"]))
				"armor":
					_route_to_server("armor", "heavy" if bool(entry.get("heavy", false)) else "light")
				"kit":
					_route_to_server("kit", "")
		return
	if actor.loadout.rebuy_last():
		_after_purchase("已复购上次装备")
	else:
		EventBus.announcement.emit("没有可复购的记录", "warn")


func _after_purchase(msg: String) -> void:
	if actor.weapon_system != null:
		actor.weapon_system.call("refresh_weapons")
	EventBus.announcement.emit(msg, "buy")
	_refresh_grid()
	_on_money_changed(actor.loadout.money)


func _on_money_changed(v: int) -> void:
	if money_label != null:
		money_label.text = "$%d" % v


# ================================================================ 输入
func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE or event.physical_keycode == KEY_B:
			close_menu()
			get_viewport().set_input_as_handled()
			return
		if QUICK_BUY.has(event.physical_keycode):
			var entry: Array = QUICK_BUY[event.physical_keycode]
			_quick_buy(str(entry[0]), int(entry[1]))
			get_viewport().set_input_as_handled()


func _quick_buy(category: String, index: int) -> void:
	if category == "pistol" or category == "smg" or category == "rifle":
		var ids: Array = WeaponDatabase.get_by_class(category)
		if index < ids.size():
			_buy_weapon(str(ids[index]))
			current_category = category
			_refresh_grid()
