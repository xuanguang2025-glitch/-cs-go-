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

## 准星四段的中心留白(像素)。
##   CROSSHAIR_GAP_AUTO(-1) = 自动: 按当前真实扩散锥在屏幕上的投影半径绘制,
##                            即"准星张开多少 = 子弹可能偏多少"(G1 修复的核心)。
##   >= 0                   = 显式覆盖值, 保留给外部/调试使用。
const CROSSHAIR_GAP_AUTO := -1.0
const CROSSHAIR_GAP_STATIC := 4.0     # crosshair_dynamic = false 时的固定留白
const CROSSHAIR_GAP_MIN := 3.0        # 自动模式下的下限, 避免散布极小时准星糊成一团
const CROSSHAIR_GAP_MAX_RATIO := 0.30 # 自动模式下上限 = 屏幕短边 * 该系数, 防止飞出屏幕

var crosshair_gap: float = CROSSHAIR_GAP_AUTO
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
	_draw_objective_markers()
	_draw_crosshair()
	_draw_damage_numbers()
	_draw_friendly_warning()
	_draw_damage_indicators()
	_draw_minimap()
	_draw_action_progress()


# ---------------------------------------------------------------- 准星

## 把一个"半角 spread_deg 的圆锥"投影到屏幕上, 返回它距离屏幕中心的**像素半径**。
##
## 这是 G1 的关键: 旧的准星留白是 `3.0 + spread * 1.35` 的经验像素映射, 与相机
## 视场角无关, 在 105° 视场下把真实散布**低估了约 3 倍**(ar17 腰射 3.4° 实测应为
## 约 24.6px, 旧公式只给 7.6px)。玩家看到"准星很小、准心压在目标身上", 实际子弹
## 落在一个半径 1.19m(@20m) 的圆里 —— 这就是"瞄得准打不中"的直接观感来源。
##
## 投影关系(透视相机): 屏幕半宽对应 tan(hfov/2), 角 θ 对应 tan(θ), 故
##   r_px = (view.x / 2) * tan(θ) / tan(hfov / 2)
## Godot 的 Camera3D.fov 是**垂直**视场角(keep_aspect = KEEP_HEIGHT 时),
## 水平视场角需要按宽高比换算: hfov = 2 * atan(tan(fov_v/2) * view.x / view.y)。
##
## 抽成 static 是为了让无头环境也能断言(不依赖任何渲染输出)。
static func cone_radius_px(spread_deg: float, view: Vector2, fov_v_deg: float) -> float:
	if view.x <= 0.0 or view.y <= 0.0:
		return 0.0
	var fov_v: float = clampf(fov_v_deg, 0.5, 179.0)
	var half_v_tan: float = tan(deg_to_rad(fov_v * 0.5))
	var half_h_tan: float = half_v_tan * (view.x / view.y)
	if half_h_tan <= 0.000001:
		return 0.0
	var spread: float = maxf(spread_deg, 0.0)
	if spread >= 89.0:
		spread = 89.0
	return (view.x * 0.5) * (tan(deg_to_rad(spread)) / half_h_tan)


## 当前应该用的准星留白(像素)。
##   crosshair_dynamic = false -> 固定 CROSSHAIR_GAP_STATIC(即"静态准星"选项)
##   crosshair_gap >= 0        -> 显式覆盖值
##   否则                      -> 按当前真实扩散与当前相机视场角忠实投影
func _crosshair_gap_px() -> float:
	if not crosshair_dynamic:
		return CROSSHAIR_GAP_STATIC
	if crosshair_gap >= 0.0:
		return crosshair_gap
	if actor == null or actor.weapon_system == null:
		return CROSSHAIR_GAP_MIN
	var spread: float = float(actor.weapon_system.call("get_current_spread"))
	var fov_v: float = 90.0
	var cam := actor.get_camera()
	if cam != null:
		fov_v = cam.fov          # 开镜/倍镜时 FOV 会收窄, 留白随之等比缩小
	var r: float = cone_radius_px(spread, size, fov_v)
	var cap: float = minf(size.x, size.y) * CROSSHAIR_GAP_MAX_RATIO
	return clampf(r, CROSSHAIR_GAP_MIN, maxf(cap, CROSSHAIR_GAP_MIN))


func _draw_crosshair() -> void:
	if actor == null or not actor.alive:
		return
	if actor.weapon_system != null and actor.weapon_system.call("is_aiming"):
		var kind: String = str(WeaponDatabase.get_weapon(
			actor.weapon_system.current_id).get("viewmodel", ""))
		# 狙击镜: 按 viewmodel 判定; 另外任何声明了 scope_zoom 的武器同样走镜内视图
		if kind == "sniper" or bool(actor.weapon_system.call("has_scope")):
			_draw_scope()
			return

	var center := size * 0.5
	var gap: float = _crosshair_gap_px()
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


