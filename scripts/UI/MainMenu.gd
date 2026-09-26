extends Control
class_name MainMenu
##
## MainMenu.gd — 主菜单
##
## 提供: 阵营选择 / Bot 数量 / 难度 / 灵敏度与 FOV / 画质档位 / 开始比赛 / 退出
## 全部控件代码生成, 背景用 _draw 绘制的工业风网格。
##

@onready var sensitivity_slider: HSlider
@onready var ads_sensitivity_slider: HSlider
@onready var fov_slider: HSlider
@onready var volume_slider: HSlider
@onready var sens_value: Label
@onready var ads_sens_value: Label
@onready var fov_value: Label
@onready var volume_value: Label
var fps_toggle: CheckButton
var invert_y_toggle: CheckButton
var crosshair_dynamic_toggle: CheckButton
var crosshair_scale_button: Button
var crosshair_color_button: Button

var team_index: int = 0
var bot_count: int = 9
var difficulty_index: int = 1

var team_button: Button
var bot_button: Button
var diff_button: Button
var map_button: Button
var gfx_button: Button
var gfx_hint: Label
var stats_label: Label
var map_index: int = 0
var steam_label: Label = null

var ip_edit: LineEdit = null
var matchmaking_panel: PanelContainer = null
var matchmaking_label: Label = null
var _matchmaking_timer: float = 0.0
var _matchmaking_pending: bool = false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_process(true)
	_build_ui()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_refresh_stats()
	NetworkManager.join_succeeded.connect(_on_join_ok)
	NetworkManager.join_failed.connect(_on_join_failed)
	# 专用服务器: -- --server 启动, 无渲染无 UI, 直接开房
	if "--server" in OS.get_cmdline_user_args():
		_start_dedicated()
		return


##
## 专用服务器启动。
##
##   -- --server [--port 24565] [--bots 9] [--map project_zero]
##
##   --bots 0  纯观察者模式: 不生成任何 Bot, 停在热身等待,
##             等网络玩家连进来、两边各够 1 人自动开赛。
##
func _start_dedicated() -> void:
	var port := 24565
	var bots := 9
	var map_id := "project_zero"
	var uargs := OS.get_cmdline_user_args()
	for i in uargs.size():
		if uargs[i] == "--port" and i + 1 < uargs.size():
			port = int(uargs[i + 1])
		elif uargs[i] == "--bots" and i + 1 < uargs.size():
			bots = clampi(int(uargs[i + 1]), 0, 10)
		elif uargs[i] == "--map" and i + 1 < uargs.size():
			map_id = uargs[i + 1]

	var err: int = NetworkManager.host_dedicated(port)
	if err != OK:
		push_error("[Dedicated] 监听失败 %d" % err)
		get_tree().quit(1)
		return

	if bots == 0:
		print("[Dedicated] 专用服务器已启动, 端口 %d, 地图 %s, 纯观察者模式 (无 Bot, 等待玩家)" % [port, map_id])
	else:
		print("[Dedicated] 专用服务器已启动, 端口 %d, 地图 %s, Bot %d 个" % [port, map_id, bots])

	GameManager.pending_match = {
		"map_id": map_id,
		"bot_count": bots,
		"team": GameConfig.Team.STRIKE,
		"dedicated_bots": bots,
	}
	var packed := load("res://scenes/Game.tscn") as PackedScene
	if packed != null:
		get_tree().change_scene_to_packed(packed)


func _on_join_ok() -> void:
	GameManager.pending_match = {
		"map_id": "project_zero",
		"bot_count": 0,
		"team": GameManager.selected_team,
	}
	var packed := load("res://scenes/Game.tscn") as PackedScene
	if packed != null:
		get_tree().change_scene_to_packed(packed)


func _on_join_failed(reason: String) -> void:
	# 连接失败可能发生在点击加入后的异步阶段，必须给出可见反馈，
	# 否则玩家会一直停留在主菜单并误以为按钮没有响应。
	if stats_label != null:
		stats_label.text = "网络连接失败：%s" % reason
	if matchmaking_panel != null:
		matchmaking_panel.visible = false


