extends SceneTree

const LaneOffsetRef = preload("res://src/navigation/LaneOffset.gd")
## GATE 3 — a "rua direita" e a FOLGA DA ROTA, na posicao ABSOLUTA.
##
## O usuario desenhou um box em Fase2 para marcar o que ele chama de rua
## direita (x 832..1206). A metrica antiga (deslocamento lateral em relacao ao
## centro do corredor) dava verde num corredor de 1470 px — seis carros de
## largura — enquanto o carro andava no MEIO. Este gate mede posicao absoluta,
## distancia ate a guia direita e fracao dentro do box, e tambem a invariante
## de seguranca (free_r' >= raio varrido) na rota deslocada.
##
## Uso: godot --headless --path . --script tools/gate_lane.gd -- --fase=Fase2 --secs=32

var _fase := "Fase2"
var _secs := 32.0
var _box := Rect2(832.0, -2000.0, 374.0, 4000.0)
var _min_corredor := 1000.0
var _shift := -1.0
var _farol := -1
var _lane := -1


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fase="):
			_fase = a.split("=")[1]
		elif a.begins_with("--secs="):
			_secs = float(a.split("=")[1])
		elif a.begins_with("--boxx0="):
			_box.position.x = float(a.split("=")[1])
		elif a.begins_with("--boxx1="):
			_box.size.x = float(a.split("=")[1]) - _box.position.x
		elif a.begins_with("--shift="):
			_shift = float(a.split("=")[1])
		elif a.begins_with("--farol="):
			_farol = int(a.split("=")[1])
		elif a.begins_with("--lane="):
			_lane = int(a.split("=")[1])
	var cena = load("res://scenes/fases/%s.tscn" % _fase).instantiate()
	var carro_pre: Node = cena.get_node_or_null("Carro")
	if carro_pre != null:
		if _shift >= 0.0:
			carro_pre.set("keep_right_shift", _shift)
		if _farol >= 0:
			carro_pre.set("farol_mode", _farol)
		if _lane >= 0:
			carro_pre.set("lane_cost_mode", _lane)
	root.add_child(cena)
	await process_frame
	var carro: Node2D = cena.get_node_or_null("Carro") as Node2D
	var espaco := root.get_world_2d().direct_space_state
	var xs: Array = []
	var frs: Array = []
	var dentro := 0
	var t := 0.0
	var prox := 0.0
	while t < _secs:
		await physics_frame
		t += 1.0 / 60.0
		if t < prox:
			continue
		prox = t + 0.1
		if int(carro.get("estado")) == 3 or absf(float(carro.get("velocidade_atual"))) < 12.0:
			continue
		var dir := Vector2.RIGHT.rotated(carro.rotation)
		var esq := dir.orthogonal()
		var dl := _sonda(carro.global_position, espaco, esq)
		var dr := _sonda(carro.global_position, espaco, -esq)
		if dl >= 1600.0 or dr >= 1600.0 or dl + dr < _min_corredor:
			continue
		xs.append(carro.global_position.x)
		frs.append(dr)
		if _box.has_point(carro.global_position):
			dentro += 1
	if xs.is_empty():
		print("GATE_LANE %s: sem amostras dentro de corredor largo" % _fase)
		print("GATE_LANE_FALHOU")
		quit(1)
		return
	# Uma mediana de 9 amostras ja produziu um veredito falso ("55,6% dentro do
	# box") na medicao de 2026-10-01: o carro passou 0,2 s no corredor largo e o
	# resto do tempo nao. Abaixo de MIN_AMOSTRAS nao ha julgamento de faixa, e o
	# gate FALHA em vez de medir a mediana de um punhado de pontos.
	const MIN_AMOSTRAS := 20
	if xs.size() < MIN_AMOSTRAS:
		print("GATE_LANE %s: so %d amostras no corredor largo (minimo %d) — nao da para julgar a faixa" % [
			_fase, xs.size(), MIN_AMOSTRAS])
		print("GATE_LANE_FALHOU")
		quit(1)
		return
	xs.sort()
	frs.sort()
	var x_med: float = xs[xs.size() / 2]
	var fr_med: float = frs[frs.size() / 2]
	var pct: float = 100.0 * dentro / xs.size()
	print("GATE_LANE %-6s n=%3d  x_mediano=%7.1f  guia_direita=%6.1f px  dentro_do_box=%5.1f%%  (box %.0f..%.0f)" % [
		_fase, xs.size(), x_med, fr_med, pct, _box.position.x, _box.end.x])

	# Invariante de seguranca na rota ja deslocada (o que o carro persegue),
	# medido SO NA VIA. A manobra final (os ultimos ~15% do comprimento, onde o
	# carro entra na vaga entre os carros estacionados) e apertada por desenho —
	# AGENTS #16/#18 — e cobrá-la aqui dava 3 "violacoes" que eram a manobra,
	# nao a faixa.
	var pl = cena.get_node_or_null("Planejador")
	var varrido: float = float(carro.raio_varrido())
	var violacoes := 0
	var min_fr := 1.0e9
	var onde := ""
	if pl != null:
		var rota: Array = carro.get("waypoints")
		if rota.size() >= 3:
			var total := 0.0
			for i in range(1, rota.size()):
				total += (rota[i] as Vector2).distance_to(rota[i - 1] as Vector2)
			var percorrido := 0.0
			for i in range(rota.size() - 1):
				percorrido += (rota[i] as Vector2).distance_to(rota[i - 1] as Vector2)
				if total > 0.0 and percorrido > total * 0.85:
					break   # manobra final: fora do invariante da faixa
				var p: Vector2 = rota[i]
				var n: Vector2 = LaneOffsetRef.tangent(rota, i).rotated(PI * 0.5)
				var fr: float = _sonda(p, espaco, n)
				if fr >= 1600.0:
					continue
				min_fr = minf(min_fr, fr)
				if fr < varrido - 0.5:
					violacoes += 1
					onde += " i=%d(%.0f,%.0f):%.0f" % [i, p.x, p.y, fr]
	print("GATE_LANE_ROTA %-6s pontos=%d min_free_r=%6.1f (raio varrido %.1f) violacoes=%d%s" % [
		_fase, (carro.get("waypoints") as Array).size(), min_fr, varrido, violacoes, onde])
	var ok: bool = violacoes == 0 and pct > 0.0
	print("GATE_LANE_%s" % ("OK" if ok else "FALHOU"))
	quit(0 if ok else 1)


func _sonda(p: Vector2, espaco, normal: Vector2) -> float:
	var q := PhysicsRayQueryParameters2D.create(p, p + normal * 1600.0)
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var r: Dictionary = espaco.intersect_ray(q)
	if r.is_empty():
		return 1600.0
	return p.distance_to(r.get("position") as Vector2)
