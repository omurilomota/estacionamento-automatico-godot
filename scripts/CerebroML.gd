extends RefCounted
## REDE NEURAL do carro (MLP treinada por imitação em ml/treinar.py).
## Forward-pass puro em GDScript: 18 entradas (sensores) -> 2 saídas
## (estercamento, velocidade). Pesos ficam em ml/modelo/pesos.json.
##
## Arquitetura: 18 -> 32 (tanh) -> 16 (tanh) -> 2 (linear)
## Usada via preload em Carro.gd (sem class_name para não depender do cache
## global de classes nas rodadas headless).

const CAMINHO_PADRAO := "res://ml/modelo/pesos.json"

var _w1: Array = []
var _b1: Array = []
var _w2: Array = []
var _b2: Array = []
var _w3: Array = []
var _b3: Array = []
var _x_mean: Array = []
var _x_std: Array = []
var carregado: bool = false


func carregar(caminho: String = CAMINHO_PADRAO) -> bool:
	if not FileAccess.file_exists(caminho):
		push_warning("CerebroML: modelo não encontrado em " + caminho)
		return false
	var j = JSON.parse_string(FileAccess.get_file_as_string(caminho))
	if j == null or not j.has("w1") or not j.has("x_mean"):
		push_warning("CerebroML: modelo inválido em " + caminho)
		return false
	_w1 = j["w1"]
	_b1 = j["b1"]
	_w2 = j["w2"]
	_b2 = j["b2"]
	_w3 = j["w3"]
	_b3 = j["b3"]
	_x_mean = j["x_mean"]
	_x_std = j["x_std"]
	carregado = true
	return true


func inferir(entradas: PackedFloat64Array) -> PackedFloat64Array:
	# Normaliza com a MESMA média/desvio usados no treino
	var x := PackedFloat64Array()
	x.resize(entradas.size())
	for i in entradas.size():
		var desvio: float = maxf(float(_x_std[i]), 1e-8)
		x[i] = (entradas[i] - float(_x_mean[i])) / desvio
	var h1 := _camada(x, _w1, _b1, true)
	var h2 := _camada(h1, _w2, _b2, true)
	return _camada(h2, _w3, _b3, false)


func _camada(entrada: PackedFloat64Array, w: Array, b: Array, ativa_tanh: bool) -> PackedFloat64Array:
	# w veio do numpy com shape (n_entradas, n_saidas): w[i][o]
	var saida := PackedFloat64Array()
	var n_out: int = (w[0] as Array).size()
	saida.resize(n_out)
	for o in n_out:
		var soma: float = float(b[o])
		for i in entrada.size():
			soma += entrada[i] * float((w[i] as Array)[o])
		saida[o] = tanh(soma) if ativa_tanh else soma
	return saida
