class_name Dwa
extends RefCounted
## FAROL · PILOTO (2/3) — Dynamic Window Approach: 27 arcs, rolled honestly.
##
## The legacy pilot had exactly two reactions to an obstacle: cap the speed and
## cut the throttle. Both are "stop", and a stopped car in a corridor is a car
## that needs the escape ladder. The DWA is the missing half: instead of
## asking "is the thing in front of me blocked", it asks "of the motions I
## could execute in the next 1.2 s, which one makes the most progress without
## putting the hull in a cell below the swept radius?" — and steering away is
## one of the answers, not an exception.
##
## The window: 9 steering commands x `dwa_velocidades` (3 by default) = 27
## arcs, each rolled for `dwa_horizonte_s` in `dwa_passo_s` steps against the
## LocalMap's cost field with a swept FOOTPRINT (not a point: the hull is
## 88x74 scaled, and a point test is how a car grinds along a wall with every
## ray reading INF).
##
## NO REVERSE. Reverse is the escape ladder's job (AGENTS #37/#43) and the
## gates count an unjustified reverse frame as a failure (`neg_frames`). The
## DWA therefore samples `speed >= 0` only, and the pilot escalates to a
## DETOUR rather than a manoeuvre. That is the whole point of the layer: turn
## around is a planner decision, not a controller one.
##
## Cost (all normalised; progress is the only px-valued term):
##   score = w_progresso * progress
##         - w_colisao      * collision      (0 or 1, hard veto above 0.9)
##         - w_folga_piloto * clearance_cost   (WORST cell over the rollout,
##                            NOT the mean: the mean dilutes a wall touch by
##                            the 12 free steps around it, which is how a
##                            grinding arc outscored a wide one, Fase9 2026-09-29)
##         - w_faixa_piloto * lane_deviation  (right-hand rule, local)
##         - w_roteiro      * |heading error vs the route tangent|
##         - w_suavidade    * |steer - last steer| (anti-chatter)
## The best arc wins; `comando` is the same `DriveCommand` the whole stack
## already speaks, so nothing downstream changes.
##
## MODEL/EFFECTOR PARITY (measured, Fase9 2026-09-29): the rollout used the
## BARE wheelbase (60 px) while the vehicle turns with `entre_eixos *
## escala_media` (84 px at scale 1.4) and clamps the steering command to
## `max_estercamento` (0.9). The arcs therefore curved ~40% tighter than the
## car could ever follow — every straightish arc was a phantom, the chase
## oscillated around the route and the measured cte was 33.6 px against the
## legacy 18.0. The window now rolls with the car's real numbers: steer is
## clamped to the actuator's limit and the turn rate uses the scaled
## wheelbase (`_curva_por_esterc`). The speeds are also capped by what the
## route's OWN curvature allows (`_limite_vel_rota`), so a corner arc is not
## "scored slow" but is never even proposed fast.

const LocalMapRef = preload("res://src/farol/LocalMap.gd")

## Hard veto: a cost above this is not "expensive", it is not allowed.
const VETO := 0.9
## Hull sampling: the footprint is probed at the centre and at 4 points on the
## rectangle's perimeter, in the car's own frame.
const AMOSTRAS_CASCO := 5

var spec: FarolSpec = null
## The last evaluation, kept for the gates and the shadow report.
var melhor_steer: float = 0.0
var melhor_speed: float = 0.0
var melhor_score: float = -INF
var avaliacoes: int = 0
var chamadas: int = 0
var arcos_reprovados: int = 0


func _init(p_spec: FarolSpec = null) -> void:
	spec = p_spec if p_spec != null else FarolSpec.new()


