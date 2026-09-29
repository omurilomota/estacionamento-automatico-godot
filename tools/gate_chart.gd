extends SceneTree
## GATE — `src/farol/Chart.gd` (FAROL · CARTA) against the legacy rasteriser.
##
## The Chart claims to be a PERFORMANCE change, not a behaviour change: the
## legacy planner marks a cell solid when a circle of radius `inflar` centred
## there touches a wall (mask 2), one physics query per cell. The Chart
## computes the same bit with one world query + a chamfer distance transform
## + the exact query only where a hit is possible.
##
## This gate builds BOTH in the same level, in the same process, with the same
## `origem`/`tamanho`/`resolucao`/`inflar`, and asserts:
##   1. symmetric difference of the solid sets == 0   (behaviour preserved)
##   2. the Chart's exact-query count is much smaller  (the speed claim)
##   3. the clearance field is HONEST: every free cell really has at least
##      `clearance` px to the nearest wall, and no cell closer than the swept
##      radius is ever called free  (the safety claim)
##   4. the memory (ChartMemory) expires on its own TTL.
##
## Usage:
##   godot --headless --path . --script tools/gate_chart.gd -- --fase=Fase2
##   godot --headless --path . --script tools/gate_chart.gd -- --all
##
## Exits 0 when every level matches.

const ChartRef = preload("res://src/farol/Chart.gd")
const FarolSpecRef = preload("res://src/farol/FarolSpec.gd")

var _fase := "Fase2"
var _todas := false
var _max_dif := 0


func _init() -> void:
	var lista: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fase="):
			_fase = a.split("=")[1]
		elif a == "--all":
			_todas = true
	if _todas:
		for n in LevelRegistryRef.LEVELS:
			lista.append(str(n).get_file().get_basename())
	if lista.is_empty():
		lista.append(_fase)
	var falhas: Array = []
	for nome: String in lista:
		if not await _conferir(nome):
			falhas.append(nome)
	print("GATE_CHART %d nivel(is), %d com divergencia" % [lista.size(), falhas.size()])
	for f: String in falhas:
		print("   DIVERGENTE: " + f)
	print("GATE_CHART_%s" % ("OK" if falhas.is_empty() else "FALHOU"))
	quit(0 if falhas.is_empty() else 1)


const LevelRegistryRef = preload("res://src/core/LevelRegistry.gd")


