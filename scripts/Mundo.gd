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
	"res://scenes/fases/Fase4.tscn",
	"res://scenes/fases/Fase5.tscn",
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
	if "modo_trilha" in carro and carro.modo_trilha:
		if carro.has_method("iniciar_modo_trilha"):
			carro.iniciar_modo_trilha()
		else:
			carro.iniciar_navegacao()
	elif carro.auto_navegacao:
		carro.iniciar_navegacao()
	else:
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
	label_sensor.text = "SENSOR: " + carro.get_sensor_text()


func _unhandled_input(event: InputEvent) -> void:
	# 1/2/3/4 trocam para as fases com os mapas reais; R reinicia o demo.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_5:
			get_tree().change_scene_to_file(FASES[event.keycode - KEY_1])
		elif event.keycode == KEY_R:
			get_tree().reload_current_scene()


func _ao_mudar_estado(nome: String) -> void:
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
		var d_ini: float = carro.global_position.distance_to(glob[0]) if glob.size() > 0 else INF
		var d_fim: float = alvo_vaga.distance_to(glob[glob.size() - 1]) if glob.size() > 0 and alvo_vaga != Vector2.INF else INF
		var score: float = d_ini * 0.6 + d_fim * 0.4
		if score < melhor_score:
			melhor_score = score
			melhor = glob
	if not melhor.is_empty():
		return melhor
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