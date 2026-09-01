extends Area2D
# Seta preferencial de fluxo — não bloqueia, só dá peso ao A*
@export var direcao: float = 0.0 # rad, 0=leste, 1.57=sul, -1.57=norte, 3.14=oeste
@export var preferencia: float = 0.7 # custo quando alinhado
@export var penalidade: float = 1.4 # custo quando contra

func _ready() -> void:
	rotation = direcao
