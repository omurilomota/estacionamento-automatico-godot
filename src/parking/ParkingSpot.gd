class_name ParkingSpot
extends "res://scripts/Vaga.gd"
## English facade over legacy `Vaga.gd` (PT-BR).
##
## DECOUPLING CONTRACT (going forward):
##  - A spot NEVER calls methods on the vehicle (`has_method` bridges are
##    legacy and will be replaced by the LevelManager mediator).
##  - A spot only exposes state + signals:
##      `is_occupied`, `mark_occupied()`, `vehicle_at_mouth(vehicle)`,
##      `vehicle_awaiting_alignment(vehicle)`.
##  - Vehicles expose `prepare_parking()` / `begin_alignment()` as their
##    side of the contract (see Vehicle facade), so the spot does not need
##    to know which brain is driving.
##
## Today this IS-A Vaga so existing Fase scenes keep working untouched.

signal vehicle_at_mouth(vehicle: Node2D)
signal vehicle_awaiting_alignment(vehicle: Node2D)


var is_occupied: bool:
	get:
		return ocupada
	set(value):
		ocupada = value


var target_yaw: float:
	get:
		return rotacao_alvo
	set(value):
		rotacao_alvo = value


var free_color: Color:
	get:
		return cor_livre
	set(value):
		cor_livre = value


var occupied_color: Color:
	get:
		return cor_ocupada
	set(value):
		cor_ocupada = value


func _ready() -> void:
	super._ready()
	# Re-emit intent as English signals for new observers.
	# (Legacy body_entered wiring inside Vaga.gd stays untouched.)
	if not body_entered.is_connected(_on_legacy_body_entered):
		body_entered.connect(_on_legacy_body_entered)
	if boca != null and not boca.body_entered.is_connected(_on_legacy_mouth_entered):
		boca.body_entered.connect(_on_legacy_mouth_entered)


func mark_occupied() -> void:
	marcar_ocupada()


func _on_legacy_body_entered(body: Node2D) -> void:
	vehicle_awaiting_alignment.emit(body)


func _on_legacy_mouth_entered(body: Node2D) -> void:
	vehicle_at_mouth.emit(body)
