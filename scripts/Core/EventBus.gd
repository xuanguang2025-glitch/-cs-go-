extends Node
##
## EventBus.gd — 全局信号总线
## Autoload 名: EventBus
##
## 所有跨模块通信走这里, 避免模块之间直接持有引用。
##

# ---- 玩家生命周期
signal player_spawned(player: Node)
signal player_died(victim: Node, killer: Node, weapon_id: String, is_headshot: bool)
signal player_damaged(victim: Node, attacker: Node, amount: float, is_headshot: bool)
signal player_respawned(player: Node)

# ---- 战斗
signal weapon_fired(player: Node, weapon_id: String)
signal hit_confirmed(attacker: Node, victim: Node, damage: float, is_headshot: bool, killed: bool)
signal hitmarker(is_kill: bool, is_headshot: bool)
## 子弹命中队友(无伤害): 用于给射击者一个"这是队友"的明确反馈,
## 否则打到队友和打空气完全一样, 玩家会误以为"打不动人"。
signal friendly_hit(shooter: Node, victim: Node)
signal shot_missed(attacker: Node)
signal grenade_thrown(thrower: Node, kind: String)
signal grenade_exploded(kind: String, position: Vector3)
signal player_flashed(player: Node, intensity: float, duration: float)
signal player_burning(player: Node, dps: float)

# ---- 回合 / 比赛
signal round_state_changed(new_state: int, round_number: int)
signal round_started(round_number: int)
signal round_ended(winner_team: int, reason: String)
signal freezetime_ended()
signal halftime_reached()
signal match_ended(winner_team: int, score_a: int, score_b: int)
signal score_changed(score_strike: int, score_guard: int)

# ---- 目标装置
signal bomb_planted(site_name: String, planter: Node)
signal bomb_defused(defuser: Node)
signal bomb_exploded()
signal plant_started(planter: Node, site_name: String)
signal plant_aborted(planter: Node)
signal defuse_started(defuser: Node, with_kit: bool)
signal defuse_aborted(defuser: Node)
signal bomb_carrier_changed(carrier: Node)

# ---- 经济 / 购买
signal money_changed(player: Node, new_amount: int)
signal item_purchased(player: Node, item_id: String, price: int)

# ---- UI
signal killfeed_request(killer_name: String, victim_name: String, weapon_id: String, is_headshot: bool, killer_team: int, victim_team: int)
signal announcement(text: String, kind: String)
signal buy_menu_toggled(open: bool)
signal spectate_target_changed(target: Node)

# ---- 商城 / 外观
## 注意: 这里的 currency_changed 指商城货币(积分/钻石),
## 与上面 money_changed(回合内购买力)是两套完全不同的经济。
signal currency_changed(currency_type: String, new_balance: int)
signal shop_opened
signal shop_closed
signal inventory_updated(owned_ids: Array)
signal cosmetic_equipped(slot: String, item_id: String)
signal cosmetic_unequipped(slot: String)
signal loot_box_opened(box_id: String, result_item_id: String)
signal shop_purchase_completed(item_id: String, success: bool, reason: String)
signal shop_preview_requested(item_id: String)

# ---- 系统
signal graphics_changed(tier: int)
signal game_start_requested(map_id: String, bot_count: int)
signal return_to_menu()
signal log_message(text: String, level: int)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
