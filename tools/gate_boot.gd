extends SceneTree
## GATE 1 — boot real de uma fase: estaciona? e como?
##
## Mede, no jogo de verdade (não no roteiro):
##   - ESTACIONADO e em quantos segundos
##   - hit da carroceria em cone + menor folga (cone e' obstaculo solido, layer 2)
##   - a sequencia de CEDENCIA do CrosserGate do cerebro ativo: latch, standstill
##   - frames de re indevida (neg_frames) e de re de RECUPERACAO (rec_frames)
##
## Uso: godot --headless --path . --script tools/gate_boot.gd -- --fase=Fase2 --secs=75
## Sai != 0 se nao estacionar, bater em cone ou dar re indevida.
##
## `neg_frames` conta re na DIRECAO (estados 0/1/2/3: buscando/desviando/
## alinhando/estacionado). A re do RECUPERANDO (4) e' a manobra DELIBERADA da
## escada de fuga (AGENTS #37/#42) e sai em `rec_frames`: sem essa separacao um
## carro que se desencrava sozinho e estaciona era reprovado pelo proprio
## resgate. O gate continua exigindo `neg_frames == 0`.
##
## NEG_GRACE_FRAMES: o carro sai do RECUPERANDO a -64 px/s e o comando novo so
## vence a inercia depois de ~0,4 s (medido 8 frames em Fase1). Contar esses
## frames como "re indevida" e' contar a MESMA re duas vezes, entao ha uma
## janela de graca depois do ultimo frame em RECUPERANDO.
const NEG_GRACE_FRAMES := 25

var _fase := "Fase2"
var _secs := 75.0
var _farol := -1
var _neg := 0
var _rec := 0
var _desde_rec := 1 << 30
var _cone_hits := 0
var _cone_ray_seen := 0
var _min_cone_gap := 1.0e9
var _latches := 0
var _latch_run := 0.0
var _max_latch := 0.0
var _max_stop := 0.0
var _stopped_while_latched := 0.0
var _min_crosser_gap := 1.0e9
## PEDESTRE (docs/tasks_trafego.md T4): observable pedestrian yield + the min
## gap the car ever kept from a pedestrian node (sensor-only — the latch is
## the only protection, so a small min gap is the run-over).
var _ped_latches := 0
var _min_ped_gap := 1.0e9
var _latched := false
var _t := 0.0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fase="):
			_fase = a.split("=")[1]
		elif a.begins_with("--secs="):
			_secs = float(a.split("=")[1])
		elif a.begins_with("--farol="):
			_farol = int(a.split("=")[1])
	var cena = load("res://scenes/fases/%s.tscn" % _fase).instantiate()
	# A/B medido sem editar a cena (o padrao do gate_drive): um farol_mode
	# diferente entre a chamada e o boot e o teste do PILOTO, nao da cena.
	if _farol >= 0:
		(cena.get_node("Carro") as Node).set("farol_mode", _farol)
	root.add_child(cena)
	await process_frame
	var carro: Node2D = cena.get_node_or_null("Carro") as Node2D
	if carro == null:
		printerr("GATE_BOOT: sem Carro em " + _fase)
		quit(1)
		return
	await physics_frame
	var cones: Array = _cones(cena)
	print("== %s spawn=(%.0f, %.0f) cones=%d" % [_fase, carro.global_position.x,
		carro.global_position.y, cones.size()])
	var parado := 0.0
	var _parado_cont := 0.0
	var _cedendo := false
	var _cedendo_ped := false
	var est: int = 0
	while _t < _secs:
		await physics_frame
		_t += 1.0 / 60.0
		est = int(carro.get("estado"))
		var v: float = float(carro.get("velocidade_atual"))
		if est == 4:
			_desde_rec = 0
		else:
			_desde_rec += 1
		if v < -1.0:
			if est == 4 or _desde_rec <= NEG_GRACE_FRAMES:
				_rec += 1
			else:
				_neg += 1
		if cones.size() > 0:
			_min_cone_gap = minf(_min_cone_gap, _folga_ao_cone(carro, cones))
			if _dentro_de_algum(carro, cones):
				_cone_hits += 1
			if v < 60.0 and _ray_frontal_bloqueada(carro, cones):
				_cone_ray_seen += 1
		var d: float = _crosser_dist(carro)
		if d < 1.0e8:
			_min_crosser_gap = minf(_min_crosser_gap, d)
			# CEDENCIA OBSERVAVEL: existe um carro que cruza perto E o jogador
			# esta parado. Nao le o CrosserGate de dentro do carro: com o cerebro
			# ativo o gate usado e' o do cerebro (AGENTS #20).
			var parando: bool = absf(v) < 5.0 and d < 340.0
			if parando:
				_parado_cont += 1.0 / 60.0
				_stopped_while_latched += 1.0 / 60.0
				_latch_run += 1.0 / 60.0
			if parando and not _cedendo:
				_latches += 1
			_cedendo = parando
			_max_latch = maxf(_max_latch, _latch_run)
		else:
			_latch_run = 0.0
		# PEDESTRE (docs/tasks_trafego.md T4): a cedencia observavel de um
		# pedestre tem prioridade — o carro NUNCA pode chegar perto demais do
		# no dele (sensor-only; a latch e a unica protecao).
		var dp: float = _pedestre_dist(carro)
		if dp < 1.0e8:
			_min_ped_gap = minf(_min_ped_gap, dp)
			var parando_ped: bool = absf(v) < 5.0 and dp < 340.0
			if parando_ped and not _cedendo_ped:
				_ped_latches += 1
			_cedendo_ped = parando_ped
		else:
			_cedendo_ped = false
		if absf(v) < 5.0:
			parado += 1.0 / 60.0
		_max_stop = maxf(_max_stop, parado)
		if est == 3:
			break
	var est_final: int = int(carro.get("estado"))
	var wp: int = int(carro.get("indice_waypoint"))
	var n_wp: int = (carro.get("waypoints") as Array).size()
	print("BOOT %s %s t=%.1fs estado=%d pos=(%.0f, %.0f) wp=%d/%d" % [
		_fase, "PARKED" if est_final == 3 else "NOT_PARKED", _t, est_final,
		carro.global_position.x, carro.global_position.y, wp, n_wp])
	print("CONES hits=%d ray_finite_while_passing=%d min_gap=%.1f px" % [
		_cone_hits, _cone_ray_seen, _min_cone_gap])
	print("CROSSER latches=%d longest_latch=%.1fs longest_stop=%.1fs stopped_while_latched=%.1fs min_gap=%.1f px" % [
		_latches, _max_latch, _max_stop, _stopped_while_latched, _min_crosser_gap])
	print("PEDESTRE latches=%d min_gap=%.1f px" % [_ped_latches, _min_ped_gap])
	print("NEG_FRAMES=%d REC_FRAMES=%d" % [_neg, _rec])
	var ok := est_final == 3 and _cone_hits == 0 and _neg == 0
	print("GATE_BOOT_%s" % ("OK" if ok else "FALHOU"))
	quit(0 if ok else 1)


