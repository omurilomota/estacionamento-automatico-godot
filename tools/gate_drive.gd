extends SceneTree
## GATE 5 — QUALIDADE DE PILOTAGEM (o gate que responde "ele entendeu mais?").
##
## `gate_boot` responde SIM ou NAO (estacionou, bateu, deu re). `gate_drive`
## responde QUANTO BEM: um carro que estaciona em 67 s serpenteando no meio da
## rua, com o volante saturado e 0,3 s de CTE, esta tecnicamente verde no
## `gate_boot` e e exatamente o que o usuario chamou de "burro". Estas sao as
## metricas de pilotagem, todas medidas NO JOGO DE VERDADE (mesmo boot, mesmo
## `physics_frame`), nunca em roteiro:
##
##   |CTE| medio e p95 .... erro lateral a rota (px). O PipelineMgr/Stanley
##                          existe porque o pure-pursuit sozinho converge so
##                          assintoticamente (AGENTS #36).
##   saturacao_volante ... % de frames com |estercamento| >= 0.98 * max. Num
##                          corredor reto isso e' ~= 0; 34% era o sintoma de
##                          "cortando a quina" (docs/tasks_dificuldade.md §8).
##   folga_min / p5 ...... distancia do casco ate o obstaculo mais proximo
##                          (layer 2), medida no centro do carro. Abaixo do raio
##                          varrido e' uma raspagem.
##   replans ............. quantas vezes o carro refez a rota.
##   desvios ............. quantas vezes o PILOTO LOCAL desviou (so > 0 com o
##                          FAROL promoted; 0 no legado e' o esperado do A/B).
##   ttc_min ............. menor time-to-collision estimado a partir dos raios.
##   parado_max .......... maior standstill (o gate_seeds ja mede isto).
##   tempo ............... segundos ate ESTACIONADO.
##
## USO:
##   godot --headless --path . --script tools/gate_drive.gd -- --fase=Fase2 --secs=75
##   godot --headless --path . --script tools/gate_drive.gd -- --all --secs=75 --json=/tmp/drive.json
##
## `--json` grava o placar agregado (uma linha por fase) para o before/after
## do docs/tasks_backlog.md. `--ref=<arquivo.json>` compara com um placar
## anterior e reprova se QUALKER metrica regredir alem da tolerancia.
## Sem `--ref` e' SO MEDIDA: sai 0 sempre (um gate que reprova o legado
## porque o legado nao sabe pilotar nao serve de linha de base).
##
## SEED (obrigatorio para um placar valer como linha de base)
## -------------------------------------------------------
## `FaseBase.posicao_aleatoria` é `true` (AGENTS #28), e o spawn sorteado
## decide TUDOnestas metricas. Medido na Fase7, mesmo commit, 3 processos:
##   spawn (744, 352) -> sat 58,5%  folga 12,4  t 33,4 s
##   spawn (583, 383) -> sat 77,4%  folga 148,7 t 10,1 s
## Um A/B entre "antes" e "depois" com sorteios diferentes mede o SORTEIO, nao
## o codigo — e foi exatamente assim que um `--all` de 9 fases deu NOT_PARKED
## na Fase7 e na Fase8 enquanto `gate_boot` (processo novo) dava 7,1 s e 6,6 s
## nas mesmas duas fases.
## Por isso `--seed` tem valor PADRAO (9000, a mesma familia do `gate_seeds`)
## e a seed entra no JSON: um placar sem seed no arquivo nao e reproduzivel e
## portanto nao serve para nada. `--seed=0` devolve o sorteio livre, que e o
## que se quer quando o objetivo e robustez e nao comparacao.
##
##   --seed=9000   fixo e reproduzivel (PADRAO, use este para o A/B)
##   --seed=0      sorteio livre (equivale a nao fixar seed)
##
## FAROL OVERLOAD (--farol=N)
## --------------------------
## Mede a fase com o piloto FAROL (`farol_mode = N`) SEM editar a cena: o
## valor e declarado no no `Carro` ANTES de `add_child` (a mesma tecnica do
## `gate_trail`), que e o unico momento seguro — `farol_mode` so e lido no
## primeiro frame (`_garantir_folga_do_planejador`, comanda §7) e o cache de
## brains tem o valor na chave (AGENTS #20). `--farol=-1` (padrao) nao toca na
## cena e mede o que ela declara. O campo `farol_mode` do relatorio reflete o
## que rodou de verdade, e comparar `--farol=2` contra uma ref `farol_mode=0`
## NAO reprova por isso (o campo nao entra na lista de regressao).
const SEM_FAROL := -1
const SEM_LANE := -1
const SEM_SHIFT := -1.0

