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
@export var velocidade_maxima: float = 120.0
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

# Sensores frontais: distância que dispara o desvio e quando a rota
# pode ser retomada (não precisa esperar o leque ficar 100% livre).
@export var distancia_desvio: float = 90.0
@export var limite_caminho_livre: float = 70.0

# Câmera de longo alcance (antecipação). distancia_antecipacao = 0 desliga.
@export var distancia_antecipacao: float = 220.0
@export var velocidade_antecipacao: float = 80.0
@export var folga_beco: float = 50.0

# --- NAVEGAÇÃO GLOBAL (o "GPS"): planejamento A* sobre o mapa de ocupação.
# auto_navegacao = false mantém o modo manual (waypoints definidos na cena).
@export var auto_navegacao: bool = true
@export var distancia_lookahead: float = 80.0
@export var vaga_prioritaria: NodePath
@export var planejador_path: NodePath = NodePath("../Planejador")
@export var vagas_path: NodePath = NodePath("../Vagas")

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
@onready var ray_frente_longo: RayCast2D = $RayFrenteLongo
@onready var ray_frente_longo_esq: RayCast2D = $RayFrenteLongoEsq
@onready var ray_frente_longo_dir: RayCast2D = $RayFrenteLongoDir
@onready var planejador: Node2D = get_node_or_null(planejador_path)
@onready var container_vagas: Node2D = get_node_or_null(vagas_path)

var estado: Estado = Estado.BUSCANDO
var waypoints: Array[Vector2] = []
var indice_waypoint: int = 0
var rotacao_alvo: float = 0.0
var posicao_alvo: Vector2 = Vector2.ZERO

# Navegação global: a vaga escolhida e o "GPS" para chegar nela.
var _vaga_alvo: Node2D = null
var _plano_pendente: bool = false
var _sem_vagas: bool = false
var _posicao_anterior: Vector2 = Vector2.ZERO
var _deslocamento_total: float = 0.0

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


func _ready() -> void:
	_posicao_anterior = global_position
	pedir_nova_vaga.connect(_ao_pedir_nova_vaga_interna)


# Inicia a navegação GLOBAL: constrói o mapa de ocupação e calcula a rota
# A* até a melhor vaga. O cálculo é adiado para o primeiro frame de física,
# garantindo que todos os obstáculos já estejam registrados no mundo.
func iniciar_navegacao() -> void:
	auto_navegacao = true
	_sem_vagas = false
	_plano_pendente = true


func _planejar_rota() -> void:
	if planejador == null or container_vagas == null:
		return
	var escolha: Dictionary = _escolher_vaga()
	if escolha.is_empty() or escolha["vaga"] == null:
		_sem_vagas = true
		pedir_nova_vaga.emit()
		return
	_sem_vagas = false
	_vaga_alvo = escolha["vaga"]
	_aplicar_rota(escolha["rota"])
	tentativa_mudou.emit(0, "Rota A* para a vaga")


func _escolher_vaga() -> Dictionary:
	# Vaga prioritária (marcada na cena) e livre ganha sempre.
	if not vaga_prioritaria.is_empty():
		var prioritaria := get_node_or_null(vaga_prioritaria)
		if prioritaria != null and not prioritaria.ocupada:
			var rota_p: Array = planejador.achar_rota(global_position, prioritaria.global_position)
			if rota_p.size() >= 2:
				return {"vaga": prioritaria, "rota": rota_p}
	# Senão: a vaga livre ALCANÇÁVEL mais próxima (menor rota).
	var melhor: Dictionary = {}
	var melhor_custo: float = INF
	for vaga in container_vagas.get_children():
		if vaga.ocupada:
			continue
		var rota: Array = planejador.achar_rota(global_position, vaga.global_position)
		if rota.size() < 2:
			continue
		var custo := _comprimento_rota(rota)
		if custo < melhor_custo:
			melhor_custo = custo
			melhor = {"vaga": vaga, "rota": rota}
	return melhor


func _comprimento_rota(rota: Array) -> float:
	var total: float = 0.0
	for i in range(1, rota.size()):
		total += (rota[i - 1] as Vector2).distance_to(rota[i] as Vector2)
	return total


func _aplicar_rota(rota: Array) -> void:
	waypoints.clear()
	for ponto in rota:
		waypoints.append(ponto)
	indice_waypoint = 0
	_resetar_tentativa()
	if planejador != null:
		planejador.definir_rota(rota)


