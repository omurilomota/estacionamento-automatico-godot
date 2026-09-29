extends Area2D

## Boca da vaga em ESPAÇO GLOBAL (AGENTS #17): na vaga base (90x120, escala 1)
## o design original é 74 px do centro (45 de meia-profundidade + 29 de margem)
## com 28 de espessura. Níveis escalados não podem esticar a banda.
const MARGEM_BOCA_WORLD := 29.0
const ESPESSURA_BOCA_WORLD := 28.0

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
var _forma_boca_propria := false


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
	# Boca fica na entrada da vaga, oposta ao nariz — âncora em espaço global:
	# meia-profundidade ESCALADA da baia + margem fixa (29 px) fora da entrada.
	var nariz_no_x := absf(dir.x) >= absf(dir.y)
	var meia_profundidade := 45.0 * absf(scale.x) if nariz_no_x else 60.0 * absf(scale.y)
	var offset_world := -dir * (meia_profundidade + MARGEM_BOCA_WORLD)
	# Contra-escala: divide pelo scale do nó para o offset mundo ficar certo.
	colisao_boca.position = Vector2(offset_world.x / scale.x, offset_world.y / scale.y)
	# O retângulo do .tscn é compartilhado por TODAS as instâncias: cópia
	# própria para redimensionar sem vazar para as irmãs.
	if colisao_boca.shape != null and not _forma_boca_propria:
		colisao_boca.shape = colisao_boca.shape.duplicate()
		_forma_boca_propria = true
	var forma := colisao_boca.shape as RectangleShape2D
	if forma != null:
		# Espessura fixa no mundo (28 px) no eixo de aproximação; largura
		# proporcional (28 locais) atravessado, como a fresta do design base.
		if nariz_no_x:
			forma.size = Vector2(ESPESSURA_BOCA_WORLD / scale.x, 28.0)
		else:
			forma.size = Vector2(28.0, ESPESSURA_BOCA_WORLD / scale.y)
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
