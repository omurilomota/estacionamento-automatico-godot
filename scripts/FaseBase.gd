extends Node2D
## FASE BASE — esqueleto de cada mapa (fase) do estacionamento.
## Cobre o mapa, cria a câmera que segue o carro, paredes no perímetro
## e a mesma UI de status/sensores/tentativas da cena de demonstração.
## Teclas: 1/2/3 trocam de fase, R reinicia a fase atual.

const FASES := [
	"res://scenes/fases/Fase1.tscn",
	"res://scenes/fases/Fase2.tscn",
	"res://scenes/fases/Fase3.tscn",
]

const NOMES_ESTADO := {
	"BUSCANDO": "Buscando vaga",
	"DESVIANDO": "Desviando de obstáculo!",
	"ALINHANDO": "Alinhando para estacionar",
	"ESTACIONADO": "Estacionado!",
	"RECUPERANDO": "Recuperando...",
}

# Qual imagem usar como chão da fase e em quanto ampliar (no mundo).
@export var mapa: Texture2D
@export var escala_mapa: float = 1.5
@export var zoom_camera: float = 0.8

@onready var sprite_mapa: Sprite2D = $Mapa
@onready var paredes: Node2D = $Paredes
@onready var carro: Node2D = $Carro
@onready var vagas: Node2D = $Vagas
@onready var waypoints: Node2D = $Waypoints
@onready var planejador: Node2D = $Planejador
@onready var camera: Camera2D = $Camera
@onready var minimapa: Control = $UI/Control/Minimapa
@onready var label_status: Label = $UI/Control/StatusLabel
@onready var label_sensor: Label = $UI/Control/SensorLabel
@onready var label_tentativa: Label = $UI/Control/TentativaLabel

# Tamanho do mundo em pixels (centrado na origem).
var largura_mundo: float = 1280.0
var altura_mundo: float = 720.0


func _ready() -> void:
	_configurar_mapa()
	_criar_paredes()
	_configurar_camera()

	# O minimapa acompanha o tamanho real do mundo (mapa * escala).
	minimapa.mundo_centro = Vector2.ZERO
	minimapa.mundo_tamanho = Vector2(largura_mundo, altura_mundo)

	# O planejador global cobre o mapa inteiro (grade de ocupação + A*).
	planejador.origem = Vector2(-largura_mundo / 2.0, -altura_mundo / 2.0)
	planejador.tamanho = Vector2(largura_mundo, altura_mundo)

	var pontos: Array = []
	for wp in waypoints.get_children():
		pontos.append(wp.global_position)
	if carro.auto_navegacao:
		# Modo inteligente: o próprio carro escolhe a vaga e planeja a rota (A*).
		carro.iniciar_navegacao()
	else:
		# Modo manual: usa os waypoints definidos na cena pelo professor.
		carro.definir_waypoints(pontos)
	carro.estado_mudou.connect(_ao_mudar_estado)
	carro.tentativa_mudou.connect(_ao_mudar_tentativa)
	carro.pedir_nova_vaga.connect(_ao_pedir_nova_vaga)
	label_status.text = "STATUS: " + NOMES_ESTADO.get(carro.nome_estado(), carro.nome_estado())
	label_sensor.text = "SENSOR: " + carro.descricao_sensor()
	label_tentativa.text = "TENTATIVA: 0"


func _process(_delta: float) -> void:
	label_sensor.text = "SENSOR: " + carro.descricao_sensor()
	_seguir_carro()


func _unhandled_input(event: InputEvent) -> void:
	# Teclas de teste: 1/2/3 trocam de fase, R reinicia a atual.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_3:
			var indice: int = event.keycode - KEY_1
			get_tree().change_scene_to_file(FASES[indice])
		elif event.keycode == KEY_R:
			get_tree().reload_current_scene()


func _configurar_mapa() -> void:
	if mapa == null:
		return
	sprite_mapa.texture = mapa
	sprite_mapa.scale = Vector2.ONE * escala_mapa
	largura_mundo = mapa.get_size().x * escala_mapa
	altura_mundo = mapa.get_size().y * escala_mapa

	# Fundo escuro atrás do mapa (para não "flutuar" no vazio).
	var fundo := Polygon2D.new()
	fundo.name = "FundoMundo"
	fundo.color = Color(0.08, 0.08, 0.08, 1)
	fundo.polygon = PackedVector2Array([
		Vector2(-largura_mundo / 2.0, -altura_mundo / 2.0),
		Vector2(largura_mundo / 2.0, -altura_mundo / 2.0),
		Vector2(largura_mundo / 2.0, altura_mundo / 2.0),
		Vector2(-largura_mundo / 2.0, altura_mundo / 2.0),
	])
	add_child(fundo)
	move_child(fundo, 0)


func _criar_paredes() -> void:
	# Perímetro automático: 4 retângulos logo fora da borda do mapa.
	var limite := StaticBody2D.new()
	limite.name = "LimiteAutomatico"
	limite.collision_layer = 2

	var metade := Vector2(largura_mundo / 2.0, altura_mundo / 2.0)
	var e := 80.0
	var paredes_dados := [
		[Vector2(0, -metade.y - e / 2.0), Vector2(largura_mundo + e * 2.0, e)],
		[Vector2(0, metade.y + e / 2.0), Vector2(largura_mundo + e * 2.0, e)],
		[Vector2(-metade.x - e / 2.0, 0), Vector2(e, altura_mundo + e * 2.0)],
		[Vector2(metade.x + e / 2.0, 0), Vector2(e, altura_mundo + e * 2.0)],
	]
	for dados in paredes_dados:
		var colisao := CollisionShape2D.new()
		var forma := RectangleShape2D.new()
		forma.size = dados[1]
		colisao.shape = forma
		colisao.position = dados[0]
		limite.add_child(colisao)

	paredes.add_child(limite)


func _configurar_camera() -> void:
	camera.make_current()
	camera.zoom = Vector2(zoom_camera, zoom_camera)
	camera.position = carro.global_position


func _seguir_carro() -> void:
	# Centraliza a câmera no carro, mas sem sair das bordas do mundo.
	var meio: Vector2 = get_viewport_rect().size * 0.5 / camera.zoom
	var metade: Vector2 = Vector2(largura_mundo, altura_mundo) * 0.5
	var pos: Vector2 = carro.global_position
	if largura_mundo > meio.x * 2.0:
		pos.x = clampf(pos.x, -metade.x + meio.x, metade.x - meio.x)
	else:
		pos.x = 0.0
	if altura_mundo > meio.y * 2.0:
		pos.y = clampf(pos.y, -metade.y + meio.y, metade.y - meio.y)
	else:
		pos.y = 0.0
	camera.position = pos


func _ao_mudar_estado(nome: String) -> void:
	label_status.text = "STATUS: " + NOMES_ESTADO.get(nome, nome)


func _ao_mudar_tentativa(tentativas: int, estrategia: String) -> void:
	label_tentativa.text = "TENTATIVA: %d — %s" % [tentativas, estrategia]


func _ao_pedir_nova_vaga() -> void:
	# No modo automático o próprio carro escolhe outra vaga (Planejador).
	if carro.auto_navegacao:
		return
	# Modo manual: escolhe a primeira vaga livre.
	for vaga in vagas.get_children():
		if not vaga.ocupada:
			label_tentativa.text = "TENTATIVA: 0 — Procurando outra vaga"
			carro.definir_waypoints([vaga.global_position])
			return
	label_status.text = "STATUS: Sem vagas livres"