## Rolls the window and returns the winning (steer, throttle) pair.
##
## pos/rot     : the car's pose in the world.
## vel_max     : the speed the route profile asked for (the window is a
##                FRACTION of it, never above).
## meia_eixos  : the hull's half extents, already scaled (px).
## entre_eixos : the wheelbase, for the bicycle model.
## rota_dir    : the unit tangent of the route at the car (the right-hand rule
##                and the route-alignment term both need it).
## max_steer_amostrado : the ACTUATOR's steering limit (normalised, 0..1). The
##                window samples inside it, so a proposed arc is always one the
##                chassis could actually hold.
## velocidade_atuador : the actuator's speed scale (px/s). The returned
##                throttle is a fraction of THIS (the adapter multiplies by
##                it), so the rollout must sample speeds in the same scale —
##                measuring arcs in the PROFILE's scale and letting the
##                actuator multiply by the cruise speed made every throttled
##                arc ~3x faster than the arc that was scored (measured:
##                the choke cap never reached the wheels, Fase9 2026-09-29).
func avaliar(local: LocalMapRef, pos: Vector2, rot: float, vel_max: float,
		meia_eixos: Vector2, entre_eixos: float, rota_dir: Vector2,
		steer_anterior: float, max_steer_amostrado: float = 1.0,
		velocidade_atuador: float = 0.0) -> Array:
	chamadas += 1
	avaliacoes = 0
	arcos_reprovados = 0
	melhor_score = -INF
	melhor_steer = 0.0
	melhor_speed = 0.0
	if local == null or vel_max <= 1.0:
		return [0.0, 0.0]
	var passos: int = maxi(2, int(round(spec.dwa_horizonte_s / maxf(0.02, spec.dwa_passo_s))))
	var dt: float = spec.dwa_horizonte_s / float(passos)
	var n_steer: int = maxi(3, spec.dwa_steer_steps)
	var vel_rel: float = clampf(vel_max, 20.0, 400.0)
	# Model/effector parity, TWO halves (both measured missing, Fase9):
	# 1. STEER — sampled inside the actuator's limit; the rollout's turn rate
	#    uses the SAME scaled wheelbase the mover does. Route-CURVE slowdown is
	#    NOT re-derived here: `vel_max` already carries it via
	#    FsmProfiles.route_speed — capping twice would crawl the straights.
# 2. SPEED — fractions of the ACTUATOR's scale (the adapter multiplies the
#    returned throttle by it), with the profile speed as a SOFT ceiling
#    charged per px/s of excess inside `_rolar`. Filtering the fractions by
#    the instantaneous profile instead froze the window on its floor fraction
#    whenever the profile dipped for one tick (measured: 40 px/s cruise
#    through wide corridors, Fase2 2026-09-29).
	var v_atuador: float = clampf(maxf(velocidade_atuador, vel_max), 20.0, 400.0)
	var steer_limite: float = clampf(max_steer_amostrado, 0.05, 1.0)
	# `steer_anterior` arrives NORMALISED (the Pilot's held command); the rollout
	# runs in actuator units, so convert once and keep every term consistent.
	var anterior_abs: float = clampf(steer_anterior, -1.0, 1.0) * steer_limite
	for si in range(n_steer):
		# symmetric window, -1..+1, INSIDE the actuator's own limit (positive =
		# right). Sampled steer = commanded steer = executed steer.
		var steer: float = steer_limite * (-1.0 + 2.0 * float(si) / float(n_steer - 1))
		for vf: float in spec.dwa_velocidades:
			var v: float = v_atuador * vf
			var score: float = _rolar(local, pos, rot, steer, v, passos, dt,
				meia_eixos, entre_eixos, rota_dir, anterior_abs, vel_max)
			avaliacoes += 1
			if score > melhor_score:
				melhor_score = score
				melhor_steer = steer
				melhor_speed = v
	# The INTERNAL rollout runs in the actuator's units (tan of the absolute
	# steering, like the mover); the RETURN is the normalised DriveCommand the
	# whole stack speaks (`to_legacy_targets` multiplies by max_steer again).
	var saida_steer: float = melhor_steer / maxf(steer_limite, 0.05)
	# Nothing survived: creep forward rather than freeze (the alternative is a
	# car that stops forever in a spot where even a 0.15 arc is "expensive").
	if melhor_score == -INF:
		arcos_reprovados += 1
		return [saida_steer, 0.15]
	return [saida_steer, clampf(melhor_speed / maxf(v_atuador, 1.0), 0.0, 1.0)]


