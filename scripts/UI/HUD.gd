extends CanvasLayer
class_name HUD
##
## HUD.gd — 战斗界面
##
## 布局(提示词要求):
##   左上  小地图(HudCanvas 绘制)
##   顶部  回合比分 + 剩余时间 + 目标装置计时
##   右上  击杀信息流
##   中央  准星(HudCanvas 绘制)
##   底部  生命值 / 护甲 / 弹药 / 武器名
##
## 所有控件由代码生成, 不使用任何图片或字体文件。
##

var actor: Actor = null
var mm: MatchManager = null
var objective: ObjectiveSystem = null

var hud_canvas: HudCanvas
var health_value: Label
var health_bar: ProgressBar
var armor_bar: ProgressBar
var armor_value: Label
var ammo_label: Label
var weapon_label: Label
var score_label: Label
var phase_label: Label
var timer_label: Label
var bomb_label: Label
var alive_label: Label
var announcement: Label
var killfeed: VBoxContainer
var flash_overlay: ColorRect
var low_hp_overlay: ColorRect
var spectate_panel: PanelContainer
var spectate_label: Label
var buy_hint: Label
var money_label: Label
var hint_label: Label
var performance_label: Label
var training_label: Label
var combat_stats_label: Label

var _announce_timer: float = 0.0
var _perf_accum: float = 0.0
var _perf_frames: int = 0
var _killfeed_items: Array = []


# ================================================================ 构建
func _ready() -> void:
	name = "HUD"
	layer = 10
	set_process(true)
	_build_ui()
	_connect_signals()


func setup(a: Actor, m: MatchManager, o: ObjectiveSystem) -> void:
	actor = a
	mm = m
	objective = o
	hud_canvas.setup(a, m, o)
	if a != null:
		a.health.health_changed.connect(_on_health_changed)
		a.health.armor_changed.connect(_on_armor_changed)
		a.loadout.money_changed.connect(_on_money_changed)
		_on_health_changed(a.health.health, a.health.max_health)
		_on_armor_changed(a.health.armor)
		_on_money_changed(a.loadout.money)


func _build_ui() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	hud_canvas = HudCanvas.new()
	hud_canvas.name = "HudCanvas"
	hud_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(hud_canvas)

	_flash_overlay_build(root)
	_low_hp_build(root)
	_build_top_bar(root)
	_build_bottom_left(root)
	_build_bottom_right(root)
	_build_killfeed(root)
	_build_announcement(root)
	_build_spectate(root)
	_build_hints(root)
	_build_performance_overlay(root)
	_build_training_overlay(root)
	_build_combat_stats_overlay(root)


func _flash_overlay_build(parent: Control) -> void:
	flash_overlay = ColorRect.new()
	flash_overlay.color = Color(1, 1, 1, 0)
	flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(flash_overlay)


func _low_hp_build(parent: Control) -> void:
	low_hp_overlay = ColorRect.new()
	low_hp_overlay.color = Color(0.65, 0.03, 0.03, 0)
	low_hp_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	low_hp_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(low_hp_overlay)


func _build_top_bar(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_top = 10
	panel.offset_bottom = 58
	panel.offset_left = 230
	panel.offset_right = -230
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.72)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 26)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(hbox)

	phase_label = Label.new()
	phase_label.text = "第 1 回合 · 购买阶段"
	phase_label.add_theme_font_size_override("font_size", 16)
	phase_label.add_theme_color_override("font_color", Color(0.65, 0.75, 0.86))
	hbox.add_child(phase_label)

	score_label = Label.new()
	score_label.text = "0 : 0"
	score_label.add_theme_font_size_override("font_size", 30)
	hbox.add_child(score_label)

	timer_label = Label.new()
	timer_label.text = "1:55"
	timer_label.add_theme_font_size_override("font_size", 26)
	hbox.add_child(timer_label)

	bomb_label = Label.new()
	bomb_label.text = ""
	bomb_label.add_theme_font_size_override("font_size", 24)
	bomb_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.2))
	hbox.add_child(bomb_label)

	alive_label = Label.new()
	alive_label.text = "5 v 5"
	alive_label.add_theme_font_size_override("font_size", 20)
	alive_label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.88))
	hbox.add_child(alive_label)


