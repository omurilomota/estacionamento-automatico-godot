class_name Chart
extends RefCounted
## FAROL · CARTA — the occupancy map that finally knows HOW MUCH FITS.
##
## The legacy planner (`Planejador.construir()`) answered one bit per cell:
## "does a circle of radius `inflar` centred here touch a wall?" and paid one
## `intersect_shape` physics query PER CELL (59 920 queries on Fase2). Two
## things were lost by that: the SIZE of the passage (is it one car wide or
## four?) and the COST (a metre-wide gap and a ten-metre aisle are both
## "free"), so A* could not tell a dead end from a shortcut until the car was
## already in it.
##
## The Chart keeps the bit EXACTLY — same query, same circle, same mask — and
## ADDS a real clearance field in pixels, produced by a two-pass 5-7 chamfer
## distance transform seeded from the obstacle footprints.
## `tools/gate_chart.gd` proves the solid set is identical to the legacy loop
## on every level; the clearance field is what `Route` turns into cost and
## what `Pilot` uses to keep the hull off the walls.
##
## HOW THE BUILD IS CHEAPER WITHOUT CHANGING THE ANSWER
## -----------------------------------------------------
## 1. One `intersect_shape` with a box the size of the grid PLUS A HALO returns
##    every collider of layer 2. Each of their `CollisionShape2D`s is reduced to
##    a CONSERVATIVE world AABB (`Shape2D.get_rect()` corners transformed by the
##    node's global transform), which stamps the RAW occupancy with no physics
##    at all. The halo is `ceil(raio / resolucao) + 2` cells wide and it is NOT
##    optional: a cell on the border is struck by a circle of radius `raio`
##    that reaches OUTSIDE the grid, and a perimeter wall that lives outside
##    the grid still blocks it. Without the halo the Chart under-counted 844
##    solid cells on Fase2 and promised 430 px of room on top of the top wall.
##    (Measured 2026-09-29.)
## 2. A chamfer distance transform over the RAW field gives, for every cell,
##    the distance to the nearest obstacle in pixels.
## 3. Only cells whose distance is <= `raio + 1.5 cells` can possibly be hit
##    by the legacy circle, and only those get the EXACT query. Everything else
##    is provably free.
## 4. If a collider's shapes cannot be enumerated (a body built by script), the
##    pre-filter is disabled and the full per-cell scan runs, so the answer is
##    identical in every case — only the speed changes.
##
## LAYOUT: the LOGICAL grid is `nx` x `ny` cells anchored at `origem` (that is
## what `AStarGrid2D` speaks). Every continuous field (`_raw`, `_dist`,
## `_clear`, the four ray fields) is stored on an EXTENDED grid of
## `nx + 2*halo` by `ny + 2*halo`, offset by the halo, so the border cells see
## the obstacles outside the logical region. Solidity is reported only for the
## logical cells, because that is all `AStarGrid2D` asks about.

const CH_A := 5.0
const CH_B := 7.0
## Safety factor applied to every distance the chamfer produces. The 2-pass
## 5-7 chamfer can overstate a distance by ~2%; the Chart's clearance is used
## to decide whether the hull FITS, so it must never overstate.
const CHAMFER_SEGURANCA := 0.96

var origem: Vector2 = Vector2.ZERO
var tamanho: Vector2 = Vector2.ZERO
var resolucao: float = 15.0
var raio: float = 110.0

var _nx: int = 0
var _ny: int = 0
## Halo (cells) of the extended field, where the obstacles outside the logical
## grid are rasterised.
var _halo: int = 0
var _wx: int = 0
var _wy: int = 0
## 1 = solid (the legacy `inflar` circle touches a wall), 0 = free. LOGICAL.
var _solid: PackedByteArray = PackedByteArray()
## The extended field, size `_wx * _wy`.
var _raw: PackedByteArray = PackedByteArray()
## Distance in px from a cell centre to the nearest raw cell centre.
var _dist: PackedFloat32Array = PackedFloat32Array()
## Conservative distance in px from a cell to the nearest obstacle SURFACE
## (never overstates the room available).
var _clear: PackedFloat32Array = PackedFloat32Array()
## Four axis-aligned ray clearances (E, W, N, S) in px, to the raw footprint.
## These are the `fr`/`fl` of the right-hand rule WITHOUT physics.
var _dirs: Array[PackedFloat32Array] = []
## cell index (logical) -> {"hits": int, "expira": float}
var _memoria: Dictionary = {}
var _agora: float = 0.0
## Diagnostics for the gates and the shadow report.
var consultas_exatas: int = 0
var celulas_totais: int = 0
var celulas_livres: int = 0
var build_ms: float = 0.0
var prefilter_completo: bool = true


