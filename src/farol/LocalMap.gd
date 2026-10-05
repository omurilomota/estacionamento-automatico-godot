class_name LocalMap
extends RefCounted
## FAROL · PILOTO (1/3) — the ego-centric costmap that does not exist today.
##
## The diagnosis of the plan is exact: with a brain driving, the car had NO
## reaction to an obstacle at all. `AutonomousDriver` is pure-pursuit over a
## STATIC A* route, and the only obstacle responses in the whole stack were a
## speed ceiling (`FsmProfiles.sensor_speed`) and Locomotion's throttle cut.
## So the car pushed into things and the only answer was the escape ladder
## (AGENTS #43).
##
## The LocalMap is what "seeing the room around the car" means. It is:
##   - EGO-CENTRIC: `2*half + 1` cells a side, `cell` px each, re-anchored on
##     the car every rebuild, so it is resolution-independent and always about
##     the next 1220 px.
##   - SENSOR-FED: the 11 existing rays + 8 diagonals (`SensorArray`), because
##     the original 11 are all along the car's axes and the hull's CORNERS are
##     what actually hit a kerb (measured, AGENTS #18: the front rays stay INF
##     while the car grinds along a wall).
##   - DECAYING: an obstacle that was seen keeps its mark for
##     `rebuild_s` and then fades. Obstacles in this game are static, so the
##     decay exists for the things that are not (and it bounds the damage when
##     a ray glitch paints a phantom wall).
##
## MEMORY DISCIPLINE (the plan's "coherent decay rates" rule): the Chart's
## memory is wall-clock and lives for `memoria_ttl_s` (30 s) because a dead end
## must be remembered for a whole approach; the LocalMap decays in half a
## second because it answers "what is in front of me NOW". Mixing the two TTLs
## is the easy mistake, so they are two different objects with two different
## clocks.
##
## The map stores a COST, not a bit: `custo` is 0 for free room and grows as
## the cell approaches an obstacle, so the DWA can prefer a wide gap over a
## narrow one instead of only avoiding the immediate collision.

const LocalMapRef = preload("res://src/farol/LocalMap.gd")

const LIVRE := 0.0
const OBSTACULO := 1.0e6

var spec: FarolSpec = null
var meio: int = 30
var cell: float = 20.0
var dim: int = 61
## Cost per cell, row-major over the ego window.
var custo: PackedFloat32Array = PackedFloat32Array()
## Where the window is anchored (world position of the cell (0,0)).
var ancora: Vector2 = Vector2.ZERO
## Generation counters for the decay (a cell's cost halves per generation).
var _idade: PackedByteArray = PackedByteArray()
var _geracao: int = 0
## The Chart handed to `misturar_carta`, kept for the body-integral probe.
var _carta_cache: Chart = null
## Diagnostics.
var celulas_ocupadas: int = 0
var reconstrucoes: int = 0
var raios_usados: int = 0
## Body-integral STATIC-clearance stats over the hull, refreshed by `atualizar`:
## how much room the Chart (the static truth) gives under the hull footprint,
## averaged over the disc, and the px of the WORST hull point inside a choke.
## `folga_media_corpo` is -1.0 until the first refresh.
var folga_media_corpo: float = -1.0
var folga_pior_px: float = INF


func _init(p_spec: FarolSpec = null) -> void:
	spec = p_spec if p_spec != null else FarolSpec.new()
	_configurar()


func _configurar() -> void:
	meio = maxi(4, spec.local_half)
	cell = maxf(4.0, spec.local_cell)
	dim = 2 * meio + 1
	custo = PackedFloat32Array()
	custo.resize(dim * dim)
	_idade = PackedByteArray()
	_idade.resize(dim * dim)


func reconfigurar() -> void:
	_configurar()