## Os cones nao tem grupo: sao instancias de scenes/Cone.tscn sob Obstaculos,
## entao a busca e por TIPO de script + geometria do circulo.
func _cones(cena: Node) -> Array:
	var out: Array = []
	var obs: Node = cena.get_node_or_null("Obstaculos")
	if obs == null:
		return out
	for n in obs.get_children():
		if "Cone" in str(n.name):
			out.append(n as Node2D)
	return out


func _folga_ao_cone(carro: Node2D, cones: Array) -> float:
	var melhor := 1.0e9
	for c in cones:
		var cd: Vector2 = c.global_position
		var cr := 18.0 * maxf(c.get("global_scale").x, 1.0)
		# retangulo do circulo do cone
		var d: float = _dist_ponto_retangulo(carro.global_position, cd, cr)
		melhor = minf(melhor, d - cr)
	return melhor


func _dist_ponto_retangulo(p: Vector2, c: Vector2, r: float) -> float:
	return p.distance_to(c) - r


func _dentro_de_algum(carro: Node2D, cones: Array) -> bool:
	for c in cones:
		var cr: float = 18.0 * maxf(c.get("global_scale").x, 1.0)
		if carro.global_position.distance_to(c.global_position) < cr:
			return true
	return false


func _ray_frontal_bloqueada(carro: Node2D, cones: Array) -> bool:
	for c in cones:
		var cr: float = 18.0 * maxf(c.get("global_scale").x, 1.0)
		if carro.global_position.distance_to(c.global_position) < cr + 120.0:
			return true
	return false


func _crosser_dist(carro: Node2D) -> float:
	var melhor := 1.0e9
	for n in get_nodes_in_group("crosser"):
		melhor = minf(melhor, carro.global_position.distance_to((n as Node2D).global_position))
	return melhor


func _pedestre_dist(carro: Node2D) -> float:
	var melhor := 1.0e9
	for n in get_nodes_in_group("pedestre"):
		melhor = minf(melhor, carro.global_position.distance_to((n as Node2D).global_position))
	return melhor
