extends CharacterBody2D
## O CÉREBRO DO CARRO — Máquina de Estados (FSM) com RECUPERAÇÃO.
## O movimento imita um motorista real:
##  - O volante (estercamento) vira aos poucos e o carro faz ARCO, não pivota.
##  - Acelera e freia com rampa (frenagem mais forte que aceleração).
##  - Desacelera em curva e PARA antes de encostar em qualquer obstáculo.
## Se não progride, ele conta tentativas e muda de estratégia (comportamento agêntico).

signal estado_mudou(nome: String)
signal tentativa_mudou(tentativas: int, estrategia: String)
signal pedir_nova_vaga

enum Estado { BUSCANDO, DESVIANDO, ALINHANDO, ESTACIONADO, RECUPERANDO }

# Velocidades (baixas = dirigindo com cuidado, como uma pessoa)
@export var velocidade_maxima: float = 150.0
@export var velocidade_desvio: float = 90.0
@export var velocidade_alinhamento: float = 55.0

# Modelo de direção (volante)
@export var aceleracao: float = 180.0
@export var frenagem: float = 320.0
@export var max_estercamento: float = 0.7
@export var taxa_estercamento: float = 2.5
@export var entre_eixos: float = 60.0

# Segurança: "proibido bater"
@export var distancia_seguranca: float = 40.0
@export var distancia_freio: float = 160.0

@export var tolerancia_chegada: float = 24.0
@export var tolerancia_alinhamento: float = 0.03
@export var debug_sensores: bool = true

# Comportamento agêntico (quando o carro fica "preso")
@export var limite_tempo_preso: float = 3.0
@export var limite_progresso: float = 40.0
@export var limite_oscilacao: int = 6
@export var max_tentativas_por_waypoint: int = 10
@export var tempo_re: float = 1.0
@export var distancia_waypoint_desvio: float = 160.0
@export var espaco_minimo_desvio: float = 70.0

# Nomes bonitos das 4 estratégias (mostrados na UI)
const ESTRATEGIAS := {
	0: "Manobra de três tempos",
	1: "Contornar o obstáculo",
	2: "Dar ré",
	3: "Desistir do waypoint",
}

# @onready => pega referências aos nós filhos ANTES do _ready().
# Os 3 raios frontais formam um "leque": cobre a largura real do carro.
@onready var ray_frente_centro: RayCast2D = $RayFrenteCentro
@onready var ray_frente_esq: RayCast2D = $RayFrenteEsq
@onready var ray_frente_dir: RayCast2D = $RayFrenteDir
@onready var ray_esquerda: RayCast2D = $RayEsquerda
@onready var ray_direita: RayCast2D = $RayDireita
@onready var ray_tras: RayCast2D = $RayTras

var estado: Estado = Estado.BUSCANDO
var waypoints: Array[Vector2] = []
var indice_waypoint: int = 0
var rotacao_alvo: float = 0.0
var posicao_alvo: Vector2 = Vector2.ZERO

# Direção e velocidade atuais (acumuladas com rampa, não "teleportam")
var estercamento: float = 0.0
var velocidade_atual: float = 0.0
var estercamento_alvo: float = 0.0
var velocidade_desejada: float = 0.0

# Monitoramento de progresso no waypoint atual
var tentativas: int = 0
var tempo_no_waypoint: float = 0.0
var distancia_inicio_waypoint: float = INF
var contador_oscilacao: int = 0
var tempo_ignorar_sensor: float = 0.0

# Estado da recuperação em andamento
var estrategia: int = 0
var fase_manobra: int = 0
var tempo_estrategia: float = 0.0
var vies_lado: int = 1


func definir_waypoints(pontos: Array) -> void:
	waypoints.clear()
	for ponto in pontos:
		waypoints.append(ponto)
	indice_waypoint = 0
	_resetar_tentativa()


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
		Estado.RECUPERANDO:
			return "RECUPERANDO"
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
	if ray_tras.is_colliding():
		return "Obstáculo atrás"
	return "Livre"


func _physics_process(delta: float) -> void:
	# O RayCast só recalcula durante o passo de física do OUTRO frame.
	# force_raycast_update() manda calcular AGORA, sem atraso de leitura.
	_atualizar_sensores()

	# "Graça" após uma recuperação: ignora o sensor por um instante
	# para o carro sair da posição antes de tentar desviar de novo.
	if tempo_ignorar_sensor > 0.0:
		tempo_ignorar_sensor -= delta

	match estado:
		Estado.BUSCANDO:
			_processar_buscando(delta)
		Estado.DESVIANDO:
			_processar_desviando(delta)
		Estado.ALINHANDO:
			_processar_alinhando(delta)
		Estado.ESTACIONADO:
			_processar_estacionado(delta)
		Estado.RECUPERANDO:
			_processar_recuperando(delta)

	queue_redraw()


