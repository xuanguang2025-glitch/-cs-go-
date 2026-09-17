extends Node
##
## ReplaySystem.gd — Demo 录像/回放(Autoload)
##
## 录制: 30Hz 记录全部角色的位置/朝向/血量/存活, 外加击杀·开火·装置·投掷事件。
##       一局 5 分钟 10 人约 6MB 内存, 控制在 MAX_FRAMES 内自动丢弃最旧的。
## 回放: 按时间轴插值采样, 驱动"回放代理"角色(简易胶囊, 不跑 AI)。
## 存档: 可导出/导入 user://replays/<时间戳>.json。
##

const HZ := 30.0
const FRAME_MS := 1000.0 / HZ
const MAX_FRAMES := 30 * 60 * 10      # 10 分钟上限
const REPLAY_DIR := "user://replays"

var recording: bool = false
var frames: Array = []                # [{t, a:[[id,px,py,pz,yaw,pitch,hp,alive,team],...]}]
var events: Array = []                # [{t, type, data}]
var meta: Dictionary = {}
var _accum: float = 0.0
var _start_ms: int = 0

# --- 回放状态
var playing: bool = false
var play_head: float = 0.0
var play_speed: float = 1.0


func _ready() -> void:
	set_process(false)


# ================================================================ 录制
func start_recording(map_name: String) -> void:
	frames.clear()
	events.clear()
	meta = {"map": map_name, "h": HZ}
	_accum = 0.0
	_start_ms = Time.get_ticks_msec()
	recording = true
	set_process(true)


func stop_recording() -> void:
	recording = false
	set_process(false)


func _process(delta: float) -> void:
	if playing:
		play_head += delta * play_speed * 1000.0
		return
	if not recording:
		return
	_accum += delta * 1000.0
	if _accum >= FRAME_MS:
		_accum -= FRAME_MS
		capture_frame()


func capture_frame() -> void:
	var mm = GameManager.match_manager
	if mm == null:
		return
	if frames.size() >= MAX_FRAMES:
		frames.pop_front()
	var row: Array = []
	var idx: int = 0
	for a in mm.actors:
		var actor: Actor = a as Actor
		if actor == null:
			continue
		row.append([
			idx,
			snappedf(actor.global_position.x, 0.001),
			snappedf(actor.global_position.y, 0.001),
			snappedf(actor.global_position.z, 0.001),
			snappedf(actor.base_yaw, 0.001),
			snappedf(actor.base_pitch, 0.001),
			snappedf(actor.health.health, 1.0),
			actor.alive,
			actor.team,
		])
		idx += 1
	frames.append({
		"t": Time.get_ticks_msec() - _start_ms,
		"a": row,
	})


func add_event(type: String, data: Dictionary) -> void:
	if not recording:
		return
	events.append({
		"t": Time.get_ticks_msec() - _start_ms,
		"type": type,
		"data": data,
	})


# ================================================================ 回放查询
func duration_ms() -> float:
	if frames.is_empty():
		return 0.0
	return float(frames[frames.size() - 1]["t"])


## 采样某一时刻(线性插值), 返回 {id: {pos, yaw, pitch, hp, alive, team}}
func sample(t_ms: float) -> Dictionary:
	if frames.is_empty():
		return {}
	var i: int = clampi(int(t_ms / FRAME_MS), 0, frames.size() - 1)
	var j: int = mini(i + 1, frames.size() - 1)
	var fa: Array = frames[i]["a"]
	var fb: Array = frames[j]["a"]
	var k: float = 0.0
	if j > i:
		var t1: float = float(frames[i]["t"])
		var t2: float = float(frames[j]["t"])
		k = clampf((t_ms - t1) / maxf(t2 - t1, 0.001), 0.0, 1.0)
	var out: Dictionary = {}
	for n in fa.size():
		var ra: Array = fa[n]
		var id: int = int(ra[0])
		var rb: Array = fb[n] if n < fb.size() else ra
		out[id] = {
			"pos": Vector3(ra[1], ra[2], ra[3]).lerp(
				Vector3(rb[1], rb[2], rb[3]), k),
			"yaw": lerpf(float(ra[4]), float(rb[4]), k),
			"pitch": lerpf(float(ra[5]), float(rb[5]), k),
			"hp": lerpf(float(ra[6]), float(rb[6]), k),
			"alive": bool(ra[7]),
			"team": int(ra[8]),
		}
	return out


func play() -> void:
	if frames.is_empty():
		return
	playing = true
	play_head = 0.0
	set_process(true)


func pause() -> void:
	playing = false


func seek(t_ms: float) -> void:
	play_head = clampf(t_ms, 0.0, duration_ms())


# ================================================================ 存档
func save_replay() -> String:
	if frames.is_empty():
		return ""
	DirAccess.make_dir_recursive_absolute(REPLAY_DIR)
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = "%s/%s.json" % [REPLAY_DIR, stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify({
		"meta": meta, "frames": frames, "events": events,
	}))
	f.close()
	return path


func load_replay(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary):
		return false
	meta = data.get("meta", {})
	frames = data.get("frames", [])
	events = data.get("events", [])
	return true


func list_replays() -> Array:
	if not DirAccess.dir_exists_absolute(REPLAY_DIR):
		return []
	var out: Array = []
	var d := DirAccess.open(REPLAY_DIR)
	if d == null:
		return out
	for file in d.get_files():
		if file.ends_with(".json"):
			out.append("%s/%s" % [REPLAY_DIR, file])
	out.sort()
	out.reverse()
	return out