func _build_ui() -> void:
	# 背景
	var bg := ColorRect.new()
	bg.color = Color(0.045, 0.055, 0.075)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var grid_bg := GridBackground.new()
	grid_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(grid_bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(600, 740)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.085, 0.11, 0.92)
	style.set_corner_radius_all(10)
	style.border_color = Color(0.3, 0.38, 0.48, 0.85)
	style.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	# 标题
	var title := Label.new()
	title.text = "PROJECT STRIKE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "5v5 战术竞技射击  ·  3 张竞技图 + 训练场  ·  22 把武器"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", Color(0.6, 0.68, 0.78))
	vbox.add_child(subtitle)

	vbox.add_child(HSeparator.new())
	_add_section_header(vbox, "对 局 设 置")

	# 选项行
	team_button = _make_option_row(vbox, "阵营", _team_text(), func(): _cycle_team())
	bot_button = _make_option_row(vbox, "Bot 数量", _bot_text(), func(): _cycle_bots())
	diff_button = _make_option_row(vbox, "Bot 难度", _diff_text(), func(): _cycle_difficulty())
	map_button = _make_option_row(vbox, "地图", _map_text(), func(): _cycle_map())
	gfx_button = _make_option_row(vbox, "画质", GraphicsQuality.tier_name(), func(): _cycle_gfx())
	gfx_hint = Label.new()
	gfx_hint.text = "画质档位：%s" % GraphicsQuality.tier_description()
	gfx_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	gfx_hint.add_theme_font_size_override("font_size", 12)
	gfx_hint.add_theme_color_override("font_color", Color(0.48, 0.62, 0.72))
	vbox.add_child(gfx_hint)

	vbox.add_child(HSeparator.new())
	_add_section_header(vbox, "控 制 与 显 示")

	# 设置滑块
	sens_value = Label.new()
	fov_value = Label.new()
	volume_value = Label.new()
	sensitivity_slider = _make_slider(vbox, "鼠标灵敏度", sens_value,
		0.2, 3.0, 0.05, float(GameManager.get_setting("mouse_sensitivity", 1.0)),
		func(v: float): GameManager.set_setting("mouse_sensitivity", v))
	ads_sens_value = Label.new()
	ads_sensitivity_slider = _make_slider(vbox, "开镜灵敏度", ads_sens_value,
		0.2, 1.2, 0.05, float(GameManager.get_setting("ads_sensitivity_mult", 0.78)),
		func(v: float): GameManager.set_setting("ads_sensitivity_mult", v))
	fov_slider = _make_slider(vbox, "视野 FOV", fov_value,
		70.0, 120.0, 1.0, float(GameManager.get_setting("fov", 90.0)),
		func(v: float): GameManager.set_setting("fov", v))
	volume_slider = _make_slider(vbox, "主音量", volume_value,
		0.0, 1.0, 0.05, float(GameManager.get_setting("master_volume", 0.85)),
		func(v: float): GameManager.set_setting("master_volume", v))
	fps_toggle = CheckButton.new()
	fps_toggle.text = "显示性能信息"
	fps_toggle.button_pressed = bool(GameManager.get_setting("show_fps", false))
	fps_toggle.toggled.connect(func(enabled: bool): GameManager.set_setting("show_fps", enabled))
	fps_toggle.add_theme_font_size_override("font_size", 14)
	vbox.add_child(fps_toggle)
	invert_y_toggle = CheckButton.new()
	invert_y_toggle.text = "反转 Y 轴"
	invert_y_toggle.button_pressed = bool(GameManager.get_setting("invert_y", false))
	invert_y_toggle.toggled.connect(func(enabled: bool): GameManager.set_setting("invert_y", enabled))
	invert_y_toggle.add_theme_font_size_override("font_size", 14)
	vbox.add_child(invert_y_toggle)
	crosshair_dynamic_toggle = CheckButton.new()
	crosshair_dynamic_toggle.text = "动态准星"
	crosshair_dynamic_toggle.button_pressed = bool(GameManager.get_setting("crosshair_dynamic", true))
	crosshair_dynamic_toggle.toggled.connect(func(enabled: bool): GameManager.set_setting("crosshair_dynamic", enabled))
	crosshair_dynamic_toggle.add_theme_font_size_override("font_size", 14)
	vbox.add_child(crosshair_dynamic_toggle)

	crosshair_scale_button = Button.new()
	crosshair_scale_button.text = "准星尺寸：%d%%" % roundi(float(GameManager.get_setting("crosshair_scale", 1.0)) * 100.0)
	crosshair_scale_button.custom_minimum_size = Vector2(0, 30)
	crosshair_scale_button.pressed.connect(_cycle_crosshair_scale)
	crosshair_scale_button.add_theme_font_size_override("font_size", 14)
	vbox.add_child(crosshair_scale_button)

	crosshair_color_button = Button.new()
	crosshair_color_button.custom_minimum_size = Vector2(0, 30)
	crosshair_color_button.pressed.connect(_cycle_crosshair_color)
	crosshair_color_button.add_theme_font_size_override("font_size", 14)
	vbox.add_child(crosshair_color_button)
	_update_slider_labels()
	_update_crosshair_labels()

	vbox.add_child(HSeparator.new())

	# 战绩
	stats_label = Label.new()
	stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats_label.add_theme_font_size_override("font_size", 15)
	stats_label.add_theme_color_override("font_color", Color(0.62, 0.7, 0.8))
	vbox.add_child(stats_label)

	# Steam 状态行(Steam 引擎运行时显示, 否则提示未连接)
	steam_label = Label.new()
	steam_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	steam_label.add_theme_font_size_override("font_size", 13)
	steam_label.add_theme_color_override("font_color", Color(0.55, 0.9, 0.7))
	vbox.add_child(steam_label)
	_refresh_steam()

	# 联机行: 建立主机 / 加入
	var net_row := HBoxContainer.new()
	net_row.add_theme_constant_override("separation", 8)
	vbox.add_child(net_row)

	var host_btn := Button.new()
	host_btn.text = "建立主机 (局域网)"
	host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_btn.custom_minimum_size = Vector2(0, 36)
	host_btn.add_theme_font_size_override("font_size", 15)
	host_btn.pressed.connect(_on_host)
	net_row.add_child(host_btn)

	ip_edit = LineEdit.new()
	ip_edit.text = "127.0.0.1"
	ip_edit.placeholder_text = "服务器 IP"
	ip_edit.custom_minimum_size = Vector2(120, 36)
	net_row.add_child(ip_edit)

	var join_btn := Button.new()
	join_btn.text = "加入"
	join_btn.custom_minimum_size = Vector2(70, 36)
	join_btn.add_theme_font_size_override("font_size", 15)
	join_btn.pressed.connect(_on_join)
	net_row.add_child(join_btn)

	# Steam 面板(成就/好友/统计) - 仅 Steam 引擎下显示
	if SteamManager.is_steam_active():
		var steam_btn := Button.new()
		steam_btn.text = "Steam 好友 / 成就"
		steam_btn.custom_minimum_size = Vector2(0, 32)
		steam_btn.add_theme_font_size_override("font_size", 14)
		steam_btn.pressed.connect(func(): SteamManager.open_overlay("Friends"))
		vbox.add_child(steam_btn)

	# 观看回放
	var replay_btn := Button.new()
	replay_btn.text = "观看上一局录像"
	replay_btn.custom_minimum_size = Vector2(0, 36)
	replay_btn.add_theme_font_size_override("font_size", 15)
	replay_btn.pressed.connect(func():
		if ReplaySystem.list_replays().is_empty():
			stats_label.text = "没有录像 - 先打一场比赛"
			return
		get_tree().change_scene_to_file("res://scenes/ReplayViewer.tscn"))
	vbox.add_child(replay_btn)

	# 按钮
	var play_btn := Button.new()
	play_btn.text = "匹 配 比 赛"
	play_btn.custom_minimum_size = Vector2(0, 54)
	play_btn.add_theme_font_size_override("font_size", 24)
	play_btn.pressed.connect(_on_play)
	vbox.add_child(play_btn)

	var quit_btn := Button.new()
	quit_btn.text = "退出"
	quit_btn.custom_minimum_size = Vector2(0, 38)
	quit_btn.pressed.connect(func(): get_tree().quit())
	vbox.add_child(quit_btn)

	# 匹配中面板(假匹配: 本地延迟后直接开局, 接口结构与真实匹配一致)
	matchmaking_panel = PanelContainer.new()
	matchmaking_panel.set_anchors_preset(Control.PRESET_CENTER)
	matchmaking_panel.custom_minimum_size = Vector2(320, 120)
	matchmaking_panel.position = Vector2(-160, -60)
	matchmaking_panel.visible = false
	var mm_style := StyleBoxFlat.new()
	mm_style.bg_color = Color(0.08, 0.10, 0.13, 0.95)
	mm_style.set_corner_radius_all(8)
	matchmaking_panel.add_theme_stylebox_override("panel", mm_style)
	add_child(matchmaking_panel)
	var mm_box := VBoxContainer.new()
	matchmaking_panel.add_child(mm_box)
	matchmaking_label = Label.new()
	matchmaking_label.text = "正在匹配..."
	matchmaking_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	matchmaking_label.add_theme_font_size_override("font_size", 20)
	mm_box.add_child(matchmaking_label)
	var cancel_btn := Button.new()
	cancel_btn.text = "取消"
	cancel_btn.pressed.connect(func():
		_matchmaking_pending = false
		matchmaking_panel.visible = false)
	mm_box.add_child(cancel_btn)

	var help := Label.new()
	help.text = "WASD 移动 · Shift 静步 · Ctrl 蹲 · 空格跳 · 左键射击 · 右键开镜 · R 换弹 · B 购买 · E 安装/拆除 · TAB 计分板"
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_font_size_override("font_size", 13)
	help.add_theme_color_override("font_color", Color(0.5, 0.56, 0.65))
	vbox.add_child(help)


