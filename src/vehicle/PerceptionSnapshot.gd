class_name PerceptionSnapshot
extends RefCounted
## Decoupled sensor reading consumed by DriverBrain implementations.
## The vehicle fills this from its RayCast2D array; brains never touch
## RayCast2D nodes directly, which makes them testable headless.

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
