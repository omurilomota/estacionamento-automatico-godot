extends CharacterBody2D
## O CÉREBRO DO CARRO — Máquina de Estados (FSM) com RECUPERAÇÃO.

const CerebroML = preload("res://scripts/CerebroML.gd")
const SensorArrayRef = preload("res://src/vehicle/SensorArray.gd")
const LocomotionRef = preload("res://src/vehicle/Locomotion.gd")
const DatasetRecorderRef = preload("res://src/vehicle/DatasetRecorder.gd")
const DriveContextRef = preload("res://src/vehicle/DriveContext.gd")
const DriveCommandAdapterRef = preload("res://src/vehicle/DriveCommandAdapter.gd")
const FsmProfilesRef = preload("res://src/vehicle/FsmProfiles.gd")
const TrailFollowerRef = preload("res://src/vehicle/TrailFollower.gd")
const AutonomousDriverRef = preload("res://src/vehicle/AutonomousDriver.gd")
const MlDriverRef = preload("res://src/vehicle/MlDriver.gd")
## O movimento imita um motorista real:
##  - O volante (estercamento) vira aos poucos e o carro faz ARCO, não pivota.
##  - Acelera e freia com rampa (frenagem mais forte que aceleração).
##  - Desacelera em curva e PARA antes de encostar em qualquer obstáculo.
## Se não progride, ele conta tentativas e muda de estratégia (comportamento agêntico).

signal estado_mudou(nome: String)
signal tentativa_mudou(tentativas: int, estrategia: String)
signal pedir_nova_vaga

enum Estado { BUSCANDO, DESVIANDO, ALINHANDO, ESTACIONADO, RECUPERANDO }

# Velocidades (humanas = mais ágeis, mas ainda cuidadosas)
@export var velocidade_maxima: float = 160.0
@export var velocidade_desvio: float = 110.0
@export var velocidade_alinhamento: float = 65.0

# Modelo de direção (volante) - humano vira rápido e até o fim
@export var aceleracao: float = 300.0
@export var frenagem: float = 300.0
@export var max_estercamento: float = 0.9
@export var taxa_estercamento: float = 5.0
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
@export var distancia_lookahead: float = 180.0
@export var vaga_prioritaria: NodePath
@export var planejador_path: NodePath = NodePath("../Planejador")
@export var vagas_path: NodePath = NodePath("../Vagas")

# --- MODO TRILHA (simplificado): segue linha pré-calculada e só PARA ao ver obstáculo ---
@export var modo_trilha: bool = true
@export var tempo_parado_replanejar: float = 2.8
@export var velocidade_trilha_max: float = 120.0

@export var tolerancia_chegada: float = 24.0
@export var tolerancia_alinhamento: float = 0.08
@export var debug_sensores: bool = true

# --- MACHINE LEARNING (imitação / behavior cloning) ---
# ml_gravar: grava CSV (sensores -> ações) do cérebro atual (o "professor")
# modo_ml:   o "aluno" (rede treinada em ml/treinar.py) dirige pelos sensores
@export var ml_gravar: bool = false
@export var ml_gravar_caminho: String = "res://ml/dados/gravacao.csv"
@export var modo_ml: bool = false
# Evolução/GA: desliga os fallbacks para o fitness medir SÓ a rede
@export var ml_sem_fallback: bool = false
var _ml_arquivo: FileAccess = null
var _ml_rede: CerebroML = null
var _ml_pos_ref: Vector2 = Vector2.ZERO
var _ml_t_progresso: float = 0.0

# --- SHADOW BRAINS (wiring step, behind flag) -----------------------------
# Steering is now DELEGATED to PurePursuit.solve_error in all 4 FSM paths
# (same transform, proven by the ShadowParity harness). The flag stays for
# the next slice: speed/reverse shadow comparisons (curve_speed, approach
# profiles, trail reverse idiom) before those delegate too.
@export var shadow_brains: bool = false
var _shadow_samples: int = 0
var _shadow_worst: float = 0.0
var _shadow_worst_speed: float = 0.0
var _shadow_drifts: int = 0
var _shadow_speed_drifts: int = 0

# Opt-in decoupled brain. The legacy FSM remains the default and fallback.
@export var brain_enabled: bool = false
var driver_brain = null
var _brain_command = null
var _brain_context: DriveContextRef = null
var _legacy_steering_target: float = 0.0
var _legacy_speed_target: float = 0.0

# Comportamento agêntico (quando o carro fica "preso")
@export var limite_tempo_preso: float = 30.0
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
@onready var ray_lateral_esq: RayCast2D = $RayLateralEsq
@onready var ray_lateral_dir: RayCast2D = $RayLateralDir
@onready var ray_seta: RayCast2D = $RaySeta
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
var _tempo_parado: float = 0.0
var _rota_trilha_anterior: Array[Vector2] = []

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
	_tempo_parado = 0.0

func definir_trilha(pontos: Array) -> void:
	definir_waypoints(pontos)


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


func iniciar_modo_trilha() -> void:
	modo_trilha = true
	auto_navegacao = true
	_sem_vagas = false
	_plano_pendente = true
	_tempo_parado = 0.0
	tempo_ignorar_sensor = 1.0


func _planejar_rota() -> void:
	# MODO ML: sem rota desenhada — só escolhe a vaga livre mais próxima.
	# A rede neural (CerebroML) dirige usando apenas os sensores.
	if modo_ml:
		waypoints = []
		indice_waypoint = 0
		var melhor_ml: Node2D = null
		var menor_ml: float = INF
		if container_vagas != null:
			for v in container_vagas.get_children():
				if v.ocupada:
					continue
				var dm: float = global_position.distance_to(v.global_position)
				if dm < menor_ml:
					menor_ml = dm
					melhor_ml = v
		if melhor_ml == null:
			_sem_vagas = true
			pedir_nova_vaga.emit()
			return
		_vaga_alvo = melhor_ml
		_sem_vagas = false
		_tempo_parado = 0.0
		_ml_pos_ref = global_position
		_ml_t_progresso = 0.0
		tentativa_mudou.emit(0, "MODO ML: rede neural dirige")
		return
	# Modo trilha: usa rota sequencial; o recovery pode usar A* se o fallback repetir.
	if modo_trilha:
		var rota_seq: Array = _construir_rota_sequencial_ruas()
		if rota_seq.size() >= 2:
			_aplicar_rota(rota_seq)
			_sem_vagas = false
			tentativa_mudou.emit(0, "Rota sequencial Reta->Curva->Reta2")
			return
		# Fallback: coleta rota via Line2D
		var fb_trilha: Array = _coletar_rota_fallback()
		if fb_trilha.size() >= 2:
			_sem_vagas = false
			var vaga_fb: Node2D = null
			var dist_fb: float = INF
			for v in container_vagas.get_children():
				if v.ocupada:
					continue
				var d: float = global_position.distance_to(v.global_position)
				if d < dist_fb:
					dist_fb = d
					vaga_fb = v
			if vaga_fb != null:
				_vaga_alvo = vaga_fb
				fb_trilha.append(_vaga_alvo.global_position)
				_aplicar_rota(fb_trilha)
				tentativa_mudou.emit(0, "Rota trilha (fallback Line2D)")
			return
		# Sem rota disponível: pede nova vaga
		_sem_vagas = true
		pedir_nova_vaga.emit()
		return

	# NÃO é modo trilha: pode usar A* normal
	if planejador == null or container_vagas == null:
		_sem_vagas = true
		pedir_nova_vaga.emit()
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
	_tempo_parado = 0.0
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
	var era_vazia: bool = waypoints.is_empty()
	waypoints.clear()
	for ponto in rota:
		waypoints.append(ponto)
	indice_waypoint = 0
	_resetar_tentativa()
	_tempo_parado = 0.0
	if modo_trilha:
		_rota_trilha_anterior.clear()
		for ponto in waypoints:
			_rota_trilha_anterior.append(ponto)
		tempo_ignorar_sensor = 0.8
		# Só orienta na primeira rota (spawn) — snap completo para não começar de lado
		if era_vazia and rota.size() >= 2:
			var dir_ini: Vector2 = (rota[1] as Vector2) - (rota[0] as Vector2)
			if dir_ini.length_squared() > 1.0:
				rotation = dir_ini.angle()
	if planejador != null:
		planejador.definir_rota(rota)


func _ao_pedir_nova_vaga_interna() -> void:
	if auto_navegacao and not _sem_vagas:
		_plano_pendente = true


func preparar_estacionamento(rotacao_da_vaga: float, posicao_da_vaga: Vector2) -> void:
	# Humano: cria waypoint de preparação à frente da vaga para ter espaço de manobra
	if estado == Estado.ALINHANDO or estado == Estado.ESTACIONADO:
		return
	rotacao_alvo = rotacao_da_vaga
	posicao_alvo = posicao_da_vaga
	# Ponto de preparação: 1.8*entre_eixos à frente da boca, na direção oposta ao nariz da vaga
	var dir_vaga := Vector2.RIGHT.rotated(rotacao_alvo)
	var dist_prep := entre_eixos * 2.5 + 80.0
	var ponto_prep := posicao_da_vaga - dir_vaga * dist_prep
	# Insere como waypoint temporário se ainda não estamos muito perto
	# Mas NÃO se já passamos do ponto de preparação (entre prep e vaga)
	var vetor_para_carro := global_position - posicao_da_vaga
	var projecao := vetor_para_carro.dot(dir_vaga)
	var ja_passou_prep := projecao > -dist_prep and projecao < 0.0
	if global_position.distance_to(posicao_da_vaga) > 60.0 and not ja_passou_prep:
		waypoints.clear()
		waypoints.append(ponto_prep)
		waypoints.append(posicao_da_vaga)
		indice_waypoint = 0
		_resetar_tentativa()
	_mudar_estado(Estado.ALINHANDO)


