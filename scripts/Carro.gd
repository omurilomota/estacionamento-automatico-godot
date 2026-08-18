extends CharacterBody2D

signal estado_mudou(nome: String)

enum Estado { BUSCANDO, DESVIANDO, ALINHANDO, ESTACIONADO }

@export var velocidade_maxima: float = 220.0
@export var velocidade_desvio: float = 110.0
@export var velocidade_alinhamento: float = 70.0
@export var velocidade_giro: float = 3.2
@export var tolerancia_chegada: float = 24.0
@export var tolerancia_alinhamento: float = 0.03

@onready var ray_frente: RayCast2D = $RayFrente
@onready var ray_esquerda: RayCast2D = $RayEsquerda
@onready var ray_direita: RayCast2D = $RayDireita

var estado: Estado = Estado.BUSCANDO
var waypoints: Array[Vector2] = []
var indice_waypoint: int = 0
var direcao_desvio: int = 1
var rotacao_alvo: float = 0.0
var posicao_alvo: Vector2 = Vector2.ZERO


func definir_waypoints(pontos: Array) -> void:
	waypoints.clear()
	for ponto in pontos:
		waypoints.append(ponto)
	indice_waypoint = 0


func entrar_estado_alinhando(rotacao_da_vaga: float, posicao_da_vaga: Vector2) -> void:
	rotacao_alvo = rotacao_da_vaga
	posicao_alvo = posicao_da_vaga
	_mudar_estado(Estado.ALINHANDO)


func nome_estado() -> String:
	match estado:
		Estado.BUSCANDO:
			return "BUSCANDO"
		Estado.DESVIANDO:
			return "DESVIANDO"
		Estado.ALINHANDO:
			return "ALINHANDO"
		Estado.ESTACIONADO:
			return "ESTACIONADO"
		_:
			return "DESCONHECIDO"


func descricao_sensor() -> String:
	if ray_frente.is_colliding():
		return "Obstáculo à frente"
	if ray_esquerda.is_colliding():
		return "Obstáculo à esquerda"
	if ray_direita.is_colliding():
		return "Obstáculo à direita"
	return "Livre"


func _physics_process(delta: float) -> void:
	match estado:
		Estado.BUSCANDO:
			_processar_buscando(delta)
		Estado.DESVIANDO:
			_processar_desviando(delta)
		Estado.ALINHANDO:
			_processar_alinhando(delta)
		Estado.ESTACIONADO:
			velocity = Vector2.ZERO
	move_and_slide()
	queue_redraw()


func _processar_buscando(delta: float) -> void:
	if waypoints.is_empty():
		velocity = Vector2.ZERO
		return
	if ray_frente.is_colliding():
		direcao_desvio = _escolher_direcao_desvio()
		_mudar_estado(Estado.DESVIANDO)
		return
	var alvo: Vector2 = waypoints[indice_waypoint]
	var angulo_desejado: float = global_position.direction_to(alvo).angle()
	rotation = lerp_angle(rotation, angulo_desejado, velocidade_giro * delta)
	velocity = transform.x * velocidade_maxima
	if global_position.distance_to(alvo) < tolerancia_chegada:
		indice_waypoint = mini(indice_waypoint + 1, waypoints.size() - 1)


func _processar_desviando(delta: float) -> void:
	rotation += direcao_desvio * velocidade_giro * delta
	velocity = transform.x * velocidade_desvio
	if not ray_frente.is_colliding():
		_mudar_estado(Estado.BUSCANDO)


func _processar_alinhando(delta: float) -> void:
	var distancia: float = global_position.distance_to(posicao_alvo)
	var angulo_para_alvo: float = global_position.direction_to(posicao_alvo).angle()
	if distancia > tolerancia_chegada * 2.0:
		rotation = lerp_angle(rotation, angulo_para_alvo, velocidade_giro * delta)
		velocity = transform.x * velocidade_alinhamento
	else:
		rotation = lerp_angle(rotation, rotacao_alvo, velocidade_giro * delta)
		var alinhado: bool = absf(angle_difference(rotation, rotacao_alvo)) < tolerancia_alinhamento
		velocity = transform.x * (velocidade_alinhamento if alinhado else velocidade_alinhamento * 0.4)
	if distancia < 10.0 and absf(angle_difference(rotation, rotacao_alvo)) < tolerancia_alinhamento:
		_mudar_estado(Estado.ESTACIONADO)


func _escolher_direcao_desvio() -> int:
	if not ray_esquerda.is_colliding():
		return -1
	if not ray_direita.is_colliding():
		return 1
	return 1


func _mudar_estado(novo: Estado) -> void:
	if novo == estado:
		return
	estado = novo
	estado_mudou.emit(nome_estado())


func _draw() -> void:
	if ray_frente == null:
		return
	var cor_livre := Color(1, 1, 1, 0.25)
	var cor_obstaculo := Color(1, 0.12, 0.12, 0.9)
	_desenhar_raio(ray_frente, cor_livre, cor_obstaculo)
	_desenhar_raio(ray_esquerda, cor_livre, cor_obstaculo)
	_desenhar_raio(ray_direita, cor_livre, cor_obstaculo)


func _desenhar_raio(raio: RayCast2D, cor_livre: Color, cor_obstaculo: Color) -> void:
	var origem: Vector2 = raio.position
	var fim: Vector2 = raio.position + raio.target_position
	var cor: Color = cor_obstaculo if raio.is_colliding() else cor_livre
	draw_line(origem, fim, cor, 3.0)