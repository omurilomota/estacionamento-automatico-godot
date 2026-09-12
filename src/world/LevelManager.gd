class_name LevelManager
extends Node2D
## Unified level orchestrator (Mundo.gd + FaseBase.gd, now in English).
## Duck-typed: works with legacy Carro AND the new Vehicle facade.

@export var level_config: LevelConfig = null
@export var random_spawn: bool = true
@export var vehicle_path: NodePath = NodePath("Carro")
@export var waypoints_path: NodePath = NodePath("Waypoints")
@export var spots_path: NodePath = NodePath("Vagas")
@export var planner_path: NodePath = NodePath("Planejador")
@export var camera_path: NodePath = NodePath("Camera")
@export var status_label_path: NodePath = NodePath("UI/Control/StatusLabel")
@export var sensor_label_path: NodePath = NodePath("UI/Control/SensorLabel")
@export var attempt_label_path: NodePath = NodePath("UI/Control/TentativaLabel")
@export var minimap_path: NodePath = NodePath("UI/Control/Minimapa")

var world_size: Vector2 = Vector2(1280, 720)
var _vehicle: Node = null
var _waypoints: Node = null
var _spots: Node = null
var _planner: Node = null
var _camera: Camera2D = null
var _status_label: Label = null
var _sensor_label: Label = null
var _attempt_label: Label = null
var _spawn_pending: bool = true

func _ready() -> void:
	_resolve_nodes()
	_apply_config()
	_boot_vehicle()
	_connect_vehicle()
	_update_status(_vehicle_state_name())

func _physics_process(_d: float) -> void:
	if _spawn_pending:
		_spawn_pending = false
		if random_spawn:
			_spawn_random()

func _process(_d: float) -> void:
	if _sensor_label != null and _vehicle != null:
		_sensor_label.text = "SENSOR: " + _vehicle_sensor_text()
	if _camera != null and _vehicle is Node2D:
		_follow()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_5:
			get_tree().change_scene_to_file(LevelRegistry.LEVELS[event.keycode - KEY_1])
		elif event.keycode == KEY_R:
			get_tree().reload_current_scene()

func _resolve_nodes() -> void:
	_vehicle = _pick([vehicle_path, NodePath("Vehicle")])
	_waypoints = _pick([waypoints_path])
	_spots = _pick([spots_path, NodePath("ParkingSpots")])
	_planner = _pick([planner_path, NodePath("PathPlanner")])
	_camera = _pick([camera_path]) as Camera2D
	_status_label = _pick([status_label_path]) as Label
	_sensor_label = _pick([sensor_label_path]) as Label
	_attempt_label = _pick([attempt_label_path]) as Label

func _pick(paths: Array) -> Node:
	for p in paths:
		var n := get_node_or_null(p)
		if n != null:
			return n
	return null

func _apply_config() -> void:
	if level_config != null:
		random_spawn = level_config.random_spawn
		if level_config.map_texture != null:
			world_size = level_config.map_texture.get_size() * level_config.map_scale
	if _camera != null:
		_camera.make_current()
		if level_config != null:
			_camera.zoom = Vector2(level_config.camera_zoom, level_config.camera_zoom)
		if _vehicle is Node2D:
			_camera.position = (_vehicle as Node2D).global_position
	var mm := get_node_or_null(minimap_path)
	if mm != null:
		mm.set("mundo_centro", Vector2.ZERO)
		mm.set("mundo_tamanho", world_size)
	if _planner != null:
		_planner.set("origem", Vector2(-world_size.x / 2.0, -world_size.y / 2.0))
		_planner.set("tamanho", world_size)

func _boot_vehicle() -> void:
	if _vehicle == null:
		return
	if _vehicle.has_method("start_trail_mode"):
		_vehicle.call("start_trail_mode")
	elif _vehicle.has_method("iniciar_modo_trilha"):
		_vehicle.call("iniciar_modo_trilha")
	elif _vehicle.has_method("start_navigation"):
		_vehicle.call("start_navigation")
	elif _vehicle.has_method("iniciar_navegacao"):
		_vehicle.call("iniciar_navegacao")
	else:
		_vehicle_set_points(_waypoint_points())

func _waypoint_points() -> Array:
	var pts: Array = []
	if _waypoints != null:
		for wp in _waypoints.get_children():
			pts.append((wp as Node2D).global_position)
	return pts

func _connect_vehicle() -> void:
	if _vehicle == null:
		return
	_sub(_vehicle, "state_changed", "estado_mudou", _on_state)
	_sub(_vehicle, "attempt_changed", "tentativa_mudou", _on_attempt)
	_sub(_vehicle, "spot_change_requested", "pedir_nova_vaga", _on_spot_request)

