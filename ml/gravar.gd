extends SceneTree
## FASE 1 — GRAVAÇÃO (behavior cloning): roda as fases com o cérebro atual
## (o "professor") e salva CSV de (18 sensores -> 2 ações) por frame.
##
## Fase3 é a fonte principal (única com rotas Line2D que o professor segue
## bem): 1 episódio canônico + 3 com spawn aleatório (seeds diferentes).
## Fase1/Fase2 entram só como variedade (o professor nelas luta mais).
##
## Rodar:  godot --headless --path . --script ml/gravar.gd
## Saída:  ml/dados/<Fase>_ep<N>.csv

const LIMITE_SEGUNDOS := 150.0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://ml/dados"))
	# [fase, episodio, spawn_aleatorio]
	var plano := [
		["Fase3", 0, false],
		["Fase3", 1, true],
		["Fase3", 2, true],
		["Fase3", 3, true],
		["Fase1", 0, false],
		["Fase2", 0, false],
	]
	var total_linhas := 0
	for item: Array in plano:
		var fase_nome: String = item[0]
		var ep: int = item[1]
		var aleatorio: bool = item[2]
		var caminho := "res://ml/dados/%s_ep%d.csv" % [fase_nome, ep]
		DirAccess.remove_absolute(ProjectSettings.globalize_path(caminho))
		seed(1000 + ep) # spawn reproduzível e diferente por episódio
		var fase = load("res://scenes/fases/%s.tscn" % fase_nome).instantiate()
		fase.posicao_aleatoria = aleatorio
		root.add_child(fase)
		await process_frame
		await process_frame
		var carro = fase.get_node("Carro")
		if carro.has_method("begin_recording"):
			carro.call("begin_recording", caminho)
		else:
			carro.ml_gravar = true
			carro.ml_gravar_caminho = caminho
		var estacionou := false
		var frames := int(LIMITE_SEGUNDOS * 60.0)
		for i in range(frames):
			await process_frame
			var parked_ep: bool = bool(carro.call("is_parked")) if carro.has_method("is_parked") else carro.estado == 3
			if parked_ep: # VehicleState.PARKED
				estacionou = true
				break
		var linhas := _contar_linhas(caminho)
		total_linhas += linhas
		print("%s ep%d (%s): %s (%d amostras) em %.1fs" % [
			fase_nome, ep, "aleatorio" if aleatorio else "fixo",
			"ESTACIONADO" if estacionou else "TIMEOUT", linhas,
			(frames / 60.0)])
		if carro.has_method("close_recording"):
			carro.call("close_recording")
		else:
			carro._ml_fechar()
		root.remove_child(fase)
		fase.queue_free()
		await process_frame
		await process_frame
	print("GRAVACAO_CONCLUIDA total=%d" % total_linhas)
	quit()


func _contar_linhas(caminho: String) -> int:
	if not FileAccess.file_exists(caminho):
		return 0
	var n := 0
	var f := FileAccess.open(caminho, FileAccess.READ)
	if f == null:
		return 0
	while not f.eof_reached():
		if not f.get_line().is_empty():
			n += 1
	f.close()
	return n