func _ao_pedir_nova_vaga_interna() -> void:
	if auto_navegacao and not _sem_vagas:
		_plano_pendente = true


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
	if ray_frente_longo.is_colliding() or ray_frente_longo_esq.is_colliding() or ray_frente_longo_dir.is_colliding():
		return "Obstáculo à frente (longe)"
	if ray_esquerda.is_colliding():
		return "Obstáculo à esquerda"
	if ray_direita.is_colliding():
		return "Obstáculo à direita"
	if ray_tras.is_colliding():
		return "Obstáculo atrás"
	return "Livre"


func _physics_process(delta: float) -> void:
	# A rota é planejada no PRIMEIRO frame de física (garante que os
	# obstáculos já estão registrados no mundo antes de "enxergá-los").
	if _plano_pendente:
		_plano_pendente = false
		_planejar_rota()

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
	var todos := [ray_frente_centro, ray_frente_esq, ray_frente_dir, ray_esquerda, ray_direita, ray_tras, \
		ray_frente_longo, ray_frente_longo_esq, ray_frente_longo_dir]
	for raio in todos:
		raio.force_raycast_update()


# --- MOVIMENTO (a "física" de dirigir de verdade) -------------------------

func _aplicar_movimento(delta: float) -> void:
	# 1) O volante vira aos poucos (não instantâneo).
	estercamento = move_toward(estercamento, estercamento_alvo, taxa_estercamento * delta)
	# 2) Modelo de bicicleta: a rotação muda conforme o volante e a velocidade.
	#    tan() faz o arco ficar fechado quando o volante está muito virado.
	rotation += velocidade_atual / entre_eixos * tan(estercamento) * delta
	# 3) PROIBIDO BATER: indo pra frente, se o CENTRO do caminho está a menos
	#    de distancia_seguranca, a velocidade alvo vira zero (para de vez).
	#    (Usa o raio central, não o leque: só um canto raspando não trava o
	#    carro numa curva — ele segue virando até o caminho ficar livre.)
	if velocidade_desejada > 0.0 and distancia_centro() < distancia_seguranca:
		velocidade_desejada = 0.0
	# 4) Rampa de aceleração/frenagem: a velocidade muda aos poucos.
	#    Freia mais forte do que acelera (igual motorista de verdade).
	var variacao: float = (frenagem if velocidade_desejada < velocidade_atual else aceleracao) * delta
	velocidade_atual = move_toward(velocidade_atual, velocidade_desejada, variacao)
	velocity = transform.x * velocidade_atual
	move_and_slide()


func _velocidade_por_sensor() -> float:
	# A velocidade segue o que está REALMENTE no caminho do carro: o raio
	# CENTRAL. Um obstáculo só raspando num canto não deve frear o carro —
	# ele pode seguir reto enquanto o centro está livre.
	var dist: float = distancia_centro()
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

	# --- NAVEGAÇÃO GLOBAL (GPS): segue a rota A* com pure pursuit. --------
	# O carro não mira no waypoint exato: mira num ponto à FRENTE do caminho,
	# o que faz as curvas saírem suaves (como um motorista real). Se travar,
	# replaneja a rota do ponto atual em vez de "tentar na sorte".
	if auto_navegacao and _vaga_alvo != null:
		_processar_rota(delta)
		return

	_atualizar_progresso(delta)
	if _detectar_travamento():
		_iniciar_recuperacao()
		return

	# --- CÂMERA DE LONGO ALCANCE (antecipação) ---------------------------
	# O carro "vê de longe": se algo está bloqueando à frente, ele reage
	# ANTES de chegar perto — vira cedo pro lado livre (beco confirmado
	# é tratado no DESVIANDO, quando os dois lados curtos fecham).
	if tempo_ignorar_sensor <= 0.0 and distancia_antecipacao > 0.0:
		var visao: float = _distancia_do_raio(ray_frente_longo)
		if visao < distancia_antecipacao:
			var dist_wp: float = global_position.distance_to(waypoints[indice_waypoint])
			# Obstáculo mais longe que o waypoint? Antecipa o desvio:
			# vira pro lado mais livre JÁ AGORA e reduz a velocidade.
			if visao < dist_wp:
				var lado: int = _lado_com_mais_espaco_longe()
				var erro_ant: float = angle_difference(rotation, global_position.direction_to(waypoints[indice_waypoint]).angle())
				estercamento_alvo = clampf(erro_ant * 2.0 + lado * 0.6, -max_estercamento, max_estercamento)
				velocidade_desejada = minf(velocidade_antecipacao, _velocidade_por_sensor())
				_aplicar_movimento(delta)
				return

	# Se qualquer raio frontal (curto) mede algo a menos de distancia_desvio,
	# hora de desviar. (pulado durante a "graça" da recuperação)
	if tempo_ignorar_sensor <= 0.0 and distancia_frente() < distancia_desvio:
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


