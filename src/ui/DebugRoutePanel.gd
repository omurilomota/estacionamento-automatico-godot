class_name DebugRoutePanel
extends "res://scripts/ControleRotas.gd"
## English facade over legacy ControleRotas (debug checkboxes).
##
## The base class resolved `../../../Planejador|Rotas|Carro` — an assumption
## about the panel's DEPTH in the tree (AGENTS #8). It broke the moment the
## panel moved one level deeper under the shared HUD's `DebugPanel/`, so this
## subclass injects the three references declaratively instead of guessing:
##
##   planner_node  -> res://scenes/Hud.tscn  (Planejador)
##   routes_node   -> res://scenes/Hud.tscn  (Rotas)
##   vehicle_node  -> res://scenes/Hud.tscn  (Carro)
##
## Legacy scenes that still instance `ControleRotas` directly keep working
## through the base class' name-based search.

@export var planner_node: NodePath = NodePath("")
@export var routes_node: NodePath = NodePath("")
@export var vehicle_node: NodePath = NodePath("")


func _resolve(name_: String) -> Node:
	var declared := NodePath("")
	match name_:
		"Planejador":
			declared = planner_node
		"Rotas":
			declared = routes_node
		"Carro":
			declared = vehicle_node
	if not declared.is_empty():
		var node := get_node_or_null(declared)
		if node != null:
			return node
	return super._resolve(name_)
