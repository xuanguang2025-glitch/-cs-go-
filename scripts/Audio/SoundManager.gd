extends Node
##
## SoundManager.gd — 3D/2D 音效播放与对象池
##
## 挂在场景根节点下, 所有音效通过这里播放, 播放器对象复用避免频繁创建销毁。
##

const POOL_3D := 48
const POOL_2D := 12

var _free_3d: Array = []
var _free_2d: Array = []
var _busy_3d: Array = []

var _sfx_volume: float = 1.0


func _ready() -> void:
	_build_pool()


func _build_pool() -> void:
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = "SFX"
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.max_distance = 70.0
		p.panning_strength = 1.0
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_IDLE_STEP
		p.finished.connect(_on_3d_finished.bind(p))
		add_child(p)
		_free_3d.append(p)

	for i in POOL_2D:
		var p2 := AudioStreamPlayer.new()
		p2.bus = "SFX"
		p2.finished.connect(_on_2d_finished.bind(p2))
		add_child(p2)
		_free_2d.append(p2)


func _ensure_bus() -> void:
	if AudioServer.get_bus_index("SFX") == -1:
		AudioServer.add_bus()
		var idx := AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(idx, "SFX")
		if AudioServer.get_bus_index("Master") != -1:
			AudioServer.set_bus_send(idx, "Master")


func _on_3d_finished(p: AudioStreamPlayer3D) -> void:
	_busy_3d.erase(p)
	_free_3d.append(p)


func _on_2d_finished(p: AudioStreamPlayer) -> void:
	_free_2d.append(p)


## 播放 3D 空间音效
func play_3d(profile: String, global_pos: Vector3, volume_db: float = 0.0,
		pitch: float = 1.0, max_distance: float = 70.0) -> void:
	var stream := AudioForge.get_sfx(profile)
	if stream == null:
		return
	var p: AudioStreamPlayer3D
	if _free_3d.is_empty():
		# 池耗尽: 抢占最旧的
		if _busy_3d.is_empty():
			return
		p = _busy_3d.pop_front()
		p.stop()
	else:
		p = _free_3d.pop_back()
	_busy_3d.append(p)
	p.stream = stream
	# 场景切换/无头测试的首帧可能在播放器重新入树前触发音效，避免读取无效 Transform。
	if not p.is_inside_tree():
		_busy_3d.erase(p)
		_free_3d.append(p)
		return
	p.global_position = global_pos
	p.volume_db = volume_db + linear_to_db(_sfx_volume)
	p.pitch_scale = pitch
	p.max_distance = max_distance
	p.play()


## 播放非空间音效(UI / 命中标记)
func play_2d(profile: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	var stream := AudioForge.get_sfx(profile)
	if stream == null:
		return
	if _free_2d.is_empty():
		return
	var p: AudioStreamPlayer = _free_2d.pop_back()
	p.stream = stream
	p.volume_db = volume_db + linear_to_db(_sfx_volume)
	p.pitch_scale = pitch
	p.play()


func set_sfx_volume(v: float) -> void:
	_sfx_volume = clampf(v, 0.0, 1.0)