func entrar_estado_alinhando(rotacao_da_vaga: float, posicao_da_vaga: Vector2) -> void:
	rotacao_alvo = rotacao_da_vaga
	posicao_alvo = posicao_da_vaga
	_mudar_estado(Estado.ALINHANDO)


func set_driver_brain(brain) -> void:
	driver_brain = brain


func set_brain_enabled(enabled: bool) -> void:
	brain_enabled = enabled


func _build_brain_perception() -> PerceptionSnapshot:
	var rays := SensorArrayRef.collect_from(self)
	var alvo: Vector2 = posicao_alvo
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		alvo = (_vaga_alvo as Node2D).global_position
	var dist_t := global_position.distance_to(alvo)
	var ang_t := 0.0
	if dist_t > 0.001:
		ang_t = angle_difference(rotation, global_position.direction_to(alvo).angle())
	return SensorArrayRef.snapshot(rays, velocidade_atual, dist_t, ang_t)


func _build_drive_context(perception: PerceptionSnapshot) -> DriveContextRef:
	var context := DriveContextRef.new()
	context.vehicle_position = global_position
	context.vehicle_rotation = rotation
	context.state = int(estado)
	if modo_ml:
		context.mode = DriveContextRef.Mode.ML
	elif modo_trilha:
		context.mode = DriveContextRef.Mode.TRAIL
	else:
		context.mode = DriveContextRef.Mode.AUTONOMOUS
	context.route = Array(waypoints)
	context.waypoint_index = indice_waypoint
	context.target_position = posicao_alvo
	context.target_yaw = rotacao_alvo
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		context.target_position = (_vaga_alvo as Node2D).global_position
		context.target_yaw = float(_vaga_alvo.get("rotacao_alvo")) if "rotacao_alvo" in _vaga_alvo else 0.0
	context.distance_to_target = global_position.distance_to(context.target_position)
	context.angle_to_target = perception.angle_to_target
	context.cte = _cte_para_rota()
	context.curvature_ahead = _curvatura_a_frente()
	context.front_distance = distancia_centro()
	context.rear_distance = distancia_tras()
	context.lateral_distance = distancia_lateral()
	context.speed = velocidade_atual
	context.arrived = estado == Estado.ESTACIONADO or (
		not waypoints.is_empty() and indice_waypoint >= waypoints.size() - 1 and
		global_position.distance_to(waypoints[waypoints.size() - 1]) < tolerancia_chegada)
	context.perception = perception
	return context


func _cte_para_rota() -> float:
	if waypoints.size() < 2:
		return INF
	var closest := INF
	for i in range(waypoints.size() - 1):
		var p := Geometry2D.get_closest_point_to_segment(global_position, waypoints[i], waypoints[i + 1])
		closest = minf(closest, global_position.distance_to(p))
	return closest


func _brain_max_speed() -> float:
	if modo_trilha:
		return velocidade_trilha_max * maxf((global_scale.x + global_scale.y) * 0.5, 1.0)
	return velocidade_maxima


func _brain_for_current_mode() -> Object:
	if driver_brain != null:
		return driver_brain
	if modo_ml:
		return null
	if modo_trilha:
		return TrailFollowerRef.new()
	return AutonomousDriverRef.new()


func _brain_speed_limit(brain: Object) -> float:
	if brain != null and "max_speed" in brain:
		var configured := float(brain.get("max_speed"))
		if configured > 0.0:
			return configured
	return _brain_max_speed()


func _apply_brain_command() -> void:
	if estado == Estado.ESTACIONADO or estado == Estado.RECUPERANDO:
		return
	var perception := _build_brain_perception()
	var context := _build_drive_context(perception)
	var brain: Object = _brain_for_current_mode()
	if brain == null:
		return
	var cmd = brain.call("decide_context", perception, context, get_physics_process_delta_time())
	if cmd == null:
		return
	var legacy_steering := estercamento_alvo
	var legacy_speed := velocidade_desejada
	if shadow_brains:
		_shadow_check_command(cmd, legacy_steering, legacy_speed)
	if not brain_enabled:
		return
	var targets := DriveCommandAdapterRef.to_legacy_targets(
		cmd, max_estercamento, _brain_speed_limit(brain))
	estercamento_alvo = float(targets["steering"])
	velocidade_desejada = float(targets["speed"])


func _shadow_check_command(cmd, legacy_steering: float, legacy_speed: float) -> void:
	var targets := DriveCommandAdapterRef.to_legacy_targets(
		cmd, max_estercamento, _brain_speed_limit(_brain_for_current_mode()))
	_shadow_samples += 1
	var steer_diff := absf(float(targets["steering"]) - legacy_steering)
	var speed_diff := absf(float(targets["speed"]) - legacy_speed)
	_shadow_worst = maxf(_shadow_worst, steer_diff)
	_shadow_worst_speed = maxf(_shadow_worst_speed, speed_diff)
	if steer_diff > 0.03:
		_shadow_drifts += 1
	if speed_diff > 2.0:
		_shadow_speed_drifts += 1
	if steer_diff > 0.03 or speed_diff > 2.0:
		print("SHADOW drift steer=%.4f speed=%.2f legacy_ste=%.4f legacy_spd=%.2f state=%s idx=%d" % [
			steer_diff, speed_diff, legacy_steering, legacy_speed, nome_estado(), indice_waypoint])


func shadow_drift() -> Dictionary:
	return {
		"samples": _shadow_samples,
		"worst": _shadow_worst,
		"worst_speed": _shadow_worst_speed,
		"drifts": _shadow_drifts,
		"speed_drifts": _shadow_speed_drifts,
	}


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


func get_sensor_text() -> String:
	# Usado pela UI (Mundo.gd) para mostrar o que o sensor está lendo.
	if ray_seta != null and ray_seta.is_colliding():
		return "Seguindo seta"
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

	# MODO ML (imitação): a rede neural dirige pelos sensores — sem trilha.
	# A FSM continua sendo o "juiz" (vaga/ESTACIONADO/ALINHANDO).
	if modo_ml:
		match estado:
			Estado.BUSCANDO, Estado.DESVIANDO:
				_processar_ml(delta)
			Estado.ALINHANDO:
				_processar_alinhando_trilha(delta)
			Estado.ESTACIONADO:
				_processar_estacionado(delta)
			Estado.RECUPERANDO:
				_processar_trilha(delta)
		queue_redraw()
		return

	# MODO TRILHA: segue linha pré-calculada, só PARA se obstáculo à frente (não desvia)
	if modo_trilha:
		match estado:
			Estado.BUSCANDO:
				_processar_trilha(delta)
			Estado.DESVIANDO:
				# Em trilha, DESVIANDO vira "PARADO por obstáculo" — trata como trilha
				_processar_trilha(delta)
			Estado.ALINHANDO:
				_processar_alinhando_trilha(delta)
			Estado.ESTACIONADO:
				_processar_estacionado(delta)
			Estado.RECUPERANDO:
				_processar_trilha(delta)
	else:
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

	# GRAVAÇÃO (professor): cada frame de BUSCANDO vira uma linha do dataset
	if ml_gravar and estado == Estado.BUSCANDO:
		_ml_gravar_linha()


func _exit_tree() -> void:
	_ml_fechar()


func _atualizar_sensores() -> void:
	var todos := [ray_frente_centro, ray_frente_esq, ray_frente_dir, ray_esquerda, ray_direita, ray_tras, \
		ray_frente_longo, ray_frente_longo_esq, ray_frente_longo_dir, ray_lateral_esq, ray_lateral_dir, ray_seta]
	for raio in todos:
		if raio == null or not is_instance_valid(raio):
			continue
		if not raio.global_position.is_finite() or not raio.target_position.is_finite():
			continue
		raio.force_raycast_update()


# --- MOVIMENTO (a "física" de dirigir de verdade) -------------------------

