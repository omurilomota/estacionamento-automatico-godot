extends SceneTree
## tools/gate_reach.gd — "the car can REACH the spots" gate.
##
## Answers the only question that matters for parking: given the occupancy grid
## the car actually builds (same origin/size/inflar as FaseBase + Carro), which
## bays have a PREPARATION POINT the car can route to?
##
## It mirrors the real pipeline: FaseBase sizes the grid, Carro raises `inflar`
## to the swept radius, Planejador.construir() rasterises the physics, and
## Planejador.achar_rota() is called exactly like Carro._escolher_vaga() does.
##
## Run: godot --headless --path . --script tools/gate_reach.gd -- --fase=Fase1
## Exit: 0 if at least one bay is reachable, 1 otherwise.

var _fase := "Fase1"


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fase="):
			_fase = a.split("=")[1]
	var cena: Node = load("res://scenes/fases/%s.tscn" % _fase).instantiate()
	root.add_child(cena)
	await process_frame
	await physics_frame
	await physics_frame
	var carro: Node2D = cena.get_node_or_null("Carro") as Node2D
	var pl: Node2D = cena.get_node_or_null("Planejador") as Node2D
	var vagas: Node2D = cena.get_node_or_null("Vagas") as Node2D
	if carro == null or pl == null or vagas == null:
		printerr("REACH: no Carro/Planejador/Vagas in " + _fase)
		quit(1)
		return
	var varrido: float = float(carro.call("raio_varrido"))
	print("   world=(%.0f x %.0f) escala=%.2f alcance_preparo=%.1f rota_alcance=%.1f" % [
		float(cena.get("largura_mundo")), float(cena.get("altura_mundo")),
		float(cena.get("escala_mapa")), float(carro.call("alcance_preparo")),
		float(carro.call("alcance_preparo"))])
	var limite: Node = cena.get_node_or_null("Paredes/LimiteAutomatico")
	if limite != null:
		for sh in limite.get_children():
			var cs := sh as CollisionShape2D
			if cs == null or not (cs.shape is RectangleShape2D):
				continue
			var sz: Vector2 = (cs.shape as RectangleShape2D).size
			print("      wall center=(%.0f, %.0f) size=(%.0f, %.0f)" % [
				cs.position.x, cs.position.y, sz.x, sz.y])
	print("== %s modo=%s auto=%s brain=%s car_scale=%.2f" % [_fase,
		"TRILHA" if bool(carro.get("modo_trilha")) else "AUTONOMO",
		str(carro.get("auto_navegacao")), str(carro.get("brain_enabled")),
		carro.global_scale.x])
	print("   spawn=(%.0f, %.0f) swept_r=%.1f inflar=%.1f resolucao=%d" % [
		carro.global_position.x, carro.global_position.y, varrido,
		float(pl.get("inflar")), int(pl.get("resolucao"))])
	pl.call("construir")
	var grade: AStarGrid2D = pl.get("_grade")
	var reg: Rect2i = grade.region
	var origem: Vector2 = pl.get("origem")
	var tamanho: Vector2 = pl.get("tamanho")
	print("   grid region=%s origem=(%.0f, %.0f) tamanho=(%.0f, %.0f)" % [
		str(reg), origem.x, origem.y, tamanho.x, tamanho.y])
	# WHY is the spawn cell solid? Print every body whose inflated AABB
	# contains the spawn (mask 2 = obstacles/walls, the same thing the
	# rasteriser queries). Silent when the spawn is free.
	var cel0: Vector2i = pl.call("_celula_de", carro.global_position)
	if grade.is_point_solid(cel0):
		print("   WHY spawn solid: inflar=%.1f" % float(pl.get("inflar")))
		var espaco := carro.get_world_2d().direct_space_state
		var forma := CircleShape2D.new()
		forma.radius = float(pl.get("inflar"))
		var q := PhysicsShapeQueryParameters2D.new()
		q.collision_mask = 2
		q.collide_with_bodies = true
		q.collide_with_areas = false
		q.shape = forma
		q.transform = Transform2D(0, carro.global_position)
		for hit in espaco.intersect_shape(q, 16):
			var body: Node = hit.get("collider")
			if body == null:
				continue
			var owner_name: String = str(body.name)
			if body.get_parent() != null and body.get_parent() != cena:
				owner_name = str(body.get_parent().name) + "/" + owner_name
			print("      HIT layer=%d %s pos=(%.0f, %.0f) scale=(%.2f, %.2f)" % [
				int(body.get("collision_layer")), owner_name,
				(body as Node2D).global_position.x, (body as Node2D).global_position.y,
				(body as Node2D).global_scale.x, (body as Node2D).global_scale.y])
	var nx: int = reg.size.x
	var ny: int = reg.size.y
	var livre: Array = []
	var free_total := 0
	var solid_total := 0
	for y in range(ny):
		var linha: Array = []
		for x in range(nx):
			if grade.is_point_solid(Vector2i(x, y)):
				solid_total += 1
				linha.append(0)
			else:
				free_total += 1
				linha.append(1)
		livre.append(linha)
	# --- BFS from the spawn cell over free cells (4-neighbour) ---
	var cel_spawn: Vector2i = pl.call("_celula_de", carro.global_position)
	cel_spawn = Vector2i(clampi(cel_spawn.x, 0, nx - 1), clampi(cel_spawn.y, 0, ny - 1))
	var alcancavel: Array = []
	for y in range(ny):
		var linha2: Array = []
		for x in range(nx):
			linha2.append(false)
		alcancavel.append(linha2)
	var fila: Array = []
	var spawn_livre: bool = livre[cel_spawn.y][cel_spawn.x] == 1
	if spawn_livre:
		alcancavel[cel_spawn.y][cel_spawn.x] = true
		fila.append(cel_spawn)
	var visitados := 0
	while not fila.is_empty():
		var c: Vector2i = fila.pop_back()
		visitados += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= nx or n.y >= ny:
				continue
			if alcancavel[n.y][n.x] or livre[n.y][n.x] == 0:
				continue
			alcancavel[n.y][n.x] = true
			fila.append(n)
	print("   cells=%d free=%d solid=%d spawn_cell=%s spawn_free=%s REACHABLE=%d (%.1f%% of free)" % [
		nx * ny, free_total, solid_total, str(cel_spawn), str(spawn_livre), visitados,
		100.0 * float(visitados) / maxf(1.0, float(free_total))])
	# --- per-bay: the prep point is where the car must ARRIVE ---
	var alcancaveis := 0
	var total := 0
	for vaga in vagas.get_children():
		total += 1
		var prep: Vector2 = carro.call("_ponto_prep_da_vaga", vaga)
		var rota: Array = pl.call("achar_rota", carro.global_position, prep)
		var cprep: Vector2i = pl.call("_celula_de", prep)
		var dentro: bool = reg.has_point(cprep)
		var solido: bool = dentro and grade.is_point_solid(cprep)
		var d_best := 1.0e12
		var best := Vector2i(-1, -1)
		var cmin := Vector2i(maxi(0, cprep.x - 25), maxi(0, cprep.y - 25))
		var cmax := Vector2i(mini(nx - 1, cprep.x + 25), mini(ny - 1, cprep.y + 25))
		for y in range(cmin.y, cmax.y + 1):
			for x in range(cmin.x, cmax.x + 1):
				if not alcancavel[y][x]:
					continue
				var d: float = Vector2(x, y).distance_to(Vector2(cprep))
				if d < d_best:
					d_best = d
					best = Vector2i(x, y)
		var ok: bool = rota.size() >= 2
		if ok:
			alcancaveis += 1
		print("   %-7s pos=(%7.0f,%7.0f) prep=(%7.0f,%7.0f) in=%s solid=%s nearest_reach=%s d=%.1f cells rota_wp=%d %s" % [
			vaga.name, vaga.global_position.x, vaga.global_position.y, prep.x, prep.y,
			str(dentro), str(solido), str(best), d_best, rota.size(),
			"REACHABLE" if ok else "*** UNREACHABLE ***"])
	print("REACH %s bays=%d reachable=%d" % [_fase, total, alcancaveis])
	print("GATE_REACH_%s" % ("OK" if alcancaveis > 0 else "FALHOU"))
	quit(0 if alcancaveis > 0 else 1)
