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
	# The vehicle's TRUE progress is normally BETWEEN idx-1 and idx (the FSM
	# advances the index as soon as it is within tolerance of the waypoint),
	# so the anchor must include the previous segment. Anchoring only at `idx`
	# starts the chord a whole segment ahead (up to ~810 px on Fase3) and a
	# far point can land at a coincidental bearing with the car's (wrong)
	# heading -> zero steering -> the car drives straight into the sidewalk
	# (the eternal CalcadaBase grind).
	var anchor := maxi(idx - 1, 0)
	var idx_best := anchor
	var best_point := route[anchor] as Vector2
	var best_distance_squared := vehicle_pos.distance_squared_to(best_point)
	for i in range(anchor, route.size() - 1):
		var a := route[i] as Vector2
		var b := route[i + 1] as Vector2
		var closest := Geometry2D.get_closest_point_to_segment(vehicle_pos, a, b)
		var segment_distance := vehicle_pos.distance_squared_to(closest)
		if segment_distance < best_distance_squared:
			best_distance_squared = segment_distance
			best_point = closest
			idx_best = i
	idx = idx_best
	var remaining := distance
	var segment_length := best_point.distance_to(route[idx + 1] as Vector2) if idx < route.size() - 1 else 0.0
	if segment_length >= remaining:
		var point := best_point.lerp(route[idx + 1] as Vector2, remaining / maxf(segment_length, 0.001))
		return {"point": point, "index": idx}
	var point: Vector2 = route[idx + 1] as Vector2 if idx < route.size() - 1 else best_point
	for i in range(idx + 1, route.size() - 1):
		var next_length := point.distance_to(route[i + 1] as Vector2)
		if next_length >= remaining:
			point = point.lerp(route[i + 1] as Vector2, remaining / maxf(next_length, 0.001))
			idx = i
			break
		remaining -= next_length
		point = route[i + 1] as Vector2
		idx = i
	# Fall-through (lookahead spans several segments, the common case on a
	# fresh A* route) MUST return the interpolated point. Returning
	# route[last] silently aimed the pilot at the FINAL waypoint (the spot
	# approach), which on Fase3 pointed straight into CalcadaBase: zero
	# steering + full throttle = eternal grind (F3 deadlock).
	return {"point": point, "index": idx}


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
##
## `cross_track` (px, com sinal: POSITIVO quando o veiculo esta a DIREITA da
## rota) e o termo lateral do controlador STANLEY, e nao um enfeite. O pure
## pursuit sozinho converge so assintoticamente: com um vies lateral constante
## — que e exatamente a faixa deslocada para a direita — ele deixa um erro
## permanente. Medido na Fase2: o carro assentava 75-130 px a oeste do meio da
## faixa (o alvo era x=1019, ele ficava em 944) e nenhum ajuste de `fsm_gain` ou
## de look-ahead tirava aquilo (reduzir o look-ahead para 90 px moveu 5 px e
## deixou a rota instavel). O termo e' `atan(k * e / v)`: quanto mais longe da
## linha, mais forte; e some com a velocidade porque o mesmo desvio a 200 px/s
## e muito mais toleravel que a 40 px/s.
static func solve_error(err: float, max_steer: float,
		fsm_gain: float = STEER_GAIN, halve: bool = false,
		cross_track: float = 0.0, speed: float = 0.0,
		k_cross: float = 1.4) -> PursuitCommand:
	var cmd := PursuitCommand.new()
	var e: float = err * (0.5 if halve else 1.0)
	var s: float = clampf(e * fsm_gain, -max_steer, max_steer)
	if absf(cross_track) > 0.5 and speed > 1.0:
		var v: float = maxf(speed, VELOCIDADE_MIN_STANLEY)
		# `cross_track` > 0 = o veiculo esta a DIREITA da rota, logo a rota esta
		# a esquerda dele e a correcao e para a ESQUERDA (estercamento NEGATIVO
		# neste projeto). A primeira versao somava o termo e jogava o carro para
		# o lado errado da via.
		# teto em meia esterco: o termo lateral serve para ACERTAR a faixa, nao
		# para virar o carro. Sem teto, um desvio grande satura o angulo e o
		# carro entra em oscilacao de meia-volta.
		s -= clampf(atan(k_cross * cross_track / v), -max_steer * 0.5, max_steer * 0.5)
		if halve:
			s *= 0.5
	cmd.steering = clampf(s, -max_steer, max_steer)
	return cmd


## piso de velocidade do termo lateral: abaixo disso o carro esta manobrando e o
## termo Stanley com velocidade quase zero diverge.
## Piso de velocidade do termo lateral. Medido: com 30 px/s o termo saturava
## (atan -> 90 graus) e o carro oscilava na manobra final — 42 frames de RE
## indevida na Fase2 (o gate reprova em neg_frames > 0). 60 px/s corta a
## oscilacao sem perder a correcao de faixa, que importa acima de ~100 px/s.
const VELOCIDADE_MIN_STANLEY := 60.0


## Scales straight speed down with lookahead curvature (matches Carro).
static func curve_speed(base: float, curv: float, max_speed: float) -> float:
	if curv > 0.05:
		return minf(base, max_speed * 0.55)
	if curv > 0.02:
		return minf(base, max_speed * 0.75)
	return base