func _aplicar_movimento(delta: float) -> void:
	_apply_brain_command()
	if not global_position.is_finite() or not is_finite(rotation) or not is_finite(estercamento):
		estercamento = 0.0
		return
	# 1) O volante vira aos poucos (não instantâneo).
	estercamento = move_toward(estercamento, estercamento_alvo, taxa_estercamento * delta)
	if not is_finite(estercamento):
		estercamento = 0.0
	# 2) Modelo de bicicleta: entre_eixos escala com o tamanho visual do carro
	var escala_media := (global_scale.x + global_scale.y) * 0.5
	var entre_eixos_efetivo := entre_eixos * maxf(escala_media, 1.0)
	if entre_eixos_efetivo < 1.0:
		entre_eixos_efetivo = 60.0
	# Proibido girar parado — humano só vira com o carro em movimento
	if absf(velocidade_atual) > 1.0 and is_finite(velocidade_atual):
		rotation += velocidade_atual / entre_eixos_efetivo * tan(estercamento) * delta
	if not is_finite(rotation):
		rotation = 0.0
	# 3) PROIBIDO BATER: frente e lateral — humano não raspa parede (escalado)
	var escala_seg := maxf(escala_media, 1.0)
	var seg_escalado := distancia_seguranca * escala_seg * 0.6 # 0.6 evita freio excessivo em escala grande
	# clamp minimo para não ficar 0 em escala pequena
	seg_escalado = maxf(seg_escalado, 18.0)
	if velocidade_desejada > 0.0:
		var dist_frente := distancia_centro()
		var dist_lat := distancia_lateral()
		var limite_lat := 12.0 if estado == Estado.RECUPERANDO else 22.0
		limite_lat *= escala_seg
		limite_lat = maxf(limite_lat, 14.0)
		if dist_frente < seg_escalado or dist_lat < limite_lat:
			velocidade_desejada = 0.0
	if velocidade_desejada < 0.0 and distancia_tras() < seg_escalado:
		if not (estado == Estado.RECUPERANDO and absf(estercamento) > 0.5):
			velocidade_desejada = 0.0
	# 4) Rampa suave humana: escala até 160 em reta, cai em curva (v_curva)
	var rate: float = 6.0 if velocidade_desejada < velocidade_atual else 3.0
	velocidade_atual = lerp(velocidade_atual, velocidade_desejada, clamp(rate * delta, 0.0, 1.0))
	if absf(velocidade_desejada) < 0.01 and absf(velocidade_atual) < 0.5:
		velocidade_atual = 0.0
	# 5) Guarda contra NaN/transform inválido antes de projetar o vetor.
	if not velocity.is_finite():
		velocity = Vector2.ZERO
		velocidade_atual = 0.0
		return
	var dir_mov := Vector2.RIGHT.rotated(rotation)
	velocity = dir_mov * velocidade_atual
	# Segurança reforçada contra Godot #94928: normal (0,0)
	# threshold maior (2 px/s = length_squared 4) evita slide degenerado
	if not velocity.is_finite() or velocity.length_squared() < 4.0:
		velocity = Vector2.ZERO
		velocidade_atual = 0.0
		return
	# Detecção de penetração: se já está dentro de parede, não chama slide (gera normal 0)
	if test_move(transform, Vector2.ZERO):
		velocity = Vector2.ZERO
		velocidade_atual = 0.0
		return
	# Teste preditivo: se o movimento colidiria com normal degenerada, freia antes
	var col_teste := move_and_collide(velocity * delta, true)
	if col_teste != null:
		var n_teste := col_teste.get_normal()
		if not n_teste.is_finite() or n_teste.length_squared() < 0.25:
			velocity = Vector2.ZERO
			velocidade_atual = 0.0
			return
		if n_teste.length_squared() < 0.9 or not n_teste.is_normalized():
			# normal quase zero ou não normalizada -> trata como penetração
			if velocity.length() < 30.0:
				velocity = Vector2.ZERO
				velocidade_atual = 0.0
				return
	if debug_sensores and absf(velocidade_atual) < 60.0 and \
		(distancia_frente() < 80.0 or distancia_tras() < 80.0 or distancia_lateral() < 80.0):
		print("[dbg-alinhamento] st=", nome_estado(), " desejada=", velocidade_desejada,
			" atual=", velocidade_atual, " df=", distancia_frente(),
			" dt=", distancia_tras(), " dlat=", distancia_lateral())
	move_and_slide()
	var dir_drift := Vector2.RIGHT.rotated(rotation)
	if velocity.is_finite():
		velocity = velocity.dot(dir_drift) * dir_drift
		velocidade_atual = velocity.dot(dir_drift)


func _aplicar_movimento_trilha(delta: float) -> void:
	_apply_brain_command()
	# Versão KINEMÁTICA para modo trilha: não usa move_and_slide (evita normal 0)
	if not global_position.is_finite() or not is_finite(rotation) or not is_finite(estercamento):
		estercamento = 0.0
		return
	if not is_finite(velocidade_desejada) or absf(velocidade_desejada) > 1e6:
		print("[BUG] desejada huge entry ", velocidade_desejada, " vel_atual ", velocidade_atual)
		velocidade_desejada = clampf(velocidade_desejada, -200, 200)
	if not is_finite(velocidade_atual) or absf(velocidade_atual) > 1e6:
		print("[BUG] vel_atual huge entry ", velocidade_atual)
		velocidade_atual = clampf(velocidade_atual, -200, 200)
	estercamento = move_toward(estercamento, estercamento_alvo, taxa_estercamento * delta)
	if not is_finite(estercamento):
		estercamento = 0.0
	if not is_finite(estercamento_alvo):
		print("[BUG] est_alvo not finite ", estercamento_alvo)
		estercamento_alvo = 0.0
	var escala_media := (global_scale.x + global_scale.y) * 0.5
	var entre_eixos_efetivo := entre_eixos * maxf(escala_media, 1.0)
	if entre_eixos_efetivo < 1.0:
		entre_eixos_efetivo = 60.0
	# Realista: só vira andando, sem drift/pivot parado
	if absf(velocidade_atual) > 1.0 and is_finite(velocidade_atual):
		rotation += velocidade_atual / entre_eixos_efetivo * tan(estercamento) * delta
	if not is_finite(rotation):
		rotation = 0.0
	var rate: float = 6.0 if velocidade_desejada < velocidade_atual else 5.0
	var prev_vel: float = velocidade_atual
	velocidade_atual = lerp(velocidade_atual, velocidade_desejada, clamp(rate * delta, 0.0, 1.0))
	if absf(velocidade_atual) < 1.0 and absf(velocidade_desejada) > 50.0:
		print("[SLOW] vel ", velocidade_atual, " desejada ", velocidade_desejada, " df ", distancia_centro(), " dlat ", distancia_lateral(), " pos ", global_position)
	if absf(velocidade_atual) > 500.0:
		print("[BUG] vel explosion lerp prev=", prev_vel, " desejada=", velocidade_desejada, " curr=", velocidade_atual, " delta=", delta, " rate=", rate)
		velocidade_atual = clampf(velocidade_atual, -200.0, 200.0)
	if absf(velocidade_desejada) < 0.01 and absf(velocidade_atual) < 0.5:
		velocidade_atual = 0.0
	if not velocity.is_finite():
		velocity = Vector2.ZERO
		velocidade_atual = 0.0
		return
	var dir_trilha := Vector2.RIGHT.rotated(rotation)
	velocity = dir_trilha * velocidade_atual
	if not velocity.is_finite() or velocity.length_squared() < 0.0001:
		velocity = Vector2.ZERO
		return
	var movimento := velocity * delta
	if not movimento.is_finite():
		print("[BUG] movimento INF vel=", velocity, " delta=", delta)
		velocity = Vector2.ZERO
		velocidade_atual = 0.0
		return
	# Clamp contra teleporte (delta grande no primeiro frame de construir)
	movimento = movimento.limit_length(8.0)
	if movimento.length_squared() < 0.001:
		velocity = Vector2.ZERO
		return
	var col := move_and_collide(movimento)
	if col != null:
		var n := col.get_normal()
		if not n.is_finite() or n.length_squared() < 0.25 or not n.is_normalized():
			velocity = Vector2.ZERO
			velocidade_atual = 0.0
			return
		velocity = velocity.slide(n)
		if velocity.is_finite():
			velocidade_atual = velocity.length()
		return
	# Sem colisão: garante sem drift lateral
	if velocity.is_finite() :
		var dir = Vector2.RIGHT.rotated(rotation)
		velocity = velocity.dot(dir) * dir
		velocidade_atual = velocity.dot(dir)


func _velocidade_por_sensor() -> float:
	# Humano: considera centro e lateral — parede ao lado também freia
	var dist_c := distancia_centro()
	var dist_lat := distancia_lateral()
	var dist := minf(dist_c, dist_lat * 1.4)
	if dist == INF:
		return velocidade_maxima
	if dist <= distancia_seguranca:
		return 0.0
	return clampf((dist - distancia_seguranca) / (distancia_freio - distancia_seguranca), 0.0, 1.0) * velocidade_maxima

func _velocidade_aproximacao_vaga(vel_base: float) -> float:
	# Perfil CONTÍNUO de aproximação (sem degraus): cruzeiro até ~450px da
	# vaga, descendo suave até ~26px/s a 40px. Usado no modo trilha E no
	# ALINHANDO para não haver salto de velocidade na troca de estado
	# (a Boca da vaga dispara ALINHANDO longe, e os caps diferentes dos dois
	# estados é que causavam "desacelerada" no meio da rua).
	var alvo: Vector2
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		alvo = _vaga_alvo.global_position
	elif posicao_alvo != Vector2.ZERO:
		alvo = posicao_alvo
	else:
		return vel_base
	var d: float = global_position.distance_to(alvo)
	if d >= 450.0:
		return vel_base
	var vel_cruzeiro: float = velocidade_maxima * 0.85
	var v_perfil: float = remap(clampf(d, 40.0, 450.0), 40.0, 450.0, 26.0, vel_cruzeiro)
	return minf(vel_base, v_perfil)


