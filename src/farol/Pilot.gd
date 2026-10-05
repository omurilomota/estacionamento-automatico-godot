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
##   1. SAFETY. The pedestrian gate (docs/tasks_trafego.md T2) — a pedestrian
##      has priority over everything; a stopped car cannot hurt a person.
##   2. YIELD. The crossing-traffic gate, unchanged (420/540 px, hysteresis).
##      Body-less crosser, so the latch is the only thing keeping them apart.
##   3. SENSE. The LocalMap, rebuilt from the 11 rays + 8 diagonals and mixed
##      with the Chart's clearance, at `local_rebuild_s`.
##   4. `blocked_ahead`. The plan is not "I hit something", it is "the next
##      `bloqueado_dist_px` of the route is unusable". Measured by cost along
##      the route, needing `bloqueado_celulas` consecutive bad cells so a single
##      shadow does not fire it. This fires at ~3 m WHILE MOVING, which is the
##      distinction from the displacement watchdog (AGENTS #37) that only
##      notices after 2 s of not moving.
##   5. DETOUR. On `blocked_ahead`, a BFS over the LocalMap finds a reachable
##      cell with better cost and asks the vehicle to REPLAN with the goal
##      moved there. The car goes AROUND, which is the whole point. It does not
##      reverse: reverse stays reserved for the escape ladder (AGENTS #43) and
##      the gates count an unjustified reverse frame as a failure.
##   6. DRIVE. The DWA at `dwa_periodo_s` (10 Hz), with the pure-pursuit
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
## The pedestrian gate (docs/tasks_trafego.md T2): a pedestrian has PRIORITY —
## ticked BEFORE the crosser gate, so a person in front wins over everything.
## Latched generously (360/480 px): sensor-only, so the latch is the only
## protection against ever running one over.
var pedestrian_gate: CrosserGate = null
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
var _steer_abs: float = 0.0
## Edge-triggered [PED] log flag (first frame of a pedestrian latch).
var _ped_log_recente: bool = false
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
var pedestrian_latches: int = 0
var ultima_ordem: String = "cruzeiro"
## The give-way ceiling (0..1): the pedestrian yield's throttle ceiling,
## applied to the DWA's command at the end of `decide_context` — the steering
## keeps coming from the drive path (the Fase11 lesson).
var give_way_ceiling: float = 1.0


func _init(p_spec: FarolSpec = null) -> void:
	spec = p_spec if p_spec != null else FarolSpec.new()
	local = LocalMapRef.new(spec)
	dwa = DwaRef.new(spec)
	crosser_gate = CrosserGate.new(420.0, 540.0)
	pedestrian_gate = CrosserGate.new(360.0, 480.0)
	pedestrian_gate.strict_release = true


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
	_steer_abs = 0.0
	desvio_alvo = Vector2.INF
	bloqueado = false
	# `_ultimo_desvio` DELIBERATELY survives (Fase5, 2026-09-29): the vehicle
	# consumes a detour by calling `resetar()`, and clearing the cooldown here
	# let the same blockage re-fire on the very next frame — 30 detours in one
	# 11 s run. The period is the anti-loop, so only the REQUEST is consumed.


func decide(_perception: PerceptionSnapshot, _delta: float) -> DriveCommand:
	return DriveCommand.stop()