## A blank window of the given half-extent, anchored on the origin. The only
## sanctioned way to build one outside a vehicle (ModulesCheck, the shield's
## unit checks, and any future test) — poking `dim`/`custo` from outside is
## exactly the kind of coupling that makes a test lie.
static func de_teste(meio: int, cell: float) -> LocalMapRef:
	var m := LocalMapRef.new()
	m.spec = FarolSpec.new()
	m.meio = maxi(1, meio)
	m.cell = maxf(4.0, cell)
	m.dim = 2 * m.meio + 1
	m.custo = PackedFloat32Array()
	m.custo.resize(m.dim * m.dim)
	m._idade = PackedByteArray()
	m._idade.resize(m.dim * m.dim)
	m.ancora = Vector2(-m.meio, -m.meio) * m.cell
	return m


## Re-anchors the window on the car and re-seeds it from the rays. Called at
## `local_rebuild_s` (10 Hz is plenty for rays; the decay is what makes the
## gap between rebuilds safe).
func reconstruir(pos: Vector2, rays: Dictionary) -> void:
	_configurar()
	ancora = pos - Vector2(meio, meio) * cell
	reconstrucoes += 1
	_geracao += 1
	# Free the whole window, then re-paint the obstacles. A cell that is seen
	# again keeps its age (so the decay is about ABSENCE, not about rebuilds).
	custo.fill(LIVRE)
	_idade.fill(0)
	celulas_ocupadas = 0
	raios_usados = 0
	for nome: String in rays.keys():
		var r: RayCast2D = rays[nome] as RayCast2D
		# `is_instance_valid` is a GLOBAL function, not a method on the object.
		# Calling it as `r.is_instance_valid(r)` raised every frame, and the
		# `continue` below then skipped EVERY ray: the map was built from the
		# Chart alone with `raios_usados == 0` (measured on Fase9, 2026-09-29).
		if r == null or not is_instance_valid(r):
			continue
		var alvo: Vector2
		var d: float = INF
		var houve_impacto := false
		if r.is_colliding():
			var hit: Vector2 = r.get_collision_point()
			if not hit.is_finite():
				continue
			d = pos.distance_to(hit)
			alvo = hit
			houve_impacto = true
		else:
			alvo = pos + (r.target_position - r.position)
			d = alvo.distance_to(pos)
		raios_usados += 1
		_tracar_rastro(pos, d, r.global_rotation, houve_impacto)
	_preservar_idade()


## Decay: every cell that was NOT seen this generation ages by one step, and
## its cost is pushed towards what this generation says. Implemented as a
## single lerp so the map forgets smoothly instead of blinking.
func _preservar_idade() -> void:
	# The rebuild already rewrote `custo`; the age array is what survives it.
	for i in _idade.size():
		if _idade[i] < 250:
			_idade[i] += 1


## Paints the wedge a ray swept: free up to the hit, blocked at the hit, and a
## small shadow BEHIND it (an obstacle hides what is behind it, and forgetting
## that is how a car plans into the back of a truck).
##
## `houve_impacto` is the whole point, and its absence was the bug that froze
## the pilot on its first real boot (Fase9, 2026-09-29, measured): a ray that
## hits NOTHING still has a finite length — its own maximum range — and the
## first version painted the contact cell solid at that range. With 19 rays
## around the car, an empty aisle was ringed by 19 phantom walls, so the shield
## vetoed every frame (`custo` = OBSTACULO along the whole beam), the DWA saw a
## closed room and could only creep, and the car sat still for 41 s while the
## escape ladder burned 672 frames of reverse. A ray that saw nothing has seen
## nothing: it paints free to the end and marks nothing beyond.
func _tracar_rastro(origem: Vector2, distancia: float, angulo_raio: float,
		houve_impacto: bool) -> void:
	if distancia <= 0.0:
		return
	var dir := Vector2.RIGHT.rotated(angulo_raio)
	var passos: int = maxi(1, int(ceil(distancia / (cell * 0.5))))
	for k in range(passos):
		var p: Vector2 = origem + dir * (distancia * float(k) / float(passos))
		_marcar(p, LIVRE, 1.0)
	if not houve_impacto:
		return
	# the contact cell and a short shadow behind it
	_marcar(origem + dir * distancia, OBSTACULO, 1.0)
	for s in range(1, 3):
		_marcar(origem + dir * (distancia + s * cell), OBSTACULO, 0.6)