func _perto_da_vaga_para_snap() -> bool:
	# O snap ("desliza pra dentro da vaga") só vale bem perto. Em fases com
	# vaga escalada (ex. Fase3, 6.4x2.9) o teste de 100% dentro dispara ainda
	# NA RUA (~200px), e o lerp do snap parecia uma "acelerada fantasma"
	# com velocidade zero no final.
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		return global_position.distance_to(_vaga_alvo.global_position) < 80.0
	return global_position.distance_to(posicao_alvo) < 80.0


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
				estercamento_alvo = clampf(erro_ant * 3.0 + lado * 0.9, -max_estercamento, max_estercamento)
				velocidade_desejada = minf(velocidade_antecipacao, _velocidade_por_sensor())
				_aplicar_movimento(delta)
				return

	# Se qualquer raio frontal (curto) mede algo a menos de distancia_desvio,
	# hora de desviar. (pulado durante a "graça" da recuperação)
	if tempo_ignorar_sensor <= 0.0 and distancia_frente() < distancia_desvio:
		_mudar_estado(Estado.DESVIANDO)
		return

	# Aponta o volante para o waypoint. Humano vira até o fim quando precisa.
	var alvo: Vector2 = waypoints[indice_waypoint]
	var angulo_erro: float = angle_difference(rotation, global_position.direction_to(alvo).angle())
	# Preferência por seta (se houver, mistura 35% da direção da seta)
	var dir_seta := _obter_direcao_seta()
	if dir_seta != INF:
		var erro_seta := angle_difference(rotation, dir_seta)
		angulo_erro = lerp(angulo_erro, erro_seta, 0.35)
	# Deadband reta: não oscila se já está quase reto e perto da linha
	var cte_b: float = INF
	for i in range(waypoints.size() - 1):
		var p2 := Geometry2D.get_closest_point_to_segment(global_position, waypoints[i], waypoints[i + 1])
		cte_b = minf(cte_b, global_position.distance_to(p2))
	var deadband: bool = cte_b < 20.0 and absf(angulo_erro) < 0.15
	estercamento_alvo = PurePursuit.solve_error(angulo_erro, max_estercamento, 3.0, deadband).steering

	# Humano freia suave quando quer virar — preditivo por curvatura
	var curv := _curvatura_a_frente()
	var v_curva: float = sqrt(0.9 / max(curv, 0.015))
	var base_vel := _velocidade_por_sensor()
	base_vel = minf(base_vel, v_curva * 1.1)
	# Freio proporcional suave
	var fator_curva: float = 1.0 - minf(absf(angulo_erro) / max_estercamento, 1.0) * 0.4
	base_vel *= fator_curva
	# Freio extra suave para curva forte (sem degrau)
	if absf(angulo_erro) > 0.7:
		var t: float = clampf((absf(angulo_erro) - 0.7) / 0.3, 0.0, 1.0)
		base_vel *= lerp(0.75, 0.5, t)
	velocidade_desejada = base_vel

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
		estercamento_alvo = PurePursuit.solve_error(erro_fim, max_estercamento, 1.2, false).steering
		velocidade_desejada = velocidade_alinhamento * 0.5
		_aplicar_movimento(delta)
		return

	# Pure pursuit sobre a rota A*
	var alvo := _ponto_lookahead(distancia_lookahead)
	var erro: float = angle_difference(rotation, global_position.direction_to(alvo).angle())
	var dir_seta2 := _obter_direcao_seta()
	if dir_seta2 != INF:
		var erro_s := angle_difference(rotation, dir_seta2)
		erro = lerp(erro, erro_s, 0.3)
	# Deadband para não oscilar em reta: se CTE <20 e erro pequeno, suaviza
	var cte: float = INF
	for i in range(waypoints.size() - 1):
		var p := Geometry2D.get_closest_point_to_segment(global_position, waypoints[i], waypoints[i + 1])
		cte = minf(cte, global_position.distance_to(p))
	var deadband: bool = cte < 20.0 and absf(erro) < 0.15
	estercamento_alvo = PurePursuit.solve_error(erro, max_estercamento, 2.8, deadband).steering
	# Freio suave preditivo
	var curv2 := _curvatura_a_frente()
	var v_curva2: float = sqrt(0.9 / max(curv2, 0.015))
	var base_vel2 := _velocidade_por_sensor()
	base_vel2 = minf(base_vel2, v_curva2 * 1.1)
	var fator_curva2: float = 1.0 - minf(absf(erro) / max_estercamento, 1.0) * 0.4
	base_vel2 *= fator_curva2
	if absf(erro) > 0.7:
		var t2: float = clampf((absf(erro) - 0.7) / 0.3, 0.0, 1.0)
		base_vel2 *= lerp(0.75, 0.5, t2)
	velocidade_desejada = base_vel2
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


func _curvatura_a_frente() -> float:
	if waypoints.size() < indice_waypoint + 3:
		return 0.0
	var p1: Vector2 = waypoints[indice_waypoint]
	var p2: Vector2 = waypoints[indice_waypoint + 1]
	var p3: Vector2 = waypoints[indice_waypoint + 2]
	var v1: Vector2 = (p2 - p1).normalized()
	var v2: Vector2 = (p3 - p2).normalized()
	var ang: float = absf(v1.angle_to(v2))
	var dist: float = p1.distance_to(p2) + p2.distance_to(p3)
	if dist < 10.0:
		return 0.0
	return ang / (dist * 0.5)


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
	if modo_trilha:
		_replanejar_ou_recuperar_trilha()
		return
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


func _rotas_iguais(primeira: Array, segunda: Array) -> bool:
	if primeira.size() != segunda.size():
		return false
	for i in range(primeira.size()):
		if (primeira[i] as Vector2).distance_squared_to(segunda[i] as Vector2) > 1.0:
			return false
	return true


func _alvo_trilha() -> Vector2:
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		return _vaga_alvo.global_position
	if not waypoints.is_empty():
		return waypoints[waypoints.size() - 1]
	return global_position


func _pedir_nova_vaga_trilha() -> void:
	_sem_vagas = true
	velocidade_desejada = 0.0
	estercamento_alvo = 0.0
	pedir_nova_vaga.emit()


func _replanejar_ou_recuperar_trilha() -> void:
	_tempo_parado = 0.0
	var fb: Array = _coletar_rota_fallback()
	if fb.size() < 2:
		_pedir_nova_vaga_trilha()
		return
	if _rotas_iguais(fb, _rota_trilha_anterior):
		if planejador != null:
			var rota: Array = planejador.achar_rota(global_position, _alvo_trilha())
			if rota.size() >= 2 and not _rotas_iguais(rota, _rota_trilha_anterior):
				_aplicar_rota(rota)
				tentativa_mudou.emit(0, "Trilha: fallback repetido; replanejamento A*")
				return
		_pedir_nova_vaga_trilha()
		return
	_aplicar_rota(fb)
	tentativa_mudou.emit(0, "Trilha: replanejamento com Line2D")


func _coletar_rota_fallback() -> Array:
	# Tenta montar trilha a partir de Rotas Line2D (ruas desenhadas) + Waypoints
	var rotas_node := get_node_or_null("../Rotas")
	if rotas_node != null:
		var linhas: Array = []
		for child in rotas_node.get_children():
			if child is Line2D:
				var pts: PackedVector2Array = child.points
				if pts.size() < 2:
					continue
				var glob: Array = []
				for p in pts:
					glob.append(child.to_global(p))
				linhas.append(glob)
		if linhas.size() > 0:
			# Concatena todas as linhas em ordem, corrigindo orientação entre segmentos
			# para garantir continuidade geométrica (o fim de uma rota deve estar perto
			# do início da próxima, ou então inverter a próxima).
			var todas: Array = []
			var fim_anterior: Vector2 = Vector2.ZERO
			var primeira = true
			for linha in linhas:
				if linha.size() < 2:
					continue
				# Decide se deve inverter este segmento baseado na proximidade
				# com o fim da rota anterior
				if not primeira and linha.size() >= 2:
					var d_comeco := fim_anterior.distance_to(linha[0])
					var d_fim := fim_anterior.distance_to(linha[linha.size()-1])
					if d_fim < d_comeco:
						var invertida: Array = []
						for i in range(linha.size()-1, -1, -1):
							invertida.append(linha[i])
						linha = invertida
				# Remove ponto duplicado na junção entre segmentos
				if not primeira and todas.size() > 0:
					var ultimo: Vector2 = todas[todas.size()-1]
					var primeiro_agora: Vector2 = linha[0]
					if ultimo.distance_to(primeiro_agora) < 5.0:
						var sem_dup: Array = []
						for i in range(1, linha.size()):
							sem_dup.append(linha[i])
						linha = sem_dup
				for p in linha:
					todas.append(p)
				if linha.size() > 0:
					fim_anterior = linha[linha.size()-1]
				primeira = false
			if todas.size() >= 2:
				return todas
			# Escolhe a linha cujo início está mais perto do carro e cujo fim está mais perto da vaga
			var melhor: Array = []
			var melhor_score: float = INF
			var alvo_vaga: Vector2 = _vaga_alvo.global_position if _vaga_alvo != null else global_position
			for linha in linhas:
				var d_ini: float = global_position.distance_to(linha[0])
				var d_fim: float = alvo_vaga.distance_to(linha[linha.size()-1]) if linha.size() > 0 else INF
				var score: float = d_ini * 0.7 + d_fim * 0.3
				if score < melhor_score:
					melhor_score = score
					melhor = linha
			if melhor.size() >= 2:
				return melhor
	# Fallback 2: Waypoints manuais (array interno ou nós da cena)
	if not waypoints.is_empty():
		return Array(waypoints)
	var wp_node := get_node_or_null("../Waypoints")
	if wp_node != null and wp_node.get_child_count() >= 2:
		var arr: Array = []
		for c in wp_node.get_children():
			if c is Marker2D:
				arr.append(c.global_position)
		if arr.size() >= 2:
			return arr
	# Fallback 3: linha reta até vaga
	if _vaga_alvo != null:
		return [global_position, _vaga_alvo.global_position]
	# Fallback 4: se ainda nada, tenta vaga mais próxima sem rota
	if container_vagas != null:
		for v in container_vagas.get_children():
			if not v.ocupada:
				return [global_position, v.global_position]
	return []


