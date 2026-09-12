class_name AutonomousDriver
extends DriverBrain
## Free A* driver (legacy auto_navegacao / _processar_rota + _processar_buscando).
## Owns the autonomous idioms: full-stop gate (dist < 200 AND center <
## 50 → 0), dead-end reverse (>220px off-route + slow), reverse exit
## (angle > 2.2 AND dist > 80), park approach, curve slowdown.
## Returns DriveCommands; Vehicle applies them.

var max_steer: float = 0.9
var max_speed: float = 160.0


func kind() -> int:
	return Kind.AUTONOMOUS


func decide(perception: PerceptionSnapshot, _delta: float) -> DriveCommand:
	if perception.front_blocked(50.0):
		return DriveCommand.stop()
	var turn: float = clampf(-perception.angle_to_target * 2.2, -1.0, 1.0)
	var gas: float = 0.5 if perception.distance_to_target > 200.0 else 0.0
	return DriveCommand.make(turn, gas)


## Full autonomous tick with route context (mirrors _processar_rota).
static func solve_route(vehicle_pos: Vector2, vehicle_rot: float,
		idx: int, route: Array, dist_trail: float, speed_now: float,
		dist_spot: float, curv_ahead: float, v_max: float,
		max_steer: float) -> PursuitCommand:
	var cmd := PurePursuit.solve(vehicle_pos, vehicle_rot, idx, route, max_steer)
	var target: Vector2 = route[idx] if idx < route.size() else vehicle_pos
	var err: float = angle_difference(vehicle_rot, vehicle_pos.direction_to(target).angle())
	if dist_trail > 220.0 and absf(speed_now) < 15.0:
		cmd.reverse = true
		cmd.speed = -60.0
		return cmd
	if absf(err) > 2.2 and vehicle_pos.distance_to(target) > 80.0:
		cmd.reverse = true
		cmd.speed = -60.0
		cmd.steering = -cmd.steering
		return cmd
	var v_alvo: float = PurePursuit.curve_speed(v_max, curv_ahead, v_max)
	if dist_spot < 250.0:
		v_alvo = minf(v_alvo, lerpf(40.0, v_max, dist_spot / 250.0))
	elif dist_spot < 700.0:
		v_alvo = minf(v_alvo, lerpf(70.0, v_max, (dist_spot - 250.0) / 450.0))
	if dist_spot < 200.0 and cmd.arrived:
		v_alvo = 0.0
	cmd.speed = v_alvo
	return cmd
