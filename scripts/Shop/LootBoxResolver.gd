class_name LootBoxResolver
extends RefCounted
##
## LootBoxResolver.gd — 开箱概率结算
##
## 纯逻辑: 输入箱子定义 + 当前保底计数 + 随机源, 输出结果物品与新计数。
## 不读节点也不写存档, 因此可以在无头环境用固定种子精确复现。
##
## 只应在服务器/主机上调用。客户端永远拿不到权重表, 也不该自己摇。
##
## 结算顺序:
##   1. 保底计数已达阈值 -> 只在 >= pity_guaranteed_rarity 的子集内摇
##   2. 否则按 (池内权重 × 稀有度权重) 摇; 结果低于 guaranteed_rarity_min
##      时在达标子集内重摇 —— 这是"地板线"
##   3. 摇到 >= pity_guaranteed_rarity 清空计数, 否则 +1 —— 这是"保底线"
##
## 两条保证各自独立: 地板线防"永远只出白色", 保底线防"运气最差的人摸不到高稀有"。

## 摇一次。
## 返回 { item_id, rarity, pity, by_pity, floored, error }
static func roll(box: Dictionary, rarity_table: Dictionary, pity: int, rng: RandomNumberGenerator) -> Dictionary:
	var empty := {
		"item_id": "", "rarity": "", "pity": pity,
		"by_pity": false, "floored": false, "error": "",
	}

	if rng == null:
		empty["error"] = "no_rng"
		return empty

	var entries := _enrich(box.get("contents_pool", []), rarity_table)
	if entries.is_empty():
		empty["error"] = "empty_pool"
		return empty

	var min_rank := _rank(String(box.get("guaranteed_rarity_min", "common")), rarity_table)
	var pity_rarity := String(box.get("pity_guaranteed_rarity", "rare"))
	var pity_rank := _rank(pity_rarity, rarity_table)
	var threshold := maxi(int(box.get("pity_counter_threshold", 0)), 1)

	var chosen: Dictionary
	var by_pity := false
	var floored := false

	if pity >= threshold:
		var pool_hi := _at_least(entries, pity_rank)
		if pool_hi.is_empty():
			# 奖池里根本没有保底档位的东西 —— 配置错误, 不能静默降级
			push_error("[LootBoxResolver] %s 奖池无 %s 及以上档位, 保底无法兑现"
				% [String(box.get("id", "?")), pity_rarity])
			chosen = _weighted_pick(entries, rng)
		else:
			chosen = _weighted_pick(pool_hi, rng)
			by_pity = true
	else:
		chosen = _weighted_pick(entries, rng)
		if int(chosen["rank"]) < min_rank:
			var pool_floor := _at_least(entries, min_rank)
			if not pool_floor.is_empty():
				chosen = _weighted_pick(pool_floor, rng)
				floored = true

	var result_pity := pity + 1
	if by_pity or int(chosen["rank"]) >= pity_rank:
		result_pity = 0

	return {
		"item_id": String(chosen["item_id"]),
		"rarity": String(chosen["rarity"]),
		"pity": result_pity,
		"by_pity": by_pity,
		"floored": floored and not by_pity,
		"error": "",
	}


## 用固定种子把整箱摇 rolls 次, 返回 item_id -> 次数。用于分布回归。
static func sample_distribution(box: Dictionary, rarity_table: Dictionary, rolls: int, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var pity := 0
	var out: Dictionary = {}
	for _i in rolls:
		var r := roll(box, rarity_table, pity, rng)
		pity = int(r.get("pity", 0))
		var id := String(r.get("item_id", ""))
		if id.is_empty():
			continue
		out[id] = int(out.get(id, 0)) + 1
	return out


# ---- 内部 ----

## 展开奖池为 { item_id, rarity, rank, w }; 物品不存在或合成权重<=0 的剔除。
static func _enrich(pool: Array, rarity_table: Dictionary) -> Array:
	var out: Array = []
	for e in pool:
		if not (e is Dictionary):
			continue
		var id := String(e.get("item_id", ""))
		if id.is_empty():
			continue
		var def: Dictionary = SkinDatabase.get_item(id)
		if def.is_empty():
			continue
		var rarity := String(def.get("rarity", "common"))
		var w := float(e.get("weight", 0.0)) * float(rarity_table.get(rarity, {}).get("drop_weight", 0.0))
		if w <= 0.0:
			continue
		out.append({
			"item_id": id,
			"rarity": rarity,
			"rank": _rank(rarity, rarity_table),
			"w": w,
		})
	return out


static func _at_least(entries: Array, min_rank: int) -> Array:
	var out: Array = []
	for e in entries:
		if int(e["rank"]) >= min_rank:
			out.append(e)
	return out


static func _weighted_pick(entries: Array, rng: RandomNumberGenerator) -> Dictionary:
	var total := 0.0
	for e in entries:
		total += float(e["w"])
	if total <= 0.0:
		return entries[0]
	var pick := rng.randf() * total
	var acc := 0.0
	for e in entries:
		acc += float(e["w"])
		if pick <= acc:
			return e
	return entries[entries.size() - 1]


static func _rank(rarity: String, rarity_table: Dictionary) -> int:
	return int(rarity_table.get(rarity, {}).get("id", 0))
