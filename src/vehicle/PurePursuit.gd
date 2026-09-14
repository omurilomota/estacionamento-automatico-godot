class_name PurePursuit
extends RefCounted
## Pure-pursuit steering solver (reference logic from Carro.gd).
## Mirrors _processar_rota/_processar_trilha steering idioms:
## steering = clamp(err * GAIN, -max, max), halved when nearly aligned
## and close; curve slowdown via lookahead curvature.
## NO scene access — same floats in, same floats out. This is the SPEC
## the FSM delegates to (wired next); brains reuse it headless.

const STEER_GAIN := 2.2


## Solves steering for a lookahead point. Returns PursuitCommand with
## steering + arrival flag; speed/curvature stay with the caller.
## NOTE: Godot 2D rotation: +X right, +Y DOWN. So a target at +Y with
## rotation 0 yields angle_difference = -PI/2 (negative = screen-right).
## fsm_gain keeps each legacy path exact (2.2 trail / 2.8 auto /
## 3.0 buscando / 1.2 arrival / -0.9 trail reverse) in one solver.
## `halve` is the caller's deadband condition (legacy: CTE < 20 AND
## |err| < 0.15 in buscando/rota; none in trail) — pass it explicitly.
static func find_lookahead(vehicle_pos: Vector2, route: Array,
		distance: float, start_index: int = 0) -> Dictionary:
	if route.is_empty():
		return {"point": vehicle_pos, "index": start_index}
	var idx := clampi(start_index, 0, route.size() - 1)
	var best_point := route[idx] as Vector2
	var best_distance_squared := vehicle_pos.distance_squared_to(best_point)
	for i in range(idx, route.size() - 1):
		var a := route[i] as Vector2
		var b := route[i + 1] as Vector2
		var closest := Geometry2D.get_closest_point_to_segment(vehicle_pos, a, b)
		var segment_distance := vehicle_pos.distance_squared_to(closest)
		if segment_distance < best_distance_squared:
			best_distance_squared = segment_distance
			best_point = closest
			idx = i
	var remaining := distance
	var segment_length := best_point.distance_to(route[idx + 1] as Vector2) if idx < route.size() - 1 else 0.0
	if segment_length >= remaining:
		var point := best_point.lerp(route[idx + 1] as Vector2, remaining / maxf(segment_length, 0.001))
		return {"point": point, "index": idx}
	var point := route[idx + 1] as Vector2 if idx < route.size() - 1 else best_point
	for i in range(idx + 1, route.size() - 1):
		var next_length := point.distance_to(route[i + 1] as Vector2)
		if next_length >= remaining:
			point = point.lerp(route[i + 1] as Vector2, remaining / maxf(next_length, 0.001))
			idx = i
			break
		remaining -= next_length
		point = route[i + 1] as Vector2
		idx = i
	return {"point": route[route.size() - 1] as Vector2 if route.size() > 0 else vehicle_pos, "index": idx}


static func solve_lookahead(vehicle_pos: Vector2, vehicle_rot: float,
		lookahead: Vector2, max_steer: float, fsm_gain: float = STEER_GAIN,
		halve: bool = false) -> PursuitCommand:
	var cmd := PursuitCommand.new()
	cmd.lookahead_index = -1
	var dist := vehicle_pos.distance_to(lookahead)
	var err := 0.0
	if dist > 0.001:
		err = angle_difference(vehicle_rot, vehicle_pos.direction_to(lookahead).angle())
	if halve:
		err *= 0.5
	cmd.steering = clampf(err * fsm_gain, -max_steer, max_steer)
	cmd.arrived = dist < 14.0
	return cmd


static func solve(vehicle_pos: Vector2, vehicle_rot: float,
		idx: int, route: Array, max_steer: float,
		fsm_gain: float = STEER_GAIN, halve: bool = false) -> PursuitCommand:
	var target: Vector2 = route[idx] if idx < route.size() else vehicle_pos
	return solve_lookahead(vehicle_pos, vehicle_rot, target, max_steer, fsm_gain, halve)


## Same transform when the caller already owns the error (seta blend,
## lookahead-point choice): pass the final error directly.
static func solve_error(err: float, max_steer: float,
		fsm_gain: float = STEER_GAIN, halve: bool = false) -> PursuitCommand:
	var cmd := PursuitCommand.new()
	var e: float = err * (0.5 if halve else 1.0)
	cmd.steering = clampf(e * fsm_gain, -max_steer, max_steer)
	return cmd


## Scales straight speed down with lookahead curvature (matches Carro).
static func curve_speed(base: float, curv: float, max_speed: float) -> float:
	if curv > 0.05:
		return minf(base, max_speed * 0.55)
	if curv > 0.02:
		return minf(base, max_speed * 0.75)
	return base
