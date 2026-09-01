extends Node2D
## FASE BASE — esqueleto de cada mapa (fase) do estacionamento.
## Cobre o mapa, cria a câmera que segue o carro, paredes no perímetro
## e a mesma UI de status/sensores/tentativas da cena de demonstração.
## Teclas: 1/2/3/4/5 trocam de fase, R reinicia a fase atual.

const FASES := [
	"res://scenes/fases/Fase1.tscn",
	"res://scenes/fases/Fase2.tscn",
	"res://scenes/fases/Fase3.tscn",
	"res://scenes/fases/Fase4.tscn",
	"res://scenes/fases/Fase5.tscn",
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
# Sorteia uma posição de partida para o carro (nunca em cima de uma vaga).
@export var posicao_aleatoria: bool = true

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

var _posicionar_pendente: bool = true


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
	# MODO TRILHA (automático): todas as fases seguem linha pré-calculada A* + fallback Line2D
	if "modo_trilha" in carro and carro.modo_trilha:
		if carro.has_method("iniciar_modo_trilha"):
			carro.iniciar_modo_trilha()
		else:
			carro.iniciar_navegacao()
	elif carro.auto_navegacao:
		# Modo inteligente legado (A*).
		carro.iniciar_navegacao()
	else:
		# Modo manual: tenta usar Rotas Line2D como trilha, senão waypoints
		var rota_fb: Array = _coletar_pontos_rotas()
		if not rota_fb.is_empty() and "modo_trilha" in carro and carro.modo_trilha:
			carro.definir_trilha(rota_fb)
		elif not rota_fb.is_empty():
			carro.definir_waypoints(rota_fb)
		else:
			carro.definir_waypoints(pontos)
	carro.estado_mudou.connect(_ao_mudar_estado)
	carro.tentativa_mudou.connect(_ao_mudar_tentativa)
	carro.pedir_nova_vaga.connect(_ao_pedir_nova_vaga)
	label_status.text = "STATUS: " + NOMES_ESTADO.get(carro.nome_estado(), carro.nome_estado())
	label_sensor.text = "SENSOR: " + carro.get_sensor_text()
	label_tentativa.text = "TENTATIVA: 0"


func _physics_process(_delta: float) -> void:
	# Sorteia a posição no PRIMEIRO frame de física (obstáculos já estão no
	# mundo). Como o pai processa ANTES do filho, o carro nasce na posição
	# sorteada e só então o Planejador traça a rota a partir dali.
	if _posicionar_pendente:
		_posicionar_pendente = false
		if posicao_aleatoria:
			_posicionar_carro_aleatorio()


func _posicionar_carro_aleatorio() -> void:
	if not planejador.grade_pronta():
		planejador.construir()
	# Proíbe nascer dentro (ou encostado) em qualquer vaga.
	var proibidos: Array[Rect2] = []
	for vaga in vagas.get_children():
		var forma: RectangleShape2D = vaga.get_node("Area").shape
		proibidos.append(Rect2(vaga.global_position - forma.size * 0.5, forma.size).grow(50.0))
	var posicao: Vector2 = planejador.achar_posicao_livre(proibidos)
	if posicao == Vector2.INF:
		return
	carro.global_position = posicao
	carro.rotation = 0.0


func _process(_delta: float) -> void:
	label_sensor.text = "SENSOR: " + carro.get_sensor_text()
	_seguir_carro()


func _unhandled_input(event: InputEvent) -> void:
	# Teclas de teste: 1/2/3/4 trocam de fase, R reinicia a atual.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_5:
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
	# Em modo trilha, DESVIANDO significa "parado por obstáculo"
	if "modo_trilha" in carro and carro.modo_trilha and nome == "DESVIANDO":
		label_status.text = "STATUS: Parado (obstáculo à frente)"
	else:
		label_status.text = "STATUS: " + NOMES_ESTADO.get(nome, nome)


func _coletar_pontos_rotas() -> Array:
	var rotas_node := get_node_or_null("Rotas")
	if rotas_node == null:
		return []
	var melhor: Array = []
	var melhor_score: float = INF
	# Para cada Line2D, avalia proximidade ao carro e às vagas
	var alvo_vaga: Vector2 = Vector2.INF
	if vagas.get_child_count() > 0:
		for v in vagas.get_children():
			if not v.ocupada:
				alvo_vaga = v.global_position
				break
		if alvo_vaga == Vector2.INF:
			alvo_vaga = vagas.get_child(0).global_position
	for child in rotas_node.get_children():
		if not child is Line2D:
			continue
		var pts: PackedVector2Array = child.points
		if pts.size() < 2:
			continue
		var glob: Array = []
		for p in pts:
			glob.append(child.to_global(p))
		# Score: distância do carro ao início + distância fim à vaga
		var d_ini: float = carro.global_position.distance_to(glob[0]) if glob.size() > 0 else INF
		var d_fim: float = alvo_vaga.distance_to(glob[glob.size() - 1]) if glob.size() > 0 and alvo_vaga != Vector2.INF else INF
		var score: float = d_ini * 0.6 + d_fim * 0.4
		if score < melhor_score:
			melhor_score = score
			melhor = glob
	if not melhor.is_empty():
		return melhor
	# Se nenhuma linha é boa, concatena todas as linhas em ordem
	var todas: Array = []
	for child in rotas_node.get_children():
		if child is Line2D:
			for p in child.points:
				todas.append(child.to_global(p))
	return todas


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