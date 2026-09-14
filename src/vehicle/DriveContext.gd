class_name DriveContext
extends RefCounted

enum Mode { TRAIL, AUTONOMOUS, ML }

var state: int = 0
var mode: int = Mode.AUTONOMOUS
var vehicle_position: Vector2 = Vector2.ZERO
var vehicle_rotation: float = 0.0
var route: Array[Vector2] = []
var waypoint_index: int = 0
var target_position: Vector2 = Vector2.ZERO
var target_yaw: float = 0.0
var distance_to_target: float = INF
var angle_to_target: float = 0.0
var cte: float = INF
var curvature_ahead: float = 0.0
var front_distance: float = INF
var rear_distance: float = INF
var lateral_distance: float = INF
var speed: float = 0.0
var arrived: bool = false
var perception: PerceptionSnapshot = null