func _build_bottom_left(parent: Control) -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	box.offset_left = 22
	box.offset_bottom = -22
	box.offset_top = -104
	box.offset_right = 262
	box.add_theme_constant_override("separation", 5)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(box)

	var hp_row := HBoxContainer.new()
	hp_row.add_theme_constant_override("separation", 8)
	box.add_child(hp_row)

	var hp_icon := Label.new()
	hp_icon.text = "HP"
	hp_icon.add_theme_font_size_override("font_size", 16)
	hp_icon.add_theme_color_override("font_color", Color(0.7, 0.78, 0.88))
	hp_icon.custom_minimum_size = Vector2(26, 0)
	hp_row.add_child(hp_icon)

	health_bar = ProgressBar.new()
	health_bar.max_value = GameConfig.MAX_HP
	health_bar.value = GameConfig.MAX_HP
	health_bar.show_percentage = false
	health_bar.custom_minimum_size = Vector2(180, 14)
	_style_bar(health_bar, Color(0.15, 0.72, 0.35))
	hp_row.add_child(health_bar)

	health_value = Label.new()
	health_value.text = "100"
	health_value.add_theme_font_size_override("font_size", 18)
	health_value.custom_minimum_size = Vector2(38, 0)
	hp_row.add_child(health_value)

	var ar_row := HBoxContainer.new()
	ar_row.add_theme_constant_override("separation", 8)
	box.add_child(ar_row)

	var ar_icon := Label.new()
	ar_icon.text = "AR"
	ar_icon.add_theme_font_size_override("font_size", 16)
	ar_icon.add_theme_color_override("font_color", Color(0.7, 0.78, 0.88))
	ar_icon.custom_minimum_size = Vector2(26, 0)
	ar_row.add_child(ar_icon)

	armor_bar = ProgressBar.new()
	armor_bar.max_value = GameConfig.MAX_ARMOR
	armor_bar.value = 0
	armor_bar.show_percentage = false
	armor_bar.custom_minimum_size = Vector2(180, 14)
	_style_bar(armor_bar, Color(0.32, 0.55, 0.85))
	ar_row.add_child(armor_bar)

	armor_value = Label.new()
	armor_value.text = "0"
	armor_value.add_theme_font_size_override("font_size", 18)
	armor_value.custom_minimum_size = Vector2(38, 0)
	ar_row.add_child(armor_value)

	money_label = Label.new()
	money_label.text = "$800"
	money_label.add_theme_font_size_override("font_size", 19)
	money_label.add_theme_color_override("font_color", Color(0.35, 0.85, 0.45))
	box.add_child(money_label)


func _style_bar(bar: ProgressBar, color: Color) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.10, 0.11, 0.13, 0.85)
	bg.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("background", bg)
	var fg := StyleBoxFlat.new()
	fg.bg_color = color
	fg.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("fill", fg)


func _build_bottom_right(parent: Control) -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	box.offset_right = -22
	box.offset_bottom = -22
	box.offset_left = -330
	box.offset_top = -96
	box.alignment = BoxContainer.ALIGNMENT_END
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(box)

	weapon_label = Label.new()
	weapon_label.text = "P01"
	weapon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	weapon_label.add_theme_font_size_override("font_size", 19)
	weapon_label.add_theme_color_override("font_color", Color(0.82, 0.86, 0.92))
	box.add_child(weapon_label)

	ammo_label = Label.new()
	ammo_label.text = "12 / 48"
	ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ammo_label.add_theme_font_size_override("font_size", 34)
	ammo_label.add_theme_color_override("font_color", Color(1, 1, 1))
	box.add_child(ammo_label)
	

func _build_killfeed(parent: Control) -> void:
	killfeed = VBoxContainer.new()
	killfeed.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	killfeed.offset_right = -18
	killfeed.offset_top = 12
	killfeed.offset_left = -430
	killfeed.alignment = BoxContainer.ALIGNMENT_BEGIN
	killfeed.add_theme_constant_override("separation", 4)
	killfeed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(killfeed)


func _build_announcement(parent: Control) -> void:
	announcement = Label.new()
	announcement.set_anchors_preset(Control.PRESET_TOP_WIDE)
	announcement.offset_top = 74
	announcement.offset_bottom = 118
	announcement.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	announcement.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	announcement.add_theme_font_size_override("font_size", 30)
	announcement.add_theme_color_override("font_color", Color(1, 0.95, 0.85))
	announcement.modulate = Color(1, 1, 1, 0)
	parent.add_child(announcement)


