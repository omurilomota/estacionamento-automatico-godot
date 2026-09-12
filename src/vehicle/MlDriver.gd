class_name MlDriver
extends DriverBrain
## Behavior-cloning driver (legacy modo_ml / _processar_ml).
## Owns the ML idioms as pure functions: center-brake scalar, spot
## approach clamp, likely-stuck detector. Inference itself stays in
## NeuralBrain (weights); this maps (net_out, perception) → command.

var max_speed: float = 160.0
var brake_distance: float = 160.0


func kind() -> int:
	return Kind.ML


func decide(perception: PerceptionSnapshot, _delta: float) -> DriveCommand:
	if perception.front_blocked(brake_distance * 0.25):
		return DriveCommand.stop()
	return DriveCommand.make(0.0, 0.2)


## Maps raw net outputs [steer -1..1, speed 0..1] to a DriveCommand,
## applying the legacy safety/approach gates (mirrors _processar_ml).
static func map_outputs(volante: float, vel_rede: float,
		dist_centro: float, dist_spot: float,
		brake_dist: float, v_max: float) -> DriveCommand:
	var cmd := DriveCommand.make(volante, 0.0)
	cmd.steering = clampf(volante, -1.0, 1.0)
	var v_desejada: float = clampf(vel_rede, 0.0, 1.0) * v_max
	var fator: float = clampf((dist_centro - 40.0) / maxf(brake_dist - 40.0, 1.0), 0.0, 1.0)
	v_desejada *= fator * fator
	if dist_spot < 700.0:
		v_desejada = minf(v_desejada, lerpf(30.0, 80.0, dist_spot / 700.0))
	cmd.throttle = clampf(v_desejada / maxf(v_max, 1.0), 0.0, 1.0)
	return cmd


## Stuck detector: same frames as legacy (pos_ref + 0.5s window).
static func likely_stuck(moved: float, elapsed: float,
		limit_move: float = 10.0, limit_time: float = 0.5) -> bool:
	return elapsed > limit_time and moved < limit_move
