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
##         - w_folga_piloto * (1 - clearance) (0 in the open)
##         - w_faixa_piloto * lane_deviation  (right-hand rule, local)
##         - w_roteiro      * |heading error vs the route tangent|
##         - w_suavidade    * |steer - last steer| (anti-chatter)
## The best arc wins; `comando` is the same `DriveCommand` the whole stack
## already speaks, so nothing downstream changes.

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
func avaliar(local: LocalMapRef, pos: Vector2, rot: float, vel_max: float,
		meia_eixos: Vector2, entre_eixos: float, rota_dir: Vector2,
		steer_anterior: float) -> Array:
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
	for si in range(n_steer):
		# symmetric window, -1 .. +1 (positive = right)
		var steer: float = -1.0 + 2.0 * float(si) / float(n_steer - 1)
		for vf: float in spec.dwa_velocidades:
			var v: float = vel_rel * vf
			var score: float = _rolar(local, pos, rot, steer, v, passos, dt,
				meia_eixos, entre_eixos, rota_dir, steer_anterior)
			avaliacoes += 1
			if score > melhor_score:
				melhor_score = score
				melhor_steer = steer
				melhor_speed = v
	# Nothing survived: creep forward rather than freeze (the alternative is a
	# car that stops forever in a spot where even a 0.15 arc is "expensive").
	if melhor_score == -INF:
		arcos_reprovados += 1
		return [0.0, 0.15]
	return [melhor_steer, clampf(melhor_speed / maxf(vel_max, 1.0), 0.0, 1.0)]


## One arc. Returns the score, or -INF when the hull enters a forbidden cell.
func _rolar(local: LocalMapRef, pos: Vector2, rot: float, steer: float, v: float,
		passos: int, dt: float, meia_eixos: Vector2, entre_eixos: float,
		rota_dir: Vector2, steer_anterior: float) -> float:
	var score: float = 0.0
	var x: float = pos.x
	var y: float = pos.y
	var r: float = rot
	var colisao := 0.0
	var soma_folga := 0.0
	var ultimo_x := x
	var ultimo_y := y
	for k in range(passos):
		# bicycle model, same integrator the vehicle uses
		r += v / maxf(entre_eixos, 1.0) * tan(steer) * dt
		x += cos(r) * v * dt
		y += sin(r) * v * dt
		# the hull, not the centre: 5 probes in the car's own frame
		for m in range(AMOSTRAS_CASCO):
			var off: Vector2 = _amostra_casco(m, meia_eixos)
			var c: float = local.custo_em(Vector2(x, y) + off.rotated(r))
			if c >= VETO:
				colisao = 1.0
			elif c > soma_folga:
				soma_folga = c
		if colisao > 0.0:
			break
	# progress along the route: the dominant term, in px
	var progresso: float = Vector2(x - ultimo_x, y - ultimo_y).dot(rota_dir)
	ultimo_x = x
	ultimo_y = y
	if colisao > 0.0:
		arcos_reprovados += 1
		return -INF
	var folga_media: float = soma_folga / float(passos)
	# right-hand rule, local: is the hull drifting to the LEFT of the route?
	var direita: Vector2 = rota_dir.rotated(PI * 0.5)
	var desvio: float = (Vector2(x, y) - pos).dot(direita)
	# route alignment: the angle between the hull and the route tangent
	var erro_rota: float = absf(angle_difference(r, rota_dir.angle()))
	score = spec.w_progresso * progresso
	score -= spec.w_colisao * colisao
	score -= spec.w_folga_piloto * folga_media
	score -= spec.w_faixa_piloto * clampf(desvio / maxf(meia_eixos.x * 4.0, 40.0), -1.5, 1.5)
	score -= spec.w_roteiro * erro_rota
	score -= spec.w_suavidade * absf(steer - steer_anterior)
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