func decide_context(perception: PerceptionSnapshot, context: DriveContext,
		delta: float) -> DriveCommand:
	chamadas += 1
	_t += delta
	# 1. SAFETY — a pedestrian has priority over everything (docs/tasks_trafego.md
	#    T2). Sensor-only, so this latch is the only protection against ever
	#    running one over; a stopped car cannot hurt a person. The command is
	#    the GIVE-WAY: the THROTTLE falls to zero at `PED_GIVEWAY_GAP` px from
	#    the pedestrian, and the STEERING keeps coming from the drive path
	#    below — a steering-0 glide drove the car straight off its lane
	#    (measured on Fase11: 255 px off the route after a yield fired at the
	#    spawn, and the brain's cte branch fired the reverse for 107 frames).
	#    NOT returning early: the drive path computes the steering, and the
	#    give-way ceiling is applied to the throttle at the end.
	if perception.pedestrian_distance < INF and pedestrian_gate.should_yield(
			perception.pedestrian_distance, perception.pedestrian_bearing, delta):
		pedestrian_latches += 1
		ultima_ordem = "pedestre"
		_ped_log(perception)
		give_way_ceiling = clampf(
			(perception.pedestrian_distance - CrosserGate.PED_GIVEWAY_GAP)
				/ CrosserGate.PED_GIVEWAY_RAMP, 0.0, 1.0)
	else:
		give_way_ceiling = 1.0
	# 2. YIELD — ticked once per frame, before anything else moves. The label
	#    does not overwrite "pedestre": a pedestrian has priority, and the
	#    command is a stop either way (safe for both).
	if gate().should_yield(perception.crosser_distance, perception.crosser_bearing, delta):
		if ultima_ordem != "pedestre":
			ultima_ordem = "cedencia"
		return DriveCommand.stop()
	# 3. SENSE.
	var rays: Dictionary = SensorArrayRef.collect_from(veiculo) if veiculo != null else {}
	var meia_eixos: Vector2 = _meia_eixos()
	var varrido: float = maxf(meia_eixos.length(), 1.0)
	if _t - _t_rebuild >= spec.local_rebuild_s:
		_t_rebuild = _t
		local.atualizar(context.vehicle_position, rays, _carta(), varrido,
			spec.local_rebuild_s, _folga_estatica_do_corpo)
	# 4. blocked_ahead — the plan is unusable, not "I hit a wall".
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
			# 5. DETOUR — around, never backwards.
			if _t - _ultimo_desvio >= spec.desvio_periodo_s:
				_ultimo_desvio = _t
				var alvo := _melhor_desvio(rota, context)
				if alvo.is_finite():
					desvio_alvo = alvo
					desvios += 1
					ultima_ordem = "desvio"
	# 6. DRIVE. The route speed, THEN the static-choke cap: the profile must
	# know how much room the WHOLE hull has, not just the route's cell centres.
	var vel_alvo: float = _velocidade_do_roteiro(context)
	vel_alvo = _velocidade_do_gargalo(vel_alvo)
	if rota.size() < 2:
		ultima_ordem = "sem rota"
		return _comando_sem_rota(perception, context)
	if _t - _t_dwa >= spec.dwa_periodo_s:
		_t_dwa = _t
		var dir: Vector2 = _tangente(rota, context)
		var r: Array = dwa.avaliar(local, context.vehicle_position,
			context.vehicle_rotation, vel_alvo, meia_eixos,
			_entre_eixos(), dir, _steer_hold, maxf(max_steer, 0.05),
			maxf(max_speed, 20.0))
		# Hold the previous command if the DWA ever answers with a short array:
		# indexing it blindly turned a single bad frame into a freeze, and the
		# car stood still for 41 s while the escape ladder burned 672 frames of
		# reverse (Fase9, 2026-09-29). A short array is a bug, not a plan.
		if r.size() >= 2:
			_steer_hold = float(r[0])
			_throttle_hold = float(r[1])
			_steer_abs = _steer_hold * maxf(max_steer, 0.05)
		else:
			ultima_ordem = "dwa vazio"
	if ultima_ordem != "desvio" and ultima_ordem != "pedestre":
		ultima_ordem = "piloto"
	return DriveCommand.make(clampf(_steer_hold, -1.0, 1.0),
		clampf(minf(_throttle_hold, give_way_ceiling), 0.0, 1.0))


## Edge-triggered [PED] log (the [RE-BRAIN] pattern): the first frame of a
## pedestrian latch, with the numbers.
func _ped_log(per: PerceptionSnapshot) -> void:
	if _ped_log_recente:
		return
	_ped_log_recente = true
	var pos := Vector2.INF
	if veiculo != null:
		pos = veiculo.global_position
	print("[PED] d=%.0f bearing=%.2f vel=%.0f pos=(%.0f,%.0f)" % [
		per.pedestrian_distance, per.pedestrian_bearing, per.speed, pos.x, pos.y])


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
		# The route point is where the CAR will be. `bloqueado_clearance_px` is
		# the spec's MINIMUM threshold on the local cost, and it must be read as
		# a FLOOR over the hard gate, not as a replacement (measured wrong way,
		# Fase9 2026-09-29): the cost field is a GRADIENT — mixing the Chart
		# writes ~0.75 on legal corridor-adjacent cells (cl = raio + 1.5 cells)
		# — so a raw low threshold marks a LEGAL route as blocked and the detour
		# replans in a loop every `desvio_periodo_s`. "The plan does not fit"
		# means the hull would TOUCH (cost >= 0.999: chart clearance at the
		# swept radius, or a solid painted by a ray). The spec raises the bar,
		# never lowers it.
		var custo: float = local.custo_em(b)
		if custo >= maxf(0.999, spec.bloqueado_clearance_px):
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


