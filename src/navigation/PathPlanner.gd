class_name PathPlanner
extends "res://scripts/Planejador.gd"
## English facade over legacy `Planejador.gd` (PT-BR).
##
## DECOUPLING CONTRACT (going forward):
##  - New code calls `build_grid()`, `is_grid_ready()`, `find_route()`,
##    `find_free_spawn()`, `set_route()` and `show_grid/show_route`.
##  - The planner must NOT discover siblings via
##    `get_parent().get_node("Setas"/"Rotas")`; route hints are injected
##    through `RouteHints` (see src/navigation/RouteHints.gd). The legacy
##    auto-discovery stays inside the base class until call sites migrate.

var show_grid: bool:
	get:
		return mostrar_grade
	set(value):
		mostrar_grade = value
		queue_redraw()

var show_route: bool:
	get:
		return mostrar_rota
	set(value):
		mostrar_rota = value
		queue_redraw()


func is_grid_ready() -> bool:
	return grade_pronta()


func build_grid() -> void:
	construir()


func find_route(from_point: Vector2, to_point: Vector2) -> Array:
	return achar_rota(from_point, to_point)


func find_free_spawn(excluded_rects: Array[Rect2] = []) -> Vector2:
	return achar_posicao_livre(excluded_rects)


func set_route(route: Array) -> void:
	definir_rota(route)
