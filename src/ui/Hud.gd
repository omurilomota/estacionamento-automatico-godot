class_name Hud
extends Control
## English HUD: observes vehicle signals instead of polling scene paths.
##
## DECOUPLING: bind via `bind_vehicle(vehicle)` (a Vehicle or legacy Carro).
## Prefers English signals (`state_changed`), falls back to PT-BR
## (`estado_mudou`). LevelManager already does this job for the main HUD;
## this class is for new scenes that want a standalone HUD node.

@export var status_label_path: NodePath = NodePath("StatusLabel")
@export var sensor_label_path: NodePath = NodePath("SensorLabel")
@export var attempt_label_path: NodePath = NodePath("AttemptLabel")

var _status: Label = null
var _sensor: Label = null
var _attempt: Label = null
var _vehicle: Node = null


func _ready() -> void:
	_status = get_node_or_null(status_label_path) as Label
	_sensor = get_node_or_null(sensor_label_path) as Label
	_attempt = get_node_or_null(attempt_label_path) as Label


func bind_vehicle(vehicle: Node) -> void:
	_vehicle = vehicle
	if _vehicle == null:
		return
	if _vehicle.has_signal("state_changed"):
		_vehicle.connect("state_changed", _on_state)
	elif _vehicle.has_signal("estado_mudou"):
		_vehicle.connect("estado_mudou", _on_state)
	if _vehicle.has_signal("attempt_changed"):
		_vehicle.connect("attempt_changed", _on_attempt)
	elif _vehicle.has_signal("tentativa_mudou"):
		_vehicle.connect("tentativa_mudou", _on_attempt)
	_on_state(_current_state_key())


func _process(_delta: float) -> void:
	if _sensor != null and _vehicle != null:
		if _vehicle.has_method("sensor_summary"):
			_sensor.text = "SENSOR: " + str(_vehicle.call("sensor_summary"))
		elif _vehicle.has_method("get_sensor_text"):
			_sensor.text = "SENSOR: " + str(_vehicle.call("get_sensor_text"))


func _current_state_key() -> String:
	if _vehicle == null:
		return "SEEKING"
	if _vehicle.has_method("state_label_en"):
		return str(_vehicle.call("state_label_en"))
	if _vehicle.has_method("nome_estado"):
		return str(_vehicle.call("nome_estado"))
	return "SEEKING"


func _on_state(state_key) -> void:
	if _status == null:
		return
	var key := str(state_key)
	_status.text = "STATUS: " + LevelRegistry.STATE_LABELS.get(key, key)


func _on_attempt(count: int, strategy: String) -> void:
	if _attempt != null:
		_attempt.text = "ATTEMPT: %d — %s" % [count, strategy]