# --- NAVEGAÇÃO GLOBAL: seguir a rota (pure pursuit) -----------------------

func _processar_rota(delta: float) -> void:
	_deslocamento_total += global_position.distance_to(_posicao_anterior)
	_posicao_anterior = global_position
	_atualizar_progresso(delta)
	if _detectar_travamento_rota():
		_replanejar_ou_recuperar()
		return

	# Chegou no fim da rota (boca da vaga): aproxima devagar e SEM girar
	# em volta do ponto final (nada de ficar "rodando" no lugar).
	var fim_rota: Vector2 = waypoints[waypoints.size() - 1]
	if indice_waypoint >= waypoints.size() - 1 and global_position.distance_to(fim_rota) < tolerancia_chegada * 2.5:
		var erro_fim: float = angle_difference(rotation, global_position.direction_to(fim_rota).angle())
		estercamento_alvo = clampf(erro_fim * 1.2, -max_estercamento, max_estercamento)
		velocidade_desejada = velocidade_alinhamento * 0.5
		_aplicar_movimento(delta)
		return

	# Ponto à frente do caminho: é nele que o volante aponta (curva suave).
	var alvo := _ponto_lookahead(distancia_lookahead)
	var erro: float = angle_difference(rotation, global_position.direction_to(alvo).angle())
	# Volante GENTIL: corrige aos poucos. Numa fresta larga, quase não vira.
	estercamento_alvo = clampf(erro * 1.5, -max_estercamento, max_estercamento)
	# Motorista real freia em curva: quanto mais virado o volante, mais devagar.
	var fator_curva: float = 1.0 - minf(absf(erro) / max_estercamento, 1.0) * 0.5
	velocidade_desejada = _velocidade_por_sensor() * fator_curva

	_aplicar_movimento(delta)
	_avancar_indice_rota()


func _detectar_travamento_rota() -> bool:
	# Na rota planejada (já sem obstáculos no caminho), "preso" é NÃO SAIR
	# DO LUGAR. Andar devagar raspando num obstáculo é cuidado, não trava —
	# isso acabava gerando manobra de três tempos à toa dentro das frestas.
	if not waypoints.is_empty() and indice_waypoint == waypoints.size() - 1 \
		and global_position.distance_to(waypoints[waypoints.size() - 1]) < tolerancia_chegada * 3.0:
		return false
	return tempo_no_waypoint > limite_tempo_preso and _deslocamento_total < limite_progresso * 1.5


func _ponto_lookahead(distancia: float) -> Vector2:
	if waypoints.size() < 2:
		return waypoints[0] if not waypoints.is_empty() else global_position
	# 1) Acha o ponto mais próximo do carro na polilinha da rota.
	var melhor_seg: int = 0
	var melhor_p: Vector2 = waypoints[0]
	var melhor_d: float = INF
	for i in range(waypoints.size() - 1):
		var p := Geometry2D.get_closest_point_to_segment(global_position, waypoints[i], waypoints[i + 1])
		var d: float = global_position.distance_squared_to(p)
		if d < melhor_d:
			melhor_d = d
			melhor_seg = i
			melhor_p = p
	# 2) Anda `distancia` para frente ao longo da rota a partir dali.
	var acum: float = melhor_p.distance_to(waypoints[melhor_seg + 1])
	if acum >= distancia:
		return melhor_p.lerp(waypoints[melhor_seg + 1], distancia / maxf(acum, 0.001))
	var fim: Vector2 = waypoints[melhor_seg + 1]
	for j in range(melhor_seg + 1, waypoints.size() - 1):
		var prox: Vector2 = waypoints[j + 1]
		var seg: float = fim.distance_to(prox)
		if acum + seg >= distancia:
			return fim.lerp(prox, (distancia - acum) / maxf(seg, 0.001))
		acum += seg
		fim = prox
	return waypoints[waypoints.size() - 1]


func _avancar_indice_rota() -> void:
	if indice_waypoint >= waypoints.size() - 1:
		return
	var atual := waypoints[indice_waypoint]
	var dist_atual: float = global_position.distance_to(atual)
	var dist_proximo: float = global_position.distance_to(waypoints[indice_waypoint + 1])
	# Passou do vértice (está mais perto do próximo) ou chegou bem perto.
	if dist_atual < tolerancia_chegada or (dist_proximo < dist_atual and dist_atual < distancia_lookahead * 1.5):
		indice_waypoint += 1
		_resetar_tentativa()


