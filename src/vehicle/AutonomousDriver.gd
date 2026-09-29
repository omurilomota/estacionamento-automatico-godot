class_name AutonomousDriver
extends DriverBrain

var max_steer: float = 0.9
var max_speed: float = 160.0

## C2: the yield decision is STATEFUL (latch + min hold), so the gate is an
## instance var — which only works because the vehicle CACHES the brain
## (`Carro._brain_for_current_mode()`, C2b). A fresh brain per frame would
## never hold for even one frame.
var crosser_gate: CrosserGate = null


func kind() -> int:
	return Kind.AUTONOMOUS


func gate() -> CrosserGate:
	if crosser_gate == null:
		# 420/540 px e nao 220/340: a 220 px o carro parava COLADO no crosser
		# (min_gap 78 px com carros de 163 px de largura = sobrepostos, foto de
		# 2026-09-26). A ~420 px o carro freia ~200 px ANTES da faixa e espera
		# la, com o transito passando na frente e folga visivel.
		crosser_gate = CrosserGate.new(420.0, 540.0)
	return crosser_gate


func decide(perception: PerceptionSnapshot, delta: float) -> DriveCommand:
	if gate().should_yield(perception.crosser_distance, perception.crosser_bearing, delta):
		return DriveCommand.stop()
	return _steer_to_target(perception)


func decide_context(perception: PerceptionSnapshot, context: DriveContext, _delta: float) -> DriveCommand:
	# The gate is ticked ONCE per frame here: `decide()` below would tick it a
	# second time when there is no route, doubling the min hold.
	if gate().should_yield(perception.crosser_distance, perception.crosser_bearing, _delta):
		return DriveCommand.stop()
	if context.route.is_empty():
		return _steer_to_target(perception)
	var lookahead_data := PurePursuit.find_lookahead(
		context.vehicle_position, context.route, _lookahead_for(context), context.waypoint_index)
	var pursuit := PurePursuit.solve_lookahead(
		context.vehicle_position, context.vehicle_rotation, lookahead_data.point,
		max_steer, 2.8, false)
	pursuit.lookahead_index = int(lookahead_data.index)
	var angular_error := angle_difference(
		context.vehicle_rotation,
		context.vehicle_position.direction_to(lookahead_data.point).angle())
	if is_finite(context.cte) and context.cte > 220.0 and absf(context.speed) < 15.0:
		pursuit.reverse = true
		pursuit.speed = -60.0
	elif absf(angular_error) > 2.2 and context.distance_to_target > 80.0 \
			and not (is_finite(context.cte) and context.cte <= 80.0):
		# So da RE se o carro esta mesmo perdido. Com o caminho suavizado, um
		# erro de proa > 126 graus quase sempre e' o PONTO DE MIRA que ficou para
		# tras (o carro esta colado na rota, `cte` pequeno) — e dar re nesse caso
		# produz a ida-e-volta de meia-volta que o usuario viu (ate 51 frames).
		# O `cte` e' <= 80 (e nao < 80) porque o limite era uma fronteira
		# ABERTA: num boot da Fase8 o carro parou em cte=80.0 exatos, o guarda
		# acima deu `not(false) = true` e a RE disparou no caso que o proprio
		# comentario manda nao reverter (12 frames de re, gate_boot reprovado por
		# NEG_FRAMES=12 num boot de 5). O carro ESTACIONOU em todas as 5
		# observacoes, entao o defeito era so a re indevida, nao o estacionamento.
		pursuit.reverse = true
		pursuit.speed = -60.0
		pursuit.steering = -pursuit.steering
	else:
		# v2 (F3 fix): base speed must be a TARGET, not the current speed.
		# Passing context.speed made route_speed return min(0, curv) = 0 for
		# a stopped car -> it never accelerated again (silent deadlock).
		var sensor_base := FsmProfiles.sensor_speed(
			context.front_distance, context.lateral_distance, 40.0, 160.0, max_speed)
		var base_speed := minf(max_speed * 0.85, sensor_base)
		pursuit.speed = FsmProfiles.route_speed(
			base_speed, context.curvature_ahead, angular_error,
			max_steer, max_speed)
		pursuit.speed = FsmProfiles.approach_speed(
			context.distance_to_target, pursuit.speed, max_speed)
		if context.arrived and context.distance_to_target < 200.0:
			pursuit.speed = 0.0
	return DriveCommandAdapter.from_pursuit(pursuit, max_steer, max_speed)


