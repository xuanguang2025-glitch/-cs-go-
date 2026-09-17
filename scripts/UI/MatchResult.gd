extends CanvasLayer
class_name MatchResult
##
## MatchResult.gd — 比赛结算画面(提示词 42 条)
##
## 比赛结束(match_ended)后全屏展示: 胜负 / 比分 / 双方 K·D·A·伤害·命中率 /
## MMR 变化与段位。按任意键或 12 秒后返回主菜单。
##

var mm: MatchManager = null
var shown: bool = false
var _countdown: float = 12.0
var _root: Control = null
var _countdown_label: Label = null


func _ready() -> void:
	layer = 40
	visible = false
	set_process(true)
	EventBus.match_ended.connect(_on_match_ended)


func setup(m: MatchManager) -> void:
	mm = m


func _on_match_ended(winner: int, s_strike: int, s_guard: int) -> void:
	if shown or mm == null:
		return
	shown = true
	visible = true
	_countdown = 12.0
	_build(winner, s_strike, s_guard)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _build(winner: int, s_strike: int, s_guard: int) -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.8)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(760, 620)
	panel.position = Vector2(-380, -310)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.09, 0.97)
	style.set_corner_radius_all(12)
	style.border_color = GameConfig.TEAM_COLOR.get(winner, Color.WHITE)
	style.set_border_width_all(3)
	panel.add_theme_stylebox_override("panel", style)
	_root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var i_won: bool = mm.local_player != null and mm.local_player.team == winner

	var title := Label.new()
	title.text = ("胜 利" if i_won else "失 败") + "   ·   STRIKE %d : %d GUARD" % [s_strike, s_guard]
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color",
		Color(0.45, 0.95, 0.55) if i_won else Color(0.95, 0.45, 0.40))
	vbox.add_child(title)

	var rank := Label.new()
	var r: Dictionary = RankSystem.report_match_result(i_won)
	rank.text = "段位 %s   ·   MMR %d (%+d)   ·   战绩 %d 胜 %d 负" % [
		str(r.get("tier", "")), int(r.get("mmr", 0)), int(r.get("delta", 0)),
		RankSystem.wins, RankSystem.losses]
	rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rank.add_theme_font_size_override("font_size", 20)
	rank.add_theme_color_override("font_color", RankSystem.tier_color())
	vbox.add_child(rank)

	vbox.add_child(HSeparator.new())

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(hbox)

	for team in [GameConfig.Team.STRIKE, GameConfig.Team.GUARD]:
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_theme_constant_override("separation", 2)
		hbox.add_child(box)

		var t := Label.new()
		t.text = "%s  (%d)" % [GameConfig.team_name(team),
			s_strike if team == GameConfig.Team.STRIKE else s_guard]
		t.add_theme_font_size_override("font_size", 22)
		t.add_theme_color_override("font_color", GameConfig.TEAM_COLOR.get(team, Color.WHITE))
		box.add_child(t)

		var head := HBoxContainer.new()
		box.add_child(head)
		for h in [["玩家", 140.0], ["K", 30.0], ["D", 30.0], ["A", 30.0], ["伤害", 62.0]]:
			var l := Label.new()
			l.text = h[0]
			l.custom_minimum_size = Vector2(h[1], 0)
			l.add_theme_font_size_override("font_size", 13)
			l.add_theme_color_override("font_color", Color(0.55, 0.6, 0.68))
			head.add_child(l)

		for a in mm.actors:
			var actor: Actor = a as Actor
			if actor == null or actor.team != team:
				continue
			var st: Dictionary = mm.get_actor_stats(actor)
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			box.add_child(row)
			var col: Color = Color(1, 1, 1) if actor.alive else Color(0.5, 0.5, 0.55)
			if actor == mm.local_player:
				col = Color(1.0, 0.85, 0.35)
			for cell in [[actor.actor_name, 140.0, col],
					[str(int(st["kills"])), 30.0, col],
					[str(int(st["deaths"])), 30.0, col],
					[str(int(st["assists"])), 30.0, col],
					[str(int(float(st["damage"]))), 62.0, col]]:
				var cl := Label.new()
				cl.text = cell[0]
				cl.custom_minimum_size = Vector2(cell[1], 0)
				cl.add_theme_font_size_override("font_size", 15)
				cl.add_theme_color_override("font_color", cell[2])
				row.add_child(cl)

	# 个人命中率
	var acc := Label.new()
	var local_shots: int = int(GameManager.stats.get("shots", 0))
	var local_hits: int = int(GameManager.stats.get("hits", 0))
	var local_accuracy: float = float(local_hits) / float(maxi(local_shots, 1)) * 100.0
	acc.text = "本局命中率 %.1f%%   ·   命中 %d/%d   ·   爆头 %d" % [
		local_accuracy, local_hits, local_shots, int(GameManager.stats["headshots"])]
	acc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	acc.add_theme_font_size_override("font_size", 16)
	acc.add_theme_color_override("font_color", Color(0.62, 0.7, 0.8))
	vbox.add_child(acc)

	_countdown_label = Label.new()
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.add_theme_font_size_override("font_size", 15)
	_countdown_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	vbox.add_child(_countdown_label)


func _process(delta: float) -> void:
	if not shown:
		return
	_countdown -= delta
	if _countdown_label != null:
		_countdown_label.text = "按任意键返回主菜单  (%d)" % int(ceilf(_countdown))
	if _countdown <= 0.0 or _any_key_pressed():
		shown = false
		visible = false
		get_tree().paused = false
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		GameManager.return_to_menu()


func _any_key_pressed() -> bool:
	for action in ["ui_buy", "util_plant", "slot_primary", "wpn_reload"]:
		if Input.is_action_just_pressed(action):
			return true
	return Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER)