func _construir_rota_sequencial_ruas() -> Array:
	# Ordem CORRETA solicitada: RotaReta -> RotaDaCurva -> RotaReta2
	var rotas_node := get_node_or_null("../Rotas")
	if rotas_node == null or container_vagas == null:
		return []
	var vaga_escolhida: Node2D = null
	var menor_dist: float = INF
	for v in container_vagas.get_children():
		if v.ocupada:
			continue
		var d: float = global_position.distance_to(v.global_position)
		if d < menor_dist:
			menor_dist = d
			vaga_escolhida = v
	if vaga_escolhida == null:
		return []
	_vaga_alvo = vaga_escolhida
	var ordem: Array = []
	# Ordem visual: segue a ordem dos filhos no nó Rotas (como arrumado no editor)
	for child in rotas_node.get_children():
		if child is Line2D:
			ordem.append(child.name)
	var rua: Array = []
	rua.append(global_position)
	# Calcula ponto de preparação antes da vaga (mesma fórmula de preparar_estacionamento)
	var dir_vaga := Vector2.RIGHT.rotated(_vaga_alvo.rotacao_alvo)
	var ponto_prep := _vaga_alvo.global_position - dir_vaga * (entre_eixos * 2.5 + 80.0)
	for nome in ordem:
		var line: Line2D = rotas_node.get_node_or_null(NodePath(nome)) as Line2D
		if line == null:
			continue
		var pts: PackedVector2Array = line.points
		if pts.size() < 2:
			continue
		# Converte pontos locais para global, respeitando position/rotation/scale da Line2D
		var glob: Array = []
		for p in pts:
				glob.append(line.to_global(p))
		# DETECÇÃO DE ORIENTAÇÃO: verifica se a próxima Line2D deve ser
		# percorrida no sentido original ou invertido para manter continuidade
		if rua.size() >= 1 and glob.size() >= 2:
			var dist_inicio = rua[rua.size()-1].distance_to(glob[0])
			var dist_fim = rua[rua.size()-1].distance_to(glob[glob.size()-1])
			# Se o último ponto da rota atual está mais próximo do FIM da próxima,
			# inverte a ordem para que o carro siga no sentido correto
			if dist_fim < dist_inicio:
				glob = _inverter_array(glob)
		# Transição suave com pontos interpolados (evita parada brusca)
		if rua.size() >= 1:
			var gap: float = rua[rua.size()-1].distance_to(glob[0])
			# Sempre faz blend de transicao para suavizar, especialmente em curvas
			var num_pontos_blend: int = 10
			if gap > 40.0:
				# Gap grande: interpolated points para suavizar
				for s in range(1, num_pontos_blend + 1):
					var t: float = float(s) / (num_pontos_blend + 1)
					t = t * t * (3.0 - 2.0 * t) # ease-in-out
					rua.append(rua[rua.size()-1].lerp(glob[0], t))
				for i in range(glob.size()):
					if rua[rua.size()-1].distance_to(glob[i]) > 8.0:
						rua.append(glob[i])
			else:
				# Gap pequeno ou negativo: adiciona pontos do glob diretamente
				# mas ignora pontos muito proximos do ultimo para evitar zigue-zague
				for i in range(glob.size()):
					if i == 0 and rua[rua.size()-1].distance_to(glob[0]) < 20.0:
						continue # Pula o primeiro se esta muito proximo
					if rua[rua.size()-1].distance_to(glob[i]) > 10.0:
						rua.append(glob[i])
	# Só adiciona ponto_prep se não estiver muito longe da última parte da rua (evita zig-zag)
	if rua[rua.size()-1].distance_to(ponto_prep) > 15.0:
		# Suaviza com ponto intermediário
		var mid_prep: Vector2 = rua[rua.size()-1].lerp(ponto_prep, 0.5)
		rua.append(mid_prep)
		rua.append(ponto_prep)
	# Filtra e suaviza com Douglas-Peucker leve (12px) para tirar micro-zigue-zague
	var filtrada: Array = []
	for pt in rua:
		if filtrada.is_empty() or filtrada[filtrada.size()-1].distance_to(pt) > 10.0:
			filtrada.append(pt)
	return filtrada


func _inverter_array(arr: Array) -> Array:
	var invertido: Array = []
	for i in range(arr.size() - 1, -1, -1):
		invertido.append(arr[i])
	return invertido


func _processar_trilha(delta: float) -> void:
	if absf(velocidade_atual) > 500:
		print("[BUG] entry vel huge ", velocidade_atual, " desejada ", velocidade_desejada, " estado ", nome_estado(), " pos ", global_position)
		velocidade_atual = clampf(velocidade_atual, -200, 200)
	_deslocamento_total += global_position.distance_to(_posicao_anterior)
	_posicao_anterior = global_position
	_atualizar_progresso(delta)
	# Se 100% dentro E perto, PARA imediatamente (lógica principal solicitada).
	# O gate de distância evita o snap "fantasma" em vagas escaladas, onde
	# "100% dentro" acontece ainda na rua.
	if _esta_100_dentro_da_vaga() and _perto_da_vaga_para_snap():
		var _err_inside: float = angle_difference(rotation, rotacao_alvo)
		if absf(_err_inside) < 0.20:
			estercamento_alvo = 0.0
			velocidade_desejada = 0.0
			velocity = Vector2.ZERO
			velocidade_atual = 0.0
			global_position = global_position.lerp(posicao_alvo, delta * 6.0)
			rotation = lerp_angle(rotation, rotacao_alvo, delta * 6.0)
			if absf(_err_inside) < tolerancia_alinhamento and global_position.distance_to(posicao_alvo) < 12.0:
				if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
					_vaga_alvo.marcar_ocupada()
				_mudar_estado(Estado.ESTACIONADO)
			return
	var _seg_tmp: float = 44.0 * maxf((global_scale.x + global_scale.y)*0.5, 1.0) + 22.0
	_seg_tmp = maxf(_seg_tmp, 48.0)
	var _frente_tmp: bool = distancia_centro() < _seg_tmp
	# Travamento só se não está parado por obstáculo frontal (evita replanejar em loop)
	if not _frente_tmp and _detectar_travamento_rota():
		_replanejar_ou_recuperar_trilha()
		return
	# --- PARADA por obstáculo: no modo trilha o carro NÃO desvia, só PARA ---
	var escala_media_trilha := (global_scale.x + global_scale.y) * 0.5
	var seg_trilha: float = 44.0 * maxf(escala_media_trilha, 1.0) + 22.0
	seg_trilha = maxf(seg_trilha, 48.0)
	var df_trilha := distancia_centro()
	var frente_bloqueada: bool = false # df_trilha < seg_trilha # disabled for test
	if frente_bloqueada and tempo_ignorar_sensor <= 0.0:
		_tempo_parado += delta
		if _tempo_parado < 0.7:
			# Para e volante reto
			estercamento_alvo = move_toward(estercamento_alvo, 0.0, delta * 3.0)
			velocidade_desejada = 0.0
		elif _tempo_parado < 1.6:
			# Ré curta com volante para sair do bloqueio (realista, gira andando de ré)
			var alvo_r := _ponto_lookahead(distancia_lookahead)
			var err_r: float = angle_difference(rotation, global_position.direction_to(alvo_r).angle())
			estercamento_alvo = PurePursuit.solve_error(-err_r, max_estercamento, -0.9, false).steering
			velocidade_desejada = -velocidade_alinhamento * 0.45
			if distancia_tras() < seg_trilha:
				velocidade_desejada = 0.0
				estercamento_alvo = 0.0
		else:
			estercamento_alvo = move_toward(estercamento_alvo, 0.0, delta * 3.0)
			velocidade_desejada = 0.0
		_aplicar_movimento_trilha(delta)
		if _tempo_parado > tempo_parado_replanejar:
			_replanejar_ou_recuperar_trilha()
		return
	else:
		_tempo_parado = 0.0
	# Chegada no fim da rota: aproxima devagar
	if waypoints.size() >= 1:
		var fim_rota: Vector2 = waypoints[waypoints.size() - 1]
		if indice_waypoint >= waypoints.size() - 1 and global_position.distance_to(fim_rota) < tolerancia_chegada * 2.5:
			var erro_fim: float = angle_difference(rotation, global_position.direction_to(fim_rota).angle())
			estercamento_alvo = PurePursuit.solve_error(erro_fim, max_estercamento, 1.2, false).steering
			velocidade_desejada = velocidade_alinhamento * 0.5
			_aplicar_movimento_trilha(delta)
			return
	# Pure pursuit sobre a trilha
	var alvo := _ponto_lookahead(distancia_lookahead)
	var erro: float = angle_difference(rotation, global_position.direction_to(alvo).angle())
	var dir_seta2 := _obter_direcao_seta()
	if dir_seta2 != INF:
		var erro_s := angle_difference(rotation, dir_seta2)
		erro = lerp(erro, erro_s, 0.2)
	var cte: float = INF
	for i in range(waypoints.size() - 1):
		var p := Geometry2D.get_closest_point_to_segment(global_position, waypoints[i], waypoints[i + 1])
		cte = minf(cte, global_position.distance_to(p))
	estercamento_alvo = PurePursuit.solve_error(erro, max_estercamento, 2.2, false).steering
	var curv2 := _curvatura_a_frente()
	var v_curva2: float = velocidade_maxima
	if curv2 > 0.05:
		v_curva2 = sqrt(30.0 / curv2)
		v_curva2 = maxf(v_curva2, 45.0)
	var dist_vaga_fim: float = global_position.distance_to(_vaga_alvo.global_position) if _vaga_alvo else INF
	var base_vel2: float
	if dist_vaga_fim > 350.0:
		# Longe da vaga: velocidade constante na rua, sem frenagem de sensor
		base_vel2 = velocidade_maxima * 0.85
		base_vel2 = minf(base_vel2, v_curva2 * 1.1)
	else:
		base_vel2 = _velocidade_por_sensor()
		base_vel2 = minf(base_vel2, v_curva2 * 1.1)
		base_vel2 = minf(base_vel2, velocidade_maxima)
	# limita ao max de trilha para não correr demais em mapa grande
	base_vel2 = minf(base_vel2, velocidade_trilha_max * maxf(escala_media_trilha, 1.0))
	var fator_curva2: float = 1.0 - minf(absf(erro) / max_estercamento, 1.0) * 0.25
	base_vel2 *= fator_curva2
	if absf(erro) > 0.7:
		var t2: float = clampf((absf(erro) - 0.7) / 0.3, 0.0, 1.0)
		base_vel2 *= lerp(0.85, 0.65, t2)
	# Frenagem CONTÍNUA na aproximação da vaga (mesmo perfil do ALINHANDO,
	# sem degraus de 75/45/28 que davam sensação de freio seco)
	base_vel2 = _velocidade_aproximacao_vaga(base_vel2)
	velocidade_desejada = base_vel2
	_aplicar_movimento_trilha(delta)
	_avancar_indice_rota()