func _build_spectate(parent: Control) -> void:
	spectate_panel = PanelContainer.new()
	spectate_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	spectate_panel.offset_left = 320
	spectate_panel.offset_right = -320
	spectate_panel.offset_top = -150
	spectate_panel.offset_bottom = -104
	spectate_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.78)
	style.set_corner_radius_all(6)
	spectate_panel.add_theme_stylebox_override("panel", style)
	parent.add_child(spectate_panel)

	spectate_label = Label.new()
	spectate_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spectate_label.add_theme_font_size_override("font_size", 20)
	spectate_label.text = "观战中"
	spectate_panel.add_child(spectate_label)


func _build_performance_overlay(parent: Control) -> void:
	performance_label = Label.new()
	performance_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	performance_label.offset_left = -168
	performance_label.offset_right = -18
	performance_label.offset_top = 14
	performance_label.offset_bottom = 54
	performance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	performance_label.add_theme_font_size_override("font_size", 13)
	performance_label.add_theme_color_override("font_color", Color(0.62, 0.74, 0.82, 0.88))
	performance_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	performance_label.visible = bool(GameManager.get_setting("show_fps", false))
	parent.add_child(performance_label)


func _build_training_overlay(parent: Control) -> void:
	training_label = Label.new()
	training_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	training_label.offset_left = 220
	training_label.offset_right = 480
	training_label.offset_top = 18
	training_label.offset_bottom = 76
	training_label.add_theme_font_size_override("font_size", 14)
	training_label.add_theme_color_override("font_color", Color(0.72, 0.88, 0.95, 0.92))
	training_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	training_label.visible = false
	parent.add_child(training_label)


func _build_combat_stats_overlay(parent: Control) -> void:
	combat_stats_label = Label.new()
	combat_stats_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	combat_stats_label.offset_left = -220
	combat_stats_label.offset_right = -18
	combat_stats_label.offset_top = 62
	combat_stats_label.offset_bottom = 88
	combat_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	combat_stats_label.add_theme_font_size_override("font_size", 13)
	combat_stats_label.add_theme_color_override("font_color", Color(0.76, 0.82, 0.9, 0.85))
	combat_stats_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	combat_stats_label.visible = false
	parent.add_child(combat_stats_label)


func _build_hints(parent: Control) -> void:
	buy_hint = Label.new()
	buy_hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	buy_hint.offset_top = -196
	buy_hint.offset_bottom = -166
	buy_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	buy_hint.add_theme_font_size_override("font_size", 20)
	buy_hint.add_theme_color_override("font_color", Color(0.45, 0.9, 0.6))
	buy_hint.text = "按 B 打开购买菜单"
	buy_hint.visible = false
	parent.add_child(buy_hint)

	hint_label = Label.new()
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint_label.offset_top = -232
	hint_label.offset_bottom = -206
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_font_size_override("font_size", 17)
	hint_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.92, 0.85))
	hint_label.text = ""
	parent.add_child(hint_label)


# ================================================================ 信号
func _connect_signals() -> void:
	EventBus.killfeed_request.connect(_on_killfeed)
	EventBus.announcement.connect(_on_announcement)
	EventBus.score_changed.connect(_on_score_changed)
	EventBus.spectate_target_changed.connect(_on_spectate_changed)


func _on_killfeed(killer_name: String, victim_name: String, weapon_id: String,
		is_headshot: bool, killer_team: int, victim_team: int) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 6)

	var kc: Color = GameConfig.TEAM_COLOR.get(killer_team, Color(0.9, 0.9, 0.9))
	var vc: Color = GameConfig.TEAM_COLOR.get(victim_team, Color(0.9, 0.9, 0.9))

	var k_label := Label.new()
	k_label.text = killer_name
	k_label.add_theme_font_size_override("font_size", 16)
	k_label.add_theme_color_override("font_color", kc)
	row.add_child(k_label)

	var w_label := Label.new()
	w_label.text = _weapon_display(weapon_id, is_headshot)
	w_label.add_theme_font_size_override("font_size", 16)
	w_label.add_theme_color_override("font_color",
		Color(1.0, 0.4, 0.3) if is_headshot else Color(0.88, 0.9, 0.95))
	row.add_child(w_label)

	var v_label := Label.new()
	v_label.text = victim_name
	v_label.add_theme_font_size_override("font_size", 16)
	v_label.add_theme_color_override("font_color", vc)
	row.add_child(v_label)

	killfeed.add_child(row)
	killfeed.move_child(row, 0)
	_killfeed_items.append({"node": row, "life": 6.0})
	while _killfeed_items.size() > 6:
		var old: Dictionary = _killfeed_items.pop_front()
		if is_instance_valid(old["node"]):
			old["node"].queue_free()