func configure(p_origem: Vector2, p_tamanho: Vector2, p_resolucao: float, p_raio: float) -> void:
	origem = p_origem
	tamanho = p_tamanho
	resolucao = maxf(1.0, p_resolucao)
	raio = p_raio
	_nx = maxi(1, int(ceil(tamanho.x / resolucao)))
	_ny = maxi(1, int(ceil(tamanho.y / resolucao)))
	_halo = int(ceil(raio / resolucao)) + 2
	_wx = _nx + 2 * _halo
	_wy = _ny + 2 * _halo


func n_cel_x() -> int:
	return _nx


func n_cel_y() -> int:
	return _ny


func celula_de(p: Vector2) -> Vector2i:
	var l: Vector2 = (p - origem) / resolucao
	return Vector2i(floori(l.x), floori(l.y))


func centro_de(cel: Vector2i) -> Vector2:
	return origem + (Vector2(cel) + Vector2(0.5, 0.5)) * resolucao


func dentro(cel: Vector2i) -> bool:
	return cel.x >= 0 and cel.y >= 0 and cel.x < _nx and cel.y < _ny


## Extended-field index. `cx`/`cy` may be negative (the halo).
func _widx(cx: int, cy: int) -> int:
	return (cy + _halo) * _wx + (cx + _halo)


func solido(cel: Vector2i) -> bool:
	if not dentro(cel):
		return true
	return _solid[cel.y * _nx + cel.x] != 0


## Clearance in px, or 0 outside the field. NEVER overstates the room.
func folga(cel: Vector2i) -> float:
	if not dentro(cel):
		return 0.0
	return _clear[_widx(cel.x, cel.y)]


func folga_em(p: Vector2) -> float:
	return folga(celula_de(p))


## Directional clearance (px) toward `dir` (world vector), quantised to the
## grid's four axes. This is the `fr`/`fl` pair of the right-hand rule, read
## from the field instead of from a physics ray per route point.
func folga_dir(cel: Vector2i, dir: Vector2) -> float:
	if not dentro(cel):
		return 0.0
	var d := dir
	if d.length_squared() < 0.0001:
		return _clear[_widx(cel.x, cel.y)]
	return _dirs[dominante_eixo(d)][_widx(cel.x, cel.y)]


## Index of `_dirs` that measures the clearance TOWARD `dir`.
##
## The four sweeps in `_varrer_direcoes` accumulate the distance to the solid
## cells at SMALLER coordinates, so the index is the INVERSE of the direction on
## x: `_dirs[0]` walks +x but reports the distance to -x, `_dirs[1]` the other
## way round. On y the sweep order already matches (+y is DOWN here, and
## `_dirs[2]` walks it).
##
## This mapping was wrong on x until 2026-10-01: it handed the caller the
## distance to the WRONG wall, so `Route.custo_celula` read the lane off the
## LEFT side of a northbound corridor. The cost then preferred the wrong side of
## the street, which is why promoting the lane-as-cost to Fase2 sent the car
## AWAY from the eastern street (0% inside the user's box, backlog §1.22).
static func dominante_eixo(dir: Vector2) -> int:
	if absf(dir.x) >= absf(dir.y):
		return 1 if dir.x >= 0.0 else 0
	return 2 if dir.y >= 0.0 else 3


## Is the whole segment `a`->`b` drivable, i.e. does every sampled point keep
## `margem` px of clearance? The PROOF that lets `Route` smooth a path without
## cutting a corner into a wall (AGENTS #35 measured what happens when it does:
## 42 frames of reverse).
func segmento_livre(a: Vector2, b: Vector2, margem: float) -> bool:
	var d: float = a.distance_to(b)
	var passos: int = maxi(1, int(ceil(d / maxf(resolucao * 0.5, 1.0))))
	for k in range(passos + 1):
		var p: Vector2 = a.lerp(b, float(k) / float(passos))
		if folga_em(p) < margem:
			return false
	return true


# --- BUILD ---------------------------------------------------------------

## Rebuilds the whole field. `espaco` is the physics space (mask 2 = walls and
## obstacles, exactly what the legacy query used).
func rebuild(espaco: PhysicsDirectSpaceState2D) -> void:
	var t0 := Time.get_ticks_msec()
	consultas_exatas = 0
	# The fields must exist BEFORE the pre-filter stamps them.
	_criar_campos()
	prefilter_completo = _prefilter(espaco)
	if prefilter_completo:
		_celulas_solidas(espaco)
	else:
		_celulas_solidas_direto(espaco)
	_limpar_memoria_expirada()
	build_ms = float(Time.get_ticks_msec() - t0)
	celulas_totais = _nx * _ny
	celulas_livres = 0
	for v in _solid:
		if v == 0:
			celulas_livres += 1