func _processar_alinhando_trilha(delta: float) -> void:
	# Se 100% dentro da vaga, PARA imediatamente. Nao continua
	# nem vira para evitar bater. Rotaciona em lugar se desalinhado.
	if _esta_100_dentro_da_vaga():
		var _err: float = angle_difference(rotation, rotacao_alvo)
		estercamento_alvo = 0.0
		velocidade_desejada = 0.0
		velocity = Vector2.ZERO
		velocidade_atual = 0.0
		global_position = global_position.lerp(posicao_alvo, delta * 6.0)
		rotation = lerp_angle(rotation, rotacao_alvo, delta * 6.0)
		if absf(_err) < tolerancia_alinhamento:
			if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
				_vaga_alvo.marcar_ocupada()
			_mudar_estado(Estado.ESTACIONADO)
		return
	# Usa ponto_prep se houver waypoints (preparação realista)
	if not waypoints.is_empty() and indice_waypoint < waypoints.size():
		var alvo_wp: Vector2 = waypoints[indice_waypoint]
		var dist_wp: float = global_position.distance_to(alvo_wp)
		if dist_wp < tolerancia_chegada:
			indice_waypoint += 1
			if indice_waypoint < waypoints.size():
				alvo_wp = waypoints[indice_waypoint]
			else:
				alvo_wp = posicao_alvo
		# Se ainda tem waypoint intermediário, vai até ele primeiro
		if indice_waypoint < waypoints.size() - 1 or (waypoints.size() == 1 and dist_wp > tolerancia_chegada):
			var ang_wp: float = global_position.direction_to(alvo_wp).angle()
			var err_wp: float = angle_difference(rotation, ang_wp)
			estercamento_alvo = clampf(err_wp * 1.8, -max_estercamento, max_estercamento)
			# Mesmo perfil da trilha: cruzeiro longe, frenagem contínua perto
			# (sem o cap 84 que dava o degrau 135->84 na boca da vaga)
			var base_wp: float = _velocidade_por_sensor()
			base_wp = minf(base_wp, velocidade_maxima * 0.85)
			base_wp = _velocidade_aproximacao_vaga(base_wp)
			if absf(err_wp) > 0.7:
				base_wp *= 0.45
			elif absf(err_wp) > 0.4:
				base_wp *= 0.7
			velocidade_desejada = base_wp
			if distancia_lateral() < 35.0:
				velocidade_desejada *= 0.5
			if distancia_centro() < distancia_seguranca * 1.2:
				velocidade_desejada = 0.0
			_aplicar_movimento_trilha(delta)
			# Checagem de vaga só quando no último waypoint
			var _dist_vaga: float = global_position.distance_to(posicao_alvo)
			var _erro_vaga: float = angle_difference(rotation, rotacao_alvo)
			if _esta_100_dentro_da_vaga() and absf(_erro_vaga) < tolerancia_alinhamento and _dist_vaga < 12.0:
				if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
					_vaga_alvo.marcar_ocupada()
				_mudar_estado(Estado.ESTACIONADO)
			return
	var distancia: float = global_position.distance_to(posicao_alvo)
	var erro: float = angle_difference(rotation, rotacao_alvo)
	if distancia > tolerancia_chegada * 2.0:
		var angulo: float = global_position.direction_to(posicao_alvo).angle()
		var erro_approach := angle_difference(rotation, angulo)
		estercamento_alvo = clampf(erro_approach * 1.8, -max_estercamento, max_estercamento)
		velocidade_desejada = _velocidade_aproximacao_vaga(75.0)
		if absf(erro_approach) > 0.6:
			velocidade_desejada = _velocidade_aproximacao_vaga(45.0)
		if distancia_centro() < distancia_seguranca:
			velocidade_desejada = 0.0
	else:
		if _esta_100_dentro_da_vaga() and absf(erro) > 0.08:
			# Dentro da vaga: gira parado suave para alinhar (único lugar permitido)
			estercamento_alvo = 0.0
			velocidade_desejada = 0.0
			rotation = lerp_angle(rotation, rotacao_alvo, delta * 2.0)
		elif absf(erro) > 0.7:
			estercamento_alvo = -sign(erro) * max_estercamento * 0.75
			velocidade_desejada = -_velocidade_reversa() * 0.55
			if distancia_tras() < distancia_seguranca:
				velocidade_desejada = 0.0
		elif absf(erro) > 0.35:
			estercamento_alvo = clampf(erro * 1.8, -max_estercamento, max_estercamento)
			velocidade_desejada = velocidade_alinhamento * 0.65
		else:
			estercamento_alvo = clampf(erro * 2.2, -max_estercamento, max_estercamento)
			var alinhado: bool = absf(erro) < tolerancia_alinhamento
			if alinhado:
				velocidade_desejada = velocidade_alinhamento * 0.5
				if distancia < 12.0:
					velocidade_desejada *= 0.45
			else:
				if distancia > 14.0:
					velocidade_desejada = velocidade_alinhamento * 0.3
				else:
					velocidade_desejada = velocidade_alinhamento * 0.18
	_aplicar_movimento_trilha(delta)
	if _esta_100_dentro_da_vaga() and absf(erro) < tolerancia_alinhamento and distancia < 12.0:
		if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
			_vaga_alvo.marcar_ocupada()
		_mudar_estado(Estado.ESTACIONADO)
	elif distancia < 9.0 and absf(erro) < 0.22 and _esta_100_dentro_da_vaga():
		if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
			_vaga_alvo.marcar_ocupada()
		_mudar_estado(Estado.ESTACIONADO)


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
	# Estacionamento humano: aproxima, se torto faz ré esterçada, ajuste fino
	var distancia: float = global_position.distance_to(posicao_alvo)
	var erro: float = angle_difference(rotation, rotacao_alvo)
	if distancia > tolerancia_chegada * 2.5:
		var angulo: float = global_position.direction_to(posicao_alvo).angle()
		var erro_approach := angle_difference(rotation, angulo)
		estercamento_alvo = clampf(erro_approach * 1.8, -max_estercamento, max_estercamento)
		# Freia para virar — habilidade de frear quando quer
		var base_a := _velocidade_por_sensor() * 0.6
		if absf(erro_approach) > 0.7:
			base_a *= 0.45
		elif absf(erro_approach) > 0.4:
			base_a *= 0.7
		velocidade_desejada = base_a
		var lat := distancia_lateral()
		if lat < 35.0:
			velocidade_desejada *= 0.5
	else:
		# Perto da vaga: precisa ficar reto
		if absf(erro) > 0.7:
			# Muito torto: ré esterçada como humano (manobra 3 tempos simplificada)
			estercamento_alvo = -sign(erro) * max_estercamento * 0.9
			velocidade_desejada = -_velocidade_reversa() * 0.7
			if distancia_tras() < distancia_seguranca + 12.0:
				estercamento_alvo = sign(erro) * max_estercamento * 0.5
				velocidade_desejada = _velocidade_por_sensor() * 0.3
		else:
			estercamento_alvo = clampf(erro * 2.2, -max_estercamento, max_estercamento)
			var alinhado: bool = absf(erro) < tolerancia_alinhamento
			if alinhado:
				# Reto: entra devagar
				velocidade_desejada = velocidade_alinhamento * 0.6
				if distancia < 12.0:
					velocidade_desejada *= 0.5
			else:
				# Quase: pequeno ajuste frente/ré
				if distancia > 14.0:
					velocidade_desejada = velocidade_alinhamento * 0.35
				else:
					velocidade_desejada = -_velocidade_reversa() * 0.4

	_aplicar_movimento(delta)

	# Só estaciona se 100% dentro da vaga (humano) e não em cima de calçada
	if _esta_100_dentro_da_vaga() and absf(erro) < tolerancia_alinhamento and distancia < 12.0:
		if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
			_vaga_alvo.marcar_ocupada()
		_mudar_estado(Estado.ESTACIONADO)
	elif distancia < 10.0 and absf(erro) < tolerancia_alinhamento and _esta_100_dentro_da_vaga():
		if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
			_vaga_alvo.marcar_ocupada()
		_mudar_estado(Estado.ESTACIONADO)


