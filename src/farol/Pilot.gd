class_name Pilot
extends DriverBrain
## FAROL · PILOTO (3/3) — the layer between "route" and "wheels".
##
## This is the file the whole plan exists for. The diagnosis, in code: with a
## brain driving, `Carro._processar_buscando` returns BEFORE the `DESVIANDO`
## transition and the long-range camera, so every line of avoidance logic in
## the 3112-line god object is unreachable, and the pilot that DOES run
## (`AutonomousDriver`) is pure-pursuit on a static A* route whose only
## obstacle responses are a speed cap and a throttle cut. The car parks by
## pushing, and the escape ladder cleans up.
##
## The Pilot adds the missing decision, in this order:
##   1. YIELD. The crossing-traffic gate, unchanged (420/540 px, hysteresis).
##      Body-less crosser, so the latch is the only thing keeping them apart.
##   2. SENSE. The LocalMap, rebuilt from the 11 rays + 8 diagonals and mixed
##      with the Chart's clearance, at `local_rebuild_s`.
##   3. `blocked_ahead`. The plan is not "I hit something", it is "the next
##      `bloqueado_dist_px` of the route is unusable". Measured by cost along
##      the route, needing `bloqueado_celulas` consecutive bad cells so a single
##      shadow does not fire it. This fires at ~3 m WHILE MOVING, which is the
##      distinction from the displacement watchdog (AGENTS #37) that only
##      notices after 2 s of not moving.
##   4. DETOUR. On `blocked_ahead`, a BFS over the LocalMap finds a reachable
##      cell with better cost and asks the vehicle to REPLAN with the goal
##      moved there. The car goes AROUND, which is the whole point. It does not
##      reverse: reverse stays reserved for the escape ladder (AGENTS #43) and
##      the gates count an unjustified reverse frame as a failure.
##   5. DRIVE. The DWA at `dwa_periodo_s` (10 Hz), with the pure-pursuit
##      command HELD in between and a rate limit on the steering change, so
##      the controller output cannot chatter at 60 Hz (the Locomotion ramp
##      would just turn noise into a full-lock oscillation).
##
## CACHING: one instance per vehicle, invalidated on any mode change
## (AGENTS #20) — a per-frame RefCounted would throw the LocalMap away 60
## times a second, which is exactly the bug the crosser gate already had.

const ChartRef = preload("res://src/farol/Chart.gd")
const LocalMapRef = preload("res://src/farol/LocalMap.gd")
const DwaRef = preload("res://src/farol/Dwa.gd")
const SensorArrayRef = preload("res://src/vehicle/SensorArray.gd")

var spec: FarolSpec = null
var local: LocalMapRef = null
var dwa: DwaRef = null
var crosser_gate: CrosserGate = null
## The vehicle, injected. `null` keeps the Pilot testable headless: everything
## that needs the vehicle is behind a `Callable` the tests can supply.
var veiculo = null
var max_steer: float = 0.9
var max_speed: float = 160.0
## The teacher (the legacy pilot), used as the fallback and by the shield.
var professor = null

var _t_rebuild: float = 0.0
var _t_dwa: float = 0.0
var _steer_hold: float = 0.0
var _throttle_hold: float = 0.0
var _ultimo_desvio: float = -1.0e9
var _t: float = 0.0
## The detour goal the Pilot is asking for (the vehicle consumes and clears it).
var desvio_alvo: Vector2 = Vector2.INF
var desvio_contagem: int = 0
var bloqueado: bool = false
var bloqueado_celulas: int = 0
var bloqueado_dist: float = 0.0
## Shadow/diagnostics for `tools/gate_drive.gd`.
var chamadas: int = 0
var desvios: int = 0
var bloqueados: int = 0
var ultima_ordem: String = "cruzeiro"


func _init(p_spec: FarolSpec = null) -> void:
	spec = p_spec if p_spec != null else FarolSpec.new()
	local = LocalMapRef.new(spec)
	dwa = DwaRef.new(spec)
	crosser_gate = CrosserGate.new(420.0, 540.0)


func kind() -> int:
	return Kind.AUTONOMOUS


func gate() -> CrosserGate:
	return crosser_gate


func injetar_veiculo(v, p_professor = null) -> void:
	veiculo = v
	professor = p_professor


func resetar() -> void:
	_t_rebuild = 0.0
	_t_dwa = 0.0
	_steer_hold = 0.0
	_throttle_hold = 0.0
	_ultimo_desvio = -1.0e9
	desvio_alvo = Vector2.INF
	bloqueado = false