func _add_section_header(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.45, 0.7, 0.85))
	parent.add_child(label)


func _make_option_row(parent: Control, label_text: String, value_text: String,
		callback: Callable) -> Button:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	parent.add_child(hbox)

	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 17)
	label.custom_minimum_size = Vector2(110, 0)
	hbox.add_child(label)

	var btn := Button.new()
	btn.text = value_text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, 36)
	btn.add_theme_font_size_override("font_size", 17)
	btn.pressed.connect(callback)
	hbox.add_child(btn)
	return btn


func _make_slider(parent: Control, label_text: String, value_label: Label,
		min_v: float, max_v: float, step: float, current: float,
		callback: Callable) -> HSlider:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	parent.add_child(hbox)

	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 15)
	label.custom_minimum_size = Vector2(110, 0)
	hbox.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = current
	slider.custom_minimum_size = Vector2(200, 26)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(slider)

	value_label.custom_minimum_size = Vector2(56, 0)
	value_label.add_theme_font_size_override("font_size", 15)
	value_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.95))
	hbox.add_child(value_label)

	slider.value_changed.connect(
		func(v: float):
			callback.call(v)
			_update_slider_labels())
	return slider


func _update_slider_labels() -> void:
	sens_value.text = "%.2f" % float(GameManager.get_setting("mouse_sensitivity", 1.0))
	if ads_sens_value != null:
		ads_sens_value.text = "%.2fx" % float(GameManager.get_setting("ads_sensitivity_mult", 0.78))
	fov_value.text = "%d" % int(GameManager.get_setting("fov", 90.0))
	volume_value.text = "%d%%" % int(float(GameManager.get_setting("master_volume", 0.85)) * 100)


