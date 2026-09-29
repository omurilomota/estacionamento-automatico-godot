class_name Route
extends RefCounted
## FAROL · ROTA — right-hand traffic as a COST, not a post-hoc shift.
##
## WHY THIS FILE EXISTS
## --------------------
## The legacy rule (`src/navigation/LaneOffset.gd`) shifts the A* polyline to
## the right AFTER the search, and AGENTS §18/#31/#34/#35 record four failed
## attempts at that: shifting the raw staircase puts every step against the
## kerb and the chord between steps cuts the wall corner; shifting and then
## rounding shortens the path ~17% and pulls it back to the middle; rounding
## first and shifting makes the lane ripple; and every one of them is a
## post-hoc patch that cannot see WHY a corridor is preferable.
##
## Here the lane is part of the search. `AStarGrid2D` takes a per-cell weight
## scale, so the three multipliers below are baked once per grid build and the
## search then finds the cheapest path through the corridor, not the shortest
## one. A cell the car must not enter becomes expensive; it does not become
## unreachable — the escape ladder (AGENTS #43) still owns "the plan is
## impossible", and this layer only makes the plan sensible before that.
##
## The three costs, all multiplied into `weight_scale`:
##   w_folga   = 1 + k / max(clearance - swept, eps)
##              The car prefers the middle of a corridor and refuses to queue
##              into a one-car gap (a Raid-Falcons/D* Lite clearance term).
##   w_faixa   = 1 + gain * clamp((fr - band) / band, 0, 1) on the right half,
##              plus `w_esquerda` extra when the cell is on the LEFT half, so
##              a wide aisle cannot settle in the middle again.
##   w_memoria = the Chart's "this is where the car got stuck" memory.
##
## `fr`/`fl` are read from the Chart's four axis ray-clearance fields, NOT
## from a physics ray per route point: same rule as `LaneOffset.apply`, no
## physics, and the numbers are the ones the planner already computed.
##
## Arrow hints are IGNORED (locked B5) — the lane is geometry, not floor paint.

const EIXO_E := 0
const EIXO_W := 1
const EIXO_N := 2
const EIXO_S := 3
## Right-hand bias when a side is OPEN (no wall within `lane_open_edge`
## swept radii). Mirrors `LaneOffset.RIGHT_HALF_BIAS`: without a readable
## right guide the "hug the wall" rule degenerates into a 900 px lunge
## (measured in Fase2, AGENTS #31).
const DIREITA_ABERTA := 0.25

var spec: FarolSpec = null
var chart: Chart = null
## Diagnostics for the gates: cells above a weight threshold, and the mean.
var custo_medio: float = 1.0
var custo_max: float = 1.0
var celulas_caro: int = 0


func _init(p_chart: Chart = null, p_spec: FarolSpec = null) -> void:
	chart = p_chart
	spec = p_spec if p_spec != null else FarolSpec.new()


## Bakes the cost into `grade` for a trip whose DESTINATION is `destino`.
##
## The reference direction is the direction of travel, which A* does not know
## per cell; the only globally available proxy is "towards the goal", and in a
## corridor that is the corridor. Cells are evaluated once per grid build and
## per destination class, so the cost of a level is paid at the first plan.
func aplicar_pesos(grade: AStarGrid2D, destino: Vector2, raio_varrido: float) -> void:
	custo_medio = 1.0
	custo_max = 1.0
	celulas_caro = 0
	if chart == null or spec == null or grade == null:
		return
	var nx: int = chart.n_cel_x()
	var ny: int = chart.n_cel_y()
	if nx <= 0 or ny <= 0:
		return
	var goal_cell: Vector2i = chart.celula_de(destino)
	var total := 0.0
	var cont := 0
	for y in range(ny):
		for x in range(nx):
			var cel := Vector2i(x, y)
			if grade.is_point_solid(cel):
				continue
			var c: float = custo_celula(cel, goal_cell, raio_varrido)
			if c <= 1.001:
				continue
			grade.set_point_weight_scale(cel, c)
			total += c
			cont += 1
			if c > custo_max:
				custo_max = c
			if c >= 2.0:
				celulas_caro += 1
	custo_medio = total / maxf(1.0, float(cont))