func _criar_campos() -> void:
	var n: int = _nx * _ny
	var w: int = _wx * _wy
	_solid = PackedByteArray()
	_solid.resize(n)
	_raw = PackedByteArray()
	_raw.resize(w)
	_dist = PackedFloat32Array()
	_dist.resize(w)
	_clear = PackedFloat32Array()
	_clear.resize(w)
	_dirs = []
	for _i in range(4):
		var f := PackedFloat32Array()
		f.resize(w)
		_dirs.append(f)


## One physics query for the whole world (grid + halo), then per-shape AABBs.
## Returns false when the pre-filter cannot be trusted, in which case the
## caller falls back to the full per-cell scan.
func _prefilter(espaco: PhysicsDirectSpaceState2D) -> bool:
	if espaco == null:
		return false
	var meia := Vector2(resolucao, resolucao) * 0.5
	var cob_min: Vector2 = origem - Vector2(_halo, _halo) * resolucao - meia
	var cob_size: Vector2 = Vector2(_wx, _wy) * resolucao
	var forma := RectangleShape2D.new()
	forma.size = cob_size
	var q := PhysicsShapeQueryParameters2D.new()
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.shape = forma
	q.transform = Transform2D(0, cob_min + cob_size * 0.5)
	var acertos: Array = espaco.intersect_shape(q, 512)
	if acertos.is_empty():
		return true
	for hit in acertos:
		var col: Object = hit.get("collider")
		if col == null or not (col is Node):
			return false
		var formas := _formas_do_no(col as Node)
		if formas.is_empty():
			# A body with no enumerable shapes: refuse the shortcut rather than
			# silently plan around something invisible.
			return false
		for cs: CollisionShape2D in formas:
			if cs.shape == null:
				return false
			carimbar_aabb(_aabb_mundo(cs))
	_transformada_distancia()
	return true


## Every CollisionShape2D under a collider (the walk is generic; one level of
## nesting is what every obstacle in this repo uses).
func _formas_do_no(no: Node) -> Array:
	var out: Array = []
	var pilha: Array = [no]
	while not pilha.is_empty():
		var n: Node = pilha.pop_back()
		if n is CollisionShape2D:
			out.append(n)
			continue
		for c in n.get_children():
			pilha.append(c)
	return out


## Conservative world AABB of a shape: the four corners of the shape's local
## bounding rect under the node's global transform. Exact for rectangles,
## slightly generous for circles and capsules — and generous is SAFE, because
## the exact physics query is still the arbiter of "solid".
func _aabb_mundo(cs: CollisionShape2D) -> Rect2:
	var r: Rect2 = cs.shape.get_rect()
	var t: Transform2D = cs.global_transform
	var cantos: Array[Vector2] = [
		t * r.position,
		t * (r.position + Vector2(r.size.x, 0.0)),
		t * (r.position + r.size),
		t * (r.position + Vector2(0.0, r.size.y)),
	]
	var p: Vector2 = cantos[0]
	var fim: Vector2 = cantos[0]
	for i in range(1, 4):
		p.x = minf(p.x, cantos[i].x)
		p.y = minf(p.y, cantos[i].y)
		fim.x = maxf(fim.x, cantos[i].x)
		fim.y = maxf(fim.y, cantos[i].y)
	return Rect2(p, fim - p)


## Marks every cell the AABB OVERLAPS as raw obstacle.
##
## "Overlaps", not "contains the cell's centre": a 10 px wall is thinner than a
## 15 px cell, so centre-only stamping made the wall invisible to the distance
## transform. Stamping the whole overlap is conservative in the safe direction.
func carimbar_aabb(aabb: Rect2) -> void:
	var meia := Vector2(resolucao, resolucao) * 0.5
	var c0: Vector2i = celula_de(aabb.position - meia)
	var c1: Vector2i = celula_de(aabb.position + aabb.size + meia)
	for cy in range(maxi(-_halo, c0.y), mini(_ny + _halo, c1.y + 1)):
		for cx in range(maxi(-_halo, c0.x), mini(_nx + _halo, c1.x + 1)):
			_raw[_widx(cx, cy)] = 1