# ---------------------------------------------------------------- 选项
func _team_text() -> String:
	return "STRIKE (进攻方)" if team_index == 0 else "GUARD (防守方)"


func _bot_text() -> String:
	return "9 个 (5v5)" if bot_count == 9 else "%d 个" % bot_count


func _diff_text() -> String:
	return ["简单", "普通", "困难"][difficulty_index]


func _cycle_team() -> void:
	team_index = (team_index + 1) % 2
	team_button.text = _team_text()


func _cycle_bots() -> void:
	bot_count += 1
	if bot_count > 9:
		bot_count = 1
	bot_button.text = _bot_text()


func _cycle_difficulty() -> void:
	difficulty_index = (difficulty_index + 1) % 3
	diff_button.text = _diff_text()


func _refresh_steam() -> void:
	if SteamManager.is_steam_active():
		steam_label.text = "Steam 在线: %s  (ID %s)" % [SteamManager.persona_name, SteamManager.steam_id]
	else:
		steam_label.text = "Steam 未连接 (使用 GodotSteam 引擎运行可启用)"
		steam_label.add_theme_color_override("font_color", Color(0.6, 0.62, 0.68))


func _map_text() -> String:
	var names := ["PROJECT ZERO (工业园)", "NIGHT HARBOR (夜港)",
		"RED DISTRICT (霓虹街区)", "TRAINING RANGE (训练场)"]
	return names[map_index]


func _cycle_map() -> void:
	map_index = (map_index + 1) % 4
	map_button.text = _map_text()


## 画质: 低 / 中 / 高, 即时生效并持久化(环境 / 后处理 / 抗锯齿联动)
func _cycle_gfx() -> void:
	GraphicsQuality.cycle()
	gfx_button.text = GraphicsQuality.tier_name()
	if gfx_hint != null:
		gfx_hint.text = "画质档位：%s" % GraphicsQuality.tier_description()


func _cycle_crosshair_scale() -> void:
	var current := float(GameManager.get_setting("crosshair_scale", 1.0))
	var next := 0.75 if current >= 1.25 else (1.0 if current < 0.9 else 1.25)
	GameManager.set_setting("crosshair_scale", next)
	if crosshair_scale_button != null:
		crosshair_scale_button.text = "准星尺寸：%d%%" % roundi(next * 100.0)