func _weapon_display(weapon_id: String, is_headshot: bool) -> String:
	var name_str: String
	match weapon_id:
		"he": name_str = "手雷"
		"molotov": name_str = "燃烧弹"
		"bomb": name_str = "装置"
		_: name_str = WeaponDatabase.get_weapon_name(weapon_id)
	if is_headshot:
		return "[HS] " + name_str
	return "[%s]" % name_str


func _on_announcement(text: String, _kind: String) -> void:
	announcement.text = text
	announcement.modulate = Color(1, 1, 1, 1)
	_announce_timer = 2.6


func _on_score_changed(s_strike: int, s_guard: int) -> void:
	score_label.text = "%d : %d" % [s_strike, s_guard]


func _on_spectate_changed(_target: Node) -> void:
	pass


func _on_health_changed(new_value: float, _max_value: float) -> void:
	health_bar.value = new_value
	health_value.text = str(int(new_value))
	if new_value <= 0.0:
		health_value.text = "0"


func _on_armor_changed(new_value: int) -> void:
	armor_bar.value = new_value
	armor_value.text = str(new_value)


func _on_money_changed(new_value: int) -> void:
	money_label.text = "$%d" % new_value


# ================================================================ 每帧
func _process(delta: float) -> void:
	_update_performance_overlay(delta)
	_update_training_overlay()
	_update_combat_stats_overlay()
	if actor == null or mm == null:
		return

	# 弹药 / 武器
	var ws = actor.weapon_system
	if ws != null:
		var ammo: Vector2i = ws.get_hud_ammo()
		ammo_label.text = "%d / %d" % [ammo.x, ammo.y]
		weapon_label.text = ws.get_weapon_display_name()
		var mag_max: int = int(WeaponDatabase.get_weapon(ws.current_id).get("magazine", 30))
		ammo_label.add_theme_color_override("font_color",
			Color(1.0, 0.35, 0.3) if ammo.x <= mag_max * 0.25 else Color(1, 1, 1))
		# 准星随扩散张开
		var spread: float = ws.get_current_spread()
		hud_canvas.crosshair_gap = 3.0 + spread * 1.35
		hud_canvas.crosshair_dot = spread > 5.0

	# 计时
	if objective != null and objective.is_planted():
		timer_label.text = mm.get_bomb_time_text()
		timer_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
		bomb_label.text = "装置已安装"
	else:
		timer_label.text = mm.get_round_time_text()
		timer_label.add_theme_color_override("font_color",
			Color(1.0, 0.4, 0.35) if mm.round_time_remaining < 20.0 else Color(1, 1, 1))
		bomb_label.text = ""

	var alive: Vector2i = mm.get_alive_counts()
	alive_label.text = "%d v %d" % [alive.x, alive.y]
	score_label.text = "%d : %d" % [mm.get_score().x, mm.get_score().y]
	phase_label.text = "第 %d 回合 · %s" % [mm.round_number, mm.get_phase_name()]
	match mm.phase:
		MatchManager.Phase.BUY:
			phase_label.add_theme_color_override("font_color", Color(0.45, 0.9, 0.62))
		MatchManager.Phase.LIVE:
			phase_label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.38))
		MatchManager.Phase.ROUND_OVER, MatchManager.Phase.MATCH_OVER:
			phase_label.add_theme_color_override("font_color", Color(1.0, 0.83, 0.42))
		_:
			phase_label.add_theme_color_override("font_color", Color(0.65, 0.75, 0.86))

	# 购买提示
	buy_hint.visible = mm.is_buy_phase() and actor.alive

	# 交互提示
	hint_label.text = _interaction_hint()

	# 闪光
	var fa: float = actor.get_flash_alpha()
	flash_overlay.color = Color(1, 1, 1, fa * 0.96)

	# 低血量渐晕
	var hp_ratio: float = clampf(actor.health.health / GameConfig.MAX_HP, 0.0, 1.0)
	if hp_ratio < 0.35 and actor.alive:
		var intensity: float = (1.0 - hp_ratio / 0.35) * 0.42
		var pulse: float = 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.006)
		low_hp_overlay.color = Color(0.65, 0.03, 0.03, intensity * pulse)
	else:
		low_hp_overlay.color = Color(0.65, 0.03, 0.03, 0.0)

	# 公告淡出
	if _announce_timer > 0.0:
		_announce_timer -= delta
		var a: float = clampf(_announce_timer / 0.6, 0.0, 1.0)
		announcement.modulate = Color(1, 1, 1, a)
	else:
		announcement.modulate = Color(1, 1, 1, 0)

	# 击杀信息淡出
	for item in _killfeed_items:
		item["life"] -= delta
		var node: Control = item["node"]
		if not is_instance_valid(node):
			continue
		if float(item["life"]) < 1.2:
			node.modulate = Color(1, 1, 1, clampf(float(item["life"]) / 1.2, 0.0, 1.0))
	_killfeed_items = _killfeed_items.filter(func(x): return float(x["life"]) > 0.0)

	# 观战面板
	if not actor.alive and mm.spectator != null and mm.spectator.enabled:
		spectate_panel.visible = true
		var info: Dictionary = mm.spectator.get_spectate_info()
		if not info.is_empty():
			spectate_label.text = "观战: %s  |  HP %d  |  %s  |  空格切换视角" % [
				info.get("name", ""), int(info.get("health", 0)), info.get("weapon", "")]
	else:
		spectate_panel.visible = false