## Route-less fallback (no A* path yet): head for the target, stop if a real
## obstacle is in the way. Crossing traffic is handled by the gate above.
func _steer_to_target(perception: PerceptionSnapshot) -> DriveCommand:
	if perception.front_blocked(50.0):
		return DriveCommand.stop()
	var turn := clampf(-perception.angle_to_target * 2.2, -1.0, 1.0)
	var gas := 0.5 if perception.distance_to_target > 200.0 else 0.0
	return DriveCommand.make(turn, gas)


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


## Adaptive lookahead: never aim past what the front ray can see, so a
## 180px chord does not cut corners into walls (the classic pure-pursuit
## failure that made the A* pilot grind against obstacles).
func _lookahead_for(context: DriveContext) -> float:
	var base := clampf(70.0 + absf(context.speed) * 0.35, 70.0, 150.0)
	if is_finite(context.front_distance):
		base = minf(base, maxf(context.front_distance * 0.9, 60.0))
	# v2 (F3 fix): the front rays do NOT see a corner the body is about to
	# clip (contact is on the hull, df/dl stay INF), so the ray cap alone
	# is not enough. Cap the chord to the next sharp bend as well.
	base = minf(base, turn_cap(context.route, context.waypoint_index,
		context.vehicle_position))
	return clampf(base, 60.0, 150.0)


## Sharper than this (~18 deg) between two route legs counts as a bend the
## pursuit chord must not cut across.
const TURN_THRESHOLD := 0.32
const TURN_CAP_MIN := 60.0
const LOOKAHEAD_MAX := 150.0


## Lookahead cap for the next sharp bend: aim AT the corner instead of
## through it. Fase3 grinds on CalcadaBase ~62px short of wp4 because a
## 180px chord leaves the aisle leg (y = 1240.5, heading 0) to chase
## wp5 (heading -0.675) and drives the hull corner into the sidewalk.
## Bends already behind the vehicle are skipped (the hull cannot cut
## what it has passed). Straight routes keep the full LOOKAHEAD_MAX chord.
static func turn_cap(route: Array, idx: int, vehicle_pos: Vector2) -> float:
	if route.size() < 3:
		return LOOKAHEAD_MAX
	var start := clampi(idx, 0, route.size() - 3)
	for k in range(start, route.size() - 2):
		var b: Vector2 = route[k + 1]
		var leg_out: Vector2 = (route[k + 2] as Vector2) - b
		if leg_out.length_squared() < 1.0:
			continue
		if (vehicle_pos - b).dot(leg_out) > 0.0:
			continue
		var leg_in: Vector2 = b - (route[k] as Vector2)
		if leg_in.length_squared() < 1.0:
			continue
		if absf(angle_difference(leg_in.angle(), leg_out.angle())) > TURN_THRESHOLD:
			return maxf(vehicle_pos.distance_to(b), TURN_CAP_MIN)
	return LOOKAHEAD_MAX


## Yaw penalty for spot choice (mirrors Carro._penalidade_rumo): 0 when
## the route arrives aligned to the spot nose, INF when it would require
## a reverse entry (forward-only parking, locked A2).
static func yaw_penalty(route: Array, spot_yaw: float) -> float:
	if route.size() < 2:
		return INF
	var end_dir: Vector2 = (route[route.size() - 1] as Vector2) - (route[route.size() - 2] as Vector2)
	if end_dir.length_squared() < 1.0:
		return 0.0
	var nose := Vector2.RIGHT.rotated(spot_yaw)
	var misalign: float = absf(angle_difference(end_dir.angle(), nose.angle()))
	if misalign > deg_to_rad(100.0):
		return INF
	return misalign * 200.0