## 圆形镜筒遮罩的内/外圈采样点。返回 [内圈(PackedVector2Array), 外圈(PackedVector2Array)]。
##   内圈: 以 center 为心、半径 r 的圆
##   外圈: 从 center 沿同一方向射出、打到 view 矩形边界的点
## 两者之间用四边形环带填充即可精确挖出一个圆孔。抽成静态方法是为了让
## 无头环境(没有渲染输出)也能直接断言几何正确性, 不必依赖截图。
static func build_scope_ring(center: Vector2, r: float, view: Vector2,
		seg: int = 72) -> Array:
	var inner := PackedVector2Array()
	var outer := PackedVector2Array()
	inner.resize(seg)
	outer.resize(seg)
	var half: Vector2 = view * 0.5
	for i in seg:
		var ang: float = TAU * float(i) / float(seg)
		var d := Vector2(cos(ang), sin(ang))
		inner[i] = center + d * r
		var t: float = 1.0e9
		if absf(d.x) > 0.0001:
			t = minf(t, half.x / absf(d.x))
		if absf(d.y) > 0.0001:
			t = minf(t, half.y / absf(d.y))
		outer[i] = center + d * t
	return [inner, outer]


func _draw_scope() -> void:
	var center := size * 0.5
	# 狙击镜: 圆形黑色遮罩 + 十字分划 + 密位刻度 + 倍率读数。
	# 全部由 _draw() 程序化绘制(rect / line / arc / polygon), 不依赖任何贴图资源。
	var mask := Color(0, 0, 0, 1.0)
	var r: float = minf(size.x, size.y) * 0.42

	# 真正的圆形遮罩: 旧实现用 4 个矩形挖洞, 留下的其实是一个方孔。
	var ring: Array = build_scope_ring(center, r, size)
	var inner: PackedVector2Array = ring[0]
	var outer: PackedVector2Array = ring[1]
	var seg: int = inner.size()
	for i in seg:
		draw_colored_polygon(PackedVector2Array([
			inner[i], inner[(i + 1) % seg], outer[(i + 1) % seg], outer[i]]), mask)

	draw_arc(center, r, 0, TAU, 96, Color(0.05, 0.05, 0.05), 3.0)
	draw_line(center + Vector2(-r, 0), center + Vector2(r, 0), Color(0.1, 0.1, 0.1), 1.4)
	draw_line(center + Vector2(0, -r), center + Vector2(0, r), Color(0.1, 0.1, 0.1), 1.4)
	# 密位刻度
	for i in range(1, 6):
		var y: float = center.y + i * 14.0
		if y < center.y + r:
			var half_w: float = 5.0 if i % 2 == 1 else 9.0
			draw_line(center + Vector2(-half_w, i * 14.0), center + Vector2(half_w, i * 14.0),
				Color(0.12, 0.12, 0.12), 1.3)
	draw_circle(center, 2.0, Color(0.9, 0.1, 0.1, 0.9))

	# 倍率读数: 直接显示 scope_zoom, 让"数据驱动的倍率"在画面上可验证
	if actor != null and actor.weapon_system != null:
		var zoom: float = float(actor.weapon_system.call("get_scope_zoom"))
		if zoom > 1.0001:
			var font := ThemeDB.fallback_font
			draw_string(font, Vector2(center.x + r * 0.55, center.y + r * 0.78),
				"%.1fx" % zoom, HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
				Color(0.06, 0.06, 0.06, 0.95))


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
			var pulse: float = 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.010)
			draw_circle(cp, 4.0 + 2.0 * pulse, Color(1.0, 0.85, 0.2, 0.28))
			draw_circle(cp, 3.5, Color(1.0, 0.85, 0.2, 0.95))
			draw_circle(cp, 3.5, Color(0, 0, 0, 0.6), false, 1.0)
			var cfont := ThemeDB.fallback_font
			draw_string(cfont, cp + Vector2(-14, -6), "C4",
				HORIZONTAL_ALIGNMENT_CENTER, 28, 11, Color(1.0, 0.88, 0.3, 0.95))

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


# ---------------------------------------------------------------- 目标标记
## 把方向向量 dir 延长到「以原点为中心、半宽 half 的矩形」边界上, 返回边界点。
## 抽成 static 是为了让无头环境也能断言(与 cone_radius_px / build_scope_ring 同一约定)。
static func border_point(dir: Vector2, half: Vector2) -> Vector2:
	var ax: float = absf(dir.x)
	var ay: float = absf(dir.y)
	if ax < 0.0001 and ay < 0.0001:
		return Vector2.ZERO
	var tx: float = (half.x / ax) if ax > 0.0001 else INF
	var ty: float = (half.y / ay) if ay > 0.0001 else INF
	var t: float = minf(tx, ty)
	if not is_finite(t) or t <= 0.0:
		return Vector2.ZERO
	return dir * t