const SensorArrayRef = preload("res://src/vehicle/SensorArray.gd")
const LevelRegistryRef = preload("res://src/core/LevelRegistry.gd")

const METRICAS := [
	"fase", "t", "cte_medio", "cte_p95", "sat_pct", "folga_min", "replans",
	"desvios", "ttc_min", "parado_max", "estado", "farol_mode", "lane_cost",
	"com_fallback", "seed",
]

## Default seed, NOT 0: see the SEED block above. A scoreboard is only a
## baseline if the same run reproduces it, and `posicao_aleatoria` is on.
const SEED_PADRAO := 9000

var _fase := "Fase2"
var _secs := 75.0
var _todas := false
var _json := ""
var _ref := ""
var _tol := 0.10
var _seed := SEED_PADRAO
var _farol := SEM_FAROL
var _lane := SEM_LANE
var _shift := SEM_SHIFT


func _init() -> void:
	var lista: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fase="):
			_fase = a.split("=")[1]
		elif a.begins_with("--secs="):
			_secs = float(a.split("=")[1])
		elif a == "--all":
			_todas = true
		elif a.begins_with("--json="):
			_json = a.split("=")[1]
		elif a.begins_with("--ref="):
			_ref = a.split("=")[1]
		elif a.begins_with("--tol="):
			_tol = float(a.split("=")[1])
		elif a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
		elif a.begins_with("--farol="):
			_farol = int(a.split("=")[1])
		elif a.begins_with("--lane="):
			_lane = int(a.split("=")[1])
		elif a.begins_with("--shift="):
			_shift = float(a.split("=")[1])
	if _todas:
		for n in LevelRegistryRef.LEVELS:
			lista.append(str(n).get_file().get_basename())
	if lista.is_empty():
		lista.append(_fase)
	var ref: Dictionary = _carregar(_ref)
	var relatorio: Array = []
	var regrediu: Array = []
	for nome: String in lista:
		var linha: Dictionary = await _medir(nome)
		relatorio.append(linha)
		var antes: Dictionary = ref.get(linha.get("fase", ""), {})
		for chave: String in METRICAS:
			if chave == "fase":
				continue
			var d: Dictionary = _compara(antes, linha, chave, _tol)
			if not bool(d.get("ok", true)):
				regrediu.append("%s.%s %s -> %s" % [nome, chave, d.get("antes"),
					d.get("agora")])
	_salvar(_json, relatorio)
	print("GATE_DRIVE %d fase(s) medida(s)%s" % [
		relatorio.size(), "" if regrediu.is_empty() else ", REGRESSAO: " + ", ".join(regrediu)])
	print("GATE_DRIVE_%s" % ("REGRESSOU" if not regrediu.is_empty() else "OK"))
	quit(1 if not regrediu.is_empty() else 0)