## Writes a cost at a world point and propagates a soft falloff to its
## neighbours, so the DWA sees a GRADIENT (it can then prefer the side with
## more room) instead of a binary cliff.
func _marcar(p: Vector2, valor: float, peso: float) -> void:
	var cx: int = int(floor((p.x - ancora.x) / cell))
	var cy: int = int(floor((p.y - ancora.y) / cell))
	if cx < 0 or cy < 0 or cx >= dim or cy >= dim:
		return
	var i := cy * dim + cx
	if valor > custo[i]:
		custo[i] = minf(OBSTACULO, maxf(custo[i], valor))
		_idade[i] = 0
	if valor == OBSTACULO:
		celulas_ocupadas += 1
		# falloff: the cell itself is 1.0, the ring around it decays
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				if ox == 0 and oy == 0:
					continue
				var nx := cx + ox
				var ny := cy + oy
				if nx < 0 or ny < 0 or nx >= dim or ny >= dim:
					continue
				var j := ny * dim + nx
				var queda: float = 1.0 - 0.34 * (absf(ox) + absf(oy))
				if queda > custo[j]:
					custo[j] = maxf(custo[j], queda * peso)
					_idade[j] = 0


## Blends the STATIC truth (the Chart's clearance) into the same cost field, so
## the DWA rollouts are conservative even where a ray has not been cast yet —
## the 19 rays cover a fan, not a disc.
func misturar_carta(p_chart: Chart, raio_varrido: float) -> void:
	_carta_cache = p_chart
	if p_chart == null:
		return
	for cy in range(dim):
		for cx in range(dim):
			var p: Vector2 = ancora + Vector2(cx, cy) * cell
			var cl: float = p_chart.folga_em(p)
			if cl <= 0.0:
				custo[cy * dim + cx] = OBSTACULO
				continue
			# 0 well clear, 1 at the swept radius: a smooth, monotone penalty.
			var folga_norm: float = clampf(1.0 - (cl - raio_varrido) / maxf(raio_varrido, 1.0), 0.0, 1.0)
			if folga_norm > 0.0:
				var i := cy * dim + cx
				custo[i] = maxf(custo[i], folga_norm)


func custo_em(p: Vector2) -> float:
	return custo_em_celula(celula_local(p))


func celula_local(p: Vector2) -> Vector2i:
	return Vector2i(int(floor((p.x - ancora.x) / cell)), int(floor((p.y - ancora.y) / cell)))


func custo_em_celula(cel: Vector2i) -> float:
	if cel.x < 0 or cel.y < 0 or cel.x >= dim or cel.y >= dim:
		return OBSTACULO
	return custo[cel.y * dim + cel.x]


func ocupado(cel: Vector2i) -> bool:
	return custo_em_celula(cel) >= 0.999


## World point of a local cell centre.
func ponto(cel: Vector2i) -> Vector2:
	return ancora + (Vector2(cel) + Vector2(0.5, 0.5)) * cell


## Fills a local field from the world state: the rays' wedge, the Chart's
## clearance and the decay in one call (the Pilot's per-frame entry point).
func atualizar(pos: Vector2, rays: Dictionary, chart: Chart, raio_varrido: float,
		delta: float, folga_estatica: Callable = Callable()) -> void:
	reconstruir(pos, rays)
	misturar_carta(chart, raio_varrido)
	_aplicar_decaimento(delta)
	if folga_estatica.is_valid():
		folga_estatica.call(pos, 0.0)


