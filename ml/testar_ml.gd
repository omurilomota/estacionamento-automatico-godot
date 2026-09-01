extends SceneTree
## FASE 2 — AVALIAÇÃO: roda a fase com o ALUNO (modo_ml = true, sem trilha
## desenhada) e reporta se estaciona, em quanto tempo e com quantas colisões.
##
## Rodar:  godot --headless --path . --script ml/testar_ml.gd

const FASES := ["Fase3"]
const LIMITE_SEGUNDOS := 110.0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://ml/modelo"))
	var modelo := "res://ml/modelo/pesos.json"
	if not FileAccess.file_exists(modelo):
		print("SEM_MODELO: treine primeiro com python3 ml/treinar.py")
		quit()
		return
	for fase_nome: String in FASES:
		var fase = load("res://scenes/fases/%s.tscn" % fase_nome).instantiate()
		fase.get_node("Carro").modo_ml = true
		root.add_child(fase)
		await process_frame
		await process_frame
		var carro = fase.get_node("Carro")
		var ok := false
		var usou_fallback := false
		var frames := int(LIMITE_SEGUNDOS * 60.0)
		var t_fim := LIMITE_SEGUNDOS
		for i in range(frames):
			await process_frame
			if i % 300 == 0:
				print("t %.1f pos %s vel %.0f estado %s fallback %s" % [
					i / 60.0, carro.global_position, carro.velocidade_atual,
					carro.nome_estado(), str(not carro.modo_ml)])
			if not carro.modo_ml:
				usou_fallback = true
			if carro.estado == 3:
				ok = true
				t_fim = i / 60.0
				break
		print("RESULTADO %s: %s em %.1fs (usou_fallback=%s)" % [
			fase_nome, "ESTACIONADO" if ok else "FALHOU", t_fim, str(usou_fallback)])
		root.remove_child(fase)
		fase.queue_free()
		await process_frame
	quit()