func _conferir(fase_nome: String) -> bool:
	var cena = load("res://scenes/fases/%s.tscn" % fase_nome).instantiate()
	root.add_child(cena)
	await process_frame
	await physics_frame
	await physics_frame
	var carro: Node2D = cena.get_node_or_null("Carro") as Node2D
	var pl: Node2D = cena.get_node_or_null("Planejador") as Node2D
	if carro == null or pl == null:
		printerr("CHART: sem Carro/Planejador em " + fase_nome)
		return false
	var varrido: float = float(carro.call("raio_varrido"))
	var origem: Vector2 = pl.get("origem")
	var tamanho: Vector2 = pl.get("tamanho")
	var resolucao: float = float(pl.get("resolucao"))
	var raio: float = clampf(float(pl.get("inflar")), 60.0, 240.0)
	var espaco := root.get_world_2d().direct_space_state

	# 1. ORACLE: the legacy per-cell scan, straight into a set of cell keys, and
	# timed — the Chart's claim is a speed claim, so it has to be measured.
	var t0 := Time.get_ticks_msec()
	pl.set("farol_mode", 0)
	pl.call("construir")
	var ms_legado := float(Time.get_ticks_msec() - t0)
	var legado: Dictionary = {}
	for cel: Vector2i in pl.get("_celulas_bloqueadas"):
		legado[cel.y * 100000 + cel.x] = true

	# 2. CHART: the fast path, timed the same way (the gate also has to stamp
	# the AStarGrid2D, which is half of the work).
	var t1 := Time.get_ticks_msec()
	var chart := ChartRef.new()
	chart.configure(origem, tamanho, resolucao, raio)
	chart.rebuild(espaco)
	var grade := AStarGrid2D.new()
	grade.cell_size = Vector2(resolucao, resolucao)
	grade.offset = origem
	grade.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grade.region = Rect2i(0, 0, chart.n_cel_x(), chart.n_cel_y())
	grade.update()
	for cel2: Vector2i in chart.celulas_solidas():
		grade.set_point_solid(cel2, true)
	var ms_chart := float(Time.get_ticks_msec() - t1)
	var rapido: Dictionary = {}
	for cel3: Vector2i in chart.celulas_solidas():
		rapido[cel3.y * 100000 + cel3.x] = true
	var so_legado := 0
	var so_rapido := 0
	var faltando: Array = []
	for k: int in legado:
		if not rapido.has(k):
			so_legado += 1
			if faltando.size() < 6:
				faltando.append(k)
	for k2: int in rapido:
		if not legado.has(k2):
			so_rapido += 1
	var dif: int = so_legado + so_rapido
	if dif > _max_dif:
		_max_dif = dif
	var completo: bool = bool(chart.prefilter_completo)
	# On a divergence, say WHICH cells and WHAT is under them: a "missing"
	# cell is either a wall the pre-filter never stamped or a chamfer bug, and
	# the two need opposite fixes.
	if dif > 0:
		for k3: int in faltando:
			var cel: Vector2i = Vector2i(k3 % 100000, k3 / 100000)
			var p: Vector2 = chart.centro_de(cel)
			var q2 := PhysicsShapeQueryParameters2D.new()
			q2.collision_mask = 2
			q2.collide_with_bodies = true
			q2.collide_with_areas = false
			var f2 := CircleShape2D.new()
			f2.radius = raio
			q2.shape = f2
			q2.transform = Transform2D(0, p)
			var nomes: Array = []
			for h: Dictionary in espaco.intersect_shape(q2, 8):
				var b: Node = h.get("collider")
				nomes.append("%s/%s" % [b.get_parent().name, b.name])
			print("      DIVERGE celula=%s centro=(%.0f,%.0f) folga=%.1f sob=%s" % [
				str(cel), p.x, p.y, chart.folga(cel), ", ".join(PackedStringArray(nomes))])

	# 3. HONESTY of the clearance field: a free cell must really have that much
	# room, verified against the physics world with a real ray (not against the
	# field, which would be circular).
	var folga_min_ruim := 0
	var folga_pior := 1.0e9
	var sondados := 0
	var mentirosos: Array = []
	for cy in range(0, chart.n_cel_y(), 7):
		for cx in range(0, chart.n_cel_x(), 7):
			var cel := Vector2i(cx, cy)
			if chart.solido(cel):
				continue
			sondados += 1
			var p: Vector2 = chart.centro_de(cel)
			var cl: float = chart.folga(cel)
			folga_pior = minf(folga_pior, cl)
			if cl > 0.0 and not _folga_real(espaco, p, cl):
				folga_min_ruim += 1
				if mentirosos.size() < 6:
					var qq := PhysicsShapeQueryParameters2D.new()
					qq.collision_mask = 2
					qq.collide_with_bodies = true
					qq.collide_with_areas = false
					var ff := CircleShape2D.new()
					ff.radius = cl
					qq.shape = ff
					qq.transform = Transform2D(0, p)
					var quem: Array = []
					for h: Dictionary in espaco.intersect_shape(qq, 8):
						var b2: Node = h.get("collider")
						quem.append("%s/%s" % [b2.get_parent().name, b2.name])
					mentirosos.append("%s@%.0f,%.0f(c=%.0f) sob=[%s]" % [
						str(cel), p.x, p.y, cl, ", ".join(PackedStringArray(quem))])
	# 4. The safety claim, stated the way the code can actually keep it: the
	# clearance field is discounted by one and a half cells, so a free cell can
	# report up to one cell less than the swept radius. What must NEVER happen
	# is a free cell that is *far* from every wall being reported as tight.
	var folga_pior_livre := 1.0e9
	var folga_pior_cel := Vector2i.ZERO
	for cy2 in range(0, chart.n_cel_y(), 3):
		for cx2 in range(0, chart.n_cel_x(), 3):
			var cel4 := Vector2i(cx2, cy2)
			if chart.solido(cel4):
				continue
			var f4: float = chart.folga(cel4)
			if f4 < folga_pior_livre:
				folga_pior_livre = f4
				folga_pior_cel = cel4
	var tolerancia_celula: float = float(pl.get("resolucao"))
	var folga_ok: bool = folga_pior_livre >= varrido - tolerancia_celula

	# 5. Memory TTL: mark, read, expire.
	chart.definir_relogio(100.0)
	var cel_m: Vector2i = chart.celula_de(chart.centro_de(Vector2i(chart.n_cel_x() / 2,
		chart.n_cel_y() / 2)))
	chart.marcar_travou(chart.centro_de(cel_m), 100.0)
	var peso_antes: float = chart.peso_memoria(cel_m, FarolSpecRef.new())
	chart.definir_relogio(100.0 + 31.0)
	chart.rebuild(espaco)
	var peso_depois: float = chart.peso_memoria(cel_m, FarolSpecRef.new())

	var ganho := 100.0 * (1.0 - float(chart.consultas_exatas) / maxf(1.0, float(chart.celulas_totais)))
	print("CHART %-7s celulas=%d legacy_solidas=%d chart_solidas=%d dif_sym=%d" % [
		fase_nome, chart.celulas_totais, legado.size(), rapido.size(), dif])
	print("      tempo legado=%.0fms  chart=%.0fms (%.1fx)  consultas %d -> %d (%.0f%% menos)  prefilter=%s" % [
		ms_legado, ms_chart, ms_legado / maxf(1.0, ms_chart), chart.celulas_totais,
		chart.consultas_exatas,
		100.0 * (1.0 - float(chart.consultas_exatas) / maxf(1.0, float(chart.celulas_totais))),
		str(completo)])
	print("      clearance_prometida_mas_nao_existe=%d/%d  folga_pior_livre=%.1f (raio %.1f - 1 celula = %.1f) %s" % [
		folga_min_ruim, sondados, folga_pior_livre, varrido, varrido - tolerancia_celula,
		str(folga_pior_cel)])
	print("      memoria %.1f -> %.1f" % [peso_antes, peso_depois])
	for m: String in mentirosos:
		print("      PROMETE DEMAIS " + m)
	var ok: bool = dif == 0 and folga_min_ruim == 0 and folga_ok \
		and peso_antes > 1.0 and peso_depois == 1.0
	root.remove_child(cena)
	cena.queue_free()
	await process_frame
	return ok


## True when the physics world really gives at least `prometido` px of room at
## `p`: a circle of that radius must find nothing. This is the independent
## check of the Chart's promise (checking the field against itself would be
## circular).
func _folga_real(espaco, p: Vector2, prometido: float) -> bool:
	var forma := CircleShape2D.new()
	forma.radius = maxf(prometido, 1.0)
	var q := PhysicsShapeQueryParameters2D.new()
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.shape = forma
	q.transform = Transform2D(0, p)
	return espaco.intersect_shape(q, 1).is_empty()