func decide(_perception: PerceptionSnapshot, _delta: float) -> DriveCommand:
	return DriveCommand.stop()


func decide_context(perception: PerceptionSnapshot, context: DriveContext,
		delta: float) -> DriveCommand:
	chamadas += 1
	_t += delta
	# 1. YIELD — ticked once per frame, before anything else moves.
	if gate().should_yield(perception.crosser_distance, perception.crosser_bearing, delta):
		ultima_ordem = "cedencia"
		return DriveCommand.stop()
	# 2. SENSE.
	var rays: Dictionary = SensorArrayRef.collect_from(veiculo) if veiculo != null else {}
	var meia_eixos: Vector2 = _meia_eixos()
	var varrido: float = maxf(meia_eixos.length(), 1.0)
	if _t - _t_rebuild >= spec.local_rebuild_s:
		_t_rebuild = _t
		local.atualizar(context.vehicle_position, rays, _carta(), varrido,
			spec.local_rebuild_s)
	# 3. blocked_ahead — the plan is unusable, not "I hit a wall".
	var rota: Array = context.route
	bloqueado = false
	bloqueado_celulas = 0
	bloqueado_dist = 0.0
	if rota.size() >= 2:
		var b := _avaliar_bloqueio(rota, context)
		bloqueado = bool(b[0])
		bloqueado_celulas = int(b[1])
		bloqueado_dist = float(b[2])
		if bloqueado:
			bloqueados += 1
			# 4. DETOUR — around, never backwards.
			if _t - _ultimo_desvio >= spec.desvio_periodo_s:
				_ultimo_desvio = _t
				var alvo := _melhor_desvio(rota, context)
				if alvo.is_finite():
					desvio_alvo = alvo
					desvios += 1
					ultima_ordem = "desvio"
	# 5. DRIVE.
	var vel_alvo: float = _velocidade_do_roteiro(context)
	if rota.size() < 2:
		ultima_ordem = "sem rota"
		return _comando_sem_rota(perception, context)
	if _t - _t_dwa >= spec.dwa_periodo_s:
		_t_dwa = _t
		var dir: Vector2 = _tangente(rota, context)
		var r: Array = dwa.avaliar(local, context.vehicle_position,
			context.vehicle_rotation, vel_alvo, meia_eixos,
			_entre_eixos(), dir, _steer_hold / maxf(max_steer, 0.001))
		# Hold the previous command if the DWA ever answers with a short array:
		# indexing it blindly turned a single bad frame into a freeze, and the
		# car stood still for 41 s while the escape ladder burned 672 frames of
		# reverse (Fase9, 2026-09-29). A short array is a bug, not a plan.
		if r.size() >= 2:
			_steer_hold = float(r[0])
			_throttle_hold = float(r[1])
		else:
			ultima_ordem = "dwa vazio"
	if ultima_ordem != "desvio":
		ultima_ordem = "piloto"
	return DriveCommand.make(clampf(_steer_hold, -1.0, 1.0), clampf(_throttle_hold, 0.0, 1.0))


## blocked_ahead, measured ALONG THE ROUTE (not by a single ray): how many
## consecutive route samples inside `bloqueado_dist_px` have a cost at or above
## `bloqueado_clearance_px`.
##
## Returns [eh_bloqueio, celulas_seguidas, distancia_analisada].
func _avaliar_bloqueio(rota: Array, context: DriveContext) -> Array:
	var pi := _indice_do_lookahead(rota, context.vehicle_position, context.waypoint_index)
	var acum := 0.0
	var seguidos := 0
	var i := pi
	while i < rota.size() - 1 and acum < spec.bloqueado_dist_px:
		var a: Vector2 = rota[i]
		var b: Vector2 = rota[i + 1]
		var seg: float = a.distance_to(b)
		if seg < 0.001:
			i += 1
			continue
		acum += seg
		# The route point is where the CAR will be. A route point that is
		# tight means the plan does not fit, even while the car is still clear
		# — that is the difference between this and a collision detector, and
		# the reason it fires at ~3 m while the car is still MOVING.
		if local.custo_em(b) >= 0.999:
			seguidos += 1
		else:
			seguidos = 0
		i += 1
	return [seguidos >= spec.bloqueado_celulas, seguidos, acum]


