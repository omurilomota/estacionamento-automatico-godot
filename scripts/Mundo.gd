extends Node2D

const NOMES_ESTADO := {
	"BUSCANDO": "Buscando vaga",
	"DESVIANDO": "Desviando de obstáculo!",
	"ALINHANDO": "Alinhando para estacionar",
	"ESTACIONADO": "Estacionado!",
	"RECUPERANDO": "Recuperando...",
}

const FASES := [
	"res://scenes/fases/Fase1.tscn",
	"res://scenes/fases/Fase2.tscn",
	"res://scenes/fases/Fase3.tscn",
]

# Sorteia uma posição de partida para o carro (nunca em cima de uma vaga).
@export var posicao_aleatoria: bool = true

@onready var carro: Node2D = $Carro
@onready var waypoints: Node2D = $Waypoints
@onready var vagas: Node2D = $Vagas
@onready var planejador: Node2D = $Planejador
@onready var label_status: Label = $UI/Control/StatusLabel
@onready var label_sensor: Label = $UI/Control/SensorLabel
@onready var label_tentativa: Label = $UI/Control/TentativaLabel

var _posicionar_pendente: bool = true


func _ready() -> void:
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


func _physics_process(_delta: float) -> void:
	# Sorteia a posição no PRIMEIRO frame de física (obstáculos já estão no
	# mundo). Como o pai processa ANTES do filho, o carro nasce na posição
	# sorteada e só então o Planejador traça a rota a partir dali.
	if _posicionar_pendente:
		_posicionar_pendente = false
		if posicao_aleatoria:
			_posicionar_carro_aleatorio()


func _posicionar_carro_aleatorio() -> void:
	if planejador == null:
		return
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
	label_sensor.text = "SENSOR: " + carro.descricao_sensor()


func _unhandled_input(event: InputEvent) -> void:
	# 1/2/3 trocam para as fases com os mapas reais; R reinicia o demo.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_3:
			get_tree().change_scene_to_file(FASES[event.keycode - KEY_1])
		elif event.keycode == KEY_R:
			get_tree().reload_current_scene()


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