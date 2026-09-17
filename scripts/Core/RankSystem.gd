extends Node
##
## RankSystem.gd — 竞技排名(Autoload)
##
## MMR + 九段位(提示词 34 条): Bronze / Silver / Gold / Platinum / Diamond /
## Master / Elite / Grandmaster / Legend。本地持久化到 user://rank.json。
## 段位图标全部程序化命名, 不复用任何商业游戏的排名美术。
##

signal mmr_changed(mmr: int, tier: int)

const SAVE_PATH := "user://rank.json"
const START_MMR := 1000
const K_FACTOR := 32.0

## 段位阈值(最低 MMR)与显示名
const TIERS := [
	{"min": 0,    "name": "Bronze",      "color": Color(0.72, 0.50, 0.30)},
	{"min": 800,  "name": "Silver",      "color": Color(0.72, 0.76, 0.80)},
	{"min": 1200, "name": "Gold",        "color": Color(0.92, 0.78, 0.30)},
	{"min": 1600, "name": "Platinum",    "color": Color(0.55, 0.85, 0.90)},
	{"min": 2000, "name": "Diamond",     "color": Color(0.50, 0.75, 1.00)},
	{"min": 2400, "name": "Master",      "color": Color(0.85, 0.45, 0.95)},
	{"min": 2800, "name": "Elite",       "color": Color(1.00, 0.45, 0.45)},
	{"min": 3200, "name": "Grandmaster", "color": Color(1.00, 0.75, 0.30)},
	{"min": 3600, "name": "Legend",      "color": Color(0.60, 1.00, 0.60)},
]

var mmr: int = START_MMR
var wins: int = 0
var losses: int = 0
var streak: int = 0


func _ready() -> void:
	load_rank()


func load_rank() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary:
		mmr = int(data.get("mmr", START_MMR))
		wins = int(data.get("wins", 0))
		losses = int(data.get("losses", 0))
		streak = int(data.get("streak", 0))


func save_rank() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"mmr": mmr, "wins": wins, "losses": losses, "streak": streak,
	}))
	f.close()


func tier_index() -> int:
	var idx := 0
	for i in TIERS.size():
		if mmr >= int(TIERS[i]["min"]):
			idx = i
	return idx


func tier_name() -> String:
	return str(TIERS[tier_index()]["name"])


func tier_color() -> Color:
	return TIERS[tier_index()]["color"]


## 比赛结束结算: 胜/败 + 对手平均 MMR(第一阶段用固定期望值, 真匹配后接入)
func report_match_result(won: bool, enemy_avg_mmr: int = -1) -> Dictionary:
	var opp: float = float(enemy_avg_mmr) if enemy_avg_mmr > 0 else float(mmr)
	var expected: float = 1.0 / (1.0 + pow(10.0, (opp - float(mmr)) / 400.0))
	var score: float = 1.0 if won else 0.0
	var delta: int = int(round(K_FACTOR * (score - expected)))
	# 连胜/连败加成(小额)
	var streak_bonus := 0
	if won:
		streak += 1
		streak_bonus = mini(maxi(streak - 1, 0), 3) * 5
	else:
		streak = 0

	var before_tier := tier_index()
	mmr = clampi(mmr + delta + (streak_bonus if won else 0), 0, 5000)
	if won:
		wins += 1
	else:
		losses += 1
	save_rank()
	var promoted: bool = tier_index() > before_tier
	var demoted: bool = tier_index() < before_tier
	mmr_changed.emit(mmr, tier_index())
	return {
		"delta": delta + (streak_bonus if won else 0),
		"mmr": mmr,
		"tier": tier_name(),
		"promoted": promoted,
		"demoted": demoted,
		"streak": streak,
	}