func _cycle_crosshair_color() -> void:
	var colors := ["#26ff80", "#55c7ff", "#ffd34d", "#ff6b6b"]
	var current := str(GameManager.get_setting("crosshair_color", colors[0]))
	var index := colors.find(current)
	index = (index + 1) % colors.size()
	GameManager.set_setting("crosshair_color", colors[index])
	_update_crosshair_labels()


func _update_crosshair_labels() -> void:
	if crosshair_scale_button != null:
		var scale_value := float(GameManager.get_setting("crosshair_scale", 1.0))
		crosshair_scale_button.text = "准星尺寸：%d%%" % roundi(scale_value * 100.0)
	if crosshair_color_button != null:
		var colors := ["#26ff80", "#55c7ff", "#ffd34d", "#ff6b6b"]
		var names := ["绿色", "青色", "黄色", "红色"]
		var index := colors.find(str(GameManager.get_setting("crosshair_color", colors[0])))
		crosshair_color_button.text = "准星颜色：%s" % names[maxi(index, 0)]


func _refresh_stats() -> void:
	var s: Dictionary = GameManager.stats
	stats_label.text = "段位 %s · MMR %d   |   %d 胜 / %d 负  ·  K/D %.2f  ·  命中率 %.1f%%" % [
		RankSystem.tier_name(), RankSystem.mmr,
		int(s["wins"]), int(s["losses"]), GameManager.get_kd(),
		GameManager.get_accuracy()]


# ---------------------------------------------------------------- 开始
func _on_play() -> void:
	if _matchmaking_pending:
		return
	# 假匹配: 显示匹配面板 1.2~2.4 秒, 然后本地开局(接口与真实匹配一致)
	_matchmaking_pending = true
	_matchmaking_timer = randf_range(1.2, 2.4)
	matchmaking_panel.visible = true


func _process(delta: float) -> void:
	if _matchmaking_pending:
		_matchmaking_timer -= delta
		if matchmaking_label != null:
			matchmaking_label.text = "正在匹配... %0.1fs" % maxf(_matchmaking_timer, 0.0)
		if _matchmaking_timer <= 0.0:
			_matchmaking_pending = false
			matchmaking_panel.visible = false
			_do_start_match()


func _do_start_match() -> void:
	GameManager.bot_difficulty = difficulty_index
	GameManager.selected_team = GameConfig.Team.STRIKE if team_index == 0 else GameConfig.Team.GUARD
	var map_ids := ["project_zero", "night_harbor", "red_district", "training_range"]
	var map_id: String = map_ids[map_index]
	var bots: int = 0 if map_id == "training_range" else bot_count
	GameManager.start_match(map_id, bots, GameManager.selected_team)


func _on_host() -> void:
	var err: int = NetworkManager.host_game()
	if err != OK:
		stats_label.text = "建立主机失败 (错误码 %d)" % err
		return
	_do_start_match()


func _on_join() -> void:
	var ip: String = ip_edit.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
	var err: int = NetworkManager.join_game(ip)
	if err != OK:
		NetworkManager.disable_reconnect()
		stats_label.text = "加入失败 (错误码 %d)" % err
		return
	# 只有底层 peer 创建成功后才开启自动重连；异步握手失败由
	# NetworkManager.join_failed 信号统一反馈到主菜单。
	NetworkManager.enable_reconnect(ip, 24565)
	stats_label.text = "正在连接 %s:%d ..." % [ip, 24565]


## 背景网格绘制
class GridBackground extends Control:
	var _t: float = 0.0

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		# 径向渐变近似
		for i in 12:
			var k: float = float(i) / 12.0
			draw_rect(Rect2(0, h * k, w, h / 12.0 + 1),
				Color(0.10, 0.13, 0.18, 0.5).lerp(Color(0.03, 0.04, 0.06, 0.5), k))
		# 网格
		var step: float = 46.0
		var offset: float = fmod(_t * 8.0, step)
		var line_col := Color(0.35, 0.48, 0.62, 0.09)
		var x: float = -offset
		while x < w:
			draw_line(Vector2(x, 0), Vector2(x, h), line_col, 1.0)
			x += step
		var y: float = -offset
		while y < h:
			draw_line(Vector2(0, y), Vector2(w, y), line_col, 1.0)
			y += step
		# 扫描线
		var scan_y: float = fmod(_t * 60.0, h)
		draw_line(Vector2(0, scan_y), Vector2(w, scan_y), Color(0.4, 0.8, 1.0, 0.05), 2.0)