## BODY-INTEGRAL static clearance (the missing half of the speed profile).
## Cost at a point is a 20 px CENTRE sample; the sweep through a 400 px gap
## reads clean even when the hull at scale 1.4 fits with ~8 px to spare, so a
## chart-only speed profile cruises into chokes at full speed, every fast arc
## dies on contact, the DWA creeps at ~8 px/s with a pinned wheel and the
## escape ladder burns reverse (Fase9 trace, 2026-09-29: 4 cycles, v=0.6->153
## ->4.1->re). The fix integrates the STATIC truth under the WHOLE footprint:
## the Chart's `folga` is real px of room (column + half cell, NEVER
## overstated), sampled on a ring + centre, normalised by the swept radius.
## Call AFTER `misturar_carta` (post-anchor, pre-decay) — reads only the Chart.
func folga_estatica_do_corpo(pos: Vector2, half_diag: float) -> void:
	var chart: Chart = _carta_cache
	if chart == null or half_diag <= 1.0:
		folga_media_corpo = -1.0
		return
	var raio: float = half_diag
	var pontos := 13
	var soma := 0.0
	var pior := INF
	for k in range(pontos):
		var p: Vector2 = pos
		if k > 0:
			var ang: float = TAU * float(k - 1) / float(pontos - 1)
			p = pos + Vector2.RIGHT.rotated(ang) * raio
		var f: float = chart.folga_em(p)
		var no_corpo: float = maxf(0.0, raio - f)
		soma += no_corpo
		pior = minf(pior, f)
	folga_media_corpo = soma / float(pontos) / maxf(raio, 1.0)
	folga_pior_px = pior


## Time-based decay: a cell nobody re-marked fades back to free, so a ray that
## saw a phantom wall (or an obstacle that moved) does not haunt the car.
func _aplicar_decaimento(delta: float) -> void:
	var meio_vida: float = maxf(0.05, spec.local_rebuild_s)
	var fator: float = clampf(delta / meio_vida, 0.0, 1.0)
	if fator <= 0.0:
		return
	# Cells written this generation (age 0) are exempt: the rays just said so.
	for i in custo.size():
		if _idade[i] == 0:
			continue
		custo[i] = maxf(LIVRE, custo[i] - custo[i] * fator * 0.5)


## BFS over the local field: the cheapest reachable cell, used by
## `blocked_ahead` to find a DETOUR instead of reversing. Returns a list of
## world points from the origin to the goal (empty when there is none).
func bfs(origem: Vector2, alvo: Vector2, raio_min: float) -> Array:
	var inicio := celula_local(origem)
	var fim := celula_local(alvo)
	if inicio.x < 0 or inicio.y < 0 or inicio.x >= dim or inicio.y >= dim:
		return []
	if fim.x < 0 or fim.y < 0 or fim.x >= dim or fim.y >= dim:
		return []
	var custo_alvo: float = custo_em_celula(fim)
	if custo_alvo > 0.6:
		return []
	var anterior := PackedInt32Array()
	anterior.resize(dim * dim)
	anterior.fill(-1)
	var inicio_i := inicio.y * dim + inicio.x
	var fila: Array = [inicio_i]
	anterior[inicio_i] = inicio_i
	var visitados := 0
	var limite: int = dim * dim
	while not fila.is_empty() and visitados < limite:
		var atual: int = fila.pop_front()
		visitados += 1
		if atual == fim.y * dim + fim.x:
			break
		var cx: int = atual % dim
		var cy: int = atual / dim
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx := cx + d.x
			var ny := cy + d.y
			if nx < 0 or ny < 0 or nx >= dim or ny >= dim:
				continue
			var ni := ny * dim + nx
			if anterior[ni] != -1:
				continue
			if custo[ni] > 0.999 and ni != fim.y * dim + fim.x:
				continue
			anterior[ni] = atual
			fila.append(ni)
	var fim_i := fim.y * dim + fim.x
	if anterior[fim_i] == -1:
		return []
	var caminho: Array = []
	var cur := fim_i
	while cur != inicio_i:
		caminho.append(ponto(Vector2i(cur % dim, cur / dim)))
		cur = anterior[cur]
		if caminho.size() > dim * dim:
			return []
	caminho.reverse()
	return caminho