## Uma fase = um boot real, medido frame a frame.
func _medir(fase_nome: String) -> Dictionary:
	# A seed e' fixada AQUI, por fase, e NAO uma vez no `_init`: num `--all` de
	# 9 fases o mesmo processo sorteia 9 spawns, e o sorteio da Fase8 depende
	# de quantas vezes o RNG foi consumido antes. Derivar a seed do NOME da fase
	# faz cada fase depender so de si mesma, entao `--fase=Fase7` mede
	# exatamente o mesmo boot que a 7a linha de um `--all`. `seed(0)` devolve o
	# sorteio livre, que e o modo "quero robustez, nao comparacao".
	if _seed != 0:
		seed(_seed + int(str(fase_nome).hash()))
	var cena = load("res://scenes/fases/%s.tscn" % fase_nome).instantiate()
	# The FAROL overload MUST land before the scene enters the tree: `_ready`
	# is where the planner reads `farol_mode` and the car caches its brain.
	if _farol != SEM_FAROL or _lane != SEM_LANE or _shift != SEM_SHIFT:
		var carro_pre: Node = cena.get_node_or_null("Carro")
		if carro_pre != null:
			if _farol != SEM_FAROL:
				carro_pre.set("farol_mode", _farol)
			if _shift != SEM_SHIFT:
				# The lane width is per-level DATA (AGENTS #31). Sweeping it
				# here is how a level's `keep_right_shift` gets tuned without
				# editing the scene and regenerating it.
				carro_pre.set("keep_right_shift", _shift)
			if _lane != SEM_LANE:
				# FAROL · ROTA (S2): the right-hand rule as A* COST. Like
				# farol_mode, it only needs to exist before the scene enters
				# the tree (the planner reads it on the first build).
				carro_pre.set("lane_cost_mode", _lane)
	root.add_child(cena)
	await process_frame
	var carro: Node2D = cena.get_node_or_null("Carro") as Node2D
	if carro == null:
		printerr("GATE_DRIVE: sem Carro em " + fase_nome)
		return {"fase": fase_nome, "estado": -1}
	await physics_frame
	var espaco := root.get_world_2d().direct_space_state
	# The spawn IS the input of this measurement: with `posicao_aleatoria` on,
	# a score without the spawn it came from cannot be reproduced or judged. Read
	# it AFTER the first physics frames, because the level places the car there.
	var spawn := Vector2.ZERO
	var varrido: float = float(carro.call("raio_varrido")) if carro.has_method("raio_varrido") else 60.0
	var max_est: float = float(carro.get("max_estercamento"))

	# Amostragem a 10 Hz (a dinometrica nao precisa de 60 Hz e o gate roda em
	# segundos, nao em horas). Uma Amostra = um tique do carro.
	var ctes: Array = []
	var saturados := 0
	var amostras := 0
	var folga_min := 1.0e9
	var ttc_min := 1.0e9
	var parado := 0.0
	var parado_max := 0.0
	var t := 0.0
	var prox := 0.0
	var est := 0
	var com_fallback := false
	# Read the spawn on the first sampled frame, once the level has placed it.
	var spawn_lido := false
	while t < _secs:
		await physics_frame
		t += 1.0 / 60.0
		est = int(carro.get("estado"))
		if not spawn_lido:
			spawn = (carro as Node2D).global_position
			spawn_lido = true
		var v: float = float(carro.get("velocidade_atual"))
		if absf(v) < 5.0:
			parado += 1.0 / 60.0
			parado_max = maxf(parado_max, parado)
		else:
			parado = 0.0
		if t < prox:
			if est == 3:
				break
			continue
		prox = t + 0.1
		if est == 3 or est == 2:
			# ESTACIONADO/ALINHANDO: a manobra final e' apertada por desenho
			# (AGENTS #16/#27) e nao e' "pilotagem em corredor".
			if est == 3:
				break
			continue
		amostras += 1
		var est_steering: float = float(carro.get("estercamento"))
		if absf(est_steering) >= max_est * 0.98:
			saturados += 1
		var cte: float = INF
		if carro.has_method("_cte_para_rota"):
			cte = float(carro.call("_cte_para_rota"))
		if is_finite(cte):
			ctes.append(cte)
		folga_min = minf(folga_min, _folga_carro(carro, espaco, varrido))
		ttc_min = minf(ttc_min, _ttc(carro, v))
		if bool(carro.get("modo_ml")) == false and carro.has_method("is_ml_driving"):
			com_fallback = com_fallback or not bool(carro.call("is_ml_driving"))
	var wp: int = int(carro.get("indice_waypoint"))
	var n_wp: int = (carro.get("waypoints") as Array).size()
	var replans: int = int(carro.get("_contagem_replanejamento")) \
		if "_contagem_replanejamento" in carro else 0
	var desvios: int = int(carro.get("_contagem_desvio_farol")) \
		if "_contagem_desvio_farol" in carro else 0
	var linha := {
		"fase": fase_nome,
		"t": snappedf(t, 0.1),
		"cte_medio": _media(ctes),
		"cte_p95": _p95(ctes),
		"sat_pct": snappedf(100.0 * float(saturados) / maxf(1.0, float(amostras)), 0.1),
		"folga_min": snappedf(folga_min, 0.1),
		"replans": replans,
		"desvios": desvios,
		"ttc_min": snappedf(ttc_min, 0.1),
		"parado_max": snappedf(parado_max, 0.1),
		"estado": est,
		"farol_mode": int(carro.get("farol_mode")) if "farol_mode" in carro else 0,
		"lane_cost": int(carro.get("lane_cost_mode")) if "lane_cost_mode" in carro else 0,
		"com_fallback": com_fallback,
		"seed": _seed,
		"spawn_x": snappedf(spawn.x, 1.0),
		"spawn_y": snappedf(spawn.y, 1.0),
	}
	print("DRIVE %-7s %-9s t=%5.1f cte_med=%6.1f cte_p95=%6.1f sat=%5.1f%% folga_min=%6.1f ttc_min=%5.1f replans=%d desvios=%d parado_max=%4.1f wp=%d/%d spawn=(%.0f,%.0f) seed=%d" % [
		fase_nome, "PARKED" if est == 3 else "NOT_PARKED", linha.t, linha.cte_medio,
		linha.cte_p95, linha.sat_pct, linha.folga_min, linha.ttc_min, replans,
		desvios, linha.parado_max, wp, n_wp, spawn.x, spawn.y, _seed])
	root.remove_child(cena)
	cena.queue_free()
	await process_frame
	return linha


