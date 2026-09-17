extends Control
class_name HudCanvas
##
## HudCanvas.gd — 准星 / 小地图 / 交互进度条 的绘制层
##
## 全部用 _draw 手写, 不依赖图片资源。准星会随当前扩散实时张开,
## 小地图只显示"符合侦查规则"的敌人(正在被任一队友看到的敌人才会显示)。
##

const MINIMAP_SIZE := 190.0
const MINIMAP_MARGIN := 16.0
const MAP_EXTENT := 35.0          # 地图半宽(米)
const RADAR_RANGE := 34.0         # 雷达可视半径(米)

var actor: Actor = null
var mm: MatchManager = null
var objective: ObjectiveSystem = null

var hitmarker_timer: float = 0.0
var hitmarker_kill: bool = false
var hitmarker_hs: bool = false

var crosshair_gap: float = 4.0
var crosshair_len: float = 7.0
var crosshair_thickness: float = 1.6
var crosshair_dot: bool = false
var crosshair_dynamic: bool = true
var crosshair_scale: float = 1.0

var _flash_alpha: float = 0.0
var _damage_dirs: Array = []      # 受击方向指示

# 命中飘字伤害数字: 本地玩家造成伤害时在准星右侧显示实际扣血量。
# 白=普通命中 / 橙=爆头 / 红=击杀。让"打中到底有没有伤害"一目了然。
var _damage_nums: Array = []
var _friendly_timer: float = 0.0  # 打中队友的提示计时


func _ready() -> void:
	set_process(true)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	EventBus.hitmarker.connect(_on_hitmarker)
	EventBus.player_damaged.connect(_on_player_damaged)
	EventBus.hit_confirmed.connect(_on_hit_confirmed)
	EventBus.friendly_hit.connect(_on_friendly_hit)


func _on_hit_confirmed(attacker: Node, victim: Node, damage: float,
		is_hs: bool, killed: bool) -> void:
	if attacker != actor or victim == null or victim == actor:
		return
	# 队友走 friendly_hit 提示, 不飘伤害数字
	if victim is Actor and (victim as Actor).team == actor.team:
		return
	_damage_nums.append({
		"amount": damage,
		"life": 0.85,
		"max_life": 0.85,
		"hs": is_hs,
		"kill": killed,
		"dx": randf_range(-16.0, 16.0),
	})
	# 防止泼水时无限堆积
	while _damage_nums.size() > 6:
		_damage_nums.pop_front()


func _on_friendly_hit(shooter: Node, _victim: Node) -> void:
	if shooter != actor:
		return
	_friendly_timer = 0.9


func setup(a: Actor, m: MatchManager, o: ObjectiveSystem) -> void:
	actor = a
	mm = m
	objective = o
	crosshair_dynamic = bool(GameManager.get_setting("crosshair_dynamic", true))
	crosshair_scale = clampf(float(GameManager.get_setting("crosshair_scale", 1.0)), 0.75, 1.35)


func _on_hitmarker(is_kill: bool, is_hs: bool) -> void:
	hitmarker_timer = 0.22
	hitmarker_kill = is_kill
	hitmarker_hs = is_hs


func _on_player_damaged(victim: Node, _attacker: Node, _amount: float, _is_hs: bool) -> void:
	if victim != actor:
		return
	if _attacker == null:
		return
	var dir: Vector3 = (_attacker.global_position - actor.global_position).normalized()
	var angle: float = atan2(dir.x, -dir.z)
	_damage_dirs.append({"angle": angle, "life": 1.4})


func _process(delta: float) -> void:
	if hitmarker_timer > 0.0:
		hitmarker_timer -= delta
	if _friendly_timer > 0.0:
		_friendly_timer -= delta
	for d in _damage_dirs:
		d["life"] -= delta
	_damage_dirs = _damage_dirs.filter(func(x): return float(x["life"]) > 0.0)
	for d in _damage_nums:
		d["life"] -= delta
	_damage_nums = _damage_nums.filter(func(x): return float(x["life"]) > 0.0)
	queue_redraw()


func _draw() -> void:
	_draw_crosshair()
	_draw_damage_numbers()
	_draw_friendly_warning()
	_draw_damage_indicators()
	_draw_minimap()
	_draw_action_progress()


