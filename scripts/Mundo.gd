extends Node2D

# Regras compartilhadas vêm de uma única fonte: scripts/Fases.gd (class_name Fases).
# Renomear nós ou rotas nas cenas não quebra este script — a ordem das rotas
# é obtida dinamicamente dentro de Carro.gd a partir da ordem dos filhos no nó Rotas.

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
	label_status.text = "STATUS: " + Fases.NOMES_ESTADO.get(carro.nome_estado(), carro.nome_estado())
	label_sensor.text = "SENSOR: " + carro.get_sensor_text()
	label_tentativa.text = "TENTATIVA: 0"


func _physics_process(_delta: float) -> void:
	if _posicionar_pendente:
		_posicionar_pendente = false
		if posicao_aleatoria:
			_posicionar_carro_aleatorio()


func _posicionar_carro_aleatorio() -> void:
	if planejador == null:
		return
	if not planejador.grade_pronta():
		planejador.construir()
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
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_5:
			get_tree().change_scene_to_file(Fases.FASES[event.keycode - KEY_1])
		elif event.keycode == KEY_R:
			get_tree().reload_current_scene()


func _ao_mudar_estado(nome: String) -> void:
	if "modo_trilha" in carro and carro.modo_trilha and nome == "DESVIANDO":
		label_status.text = "STATUS: Parado (obstáculo à frente)"
	else:
		label_status.text = "STATUS: " + Fases.NOMES_ESTADO.get(nome, nome)


func _coletar_pontos_rotas() -> Array:
	return Fases.coletar_pontos_rotas(get_node_or_null("Rotas"), carro.global_position, vagas)


func _ao_mudar_tentativa(tentativas: int, estrategia: String) -> void:
	label_tentativa.text = "TENTATIVA: %d — %s" % [tentativas, estrategia]


func _ao_pedir_nova_vaga() -> void:
	if carro.auto_navegacao:
		return
	for vaga in vagas.get_children():
		if not vaga.ocupada:
			label_tentativa.text = "TENTATIVA: 0 — Procurando outra vaga"
			carro.definir_waypoints([vaga.global_position])
			return
	label_status.text = "STATUS: Sem vagas livres"