func _processar_estacionado(delta: float) -> void:
	# Trava bonitinho: interpola até o centro exato da vaga com rotação perfeita
	var dano_pos := posicao_alvo - global_position
	var erro_rot := angle_difference(rotation, rotacao_alvo)
	# Se já está bem perto, trava duro
	if dano_pos.length() < 8.0 and absf(erro_rot) < 0.08:
		global_position = global_position.lerp(posicao_alvo, delta * 6.0)
		rotation = lerp_angle(rotation, rotacao_alvo, delta * 6.0)
		velocidade_atual = move_toward(velocidade_atual, 0.0, frenagem * delta * 2.0)
		velocity = Vector2.ZERO
		estercamento = 0.0
		estercamento_alvo = 0.0
		# ESTACIONADO: posicionado via lerp acima. move_and_slide com
		# velocidade zero dispara "normal (0.0, 0.0) must be normalized"
		# (Godot #94928); o frame físico é intencionalmente ignorado.
		return
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
	distancia_inicio_waypoint = global_position.distance_to(waypoints[indice_waypoint]) if indice_waypoint < waypoints.size() else 0.0
	contador_oscilacao = 0

	if tentativas == 1:
		# Paralelo por manobra: avalia 3 estratégias via corrotina com snapshot
		_tentar_manoabras_paralelo()
		return
	elif tentativas == 2:
		# 2ª: desvio lateral (contorna) — já avaliado no paralelo, mas mantém fallback
		estrategia = 1
		_inserir_waypoint_desvio()
		tempo_ignorar_sensor = 0.5
		_mudar_estado(Estado.BUSCANDO)
	elif tentativas == 3:
		# 3ª: em trilha, o recovery já tenta A* se o fallback Line2D repetir.
		estrategia = 2
		if modo_trilha:
			# Modo trilha: usa fallback Line2D em vez de A*
			var fb_alt: Array = _coletar_rota_fallback()
			if fb_alt.size() >= 2:
				_aplicar_rota(fb_alt)
				tentativa_mudou.emit(tentativas, "Replanejou (trilha - Line2D)")
				_mudar_estado(Estado.BUSCANDO)
				return
		elif planejador != null:
			# Não é modo trilha: tenta rota alternativa com inflar reduzido temporariamente
			var inflar_original = planejador.inflar
			planejador.inflar = 50.0
			planejador.construir()
			var alvo: Vector2 = _vaga_alvo.global_position if _vaga_alvo != null else waypoints[waypoints.size()-1]
			var nova_rota: Array = planejador.achar_rota(global_position, alvo)
			planejador.inflar = inflar_original
			planejador.construir()
			if nova_rota.size() >= 2:
				_aplicar_rota(nova_rota)
				tentativa_mudou.emit(tentativas, "Replanejou (humano)")
				_mudar_estado(Estado.BUSCANDO)
				return
		# Se não conseguiu nova rota, faz ré simples
		tempo_estrategia = 0.0
		_mudar_estado(Estado.RECUPERANDO)
	elif tentativas < max_tentativas_por_waypoint:
		# 4ª: ré prolongada
		estrategia = 2
		tempo_estrategia = 0.0
		_mudar_estado(Estado.RECUPERANDO)
	else:
		# Só agora desiste da vaga e escolhe próxima (agêntico)
		estrategia = 3
		_desistir_waypoint()
		if tentativas >= max_tentativas_por_waypoint and _vaga_alvo != null:
			# Marca vaga atual como tentada e pede nova
			pedir_nova_vaga.emit()
		_mudar_estado(Estado.BUSCANDO)

	tentativa_mudou.emit(tentativas, ESTRATEGIAS[estrategia])


func _tentar_manoabras_paralelo() -> void:
	# Paralelo por manobra via corrotina await (3 fantasmas)
	if modo_trilha:
		# Em modo trilha, não usar A*/snapshot para manobras - usar estratégia simples
		estrategia = 0
		fase_manobra = 1
		tempo_estrategia = 0.0
		# Ré simples para trás para sair do impasse, com estercamento suave
		velocidade_desejada = -velocidade_alinhamento * 0.4
		if _vaga_alvo != null:
			var dir_alerte: float = angle_difference(rotation, _vaga_alvo.global_position.direction_to(global_position).angle())
			estercamento_alvo = clampf(-dir_alerte * 0.8, -max_estercamento, max_estercamento)
		else:
			estercamento_alvo = 0.0
		_mudar_estado(Estado.RECUPERANDO)
		tentativa_mudou.emit(tentativas, ESTRATEGIAS[estrategia])
		return
	if planejador == null or _vaga_alvo == null:
		estrategia = 0
		fase_manobra = 1
		tempo_estrategia = 0.0
		vies_lado = _lado_com_mais_espaco()
		_mudar_estado(Estado.RECUPERANDO)
		tentativa_mudou.emit(tentativas, ESTRATEGIAS[estrategia])
		return
	var snap = planejador.snapshot()
	var alvo: Vector2 = _vaga_alvo.global_position
	# Simula 3 estratégias sem mover o corpo, usando snapshot
	var resultados: Array = []
	# Estratégia 0: manobra 3 tempos — precisa espaço lateral >50 e trás >40
	var espaco_lat_0 = minf(_distancia_do_raio(ray_esquerda), _distancia_do_raio(ray_lateral_esq))
	var espaco_lat_1 = minf(_distancia_do_raio(ray_direita), _distancia_do_raio(ray_lateral_dir))
	var score0: float = INF
	if maxf(espaco_lat_0, espaco_lat_1) > 50.0 and distancia_tras() > 40.0:
		score0 = 0.0
	resultados.append({"id":0, "score":score0, "nome":"Manobra de três tempos"})
	await get_tree().process_frame
	# Estratégia 1: contornar — waypoint lateral + rota snapshot
	var lado1: int = _lado_com_mais_espaco()
	var ponto1: Vector2 = global_position + Vector2(0, 1).rotated(rotation + lado1 * PI / 2.0) * distancia_waypoint_desvio
	var rota1: Array = planejador.achar_rota_snapshot(global_position, ponto1, snap)
	var score1: float = INF
	if rota1.size() >= 2:
		score1 = _comprimento_rota(rota1) * 0.8
	resultados.append({"id":1, "score":score1, "rota":rota1, "nome":"Contornar o obstáculo"})
	await get_tree().process_frame
	# Estratégia 2: replanejar com inflar 35
	var rota2: Array = []
	# Simula inflar 35 construindo grade local com celulas do snapshot mas com raio menor?
	# Aproxima: usa snapshot atual mas com peso menor, rota deve ser similar
	rota2 = planejador.achar_rota_snapshot(global_position, alvo, snap)
	var score2: float = INF
	if rota2.size() >= 2:
		score2 = _comprimento_rota(rota2) * 1.1
		if rota2.size() > 0:
			# Penaliza se passa muito perto de obstáculo (já inflado)
			score2 += 20.0
	resultados.append({"id":2, "score":score2, "rota":rota2, "nome":"Dar ré"})
	await get_tree().process_frame
	# Escolhe menor score viável
	resultados.sort_custom(func(a,b): return a.score < b.score)
	var melhor = resultados[0]
	if melhor.score == INF:
		# Nenhuma viável: fallback manobra
		estrategia = 0
		fase_manobra = 1
		tempo_estrategia = 0.0
		vies_lado = _lado_com_mais_espaco()
		_mudar_estado(Estado.RECUPERANDO)
	else:
		if melhor.id == 0:
			estrategia = 0
			fase_manobra = 1
			tempo_estrategia = 0.0
			vies_lado = _lado_com_mais_espaco()
			_mudar_estado(Estado.RECUPERANDO)
		elif melhor.id == 1:
			estrategia = 1
			# Reusa rota já calculada
			if melhor.rota.size() >= 2:
				_aplicar_rota(melhor.rota)
			else:
				_inserir_waypoint_desvio()
			tempo_ignorar_sensor = 0.5
			_mudar_estado(Estado.BUSCANDO)
		elif melhor.id == 2:
			estrategia = 2
			if melhor.rota.size() >= 2:
				_aplicar_rota(melhor.rota)
				_mudar_estado(Estado.BUSCANDO)
			else:
				tempo_estrategia = 0.0
				_mudar_estado(Estado.RECUPERANDO)
	tentativa_mudou.emit(tentativas, ESTRATEGIAS[estrategia] + " (paralelo)")


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
	var rays: Dictionary = _rays_dict()
	return minf(minf(_distancia_ray(rays, SensorArrayRef.FRONT_CENTER),
		_distancia_ray(rays, SensorArrayRef.FRONT_LEFT)),
		_distancia_ray(rays, SensorArrayRef.FRONT_RIGHT))


func distancia_centro() -> float:
	# Distância do raio CENTRAL: o que está mesmo à frente do carro.
	# É ela que manda na velocidade (freiar por um canto raspando = errado).
	return _distancia_ray(_rays_dict(), SensorArrayRef.FRONT_CENTER)


func distancia_lateral() -> float:
	# Menor distância lateral pura — humano sente parede ao lado
	var rays := _rays_dict()
	return minf(_distancia_ray(rays, SensorArrayRef.LATERAL_LEFT),
		_distancia_ray(rays, SensorArrayRef.LATERAL_RIGHT))


func _esta_100_dentro_da_vaga() -> bool:
	if _vaga_alvo == null or not is_instance_valid(_vaga_alvo):
		return false
	var forma_vaga: RectangleShape2D = _vaga_alvo.get_node("Area").shape
	if forma_vaga == null:
		return false
	var size_vaga: Vector2 = forma_vaga.size * _vaga_alvo.global_scale
	var rot_vaga: float = _vaga_alvo.rotacao_alvo if "rotacao_alvo" in _vaga_alvo else 0.0
	# Carro 4 cantos em mundo
	var forma_carro: RectangleShape2D = $CollisionShape2D.shape
	if forma_carro == null:
		return false
	var size_carro: Vector2 = forma_carro.size * global_scale
	var half: Vector2 = size_carro * 0.5
	var corners: Array[Vector2] = [
		global_position + Vector2(-half.x, -half.y).rotated(rotation),
		global_position + Vector2(half.x, -half.y).rotated(rotation),
		global_position + Vector2(half.x, half.y).rotated(rotation),
		global_position + Vector2(-half.x, half.y).rotated(rotation),
	]
	for p: Vector2 in corners:
		# Transforma ponto para espaço local da vaga (inverso da rotação da vaga)
		var local_vec: Vector2 = (p - _vaga_alvo.global_position).rotated(-rot_vaga)
		var half_vaga := size_vaga * 0.5
		if absf(local_vec.x) > half_vaga.x + 2.0 or absf(local_vec.y) > half_vaga.y + 2.0:
			return false
	# Proibir estar em cima de obstáculo (calçada) — grade sólida
	if planejador != null and planejador.grade_pronta():
		var cel = planejador._celula_de(global_position)
		if planejador._grade.is_point_solid(cel):
			return false
	return true


func distancia_tras() -> float:
	return _distancia_ray(_rays_dict(), SensorArrayRef.REAR)