func _sub(node: Node, en: String, legacy: String, cb: Callable) -> void:
	var sig := en if node.has_signal(en) else legacy
	if node.has_signal(sig) and not node.is_connected(sig, cb):
		node.connect(sig, cb)

func _vehicle_state_name() -> String:
	if _vehicle == null:
		return "SEEKING"
	if _vehicle.has_method("state_label_en"):
		return str(_vehicle.call("state_label_en"))
	if _vehicle.has_method("nome_estado"):
		return str(_vehicle.call("nome_estado"))
	return "SEEKING"

func _vehicle_sensor_text() -> String:
	if _vehicle == null:
		return "Free"
	if _vehicle.has_method("sensor_summary"):
		return str(_vehicle.call("sensor_summary"))
	if _vehicle.has_method("get_sensor_text"):
		return str(_vehicle.call("get_sensor_text"))
	return "Free"

func _vehicle_is_trail() -> bool:
	if _vehicle == null:
		return false
	if _vehicle.has_method("is_trail_following"):
		return bool(_vehicle.call("is_trail_following"))
	return bool(_vehicle.get("modo_trilha"))

func _vehicle_is_auto() -> bool:
	if _vehicle == null:
		return false
	if _vehicle.has_method("is_autonomous"):
		return bool(_vehicle.call("is_autonomous"))
	return bool(_vehicle.get("auto_navegacao"))

func _vehicle_set_points(pts: Array) -> void:
	if _vehicle == null:
		return
	if _vehicle.has_method("set_waypoints"):
		_vehicle.call("set_waypoints", pts)
	elif _vehicle.has_method("definir_waypoints"):
		_vehicle.call("definir_waypoints", pts)

func _update_status(key: String) -> void:
	_on_state(key)

func _on_state(key) -> void:
	if _status_label == null:
		return
	var k := str(key)
	var label: String = LevelRegistry.STATE_LABELS.get(k, k)
	if _vehicle_is_trail() and (k == "AVOIDING" or k == "DESVIANDO"):
		_status_label.text = "STATUS: Stopped (obstacle ahead)"
	else:
		_status_label.text = "STATUS: " + label

func _on_attempt(count: int, strategy: String) -> void:
	if _attempt_label != null:
		_attempt_label.text = "ATTEMPT: %d - %s" % [count, strategy]

func _on_spot_request() -> void:
	if _vehicle == null or _spots == null or _vehicle_is_auto():
		return
	for spot in _spots.get_children():
		if not bool(spot.get("ocupada")):
			if _attempt_label != null:
				_attempt_label.text = "ATTEMPT: 0 - Seeking another spot"
			_vehicle_set_points([(spot as Node2D).global_position])
			return
	if _status_label != null:
		_status_label.text = "STATUS: No free spots"

func _spawn_random() -> void:
	if _vehicle == null or _planner == null or _spots == null:
		return
	var ready_now: bool = bool(_planner.call("is_grid_ready")) if _planner.has_method("is_grid_ready") else bool(_planner.call("grade_pronta"))
	if not ready_now:
		_planner.call("build_grid" if _planner.has_method("build_grid") else "construir")
	var excluded: Array[Rect2] = []
	for spot in _spots.get_children():
		var area := (spot as Node).get_node_or_null("Area") as CollisionShape2D
		if area != null and area.shape is RectangleShape2D:
			var rs: Vector2 = (area.shape as RectangleShape2D).size
			excluded.append(Rect2((spot as Node2D).global_position - rs * 0.5, rs).grow(50.0))
	var pos: Vector2 = _planner.call("find_free_spawn", excluded) if _planner.has_method("find_free_spawn") else _planner.call("achar_posicao_livre", excluded)
	if pos == Vector2.INF:
		return
	(_vehicle as Node2D).global_position = pos
	(_vehicle as Node2D).rotation = 0.0

func _follow() -> void:
	var half_view: Vector2 = get_viewport_rect().size * 0.5 / _camera.zoom
	var half_world: Vector2 = world_size * 0.5
	var pos: Vector2 = (_vehicle as Node2D).global_position
	if world_size.x > half_view.x * 2.0:
		pos.x = clampf(pos.x, -half_world.x + half_view.x, half_world.x - half_view.x)
	else:
		pos.x = 0.0
	if world_size.y > half_view.y * 2.0:
		pos.y = clampf(pos.y, -half_world.y + half_view.y, half_world.y - half_view.y)
	else:
		pos.y = 0.0
	_camera.position = pos