# ---------------------------------------------------------------- 准星
func _draw_crosshair() -> void:
	if actor == null or not actor.alive:
		return
	if actor.weapon_system != null and actor.weapon_system.call("is_aiming"):
		var kind: String = str(WeaponDatabase.get_weapon(
			actor.weapon_system.current_id).get("viewmodel", ""))
		if kind == "sniper":
			_draw_scope()
			return

	var center := size * 0.5
	var gap: float = crosshair_gap if crosshair_dynamic else 4.0
	var length: float = crosshair_len * crosshair_scale
	var w: float = crosshair_thickness * crosshair_scale
	var color_text: String = str(GameManager.get_setting("crosshair_color", "#26ff80"))
	var col := Color(color_text)
	col.a = 0.95
	var outline := Color(0, 0, 0, 0.65)

	# 四条线段 + 黑色描边, 保证在亮暗背景上都清晰
	var segs := [
		[Vector2(0, -gap - length), Vector2(0, -gap)],
		[Vector2(0, gap), Vector2(0, gap + length)],
		[Vector2(-gap - length, 0), Vector2(-gap, 0)],
		[Vector2(gap, 0), Vector2(gap + length, 0)],
	]
	for s in segs:
		var a: Vector2 = center + s[0]
		var b: Vector2 = center + s[1]
		draw_line(a, b, outline, w + 2.0)
		draw_line(a, b, col, w)

	if crosshair_dot:
		draw_circle(center, 1.2 * crosshair_scale, col)

	# 命中标记
	if hitmarker_timer > 0.0:
		var k: float = hitmarker_timer / 0.22
		var c: Color = Color(1.0, 0.25, 0.25, k) if hitmarker_hs else Color(1.0, 1.0, 1.0, k)
		if hitmarker_kill:
			c = Color(0.95, 0.15, 0.15, k)
		var d1: float = 5.0
		var d2: float = 11.0 + (1.0 - k) * 3.0
		var pts := [
			[Vector2(-d1, -d1), Vector2(-d2, -d2)],
			[Vector2(d1, -d1), Vector2(d2, -d2)],
			[Vector2(-d1, d1), Vector2(-d2, d2)],
			[Vector2(d1, d1), Vector2(d2, d2)],
		]
		for p in pts:
			draw_line(center + p[0], center + p[1], c, 2.2)
			draw_line(center + p[0] + Vector2(1, 0), center + p[1] + Vector2(1, 0), Color(0, 0, 0, k * 0.6), 1.0)


# ------------------------------------------------- 伤害飘字 / 队友提示
func _draw_damage_numbers() -> void:
	if _damage_nums.is_empty() or actor == null or not actor.alive:
		return
	var center := size * 0.5
	var font := ThemeDB.fallback_font
	for i in _damage_nums.size():
		var d: Dictionary = _damage_nums[i]
		var k: float = clampf(float(d["life"]) / float(d["max_life"]), 0.0, 1.0)
		# 前段快速上浮, 后段减速淡出
		var rise: float = (1.0 - k) * 30.0 + k * k * 14.0
		var pos: Vector2 = center \
			+ Vector2(46.0 + float(d["dx"]), -16.0 - rise - i * 15.0)
		var col: Color
		if bool(d["kill"]):
			col = Color(1.0, 0.22, 0.16, minf(k * 1.8, 1.0))
		elif bool(d["hs"]):
			col = Color(1.0, 0.78, 0.25, minf(k * 1.8, 1.0))
		else:
			col = Color(1.0, 1.0, 1.0, minf(k * 1.8, 1.0))
		var txt := str(roundi(float(d["amount"])))
		var fsize: int = 20 if bool(d["hs"]) else 15
		draw_string_outline(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
			fsize, 3, Color(0, 0, 0, col.a * 0.9))
		draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, col)


func _draw_friendly_warning() -> void:
	if _friendly_timer <= 0.0 or actor == null:
		return
	var k: float = clampf(_friendly_timer / 0.9, 0.0, 1.0)
	var center := size * 0.5
	var font := ThemeDB.fallback_font
	var col := Color(0.45, 0.75, 1.0, k)
	var txt := "队友！"
	# draw_string 的对齐是从 pos 起向右铺满 width, 想居中必须左移半宽
	var draw_pos := center + Vector2(-60.0, 52.0)
	draw_string_outline(font, draw_pos, txt,
		HORIZONTAL_ALIGNMENT_CENTER, 120, 17, 3, Color(0, 0, 0, k * 0.85))
	draw_string(font, draw_pos, txt,
		HORIZONTAL_ALIGNMENT_CENTER, 120, 17, col)


