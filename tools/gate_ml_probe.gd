extends SceneTree
## GATE 5 (lado A) — a rede do JOGO rodando num vetor fixo de 22 entradas.
##
## Preloada scripts/CerebroML.gd (o cerebro que a engine carrega) e imprime as
## duas saidas com 12 casas. O lado B e' `tools/gate_ml_probe.js`, que roda o
## MESMO site/js/ml.js que o navegador carrega. Se os dois divergirem alem de
## 1e-6, a matematica do site deixou de ser a do jogo.
##
## Uso: godot --headless --path . --script tools/gate_ml_probe.gd

const CerebroMLRef = preload("res://scripts/CerebroML.gd")
const VETOR := "res://tools/ml_probe_vector.json"
const PESOS := "res://ml/modelo/pesos.json"


func _init() -> void:
	var bruto := FileAccess.get_file_as_string(VETOR)
	var vals = JSON.parse_string(bruto)
	if vals == null or (vals as Array).size() != 22:
		printerr("GATE_ML: vetor invalido em " + VETOR)
		quit(1)
		return
	var entrada := PackedFloat64Array()
	for v in vals:
		entrada.append(float(v))
	var rede := CerebroMLRef.new()
	if not rede.carregar(PESOS):
		printerr("GATE_ML: CerebroML nao carregou " + PESOS)
		quit(1)
		return
	var out: PackedFloat64Array = rede.inferir(entrada)
	var campos := PackedStringArray()
	for v in entrada:
		campos.append("%.4f" % v)
	print("VETOR    = " + ", ".join(campos))
	print("GODOT_ESTERCAMENTO = %.12f" % out[0])
	print("GODOT_VELOCIDADE   = %.12f" % out[1])
	quit(0)
