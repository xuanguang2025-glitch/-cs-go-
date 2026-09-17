extends Node
## SteamManager.gd — Steam 集成层(autoload)
##
## 通过 Engine.get_singleton("Steam") 动态访问 GodotSteam 单例:
##   * 用 GodotSteam 引擎(GodotSteam_Editor.exe)运行 -> Steam 单例存在, 功能全部可用
##   * 用普通 Godot 引擎运行 / 无头测试       -> 单例为 null, 所有方法安全 no-op
## 这样同一份代码既能在 Steam 环境工作, 也能在无 Steam 环境开发/测试。
##
## 成就清单(Steamworks 后台需按这些 API 名称配置):
##   FIRST_KILL     首杀
##   HEADSHOT_MASTER 爆头王
##   BOMB_PLANTED   爆破专家
##   FIRST_WIN      首胜
##   RANK_SILVER    白银之上
##   TRAINING_STAR  训练标兵

const ACH_FIRST_KILL := "FIRST_KILL"
const ACH_HEADSHOT := "HEADSHOT_MASTER"
const ACH_BOMB := "BOMB_PLANTED"
const ACH_FIRST_WIN := "FIRST_WIN"
const ACH_RANK := "RANK_SILVER"
const ACH_TRAINING := "TRAINING_STAR"

var _steam: Object = null
var initialized: bool = false
var steam_running: bool = false
var persona_name: String = ""
var steam_id: String = ""

## 云存档键
const CLOUD_RANK := "ps_rank.json"
const CLOUD_STATS := "ps_stats.json"


func _ready() -> void:
	# GodotSteam 以 Engine Singleton "Steam" 注册。
	# 先 has_singleton 再取, 避免普通引擎打印 "Failed to retrieve non-existent singleton" ERROR
	if not Engine.has_singleton("Steam"):
		_steam = null
	else:
		_steam = Engine.get_singleton("Steam")
	if _steam == null:
		push_warning("[SteamManager] 未检测到 Steam 单例(普通引擎), Steam 功能禁用")
		return
	if not _steam.has_method("steamInit"):
		push_warning("[SteamManager] Steam 单例缺少 steamInit, 版本不匹配")
		_steam = null
		return
	# GodotSteam 4.x: steamInit() 返回 bool(是否成功); 更早版本返回 Dictionary
	var res: Variant = _steam.steamInit()
	if res is bool:
		initialized = bool(res)
	elif res is Dictionary:
		initialized = int(res.get("status", -1)) == 0 or int(res.get("status", -1)) == 2
	else:
		initialized = false
	steam_running = bool(_steam.isSteamRunning()) if _steam.has_method("isSteamRunning") else false
	if initialized:
		persona_name = str(_steam.getPersonaName()) if _steam.has_method("getPersonaName") else ""
		steam_id = str(_steam.getSteamID()) if _steam.has_method("getSteamID") else ""
		GameManager.log_line("[Steam] 已连接: %s (ID %s)" % [persona_name, steam_id])
		_load_cloud_data()
	else:
		var reason: String = ""
		if res is Dictionary:
			reason = " (status=%d)" % int(res.get("status", -1))
		GameManager.log_line("[Steam] steamInit 失败%s, 以离线模式运行" % reason)


## Steam 可用?
func is_steam_active() -> bool:
	return _steam != null and initialized


## 解锁成就(可重复调用, 已解锁自动忽略)
func unlock_achievement(ach: String) -> void:
	if not is_steam_active() or not _steam.has_method("setAchievement"):
		return
	if _steam.has_method("isAchievementUnlocked") and _steam.isAchievementUnlocked(ach):
		return
	if _steam.setAchievement(ach) and _steam.has_method("storeStats"):
		_steam.storeStats()
		GameManager.log_line("[Steam] 成就解锁: " + ach)


## 清除成就(调试用)
func clear_achievement(ach: String) -> void:
	if not is_steam_active():
		return
	if _steam.has_method("clearAchievement"):
		_steam.clearAchievement(ach)
	if _steam.has_method("storeStats"):
		_steam.storeStats()


## 打开 Steam Overlay 面板: friends / achievements / stats / community / lobbyinvite
func open_overlay(dialog: String = "friends") -> void:
	if not is_steam_active() or not _steam.has_method("activateGameOverlay"):
		return
	_steam.activateGameOverlay(dialog)


## 打开网页(可做赞助/官网链接)
func open_web_page(url: String) -> void:
	if not is_steam_active() or not _steam.has_method("activateGameOverlayToWebPage"):
		return
	_steam.activateGameOverlayToWebPage(url)


# ================================================================ 云存档
## 把数据写入 Steam 云存档(自动同步到云端)
func cloud_write(key: String, data: PackedByteArray) -> bool:
	if not is_steam_active() or not _steam.has_method("fileWrite"):
		return false
	var ok: bool = _steam.fileWrite(key, data)
	if ok and _steam.has_method("fileShare"):
		_steam.fileShare(key)
	return ok


## 从 Steam 云存档读取
func cloud_read(key: String) -> PackedByteArray:
	if not is_steam_active() or not _steam.has_method("fileRead"):
		return PackedByteArray()
	return _steam.fileRead(key)


func cloud_exists(key: String) -> bool:
	if not is_steam_active() or not _steam.has_method("fileExists"):
		return false
	return bool(_steam.fileExists(key))


## 段位数据与云存档互同步(本地文件为权威, 云存档兜底)
func _load_cloud_data() -> void:
	# 段位
	if cloud_exists(CLOUD_RANK):
		var bytes: PackedByteArray = cloud_read(CLOUD_RANK)
		if bytes.size() > 0:
			var text: String = bytes.get_string_from_utf8()
			var parsed = JSON.parse_string(text)
			if parsed is Dictionary:
				RankSystem.mmr = int(parsed.get("mmr", RankSystem.mmr))
				RankSystem.streak = int(parsed.get("streak", RankSystem.streak))
				RankSystem.wins = int(parsed.get("wins", RankSystem.wins))
				RankSystem.losses = int(parsed.get("losses", RankSystem.losses))
				GameManager.log_line("[Steam] 云存档段位已载入 MMR=%d" % RankSystem.mmr)


func push_cloud_data() -> void:
	if not is_steam_active():
		return
	var rank_data := {"mmr": RankSystem.mmr, "streak": RankSystem.streak,
		"wins": RankSystem.wins, "losses": RankSystem.losses}
	cloud_write(CLOUD_RANK, JSON.stringify(rank_data).to_utf8_buffer())


## 退出前保存云存档
func save_all() -> void:
	if not is_steam_active():
		return
	RankSystem.save()
	push_cloud_data()
	if _steam.has_method("fileStore"):
		_steam.fileStore()  # 立即提交到云端
