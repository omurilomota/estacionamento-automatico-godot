class_name Hud
extends Control
## THE single HUD panel (one instance per level, `scenes/Hud.tscn`).
##
## WHY THIS EXISTS: the status/sensor/attempt triple was duplicated in 6 scenes
## and written by 3 different orchestrators (Mundo.gd, FaseBase.gd,
## LevelManager.gd) on top of an orphan `Hud.gd` nobody instanced. Three
## competing raw labels + always-on debug checkboxes + a PT-BR/EN text mix
## ("STATUS: Seeking spot" next to "SENSOR: Obstáculo à frente") is exactly
## what the player reported as confusing. Now: one owner, one language (PT-BR
## in the visible strings), and a debug section that is HIDDEN by default.
##
## LAYOUT: `Fundo` + `StatusChip` + `InfoLabel` + `CarSelector` + `DebugToggle`
## always visible; `DebugPanel` (sensor + attempt + route debug) behind the
## button or the **H** key; `Minimap` bottom-right, unchanged subtree.
##
## DECOUPLING (AGENTS §3): the panel binds through SIGNALS, never by crawling
## the scene. `bind_vehicle()` prefers the English `state_changed` /
## `attempt_changed` and falls back to the PT-BR `estado_mudou` /
## `tentativa_mudou`, so it works with both `Vehicle` and legacy `Carro`.

@export var status_path: NodePath = NodePath("StatusChip")
@export var info_path: NodePath = NodePath("InfoLabel")
@export var legend_path: NodePath = NodePath("LegendLabel")
@export var selector_path: NodePath = NodePath("CarSelector")
@export var toggle_path: NodePath = NodePath("DebugToggle")
@export var debug_panel_path: NodePath = NodePath("DebugPanel")
@export var sensor_path: NodePath = NodePath("DebugPanel/SensorLabel")
@export var attempt_path: NodePath = NodePath("DebugPanel/TentativaLabel")
@export var minimap_path: NodePath = NodePath("Minimap")
@export var route_panel_path: NodePath = NodePath("DebugPanel/ControleRotas")

## Cosmetic: 1 px = 1 cm, so px/s * 0.36 reads as km/h for the player.
const PX_S_TO_KMH := 0.36
const LEGEND := "1-7 fase · R reinicia · T modo · C carro · H debug"

var _status: Label = null
var _info: Label = null
var _selector: OptionButton = null
var _toggle: Button = null
var _debug_panel: Control = null
var _sensor: Label = null
var _attempt: Label = null
var _vehicle: Node = null
var _syncing_selector: bool = false


func _ready() -> void:
	_status = get_node_or_null(status_path) as Label
	_info = get_node_or_null(info_path) as Label
	_sensor = get_node_or_null(sensor_path) as Label
	_attempt = get_node_or_null(attempt_path) as Label
	_toggle = get_node_or_null(toggle_path) as Button
	_debug_panel = get_node_or_null(debug_panel_path) as Control
	_selector = get_node_or_null(selector_path) as OptionButton
	var legend := get_node_or_null(legend_path) as Label
	if legend != null:
		legend.text = LEGEND
	_preencher_menu_de_carros()
	if _toggle != null and not _toggle.pressed.is_connected(toggle_debug):
		_toggle.pressed.connect(toggle_debug)
	if _selector != null and not _selector.item_selected.is_connected(_ao_selecionar_carro):
		_selector.item_selected.connect(_ao_selecionar_carro)
	if _debug_panel != null:
		_debug_panel.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_H:
			toggle_debug()
			get_viewport().set_input_as_handled()


## Binds the vehicle to observe. Safe to call again (re-binds on level change).
func bind_vehicle(vehicle: Node) -> void:
	_vehicle = vehicle
	if _vehicle == null:
		return
	_sub("state_changed", "estado_mudou", _on_state)
	_sub("attempt_changed", "tentativa_mudou", _on_attempt)
	_sub("mode_changed", "modo_mudou", _on_mode_changed)
	_on_state(_current_state_payload())


## Planner + spots: kept as an explicit contract so the panel never walks the
## tree (AGENTS §3). Today the panel only needs them to stay a single entry
## point for level wiring; the minimap reads its own exported paths.
func bind_world(_planner: Node, _spots: Node) -> void:
	pass


## Line2D routes node handed to the debug panel (route combo).
func bind_routes(routes_node: Node) -> void:
	var panel := get_node_or_null(route_panel_path)
	if panel != null and panel.has_method("set_routes"):
		panel.call("set_routes", routes_node)


func set_world_size(size_px: Vector2) -> void:
	var mm := minimap()
	if mm != null and "mundo_tamanho" in mm:
		mm.set("mundo_centro", Vector2.ZERO)
		mm.set("mundo_tamanho", size_px)


func minimap() -> Control:
	return get_node_or_null(minimap_path) as Control


func debug_panel() -> Control:
	return _debug_panel


func toggle_debug() -> void:
	if _debug_panel == null:
		return
	_debug_panel.visible = not _debug_panel.visible
	if _toggle != null:
		_toggle.text = "DEBUG (H) -" if _debug_panel.visible else "DEBUG (H)"