func _draw_scope() -> void:
	var center := size * 0.5
	# 狙击镜: 黑色遮罩 + 十字线 + 密位刻度
	var mask := Color(0, 0, 0, 1.0)
	var r: float = minf(size.x, size.y) * 0.42
	# 上下左右四块遮罩
	draw_rect(Rect2(0, 0, size.x, center.y - r), mask)
	draw_rect(Rect2(0, center.y + r, size.x, size.y - center.y - r), mask)
	draw_rect(Rect2(0, center.y - r, center.x - r, r * 2.0), mask)
	draw_rect(Rect2(center.x + r, center.y - r, size.x - center.x - r, r * 2.0), mask)

	draw_arc(center, r, 0, TAU, 64, Color(0.05, 0.05, 0.05), 3.0)
	draw_line(center + Vector2(-r, 0), center + Vector2(r, 0), Color(0.1, 0.1, 0.1), 1.4)
	draw_line(center + Vector2(0, -r), center + Vector2(0, r), Color(0.1, 0.1, 0.1), 1.4)
	# 密位刻度
	for i in range(1, 6):
		var y: float = center.y + i * 14.0
		if y < center.y + r:
			var half: float = 5.0 if i % 2 == 1 else 9.0
			draw_line(center + Vector2(-half, i * 14.0), center + Vector2(half, i * 14.0),
				Color(0.12, 0.12, 0.12), 1.3)
	draw_circle(center, 2.0, Color(0.9, 0.1, 0.1, 0.9))


func _draw_damage_indicators() -> void:
	var center := size * 0.5
	for d in _damage_dirs:
		var life: float = float(d["life"])
		var alpha: float = clampf(life / 1.4, 0.0, 1.0) * 0.85
		# 世界角度 -> 屏幕角度: 以玩家朝向为基准
		var relative: float = float(d["angle"]) - actor.base_yaw
		var r: float = minf(size.x, size.y) * 0.16
		var pos: Vector2 = center + Vector2(sin(relative), -cos(relative)) * r
		draw_arc(center, r, 0, TAU, 48, Color(0, 0, 0, 0.0), 0.0)
		var c := Color(1.0, 0.15, 0.1, alpha)
		draw_circle(pos, 5.0, c)
		draw_arc(pos, 5.0, 0, TAU, 16, Color(0, 0, 0, alpha * 0.7), 1.2)


# ---------------------------------------------------------------- 小地图
func _world_to_radar(p: Vector3) -> Vector2:
	var nx: float = (p.x + MAP_EXTENT) / (MAP_EXTENT * 2.0)
	var nz: float = (p.z + MAP_EXTENT) / (MAP_EXTENT * 2.0)
	return Vector2(
		MINIMAP_MARGIN + nx * MINIMAP_SIZE,
		MINIMAP_MARGIN + nz * MINIMAP_SIZE)


