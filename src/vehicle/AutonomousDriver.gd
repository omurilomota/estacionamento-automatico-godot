class_name AutonomousDriver
extends DriverBrain

var max_steer: float = 0.9
var max_speed: float = 160.0


func kind() -> int:
	return Kind.AUTONOMOUS


func decide(perception: PerceptionSnapshot, _delta: float) -> DriveCommand:
	if perception.front_blocked(50.0):
		return DriveCommand.stop()
	var turn := clampf(-perception.angle_to_target * 2.2, -1.0, 1.0)
	var gas := 0.5 if perception.distance_to_target > 200.0 else 0.0
	return DriveCommand.make(turn, gas)


func decide_context(perception: PerceptionSnapshot, context: DriveContext, _delta: float) -> DriveCommand:
	if context.route.is_empty():
		return decide(perception, _delta)
	var lookahead_data := PurePursuit.find_lookahead(
		context.vehicle_position, context.route, 180.0, context.waypoint_index)
	var pursuit := PurePursuit.solve_lookahead(
		context.vehicle_position, context.vehicle_rotation, lookahead_data.point,
		max_steer, 2.8, false)
	pursuit.lookahead_index = int(lookahead_data.index)
	var angular_error := angle_difference(
		context.vehicle_rotation,
		context.vehicle_position.direction_to(lookahead_data.point).angle())
	if context.cte > 220.0 and absf(context.speed) < 15.0:
		pursuit.reverse = true
		pursuit.speed = -60.0
	elif absf(angular_error) > 2.2 and context.distance_to_target > 80.0:
		pursuit.reverse = true
		pursuit.speed = -60.0
		pursuit.steering = -pursuit.steering
	else:
		pursuit.speed = FsmProfiles.route_speed(
			context.speed, context.curvature_ahead, angular_error,
			max_steer, max_speed)
		pursuit.speed = FsmProfiles.approach_speed(
			context.distance_to_target, pursuit.speed, max_speed)
		if context.arrived and context.distance_to_target < 200.0:
			pursuit.speed = 0.0
	return DriveCommandAdapter.from_pursuit(pursuit, max_steer, max_speed)


static func solve_route(vehicle_pos: Vector2, vehicle_rot: float,
		idx: int, route: Array, dist_trail: float, speed_now: float,
		dist_spot: float, curv_ahead: float, v_max: float,
		max_steer: float) -> PursuitCommand:
	var cmd := PurePursuit.solve(vehicle_pos, vehicle_rot, idx, route, max_steer)
	var target: Vector2 = route[idx] if idx < route.size() else vehicle_pos
	var err := angle_difference(vehicle_rot, vehicle_pos.direction_to(target).angle())
	if dist_trail > 220.0 and absf(speed_now) < 15.0:
		cmd.reverse = true
		cmd.speed = -60.0
		return cmd
	if absf(err) > 2.2 and vehicle_pos.distance_to(target) > 80.0:
		cmd.reverse = true
		cmd.speed = -60.0
		cmd.steering = -cmd.steering
		return cmd
	var v_alvo := FsmProfiles.route_speed(speed_now, curv_ahead, err, max_steer, v_max)
	v_alvo = FsmProfiles.approach_speed(dist_spot, v_alvo, v_max)
	if dist_spot < 200.0 and cmd.arrived:
		v_alvo = 0.0
	cmd.speed = v_alvo
	return cmd