func _replanejar_ou_recuperar() -> void:
	if planejador == null:
		_iniciar_recuperacao()
		return
	var alvo: Vector2
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		alvo = _vaga_alvo.global_position
	elif not waypoints.is_empty():
		alvo = waypoints[waypoints.size() - 1]
	else:
		alvo = global_position
	var rota: Array = planejador.achar_rota(global_position, alvo)
	if rota.size() >= 2:
		_aplicar_rota(rota)
		tentativa_mudou.emit(0, "Replanejou rota (A*)")
	else:
		_iniciar_recuperacao()


func _processar_desviando(delta: float) -> void:
	_atualizar_progresso(delta)
	if _detectar_travamento():
		_iniciar_recuperacao()
		return

	# Sem espaço nos DOIS lados? Não dá para desviar virando. Se a parede
	# longa confirma beco sem saída, o carro reconhece e pula cedo (visão);
	# senão, faz a manobra de três tempos em vez de oscilar (zigue-zague).
	if _espaco_insuficiente():
		if _beco_confirmado():
			_desistir_waypoint()
			tempo_ignorar_sensor = 0.5
			tentativa_mudou.emit(0, "Reconheceu beco sem saída")
			_mudar_estado(Estado.BUSCANDO)
			return
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
	_deslocamento_total = 0.0


# --- LÓGICA DOS SENSORES (o "radar") -------------------------------------

func distancia_frente() -> float:
	# Menor distância medida pelos 3 raios frontais. INF = nada colidindo.
	var menor: float = INF
	for raio in [ray_frente_centro, ray_frente_esq, ray_frente_dir]:
		menor = minf(menor, _distancia_do_raio(raio))
	return menor


func distancia_centro() -> float:
	# Distância do raio CENTRAL: o que está mesmo à frente do carro.
	# É ela que manda na velocidade (freiar por um canto raspando = errado).
	return _distancia_do_raio(ray_frente_centro)


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


func _lado_com_mais_espaco_longe() -> int:
	# Igual ao de cima, mas usando a câmera de longo alcance: vê qual lado
	# tem mais espaço LÁ NA FRENTE (na altura do obstáculo), não ao lado do carro.
	var espaco_esq: float = _distancia_do_raio(ray_frente_longo_esq)
	var espaco_dir: float = _distancia_do_raio(ray_frente_longo_dir)
	return -1 if espaco_esq >= espaco_dir else 1


func _beco_confirmado() -> bool:
	# Confirma beco sem saída (usado quando os dois lados já estão fechados):
	# a parede longa está batendo E o waypoint está além dela (ou colado).
	var visao: float = _distancia_do_raio(ray_frente_longo)
	if visao >= distancia_antecipacao:
		return false
	var dist_wp: float = global_position.distance_to(waypoints[indice_waypoint])
	return dist_wp > visao - folga_beco


func _espaco_insuficiente() -> bool:
	# Só declara "preso" se não dá nem para seguir em frente: o CENTRO
	# está bloqueado E os dois lados não têm espaço para virar. Se o centro
	# está livre, o carro segue reto (não faz manobra à toa).
	if distancia_centro() >= distancia_desvio:
		return false
	return _distancia_do_raio(ray_esquerda) < espaco_minimo_desvio \
		and _distancia_do_raio(ray_direita) < espaco_minimo_desvio


func _caminho_livre() -> bool:
	# Não precisa estar 100% sem colisão: basta o obstáculo estar longe o
	# suficiente (limite_caminho_livre) para retomar a rota. Senão, ao passar
	# raspando por um obstáculo lateral, o carro "encara" e nunca sai do desvio.
	return distancia_frente() > limite_caminho_livre


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
	# Câmera de longo alcance: desenhada em CIANO para diferenciar.
	var cor_livre_longa := Color(0.3, 0.9, 1, 0.18)
	var cor_obstaculo_longa := Color(0.3, 0.9, 1, 0.9)
	for raio in [ray_frente_longo, ray_frente_longo_esq, ray_frente_longo_dir]:
		_desenhar_raio(raio, cor_livre_longa, cor_obstaculo_longa)


func _desenhar_raio(raio: RayCast2D, cor_livre: Color, cor_obstaculo: Color) -> void:
	var origem: Vector2 = raio.position
	var fim: Vector2 = raio.position + raio.target_position
	var cor: Color = cor_obstaculo if raio.is_colliding() else cor_livre
	draw_line(origem, fim, cor, 3.0)
	if debug_sensores and raio.is_colliding():
		# Bolinha laranja no ponto exato do impacto (visão de "radar").
		var ponto: Vector2 = to_local(raio.get_collision_point())
		draw_circle(ponto, 4.0, Color(1, 0.5, 0, 0.9))