## The multiplier of one cell. Pure function of the Chart's fields, so
## `ModulesCheck` can assert the rule without a scene.
func custo_celula(cel: Vector2i, goal_cell: Vector2i, raio_varrido: float) -> float:
	var folga: float = chart.folga(cel)
	var w := 1.0
	# w_folga: prefer the roomy middle, punish a cell that barely fits.
	w += spec.w_folga / maxf(folga - raio_varrido, maxf(chart.resolucao * 0.5, 1.0))
	# w_faixa: the right-hand strip. `dir` is the direction of travel towards
	# the goal, quantised by `folga_dir` to the grid's axes; its orthogonal
	# is the driver's right (screen +y on an eastbound leg).
	var dir: Vector2 = Vector2(goal_cell - cel)
	if dir.length_squared() < 1.0:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var right: Vector2 = dir.rotated(PI * 0.5)
	var fr: float = chart.folga_dir(cel, right)
	var fl: float = chart.folga_dir(cel, -right)
	if fl <= 0.0:
		fl = fr   # one-sided field: read the corridor as symmetric
	var largura: float = fr + fl
	var band: float = raio_varrido * (1.0 + spec.lane_edge_margin)
	# "Open" is the LaneOffset rule, verbatim: with no readable guide on the
	# right, the lane is the proportional bias, not a wall hug.
	var aberto: bool = fr > raio_varrido * spec.lane_open_edge \
		and largura - fr > raio_varrido * spec.lane_open_edge
	var alvo: float
	if aberto or largura < raio_varrido * 2.0:
		alvo = maxf(0.0, fr - largura * DIREITA_ABERTA)
	else:
		alvo = minf(raio_varrido * spec.lane_max_largura, maxf(0.0, fr - band))
	if fr <= fl:
		# Right half: the further from the lane target, the more it costs.
		w += spec.w_faixa * clampf((alvo - fr) / maxf(alvo, 1.0), 0.0, 1.0)
	else:
		# Left half: always off-lane, and explicitly more expensive so a wide
		# aisle cannot settle in the middle.
		w += spec.w_faixa + spec.w_esquerda
	# w_memoria: the dead ends the car already paid for.
	w *= chart.peso_memoria(cel, spec)
	return maxf(1.0, w)


## SMOOTHING WITH PROOF (S2). Chaikin is kept (AGENTS #35: it is the only
## smoother that never creates a loop) and then a shortcut loop runs: it may
## only remove the vertex `P[i]` when the chord `P[i-1] -> P[i+1]` keeps
## `raio_varrido + shortcut_margem_px` of clearance for its WHOLE length.
##
## This is the guarantee the legacy pipeline lacked. Rounding a corner with
## `RouteShape.round_corners` is blind: it cuts the corner towards the inside
## and, near an obstacle, the car grinds (AGENTS #35: 42 frames of reverse).
## Here a shortcut that would touch a wall is simply not taken, so the route
## is continuous AND drivable — or it stays a staircase, which is merely
## ugly, never lethal.
static func atalho(rota: Array, chart: Chart, raio_varrido: float, spec: FarolSpec) -> Array:
	var atual: Array = rota.duplicate()
	if chart == null or spec == null or atual.size() < 3:
		return atual
	var margem: float = raio_varrido + spec.shortcut_margem_px
	for _passe in range(maxi(1, spec.shortcut_passes)):
		var mudou := false
		var i := 1
		while i < atual.size() - 1:
			var a: Vector2 = atual[i - 1]
			var b: Vector2 = atual[i]
			var c: Vector2 = atual[i + 1]
			# Never cut a hairpin into a loop: that is what turns a parking
			# manoeuvre into a full circle.
			var dentro: Vector2 = b - a
			var fora: Vector2 = c - b
			if dentro.length_squared() < 1.0 or fora.length_squared() < 1.0:
				i += 1
				continue
			if absf(angle_difference(dentro.angle(), fora.angle())) > 2.2:
				i += 1
				continue
			if a.distance_to(c) >= a.distance_to(b) + b.distance_to(c) - 1.0:
				i += 1
				continue
			if not chart.segmento_livre(a, c, margem):
				i += 1
				continue
			atual.remove_at(i)
			mudou = true
		if not mudou:
			break
	return atual


## True when EVERY point of the polyline keeps `margem` px of clearance. This
## is the promise the smoothing makes, checked by the vehicle after it runs
## and counted by `tools/gate_drive.gd`; it must stay at zero.
func vias_livreis(rota: Array, raio_varrido: float) -> bool:
	if chart == null or rota.size() < 2:
		return true
	var margem: float = raio_varrido + (spec.shortcut_margem_px if spec != null else 14.0)
	for i in range(rota.size() - 1):
		if not chart.segmento_livre(rota[i], rota[i + 1], margem):
			return false
	return true