## Orchestrators used to write the attempt line themselves (manual-mode spot
## change); this keeps that behaviour without touching labels directly.
func set_attempt(count: int, text: String) -> void:
	if _attempt != null:
		_attempt.text = "TENTATIVA: %d — %s" % [count, text]


func _process(_delta: float) -> void:
	if _vehicle == null:
		return
	if _sensor != null:
		_sensor.text = "SENSOR: %s  |  MODO: %s" % [_sensor_text(), _mode_text()]
	if _info != null:
		_info.text = _info_text()
	_sync_selector()


# --- text sources (duck-typed: Vehicle facade or legacy Carro) -------------

func _sensor_text() -> String:
	if _vehicle.has_method("sensor_summary"):
		return str(_vehicle.call("sensor_summary"))
	if _vehicle.has_method("get_sensor_text"):
		return str(_vehicle.call("get_sensor_text"))
	return "Livre"


func _mode_text() -> String:
	if _vehicle.has_method("modo_atual"):
		return "AUTONOMO" if int(_vehicle.call("modo_atual")) == 1 else "TRILHA"
	if _vehicle.has_method("is_autonomous"):
		return "AUTONOMO" if bool(_vehicle.call("is_autonomous")) else "TRILHA"
	return "-"


## "Vaga: Vaga2 | 312 px | 88 km/h | AUTONOMO" — the one line the player
## actually needs (where it is going, how far, how fast, which mode).
func _info_text() -> String:
	var spot_name := "-"
	var spot: Node2D = null
	if _vehicle.has_method("target_spot"):
		spot = _vehicle.call("target_spot") as Node2D
	elif _vehicle.has_method("vaga_alvo_atual"):
		spot = _vehicle.call("vaga_alvo_atual") as Node2D
	var dist := INF
	if spot != null and is_instance_valid(spot):
		spot_name = str(spot.name)
		if _vehicle is Node2D:
			dist = (_vehicle as Node2D).global_position.distance_to(spot.global_position)
	var dist_txt := "-"
	if is_finite(dist):
		dist_txt = "%d px" % int(dist)
	var speed := 0.0
	if "velocidade_atual" in _vehicle:
		speed = float(_vehicle.get("velocidade_atual"))
	var kmh := int(round(absf(speed) * PX_S_TO_KMH))
	return "Vaga: %s  |  %s  |  %d km/h  |  %s" % [spot_name, dist_txt, kmh, _mode_text()]


func _current_state_payload() -> Variant:
	if _vehicle == null:
		return "SEEKING"
	if _vehicle.has_signal("estado_mudou"):
		return _vehicle.call("nome_estado") if _vehicle.has_method("nome_estado") else "SEEKING"
	return "SEEKING"


# --- wiring ---------------------------------------------------------------

func _sub(en: String, legacy: String, cb: Callable) -> void:
	if not _vehicle.has_signal(legacy):
		legacy = en
	if not _vehicle.has_signal(legacy):
		return
	if not _vehicle.is_connected(legacy, cb):
		_vehicle.connect(legacy, cb)


func _on_state(payload: Variant) -> void:
	if _status == null:
		return
	var key := LevelRegistry.state_key(payload)
	_status.text = LevelRegistry.state_text(key).to_upper()
	_status.add_theme_color_override("font_color", LevelRegistry.state_color(key))
	if key == "DESVIANDO" and _is_trail():
		# In trail mode AVOIDING means "stopped, something is in the way".
		_status.text = "PARADO (OBSTÁCULO À FRENTE)"


## Trail following? (`Vehicle` facade first, then the legacy flag.)
func _is_trail() -> bool:
	if _vehicle == null:
		return false
	if _vehicle.has_method("is_trail_following"):
		return bool(_vehicle.call("is_trail_following"))
	if "modo_trilha" in _vehicle:
		return bool(_vehicle.get("modo_trilha"))
	return false


func _on_attempt(count: int, strategy: String) -> void:
	set_attempt(count, strategy)


func _on_mode_changed(_mode: int) -> void:
	if _sensor != null and _vehicle != null:
		_sensor.text = "SENSOR: %s  |  MODO: %s" % [_sensor_text(), _mode_text()]


# --- car menu -------------------------------------------------------------

func _preencher_menu_de_carros() -> void:
	if _selector == null:
		return
	_selector.clear()
	for id in VehicleCatalog.ids():
		_selector.add_item(VehicleCatalog.label_for(id))
	_selector.selected = maxi(VehicleCatalog.index_of(VehicleCatalog.current_id), 0)


func _ao_selecionar_carro(index: int) -> void:
	if _syncing_selector or _vehicle == null:
		return
	var id := VehicleCatalog.id_at(index)
	if _vehicle.has_method("aplicar_skin"):
		_vehicle.call("aplicar_skin", id)
	elif _vehicle.has_method("set_skin"):
		_vehicle.call("set_skin", id)


## Keeps the selector in sync when the car is cycled with the C key (the
## vehicle owns the input handler, the panel only mirrors it).
func _sync_selector() -> void:
	if _selector == null:
		return
	var want := VehicleCatalog.index_of(VehicleCatalog.current_id)
	if want >= 0 and _selector.selected != want:
		_syncing_selector = true
		_selector.select(want)
		_syncing_selector = false
