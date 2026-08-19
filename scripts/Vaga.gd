extends Area2D

@export var rotacao_alvo: float = 0.0
@export var cor_livre: Color = Color(0.25, 0.9, 0.35)
@export var cor_ocupada: Color = Color(0.95, 0.3, 0.3)

@onready var contorno: Polygon2D = $Contorno
@onready var fundo: Polygon2D = $Fundo

var ocupada: bool = false


func _ready() -> void:
	body_entered.connect(_ao_corpo_entrar)


func _ao_corpo_entrar(corpo: Node2D) -> void:
	if ocupada:
		return
	if corpo.has_method("entrar_estado_alinhando"):
		ocupada = true
		contorno.default_color = cor_ocupada
		fundo.color = Color(cor_ocupada, 0.15)
		corpo.entrar_estado_alinhando(rotacao_alvo, global_position)