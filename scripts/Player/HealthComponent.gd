extends Node
class_name HealthComponent
##
## HealthComponent.gd — 生命值 / 护甲 / 伤害结算
##
## 伤害结算顺序:
##   1. 判定护甲是否参与吸收(爆头且无头盔 -> 护甲无效)
##   2. 按武器穿透力削弱护甲吸收效率
##   3. 护甲值低于 20 时吸收效率线性衰减
##   4. 护甲扣减 50% 原始伤害, 剩余进入生命值
##

signal health_changed(new_value: float, max_value: float)
signal armor_changed(new_value: int)
signal damaged(amount: float, attacker: Node, is_headshot: bool, hit_group: int)
signal died(victim: Node, killer: Node, weapon_id: String, is_headshot: bool)

const ARMOR_LOW_THRESHOLD := 20.0

var max_health: float = GameConfig.MAX_HP
var health: float = GameConfig.MAX_HP
var armor: int = 0
var has_helmet: bool = false
var has_kevlar: bool = false

var alive: bool = true
var last_attacker: Node = null
var last_damage_time: int = 0

## 击杀归属: 由 HitSystem 在 apply_damage 之前写入, 保证死亡事件携带正确凶器
var pending_weapon_id: String = ""
var pending_killer: Node = null
var pending_headshot: bool = false

## 燃烧状态(由燃烧弹施加)
var burn_remaining: float = 0.0
var burn_dps: float = 0.0
var burn_source: Node = null


func reset_full() -> void:
	health = max_health
	armor = 0
	has_helmet = false
	has_kevlar = false
	alive = true
	last_attacker = null
	pending_weapon_id = ""
	pending_killer = null
	pending_headshot = false
	burn_remaining = 0.0
	burn_dps = 0.0
	burn_source = null
	health_changed.emit(health, max_health)
	armor_changed.emit(armor)


## 应用一次伤害, 返回实际扣减的生命值
func apply_damage(raw: float, armor_pen: float, is_headshot: bool,
		hit_group: int, attacker: Node) -> float:
	if not alive or raw <= 0.0:
		return 0.0

	var to_health: float = raw
	var absorbs := true

	# 爆头但无头盔 -> 护甲完全无效
	if is_headshot and not has_helmet:
		absorbs = false
	if armor <= 0:
		absorbs = false

	if absorbs:
		var absorb_ratio: float = GameConfig.ARMOR_HEAVY_ABSORB if has_kevlar else GameConfig.ARMOR_ABSORB
		# 武器穿透力越高, 护甲吸收效率越低
		absorb_ratio *= clampf(1.0 - armor_pen * 0.5, 0.15, 1.0)
		# 护甲残量低时吸收效率线性衰减
		if armor < ARMOR_LOW_THRESHOLD:
			absorb_ratio *= float(armor) / ARMOR_LOW_THRESHOLD

		var absorbed: float = raw * clampf(absorb_ratio, 0.0, 0.9)
		to_health = raw - absorbed
		set_armor(armor - int(ceili(raw * 0.5)))

	if pending_killer == null:
		pending_killer = attacker

	health = maxf(health - to_health, 0.0)
	last_attacker = attacker
	last_damage_time = Time.get_ticks_msec()

	health_changed.emit(health, max_health)
	damaged.emit(to_health, attacker, is_headshot, hit_group)

	if health <= 0.0 and alive:
		alive = false
		pending_headshot = is_headshot
		died.emit(get_parent(), pending_killer, pending_weapon_id, is_headshot)

	return to_health


## 由外部(Combat)在确认击杀武器后调用, 补发精确的死亡事件
func finalize_death(weapon_id: String, killer: Node, is_headshot: bool) -> void:
	if alive:
		return
	died.emit(get_parent(), killer, weapon_id, is_headshot)


func set_armor(v: int) -> void:
	var nv: int = clampi(v, 0, GameConfig.MAX_ARMOR)
	if nv != armor:
		armor = nv
		armor_changed.emit(armor)


func set_helmet(v: bool) -> void:
	has_helmet = v
	armor_changed.emit(armor)


func buy_armor(heavy: bool) -> void:
	armor = GameConfig.MAX_ARMOR
	has_kevlar = true
	has_helmet = heavy
	armor_changed.emit(armor)


func apply_burn(dps: float, duration: float, source: Node) -> void:
	burn_dps = maxf(burn_dps, dps)
	burn_remaining = maxf(burn_remaining, duration)
	burn_source = source


func _process(delta: float) -> void:
	if burn_remaining > 0.0 and alive:
		burn_remaining -= delta
		health = maxf(health - burn_dps * delta, 0.0)
		health_changed.emit(health, max_health)
		if health <= 0.0:
			alive = false
			died.emit(get_parent(), burn_source, "molotov", false)
