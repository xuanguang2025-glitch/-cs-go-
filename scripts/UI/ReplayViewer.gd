extends Node3D
class_name ReplayViewer
##
## ReplayViewer.gd — 回放查看器
##
## 简易场景 + 按时间轴驱动的角色代理(胶囊+队色), 自动加载最新一段录像播放。
## 空格暂停 / 左右键倍速 / ESC 退出。
##

var proxies: Dictionary = {}     # id -> Node3D
var camera: Camera3D
var _ui_label: Label = null
var _loaded: bool = false


func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.08, 0.09, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.55, 0.65)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.4
	add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	plane.orientation = PlaneMesh.FACE_Y
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.25, 0.27, 0.3)
	ground.material_override = gm
	add_child(ground)

	camera = Camera3D.new()
	camera.position = Vector3(0, 55, 30)
	camera.rotation_degrees = Vector3(-60, 0, 0)
	camera.fov = 60
	add_child(camera)
	camera.make_current()

	# UI
	var layer := CanvasLayer.new()
	add_child(layer)
	var label := Label.new()
	label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	label.offset_top = 12
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	layer.add_child(label)
	_ui_label = label

	_load_latest()


func _load_latest() -> void:
	var replays: Array = ReplaySystem.list_replays()
	if replays.is_empty():
		_ui_label.text = "没有录像 - 先打一场比赛"
		return
	if ReplaySystem.load_replay(replays[0]):
		_loaded = true
		ReplaySystem.play()
		_ui_label.text = "回放中  %.1fs / %.1fs  ·  空格暂停  ·  ←→ 倍速  ·  ESC 退出" % [
			ReplaySystem.play_head / 1000.0, ReplaySystem.duration_ms() / 1000.0]


func _ensure_proxy(id: int, team: int) -> Node3D:
	if proxies.has(id):
		return proxies[id]
	var proxy := Node3D.new()
	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.3
	cap.height = 1.3
	mi.mesh = cap
	var m := StandardMaterial3D.new()
	m.albedo_color = GameConfig.TEAM_COLOR.get(team, Color.WHITE)
	mi.material_override = m
	mi.position = Vector3(0, 0.75, 0)
	proxy.add_child(mi)
	add_child(proxy)
	proxies[id] = proxy
	return proxy


func _process(delta: float) -> void:
	if not _loaded:
		return
	if Input.is_action_just_pressed("mv_jump"):
		if ReplaySystem.playing:
			ReplaySystem.pause()
		else:
			ReplaySystem.play()
	if Input.is_action_just_pressed("mv_left"):
		ReplaySystem.play_speed = maxf(ReplaySystem.play_speed - 0.5, 0.25)
	if Input.is_action_just_pressed("mv_right"):
		ReplaySystem.play_speed = minf(ReplaySystem.play_speed + 0.5, 4.0)
	if Input.is_action_just_pressed("mv_crouch"):
		GameManager.return_to_menu()
		return

	var state: Dictionary = ReplaySystem.sample(ReplaySystem.play_head)
	for id in state:
		var s: Dictionary = state[id]
		var proxy := _ensure_proxy(id, int(s["team"]))
		proxy.global_position = s["pos"]
		proxy.rotation.y = float(s["yaw"])
		proxy.visible = bool(s["alive"])
		proxy.scale.y = clampf(float(s["hp"]) / 100.0, 0.25, 1.0)

	if _ui_label != null:
		var spd: String = "%.1fx" % ReplaySystem.play_speed
		_ui_label.text = "%s  %.1fs / %.1fs  ·  速度 %s  ·  空格暂停  ·  ←→ 倍速  ·  Ctrl 退出" % [
			str(ReplaySystem.meta.get("map", "")),
			ReplaySystem.play_head / 1000.0, ReplaySystem.duration_ms() / 1000.0, spd]

	if ReplaySystem.play_head >= ReplaySystem.duration_ms():
		ReplaySystem.pause()
		if _ui_label != null:
			_ui_label.text = "回放结束 - Ctrl 退出"