func _atualizar_sensores() -> void:
	var todos := [ray_frente_centro, ray_frente_esq, ray_frente_dir, ray_esquerda, ray_direita, ray_tras]
	for raio in todos:
		raio.force_raycast_update()


# --- MOVIMENTO (a "física" de dirigir de verdade) -------------------------

func _aplicar_movimento(delta: float) -> void:
	# 1) O volante vira aos poucos (não instantâneo).
	estercamento = move_toward(estercamento, estercamento_alvo, taxa_estercamento * delta)
	# 2) Modelo de bicicleta: a rotação muda conforme o volante e a velocidade.
	#    tan() faz o arco ficar fechado quando o volante está muito virado.
	rotation += velocidade_atual / entre_eixos * tan(estercamento) * delta
	# 3) PROIBIDO BATER: indo pra frente, se o sensor está a menos de
	#    distancia_seguranca, a velocidade alvo vira zero (para de vez).
	if velocidade_desejada > 0.0 and distancia_frente() < distancia_seguranca:
		velocidade_desejada = 0.0
	# 4) Rampa de aceleração/frenagem: a velocidade muda aos poucos.
	#    Freia mais forte do que acelera (igual motorista de verdade).
	var variacao: float = (frenagem if velocidade_desejada < velocidade_atual else aceleracao) * delta
	velocidade_atual = move_toward(velocidade_atual, velocidade_desejada, variacao)
	velocity = transform.x * velocidade_atual
	move_and_slide()


func _velocidade_por_sensor() -> float:
	# Converte a leitura do sensor frontal em velocidade alvo.
	# Longe => rápida. Na bolha de segurança => parada.
	var dist: float = distancia_frente()
	if dist == INF:
		return velocidade_maxima
	if dist <= distancia_seguranca:
		return 0.0
	return clampf((dist - distancia_seguranca) / (distancia_freio - distancia_seguranca), 0.0, 1.0) * velocidade_maxima


func _velocidade_reversa() -> float:
	# Igual à de cima, mas para o sensor TRASEIRO (usada ao dar ré).
	var dist: float = distancia_tras()
	if dist == INF:
		return velocidade_alinhamento
	if dist <= distancia_seguranca:
		return 0.0
	return clampf((dist - distancia_seguranca) / (distancia_freio - distancia_seguranca), 0.0, 1.0) * velocidade_alinhamento


# --- ESTADOS -------------------------------------------------------------

func _processar_buscando(delta: float) -> void:
	if waypoints.is_empty():
		estercamento_alvo = 0.0
		velocidade_desejada = 0.0
		_aplicar_movimento(delta)
		return

	_atualizar_progresso(delta)
	if _detectar_travamento():
		_iniciar_recuperacao()
		return

	# Se qualquer raio frontal mede algo a menos de 90px, hora de desviar.
	# (pulado durante a "graça" da recuperação)
	if tempo_ignorar_sensor <= 0.0 and distancia_frente() < 90.0:
		_mudar_estado(Estado.DESVIANDO)
		return

	# Aponta o volante para o waypoint. O arco surge sozinho do modelo.
	var alvo: Vector2 = waypoints[indice_waypoint]
	var angulo_erro: float = angle_difference(rotation, global_position.direction_to(alvo).angle())
	estercamento_alvo = clampf(angulo_erro * 2.0, -max_estercamento, max_estercamento)

	# Motorista real freia em curva: quanto mais virado o volante, mais devagar.
	var fator_curva: float = 1.0 - minf(absf(angulo_erro) / max_estercamento, 1.0) * 0.5
	velocidade_desejada = _velocidade_por_sensor() * fator_curva

	_aplicar_movimento(delta)

	# Chegou perto o suficiente do waypoint? Avança para o próximo.
	if global_position.distance_to(alvo) < tolerancia_chegada:
		_chegou_no_waypoint()


func _processar_desviando(delta: float) -> void:
	_atualizar_progresso(delta)
	if _detectar_travamento():
		_iniciar_recuperacao()
		return

	# Sem espaço nos DOIS lados? Não dá para desviar virando: faz
	# a manobra de três tempos em vez de ficar oscilando (zigue-zague).
	if _espaco_insuficiente():
		_iniciar_recuperacao()
		return

	# Vira o volante para o lado com MAIS espaço (reavaliado todo frame).
	var lado: int = _lado_com_mais_espaco()
	estercamento_alvo = lado * max_estercamento
	var fator: float = clampf(distancia_frente() / 100.0, 0.3, 1.0)
	velocidade_desejada = velocidade_desvio * fator
	_aplicar_movimento(delta)

	# Só volta a buscar quando o caminho está livre E o carro já está
	# apontando pro waypoint (acaba com a oscilação).
	if _caminho_livre() and _quase_apontando_ao_waypoint():
		_mudar_estado(Estado.BUSCANDO)


