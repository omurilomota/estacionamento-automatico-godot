class_name TrailFollower
extends DriverBrain

var max_steer: float = 0.9
var max_speed: float = 120.0


func kind() -> int:
	return Kind.TRAIL


func decide(perception: PerceptionSnapshot, _delta: float) -> DriveCommand:
	if perception.front_blocked(70.0):
		return DriveCommand.stop()
	return DriveCommand.make(0.0, 0.3)


func decide_context(perception: PerceptionSnapshot, context: DriveContext, _delta: float) -> DriveCommand:
	if context.route.is_empty():
		return decide(perception, _delta)
	var lookahead_data := PurePursuit.find_lookahead(
		context.vehicle_position, context.route, 180.0, context.waypoint_index)
	var lookahead := lookahead_data.point as Vector2
	var pursuit := PurePursuit.solve_lookahead(
		context.vehicle_position, context.vehicle_rotation, lookahead, max_steer, 2.2, false)
	pursuit.lookahead_index = int(lookahead_data.index)
	var angular_error := angle_difference(
		context.vehicle_rotation,
		context.vehicle_position.direction_to(lookahead).angle())
	var sensor_base := FsmProfiles.sensor_speed(
		context.front_distance, context.lateral_distance, 40.0, 160.0, max_speed)
	var base_speed := max_speed * 0.85
	if context.distance_to_target <= 350.0:
		base_speed = sensor_base
	var speed := FsmProfiles.trail_speed(
		base_speed, context.curvature_ahead, angular_error,
		context.distance_to_target, max_steer, max_speed, max_speed, 1.0)
	if context.cte > 90.0 and absf(context.speed) < 15.0:
		pursuit.reverse = true
		pursuit.speed = -60.0
	else:
		pursuit.speed = speed
	return DriveCommandAdapter.from_pursuit(pursuit, max_steer, max_speed)


static func solve_trail(vehicle_pos: Vector2, vehicle_rot: float,
		idx: int, route: Array, cte: float, speed_now: float,
		dist_spot: float, curv_ahead: float, v_max: float,
		max_steer: float) -> PursuitCommand:
	var cmd := PurePursuit.solve(vehicle_pos, vehicle_rot, idx, route, max_steer)
	if cte > 90.0 and absf(speed_now) < 15.0:
		cmd.reverse = true
		cmd.speed = -60.0
		return cmd
	var v_alvo := FsmProfiles.trail_speed(speed_now, curv_ahead, 0.0, dist_spot,
		max_steer, v_max, v_max, 1.0)
	cmd.speed = v_alvo
	return cmd
