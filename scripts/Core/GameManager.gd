extends Node
##
## GameManager.gd — 全局管理器(Autoload)
##
## 只持有"当前场景注册进来的系统引用"与跨场景持久化的设置, 不直接实现玩法。
## 各系统在 _ready 时调用 register_* 注册自己, 场景切换时自动置空。
##

signal settings_changed()

# 当前比赛场景注册的系统(切换场景后由新场景重新注册)
var sound_manager: Node = null
var fx: FXManager = null
var hit_system: HitSystem = null
var grenade_manager: Node = null
var match_manager: Node = null
var hud: Node = null
var local_player: Actor = null
var spectator: Node = null

# 跨场景设置
var settings: Dictionary = {
	"mouse_sensitivity": 1.0,
	"ads_sensitivity_mult": 0.78,
	"fov": 90.0,
	"master_volume": 0.85,
	"sfx_volume": 0.9,
	"graphics_quality": 1,
	"show_fps": false,
	"crosshair_color": "#26ff80",
	"crosshair_dynamic": true,
	"crosshair_scale": 1.0,
	"raw_input": true,
	"invert_y": false,
}

var player_name: String = "PLAYER"
var selected_team: int = GameConfig.Team.STRIKE
var bot_difficulty: int = 1          # 0=简单 1=普通 2=困难
var current_map_id: String = "project_zero"

# 战绩统计(本地累计)
var stats: Dictionary = {
	"kills": 0, "deaths": 0, "assists": 0, "headshots": 0,
	"damage": 0.0, "shots": 0, "hits": 0,
	"wins": 0, "losses": 0, "mvp": 0,
}

var training_session: Dictionary = {
	"shots": 0, "hits": 0, "damage": 0.0,
}

## 场景切换时传递给 GameRoot 的开局参数
var pending_match: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()


# ---------------------------------------------------------------- 场景切换
## 参数通过 pending_match 传递: GameRoot 在 add_child(MatchManager) 之前
## 调用 configure(), 保证 MatchManager._ready 里就能拿到正确的开局配置。
func start_match(map_id: String, bot_count: int, team: int) -> void:
	current_map_id = map_id
	selected_team = team
	pending_match = {
		"map_id": map_id,
		"bot_count": bot_count,
		"team": team,
	}
	_clear_scene_refs()
	var packed := load("res://scenes/Game.tscn") as PackedScene
	if packed == null:
		push_error("[GameManager] 无法加载 Game.tscn")
		return
	get_tree().change_scene_to_packed(packed)


func return_to_menu() -> void:
	_clear_scene_refs()
	var packed := load("res://scenes/MainMenu.tscn") as PackedScene
	if packed != null:
		get_tree().change_scene_to_packed(packed)
	EventBus.return_to_menu.emit()


func _clear_scene_refs() -> void:
	sound_manager = null
	fx = null
	hit_system = null
	grenade_manager = null
	match_manager = null
	hud = null
	local_player = null
	spectator = null


# ---------------------------------------------------------------- 设置
func get_setting(key: String, fallback: Variant = null) -> Variant:
	return settings.get(key, fallback)


func set_setting(key: String, value: Variant) -> void:
	settings[key] = value
	if key == "master_volume":
		var idx := AudioServer.get_bus_index("Master")
		if idx != -1:
			AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(float(value), 0.0, 1.0)))
			AudioServer.set_bus_mute(idx, float(value) <= 0.0)
	elif key == "sfx_volume" and sound_manager != null:
		sound_manager.call("set_sfx_volume", float(value))
	elif key == "fov" and local_player != null:
		if local_player.weapon_system != null:
			local_player.weapon_system.base_fov = float(value)
	settings_changed.emit()
	save_settings()


func save_settings() -> void:
	var path := "user://settings.cfg"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(settings))
	f.close()


func load_settings() -> void:
	var path := "user://settings.cfg"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		for k in parsed:
			settings[k] = parsed[k]


# ---------------------------------------------------------------- 统计
func record_stat(key: String, amount: float = 1.0) -> void:
	if not stats.has(key):
		stats[key] = 0
	stats[key] = float(stats[key]) + amount
	if training_session.has(key):
		training_session[key] = float(training_session[key]) + amount


func reset_training_session() -> void:
	training_session = {"shots": 0, "hits": 0, "damage": 0.0}


func get_accuracy() -> float:
	if stats["shots"] <= 0:
		return 0.0
	return float(stats["hits"]) / float(stats["shots"]) * 100.0


func get_kd() -> float:
	if stats["deaths"] <= 0:
		return float(stats["kills"])
	return float(stats["kills"]) / float(stats["deaths"])


func log_line(text: String, level: int = 0) -> void:
	var prefix: String = ["INFO", "WARN", "ERROR"][clampi(level, 0, 2)]
	print("[PS][%s] %s" % [prefix, text])
	EventBus.log_message.emit(text, level)