## Two-pass 5-7 chamfer over `_raw`, in pixels. In a 3x3 mask the CARDINAL
## neighbours (N/S/E/W) get weight 5 and the DIAGONALS get 7; the 11 (knight)
## needs a third pass and buys nothing at a 15 px cell. Weights are scaled so
## the result is Euclidean pixels: cardinal = 1.0 cell, diagonal = 7/5 = 1.4.
##
## The weights being swapped is a silent, catastrophic bug: with 7 on the
## cardinals the transform overstates every distance by 40%, the Chart then
## promised 178 px of room where there were 124, and `tools/gate_chart.gd`
## reported 284 of 599 sampled free cells as lying — the gate's independent
## physics check is what caught it.
func _transformada_distancia() -> void:
	var res := resolucao
	var a := res                          # 5/5  cardeal
	var b := res * (CH_B / CH_A)          # 7/5  diagonal
	var d := _dist
	var big := 1.0e12
	for i in d.size():
		d[i] = 0.0 if _raw[i] != 0 else big
	# Forward: W (5), NW (7), N (5), NE (7).
	for y in range(_wy):
		var row := y * _wx
		for x in range(_wx):
			var i := row + x
			if _raw[i] != 0:
				continue
			var best: float = d[i]
			if x > 0:
				best = minf(best, d[i - 1] + a)
			if y > 0:
				best = minf(best, d[i - _wx] + a)
				if x > 0:
					best = minf(best, d[i - _wx - 1] + b)
				if x + 1 < _wx:
					best = minf(best, d[i - _wx + 1] + b)
			d[i] = best
	# Backward: E (5), SE (7), S (5), SW (7).
	for y in range(_wy - 1, -1, -1):
		var row2 := y * _wx
		for x in range(_wx - 1, -1, -1):
			var i2 := row2 + x
			if _raw[i2] != 0:
				continue
			var best2: float = d[i2]
			if x + 1 < _wx:
				best2 = minf(best2, d[i2 + 1] + a)
			if y + 1 < _wy:
				best2 = minf(best2, d[i2 + _wx] + a)
				if x > 0:
					best2 = minf(best2, d[i2 + _wx - 1] + b)
				if x + 1 < _wx:
					best2 = minf(best2, d[i2 + _wx + 1] + b)
			d[i2] = best2
	# Surface clearance, and the contract the whole layer rests on: **this never
	# overstates the room available.** Two errors are taken off the table:
	#   1. `CHAMFER_SEGURANCA` — a 2-pass 5-7 chamfer can overstate a distance
	#      by ~2%, which at 700 px is 14 px, and 14 px of false promise is
	#      exactly the "the wall was there and the Chart said it was not" bug;
	#   2. one and a half cells — the nearest raw cell's CENTRE can sit up to
	#      half a diagonal inside the obstacle AABB, so the centre-to-centre
	#      distance understates nothing and the cell quantisation must be
	#      discounted a full cell.
	# Measured on Fase2: with half a cell only, 3 of 566 sampled free cells
	# promised 2 px more room than the physics world had.
	var desconta: float = res * 1.5
	for i in d.size():
		_clear[i] = 0.0 if _raw[i] != 0 else maxf(0.0, d[i] * CHAMFER_SEGURANCA - desconta)
	_varrer_direcoes()


## Four axis-aligned ray clearances (E/W/N/S) to the raw footprint. This is
## the `fr`/`fl` of the right-hand rule, read from the field instead of from
## one physics ray per route point.
func _varrer_direcoes() -> void:
	var res := resolucao
	var big := 1.0e9
	var fe := _dirs[0]
	var fw := _dirs[1]
	var fn := _dirs[2]
	var fs := _dirs[3]
	for y in range(_wy):
		var row := y * _wx
		var last: float = big
		for x in range(_wx):
			var i := row + x
			last = 0.0 if _raw[i] != 0 else last + res
			fe[i] = last
		last = big
		for x2 in range(_wx - 1, -1, -1):
			var i2 := row + x2
			last = 0.0 if _raw[i2] != 0 else last + res
			fw[i2] = last
	for x3 in range(_wx):
		var last2: float = big
		for y2 in range(_wy - 1, -1, -1):
			var i3 := y2 * _wx + x3
			last2 = 0.0 if _raw[i3] != 0 else last2 + res
			fn[i3] = last2
		last2 = big
		for y3 in range(_wy):
			var i4 := y3 * _wx + x3
			last2 = 0.0 if _raw[i4] != 0 else last2 + res
			fs[i4] = last2


