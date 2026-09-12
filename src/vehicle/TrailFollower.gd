class_name TrailFollower
extends DriverBrain
## Follows a precomputed trail (legacy modo_trilha / _processar_trilha).
## Owns the trail idioms: CTE-based reverse trigger (>90px + slow),
## 0.5x err damping when aligned+close, 0.55x/0.75x curve slowdown,
## brake-to-spot approach. Returns DriveCommands; Vehicle applies them.

var max_steer: float = 0.9
var max_speed: float = 120.0


func kind() -> int:
	return Kind.TRAIL


func decide(perception: PerceptionSnapshot, _delta: float) -> DriveCommand:
	# Perception-only mode (no route): stop when blocked, else crawl.
	if perception.front_blocked(70.0):
		return DriveCommand.stop()
	return DriveCommand.make(0.0, 0.3)


## Full trail tick with route context (mirrors _processar_trilha).
static func solve_trail(vehicle_pos: Vector2, vehicle_rot: float,
		idx: int, route: Array, cte: float, speed_now: float,
		dist_spot: float, curv_ahead: float, v_max: float,
		max_steer: float) -> PursuitCommand:
	var cmd := PurePursuit.solve(vehicle_pos, vehicle_rot, idx, route, max_steer)
	if cte > 90.0 and absf(speed_now) < 15.0:
		cmd.reverse = true
		cmd.speed = -60.0
		return cmd
	var v_alvo: float = PurePursuit.curve_speed(v_max, curv_ahead, v_max)
	if dist_spot < 250.0:
		v_alvo = minf(v_alvo, lerpf(40.0, v_max, dist_spot / 250.0))
	elif dist_spot < 700.0:
		v_alvo = minf(v_alvo, lerpf(70.0, v_max, (dist_spot - 250.0) / 450.0))
	cmd.speed = v_alvo
	return cmd