## 目标装置相关的屏幕标记: 下包点 A/B、队友携带者、已安装装置。
## 目的(对应用户反馈"看不清谁带包/去哪下包"):
##   * 任何存活玩家都能看到 A/B 点方位与距离(屏幕外 -> 边缘箭头);
##   * 队友携带装置时其头顶显示醒目 C4 图标 + 名字, 全队一眼看清谁带包;
##   * 装置一旦安装, 全场显示红色装置标记(覆盖下包点指引)。
## 敌方携带者不显示(竞技公平)。
func _draw_objective_markers() -> void:
	if actor == null or not actor.alive or objective == null:
		return
	var cam := actor.get_camera()
	if cam == null or not cam.is_inside_tree():
		return

	if objective.is_planted():
		_draw_world_marker(cam, objective.get_planted_position() + Vector3(0, 1.3, 0),
			"C4", Color(1.0, 0.22, 0.14), "装置已安装")
		return

	for s in objective.sites:
		var site: BombSite = s as BombSite
		if site == null:
			continue
		var dist: float = actor.global_position.distance_to(site.global_position)
		_draw_world_marker(cam, site.global_position + Vector3(0, 2.3, 0),
			site.site_name, Color(1.0, 0.72, 0.22), "%d m" % int(dist))

	var carrier: Actor = objective.get_carrier()
	if carrier != null and carrier != actor and carrier.alive \
			and carrier.team == actor.team:
		_draw_world_marker(cam, carrier.global_position + Vector3(0, 2.05, 0),
			"C4", Color(1.0, 0.86, 0.25), carrier.actor_name)


func _draw_world_marker(cam: Camera3D, world_pos: Vector3, glyph: String,
		color: Color, label: String) -> void:
	var behind: bool = cam.is_position_behind(world_pos)
	var sp: Vector2 = cam.unproject_position(world_pos)
	var center: Vector2 = size * 0.5
	var on_screen: bool = (not behind) and Rect2(Vector2.ZERO, size).has_point(sp)
	if on_screen:
		_draw_marker_icon(sp, glyph, color, label)
		return
	var dir: Vector2 = sp - center
	if behind:
		dir = -dir
	if dir.length_squared() < 0.0001:
		return
	var bp: Vector2 = center + border_point(dir, center - Vector2(56.0, 56.0))
	_draw_edge_arrow(bp, dir.normalized(), color, glyph)


func _draw_marker_icon(sp: Vector2, glyph: String, color: Color, label: String) -> void:
	var font := ThemeDB.fallback_font
	var r: float = 13.0
	var poly := PackedVector2Array([
		sp + Vector2(0, -r), sp + Vector2(r, 0), sp + Vector2(0, r), sp + Vector2(-r, 0)])
	draw_colored_polygon(poly, Color(0, 0, 0, 0.55))
	draw_polyline(PackedVector2Array([poly[0], poly[1], poly[2], poly[3], poly[0]]), color, 2.0)
	draw_string(font, sp + Vector2(-r, 5), glyph, HORIZONTAL_ALIGNMENT_CENTER, int(r * 2), 14, color)
	draw_string_outline(font, sp + Vector2(-70, r + 16), label,
		HORIZONTAL_ALIGNMENT_CENTER, 140, 13, 3, Color(0, 0, 0, 0.85))
	draw_string(font, sp + Vector2(-70, r + 16), label,
		HORIZONTAL_ALIGNMENT_CENTER, 140, 13, color)


func _draw_edge_arrow(bp: Vector2, dirn: Vector2, color: Color, glyph: String) -> void:
	var perp := Vector2(-dirn.y, dirn.x)
	var tip: Vector2 = bp + dirn * 12.0
	var a: Vector2 = bp - dirn * 6.0 + perp * 9.0
	var b: Vector2 = bp - dirn * 6.0 - perp * 9.0
	draw_colored_polygon(PackedVector2Array([tip, a, b]), color)
	draw_polyline(PackedVector2Array([tip, a, b, tip]), Color(0, 0, 0, 0.6), 1.5)
	var font := ThemeDB.fallback_font
	var lp: Vector2 = bp - dirn * 18.0
	draw_string(font, lp + Vector2(-20, 5), glyph, HORIZONTAL_ALIGNMENT_CENTER, 40, 14, color)
