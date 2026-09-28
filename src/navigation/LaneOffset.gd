class_name LaneOffset
extends RefCounted
## Shifts a planned path to the RIGHT of its direction of travel — the
## right-hand traffic rule (Brazil, most of the world). A* alone minimizes
## distance, so it happily takes the LEFT half of an aisle when that is
## shorter; this makes the vehicle keep to its own side.
##
## Pure geometry: the caller supplies the clearance probe, so this stays
## testable without a scene tree (see ModulesCheck: Lane.* checks).

## Near-reversal (rad) at a vertex: below it the offset stays full, above it the
## offset is cancelled over another REVERSAL_FADE radians. A decimated A* route
## keeps almost ONLY vertices (every point is a 30-90 deg bend), so cancelling
## ordinary corners would disable the whole rule — and a corner that is shifted
## as a whole is still a valid, clearance-checked corner. Only hairpins (the
## parking manoeuvre, dead ends) must stay exactly on the planner's line.
const REVERSAL_MIN := 1.75
const REVERSAL_FADE := 0.45


## RIGHT-EDGE RULE (2026-09-26): the lane is the strip against the RIGHT WALL
## of the corridor, not the middle of its right half. The proportional bias
## (0.25) was tuned for a 700-1000 px aisle, where "half way into the right
## half" reads as "on the right". Fase2's aisle is 1470 px wide (6 car widths)
## and the bias left the car 620 px from the right guide — in the middle of the
## road: 0% of the samples landed inside the RuaDireita box the user drew
## (x 832..1206), median x = 385. So the shift is now `free_r - keep_clear`:
## as far right as the swept radius allows, which IS the definition of keeping
## to the right. `keep_clear` (the swept radius) is unchanged, so the safety
## invariant `free_r' >= keep_clear` still holds BY CONSTRUCTION.
const RIGHT_HALF_BIAS := 0.25  # kept for reference: the rule that failed

## Margin kept from the right wall ON TOP of the swept radius, as a fraction of
## it (self-scaling, no magic pixels). 0 = hard against the wall: with the
## floor reached the car pinned itself on the kerb and the stuck-recovery loop
## crept 1 px/s (Fase3 seed 2, 2026-09-26). Half the swept radius keeps the
## lane visibly against the right side AND leaves room to correct.
const LANE_EDGE_MARGIN := 0.5

## Espaco aberto = os DOIS lados sem parede a menos de N raios varridos. So
## um lado aberto ainda e' corredor (a parede oposta e' a guia da direita), e
## um limiar de um lado so tratava a guia da Fase2 (a 894 px) como inexistente
## e devolvia o carro para o meio da rua.
const LANE_OPEN_EDGE := 6.0

## Teto anti-fuga do deslocamento, em raios varridos.
const LANE_MAX_WIDTH := 6.0

## Pontos lidos para tras/frente ao definir a direcao da Perna (ver `apply`).
const LANE_TANGENT_WINDOW := 2



## route: Array[Vector2] (at least 3 points to be worth offsetting).
## desired: maximum lateral offset in px.
## probe(p, right_dir) -> free distance from `p` toward `right_dir` (px,
## max_dist ok). DIRECTION-AWARE: the same callable is asked for the left
## clearance by passing `-right`, so one physics ray probe answers both sides.
## keep_clear: clearance the point must still have on the right AFTER the shift.
## fade_start_m: arc length (px) over which the offset ramps in from the
## vehicle's current position (avoids an instant jump at the first point).
## fade_end_m: arc length (px) over which it ramps back out to the route end,
## so the tail (the parking approach) stays exactly on the planner's line and
## the target spot is never dragged sideways.
##
## RULE: `shift = free_r - keep_clear` — the lane hugs the right wall, bounded
## by the swept radius, so `free_r' >= keep_clear` BY CONSTRUCTION. `desired` is
## only a MAXIMUM (the per-level `keep_right_shift`); it must be large enough not
## to bind in a wide aisle or the rule silently degrades to "barely moved right".
static func apply(route: Array, desired: float, probe: Callable, keep_clear: float,
		fade_start_m: float = 120.0, fade_end_m: float = 200.0) -> Array:
	var out: Array[Vector2] = []
	var n := route.size()
	if n < 3 or desired <= 0.0 or not probe.is_valid():
		for p in route:
			out.append(p)
		return out
	var arc: Array[float] = [0.0]
	for i in range(1, n):
		arc.append(arc[i - 1] + (route[i] as Vector2).distance_to(route[i - 1] as Vector2))
	var total: float = arc[n - 1]

	# Direction and clearance of EVERY point, then one shift each. Tried and
	# rejected on 2026-09-26: (a) a +/-2 windowed tangent and (b) limiting the
	# shift to the tightest point of the window both made the car MORE central
	# (x 491 -> 401, 512 px from the right guide), because the coarse RDP route
	# hides narrow pockets that then veto the shift for the whole leg.
	for i in range(n):
		# Tangente por janela: num trecho DIAGONAL da rota, a normal do proprio
		# ponto aponta para nordeste, e a faixa derivava para a esquerda em vez
		# de acompanhar a via (o carro comia a rua esquerda na curva, foto de
		# 2026-09-26). A janela da a direcao da Perna, nao do vertice.
		var right := tangent_windowed(route, i, LANE_TANGENT_WINDOW).rotated(PI * 0.5)
		var fr: float = float(probe.call(route[i], right))
		var fl: float = float(probe.call(route[i], -right))
		# A one-sided probe (0 = "no wall found in that direction", e.g. a stub
		# that only reports the blocked side) must not shrink the corridor to the
		# right side alone: assume the corridor is symmetric.
		if fl <= 0.0:
			fl = fr
		var largura: float = fr + fl
		# A corridor narrower than the keep-clear band cannot host the car at
		# all: in that case the right edge is unreadable and the old proportional
		# bias is the safer (smaller) shift.
		var shift: float = fr - keep_clear * (1.0 + LANE_EDGE_MARGIN)
		# Sem guia legivel a direita NAO e' "faixa colada na parede": e' espaco
		# aberto, e a sonda devolve o seu alcance maximo (2.8 km em Fase2). Com
		# aquilo virava shift de ~900 px e a rota saia do corredor — o carro
		# passava raspando na guia (x=1020 com a parede em 1039) e a curva
		# cortava a faixa esquerda (fotos de 2026-09-26). Uma faixa tem no maximo
		# ~2 raios varridos de largura; acima disso usamos a regra proporcional.
		var aberto := fr > keep_clear * LANE_OPEN_EDGE and largura - fr > keep_clear * LANE_OPEN_EDGE
		if aberto or largura < keep_clear * 2.0:
			shift = fr - largura * RIGHT_HALF_BIAS
		# Teto anti-fuga: nunca mais que N raios varridos (o corredor da Fase2
		# pede ~680 px = 5,4 raios, entao 6 nao morde).
		shift = minf(shift, keep_clear * LANE_MAX_WIDTH)
		shift = clampf(shift, 0.0, desired)
		shift *= _ramp(arc[i], fade_start_m) * _ramp(total - arc[i], fade_end_m)
		shift *= _turn_factor(route, i)
		out.append((route[i] as Vector2) + right * shift)
	return out