func _update_performance_overlay(delta: float) -> void:
	if performance_label == null:
		return
	var enabled: bool = bool(GameManager.get_setting("show_fps", false))
	performance_label.visible = enabled
	if not enabled:
		return
	_perf_accum += delta
	_perf_frames += 1
	if _perf_accum < 0.25:
		return
	var fps: float = float(_perf_frames) / maxf(_perf_accum, 0.001)
	var tier := GraphicsQuality.tier_name()
	var net := NetworkManager.connection_summary()
	performance_label.text = "FPS %d  ·  %s  ·  %s  ·  %d 人" % [roundi(fps), tier, net, NetworkManager.peer_count()]
	_perf_accum = 0.0
	_perf_frames = 0


func _update_training_overlay() -> void:
	if training_label == null:
		return
	var training: bool = mm != null and bool(mm.get("training_mode"))
	training_label.visible = training
	if not training or actor == null:
		return
	var shots: int = int(GameManager.training_session.get("shots", 0))
	var hits: int = int(GameManager.training_session.get("hits", 0))
	var accuracy: float = float(hits) / float(maxi(shots, 1)) * 100.0
	training_label.text = "训练场 · 无限弹药\n命中 %d / %d  ·  命中率 %.1f%%" % [hits, shots, accuracy]


func _update_combat_stats_overlay() -> void:
	if combat_stats_label == null:
		return
	var show_stats: bool = bool(GameManager.get_setting("show_fps", false))
	var in_match: bool = mm != null and not bool(mm.get("training_mode"))
	combat_stats_label.visible = show_stats and in_match and actor != null
	if not combat_stats_label.visible:
		return
	var stats := mm.get_actor_stats(actor)
	combat_stats_label.text = "K %d  ·  A %d  ·  DMG %d" % [int(stats.get("kills", 0)), int(stats.get("assists", 0)), roundi(float(stats.get("damage", 0.0)))]


func _interaction_hint() -> String:
	if not actor.alive:
		return ""
	if objective == null:
		return ""
	if actor.team == GameConfig.Team.STRIKE and actor.loadout.has_bomb:
		if objective.can_plant(actor):
			return "按住 [E] 安装目标装置"
	elif actor.team == GameConfig.Team.GUARD and objective.is_planted():
		if objective.can_defuse(actor):
			var kit: String = " (拆弹器 4s)" if actor.loadout.has_defuse_kit else " (7s)"
			return "按住 [E] 拆除目标装置" + kit
	if actor.loadout.has_bomb:
		return "你携带目标装置 - 前往 A / B 点"
	return ""