## Folga do CASCO ate o obstaculo mais proximo na layer 2: 16 pontos do
## perimetro do retangulo do carro (ja escalado), cada um sondado para FORA
## (do centro do carro atraves do ponto). E' o que diz se o carro passou
## raspando numa guia — e' o numero que o AGENTS #19 chama de "distancia do
## cone/concorrente ate a rota", medido no veiculo em vez de no roteiro.
func _folga_carro(carro: Node2D, espaco, varrido: float) -> float:
	var eixos := _meios_do_carro(carro)
	if eixos == Vector2.ZERO:
		return varrido
	var melhor := 1.0e9
	for k in range(16):
		# perimetro do retangio, 4 lados x 4 pontos, em ordem
		var t: float = float(k % 4) / 4.0
		var lado: int = k / 4
		var lx := -eixos.x + t * 2.0 * eixos.x
		var ly := -eixos.y + t * 2.0 * eixos.y
		match lado:
			0: ly = -eixos.y
			1: lx = eixos.x
			2: ly = eixos.y
			3: lx = -eixos.x
		var borda: Vector2 = carro.global_position + Vector2(lx, ly).rotated(carro.rotation)
		var fora: Vector2 = Vector2(lx, ly)
		if fora.length_squared() < 0.0001:
			continue
		melhor = minf(melhor, _sonda(borda, fora.normalized(), 600.0, espaco))
	return melhor


func _meios_do_carro(carro: Node2D) -> Vector2:
	var cs := carro.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null or not (cs.shape is RectangleShape2D):
		return Vector2.ZERO
	var rs: Vector2 = (cs.shape as RectangleShape2D).size * 0.5
	return Vector2(rs.x * absf(carro.global_scale.x), rs.y * absf(carro.global_scale.y))


func _sonda(de: Vector2, dir: Vector2, max_dist: float, espaco) -> float:
	if dir.length_squared() < 0.0001:
		return max_dist
	var q := PhysicsRayQueryParameters2D.create(de, de + dir.normalized() * max_dist)
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var r: Dictionary = espaco.intersect_ray(q)
	if r.is_empty():
		return max_dist
	return de.distance_to(r.get("position") as Vector2)


