class_name SensorArray
extends RefCounted
## Builds a PerceptionSnapshot from the vehicle's RayCast2D nodes.
## Owns the 12-ray contract in ONE place (was scattered over Carro.gd).
## No decisions here — brains receive the snapshot, never the rays.

const FRONT_CENTER := "RayFrenteCentro"
const FRONT_LEFT := "RayFrenteEsq"
const FRONT_RIGHT := "RayFrenteDir"
const SIDE_LEFT := "RayEsquerda"
const SIDE_RIGHT := "RayDireita"
const REAR := "RayTras"
const LONG_CENTER := "RayFrenteLongo"
const LONG_LEFT := "RayFrenteLongoEsq"
const LONG_RIGHT := "RayFrenteLongoDir"
const LATERAL_LEFT := "RayLateralEsq"
const LATERAL_RIGHT := "RayLateralDir"

const RAY_NAMES: Array[String] = [
	FRONT_CENTER, FRONT_LEFT, FRONT_RIGHT,
	SIDE_LEFT, SIDE_RIGHT, REAR,
	LONG_CENTER, LONG_LEFT, LONG_RIGHT,
	LATERAL_LEFT, LATERAL_RIGHT,
]


## Distance in px to the obstacle on this ray, INF when clear/invalid.
static func distance_of(ray: RayCast2D) -> float:
	if ray == null or not is_instance_valid(ray):
		return INF
	if not ray.is_colliding():
		return INF
	var hit: Vector2 = ray.get_collision_point()
	if not hit.is_finite() or not ray.global_position.is_finite():
		return INF
	return ray.global_position.distance_to(hit)


## Grabs the named rays from the vehicle tree (missing ones stay null).
static func collect_from(vehicle: Node) -> Dictionary:
	var rays := {}
	for ray_name in RAY_NAMES:
		rays[ray_name] = vehicle.get_node_or_null(ray_name) as RayCast2D
	return rays


## Folds raw rays + mission data into the snapshot brains consume.
static func snapshot(rays: Dictionary, speed: float, dist_target: float, angle_target: float) -> PerceptionSnapshot:
	var s := PerceptionSnapshot.new()
	s.front_center = distance_of(rays.get(FRONT_CENTER) as RayCast2D)
	s.front_left = distance_of(rays.get(FRONT_LEFT) as RayCast2D)
	s.front_right = distance_of(rays.get(FRONT_RIGHT) as RayCast2D)
	s.side_left = distance_of(rays.get(SIDE_LEFT) as RayCast2D)
	s.side_right = distance_of(rays.get(SIDE_RIGHT) as RayCast2D)
	s.rear = distance_of(rays.get(REAR) as RayCast2D)
	s.long_range_center = distance_of(rays.get(LONG_CENTER) as RayCast2D)
	s.long_range_left = distance_of(rays.get(LONG_LEFT) as RayCast2D)
	s.long_range_right = distance_of(rays.get(LONG_RIGHT) as RayCast2D)
	s.lateral_left = distance_of(rays.get(LATERAL_LEFT) as RayCast2D)
	s.lateral_right = distance_of(rays.get(LATERAL_RIGHT) as RayCast2D)
	s.speed = speed
	s.distance_to_target = dist_target
	s.angle_to_target = angle_target
	return s
