extends RefCounted
class_name LagComp
##
## LagComp.gd — 服务器命中回溯(Lag Compensation)
##
## 问题: 客户端看到的画面比服务器滞后(网络延迟 + 插值缓冲)。玩家开枪时瞄准的是
##       "过去的位置", 如果服务器直接用当前位置判定, 高延迟玩家永远打不中移动目标。
##
## 方案: 服务器保留每个角色最近 HISTORY_MS 的位置历史; 处理某个 peer 的射击请求时,
##       把其他角色按该 peer 的延迟倒回到"他当时看到的位置"再判定, 判定完恢复。
##
## 注意: 倒回只影响碰撞用的 transform, 不写入任何游戏状态(血量/弹药不受影响)。
##

const HISTORY_MS := 1000.0      # 保留 1 秒历史
const MAX_REWIND_MS := 250.0    # 最多回溯 250ms(超过说明是异常客户端)
const SAMPLE_INTERVAL_MS := 16.0  # 约 60Hz 采样

## actor -> [{t: float(ms), pos: Vector3, yaw: float}]
static var _history: Dictionary = {}
## 上一次采样时间 actor -> ms
static var _last_sample: Dictionary = {}
## 倒回时保存的现场: actor -> {pos, yaw}
static var _saved: Dictionary = {}


static func record(actor: Node, now_ms: float) -> void:
	if actor == null or not is_instance_valid(actor):
		return
	var arr: Array = _history.get(actor, [])
	# 按间隔采样, 避免历史数组膨胀
	var last: float = float(_last_sample.get(actor, -9999.0))
	if now_ms - last < SAMPLE_INTERVAL_MS:
		return
	_last_sample[actor] = now_ms
	arr.append({
		"t": now_ms,
		"pos": actor.global_position,
		"yaw": actor.get("base_yaw") if "base_yaw" in actor else actor.rotation.y,
	})
	# 裁剪过期记录
	while arr.size() > 2 and float(arr[0]["t"]) < now_ms - HISTORY_MS:
		arr.pop_front()
	_history[actor] = arr


static func clear() -> void:
	_history.clear()
	_last_sample.clear()
	_saved.clear()


static func forget(actor: Node) -> void:
	_history.erase(actor)
	_last_sample.erase(actor)
	_saved.erase(actor)


## 估算某角色在 (now_ms - rewind_ms) 时刻的位置
static func sample_past(actor: Node, target_ms: float) -> Dictionary:
	var arr: Array = _history.get(actor, [])
	if arr.size() < 2:
		return {}
	# 二分/线性查找最近的两条记录做插值
	for i in range(arr.size() - 1, -1, -1):
		var t: float = float(arr[i]["t"])
		if t <= target_ms:
			if i + 1 < arr.size():
				var t2: float = float(arr[i + 1]["t"])
				var k: float = clampf((target_ms - t) / maxf(t2 - t, 0.001), 0.0, 1.0)
				return {
					"pos": arr[i]["pos"].lerp(arr[i + 1]["pos"], k),
					"yaw": lerpf(float(arr[i]["yaw"]), float(arr[i + 1]["yaw"]), k),
				}
			return {"pos": arr[i]["pos"], "yaw": float(arr[i]["yaw"])}
	# 目标比所有历史都旧 -> 用最老的一条
	return {"pos": arr[0]["pos"], "yaw": float(arr[0]["yaw"])}


## 倒回除 exclude 以外所有角色到 (now_ms - rewind_ms)
static func rewind_all(actors: Array, exclude: Node, rewind_ms: float, now_ms: float) -> void:
	_saved.clear()
	if rewind_ms <= 0.0:
		return
	if rewind_ms > MAX_REWIND_MS:
		rewind_ms = MAX_REWIND_MS
	var target: float = now_ms - rewind_ms
	for a in actors:
		if a == null or not is_instance_valid(a) or a == exclude:
			continue
		var past := sample_past(a, target)
		if past.is_empty():
			continue
		_saved[a] = {
			"pos": a.global_position,
			"yaw": a.get("base_yaw") if "base_yaw" in a else a.rotation.y,
		}
		a.global_position = past["pos"]
		if "base_yaw" in a:
			a.set("base_yaw", past["yaw"])
		a.force_update_transform()


## 恢复到倒回前的现场
static func restore_all() -> void:
	for a in _saved:
		if a == null or not is_instance_valid(a):
			continue
		var s: Dictionary = _saved[a]
		a.global_position = s["pos"]
		if "base_yaw" in a:
			a.set("base_yaw", s["yaw"])
		a.force_update_transform()
	_saved.clear()


static func is_rewound() -> bool:
	return not _saved.is_empty()