## Time-to-collision: menor (distancia do raio frontal / velocidade de
## aproximacao). A 0 = colisao agora. INF quando nenhum raio ve nada.
func _ttc(carro: Node2D, v: float) -> float:
	var melhor := INF
	for nome: String in SensorArrayRef.RAY_NAMES:
		var r := carro.get_node_or_null(nome) as RayCast2D
		if r == null or not r.is_colliding():
			continue
		var d: float = SensorArrayRef.distance_of(r)
		if not is_finite(d) or d <= 0.0:
			return 0.0
		if absf(v) > 1.0:
			melhor = minf(melhor, d / absf(v))
		else:
			melhor = minf(melhor, d / 60.0)
	return melhor


func _media(v: Array) -> float:
	if v.is_empty():
		return -1.0
	var s := 0.0
	for x in v:
		s += x
	return snappedf(s / v.size(), 0.1)


func _p95(v: Array) -> float:
	if v.is_empty():
		return -1.0
	var c := v.duplicate()
	c.sort()
	var i: int = clampi(int(ceil(0.95 * c.size())) - 1, 0, c.size() - 1)
	return snappedf(float(c[i]), 0.1)


## Regressao: menor e MELHOR para folga/ttc; maior e MELHOR para tempo, CTE e
## standstill. Comparacao com tolerancia relativa.
func _compara(antes: Dictionary, agora: Dictionary, chave: String, tol: float) -> Dictionary:
	if not antes.has(chave):
		return {"ok": true}
	var a: float = float(antes[chave])
	var b: float = float(agora[chave])
	if chave == "estado":
		return {"ok": a == b, "antes": a, "agora": b}
	if chave == "com_fallback":
		return {"ok": not (a < b), "antes": a, "agora": b}
	if chave == "replans" or chave == "desvios":
		# nao sao "pior quando sobem": sao o registro de que o piloto REAGE.
		return {"ok": true}
	if chave == "seed":
		# A seed e' o QUE ESTAMOS COMPARANDO. Duas seeds diferentes medem dois
		# boots diferentes, entao um placar obtido com outra seed nao pode ser a
		# referencia deste A/B — reprovar aqui atribuiria ao codigo uma diferenca
		# que veio do sorteio do spawn.
		return {"ok": a == b, "antes": a, "agora": b}
	if a < 0.0 or b < 0.0:
		return {"ok": true}
	var melhor_baixo: Array = ["cte_medio", "cte_p95", "sat_pct", "t", "parado_max"]
	var piores: Array = ["folga_min", "ttc_min"]
	var mais_alto_e_melhor: Array = ["folga_min", "ttc_min"]
	var alto_e_pior: Array = ["cte_medio", "cte_p95", "sat_pct", "t", "parado_max"]
	var limpo := piores.has(chave) or mais_alto_e_melhor.has(chave) \
		or alto_e_pior.has(chave) or melhor_baixo.has(chave)
	if not limpo:
		return {"ok": true}
	if mais_alto_e_melhor.has(chave):
		if b + 1.0 < a * (1.0 - tol):
			return {"ok": false, "antes": a, "agora": b}
		return {"ok": true}
	# menor e melhor: 10% de piora relativa (ou 2 px absolutos) reprova
	var limiar: float = maxf(2.0, absf(a) * tol)
	if b > a + limiar:
		return {"ok": false, "antes": a, "agora": b}
	return {"ok": true}


func _carregar(caminho: String) -> Dictionary:
	if caminho.is_empty() or not FileAccess.file_exists(caminho):
		return {}
	var j = JSON.parse_string(FileAccess.get_file_as_string(caminho))
	if j is Array:
		var d: Dictionary = {}
		for linha in (j as Array):
			d[str((linha as Dictionary).get("fase", ""))] = linha
		return d
	return j if j is Dictionary else {}


func _salvar(caminho: String, relatorio: Array) -> void:
	if caminho.is_empty():
		return
	var f := FileAccess.open(caminho, FileAccess.WRITE)
	if f == null:
		printerr("GATE_DRIVE: nao pode gravar " + caminho)
		return
	f.store_string(JSON.stringify(relatorio, "  "))
	f.close()
	print("GATE_DRIVE_JSON %s" % caminho)