## Speed the STATIC room under the hull allows (Fase9 choke fix, 2026-09-29).
## The route profile only reads the CHART at the route's cell centres; a 400
## px gap that the scaled hull crosses with ~8 px to spare is `folga = free`
## there, so `vel_alvo` arrived at full cruise, every fast DWA arc died on
## contact and the window settled for creep + reverse loops. The static
## integral under the WHOLE footprint (`folga_media_corpo`, 0..1 = share of
## the swept radius the body is buried) is the number the profile was missing.
## The cap is deliberately a CEILING profile: below `normal` (most of the
## radius of room) no cap; down to `minimo` (creep) at the tightest fit; the
## rate-limited steering does the steering.
## `folga_media_corpo` POLARITY: 0 = the hull has swept-radius room everywhere
## (open), 1 = the hull is fully buried (clearance ~0 under the body). The cap
## therefore ENGAGES as f GROWS past `normal`, and crawls towards `v_teto` as f
## approaches 1. (The first version had this backwards — it capped f BELOW the
## threshold, i.e. the open road — which ModulesCheck caught as
## `Pilot.cap_crawls_in_choke` failing at f=0.9 returning full speed.)
func _velocidade_do_gargalo(vel: float) -> float:
	var f: float = local.folga_media_corpo
	# -1 = metric undefined (no chart yet); 0 = open. Both pass through.
	if f <= 0.0:
		return vel
	var normal: float = 0.35
	if f <= normal:
		return vel
	# 0..1 from "room is getting tight" to "fully buried"
	var t: float = clampf((f - normal) / (1.0 - normal), 0.0, 1.0)
	var k: float = t * t * (3.0 - 2.0 * t) # smoothstep
	var v_teto: float = maxf(45.0, vel * 0.30)
	# Crawl to ~15% of the profile at the worst burial; never below v_teto.
	return maxf(v_teto, vel * (1.0 - k * 0.85))


func _comando_sem_rota(perception: PerceptionSnapshot, context: DriveContext) -> DriveCommand:
	# Without a route the only honest thing is to look at the target, and to
	# STOP (never push) when the front is closed. The DWA cannot help: it has
	# nothing to make progress towards.
	if perception.front_blocked(50.0):
		return DriveCommand.stop()
	var turn: float = clampf(-context.angle_to_target * 2.2, -1.0, 1.0)
	var gas: float = 0.5 if context.distance_to_target > 200.0 else 0.0
	return DriveCommand.make(turn, gas)


## The body-integral over the LOCAL grid's cells, using the same `folga` px
## the route profile and `misturar_carta` read. Exposed as a Callable for
## `LocalMap.atualizar` — the metric lives with the map, the policy (the cap)
## lives with the Pilot. Cells outside the chart count as 0 room (NEVER
## overstated).
func _folga_estatica_do_corpo(pos: Vector2, _ignored: float) -> void:
	var chart = _carta()
	if chart == null or veiculo == null:
		local.folga_media_corpo = -1.0
		return
	var meia: Vector2 = _meia_eixos()
	var raio: float = maxf(meia.length(), 1.0)
	var cel0: Vector2i = chart.celula_de(pos)
	var n: int = maxi(2, int(raio / chart.resolucao))
	var soma := 0.0
	var total := 0
	var pior := INF
	for gy in range(-n, n + 1):
		for gx in range(-n, n + 1):
			var cel := cel0 + Vector2i(gx, gy)
			var centro: Vector2 = chart.centro_de(cel)
			if centro.distance_to(pos) > raio:
				continue
			var f: float = chart.folga(cel)
			var no_corpo: float = maxf(0.0, raio - f)
			soma += no_corpo
			total += 1
			pior = minf(pior, f)
	if total <= 0:
		local.folga_media_corpo = -1.0
		return
	local.folga_media_corpo = soma / float(total) / maxf(raio, 1.0)
	local.folga_pior_px = pior


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
	# MODEL/EFFECTOR PARITY: the mover turns with `entre_eixos * escala_media`
	# (Carro._aplicar_movimento), so the rollout must too. The bare 60 px made
	# every DWA arc curve ~40% tighter than the chassis could follow at the
	# phases' scales (1.1..2.2) — the chase oscillated around the route and the
	# measured cte was 33.6 px against the legacy 18.0 (Fase9, 2026-09-29).
	if veiculo == null:
		return 84.0
	var entre_eixos: float = float(veiculo.get("entre_eixos")) if "entre_eixos" in veiculo else 60.0
	var escala: float = 1.0
	var gs: Vector2 = veiculo.get("global_scale") as Vector2 if veiculo.get("global_scale") is Vector2 else Vector2.ONE
	escala = maxf((gs.x + gs.y) * 0.5, 1.0)
	return maxf(entre_eixos * escala, 1.0)


func _carta():
	if veiculo == null:
		return null
	var pl = veiculo.get("planejador")
	if pl == null or not pl.has_method("chart"):
		return null
	return pl.call("chart")
