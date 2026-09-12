extends SceneTree
## FASE 3 — AVALIADOR de fitness para a neuroevolução (chamado por ml/evoluir.py).
## Roda 1 episódio da Fase3 (spawn fixo, determinístico) com a rede em
## 240 ticks/s (4x mais rápido), SEM fallbacks, e imprime o fitness.
##
## Fitness: estacionou -> 3000 - t | não -> -distância_final até a vaga
##
## Rodar:  godot --headless --path . --script ml/avaliar.gd

const LIMITE_SEGUNDOS := 45.0
const TICKS_POR_SEGUNDO := 240


func _init() -> void:
	Engine.physics_ticks_per_second = TICKS_POR_SEGUNDO
	if not FileAccess.file_exists("res://ml/modelo/pesos.json"):
		print("FITNESS -9999.0")
		quit()
		return
	var fase = load("res://scenes/fases/Fase3.tscn").instantiate()
	fase.posicao_aleatoria = false
	root.add_child(fase)
	await process_frame
	await process_frame
	var carro = fase.get_node("Carro")
	if carro.has_method("set_ml_driving"):
		carro.call("set_ml_driving", true)
	else:
		carro.modo_ml = true
	if carro.has_method("set_ml_fallback_off"):
		carro.call("set_ml_fallback_off", true)
	else:
		carro.ml_sem_fallback = true
	var vaga = carro.call("target_spot") if carro.has_method("target_spot") else carro._vaga_alvo
	if vaga == null:
		# vaga escolhida no primeiro frame de física
		await physics_frame
		vaga = carro._vaga_alvo
	var estacionou := false
	var limite := int(LIMITE_SEGUNDOS * TICKS_POR_SEGUNDO)
	var t_fim := LIMITE_SEGUNDOS
	for i in range(limite):
		await physics_frame
		var live_spot = carro.call("target_spot") if carro.has_method("target_spot") else carro._vaga_alvo
		if live_spot != null:
			vaga = live_spot
		var parked_now: bool = bool(carro.call("is_parked")) if carro.has_method("is_parked") else carro.estado == 3
		if parked_now: # PARKED
			estacionou = true
			t_fim = i / float(TICKS_POR_SEGUNDO)
			break
	var dist_final: float = carro.global_position.distance_to(vaga.global_position) if vaga != null else 9999.0
	var fitness: float = (3000.0 - t_fim) if estacionou else -dist_final
	print("FITNESS %.2f estacionou %s t %.2f dist %.1f" % [fitness, str(estacionou), t_fim, dist_final])
	quit()
