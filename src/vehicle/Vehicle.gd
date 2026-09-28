class_name Vehicle
extends "res://scripts/Carro.gd"
## English facade over the legacy `Carro.gd` (PT-BR).
##
## WHY THIS EXISTS:
##  - Scenes still instance `Carro.tscn` / `Carro.gd`, so we cannot rename
##    the base file in one shot without touching every Fase scene.
##  - New code should talk ENGLISH and depend on ABSTRACTIONS, not on
##    `has_method("iniciar_modo_trilha")` or `"modo_trilha" in carro`.
##
## MIGRATION PATH:
##  1) New code uses `Vehicle` (this class): `state_changed`,
##     `set_waypoints()`, `start_navigation()`, `follow_trail_enabled`, ...
##  2) Old scenes keep working — this IS-A Carro, so every legacy call
##     (`definir_waypoints`, `estado_mudou`, `modo_trilha`, ...) still works.
##  3) When `Vehicle.tscn` lands, we move the logic up from `Carro.gd`
##     into `src/vehicle/*` (Locomotion, SensorArray, brains) and turn
##     `Carro.gd` into a thin shim extending this class. No flag day.

signal state_changed(state: int)
signal attempt_changed(count: int, strategy: String)
signal spot_change_requested


func _ready() -> void:
	super._ready()
	# Bridge legacy PT-BR signals -> English signals (both stay alive).
	if not estado_mudou.is_connected(_on_legacy_estado_mudou):
		estado_mudou.connect(_on_legacy_estado_mudou)
	if not tentativa_mudou.is_connected(_on_legacy_tentativa_mudou):
		tentativa_mudou.connect(_on_legacy_tentativa_mudou)
	if not pedir_nova_vaga.is_connected(_on_legacy_pedir_nova_vaga):
		pedir_nova_vaga.connect(_on_legacy_pedir_nova_vaga)


func _on_legacy_estado_mudou(legacy_name: String) -> void:
	state_changed.emit(VehicleState.from_legacy_name(legacy_name))


func _on_legacy_tentativa_mudou(count: int, strategy: String) -> void:
	attempt_changed.emit(count, strategy)


func _on_legacy_pedir_nova_vaga() -> void:
	spot_change_requested.emit()


# --- English command API (delegates to legacy implementation) ---

func set_waypoints(points: Array) -> void:
	definir_waypoints(points)


func set_trail(points: Array) -> void:
	definir_trilha(points)


func start_navigation() -> void:
	iniciar_navegacao()


func start_trail_mode() -> void:
	iniciar_modo_trilha()


func current_state() -> int:
	# `estado` is the legacy enum int; order matches VehicleState.State.
	return int(estado)


func state_label_en() -> String:
	return VehicleState.label(current_state())


func is_trail_following() -> bool:
	return modo_trilha


func set_trail_following(value: bool) -> void:
	modo_trilha = value


func is_autonomous() -> bool:
	return auto_navegacao


func set_autonomous(value: bool) -> void:
	auto_navegacao = value


func is_ml_driving() -> bool:
	return modo_ml


func set_ml_driving(value: bool) -> void:
	modo_ml = value


func build_perception() -> PerceptionSnapshot:
	# New API: snapshot for DriverBrain implementations (legacy FSM keeps
	# using its inline helpers until brains land). Zero behavior change.
	var rays: Dictionary = SensorArray.collect_from(self)
	var alvo: Vector2 = posicao_alvo
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		alvo = (_vaga_alvo as Node2D).global_position
	var dist_t: float = global_position.distance_to(alvo)
	var ang_t: float = angle_difference(rotation, global_position.direction_to(alvo).angle())
	return SensorArray.snapshot(rays, velocidade_atual, dist_t, ang_t)


func sensor_summary() -> String:
	return get_sensor_text()
func is_parked() -> bool:
	return current_state() == VehicleState.State.PARKED


func target_spot() -> Node2D:
	return _vaga_alvo as Node2D


func begin_recording(path: String) -> void:
	ml_gravar = true
	ml_gravar_caminho = path


func close_recording() -> void:
	_ml_fechar()


func set_ml_fallback_off(value: bool) -> void:
	ml_sem_fallback = value


func set_driver_brain(brain: DriverBrain) -> void:
	super.set_driver_brain(brain)


func set_brain_enabled(value: bool) -> void:
	super.set_brain_enabled(value)


# --- Car menu (VehicleCatalog) -------------------------------------------

## Swaps the skin of the exported `sprite_path` node. Returns false for an
## unknown id or a missing sprite.
func set_skin(id: String) -> bool:
	return aplicar_skin(id)


func current_skin() -> String:
	return VehicleCatalog.current_id


## Ids of every selectable car, in menu order.
func skin_options() -> Array[String]:
	return VehicleCatalog.ids()


func build_drive_context() -> DriveContext:
	return _build_drive_context(build_perception())


func prepare_parking(target_yaw: float, target_position: Vector2) -> void:
	preparar_estacionamento(target_yaw, target_position)


func begin_alignment(target_yaw: float, target_position: Vector2) -> void:
	entrar_estado_alinhando(target_yaw, target_position)

