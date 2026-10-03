class_name PerceptionSnapshot
extends RefCounted
## Decoupled sensor reading consumed by DriverBrain implementations.
## The vehicle fills this from its RayCast2D array; brains never touch
## RayCast2D nodes directly, which makes them testable headless.
## v2 (F1): 22-field contract — 11 ray distances + speed/target (7) +
## yaw_error(1) + corridor(1, derived) + crosser dist/bearing(2) + stuck(1).
## Arrow-floor inputs are DEAD (setas ignored, locked B5): the 3 arrow
## slots keep existing for the v1 weights file only, new recorders write 0.

var front_center: float = INF ## meters/px to obstacle, INF = clear
var front_left: float = INF
var front_right: float = INF
var side_left: float = INF
var side_right: float = INF
var rear: float = INF
var long_range_center: float = INF
var long_range_left: float = INF
var long_range_right: float = INF
var lateral_left: float = INF
var lateral_right: float = INF
var speed: float = 0.0 ## current forward speed (px/s)
var distance_to_target: float = INF
var angle_to_target: float = 0.0 ## signed radians, 0 = straight ahead
var yaw_error: float = 0.0 ## signed radians to target_yaw (0 = aligned)
var crosser_distance: float = INF ## px to scripted crossing car, INF = none
var crosser_bearing: float = 0.0 ## signed radians, 0 = straight ahead
var stuck_time: float = 0.0 ## seconds without progress (0 = moving fine)
## Runtime-only pedestrian fields (docs/tasks_trafego.md T2). NOT part of the
## 22-field ML contract — the recorders keep writing 22 columns; the
## pedestrian is a yield hazard only (a pedestrian has priority).
var pedestrian_distance: float = INF ## px to the nearest pedestrian, INF = none
var pedestrian_bearing: float = 0.0 ## signed radians, 0 = straight ahead


func front_blocked(threshold: float) -> bool:
	return minf(front_center, minf(front_left, front_right)) < threshold


func corridor_width() -> float:
	var l: float = minf(side_left, lateral_left)
	var r: float = minf(side_right, lateral_right)
	if not is_finite(l):
		l = 9999.0
	if not is_finite(r):
		r = 9999.0
	return l + r


## Crosser visible ahead inside a cone: used by brains to yield.
func crosser_ahead(dist_limit: float, cone: float = 0.6) -> bool:
	return is_finite(crosser_distance) and crosser_distance < dist_limit \
		and absf(crosser_bearing) < cone