func _processar_alinhando(delta: float) -> void:
	# Estacionamento: primeiro se aproxima da vaga (curva), depois gira até a
	# rotação certa e entra devagar até o centro.
	var distancia: float = global_position.distance_to(posicao_alvo)
	if distancia > tolerancia_chegada * 2.0:
		var angulo: float = global_position.direction_to(posicao_alvo).angle()
		estercamento_alvo = clampf(angle_difference(rotation, angulo) * 2.0, -max_estercamento, max_estercamento)
		velocidade_desejada = _velocidade_por_sensor() * (velocidade_alinhamento / velocidade_maxima)
	else:
		var erro: float = angle_difference(rotation, rotacao_alvo)
		estercamento_alvo = clampf(erro * 2.0, -max_estercamento, max_estercamento)
		var alinhado: bool = absf(erro) < tolerancia_alinhamento
		velocidade_desejada = velocidade_alinhamento if alinhado else velocidade_alinhamento * 0.3

	_aplicar_movimento(delta)

	if distancia < 10.0 and absf(angle_difference(rotation, rotacao_alvo)) < tolerancia_alinhamento:
		_mudar_estado(Estado.ESTACIONADO)


func _processar_estacionado(delta: float) -> void:
	estercamento_alvo = 0.0
	velocidade_desejada = 0.0
	_aplicar_movimento(delta)


func _processar_recuperando(delta: float) -> void:
	match estrategia:
		0:
			# Manobra de três tempos: ré girando, pausa, frente girando.
			_processar_manobra_tres_tempos(delta)
		2:
			# Ré prolongada: recua devagar e seguro (freia se encostar atrás).
			tempo_estrategia += delta
			estercamento_alvo = 0.0
			velocidade_desejada = -_velocidade_reversa()
			_aplicar_movimento(delta)
			if tempo_estrategia >= tempo_re:
				_fim_recuperacao()
		_:
			# Estratégias 1 e 3 já voltaram ao BUSCANDO na hora de iniciar.
			_fim_recuperacao()


# --- COMPORTAMENTO AGÊNTICO (travamento e recuperação) --------------------

func _atualizar_progresso(delta: float) -> void:
	tempo_no_waypoint += delta


func _detectar_travamento() -> bool:
	# No último waypoint e quase lá? Fica aguardando a vaga (não é travamento).
	if indice_waypoint == waypoints.size() - 1:
		if global_position.distance_to(waypoints[indice_waypoint]) < tolerancia_chegada * 3.0:
			return false
	# Regra 1: em limite_tempo_preso segundos, precisa ter se aproximado do
	# waypoint pelo menos limite_progresso px. Senão está travado.
	if tempo_no_waypoint > limite_tempo_preso:
		var progresso: float = distancia_inicio_waypoint - global_position.distance_to(waypoints[indice_waypoint])
		if progresso < limite_progresso:
			return true
	# Regra 2: ficou indo e voltando entre desviar e buscar muitas vezes.
	if contador_oscilacao >= limite_oscilacao:
		return true
	return false


func _iniciar_recuperacao() -> void:
	tentativas += 1
	tempo_no_waypoint = 0.0
	distancia_inicio_waypoint = global_position.distance_to(waypoints[indice_waypoint])
	contador_oscilacao = 0

	if tentativas <= 3:
		# Estratégia 0: manobra de três tempos — ré girando, depois frente.
		estrategia = 0
		fase_manobra = 1
		tempo_estrategia = 0.0
		vies_lado = _lado_com_mais_espaco()
		_mudar_estado(Estado.RECUPERANDO)
	elif tentativas <= 6:
		# Estratégia 1: contorna — cria um waypoint temporário ao lado,
		# então o carro dá a volta por fora e retoma o caminho.
		estrategia = 1
		_inserir_waypoint_desvio()
		tempo_ignorar_sensor = 0.5
		_mudar_estado(Estado.BUSCANDO)
	elif tentativas < max_tentativas_por_waypoint:
		# Estratégia 2: ré — recua para se reposicionar.
		estrategia = 2
		tempo_estrategia = 0.0
		_mudar_estado(Estado.RECUPERANDO)
	else:
		# Estratégia 3: desiste — pula o waypoint; se era o último,
		# pede para escolher outra vaga.
		estrategia = 3
		_desistir_waypoint()
		_mudar_estado(Estado.BUSCANDO)

	tentativa_mudou.emit(tentativas, ESTRATEGIAS[estrategia])


