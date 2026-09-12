class_name RouteHints
extends Resource
## Injected route preferences for PathPlanner (decoupled).
##
## Replaces the planner reaching into its parent scene via
## `get_parent().get_node("Setas" / "Rotas")`. Level authors fill this
## resource (or LevelManager builds it from the level tree once) and hand
## it to the planner, so the planner stays a pure service.

@export var lane_polylines: Array[PackedVector2Array] = []
@export var preferred_points: Array[Vector2] = []
@export var preferred_radius: float = 70.0
@export var lane_graph: Resource = null


func is_empty() -> bool:
	return lane_polylines.is_empty() and preferred_points.is_empty() and lane_graph == null

## Collects lane polylines + arrow spots from a level tree ONCE, so the
## planner can be fed hints without crawling scenes itself (see
## PathPlanner; legacy auto-discovery stays in the base class).
static func collect_from_level(root: Node) -> RouteHints:
	var hints := RouteHints.new()
	var routes := root.get_node_or_null("Rotas")
	if routes != null:
		for child in routes.get_children():
			if child is Line2D and (child as Line2D).points.size() >= 2:
				var glob := PackedVector2Array()
				for p in (child as Line2D).points:
					glob.append((child as Node2D).to_global(p))
				hints.lane_polylines.append(glob)
	var arrows := root.get_node_or_null("Setas")
	if arrows != null:
		for a in arrows.get_children():
			if a is Node2D:
				hints.preferred_points.append((a as Node2D).global_position)
	var graph: Resource = load("res://resources/RoadGraph.tres")
	if graph != null:
		hints.lane_graph = graph
	return hints