## One arc. Returns the score, or -INF when the hull enters a forbidden cell.
func _rolar(local: LocalMapRef, pos: Vector2, rot: float, steer: float, v: float,
		passos: int, dt: float, meia_eixos: Vector2, entre_eixos: float,
		rota_dir: Vector2, steer_anterior: float, vel_perfil: float) -> float:
	var score: float = 0.0
	var x: float = pos.x
	var y: float = pos.y
	var r: float = rot
	var colisao := 0.0
	# The WORST cell cost of the whole rollout, not a sum: a wall touch must
	# cost the arc, not 1/12th of it.
	var pior_custo := 0.0
	var ultimo_x := x
	var ultimo_y := y
	for k in range(passos):
		# bicycle model, same integrator the vehicle uses
		r += v / maxf(entre_eixos, 1.0) * tan(steer) * dt
		x += cos(r) * v * dt
		y += sin(r) * v * dt
		# the hull, not the centre: 5 probes in the car's own frame. The
		# rollout only STOPS early on a hard veto; the near-wall cost still
		# accumulates to the end, so a grazing arc pays for every step it
		# spends against the kerb instead of just the first one.
		var pior_do_passo := 0.0
		for m in range(AMOSTRAS_CASCO):
			var off: Vector2 = _amostra_casco(m, meia_eixos)
			var c: float = local.custo_em(Vector2(x, y) + off.rotated(r))
			if c >= VETO:
				colisao = 1.0
			elif c > pior_do_passo:
				pior_do_passo = c
		pior_custo = maxf(pior_custo, pior_do_passo)
		if colisao > 0.0:
			break
	# progress along the route: the dominant term, in px. Measured from the
	# START pose (the pre-loop x/y kept tracking the last integrated step, so
	# the displacement was zero and the only thing separating arcs was their
	# penalty terms — that is what made the window pick weird headings).
	var progresso: float = (Vector2(x, y) - pos).dot(rota_dir)
	if colisao > 0.0:
		arcos_reprovados += 1
		return -INF
	# clearance cost: the WORST cell the hull visited, 0 in the open, 1 at the
	# swept radius. The mean made a 12-step rollout with one wall touch look
	# cheaper than a clean arc through the middle of the lane.
	var folga := minf(1.0, pior_custo)
	# right-hand rule, local: is the hull drifting to the LEFT of the route?
	var direita: Vector2 = rota_dir.rotated(PI * 0.5)
	var desvio: float = (Vector2(x, y) - pos).dot(direita)
	# route alignment: the angle between the hull and the route tangent
	var erro_rota: float = absf(angle_difference(r, rota_dir.angle()))
	score = spec.w_progresso * progresso
	score -= spec.w_colisao * colisao
	score -= spec.w_folga_piloto * folga
	score -= spec.w_faixa_piloto * clampf(desvio / maxf(meia_eixos.x * 4.0, 40.0), -1.5, 1.5)
	score -= spec.w_roteiro * erro_rota
	score -= spec.w_suavidade * absf(steer - steer_anterior)
	# Profile as a SOFT ceiling, not a filter (measured wrong both ways,
	# Fase9/Fase2 2026-09-29): REMOVING the fractions above the instantaneous
	# `vel_max` froze the window on the floor fraction whenever the profile
	# dipped for one tick (route curvature, approach), because the held throttle
	# then persisted at 0.25 * cruise through WIDE corridors. Charging the
	# excess instead lets the profile win exactly where it matters — a choke
	# costs the fast arc more than its progress is worth — while an open-road
	# dip costs it almost nothing. Charging `max(0, v - vel_max) * k`: k=1.5
	# makes a 111 px/s excess (full speed over a 49 px/s choke) outweigh the
	# ~86 px of progress the fast arc could bank, and a 24 px/s excess (full
	# speed over a 136 px/s open-road cap) stay cheap.
	score -= spec.w_excesso_vel * maxf(0.0, v - vel_perfil)
	# A zero-speed arc must not win on `progresso` alone; it pays for standing
	# still, which is what produced the standstill loops in gate_seeds.
	score -= v * 0.02
	return score


## 5 points of the hull: the centre, the two ends of the long axis and the two
## ends of the short axis. Enough to catch a corner against a kerb, cheap
## enough to run 27 x 12 times per call.
func _amostra_casco(i: int, e: Vector2) -> Vector2:
	match i:
		0: return Vector2.ZERO
		1: return Vector2(e.x, 0.0)
		2: return Vector2(-e.x, 0.0)
		3: return Vector2(0.0, e.y)
		_: return Vector2(0.0, -e.y)
