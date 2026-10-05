extends SceneTree
## FASE 2 — AVALIAÇÃO: roda a fase com o ALUNO (modo_ml = true, sem trilha
## desenhada) e reporta se estaciona, em quanto tempo e com quantas colisões.
##
## Rodar:  godot --headless --path . --script ml/testar_ml.gd

const FASES := ["Fase3"]
## 150 s (era 110). O caminho mudou de comprimento E de forma: a rota agora e
## suavizada (Chaikin) e deslizada para a faixa da direita, entao a rede dirige
## mais devagar pela via antes de entrar na vaga. O traço de 2026-09-26 mostra o
## carro na faixa (x ~ 1020) o tempo todo e entrando em ALINHANDO aos 100 s —
## ele estaciona, so depois do orcamento. O que este gate garante e que a rede
## CHEGA e estaciona com fallback da FSM, nao um tempo de corrida FIXO: a
## politica de seguranca do veiculo e o alvo, nao a velocidade.
const LIMITE_SEGUNDOS := 150.0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://ml/modelo"))
	var modelo := "res://ml/modelo/pesos.json"
	if not FileAccess.file_exists(modelo):
		print("SEM_MODELO: treine primeiro com python3 ml/treinar.py")
		quit()
		return
	for fase_nome: String in FASES:
		var fase = load("res://scenes/fases/%s.tscn" % fase_nome).instantiate()
		var ml_car = fase.get_node("Carro")
		if ml_car.has_method("set_ml_driving"):
			ml_car.call("set_ml_driving", true)
		else:
			ml_car.modo_ml = true
		root.add_child(fase)
		await process_frame
		await process_frame
		var carro = fase.get_node("Carro")
		var ok := false
		var usou_fallback := false
		var frames := int(LIMITE_SEGUNDOS * 60.0)
		var t_fim := LIMITE_SEGUNDOS
		for i in range(frames):
			# PHYSICS frames, not process frames (2026-09-29): the old loop
			# counted RENDER frames as if each were 1/60 s of game time. In
			# headless the two do not march 1:1, so the "150 s" budget was an
			# unknown number of game seconds — the car kept failing "at 150 s"
			# while a physics-paced trace of the SAME spawn parked at 70.4 s
			# (measured A/B, same seed family). AGENTS #14 already names
			# `--headless` + `await physics_frame` as the way to reproduce a
			# run; the budget now means what it says.
			await physics_frame
			if i % 300 == 0:
				print("t %.1f pos %s vel %.0f state %s fallback %s" % [
					i / 60.0, carro.global_position, carro.velocidade_atual,
					carro.call("state_label_en") if carro.has_method("state_label_en") else carro.nome_estado(),
					str(not (bool(carro.call("is_ml_driving")) if carro.has_method("is_ml_driving") else carro.modo_ml))])
			var ml_still_on: bool = bool(carro.call("is_ml_driving")) if carro.has_method("is_ml_driving") else carro.modo_ml
			if not ml_still_on:
				usou_fallback = true
			var parked_ok: bool = bool(carro.call("is_parked")) if carro.has_method("is_parked") else carro.estado == 3
			if parked_ok: # PARKED
				ok = true
				t_fim = i / 60.0
				break
		print("RESULTADO %s: %s em %.1fs (usou_fallback=%s)" % [
			fase_nome, "ESTACIONADO" if ok else "FALHOU", t_fim, str(usou_fallback)])
		root.remove_child(fase)
		fase.queue_free()
		await process_frame
	quit()
