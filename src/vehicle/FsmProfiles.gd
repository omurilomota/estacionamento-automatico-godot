class_name FsmProfiles
extends RefCounted

static func sensor_speed(front_distance: float, lateral_distance: float,
		safety_distance: float, brake_distance: float, max_speed: float) -> float:
	var distance := minf(front_distance, lateral_distance * 1.4)
	if distance == INF:
		return max_speed
	if distance <= safety_distance:
		return 0.0
	return clampf((distance - safety_distance) / maxf(brake_distance - safety_distance, 0.001), 0.0, 1.0) * max_speed


static func approach_speed(distance: float, base_speed: float, max_speed: float) -> float:
	if distance >= 450.0:
		return base_speed
	var cruise := max_speed * 0.85
	var profile := remap(clampf(distance, 40.0, 450.0), 40.0, 450.0, 26.0, cruise)
	return minf(base_speed, profile)


static func reverse_speed(rear_distance: float, max_speed: float,
		safety_distance: float, brake_distance: float) -> float:
	if rear_distance == INF:
		return max_speed
	if rear_distance <= safety_distance:
		return 0.0
	return clampf((rear_distance - safety_distance) / maxf(brake_distance - safety_distance, 0.001), 0.0, 1.0) * max_speed


## Cruise profile for A* routes. v2 (F3 fix): the old mapping used
## sqrt(0.9 / max(curv, 0.015)) which treated ANY mild bend (A* decimated
## points are ~18px apart) as curvature 0.015+ and capped speed at ~8 px/s
## — the A* pilot crawled. Now it mirrors the proven trail profile:
## only real curves slow the car, down to a 45 px/s floor.
static func route_speed(base_speed: float, curvature: float, angular_error: float,
		max_steer: float, max_speed: float) -> float:
	var curve_limit := max_speed
	if curvature > 0.005:
		curve_limit = maxf(sqrt(30.0 / curvature), 45.0)
	var speed := minf(base_speed, curve_limit * 1.1)
	var factor := 1.0 - minf(absf(angular_error) / maxf(max_steer, 0.001), 1.0) * 0.4
	speed *= factor
	if absf(angular_error) > 0.7:
		var t := clampf((absf(angular_error) - 0.7) / 0.3, 0.0, 1.0)
		speed *= lerp(0.75, 0.5, t)
	return speed


static func trail_speed(base_speed: float, curvature: float, angular_error: float,
		distance_to_spot: float, max_steer: float, max_speed: float,
		trail_max: float, scale: float) -> float:
	var curve_limit := max_speed
	if curvature > 0.005:
		curve_limit = maxf(sqrt(30.0 / curvature), 45.0)
	var speed := minf(base_speed, curve_limit * 1.1)
	speed = minf(speed, trail_max * maxf(scale, 1.0))
	speed *= 1.0 - minf(absf(angular_error) / maxf(max_steer, 0.001), 1.0) * 0.25
	if absf(angular_error) > 0.7:
		var t := clampf((absf(angular_error) - 0.7) / 0.3, 0.0, 1.0)
		speed *= lerp(0.85, 0.65, t)
	if distance_to_spot < 450.0:
		speed = approach_speed(distance_to_spot, speed, max_speed)
	return speed


static func alignment_speed(distance: float, angular_error: float,
		rear_distance: float, lateral_distance: float, front_distance: float,
		alignment_speed_max: float, max_speed: float,
		safety_distance: float, tolerance: float) -> float:
	if distance > tolerance * 2.5:
		var speed := sensor_speed(front_distance, lateral_distance, safety_distance, 160.0, max_speed) * 0.6
		if absf(angular_error) > 0.7:
			speed *= 0.45
		elif absf(angular_error) > 0.4:
			speed *= 0.7
		if lateral_distance < 35.0:
			speed *= 0.5
		return speed
	if absf(angular_error) > 0.7:
		return -reverse_speed(rear_distance, alignment_speed_max, safety_distance, 160.0) * 0.7
	if absf(angular_error) > 0.35:
		return alignment_speed_max * 0.65
	if absf(angular_error) < tolerance:
		var speed := alignment_speed_max * 0.6
		if distance < 12.0:
			speed *= 0.5
		return speed
	if distance > 14.0:
		return alignment_speed_max * 0.35
	return -reverse_speed(rear_distance, alignment_speed_max, safety_distance, 160.0) * 0.4


static func trail_alignment_speed(distance: float, angular_error: float,
		rear_distance: float, lateral_distance: float, front_distance: float,
		alignment_speed_max: float, max_speed: float,
		safety_distance: float, tolerance: float) -> float:
	if distance > tolerance * 2.0:
		var approach_angle := angular_error
		var speed := approach_speed(distance, 75.0, max_speed)
		if absf(approach_angle) > 0.6:
			speed = approach_speed(distance, 45.0, max_speed)
		if front_distance < safety_distance:
			speed = 0.0
		return speed
	if absf(angular_error) > 0.7:
		return -reverse_speed(rear_distance, alignment_speed_max, safety_distance, 160.0) * 0.55
	if absf(angular_error) > 0.35:
		return alignment_speed_max * 0.65
	var speed := alignment_speed_max * 0.5
	if distance < 12.0:
		speed *= 0.45
	return speed


static func command_from_legacy(steering: float, speed: float, max_steer: float, max_speed: float) -> DriveCommand:
	return DriveCommand.make(steering / maxf(max_steer, 0.001), speed / maxf(max_speed, 0.001))
