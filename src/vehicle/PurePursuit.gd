class_name PurePursuit
extends RefCounted
## Pure-pursuit steering solver (reference logic from Carro.gd).
## Mirrors _processar_rota/_processar_trilha steering idioms:
## steering = clamp(err * GAIN, -max, max), halved when nearly aligned
## and close; curve slowdown via lookahead curvature.
## NO scene access — same floats in, same floats out. This is the SPEC
## the FSM delegates to (wired next); brains reuse it headless.

const STEER_GAIN := 2.2
const ALIGN_ERR := 0.15
const ALIGN_DIST := 20.0


## Solves steering for a lookahead point. Returns PursuitCommand with
## steering + arrival flag; speed/curvature stay with the caller.
## NOTE: Godot 2D rotation: +X right, +Y DOWN. So a target at +Y with
## rotation 0 yields angle_difference = -PI/2 (negative = screen-right).
static func solve(vehicle_pos: Vector2, vehicle_rot: float,
		idx: int, route: Array, max_steer: float) -> PursuitCommand:
	var cmd := PursuitCommand.new()
	cmd.lookahead_index = idx
	var target: Vector2 = route[idx] if idx < route.size() else vehicle_pos
	var dist: float = vehicle_pos.distance_to(target)
	var err: float = 0.0
	if dist > 0.001:
		err = angle_difference(vehicle_rot, vehicle_pos.direction_to(target).angle())
	if dist < ALIGN_DIST and absf(err) < ALIGN_ERR:
		err *= 0.5
	cmd.steering = clampf(err * STEER_GAIN, -max_steer, max_steer)
	cmd.arrived = dist < 14.0
	return cmd


## Scales straight speed down with lookahead curvature (matches Carro).
static func curve_speed(base: float, curv: float, max_speed: float) -> float:
	if curv > 0.05:
		return minf(base, max_speed * 0.55)
	if curv > 0.02:
		return minf(base, max_speed * 0.75)
	return base