func _processar_manobra_tres_tempos(delta: float) -> void:
	tempo_estrategia += delta
	match fase_manobra:
		1:
			# 1º tempo: dá ré girando o volante para o lado da abertura.
			estercamento_alvo = vies_lado * max_estercamento * 0.8
			velocidade_desejada = -_velocidade_reversa()
			_aplicar_movimento(delta)
			if distancia_tras() < distancia_seguranca + 15.0 or tempo_estrategia >= tempo_re:
				fase_manobra = 2
				tempo_estrategia = 0.0
		2:
			# 2º tempo: pausa curta, já virando o volante para o lado oposto.
			estercamento_alvo = -vies_lado * max_estercamento
			velocidade_desejada = 0.0
			_aplicar_movimento(delta)
			if tempo_estrategia >= 0.3:
				fase_manobra = 3
				tempo_estrategia = 0.0
		3:
			# 3º tempo: vai para a frente virando para o lado oposto.
			estercamento_alvo = -vies_lado * max_estercamento
			velocidade_desejada = _velocidade_por_sensor()
			_aplicar_movimento(delta)
			if _caminho_livre() and _quase_apontando_ao_waypoint():
				_fim_recuperacao()


func _inserir_waypoint_desvio() -> void:
	# Um ponto temporário ao lado do carro, na direção com mais espaço.
	var lado: int = _lado_com_mais_espaco()
	var ponto: Vector2 = global_position + Vector2(0, 1).rotated(rotation + lado * PI / 2.0) * distancia_waypoint_desvio
	waypoints.insert(indice_waypoint, ponto)


func _desistir_waypoint() -> void:
	# Zera a contagem para o PRÓXIMO waypoint começar com 10 tentativas novas.
	_resetar_tentativa()
	if indice_waypoint >= waypoints.size() - 1:
		pedir_nova_vaga.emit()
	else:
		indice_waypoint += 1


func _fim_recuperacao() -> void:
	tempo_ignorar_sensor = 0.5
	_mudar_estado(Estado.BUSCANDO)


func _chegou_no_waypoint() -> void:
	if indice_waypoint < waypoints.size() - 1:
		indice_waypoint += 1
		_resetar_tentativa()
	else:
		# Último waypoint: fica ali esperando a vaga chamar (sem "travar").
		tempo_no_waypoint = 0.0


func _resetar_tentativa() -> void:
	tentativas = 0
	tempo_no_waypoint = 0.0
	distancia_inicio_waypoint = global_position.distance_to(waypoints[indice_waypoint]) if indice_waypoint < waypoints.size() else INF
	contador_oscilacao = 0
	tempo_ignorar_sensor = 0.0


# --- LÓGICA DOS SENSORES (o "radar") -------------------------------------

func distancia_frente() -> float:
	# Menor distância medida pelos 3 raios frontais. INF = nada colidindo.
	var menor: float = INF
	for raio in [ray_frente_centro, ray_frente_esq, ray_frente_dir]:
		menor = minf(menor, _distancia_do_raio(raio))
	return menor


func distancia_tras() -> float:
	return _distancia_do_raio(ray_tras)


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


func _espaco_insuficiente() -> bool:
	# Os dois lados bloqueados => não há para onde virar.
	return _distancia_do_raio(ray_esquerda) < espaco_minimo_desvio \
		and _distancia_do_raio(ray_direita) < espaco_minimo_desvio


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
	# Conta as trocas BUSCANDO <-> DESVIANDO: se isso se repetir demais,
	# o carro está oscilando (zigue-zague) e deve entrar em recuperação.
	if (estado == Estado.BUSCANDO and novo == Estado.DESVIANDO) or \
		(estado == Estado.DESVIANDO and novo == Estado.BUSCANDO):
		contador_oscilacao += 1
	estado = novo
	estado_mudou.emit(nome_estado())


# --- VISUALIZAÇÃO (desenha os sensores na tela) ---------------------------

func _draw() -> void:
	if ray_frente_centro == null:
		return
	var cor_livre := Color(1, 1, 1, 0.25)
	var cor_obstaculo := Color(1, 0.12, 0.12, 0.9)
	for raio in [ray_frente_centro, ray_frente_esq, ray_frente_dir, ray_esquerda, ray_direita, ray_tras]:
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