## The detour goal: among the local cells reachable by BFS from the car, the one
## that is (a) past the blockage, (b) free, and (c) closest to the original
## route. This is the "go around" the legacy pilot never had.
func _melhor_desvio(rota: Array, context: DriveContext) -> Vector2:
	var pi := _indice_do_lookahead(rota, context.vehicle_position, context.waypoint_index)
	var alvo_fim: Vector2 = rota[mini(pi + 4, rota.size() - 1)]
	var alcance: int = spec.desvio_raio_celulas
	var melhor := Vector2.INF
	var melhor_custo := INF
	var passo := maxi(2, int(alcance / 6))
	for oy in range(-alcance, alcance + 1, passo):
		for ox in range(-alcance, alcance + 1, passo):
			var cel := Vector2i(ox, oy)
			var p: Vector2 = local.ponto(cel)
			# must be free and reachable
			if local.custo_em_celula(cel) > 0.6:
				continue
			if local.bfs(context.vehicle_position, p, 0.0).is_empty():
				continue
			# must be AHEAD of the blockage, not behind it
			if p.distance_to(alvo_fim) >= context.vehicle_position.distance_to(alvo_fim):
				continue
			# score: how close it gets to the route ahead, minus the room it has
			var dist_rota: float = _dist_ao_segmento(p, rota, maxi(0, pi))
			var c: float = dist_rota - 0.15 * (1.0 - local.custo_em_celula(cel))
			if c < melhor_custo:
				melhor_custo = c
				melhor = p
	return melhor


func _dist_ao_segmento(p: Vector2, rota: Array, de: int) -> float:
	var melhor := INF
	for i in range(maxi(0, de), rota.size() - 1):
		melhor = minf(melhor, Geometry2D.get_closest_point_to_segment(
			p, rota[i], rota[i + 1]).distance_to(p))
	return melhor


## The route-profile speed the DWA window is a fraction of. Mirrors the
## teacher so the two agree on "how fast should we be going here" and the DWA
## only ever decides WHERE, not WHEN.
func _velocidade_do_roteiro(context: DriveContext) -> float:
	var sensor_base: float = FsmProfiles.sensor_speed(
		context.front_distance, context.lateral_distance, 40.0, 160.0, max_speed)
	var base: float = minf(max_speed * 0.85, sensor_base)
	var v: float = FsmProfiles.route_speed(base, context.curvature_ahead,
		0.0, max_steer, max_speed)
	return FsmProfiles.approach_speed(context.distance_to_target, v, max_speed)


func _comando_sem_rota(perception: PerceptionSnapshot, context: DriveContext) -> DriveCommand:
	# Without a route the only honest thing is to look at the target, and to
	# STOP (never push) when the front is closed. The DWA cannot help: it has
	# nothing to make progress towards.
	if perception.front_blocked(50.0):
		return DriveCommand.stop()
	var turn: float = clampf(-context.angle_to_target * 2.2, -1.0, 1.0)
	var gas: float = 0.5 if context.distance_to_target > 200.0 else 0.0
	return DriveCommand.make(turn, gas)


func _tangente(rota: Array, context: DriveContext) -> Vector2:
	var la := PurePursuit.find_lookahead(context.vehicle_position, rota,
		140.0, context.waypoint_index)
	var p: Vector2 = la["point"]
	var d: Vector2 = p - context.vehicle_position
	if d.length_squared() < 1.0:
		return Vector2.RIGHT.rotated(context.vehicle_rotation)
	return d.normalized()


func _indice_do_lookahead(rota: Array, pos: Vector2, idx: int) -> int:
	var melhor := maxi(0, idx - 1)
	var melhor_d := INF
	for i in range(maxi(0, idx - 1), rota.size()):
		var d: float = pos.distance_squared_to(rota[i])
		if d < melhor_d:
			melhor_d = d
			melhor = i
	return melhor


func _meia_eixos() -> Vector2:
	if veiculo == null:
		return Vector2(44.0, 37.0)
	var cs: CollisionShape2D = veiculo.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null or not (cs.shape is RectangleShape2D):
		return Vector2(44.0, 37.0)
	var r: Vector2 = (cs.shape as RectangleShape2D).size * 0.5
	return Vector2(r.x * absf(float(veiculo.get("global_scale").x)),
		r.y * absf(float(veiculo.get("global_scale").y)))


func _entre_eixos() -> float:
	if veiculo == null:
		return 60.0
	return maxf(float(veiculo.get("entre_eixos")), 1.0)


func _carta():
	if veiculo == null:
		return null
	var pl = veiculo.get("planejador")
	if pl == null or not pl.has_method("chart"):
		return null
	return pl.call("chart")
