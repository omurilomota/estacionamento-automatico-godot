extends SceneTree
## GATE 4 — prova de MODO TRILHA na Fase2.
##
## A cena abre no piloto AUTONOMO, entao o modo trilha precisa ser FORCADO
## antes de a cena entrar na arvore (senao a `iniciar_modo_trilha()` nunca e'
## chamada). E o gate que garante que a rota autorada continua terminando
## dentro da vaga depois de qualquer mexida no offset de faixa: a regra de
## direita e' 0 no inicio e no fim da rota por projeto, e este gate e' quem
## prova isso.
##
## Uso: godot --headless --path . --script tools/gate_trail.gd -- --secs=70
## Sai != 0 se nao estacionar, se a distancia ao centro da vaga for grande, ou
## se der re indevida.

var _secs := 70.0
var _neg := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--secs="):
			_secs = float(a.split("=")[1])
	var cena = load("res://scenes/fases/Fase2.tscn").instantiate()
	var carro: Node2D = cena.get_node_or_null("Carro") as Node2D
	if carro == null:
		printerr("GATE_TRAIL: sem Carro")
		quit(1)
		return
	# ANTES de add_child: e' o unico momento em que o modo trilha pega.
	carro.set("modo_trilha", true)
	carro.set("auto_navegacao", false)
	root.add_child(cena)
	await process_frame
	var t := 0.0
	var est := 0
	var dist := 0.0
	var rot := 0.0
	var ocupada := false
	while t < _secs:
		await physics_frame
		t += 1.0 / 60.0
		est = int(carro.get("estado"))
		# Re de RECUPERACAO (estado 4) e' a manobra deliberada da escada de fuga
		# (AGENTS #37/#42) e nao entra em `neg_frames` — ver tools/gate_boot.gd.
		if float(carro.get("velocidade_atual")) < -1.0 and est != 4:
			_neg += 1
		if est == 3:
			break
	var vaga = carro.get("_vaga_alvo")
	if vaga != null:
		dist = (vaga as Node2D).global_position.distance_to(carro.global_position)
		rot = float((vaga as Node2D).get("rotacao_alvo"))
		ocupada = bool((vaga as Node2D).get("ocupada"))
	print("TRAIL %s t=%.1fs dist_centro=%.1f rot_alvo=%.3f ocupada=%s" % [
		"PARKED" if est == 3 else "NOT_PARKED", t, dist, rot, str(ocupada)])
	print("TRAIL_SUMMARY min_dist_centro=%.1f neg_frames=%d" % [dist, _neg])
	var ok: bool = est == 3 and dist < 30.0 and _neg == 0
	print("GATE_TRAIL_%s" % ("OK" if ok else "FALHOU"))
	quit(0 if ok else 1)
