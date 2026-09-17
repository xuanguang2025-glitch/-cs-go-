extends Node3D
##
## GameRoot.gd — 比赛场景根节点
##
## 负责: 组装 MatchManager / HUD / 购买菜单 / 计分板, 以及全局快捷键分发。
## 地图与角色由 MatchManager 在其 _ready 中构建。
##

var mm: MatchManager = null
var hud: HUD = null
var buy_menu: BuyMenu = null
var scoreboard: Scoreboard = null
var match_result: MatchResult = null

var _paused: bool = false
var _pause_layer: CanvasLayer = null
var _pause_title: Label = null
var _pause_status: Label = null
var _pause_resume_button: Button = null
var _pause_menu_button: Button = null


func _ready() -> void:
	name = "GameRoot"
	set_process_unhandled_input(true)

	var pending: Dictionary = GameManager.pending_match
	var map_id: String = str(pending.get("map_id", "project_zero"))
	var bot_count: int = int(pending.get("bot_count", 9))
	var team: int = int(pending.get("team", GameConfig.Team.STRIKE))

	# 应用画质档位(必须早于地图构建: 环境/光照按档位生成)
	GraphicsQuality.apply()

	mm = MatchManager.new()
	# 必须在 add_child(触发 _ready)之前完成配置
	mm.configure(map_id, bot_count, team)
	# 专用服务器的 Bot 数量(N=0 即纯观察者模式)
	if pending.has("dedicated_bots"):
		mm.dedicated_bot_count = clampi(int(pending["dedicated_bots"]), 0, 10)
	add_child(mm)

	var dedicated: bool = NetworkManager.dedicated_server
	if mm.local_player == null and not NetworkManager.is_client and not dedicated:
		push_error("[GameRoot] 本地玩家创建失败")
		return

	# 专用服务器: 只跑模拟, 不建任何 UI
	if not dedicated:
		# 后处理必须排在 HUD 之前加入: 同层 CanvasLayer 按树序绘制,
		# 这样锐化/暗角只作用于 3D 画面, 不影响准星与文字的清晰度。
		add_child(PostFX.new())

		hud = HUD.new()
		add_child(hud)
		# 客户端: 角色等服务器下发(assign_local)后再绑定; 本地模式直接绑
		hud.setup(mm.local_player, mm, mm.objective)
		GameManager.hud = hud

		buy_menu = BuyMenu.new()
		add_child(buy_menu)
		buy_menu.setup(mm.local_player, mm)

		scoreboard = Scoreboard.new()
		add_child(scoreboard)
		scoreboard.setup(mm)

		match_result = MatchResult.new()
		add_child(match_result)
		match_result.setup(mm)

		_build_pause_overlay()

	# 应用设置
	var vol: float = float(GameManager.get_setting("master_volume", 0.85))
	GameManager.set_setting("master_volume", vol)
	if mm.sound != null:
		mm.sound.call("set_sfx_volume", float(GameManager.get_setting("sfx_volume", 0.9)))


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return

	match k.physical_keycode:
		KEY_B:
			if buy_menu != null and not (scoreboard != null and scoreboard.is_open):
				buy_menu.toggle()
				get_viewport().set_input_as_handled()
		KEY_TAB:
			if scoreboard != null:
				scoreboard.set_open(true)
				get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			if buy_menu != null and buy_menu.is_open:
				buy_menu.close_menu()
			else:
				_toggle_pause()
			get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	# TAB 松开即关闭计分板
	if scoreboard != null and scoreboard.is_open:
		if not Input.is_action_pressed("ui_scoreboard"):
			scoreboard.set_open(false)
		else:
			scoreboard.refresh()


func _toggle_pause() -> void:
	# 联机对局不能暂停整个树，否则会连网络心跳一起冻结；只提示玩家使用退出键离开。
	if NetworkManager.is_client or NetworkManager.is_server:
		if _paused:
			_resume_game()
			return
		if _pause_status != null:
			_pause_status.text = "联机对局中不可暂停\n按 ESC 关闭此提示"
			_pause_status.modulate = Color(1.0, 0.55, 0.4, 1.0)
		if _pause_resume_button != null:
			_pause_resume_button.visible = false
		if _pause_menu_button != null:
			_pause_menu_button.text = "返回主菜单"
			_pause_menu_button.visible = true
		_pause_layer.visible = true
		_paused = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	_paused = not _paused
	get_tree().paused = _paused
	if _pause_layer != null:
		_pause_layer.visible = _paused
		if _paused:
			if _pause_status != null:
				_pause_status.text = "游戏已暂停\n战局时间不会继续流逝"
				_pause_status.modulate = Color(0.72, 0.8, 0.9, 1.0)
			if _pause_resume_button != null:
				_pause_resume_button.visible = true
			if _pause_menu_button != null:
				_pause_menu_button.text = "返回主菜单"
				_pause_menu_button.visible = true
	Input.set_mouse_mode(
		Input.MOUSE_MODE_VISIBLE if _paused else Input.MOUSE_MODE_CAPTURED)


func _build_pause_overlay() -> void:
	_pause_layer = CanvasLayer.new()
	_pause_layer.name = "PauseOverlay"
	_pause_layer.layer = 60
	_pause_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause_layer.visible = false
	add_child(_pause_layer)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_layer.add_child(root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.015, 0.02, 0.035, 0.82)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 300)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.07, 0.095, 0.98)
	panel_style.border_color = Color(0.3, 0.62, 0.82, 0.75)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	_pause_title = Label.new()
	_pause_title.text = "战术暂停"
	_pause_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pause_title.add_theme_font_size_override("font_size", 32)
	_pause_title.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	box.add_child(_pause_title)

	_pause_status = Label.new()
	_pause_status.text = "游戏已暂停\n战局时间不会继续流逝"
	_pause_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pause_status.add_theme_font_size_override("font_size", 16)
	_pause_status.add_theme_color_override("font_color", Color(0.72, 0.8, 0.9))
	box.add_child(_pause_status)

	_pause_resume_button = Button.new()
	_pause_resume_button.text = "继续游戏"
	_pause_resume_button.custom_minimum_size = Vector2(0, 42)
	_pause_resume_button.add_theme_font_size_override("font_size", 18)
	_pause_resume_button.pressed.connect(_resume_game)
	box.add_child(_pause_resume_button)

	_pause_menu_button = Button.new()
	_pause_menu_button.text = "返回主菜单"
	_pause_menu_button.custom_minimum_size = Vector2(0, 38)
	_pause_menu_button.pressed.connect(_leave_to_menu)
	box.add_child(_pause_menu_button)

	var hint := Label.new()
	hint.text = "ESC 继续 · 鼠标已释放"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.48, 0.56, 0.66))
	box.add_child(hint)


func _resume_game() -> void:
	# 联机提示模式不暂停树，直接关闭即可；单机模式则恢复处理。
	_paused = false
	get_tree().paused = false
	if _pause_layer != null:
		_pause_layer.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _leave_to_menu() -> void:
	_paused = false
	get_tree().paused = false
	if _pause_layer != null:
		_pause_layer.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	GameManager.return_to_menu()