func _rays_dict() -> Dictionary:
	# Single collection point for the extracted SensorArray contract.
	# @onready rays are children; collect_from is null-safe by design.
	return SensorArrayRef.collect_from(self)


func _distancia_ray(rays: Dictionary, ray_name: String) -> float:
	return SensorArrayRef.distance_of(rays.get(ray_name) as RayCast2D)


func _distancia_do_raio(raio: RayCast2D) -> float:
	if not raio.is_colliding():
		return INF
	# get_collision_point() devolve ONDE o raio bateu (posição global).
	return raio.global_position.distance_to(raio.get_collision_point())


func _obter_direcao_seta() -> float:
	if ray_seta != null and ray_seta.is_colliding():
		var col = ray_seta.get_collider()
		if col != null and col.has_method("get") and "direcao" in col:
			return col.direcao
		# Tenta via propriedade direta
		if col != null and col.get("direcao") != null:
			return col.get("direcao")
	return INF


func _lado_com_mais_espaco() -> int:
	# Mede folga nos dois lados e escolhe o maior. -1 = esquerda, 1 = direita.
	var rays := _rays_dict()
	var espaco_esq: float = minf(_distancia_ray(rays, SensorArrayRef.SIDE_LEFT),
		_distancia_ray(rays, SensorArrayRef.LATERAL_LEFT))
	var espaco_dir: float = minf(_distancia_ray(rays, SensorArrayRef.SIDE_RIGHT),
		_distancia_ray(rays, SensorArrayRef.LATERAL_RIGHT))
	return -1 if espaco_esq >= espaco_dir else 1


func _lado_com_mais_espaco_longe() -> int:
	# Igual ao de cima, mas usando a câmera de longo alcance: vê qual lado
	# tem mais espaço LÁ NA FRENTE (na altura do obstáculo), não ao lado do carro.
	var rays := _rays_dict()
	var espaco_esq: float = _distancia_ray(rays, SensorArrayRef.LONG_LEFT)
	var espaco_dir: float = _distancia_ray(rays, SensorArrayRef.LONG_RIGHT)
	return -1 if espaco_esq >= espaco_dir else 1


func _beco_confirmado() -> bool:
	# Confirma beco sem saída (usado quando os dois lados já estão fechados):
	# a parede longa está batendo E o waypoint está além dela (ou colado).
	var visao: float = _distancia_ray(_rays_dict(), SensorArrayRef.LONG_CENTER)
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
	var rays := _rays_dict()
	return _distancia_ray(rays, SensorArrayRef.SIDE_LEFT) < espaco_minimo_desvio \
		and _distancia_ray(rays, SensorArrayRef.SIDE_RIGHT) < espaco_minimo_desvio


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


# ================= MACHINE LEARNING (imitação) ===============================

func _ml_features() -> PackedFloat64Array:
	# 18 entradas da rede, todas normalizadas:
	#   [0..10]  distância dos 11 raios (0 = colado, 1 = livre)
	#   [11]     velocidade atual / velocidade_maxima
	#   [12]     distância até a vaga / 2500
	#   [13,14]  sin/cos do erro angular até a vaga
	#   [15..17] seta do piso: achou?(0/1) e cos/sin da direção relativa
	var f := PackedFloat64Array()
	# Column order is the DatasetRecorder contract (see its header doc).
	var rays := _rays_dict()
	var raios_nomes: Array[String] = [SensorArrayRef.FRONT_CENTER, SensorArrayRef.FRONT_LEFT,
		SensorArrayRef.FRONT_RIGHT, SensorArrayRef.SIDE_LEFT, SensorArrayRef.SIDE_RIGHT,
		SensorArrayRef.REAR, SensorArrayRef.LONG_CENTER, SensorArrayRef.LONG_LEFT,
		SensorArrayRef.LONG_RIGHT, SensorArrayRef.LATERAL_LEFT, SensorArrayRef.LATERAL_RIGHT]
	for ray_name in raios_nomes:
		var r: RayCast2D = rays.get(ray_name) as RayCast2D
		var alcance: float = maxf(r.target_position.length() if r != null else 1.0, 1.0)
		var d: float = _distancia_ray(rays, ray_name)
		f.append(clampf(d / alcance, 0.0, 1.0))
	f.append(clampf(velocidade_atual / velocidade_maxima, -1.0, 1.0))
	var alvo_v: Vector2 = posicao_alvo
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		alvo_v = _vaga_alvo.global_position
	var erro_v: float = angle_difference(rotation, global_position.direction_to(alvo_v).angle())
	f.append(clampf(global_position.distance_to(alvo_v) / 2500.0, 0.0, 1.0))
	f.append(sin(erro_v))
	f.append(cos(erro_v))
	var dir_s: float = _obter_direcao_seta()
	if dir_s != INF:
		f.append(1.0)
		f.append(cos(dir_s - rotation))
		f.append(sin(dir_s - rotation))
	else:
		f.append(0.0)
		f.append(0.0)
		f.append(0.0)
	return f


func _ml_gravar_linha() -> void:
	# Uma linha = (18 entradas, 2 ações do professor neste mesmo frame)
	if _ml_arquivo == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://ml/dados"))
		_ml_arquivo = FileAccess.open(ml_gravar_caminho, FileAccess.WRITE)
		if _ml_arquivo == null:
			push_warning("ML: falha ao abrir " + ml_gravar_caminho)
			ml_gravar = false
			return
	var f := _ml_features()
	# Row layout is the DatasetRecorder contract (18 feats + 2 labels).
	var steering_norm: float = clampf(estercamento_alvo / max_estercamento, -1.0, 1.0)
	var speed_norm: float = clampf(velocidade_desejada / velocidade_maxima, 0.0, 1.0)
	_ml_arquivo.store_line(DatasetRecorderRef.format_row(f, steering_norm, speed_norm))


func _ml_fechar() -> void:
	if _ml_arquivo != null:
		_ml_arquivo.close()
		_ml_arquivo = null


# --- SHADOW BRAINS: compare the pure solver with the inline legacy math ---
# Zero effect on behavior (writes only counters). Steering is already
# delegated to PurePursuit (see top-of-file note); this infra is ready
# for the next slice's speed/reverse comparisons (curve_speed, approach
# profiles, trail reverse idiom) before those delegate too.
func _shadow_check2(solver_val: float, legacy_val: float, label: String) -> void:
	_shadow_samples += 1
	var diff: float = absf(solver_val - legacy_val)
	_shadow_worst = maxf(_shadow_worst, diff)
	if diff > 0.03:
		_shadow_drifts += 1
		print("SHADOW drift[%s] %.4f solver %.4f legacy %.4f (state %s idx %d)" % [
			label, diff, solver_val, legacy_val, nome_estado(), indice_waypoint])


func _shadow_check(cmd) -> void:
	_shadow_check2(cmd.steering, estercamento_alvo, "steer")


func _processar_ml(delta: float) -> void:
	# O ALUNO dirige: sensores -> rede -> volante/velocidade. Sem trilha.
	if _ml_rede == null:
		_ml_rede = CerebroML.new()
		if not _ml_rede.carregar("res://ml/modelo/pesos.json"):
			# Sem modelo treinado: fallback seguro para o cérebro de trilha
			_ml_rede = null
			modo_ml = false
			_plano_pendente = true
			return
	# Fallback por FALTA DE PROGRESSO (não só parada total): se em 4s andou
	# menos de 100px (<25px/s), a rede está timida/rastejando — FSM assume.
	# (Desligado em ml_sem_fallback: durante a evolução o fitness mede só a rede.)
	if not ml_sem_fallback:
		_ml_t_progresso += delta
		if _ml_t_progresso >= 4.0:
			if global_position.distance_to(_ml_pos_ref) < 100.0:
				modo_ml = false
				_plano_pendente = true
				return
			_ml_pos_ref = global_position
			_ml_t_progresso = 0.0
	# Rede travada (quer andar e não anda, OU parada total): FSM assume
	if velocidade_atual < 2.0 and not ml_sem_fallback:
		_tempo_parado += delta
		if _tempo_parado > tempo_parado_replanejar * 2.0:
			_tempo_parado = 0.0
			modo_ml = false
			_plano_pendente = true
			return
	else:
		_tempo_parado = 0.0
	# Rede de segurança do snap: dentro + perto + alinhado = estacionou
	if _esta_100_dentro_da_vaga() and _perto_da_vaga_para_snap():
		var rot_v: float = rotation
		if _vaga_alvo != null and "rotacao_alvo" in _vaga_alvo:
			rot_v = _vaga_alvo.rotacao_alvo
		if absf(angle_difference(rotation, rot_v)) < 0.20:
			estercamento_alvo = 0.0
			velocidade_desejada = 0.0
			velocity = Vector2.ZERO
			velocidade_atual = 0.0
			global_position = global_position.lerp(_vaga_alvo.global_position, delta * 6.0)
			rotation = lerp_angle(rotation, rot_v, delta * 6.0)
			if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
				_vaga_alvo.marcar_ocupada()
			_mudar_estado(Estado.ESTACIONADO)
			return
	var f := _ml_features()
	var saida: PackedFloat64Array = _ml_rede.inferir(f)
	estercamento_alvo = clampf(saida[0] * max_estercamento, -max_estercamento, max_estercamento)
	velocidade_desejada = maxf(saida[1] * velocidade_maxima, 0.0)
	# Camada de segurança dura (sensores freiam, não dirigem):
	if distancia_centro() < distancia_seguranca:
		velocidade_desejada = 0.0
	_aplicar_movimento_trilha(delta)


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
	for raio in [ray_frente_centro, ray_frente_esq, ray_frente_dir, ray_esquerda, ray_direita, ray_tras, ray_lateral_esq, ray_lateral_dir]:
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
