extends Node
class_name EconomyManager
##
## EconomyManager.gd — 回合经济结算
##
## 奖励规则(全部常量集中在 GameConfig, 不在此处硬编码数值):
##   胜方: 歼灭 / 引爆 / 拆除 / 时间耗尽 各有不同奖励
##   败方: 连败补偿随连败次数递增(1400 -> 3400 封顶), 安装过装置额外补偿
##   个人: 击杀按武器 kill_reward 发放, 安装/拆除另有奖励
##

var loss_streak: Dictionary = {
	GameConfig.Team.STRIKE: 0,
	GameConfig.Team.GUARD: 0,
}

var round_econ_log: Array = []


func reset_match() -> void:
	loss_streak[GameConfig.Team.STRIKE] = 0
	loss_streak[GameConfig.Team.GUARD] = 0
	round_econ_log.clear()


## 回合结束给全队发放奖励
## reason: "elimination" | "bomb" | "defuse" | "time"
func award_round(winner_team: int, reason: String, bomb_planted: bool) -> void:
	var loser_team: int = GameConfig.opponent(winner_team)

	var win_bonus: int = _win_bonus(reason)
	var loss_bonus: int = _loss_bonus(loser_team, bomb_planted)

	for a in _all_actors():
		if a.team == winner_team:
			a.loadout.add_money(win_bonus)
		else:
			a.loadout.add_money(loss_bonus)

	# 连败计数
	if reason != "draw":
		loss_streak[winner_team] = 0
		loss_streak[loser_team] = mini(
			loss_streak[loser_team] + 1,
			_loss_max_step())

	round_econ_log.append({
		"round": len(round_econ_log) + 1,
		"winner": winner_team,
		"reason": reason,
		"win_bonus": win_bonus,
		"loss_bonus": loss_bonus,
	})


func _loss_max_step() -> int:
	return int((GameConfig.LOSS_BONUS_MAX - GameConfig.LOSS_BONUS_BASE) / GameConfig.LOSS_BONUS_STEP)


func _win_bonus(reason: String) -> int:
	match reason:
		"bomb":    return GameConfig.WIN_BONUS_PLANT
		"defuse":  return GameConfig.WIN_BONUS_DEFUSE
		"time":    return GameConfig.WIN_BONUS_TIME
		_:         return GameConfig.WIN_BONUS_ELIM


func _loss_bonus(loser_team: int, bomb_planted: bool) -> int:
	var streak: int = int(loss_streak.get(loser_team, 0))
	var bonus: int = GameConfig.LOSS_BONUS_BASE + streak * GameConfig.LOSS_BONUS_STEP
	bonus = mini(bonus, GameConfig.LOSS_BONUS_MAX)
	if bomb_planted:
		bonus += GameConfig.LOSER_PLANT_BONUS
	return bonus


func award_kill(killer: Actor, weapon_id: String) -> int:
	if killer == null or not is_instance_valid(killer):
		return 0
	var reward: int = GameConfig.KILL_REWARD_BASE
	if WeaponDatabase.has_weapon(weapon_id):
		reward = int(WeaponDatabase.get_weapon(weapon_id)["kill_reward"])
	elif weapon_id == "he":
		reward = 300
	elif weapon_id == "molotov":
		reward = 300
	elif weapon_id == "bomb":
		reward = 0
	killer.loadout.add_money(reward)
	return reward


func award_plant(actor: Actor) -> void:
	if actor == null:
		return
	actor.loadout.add_money(GameConfig.PLANT_REWARD)


func award_defuse(actor: Actor) -> void:
	if actor == null:
		return
	actor.loadout.add_money(GameConfig.DEFUSE_REWARD)


func _all_actors() -> Array:
	return get_tree().get_nodes_in_group("actors")
