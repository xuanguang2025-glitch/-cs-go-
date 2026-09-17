extends CanvasLayer
class_name Scoreboard
##
## Scoreboard.gd — 计分板(按住 TAB 显示)
##
## 显示双方队伍的 击杀 / 死亡 / 助攻 / 伤害 / 金钱 / 存活状态。
##

var mm: MatchManager = null
var is_open: bool = false
var root: Control
var strike_box: VBoxContainer
var guard_box: VBoxContainer
var header_label: Label
var footer_label: Label


func _ready() -> void:
	layer = 25
	visible = false
	_build_ui()


func setup(m: MatchManager) -> void:
	mm = m


func _build_ui() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(720, 520)
	panel.position = Vector2(-360, -260)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.96)
	style.set_corner_radius_all(8)
	style.border_color = Color(0.32, 0.38, 0.46, 0.8)
	style.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", style)
	root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	header_label = Label.new()
	header_label.text = "PROJECT STRIKE"
	header_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header_label.add_theme_font_size_override("font_size", 28)
	vbox.add_child(header_label)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(hbox)

	strike_box = VBoxContainer.new()
	strike_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	strike_box.add_theme_constant_override("separation", 2)
	hbox.add_child(strike_box)

	guard_box = VBoxContainer.new()
	guard_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	guard_box.add_theme_constant_override("separation", 2)
	hbox.add_child(guard_box)

	footer_label = Label.new()
	footer_label.text = "第 1 回合"
	footer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer_label.add_theme_font_size_override("font_size", 16)
	footer_label.add_theme_color_override("font_color", Color(0.68, 0.73, 0.8))
	vbox.add_child(footer_label)


func set_open(v: bool) -> void:
	is_open = v
	visible = v
	if v:
		refresh()


func refresh() -> void:
	if mm == null:
		return
	var s: Vector2i = mm.get_score()
	header_label.text = "PROJECT STRIKE   |   STRIKE %d : %d GUARD" % [s.x, s.y]
	footer_label.text = "第 %d 回合  ·  %s  ·  松开 TAB 关闭" % [
		mm.round_number, mm.get_phase_name()]

	_fill_team(strike_box, GameConfig.Team.STRIKE)
	_fill_team(guard_box, GameConfig.Team.GUARD)


func _fill_team(box: VBoxContainer, team: int) -> void:
	for c in box.get_children():
		c.queue_free()

	var score_val: int = mm.score.get(team, 0)
	var title := Label.new()
	title.text = "%s   %d" % [GameConfig.team_name(team), score_val]
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", GameConfig.TEAM_COLOR.get(team, Color.WHITE))
	box.add_child(title)

	# 表头
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	box.add_child(head)
	for h in ["玩家", "K", "D", "A", "伤害", "金钱"]:
		var l := Label.new()
		l.text = h
		l.add_theme_font_size_override("font_size", 14)
		l.add_theme_color_override("font_color", Color(0.55, 0.6, 0.68))
		l.custom_minimum_size = Vector2(_col_width(h), 0)
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

		_add_cell(row, actor.actor_name, col, 15, _col_width("玩家"))
		_add_cell(row, str(int(st.get("kills", 0))), col, 15, _col_width("K"))
		_add_cell(row, str(int(st.get("deaths", 0))), col, 15, _col_width("D"))
		_add_cell(row, str(int(st.get("assists", 0))), col, 15, _col_width("A"))
		_add_cell(row, str(int(st.get("damage", 0.0))), col, 15, _col_width("伤害"))
		_add_cell(row, "$%d" % actor.loadout.money, Color(0.45, 0.9, 0.55), 15, _col_width("金钱"))


func _col_width(header: String) -> float:
	match header:
		"玩家": return 150.0
		"K", "D", "A": return 34.0
		"伤害": return 62.0
		"金钱": return 72.0
	return 60.0


func _add_cell(parent: Control, text: String, color: Color, size: int, width: float) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.custom_minimum_size = Vector2(width, 0)
	parent.add_child(l)
