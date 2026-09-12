class_name LevelRegistry
extends RefCounted
## Single source of truth for level scenes + state labels (English).
## Decoupled replacement for legacy `scripts/Fases.gd` (PT-BR).
## New code should use this; Fases.gd stays as a thin shim.

const LEVELS := [
	"res://scenes/fases/Fase1.tscn",
	"res://scenes/fases/Fase2.tscn",
	"res://scenes/fases/Fase3.tscn",
	"res://scenes/fases/Fase4.tscn",
	"res://scenes/fases/Fase5.tscn",
]

const DEMO_SCENE := "res://scenes/Mundo.tscn"

const STATE_LABELS := {
	"SEEKING": "Seeking spot",
	"AVOIDING": "Avoiding obstacle!",
	"ALIGNING": "Aligning to park",
	"PARKED": "Parked!",
	"RECOVERING": "Recovering...",
	# Legacy PT-BR keys stay readable so old signal payloads still resolve.
	"BUSCANDO": "Seeking spot",
	"DESVIANDO": "Avoiding obstacle!",
	"ALINHANDO": "Aligning to park",
	"ESTACIONADO": "Parked!",
	"RECUPERANDO": "Recovering...",
}


## Best Line2D route for the vehicle (fallback when A* is unavailable).
## `routes_node` holds the Line2D lanes, `vehicle_position` and `spots`
## are only used to score each candidate route.
static func collect_route_points(routes_node: Node, vehicle_position: Vector2, spots: Node) -> Array:
	if routes_node == null:
		return []
	var best: Array = []
	var best_score: float = INF
	var spot_target: Vector2 = Vector2.INF
	if spots != null and spots.get_children().size() > 0:
		for spot in spots.get_children():
			var taken: bool = bool(spot.get("is_occupied")) or bool(spot.get("ocupada"))
			if not taken:
				spot_target = (spot as Node2D).global_position
				break
		if spot_target == Vector2.INF:
			spot_target = (spots.get_child(0) as Node2D).global_position
	for child in routes_node.get_children():
		if not child is Line2D:
			continue
		var pts: PackedVector2Array = child.points
		if pts.size() < 2:
			continue
		var glob: Array = []
		for p in pts:
			glob.append(child.to_global(p))
		var d_start: float = vehicle_position.distance_to(glob[0]) if glob.size() > 0 else INF
		var d_end: float = spot_target.distance_to(glob[glob.size() - 1]) if glob.size() > 0 and spot_target != Vector2.INF else INF
		var score: float = d_start * 0.6 + d_end * 0.4
		if score < best_score:
			best_score = score
			best = glob
	if not best.is_empty():
		return best
	var all_points: Array = []
	for child in routes_node.get_children():
		if child is Line2D:
			for p in child.points:
				all_points.append(child.to_global(p))
	return all_points
