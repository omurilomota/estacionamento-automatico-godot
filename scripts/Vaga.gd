extends Area2D

@export var rotacao_alvo: float = 0.0:
	set(v):
		rotacao_alvo = v
		_atualizar_boca_pos()
@export var cor_livre: Color = Color(0.25, 0.9, 0.35)
@export var cor_ocupada: Color = Color(0.95, 0.3, 0.3)

@onready var contorno: Line2D = $Contorno
@onready var fundo: Polygon2D = $Fundo
@onready var boca: Area2D = $Boca
@onready var colisao_boca: CollisionShape2D = $Boca/ColisaoBoca

var ocupada: bool = false


func _ready() -> void:
	_atualizar_boca_pos()
	body_entered.connect(_ao_corpo_entrar)
	if boca != null:
		boca.body_entered.connect(_ao_boca_entrar)


func _atualizar_boca_pos() -> void:
	if colisao_boca == null:
		# Ainda não está pronto (setter chamado antes de _ready)
		return
	var dir := Vector2.RIGHT.rotated(rotacao_alvo)
	# Boca fica na entrada da vaga, oposta ao nariz
	colisao_boca.position = -dir * 74.0
	# Desenha boca semi-transparente para debug (opcional, invisível em jogo)
	boca.visible = true


func _ao_boca_entrar(corpo: Node2D) -> void:
	if ocupada:
		return
	if corpo.has_method("_esta_100_dentro_da_vaga") and corpo._esta_100_dentro_da_vaga():
		return
	if corpo.has_method("preparar_estacionamento"):
		corpo.preparar_estacionamento(rotacao_alvo, global_position)


func marcar_ocupada() -> void:
	if ocupada:
		return
	ocupada = true
	contorno.default_color = cor_ocupada
	fundo.color = Color(cor_ocupada, 0.15)


func _ao_corpo_entrar(corpo: Node2D) -> void:
	if ocupada:
		return
	if corpo.has_method("entrar_estado_alinhando"):
		# Não marca ocupada ainda — só 100% dentro vira ocupada (humano)
		corpo.entrar_estado_alinhando(rotacao_alvo, global_position)
