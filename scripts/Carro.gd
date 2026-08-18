extends CharacterBody2D
## O CÉREBRO DO CARRO — Máquina de Estados (FSM).
## O carro nunca age "por script fixo": ele decide em tempo real
## com base no que os sensores (RayCast2D) medem, igual um robô autônomo de verdade.

signal estado_mudou(nome: String)

enum Estado { BUSCANDO, DESVIANDO, ALINHANDO, ESTACIONADO }

# @export => aparece no Inspector. Ajuste sem abrir o código.
@export var velocidade_maxima: float = 220.0
@export var velocidade_desvio: float = 110.0
@export var velocidade_alinhamento: float = 70.0
@export var velocidade_giro: float = 3.2
@export var tolerancia_chegada: float = 24.0
@export var tolerancia_alinhamento: float = 0.03
@export var debug_sensores: bool = true

# @onready => pega referências aos nós filhos ANTES do _ready().
# Os 3 raios frontais formam um "leque": cobre a largura real do carro.
@onready var ray_frente_centro: RayCast2D = $RayFrenteCentro
@onready var ray_frente_esq: RayCast2D = $RayFrenteEsq
@onready var ray_frente_dir: RayCast2D = $RayFrenteDir
@onready var ray_esquerda: RayCast2D = $RayEsquerda
@onready var ray_direita: RayCast2D = $RayDireita

var estado: Estado = Estado.BUSCANDO
var waypoints: Array[Vector2] = []
var indice_waypoint: int = 0
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
	# Usado pela UI (Mundo.gd) para mostrar o que o sensor está lendo.
	if ray_frente_centro.is_colliding() or ray_frente_esq.is_colliding() or ray_frente_dir.is_colliding():
		return "Obstáculo à frente"
	if ray_esquerda.is_colliding():
		return "Obstáculo à esquerda"
	if ray_direita.is_colliding():
		return "Obstáculo à direita"
	return "Livre"


func _physics_process(delta: float) -> void:
	# Aula de física: o RayCast só recalcula durante o passo de física do OUTRO
	# frame. force_raycast_update() manda calcular AGORA, sem atraso de leitura.
	_atualizar_sensores()

	match estado:
		Estado.BUSCANDO:
			_processar_buscando(delta)
		Estado.DESVIANDO:
			_processar_desviando(delta)
		Estado.ALINHANDO:
			_processar_alinhando(delta)
		Estado.ESTACIONADO:
			velocity = Vector2.ZERO

	# move_and_slide() = "tenho uma velocidade, move e resolve colisões".
	move_and_slide()
	queue_redraw()


func _atualizar_sensores() -> void:
	var todos := [ray_frente_centro, ray_frente_esq, ray_frente_dir, ray_esquerda, ray_direita]
	for raio in todos:
		raio.force_raycast_update()


func _processar_buscando(delta: float) -> void:
	if waypoints.is_empty():
		velocity = Vector2.ZERO
		return

	# Se qualquer raio frontal mede algo a menos de 80px, hora de desviar.
	if distancia_frente() < 80.0:
		_mudar_estado(Estado.DESVIANDO)
		return

	var alvo: Vector2 = waypoints[indice_waypoint]
	# lerp_angle = "gira suavemente até o ângulo desejado" (sem virar instantâneo).
	rotation = lerp_angle(rotation, global_position.direction_to(alvo).angle(), velocidade_giro * delta)

	# Aula de vetores: fator de freio = distância até o obstáculo.
	# Quanto mais perto, mais devagar => o sensor "mede", o carro reage.
	var fator_freio: float = clampf(distancia_frente() / 140.0, 0.3, 1.0)
	velocity = transform.x * velocidade_maxima * fator_freio

	# Chegou perto o suficiente do waypoint? Avança para o próximo.
	if global_position.distance_to(alvo) < tolerancia_chegada:
		indice_waypoint = mini(indice_waypoint + 1, waypoints.size() - 1)


func _processar_desviando(delta: float) -> void:
	# Melhoria: a direção é reavaliada TODO FRAME (não só quando entrou no desvio).
	# Vira para o lado que o sensor mede com MAIS espaço livre.
	rotation += _lado_com_mais_espaco() * velocidade_giro * delta

	# Reduz a velocidade perto do obstáculo para conseguir curvar mais fechado.
	var fator: float = clampf(distancia_frente() / 100.0, 0.3, 1.0)
	velocity = transform.x * velocidade_desvio * fator

	# Só volta a buscar quando o caminho está livre E o carro já está
	# apontando pro waypoint. Isso acaba com a oscilação (zigue-zague).
	if _caminho_livre() and _quase_apontando_ao_waypoint():
		_mudar_estado(Estado.BUSCANDO)


func _processar_alinhando(delta: float) -> void:
	# Estacionamento: primeiro se aproxima da vaga (curva), depois gira até a
	# rotação certa da vaga e entra de ré/frente até o centro.
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


# --- LÓGICA DOS SENSORES (o "radar") -------------------------------------

func distancia_frente() -> float:
	# Menor distância medida pelos 3 raios frontais. INF = nada colidindo.
	var menor: float = INF
	for raio in [ray_frente_centro, ray_frente_esq, ray_frente_dir]:
		menor = minf(menor, _distancia_do_raio(raio))
	return menor


func _distancia_do_raio(raio: RayCast2D) -> float:
	if not raio.is_colliding():
		return INF
	# get_collision_point() devolve ONDE o raio bateu (posição global).
	return raio.global_position.distance_to(raio.get_collision_point())


func _lado_com_mais_espaco() -> int:
	# Mede folga nos dois lados e escolhe o maior. -1 = esquerda, 1 = direita.
	var espaco_esq: float = _distancia_do_raio(ray_esquerda)
	var espaco_dir: float = _distancia_do_raio(ray_direita)
	return -1 if espaco_esq >= espaco_dir else 1


func _caminho_livre() -> bool:
	return distancia_frente() == INF


func _quase_apontando_ao_waypoint() -> bool:
	if waypoints.is_empty():
		return true
	var alvo: Vector2 = waypoints[indice_waypoint]
	var angulo_erro: float = absf(angle_difference(rotation, global_position.direction_to(alvo).angle()))
	return angulo_erro < 0.7


func _mudar_estado(novo: Estado) -> void:
	if novo == estado:
		return
	estado = novo
	estado_mudou.emit(nome_estado())


# --- VISUALIZAÇÃO (desenha os sensores na tela) ---------------------------

func _draw() -> void:
	if ray_frente_centro == null:
		return
	var cor_livre := Color(1, 1, 1, 0.25)
	var cor_obstaculo := Color(1, 0.12, 0.12, 0.9)
	for raio in [ray_frente_centro, ray_frente_esq, ray_frente_dir, ray_esquerda, ray_direita]:
		_desenhar_raio(raio, cor_livre, cor_obstaculo)


func _desenhar_raio(raio: RayCast2D, cor_livre: Color, cor_obstaculo: Color) -> void:
	var origem: Vector2 = raio.position
	var fim: Vector2 = raio.position + raio.target_position
	var cor: Color = cor_obstaculo if raio.is_colliding() else cor_livre
	draw_line(origem, fim, cor, 3.0)
	if debug_sensores and raio.is_colliding():
		# Bolinha laranja no ponto exato do impacto (visão de "radar").
		var ponto: Vector2 = to_local(raio.get_collision_point())
		draw_circle(ponto, 4.0, Color(1, 0.5, 0, 0.9))