## The exact pass: the SAME `intersect_shape` the legacy planner ran, asked
## only where the distance transform says a hit is possible.
func _celulas_solidas(espaco: PhysicsDirectSpaceState2D) -> void:
	var forma := CircleShape2D.new()
	forma.radius = raio
	var q := PhysicsShapeQueryParameters2D.new()
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.shape = forma
	var limite: float = raio + resolucao * 1.5
	_solid.fill(0)
	for cy in range(_ny):
		for cx in range(_nx):
			var i := cy * _nx + cx
			var w := _widx(cx, cy)
			# Cells far from every obstacle are provably free: the circle of
			# radius `raio` cannot reach a footprint whose cell centres are all
			# further away than `raio + 1.5 cells`.
			if _raw[w] == 0 and _dist[w] > limite:
				continue
			q.transform = Transform2D(0, centro_de(Vector2i(cx, cy)))
			consultas_exatas += 1
			if not espaco.intersect_shape(q, 1).is_empty():
				_solid[i] = 1


## Full scan, used when the pre-filter cannot be trusted. Byte-for-byte the
## legacy loop.
func _celulas_solidas_direto(espaco: PhysicsDirectSpaceState2D) -> void:
	var forma := CircleShape2D.new()
	forma.radius = raio
	var q := PhysicsShapeQueryParameters2D.new()
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.shape = forma
	_solid.fill(0)
	for cy in range(_ny):
		for cx in range(_nx):
			q.transform = Transform2D(0, centro_de(Vector2i(cx, cy)))
			consultas_exatas += 1
			if not espaco.intersect_shape(q, 1).is_empty():
				_solid[cy * _nx + cx] = 1


## The solid set as Vector2i cells (the equivalence gate's contract).
func celulas_solidas() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cy in range(_ny):
		for cx in range(_nx):
			if _solid[cy * _nx + cx] != 0:
				out.append(Vector2i(cx, cy))
	return out


## Nearest free LOGICAL cell to `cel`. Targets land on solid cells all the time
## (a bay edge, a preparation point) and AStarGrid2D errors on a point outside
## `region` and on a solid one (AGENTS #28), so this clamp is load-bearing.
func celula_livre_proxima(cel: Vector2i) -> Vector2i:
	var c := Vector2i(clampi(cel.x, 0, _nx - 1), clampi(cel.y, 0, _ny - 1))
	if _solid[c.y * _nx + c.x] == 0:
		return c
	for raio_c in range(1, maxi(_nx, _ny)):
		for cy in range(c.y - raio_c, c.y + raio_c + 1):
			if cy < 0 or cy >= _ny:
				continue
			for cx in range(c.x - raio_c, c.x + raio_c + 1):
				if cx < 0 or cx >= _nx:
					continue
				if _solid[cy * _nx + cx] == 0:
					return Vector2i(cx, cy)
	return c


# --- MEMORY ---------------------------------------------------------------

## The only history the vehicle keeps. "This cell beat me" is remembered for
## `spec.memoria_ttl_s` and turned into route cost, which is what stops the car
## from driving into the same dead end twice (the legacy answer was the 4-rung
## escape ladder of AGENTS #43 and three replans).
func marcar_travou(p: Vector2, agora: float) -> void:
	if _memoria.size() >= 4096:
		_limpar_memoria_expirada()
	var cel := celula_de(p)
	if not dentro(cel):
		return
	var i := cel.y * _nx + cel.x
	var reg: Dictionary = _memoria.get(i, {})
	var hits: int = int(reg.get("hits", 0)) + 1
	_memoria[i] = {"hits": mini(hits, 64), "expira": agora}


## Multiplier applied to a remembered cell's route cost (1.0 = free).
func peso_memoria(cel: Vector2i, spec: FarolSpec) -> float:
	if _memoria.is_empty() or not dentro(cel):
		return 1.0
	var reg: Dictionary = _memoria.get(cel.y * _nx + cel.x, {})
	if reg.is_empty():
		return 1.0
	var hits: int = int(reg.get("hits", 1))
	return 1.0 + spec.memoria_peso * clampf(
		float(hits) / float(maxi(1, spec.memoria_max_hits)), 0.0, 1.0)


## Removes the cells whose TTL ran out. The Chart memory decays ONLY here
## (wall-clock), never per frame: it has to survive a whole approach to a dead
## end, which the LocalMap's fast decay (half a second) deliberately does not.
func _limpar_memoria_expirada() -> void:
	if _memoria.is_empty():
		return
	var morreu: Array = []
	for k: int in _memoria:
		if _agora - float((_memoria[k] as Dictionary).get("expira", 0.0)) > 0.0:
			morreu.append(k)
	for k: int in morreu:
		_memoria.erase(k)


func definir_relogio(agora: float) -> void:
	_agora = agora


func limpar_memoria() -> void:
	_memoria.clear()


func tamanho_memoria() -> int:
	return _memoria.size()
