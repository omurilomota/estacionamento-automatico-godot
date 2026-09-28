class_name NeuralBrain
extends "res://scripts/CerebroML.gd"
## English facade over legacy CerebroML (MLP 18-32-16-2, GDScript).
## `load_model()` / `predict()` replace PT-BR `carregar()` / `inferir()`;
## `is_loaded` replaces `carregado`. Weights format unchanged.

var is_loaded: bool:
	get:
		return carregado
	set(value):
		carregado = value


func load_model(path: String = CAMINHO_PADRAO) -> bool:
	return carregar(path)


func predict(inputs: PackedFloat64Array) -> PackedFloat64Array:
	return inferir(inputs)
