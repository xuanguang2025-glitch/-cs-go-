extends Node
##
## WeaponDatabase.gd — 武器 / 投掷物数据加载与查询
## Autoload 名: WeaponDatabase
##
## 所有平衡数据来自 data/*.json。代码里不允许出现硬编码的武器数值。
##

const WEAPON_PATH := "res://data/weapons.json"
const GRENADE_PATH := "res://data/grenades.json"

var _weapons: Dictionary = {}
var _grenades: Dictionary = {}
var _by_class: Dictionary = {}

# 起始配枪(手枪局)
const DEFAULT_PISTOL := {
	GameConfig.Team.STRIKE: "m7",
	GameConfig.Team.GUARD: "p01",
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_all()


## 重新加载全部数据(支持热更新平衡数值)
func load_all() -> bool:
	var ok_w := _load_weapons()
	var ok_g := _load_grenades()
	_build_class_index()
	return ok_w and ok_g


func _load_weapons() -> bool:
	var raw = _read_json(WEAPON_PATH)
	if raw == null:
		push_error("[WeaponDatabase] 无法加载武器数据: " + WEAPON_PATH)
		return false
	_weapons.clear()
	for key in raw:
		if key.begins_with("_"):
			continue
		var d: Dictionary = raw[key]
		_weapons[key] = _normalize_weapon(d)
	print("[WeaponDatabase] 已加载 %d 把武器" % _weapons.size())
	return _weapons.size() > 0


func _load_grenades() -> bool:
	var raw = _read_json(GRENADE_PATH)
	if raw == null:
		push_error("[WeaponDatabase] 无法加载投掷物数据: " + GRENADE_PATH)
		return false
	_grenades.clear()
	for key in raw:
		if key.begins_with("_"):
			continue
		_grenades[key] = raw[key]
	print("[WeaponDatabase] 已加载 %d 种投掷物" % _grenades.size())
	return _grenades.size() > 0


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("[WeaponDatabase] 文件不存在: " + path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[WeaponDatabase] 无法打开文件: " + path)
		return null
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_error("[WeaponDatabase] JSON 解析失败: %s -> %s (第 %d 行)" % [
			path, json.get_error_message(), json.get_error_line()])
		return null
	return json.data


## 补齐缺省字段 + 规范化类型, 避免后续到处做空值判断
func _normalize_weapon(d: Dictionary) -> Dictionary:
	var out := d.duplicate(true)

	out["id"] = str(d.get("id", "unknown"))
	out["display_name"] = str(d.get("display_name", out["id"]))
	out["class"] = str(d.get("class", "rifle"))
	out["slot"] = str(d.get("slot", "primary"))
	out["fire_mode"] = str(d.get("fire_mode", "auto"))
	out["price"] = int(d.get("price", 0))

	out["rpm"] = float(d.get("rpm", 600.0))
	out["fire_interval"] = _fire_interval(out)
	out["damage"] = float(d.get("damage", 30.0))
	out["magazine"] = int(d.get("magazine", 30))
	out["ammo_reserve"] = int(d.get("ammo_reserve", 90))

	out["reload_time"] = float(d.get("reload_time", 2.4))
	out["equip_time"] = float(d.get("equip_time", 0.6))
	out["move_speed_mult"] = float(d.get("move_speed_mult", 0.92))

	out["recoil_recovery"] = float(d.get("recoil_recovery", 8.0))
	out["recoil_pattern"] = _to_vector2_array(d.get("recoil_pattern", [[0.0, 0.5]]))

	out["spread_hip"] = float(d.get("spread_hip", 3.0))
	out["spread_ads"] = float(d.get("spread_ads", 0.3))
	out["spread_move_add"] = float(d.get("spread_move_add", 2.5))
	out["spread_air_add"] = float(d.get("spread_air_add", 5.0))
	out["spread_per_shot"] = float(d.get("spread_per_shot", 0.35))
	out["spread_max"] = float(d.get("spread_max", 7.0))
	out["spread_recovery"] = float(d.get("spread_recovery", 6.0))

	out["range_falloff"] = _to_vector2_array(d.get("range_falloff", [[0, 1.0], [50, 1.0]]))
	out["penetration_power"] = float(d.get("penetration_power", 1.0))
	out["penetration_damage_mult"] = float(d.get("penetration_damage_mult", 0.7))

	out["headshot_mult"] = float(d.get("headshot_mult", 4.0))
	out["body_mult"] = float(d.get("body_mult", 1.0))
	out["leg_mult"] = float(d.get("leg_mult", 0.75))
	out["armor_penetration"] = float(d.get("armor_penetration", 0.7))
	out["kill_reward"] = int(d.get("kill_reward", 300))
	out["pellets"] = int(d.get("pellets", 1))

	out["ads_time"] = float(d.get("ads_time", 0.25))
	out["ads_fov_delta"] = float(d.get("ads_fov_delta", -15.0))
	out["can_ads"] = bool(d.get("can_ads", true))
	out["muzzle_flash"] = float(d.get("muzzle_flash", 1.0))
	out["sound_profile"] = str(d.get("sound_profile", "rifle_mid"))
	out["viewmodel"] = str(d.get("viewmodel", "rifle"))
	out["tracer_color"] = Color(str(d.get("tracer_color", "#ffcf6b")))

	return out


func _fire_interval(d: Dictionary) -> float:
	var rpm: float = float(d.get("rpm", 600.0))
	if rpm <= 0.0:
		return 1.0
	return 60.0 / rpm


func _to_vector2_array(raw: Variant) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if raw is Array:
		for item in raw:
			if item is Array and item.size() >= 2:
				out.append(Vector2(float(item[0]), float(item[1])))
	if out.is_empty():
		out.append(Vector2(0.0, 0.5))
	return out


func _build_class_index() -> void:
	_by_class.clear()
	for key in _weapons:
		var cls: String = _weapons[key]["class"]
		if not _by_class.has(cls):
			_by_class[cls] = []
		_by_class[cls].append(key)


# ---------------------------------------------------------------- 查询接口
func has_weapon(id: String) -> bool:
	return _weapons.has(id)


func get_weapon(id: String) -> Dictionary:
	# 空串是合法状态(角色尚未配枪, 如联机客户端的网络角色),
	# 静默返回空字典; 只有"非空的未知 id"才值得告警。
	if id == "":
		return {}
	if not _weapons.has(id):
		push_warning("[WeaponDatabase] 未知武器 id: " + id)
		return {}
	return _weapons[id]


func get_weapon_name(id: String) -> String:
	if not _weapons.has(id):
		return id.to_upper()
	return str(_weapons[id]["display_name"])


func get_grenade(id: String) -> Dictionary:
	if not _grenades.has(id):
		push_warning("[WeaponDatabase] 未知投掷物 id: " + id)
		return {}
	return _grenades[id]


func get_all_weapons() -> Dictionary:
	return _weapons


func get_all_grenades() -> Dictionary:
	return _grenades


func get_by_class(cls: String) -> Array:
	return _by_class.get(cls, [])


func get_starting_pistol(team: int) -> String:
	return DEFAULT_PISTOL.get(team, "p01")


## 按距离查询伤害衰减系数(分段线性插值)
func damage_falloff(id: String, distance: float) -> float:
	if not _weapons.has(id):
		return 1.0
	var curve: Array = _weapons[id]["range_falloff"]
	if curve.is_empty():
		return 1.0
	if distance <= curve[0].x:
		return curve[0].y
	for i in range(1, curve.size()):
		var prev: Vector2 = curve[i - 1]
		var cur: Vector2 = curve[i]
		if distance <= cur.x:
			var t := (distance - prev.x) / maxf(cur.x - prev.x, 0.0001)
			return lerpf(prev.y, cur.y, t)
	return curve[-1].y


## 取得第 n 发的后坐力偏移(超出表长后循环末尾 6 发)
func recoil_at(id: String, shot_index: int) -> Vector2:
	if not _weapons.has(id):
		return Vector2.ZERO
	var pat: Array = _weapons[id]["recoil_pattern"]
	if pat.is_empty():
		return Vector2.ZERO
	var idx: int = shot_index
	if idx >= pat.size():
		var tail_start: int = maxi(pat.size() - 6, 0)
		var tail_len: int = pat.size() - tail_start
		idx = tail_start + ((shot_index - tail_start) % maxi(tail_len, 1))
	return pat[idx]
