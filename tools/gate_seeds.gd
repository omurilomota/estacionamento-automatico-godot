extends SceneTree
## GATE 2 — matriz de spawns aleatorios: 5 seeds x {Fase2, Fase3}, real boot.
##
## E o gate que pega o que a prova de boot nao pega: a escolha de vaga e o
## traçado dependem do ponto de partida, entao um unico boot canonico nao
## diz nada sobre robustez. Tambem reporta a cedencia por seed.
##
## Uso: godot --headless --path . --script tools/gate_seeds.gd -- --secs=80
## Sai != 0 se o total estacionado for menor que 10/10.

var NIVEIS := ["Fase2", "Fase3"]
const SEEDS := 5

var _secs := 80.0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--secs="):
			_secs = float(a.split("=")[1])
		elif a.begins_with("--fases="):
			NIVEIS = a.split("=")[1].split(",")
	var total := 0
	for nome in NIVEIS:
		var ok := 0
		var com_cedencia := 0
		for i in range(SEEDS):
			seed(9000 + i)
			var cena = load("res://scenes/fases/%s.tscn" % nome).instantiate()
			cena.set("posicao_aleatoria", true)
			root.add_child(cena)
			await process_frame
			var carro: Node2D = cena.get_node_or_null("Carro") as Node2D
			await physics_frame
			var t := 0.0
			var parado := 0.0
			var _min_gap := 1.0e9
			var _cedeu := false
			while t < _secs:
				await physics_frame
				t += 1.0 / 60.0
				if absf(float(carro.get("velocidade_atual"))) < 5.0:
					parado += 1.0 / 60.0
				for n in get_nodes_in_group("crosser"):
					var d: float = carro.global_position.distance_to((n as Node2D).global_position)
					_min_gap = minf(_min_gap, d)
					if d < 340.0 and absf(float(carro.get("velocidade_atual"))) < 5.0:
						_cedeu = true
				if int(carro.get("estado")) == 3:
					break
			var parked: bool = int(carro.get("estado")) == 3
			if parked:
				ok += 1
			if _cedeu:
				com_cedencia += 1
			print("SEED_RESULT %s seed=%d parked=%s t=%.1fs parado_max=%.1fs min_gap_crosser=%.1f" % [
				nome, i + 1, str(parked), t, parado, _min_gap])
			root.remove_child(cena)
			cena.queue_free()
			await process_frame
		total += ok
		print("LEVEL_SUMMARY %s: %d/%d estacionou, cedencia em %d/%d seeds" % [
			nome, ok, SEEDS, com_cedencia, SEEDS])
	print("MATRIX_SUMMARY: %d/%d estacionou" % [total, NIVEIS.size() * SEEDS])
	var passou: bool = total == NIVEIS.size() * SEEDS
	print("GATE_SEEDS_%s" % ("OK" if passou else "FALHOU"))
	quit(0 if passou else 1)
