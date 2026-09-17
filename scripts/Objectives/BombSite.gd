extends Area3D
class_name BombSite
##
## BombSite.gd — 目标点区域 (A / B)
##
## 只负责"谁在里面"与视觉提示, 安装/拆除的进度推进交给 ObjectiveSystem。
##

signal actor_entered(actor: Node)
signal actor_exited(actor: Node)

@export var site_name: String = "A"
@export var site_size: Vector2 = Vector2(9.0, 9.0)

var is_planted: bool = false
var _inside: Array = []

var _marker: MeshInstance3D
var _marker_mat: StandardMaterial3D
var _beacon: OmniLight3D


func _ready() -> void:
	name = "BombSite_" + site_name
	collision_layer = 0
	collision_mask = GameConfig.LAYER_PLAYER
	monitoring = true
	monitorable = false
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(site_size.x, 3.0, site_size.y)
	shape.shape = box
	shape.position = Vector3(0, 1.5, 0)
	add_child(shape)

	_build_marker()
	set_process(true)


func _build_marker() -> void:
	_marker = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = site_size
	plane.orientation = PlaneMesh.FACE_Y
	_marker.mesh = plane
	_marker.position = Vector3(0, 0.03, 0)
	_marker_mat = StandardMaterial3D.new()
	_marker_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_mat.albedo_color = Color(1.0, 0.62, 0.15, 0.16)
	_marker_mat.emission_enabled = true
	_marker_mat.emission = Color(1.0, 0.55, 0.12)
	_marker_mat.emission_energy_multiplier = 0.7
	_marker_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_marker.material_override = _marker_mat
	add_child(_marker)

	_beacon = OmniLight3D.new()
	_beacon.light_color = Color(1.0, 0.55, 0.15)
	_beacon.light_energy = 1.6
	_beacon.omni_range = 12.0
	_beacon.position = Vector3(0, 2.4, 0)
	_beacon.shadow_enabled = false
	add_child(_beacon)


func _on_body_entered(body: Node) -> void:
	var a := body as Actor
	if a == null:
		return
	_inside.append(a)
	actor_entered.emit(a)


func _on_body_exited(body: Node) -> void:
	var a := body as Actor
	if a == null:
		return
	_inside.erase(a)
	actor_exited.emit(a)


func contains(actor: Actor) -> bool:
	return actor in _inside


func get_actors_inside() -> Array:
	var out: Array = []
	for a in _inside:
		if is_instance_valid(a) and a.alive:
			out.append(a)
	return out


func set_planted(v: bool) -> void:
	is_planted = v
	if _marker_mat != null:
		_marker_mat.albedo_color = Color(1.0, 0.25, 0.15, 0.30) if v \
			else Color(1.0, 0.62, 0.15, 0.16)
	if _beacon != null:
		_beacon.light_color = Color(1.0, 0.2, 0.12) if v else Color(1.0, 0.55, 0.15)


func _process(delta: float) -> void:
	if _beacon != null:
		var pulse: float = 1.4 + sin(Time.get_ticks_msec() * 0.004) * 0.5
		_beacon.light_energy = pulse * (2.2 if is_planted else 1.0)