## Clearance probe backed by the physics world: free distance from `p` to the
## first obstacle (collision_mask, walls = 2) toward `right`. Returns `max_dist`
## when the side is open — the caller caps the shift with `desired` anyway.
## Direction-aware: pass `-right` to measure the OTHER side with the same ray.
static func wall_probe(space: PhysicsDirectSpaceState2D, mask: int = 2,
		max_dist: float = 600.0) -> Callable:
	if space == null:
		return Callable()
	return func(p: Vector2, right: Vector2) -> float:
		var q := PhysicsRayQueryParameters2D.create(p, p + right * max_dist)
		q.collision_mask = mask
		q.collide_with_bodies = true
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return max_dist
		return p.distance_to(hit["position"])


## Unit tangent at index i over a +/-w window: the DIRECTION OF THE LEG instead
## of the direction of the vertex. On a decimated route (RDP tol. 18 px) almost
## only vertices survive, so the 1-neighbour tangent swings ~90 deg from point
## to point and the offset lane follows the zigzag.
static func tangent_windowed(route: Array, i: int, w: int = 0) -> Vector2:
	var n := route.size()
	var a_i: int = maxi(i - w, 0)
	var b_i: int = mini(i + w, n - 1)
	if a_i == b_i:
		return tangent(route, i)
	var d: Vector2 = (route[b_i] as Vector2) - (route[a_i] as Vector2)
	if d.length_squared() < 0.0001:
		return tangent(route, i)
	return d.normalized()


## Unit tangent at index i (forward/backward difference at the ends).
static func tangent(route: Array, i: int) -> Vector2:
	var n := route.size()
	var a: Vector2 = route[maxi(i - 1, 0)]
	var b: Vector2 = route[mini(i + 1, n - 1)]
	var d := b - a
	if d.length_squared() < 0.0001:
		return Vector2.RIGHT
	return d.normalized()


## Smoothstep: exactly 0 at ramp distance 0, 1 from fade_m of arc length on.
## The flat start/end is what keeps the route anchored on the planner's line at
## both extremities (vehicle position and parking approach) — a linear ramp
## would jump `desired` over the first/last leg.
static func _ramp(distance: float, fade_m: float) -> float:
	if fade_m <= 0.0:
		return 1.0
	var t: float = clampf(distance / fade_m, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## 1 on an ordinary leg (including 90 deg corners), 0 at a near-reversal.
static func _turn_factor(route: Array, i: int) -> float:
	var n := route.size()
	if i <= 0 or i >= n - 1:
		return 1.0
	var in_dir: Vector2 = (route[i] as Vector2) - (route[i - 1] as Vector2)
	var out_dir: Vector2 = (route[i + 1] as Vector2) - (route[i] as Vector2)
	if in_dir.length_squared() < 0.0001 or out_dir.length_squared() < 0.0001:
		return 1.0
	var turn: float = absf(angle_difference(in_dir.angle(), out_dir.angle()))
	return 1.0 - clampf((turn - REVERSAL_MIN) / REVERSAL_FADE, 0.0, 1.0)