func _draw_minimap() -> void:
	if actor == null:
		return
	var rect := Rect2(MINIMAP_MARGIN, MINIMAP_MARGIN, MINIMAP_SIZE, MINIMAP_SIZE)
	draw_rect(rect, Color(0.06, 0.08, 0.10, 0.62))
	draw_rect(rect, Color(0.55, 0.65, 0.75, 0.45), false, 1.5)

	# 裁剪到雷达范围
	var center_radar := _world_to_radar(actor.global_position)
	var clip_r: float = (RADAR_RANGE / (MAP_EXTENT * 2.0)) * MINIMAP_SIZE

	# 炸弹点
	for s in mm.sites:
		var site: BombSite = s as BombSite
		if site == null:
			continue
		var p := _world_to_radar(site.global_position)
		if p.distance_to(center_radar) > MINIMAP_SIZE:
			continue
		var col: Color = Color(1.0, 0.35, 0.15, 0.85) if site.is_planted else Color(0.85, 0.75, 0.35, 0.55)
		draw_rect(Rect2(p - Vector2(7, 7), Vector2(14, 14)), col)
		draw_rect(Rect2(p - Vector2(7, 7), Vector2(14, 14)), Color(0, 0, 0, 0.6), false, 1.0)

	# 装置
	if objective != null and objective.is_planted():
		var bp := _world_to_radar(objective.get_planted_position())
		var pulse: float = 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.012)
		draw_circle(bp, 5.0 * pulse + 2.0, Color(1.0, 0.2, 0.1, 0.95))
	elif objective != null and objective.get_carrier() != null:
		var carrier: Actor = objective.get_carrier()
		if carrier.team == actor.team:
			var cp := _world_to_radar(carrier.global_position)
			draw_circle(cp, 3.5, Color(1.0, 0.85, 0.2, 0.9))

	# 单位
	var spotted: Array = _get_spotted_enemies()
	for a in mm.actors:
		var other: Actor = a as Actor
		if other == null or not other.alive:
			continue
		var p := _world_to_radar(other.global_position)
		if p.distance_to(center_radar) > MINIMAP_SIZE * 0.95:
			continue
		var is_ally: bool = other.team == actor.team
		if not is_ally and not (other in spotted):
			continue
		var col: Color = GameConfig.TEAM_COLOR.get(other.team, Color.WHITE)
		if not is_ally:
			col = Color(1.0, 0.25, 0.2, 0.95)
		# 朝向短线
		var fwd := Vector2(sin(other.base_yaw), -cos(other.base_yaw)) * 7.0
		draw_line(p, p + fwd, col, 2.0)
		draw_circle(p, 3.4, col)
		draw_circle(p, 3.4, Color(0, 0, 0, 0.55), false, 1.0)

	# 自己(三角形, 始终朝向正上方)
	var tip: Vector2 = center_radar + Vector2(0, -7)
	var left: Vector2 = center_radar + Vector2(-5, 5)
	var right: Vector2 = center_radar + Vector2(5, 5)
	draw_colored_polygon(PackedVector2Array([tip, left, right]), Color(1, 1, 1, 0.95))
	draw_line(tip, left, Color(0, 0, 0, 0.6), 1.2)
	draw_line(left, right, Color(0, 0, 0, 0.6), 1.2)
	draw_line(right, tip, Color(0, 0, 0, 0.6), 1.2)

	# 视野扇形
	var view_half: float = deg_to_rad(45.0)
	var arc_pts := PackedVector2Array([center_radar])
	for i in range(13):
		var ang: float = -PI * 0.5 - view_half + (view_half * 2.0) * (float(i) / 12.0)
		arc_pts.append(center_radar + Vector2(cos(ang), sin(ang)) * 26.0)
	draw_colored_polygon(arc_pts, Color(1, 1, 1, 0.07))


## 侦查规则: 只显示"正在被任一存活队友看到"的敌人, 不直接暴露全场位置
func _get_spotted_enemies() -> Array:
	var out: Array = []
	if actor == null:
		return out
	for a in mm.actors:
		var ally: Actor = a as Actor
		if ally == null or not ally.alive or ally.team != actor.team or ally == actor:
			continue
		var bot := _find_bot_controller(ally)
		if bot == null:
			continue
		for e in bot.visible_enemies:
			if is_instance_valid(e) and e.alive and not (e in out):
				out.append(e)
	return out


func _find_bot_controller(a: Actor) -> BotController:
	for c in a.controllers:
		if c is BotController:
			return c
	return null


# ---------------------------------------------------------------- 交互进度
func _draw_action_progress() -> void:
	if actor == null:
		return
	var progress: float = -1.0
	var label: String = ""
	if actor.is_planting:
		progress = actor.action_progress
		label = "安装目标装置"
	elif actor.is_defusing:
		progress = actor.action_progress
		label = "拆除目标装置"

	if progress < 0.0:
		return
	var w: float = 240.0
	var h: float = 10.0
	var x: float = (size.x - w) * 0.5
	var y: float = size.y * 0.62
	draw_rect(Rect2(x - 1, y - 1, w + 2, h + 2), Color(0, 0, 0, 0.75))
	draw_rect(Rect2(x, y, w, h), Color(0.16, 0.18, 0.22, 0.9))
	var fill_col: Color = Color(1.0, 0.55, 0.15) if actor.is_planting else Color(0.3, 0.8, 1.0)
	draw_rect(Rect2(x, y, w * clampf(progress, 0.0, 1.0), h), fill_col)

	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(x, y - 8), label,
		HORIZONTAL_ALIGNMENT_CENTER, w, 14, Color(1, 1, 1, 0.95))
