extends CharacterBody2D
## O CÉREBRO DO CARRO — Máquina de Estados (FSM) com RECUPERAÇÃO.

const CerebroML = preload("res://scripts/CerebroML.gd")
const SensorArrayRef = preload("res://src/vehicle/SensorArray.gd")
const LocomotionRef = preload("res://src/vehicle/Locomotion.gd")
const DatasetRecorderRef = preload("res://src/vehicle/DatasetRecorder.gd")
const RouteShapeRef = preload("res://src/navigation/RouteShape.gd")
const FarolSpecRef = preload("res://src/farol/FarolSpec.gd")
const RouteRef = preload("res://src/farol/Route.gd")
const PilotRef = preload("res://src/farol/Pilot.gd")
const FarolShieldRef = preload("res://src/farol/FarolShield.gd")
const MooringRef = preload("res://src/farol/Mooring.gd")

## Geometria da rota (RouteShape): raio maximo do arredondamento, em px, e passo
## de reamostragem. 0 desliga e volta a polilinha de vertices duros (que e o
## que fazia o pure-pursuit cortar a quina e o carro andar torto).
## Iteracoes de Chaikin na escadaria do A*. 0 desliga a suavizacao. 3 limpa a
## quina sem encurtar o caminho a ponto de o carro mudar de lado da via.
@export var suavizacoes_rota: int = 3
## Raio de arredondamento por vertice (RouteShape.round_corners). 0 = desligado:
## arredondar hairpin cria laco (oito de meia-volta na Fase2).
@export var raio_curva: float = 0.0
@export var passo_rota: float = 30.0

## Ganho do termo lateral do Stanley (PurePursuit.solve_error). Maior = o carro
## cola na faixa mais rapido, ao custo de oscilar em baixa velocidade.
@export var ganho_erro_lateral: float = 1.4

## Segundos de manobra FINAL sem movimento antes de desistir da vaga. Sem isto
## o carro pode ficar parado indefinidamente em ALINHANDO: a Fase5 travava 68 s
## a 73 px do centro, com um obstaculo 97 px a frente, porque o detector de
## travamento so roda no caminho de busca (`_processar_rota`).
@export var manobra_travada_s: float = 6.0## Teto de desistencias por fase. Sem ele a Fase5 (89 vagas sobrepostas, zero
## obstaculos) entrava em laco: desiste, pega outra, trava, desiste — 828 frames
## de RE em 70 s, PIOR do que ficar parado esperando (que era o estado antes).
const DriveContextRef = preload("res://src/vehicle/DriveContext.gd")
const DriveCommandAdapterRef = preload("res://src/vehicle/DriveCommandAdapter.gd")
const FsmProfilesRef = preload("res://src/vehicle/FsmProfiles.gd")
const TrailFollowerRef = preload("res://src/vehicle/TrailFollower.gd")
const AutonomousDriverRef = preload("res://src/vehicle/AutonomousDriver.gd")
const MlDriverRef = preload("res://src/vehicle/MlDriver.gd")
const LaneOffsetRef = preload("res://src/navigation/LaneOffset.gd")
const VehicleCatalogRef = preload("res://src/vehicle/VehicleCatalog.gd")
const CrosserGateRef = preload("res://src/vehicle/CrosserGate.gd")
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
## Pure pursuit: quanto longe o carro mira NA ROTA. REDUZIR (testado 90 px)
## nao tira o carro do canto: ele assentou 5 px a mais e a rota ficou
## instavel (8 violacoes de raio varrido). O erro e' do SOLVER, nao do
## look-ahead, e o que resolve e' a Pursuit lateral — ver backlog.
@export var distancia_lookahead: float = 180.0
@export var vaga_prioritaria: NodePath
## Right-hand traffic (mão à direita): the autonomous A* route is shifted up to
## this many px to the RIGHT of its direction of travel, limited by the real
## clearance to the wall on that side (see src/navigation/LaneOffset.gd).
## 0 disables the shift. Only A* routes are shifted — authored trail routes stay
## exactly where the teacher drew them.
@export var keep_right_shift: float = 110.0
# --- FAROL (src/farol/*): o carro que enfim entende o estacionamento -------
## Rollout switch, DECLARED ONCE PER LEVEL (promotion is one level at a time,
## and only when every gate of docs/tasks_backlog.md is green):
##   0 = legado  — exatamente o comportamento de 2026-09-28 (o default);
##   1 = sombra  — roda e mede, NAO dirige (o Chart e' construido e o Pilot
##                 acumula metricas, mas quem manda no volante e' o legado);
##   2 = piloto  — o FAROL pilota (Chart + custo de faixa + Pilot local).
## O numero vive aqui e e' empurrado ao planejador no primeiro frame
## (`_garantir_folga_do_planejador`), para que a cena precise declarar o
## rollout em UM lugar so.
@export_range(0, 2) var farol_mode: int = 0
## 0 = deslocamento pos-A* (LaneOffset, o legado); 1 = custo de faixa DENTRO
## do A* (FAROL · ROTA). A trilha NUNCA entra: rota autorada fica onde o
## professor a desenhou (AGENTS #18).
@export_range(0, 1) var lane_cost_mode: int = 0
## Null = `FarolSpec.default()`. Todos os numeros do FAROL vivem aqui.
@export var farol_spec: Resource = null
## Contadores de observacao (lidos por `tools/gate_drive.gd`). Nao afetam o
## comportamento: e' o placar que responde "ele entendeu mais?".
var _contagem_replanejamento: int = 0
var _contagem_desvio_farol: int = 0
## Rotas pos-suavizacao que NAO cumpriram a promessa de folga do FAROL · ROTA
## (deve ser 0; e' o contador que prova que o atalho com prova funciona).
var _contagem_via_ruim: int = 0
var _farol_spec = null
@export var planejador_path: NodePath = NodePath("../Planejador")
@export var vagas_path: NodePath = NodePath("../Vagas")
## Node que carrega a textura do carro (menu de carros — VehicleCatalog).
## English name on purpose: new symbols follow AGENTS §1 even in this PT-BR file.
@export var sprite_path: NodePath = NodePath("Sprite2D")

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
var _brain_re_recente: bool = false
var _brain_command = null
var _brain_context: DriveContextRef = null
var _legacy_steering_target: float = 0.0
var _legacy_speed_target: float = 0.0
# C2b: the brain was re-allocated EVERY FRAME (`AutonomousDriverRef.new()` per
# `_brain_for_current_mode()` call) when no brain was injected — exactly the
# case in Fase2/Fase3. Any per-brain state (crosser gate latch, timers) was
# discarded at 60 Hz. One instance per kind, invalidated on every mode change.
var _brain_cache: Object = null
var _brain_cache_kind: int = -1
# farol_mode is part of the cache key (AGENTS #20: the brain MUST be cached, and
# switching the rollout must invalidate it).
var _brain_cache_variante: int = -99
# Yield gate shared with the autonomous brain (C2): crossing traffic is
# BODY-LESS (src/world/Crosser.gd), so a latch with hysteresis is the only
# thing that keeps the car from creeping through it.
var _crosser_gate: CrosserGateRef = null

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
@onready var audio_motor: Node = get_node_or_null("EngineAudio")
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
## Detector de travamento por DESLOCAMENTO (2026-09-26). A velocidade
## COMANDADA não serve: encostado numa parede o carro mantém
## `velocidade_atual` em ~22 px/s (o modelo cinemático não sabe que está
## travado), e com o cérebro no comando o `_physics_process` retorna antes do
## `_atualizar_progresso`/`_detectar_travamento` — os dois legacy ficavam
## cegos. Medido na Fase3 seed 2: parado em (349, -1108) por 70 s em
## BUSCANDO. O teste certo é "andei algum px nos últimos N segundos".
var _ancora_deslocamento: Vector2 = Vector2.ZERO
var _travado_ha: float = 0.0
## Quando o detector de deslocamento dispara, a proxima `_iniciar_recuperacao`
## ja vai direto a ultima estrategia (replanejar) — uma manobra de ré contra
## uma parede nao resolve nada e custava 3 tentativas de 12 s cada.
var _tentativa_travada: int = 0
## Replanejamentos por travamento sem sair do lugar. Depois de
## `TRAVA_MAX_TENTATIVAS` o problema nao e' a rota, e' o ALVO: pede outra vaga
## em vez de reconstruir a grade para sempre.
const TRAVA_MAX_TENTATIVAS := 3
var _travado_tentativas: int = 0
## A re de emergencia (degrau 3 da escada) reorienta o carro ao terminar:
## ver `_orientar_para_rota()`. Sem isso o carro sai do solido e volta para ele.
var _reorientar_pos_reversao: bool = false

## CAUTELA POS-RE. Mesmo desencravado, o carro reentra no MESMO trecho a
## ~120 px/s e volta a encravar (medido na Fase3 seed 2: 3 ciclos de re +
## recravamento em 20 s, `inside=true` a cada volta). O vao estreito exige
## precisao de seguimento que a 120 px/s o carro nao tem, entao depois de cada
## re ele roda alguns segundos com velocidade limitada. Custo zero nos níveis
## saudáveis: sem re, o cronômetro nunca liga (medido: NEG_FRAMES=0).
const CAUTELA_S := 6.0
const CAUTELA_VEL := 55.0
var _cautela_tempo: float = 0.0
## Deslocamento que ZERA a escada de fuga. Tem que ser bem maior que
## `TRAVA_MIN_PX`: a ré de emergência (degrau 3) anda ~26 px e, com o reset
## em 26 px, zerava o contador logo depois de disparar — a escada voltava ao
## degrau 1 e nunca chegava ao degrau que desiste da vaga. Medido na Fase1:
## anda 2 s -> trava -> ré -> zera -> anda 2 s ... 75 s em laço, 1136 frames
## de ré, nenhuma vaga conquistada.
const TRAVA_RESET_PX := 78.0
## O degrau "sair do bolso" ja rodou nesta vaga (um por tentativa; o reset
## por progresso real em `_cravou` reabre a contagem para OUTRO bolso).
var _bolso_resolvido: bool = false
## Distancia ao FIM da rota no instante da ancora. Quem zera a escada e'
## "chegou mais perto", nao "andou": dentro de um bolso o carro da ~30 px de re
## por ciclo e voltava, o que contava como progresso e a escada reiniciava
## sozinha (Fase8 seed 9000: 66 s parado, wp 0/39).
var _ancora_distancia: float = 1.0e9
## Minutos que o carro pode ficar parado em cima do comando antes de recuperar.
const TRAVA_MIN_S := 2.0
## Progresso mínimo em px durante esse tempo (abaixo disso = travado).
const TRAVA_MIN_PX := 26.0
## Vagas que o carro JA desistiu nesta corrida. Sem isso o degrau final da
## escada era inutil: `pedir_nova_vaga` -> `_planejar_rota` -> `_escolher_vaga`
## e o custo do A* e DETERMINISTICO, entao ele reescolhia a MESMA vaga e
## voltava a encravar no mesmo ponto (Fase1: vaga alcancavel em gate_reach,
## carro preso em ALINHANDO a 359 px do centro por 75 s).
var _vagas_recusadas: Array[Node] = []
## TEMPO em ALINHANDO sem fechar a manobra. `_processar_alinhando()` nao tem
## prazo: se o portao `_esta_100_dentro_da_vaga()` nunca abre (carro torto, ou
## a Boca disparou longe e ha um carro estacionado no caminho reto), o carro
## manobra para sempre. E o mesmo "mandou estacionar e nao estacionou" do
## detector por deslocamento, so que na manobra final (o detector so olha
## BUSCANDO/DESVIANDO de proposito: em ALINHANDO o carro gira parado).
const ALINHA_MAX_S := 25.0
var _tempo_alinhando: float = 0.0
## 1 = ja replanejou uma vez; 2 = larga a vaga (a manobra nao tem solucao).
var _alinhando_tentativas: int = 0
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
	# Contrato de grupo: e' assim que o Crosser (sensor-only, sem corpo) sabe
	# que tem um veiculo na faixa e segura o carro que cruza. Sem isso ele
	# simplesmente atravessava o jogador (Crosser._conflito).
	add_to_group(&"veiculo")
	pedir_nova_vaga.connect(_ao_pedir_nova_vaga_interna)
	_garantir_folga_do_planejador()
	# A escolha do menu vive num static (sobrevive a change_scene), então cada
	# fase reaplica a pele escolhida sem precisar guardar nada na cena.
	aplicar_skin(VehicleCatalogRef.current_id)


## Margem (em células) somada ao raio varrido: cobre a intrusão das quinas
## das células vizinhas, que a checagem por CENTRO de célula não vê.
const FOLGA_EXTRA_CELULAS := 1.5


## Raio varrido pela carroceria (meia diagonal, já com a escala do nível).
func raio_varrido() -> float:
	var forma := $CollisionShape2D.shape as RectangleShape2D
	if forma == null:
		return 0.0
	return (forma.size * global_scale * 0.5).length()


## Garante que a folga do planejador cubra o raio varrido do carro + margem.
## Medido em Fase2: inflar 110 com raio varrido 126.5 -> 91 de 173 amostras da
## rota violavam a folga e o carro empurrava a calçada por 5.4 s seguidos.
## Fase3 (inflar 150 >= 115) tinha 0 violações e 0.08 s. O export `inflar` do
## nível continua valendo como MÍNIMO declarativo.
func _garantir_folga_do_planejador() -> void:
	# FAROL: a cena declara o rollout e os numeros num lugar so; aqui eles
	# chegam ao planejador ANTES de qualquer A* (a ordem e' critica: raio
	# varrido -> inflar/Chart -> grade -> rota).
	_farol_spec = _spec_do_farol()
	if planejador != null:
		planejador.set("farol_mode", farol_mode)
		planejador.set("lane_cost_mode", lane_cost_mode)
		if farol_spec != null:
			planejador.set("farol_spec", farol_spec)
		planejador.call("definir_raio_varrido", raio_varrido())
	if planejador == null:
		return
	var varrido := raio_varrido()
	if varrido <= 0.0:
		return
	var necessario := varrido
	if "resolucao" in planejador:
		necessario += float(planejador.resolucao) * FOLGA_EXTRA_CELULAS
	if float(planejador.get("inflar")) >= necessario:
		return
	planejador.set("inflar", necessario)
	if planejador.has_method("invalidar_grade"):
		planejador.call("invalidar_grade")
	print("[FOLGA] inflar=%.1f (raio varrido %.1f + margem de célula)" % [necessario, varrido])


## O `FarolSpec` em uso, nunca nulo. A cena pode apontar para um .tres; o
## default e' uma instancia nova (NAO um singleton: os numeros sao mutaveis e
## um `static` compartilharia estado entre as 9 fases).
func _spec_do_farol():
	if farol_spec != null and "w_folga" in farol_spec:
		return farol_spec
	if _farol_spec == null:
		_farol_spec = FarolSpecRef.new()
	return _farol_spec


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


## Modo de condução (F6): TRILHA segue a rota Line2D sequencial autorada;
## AUTONOMO planeja a própria rota A* e dirige pelo brain injetado.
## A troca vale em runtime (tecla T ou o checkbox "Auto Navegação").
enum Modo { TRILHA, AUTONOMO }

signal modo_mudou(modo: int)


func modo_atual() -> int:
	return Modo.TRILHA if modo_trilha else Modo.AUTONOMO


## Troca de modo em runtime. Limpa rota/vaga/alinhamento do modo anterior e
## replaneja do zero: sem isso o carro herda a cauda de rota antiga e trava
## no ALINHANDO (bug observado ao alternar no meio da corrida).
## `manter_rota`: a UI (ComboRotas) injeta a rota escolhida logo depois;
## então não deixamos o replanejamento pendente sobrescrevê-la.
func definir_modo(modo: int, manter_rota: bool = false) -> void:
	if modo_ml:
		return
	modo_trilha = false
	brain_enabled = false
	driver_brain = null
	_invalidar_brain()
	_sem_vagas = false
	waypoints.clear()
	indice_waypoint = 0
	_vaga_alvo = null
	estrategia = 0
	_tempo_parado = 0.0
	tempo_ignorar_sensor = 0.0
	_rota_trilha_anterior.clear()
	# Recomeca do zero: as desistencias valem por corrida, nao para sempre.
	_vagas_recusadas.clear()
	_travado_tentativas = 0
	_travado_ha = 0.0
	_ancora_deslocamento = global_position
	_ancora_distancia = 1.0e9
	_bolso_resolvido = false
	_alinhando_tentativas = 0
	_tempo_alinhando = 0.0
	_cautela_tempo = 0.0
	_reorientar_pos_reversao = false
	if modo == Modo.TRILHA:
		iniciar_modo_trilha()
	else:
		brain_enabled = true
		iniciar_navegacao()
	if manter_rota:
		_plano_pendente = false
	_mudar_estado(Estado.BUSCANDO)
	modo_mudou.emit(modo_atual())


func _unhandled_input(event: InputEvent) -> void:
	# T alterna TRILHA <-> AUTONOMO em qualquer nível (Mundo.tscn ou FaseN).
	# C cicla o carro do menu (VehicleCatalog) — o HUD só mostra o nome.
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		if key == KEY_T:
			definir_modo(Modo.AUTONOMO if modo_atual() == Modo.TRILHA else Modo.TRILHA)
			get_viewport().set_input_as_handled()
		elif key == KEY_C:
			aplicar_skin(VehicleCatalogRef.cycle(1))
			get_viewport().set_input_as_handled()


## Gate de cruzamento compartilhado com o piloto autônomo (C2). Uma instância
## por carro: o latch precisa sobreviver entre frames, por isso o cérebro é
## cacheado (C2b) e este gate também.
func gate_cruzamento() -> CrosserGateRef:
	if _crosser_gate == null:
		_crosser_gate = CrosserGateRef.new()
	return _crosser_gate


## Troca a "pintura" do carro (menu de 5 modelos Kenney). Todas têm a mesma
## resolução, então `scale`/colisão continuam válidos (VehicleCatalog).
func aplicar_skin(id: String) -> bool:
	return VehicleCatalogRef.apply(self, id)


func _planejar_rota() -> void:
	# A folga da grade precisa cobrir o carro antes de qualquer A*.
	_garantir_folga_do_planejador()
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
	posicao_alvo = (_vaga_alvo as Node2D).global_position
	rotacao_alvo = float(_vaga_alvo.get("rotacao_alvo")) if "rotacao_alvo" in _vaga_alvo else 0.0
	_aplicar_rota(escolha["rota"])
	tentativa_mudou.emit(0, "Rota A* para a vaga")
	_tempo_parado = 0.0
func _escolher_vaga() -> Dictionary:
	# Vaga prioritária (marcada na cena) e livre ganha sempre — MENOS se o
	# carro já desistiu dela nesta corrida (_vagas_recusadas). Sem essa
	# exceção, a vaga prioritária reintroduzia o laço do AGENTS: desiste ->
	# `_escolher_vaga` -> mesma vaga de novo.
	if not vaga_prioritaria.is_empty():
		var prioritaria := get_node_or_null(vaga_prioritaria)
		if prioritaria != null and not prioritaria.ocupada \
				and not _vaga_esta_recusada(prioritaria):
			var rota_p: Array = _rota_ate_vaga(prioritaria)
			if rota_p.size() >= 2:
				return {"vaga": prioritaria, "rota": rota_p}
	# Senão: a vaga livre ALCANÇÁVEL mais barata (A* + rumo compatível).
	# Entrada é sempre DE FRENTE (locked A2): vagas cujo nariz exige
	# chegada de ré (|yaw_err no fim da rota| > ~100°) são puladas.
	var melhor: Dictionary = {}
	var melhor_custo: float = INF
	for vaga in container_vagas.get_children():
		if vaga.ocupada or _vaga_esta_recusada(vaga):
			continue
		var prep: Vector2 = _ponto_prep_da_vaga(vaga)
		var rota_prep: Array = planejador.achar_rota(global_position, prep)
		if rota_prep.size() < 2:
			continue
		# Custo e rumo são medidos na CHEGADA ao ponto de preparação: é lá
		# que o carro precisa já estar apontado para a boca. O trecho final
		# (prep -> centro) é reto no eixo do nariz por construção.
		var custo := _comprimento_rota(rota_prep)
		custo += _penalidade_rumo(rota_prep, float(vaga.rotacao_alvo))
		if custo < melhor_custo:
			melhor_custo = custo
			melhor = {"vaga": vaga, "rota": _rota_ate_vaga(vaga)}
	return melhor


## A vaga esta na lista de desistencias desta corrida?
func _vaga_esta_recusada(vaga: Node) -> bool:
	return vaga != null and (_vagas_recusadas as Array).has(vaga)


## Penalidade de rumo: 0 quando a rota chega alinhada ao nariz da vaga,
## INF quando exigiria entrada de ré (não fazemos baliza — locked A2).
func _penalidade_rumo(rota: Array, rot_vaga: float) -> float:
	if rota.size() < 2:
		return INF
	var dir_fim: Vector2 = (rota[rota.size() - 1] as Vector2) - (rota[rota.size() - 2] as Vector2)
	if dir_fim.length_squared() < 1.0:
		return 0.0
	var nariz := Vector2.RIGHT.rotated(rot_vaga)
	var desalinhado: float = absf(angle_difference(dir_fim.angle(), nariz.angle()))
	if desalinhado > deg_to_rad(100.0):
		return INF
	return desalinhado * 200.0


## Ponto de preparação no eixo do nariz, na frente da boca (mesma ideia do
## `preparar_estacionamento` do modo trilha), já escalado como o carro.
## Alcance do ponto de preparação além do centro da vaga — MESMA fórmula de
## `_ponto_prep_da_vaga()`. A fase usa este número para dimensionar a grade do
## planejador: a grade precisa cobrir a vaga E o ponto de aproximação, senão o
## A* cai fora da região, `achar_rota` devolve vazio e o carro fica em
## BUSCANDO com zero waypoints (Fase1, 2026-09-26).
func alcance_preparo() -> float:
	var escala: float = maxf((global_scale.x + global_scale.y) * 0.5, 1.0)
	return entre_eixos * escala * 2.5 + 80.0


func _ponto_prep_da_vaga(vaga: Node2D) -> Vector2:
	var rot_v: float = float(vaga.get("rotacao_alvo")) if "rotacao_alvo" in vaga else 0.0
	var dir_nariz := Vector2.RIGHT.rotated(rot_v)
	var escala: float = maxf((global_scale.x + global_scale.y) * 0.5, 1.0)
	var d: float = entre_eixos * escala * 2.5 + 80.0
	return vaga.global_position - dir_nariz * d


## Rota de estacionamento AUTÔNOMA terminando alinhada ao nariz:
## A* até o ponto de preparação e depois o trecho reto prep -> centro.
## Sem isso o A* termina no CENTRO da vaga e o carro chega atravessado
## (41° em Fase2), travando no limiar |erro| > 0.7 dentro da vaga — a
## entrada é sempre DE FRENTE (locked A2).
func _rota_ate_vaga(vaga: Node2D) -> Array:
	if planejador == null or vaga == null or not is_instance_valid(vaga):
		return []
	var prep: Vector2 = _ponto_prep_da_vaga(vaga)
	var rota: Array = _rota_a_star_ate(prep)
	if rota.size() < 2:
		return []
	# Regra da mão à direita só na MALHA planejada; o trecho final (prep ->
	# centro) entra exato, senão o alvo da vaga sai de eixo.
	if (rota[rota.size() - 1] as Vector2).distance_to(prep) > 1.0:
		rota.append(prep)
	rota.append(vaga.global_position)
	return rota


## ÚNICO ponto de entrada para rotas A* autonomousas: planeja E aplica a regra
## da mão à direita. Antes, 3 de 5 call sites (replanejamento, fallback da
## trilha, tentativa 3) pulavam `_deslocar_para_direita()` e o carro voltava
## a dirigir pela esquerda assim que replanejava.
## Linhas 395 (medição de custo), os trails Line2D e os snapshots ficam de
## fora por projeto: são rotas de leitura, não o caminho dirigido (AGENTS §3).
func _rota_a_star_ate(alvo: Vector2) -> Array:
	if planejador == null:
		return []
	# Deslocar a rota CRUA (escadaria de células) antes de decimar foi tentado e
	# REVERTIDO em 2026-09-26: cada degrau passa a encostar na guia da direita e
	# o segmento entre dois degraus corta quina de parede — o carro travava a
	# (−632, 1479) a 23 px/s. A ordem que funciona é decimar, depois deslocar.
	# ORDEM (tres tentativas medidas em 2026-09-26; a que funciona):
	#   1. A* cru, 2. decima (8 vertices), 3. ARREDONDA (RouteShape), 4. desloca
	#      para a faixa da direita (LaneOffset).
	#   - deslocar a escadaria CRUA: cada degrau encosta na guia e o segmento
	#     entre degraus corta quina de parede — o carro travava a 23 px/s;
	#   - deslocar e so DEPOIS arredondar: o arredondamento encurta o caminho em
	#     ~17% cortando a quina para dentro, e isso tira a rota da faixa em cada
	#     curva (medido: 24% dentro do box);
	#   - arredondar ANTES de deslocar: a polilinha ja e suave, entao o
	#     deslocamento a aplica sem Ondular e a faixa fica continua.
	var crua: PackedVector2Array = planejador.achar_rota_crua(global_position, alvo)
	if crua.size() < 2:
		return []
	return _pos_processar_rota(crua)


## The shared tail of every autonomous A* route: decimate, round, apply the
## right-hand rule, guarantee the swept-radius clearance. `_rota_a_star_ate` and
## the detour's second leg MUST both land here, or a detour would become the one
## route that skips the lane rule (the exact bug AGENTS #18 records, where 3 of
## 5 call sites skipped `_deslocar_para_direita`).
func _pos_processar_rota(crua: PackedVector2Array) -> Array:
	# 1. CHAIKIN na escadaria de celulas (nunca cria laco, so limpa a quina);
	# 2. reamostra no passo, para a lista de waypoints ter tamanho util;
	# 3. desloca para a faixa da direita (agora sobre um caminho de verdade
	#    suave, entao a faixa nao ondula);
	# 4. garante a folga do raio varrido.
	var suave: Array = RouteShapeRef.resample(
		RouteShapeRef.smooth(Array(crua), suavizacoes_rota), passo_rota)
	if lane_cost_mode == 1 and planejador.has_method("rota_farol") \
			and planejador.call("rota_farol") != null:
		# FAROL · ROTA: a mao a direita ja esta NO CUSTO do A* (a faixa veio
		# do Chart, nao de um shift pos-hoc), entao o passo 3 some. No lugar
		# dele entra a SUAVIZACAO COM PROVA: o atalho so aceita cortar a
		# quina quando o segmento inteiro tem `raio varrido + margem` de
		# folga. `_garantir_folga` continua depois dela, porque o proprio
		# atalho so garante a folga nos VERTICES que ele remove.
		var rota_farol: RouteRef = planejador.call("rota_farol")
		suave = RouteRef.atalho(suave, plano_chart(), raio_varrido(), _spec_do_farol())
		if not rota_farol.vias_livreis(suave, raio_varrido()):
			_contagem_via_ruim += 1
		return _garantir_folga(suave)
	return _garantir_folga(_deslocar_para_direita(suave), suave)


## FAROL · DESVIO (S3): the Pilot's detour request, consumed.
##
## The FAROL Pilot measures `blocked_ahead` ALONG THE ROUTE and, when the next
## `bloqueado_dist_px` is unusable for `bloqueado_celulas` samples in a row,
## publishes a free cell in `desvio_alvo` (BFS over its LocalMap) instead of
## asking for reverse. Until something read that field the whole reactive layer
## was write-only: the Pilot detected the blockage, chose a way around, and the
## vehicle never heard about it.
##
## What this does: a REPLAN with a displaced goal — the route to the detour
## cell, then the route from the detour cell to the real target. It is NOT the
## escape ladder: `AGENTS #43`'s `_cravou` ladder keeps reverse for a car that
## is physically stuck, and this path never touches it. Both legs go through
## `_rota_a_star_ate`, the single autonomous-A* gate (AGENTS #18), so the lane
## rule cannot be skipped by taking a detour.
##
## Returns true when a new route was applied. `false` leaves the route alone
## (the Pilot will re-publish after `desvio_periodo_s`).
func _aplicar_desvio_do_piloto() -> bool:
	var brain: Object = _brain_for_current_mode()
	if brain == null or not ("desvio_alvo" in brain):
		return false
	var alvo: Vector2 = brain.get("desvio_alvo")
	if not (alvo.is_finite() and alvo != Vector2.INF):
		return false
	# The spot is still the destination; the detour only changes HOW we get
	# there. Resolve it the same way `_replanejar_com_Inflacao_maior` does, so
	# a detour can never re-choose the bay behind the vehicle's back.
	var alvo_final := posicao_alvo
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		alvo_final = (_vaga_alvo as Node2D).global_position
	var primeira: Array = _rota_a_star_ate(alvo)
	if primeira.size() < 2:
		return false
	# Second leg from the detour cell. `achar_rota_crua` measures from the
	# detour point, so the planner must be told to start there — the vehicle's
	# own position is still behind the blockage.
	var segunda: Array = _rota_a_star_ate_por_de(alvo, alvo_final)
	if segunda.size() < 2:
		# No way onwards from the detour cell: the first leg alone would park the
		# car in a corner. Refuse the whole detour and keep the current route.
		return false
	var nova: Array = []
	nova.append_array(primeira)
	# Drop the duplicated joint: the first leg ends where the second begins.
	if primeira.size() >= 1 and segunda.size() >= 1 \
			and (primeira[primeira.size() - 1] as Vector2).distance_to(segunda[0] as Vector2) < 1.0:
		nova.append_array(segunda.slice(1))
	else:
		nova.append_array(segunda)
	_aplicar_rota(nova)
	_contagem_desvio_farol += 1
	_contagem_replanejamento += 1
	# The request is consumed: the Pilot must not keep re-publishing the same
	# cell while the car drives the detour it produced.
	if "resetar" in brain:
		brain.call("resetar")
	print("[FAROL-DESVIO] replan com goal deslocado (%.0f, %.0f) -> alvo (%.0f, %.0f), %d pontos" % [
		alvo.x, alvo.y, alvo_final.x, alvo_final.y, nova.size()])
	return true


## `_rota_a_star_ate` from an arbitrary start, not from the vehicle. The detour's
## second leg needs this: the car is still behind the blockage, so measuring the
## A* from `global_position` would route straight back into it.
func _rota_a_star_ate_por_de(de: Vector2, ate: Vector2) -> Array:
	if planejador == null:
		return []
	var crua: PackedVector2Array = planejador.achar_rota_crua(de, ate)
	if crua.size() < 2:
		return []
	return _pos_processar_rota(crua)


## O Chart do planejador (null enquanto `farol_mode == 0`). O veiculo nunca
## constroi um: quem mede o mundo e' o planejador, e ter dois mapas do mesmo
## mundo seria a pior das duplicacoes possiveis.
func plano_chart():
	if planejador == null or not planejador.has_method("chart"):
		return null
	return planejador.call("chart")


## GARANTIA DE FOLGA (o invariante do AGENTS #18, agora no ponto onde ele podia
## quebrar): o arredondamento tira a quina PARA DENTRO, e perto de obstaculo
## isso encosta a linha na parede. A sonda empurra cada ponto para fora ate o
## raio varrido. Sem esta passagem a Fase2 dava 3 violacoes (min 97 px contra
## 126,5 do raio) logo na saida do spawn.
## `origem` is the SAME polyline BEFORE the right-hand shift, point by point.
## The shift only measures clearance along ONE direction (the route normal), so
## `free_r' >= keep_clear` is an invariant about that axis only. Two things then
## break, both measured on 2026-09-30 in Fase3 (seed 9001, `keep_right_shift`
## 900): a shifted point lands 73 px from a wall with a 115 px swept radius, and
## — worse — a SEGMENT between two points that are each clear passes 0.8 px
## from a convex corner. The car cannot drive its own route, and the escape
## ladder (AGENTS #43) loops forever. So the guarantee runs over the vertices
## AND over the segments, and whatever it cannot repair reverts to the planner's
## own line: A* marks every cell within `inflar >= raio_varrido` as solid, and
## the smoothed line measured 213 px of clearance in that same run.
func _garantir_folga(rota: Array, origem: Array = []) -> Array:
	if rota.size() < 2 or planejador == null:
		return rota
	var espaco := _espaco_de_fisica()
	if espaco == null:
		return rota
	var varrido: float = raio_varrido()
	if varrido <= 1.0:
		return rota
	var saida: Array = rota.duplicate()
	for i in range(saida.size()):
		# Os extremos NAO se movem: o primeiro e onde o carro esta agora e o
		# ultimo e o ponto de preparacao da vaga (AGENTS #18). Mover o primeiro
		# criava um erro lateral de ~1 raio varrido no instante seguinte, o
		# termo Stanley saturava e o carro dava meia-volta (42 frames de RE).
		if i == 0 or i == saida.size() - 1:
			continue
		var p: Vector2 = saida[i]
		var guarda := 0
		var medido := _folga_minima(espaco, p, varrido + 4.0)
		while guarda < 4:
			medido = _folga_minima(espaco, p, varrido + 4.0)
			if float(medido["d"]) >= varrido - 0.5:
				break
			p += (medido["n"] as Vector2) * (varrido - float(medido["d"]) + 2.0)
			guarda += 1
		if float(medido["d"]) < varrido - 0.5 and i < origem.size():
			var alt: Vector2 = origem[i]
			if float(_folga_minima(espaco, alt, varrido + 4.0)["d"]) > float(medido["d"]):
				p = alt
		saida[i] = p
	# Segmentos: o que o carro realmente percorre. O reparo e LOCAL — o ponto
	# ofendido recua pelo MENOR trecho que resolve, em direcao a linha do
	# planejador (bisecao). Reverter a perna inteira custou 10 s de pilotagem na
	# Fase6 e aproximou o carro 19 px de um obstaculo, porque a lane perde o
	# formato num trecho que so estava apertado num ponto.
	for _volta in range(3):
		if not _repuxar_pontos(espaco, saida, origem):
			break
	return saida


## Pulls each offending point toward the planner's line by the SMALLEST amount
## that leaves room for the car body — the lane keeps its shape everywhere else.
## Sliding the point away from the wall instead (the "driver's" fix) bent the
## route and cost Fase10 more than it bought: `cte_p95` 44 -> 97 px.
## Returns true when something moved.
func _repuxar_pontos(espaco, saida: Array, origem: Array) -> bool:
	if origem.size() != saida.size() or origem.size() < 3:
		return false
	var passo: float = maxf(passo_rota * 0.4, 10.0)
	var mudou := false
	for i in range(1, saida.size() - 1):
		var alvo: Vector2 = saida[i]
		var escolhido: Vector2 = _melhor_entre(espaco, saida, i, origem[i], passo)
		if escolhido == alvo:
			continue
		saida[i] = escolhido
		mudou = true
	return mudou


## Smallest pull from the lane point toward the planner's line that gives the
## body room on both legs of point `i`. `t = 0` is the planner's line, `t = 1`
## the lane point.
func _melhor_entre(espaco, saida: Array, i: int, base: Vector2, passo: float) -> Vector2:
	var alvo: Vector2 = saida[i]
	saida[i] = alvo
	if _folga_das_pernas(espaco, saida, i, passo) >= 0.0:
		return alvo
	saida[i] = base
	if _folga_das_pernas(espaco, saida, i, passo) < 0.0:
		return base
	var lo := 0.0
	var hi := 1.0
	for _k in range(6):
		var meio := (lo + hi) * 0.5
		saida[i] = base.lerp(alvo, meio)
		if _folga_das_pernas(espaco, saida, i, passo) >= 0.0:
			lo = meio
		else:
			hi = meio
	saida[i] = base.lerp(alvo, lo)
	return saida[i]


## Room the car BODY has on the two legs that meet at point `i`, sampled along
## them. Negative means the hull would touch a wall. Measured against the
## RECTANGLE the car is (176x148 px in Fase3), not its circumscribed circle
## (115 px): the circle is 30% wider than the body, and demanding it everywhere
## "repaired" routes the car drove perfectly — it cost Fase6 ten seconds and
## brought it within 30 px of an obstacle.
func _folga_das_pernas(espaco, saida: Array, i: int, passo: float) -> float:
	return minf(
		_folga_do_segmento(espaco, saida[i - 1], saida[i], passo),
		_folga_do_segmento(espaco, saida[i], saida[i + 1], passo))


func _folga_do_segmento(espaco, a: Vector2, b: Vector2, passo: float) -> float:
	var comp: float = a.distance_to(b)
	if comp <= passo:
		return 1.0e9
	var n := int(comp / passo)
	var pior := 1.0e9
	for k in range(n + 1):
		var q := a.lerp(b, float(k) / float(n))
		var dir := (b - a).normalized()
		pior = minf(pior, _folga_do_casco(espaco, q, dir, 400.0))
	return pior


## Clearance from `p` to the first wall, minus the distance the car BODY reaches
## in that same direction while travelling along `dir`. Negative = the hull
## overlaps the wall at this pose.
func _folga_do_casco(espaco, p: Vector2, dir: Vector2, max_dist: float) -> float:
	var meia := _meia_eixos_do_carro()
	if meia == Vector2.ZERO:
		return float(_folga_minima(espaco, p, max_dist)["d"])
	var frente := dir.normalized()
	var lado := frente.orthogonal()
	var folga := max_dist
	for k in range(12):
		var u := Vector2.RIGHT.rotated(TAU * float(k) / 12.0)
		# distance from the centre to the rectangle's boundary along u
		var alcance: float = 1.0 / maxf(
			absf(u.dot(frente)) / meia.x, absf(u.dot(lado)) / meia.y)
		folga = minf(folga, _distancia_parede(espaco, p, u, max_dist) - alcance)
	return folga


## Closest wall in ANY of 12 directions: `d` is the distance and `n` the unit
## vector pointing from that wall toward the point (the way out).
func _folga_minima(espaco, p: Vector2, max_dist: float) -> Dictionary:
	var d_min: float = max_dist
	var n_para: Vector2 = Vector2.ZERO
	for k in range(12):
		var dir := Vector2.RIGHT.rotated(TAU * float(k) / 12.0)
		var d: float = _distancia_parede(espaco, p, dir, max_dist)
		if d < d_min:
			d_min = d
			n_para = -dir
	return {"d": d_min, "n": n_para}


func _espaco_de_fisica() -> PhysicsDirectSpaceState2D:
	var mundo := get_world_2d()
	return mundo.direct_space_state if mundo != null else null


func _distancia_parede(espaco: PhysicsDirectSpaceState2D, de: Vector2, dir: Vector2, max_dist: float) -> float:
	var q := PhysicsRayQueryParameters2D.create(de, de + dir * max_dist)
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var r: Dictionary = espaco.intersect_ray(q)
	if r.is_empty():
		return max_dist
	return de.distance_to(r.get("position") as Vector2)


## Desloca a rota A* para a direita de quem dirige (mão à direita), o quanto a
## folga real permitir. Medido em Fase2/Fase3: o A* sem isso corria ~40 px à
## esquerda do eixo do corredor em média e até ~160 px nas curvas (cortando a
## quina por dentro). O offset zera no primeiro e no último ponto da malha.
## `sonda` é DIRECIONAL: o LaneOffset pergunta o lado esquerdo passando
## `-right`, então uma única sonda de física responde os dois lados.
func _deslocar_para_direita(rota: Array) -> Array:
	if keep_right_shift <= 0.0 or rota.size() < 3 or planejador == null:
		return rota
	var varrido := raio_varrido()
	if varrido <= 0.0:
		return rota
	var espaco := get_world_2d().direct_space_state
	var sonda := LaneOffsetRef.wall_probe(espaco, 2, varrido + keep_right_shift * 3.0)
	var fade: float = maxf(varrido * 2.0, 200.0)
	return LaneOffsetRef.apply(rota, keep_right_shift, sonda, varrido, fade, fade)


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
		# Só orienta na primeira rota (spawn) — usa o primeiro ponto a >80px
		# para não mirar num micro-blend (ex. Fase3 spawn->blend = sudoeste
		# enquanto o lookahead de 180px já mira leste; o snap curto causava
		# curva aberta para a parede sul e deadlock cinemático vel<1 sem virar).
		if era_vazia and rota.size() >= 2:
			var origem_ini: Vector2 = rota[0]
			var dir_ini: Vector2 = (rota[1] as Vector2) - origem_ini
			for k in range(2, rota.size()):
				var cand: Vector2 = (rota[k] as Vector2) - origem_ini
				if cand.length() > 80.0:
					dir_ini = cand
					break
			if dir_ini.length_squared() > 1.0:
				rotation = dir_ini.angle()
	# v2 (F3): anti-deadlock orientation, shared by A* and trail routes.
	# A fresh route may start BEHIND the car; the brain then commands a
	# reverse that the rear-wall safety zeroes -> full-lock steering at
	# zero speed = frozen forever (turning needs movement). So: when the
	# car is stopped and the first real leg (first point >80px) points
	# away (>~108 deg), orient the car to that leg before driving.
	if absf(velocidade_atual) < 5.0 and rota.size() >= 2:
		var origem0: Vector2 = rota[0]
		var dir0: Vector2 = (rota[1] as Vector2) - origem0
		for k in range(2, rota.size()):
			var cand0: Vector2 = (rota[k] as Vector2) - origem0
			if cand0.length() > 80.0:
				dir0 = cand0
				break
		if dir0.length_squared() > 1.0 and \
				absf(angle_difference(rotation, dir0.angle())) > PI * 0.6:
			rotation = dir0.angle()
	if planejador != null:
		planejador.definir_rota(rota)


func _ao_pedir_nova_vaga_interna() -> void:
	if auto_navegacao and not _sem_vagas:
		_plano_pendente = true


## v2 (F3 fix): in autonomous mode the PLANNER owns the target — spots must
## NOT retarget the vehicle (AGENTS §3). Fase2 bays are 689x314 with a mouth
## band ~567 px from the centre (AGENTS #17), so simply driving north past
## Vaga4 fired its triggers and rewrote posicao_alvo/rotacao_alvo to Vaga4
## while _vaga_alvo stayed Vaga2: _processar_alinhando then aligned to one
## spot and gated on the other (_esta_100_dentro_da_vaga() false forever) ->
## the car jittered forever inside Vaga4 and never parked (Fase2 autonomous).
## Manual/legacy driving keeps the old behaviour: that is how a human picks.
func _aceita_pedido_de_vaga(posicao_da_vaga: Vector2) -> bool:
	if not brain_enabled and driver_brain == null:
		return true
	if _vaga_alvo == null or not is_instance_valid(_vaga_alvo):
		return true
	return (_vaga_alvo as Node2D).global_position.distance_to(posicao_da_vaga) < 1.0


func preparar_estacionamento(rotacao_da_vaga: float, posicao_da_vaga: Vector2) -> void:
	# Humano: cria waypoint de preparação à frente da vaga para ter espaço de manobra
	if estado == Estado.ALINHANDO or estado == Estado.ESTACIONADO:
		return
	if not _aceita_pedido_de_vaga(posicao_da_vaga):
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
	if not _aceita_pedido_de_vaga(posicao_da_vaga):
		return
	rotacao_alvo = rotacao_da_vaga
	posicao_alvo = posicao_da_vaga
	_mudar_estado(Estado.ALINHANDO)


func set_driver_brain(brain) -> void:
	driver_brain = brain
	_invalidar_brain()


func set_brain_enabled(enabled: bool) -> void:
	brain_enabled = enabled
	_invalidar_brain()


## Drops the cached fallback brain (C2b) and the crosser latch: a mode change
## must never inherit the previous brain's state.
func _invalidar_brain() -> void:
	_brain_cache = null
	_brain_cache_kind = -1
	_brain_cache_variante = -99
	if _crosser_gate != null:
		_crosser_gate.reset()


func _build_brain_perception() -> PerceptionSnapshot:
	var rays := SensorArrayRef.collect_from(self)
	var alvo: Vector2 = posicao_alvo
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		alvo = (_vaga_alvo as Node2D).global_position
	var dist_t := global_position.distance_to(alvo)
	var ang_t := 0.0
	if dist_t > 0.001:
		ang_t = angle_difference(rotation, global_position.direction_to(alvo).angle())
	# v2 (F1): yaw_error to the spot heading + stuck watchdog. Crosser
	# fields come from the F5 group broadcast (INF = none until then).
	var rot_v: float = rotacao_alvo
	if _vaga_alvo != null and "rotacao_alvo" in _vaga_alvo:
		rot_v = _vaga_alvo.rotacao_alvo
	var cross_dist := INF
	var cross_bear := 0.0
	var ped_dist := INF
	var ped_bear := 0.0
	if get_tree() != null:
		for n in get_tree().get_nodes_in_group("crosser"):
			var c := n as Node2D
			if c == null:
				continue
			var d := global_position.distance_to(c.global_position)
			if d < cross_dist:
				cross_dist = d
				cross_bear = angle_difference(rotation,
					global_position.direction_to(c.global_position).angle())
		# pedestrian broadcast (docs/tasks_trafego.md T2): a pedestrian has
		# priority and must never be run over; sensor-only, so the yield
		# decision is the only protection.
		for n in get_tree().get_nodes_in_group("pedestre"):
			var p := n as Node2D
			if p == null:
				continue
			var d2 := global_position.distance_to(p.global_position)
			if d2 < ped_dist:
				ped_dist = d2
				ped_bear = angle_difference(rotation,
					global_position.direction_to(p.global_position).angle())
	var snapshot := SensorArrayRef.snapshot_full(rays, velocidade_atual, dist_t, ang_t,
		angle_difference(rotation, rot_v), cross_dist, cross_bear, _tempo_parado)
	snapshot.pedestrian_distance = ped_dist
	snapshot.pedestrian_bearing = ped_bear
	return snapshot


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
	# v2 (F3): brain_enabled means "drive autonomously" — the injected
	# brain (or AutonomousDriver here) replaces the legacy FSM paths.
	# Trail mode stays only for the legacy proof scenes.
	# C2b: ONE instance per kind, cached — a fresh RefCounted every frame
	# threw away every latch/timer the brain keeps.
	# v2 (F3/FAROL S3): the pilot is per farol_mode, and mode 2 is the FAROL
	# Pilot (src/farol/Pilot.gd). The kind is part of the cache key, so
	# switching the rollout invalidates the instance and its LocalMap — which
	# is exactly the "cache FIRST" discipline of AGENTS #20.
	var kind: int = 1 if (not brain_enabled and modo_trilha) else 0
	var variante: int = farol_mode if kind == 0 else -1
	if _brain_cache == null or _brain_cache_kind != kind or _brain_cache_variante != variante:
		if kind == 1:
			_brain_cache = TrailFollowerRef.new()
		elif farol_mode >= 2:
			_brain_cache = _novo_piloto_farol()
		else:
			_brain_cache = AutonomousDriverRef.new()
		_brain_cache_kind = kind
		_brain_cache_variante = variante
	return _brain_cache


## Builds the FAROL Pilot and injects the vehicle + the legacy pilot as the
## teacher (the shield and the speed profile both need a second opinion).
func _novo_piloto_farol() -> Object:
	var piloto = PilotRef.new(_spec_do_farol())
	if piloto.has_method("injetar_veiculo"):
		piloto.call("injetar_veiculo", self, _teacher_do_carro())
	if piloto.has_method("max_steer") or "max_steer" in piloto:
		piloto.set("max_steer", max_estercamento)
		piloto.set("max_speed", _brain_max_speed())
	return piloto


## The legacy pure-pursuit pilot, used as the FAROL Pilot's teacher. It has
## its OWN slot: it must survive the mode switch, because "fall back to the
## legacy pilot" is only meaningful if the legacy pilot is still there.
var _teacher_piloto: Object = null


func _teacher_do_carro() -> Object:
	if _teacher_piloto == null:
		_teacher_piloto = AutonomousDriverRef.new()
	return _teacher_piloto


## The LocalMap of the active FAROL pilot, or null when the legacy pilot drives.
func _local_do_piloto():
	var b: Object = _brain_for_current_mode()
	if b != null and "local" in b:
		return b.get("local")
	return null


## The hull's half extents in world px (88x74 local, already scaled).
func _meia_eixos_do_carro() -> Vector2:
	var forma := $CollisionShape2D.shape as RectangleShape2D
	if forma == null:
		return Vector2.ZERO
	var r: Vector2 = forma.size * 0.5
	return Vector2(r.x * absf(global_scale.x), r.y * absf(global_scale.y))


func _brain_speed_limit(brain: Object) -> float:
	if brain != null and "max_speed" in brain:
		var configured := float(brain.get("max_speed"))
		if configured > 0.0:
			return configured
	return _brain_max_speed()


func _apply_brain_command() -> void:
	if estado == Estado.ESTACIONADO or estado == Estado.RECUPERANDO:
		return
	# v2 (F3 fix): ALINHANDO is the FSM's parking maneuver. The brain used to
	# overwrite estercamento_alvo/velocidade_desejada every frame (because
	# _aplicar_movimento_trilha() calls this first), so the alignment commands
	# never reached the wheels: in Fase2 the car sat 80 px inside Vaga2 with
	# 89 deg of yaw error, alternating +37/-60 forever and never parking.
	if estado == Estado.ALINHANDO:
		return
	# v2 (F3): with an injected/autonomous brain, the DriveCommand OWNS
	# BUSCANDO steering+speed — the legacy FSM paths below only run when
	# NO brain is active (trail proof scenes with brain disabled, ML mode).
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
	# FAROL · NERVO: the shield is the ONE rule that is never learned. It runs
	# before any write to the controls, and it is a pure function of (command,
	# what the LocalMap can see) — see src/farol/FarolShield.gd. The teacher is
	# the legacy FSM target, which is the only other opinion the car has; with
	# no local map the shield ABSTAINS (a blind guard that silently becomes a
	# "stop everything" governor would be worse than no guard).
	var professor := DriveCommandAdapterRef.to_legacy_command(
		legacy_steering, legacy_speed, max_estercamento, velocidade_maxima)
	cmd = FarolShieldRef.aplicar(cmd, professor, _local_do_piloto(),
		_meia_eixos_do_carro(), global_position, rotation)
	if not brain_enabled and driver_brain == null:
		return
	var targets := DriveCommandAdapterRef.to_legacy_targets(
		cmd, max_estercamento, _brain_speed_limit(brain))
	estercamento_alvo = float(targets["steering"])
	velocidade_desejada = float(targets["speed"])
	# Log enxuto das RÉS comandadas pelo brain (causa da "ré/giro estranho no
	# meio do caminho"): só na borda (primeiro frame da ré), com o motivo.
	var re_agora: bool = cmd.throttle < -0.05
	if re_agora and not _brain_re_recente:
		print("[RE-BRAIN] estado=%d pos=%s rot=%.2f vel=%.0f/%.0f cte=%.0f dist_alvo=%.0f" % [
			int(estado), global_position, rotation, velocidade_atual,
			velocidade_desejada, context.cte, context.distance_to_target])
	_brain_re_recente = re_agora
	_brain_command = cmd
	_brain_context = context
	_legacy_steering_target = legacy_steering
	_legacy_speed_target = legacy_speed


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

	# CAUTELA pos-re (ver CAUTELA_S): conta para tras sozinha.
	if _cautela_tempo > 0.0:
		_cautela_tempo -= delta

	# TRAVAMENTO POR DESLOCAMENTO — fora dos ramos, para valer com QUALQUER dono
	# do comando. Ate 2026-09-27 esta checagem vivia dentro de `_processar_rota`
	# e, com o cérebro no comando, `_processar_buscando` NUNCA chama
	# `_processar_rota` (o brain tem a palavra) — entao o detector estava MORTO
	# exactamente no caminho autónomo. Medido na Fase3 seed 2: o carro ficou
	# 45 s a 7,4 px/s, preso na mesma celula, com 74 -> 58 waypoints e ZERO
	# replanejamentos. O watchdog do proprio cerebro nao cobre isso: ele exige
	# `distancia_frente() < 90`, e aqui o carro escorregava de LADO numa parede,
	# sem nada a frente. A checagem so vale nos estados que DIRIGEM: em ALINHANDO
	# o carro gira parado de proposito e em ESTACIONADO ele nao anda.
	if not modo_trilha and not modo_ml \
			and (estado == Estado.BUSCANDO or estado == Estado.DESVIANDO):
		if _cravou(delta):
			_travado_tentativas += 1
			# ESCADA DE FUGA (medida na Fase3 seed 2): replanejar sozinho NAO tira
			# um carro encostado na parede — a rota nova comeca apontando para a
			# mesma parede e o carro volta a escorregar a 7 px/s. Medido: o
			# replanejamento com inflacao 227 disparava a cada 2 s, devolvia a
			# MESMA rota de 58 waypoints e nao movia o carro um pixel em 45 s.
			# Entao a escada e': replanejar (1-2) -> dar RE (3) -> largar a vaga (4).

			if _travado_tentativas <= 2:
				if not _replanejar_com_Inflacao_maior():
					_comecar_reversao_de_emergencia()
			elif _travado_tentativas == 3:
				_comecar_reversao_de_emergencia()
			elif _travado_tentativas == 4 and not _bolso_resolvido and _sem_espaco_ao_redor():
				# DEGRAU 4: SAIR DO BOLSO. Replanejar e dar re resolvem a
				# parede, nao o bolso: dentro de um chao entre duas paredes os
				# dois devolvem o carro ao mesmo ponto (Fase8 seed 9000, medido
				# 2026-10-01: 66 s parado, wp 0/39, a escada recomecando do
				# zero a cada 30 px de re). O que tira o carro de um bolso e' um
				# objetivo NOVO com mais espaco em volta — e recusar a vaga na
				# primeira tentativa esgota o orcamento sem mover o carro.
				if not _sair_do_bolso():
					_recusar_vaga_atual()
			else:
				_recusar_vaga_atual()
			queue_redraw()
			return

	# FAROL · DESVIO (S3): the Pilot asked to go AROUND, not to reverse. It runs
	# BEFORE the escape ladder on purpose — the ladder is the cure for a car
	# that already scraped, and this is the cure for one that is still moving
	# with a blocked plan. Same placement rationale as `_cravou`: outside the
	# mode dispatch, so it counts whoever holds the wheel (the brain does, on
	# Fase2..Fase9, which is why `_processar_buscando` never sees it).
	# Inert with farol_mode == 0: the legacy brain has no `desvio_alvo` field,
	# so this returns false on the first line and nothing below can run.
	if farol_mode >= 2 and not modo_trilha and not modo_ml \
			and (estado == Estado.BUSCANDO or estado == Estado.DESVIANDO):
		if _aplicar_desvio_do_piloto():
			queue_redraw()
			return

	# MANOBRA FINAL COM PRAZO — a outra fonte de "mandou estacionar e nao
	# estacionou". Ver ALINHA_MAX_S. Vale para os DOIS ramos de alinhamento
	# (A* e trilha) porque fica antes do despacho de modo.
	if estado == Estado.ALINHANDO:
		_tempo_alinhando += delta
		if _tempo_alinhando > ALINHA_MAX_S:
			_tempo_alinhando = 0.0
			_alinhando_tentativas += 1
			if _alinhando_tentativas <= 1 and _replanejar_com_Inflacao_maior():
				queue_redraw()
				return
			_recusar_vaga_atual()
			queue_redraw()
			return
	else:
		_tempo_alinhando = 0.0

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

	# ÁUDIO: o motor segue a velocidade comandada (o carro parado continua com
	# motor em marcha lenta; ESTACIONADO é o único caso silencioso).
	if audio_motor != null:
		audio_motor.call("set_engine", velocidade_atual, velocidade_atual < -1.0,
			estado == Estado.ESTACIONADO, delta)

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
	# v2 (F3): in autonomous mode (brain enabled, or modo_trilha=false),
	# delegate locomotion to _aplicar_movimento_trilha (the kinematic
	# solver). The legacy physics path calls move_and_slide(), which
	# friction-clamps the body when grazing a wall parallel to the heading
	# (Godot #94928 normal-filtering reduces velocity to 0-2 px/s while
	# desired is 130+). The kinematic path glides along walls smoothly,
	# and Locomotion/FsmProfiles safety still vetos real collisions.
	if brain_enabled or not modo_trilha:
		_aplicar_movimento_trilha(delta)
		return
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


## Travamento por deslocamento: true quando o carro mandou andar e não andou.
## Replaneja da posicao atual com a inflacao ACIMA do raio varrido, para o
## A* parar de escolher breches que a carroceria nao atravessa. True se achou
## rota nova.
func _replanejar_com_Inflacao_maior() -> bool:
	if planejador == null:
		return false
	var alvo := posicao_alvo
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo):
		alvo = (_vaga_alvo as Node2D).global_position
	elif waypoints.size() > 0:
		alvo = waypoints[waypoints.size() - 1]
	var original: float = float(planejador.get("inflar"))
	var necessario: float = maxf(original, raio_varrido() * 1.8)
	if necessario <= original + 1.0:
		necessario = original * 1.5   # ja estava folgado: ainda mais
	planejador.set("inflar", clampf(necessario, 60.0, 240.0))
	planejador.call("invalidar_grade")
	planejador.construir()
	_contagem_replanejamento += 1
	var nova: Array = _rota_a_star_ate(alvo)
	planejador.set("inflar", original)
	planejador.call("invalidar_grade")
	planejador.construir()
	if nova.size() < 2:
		return false
	_aplicar_rota(nova)
	tentativas = 0
	tempo_no_waypoint = 0.0
	_mudar_estado(Estado.BUSCANDO)
	return true


## Larga a vaga atual: marca como recusada (para `_escolher_vaga` nao
## reescolher a MESMA e cair no mesmo laço), zera o orcamento da manobra e
## pede outra vaga. Chamado pelo ultimo degrau da escada de fuga e pelo
## timeout de ALINHANDO.
## Plano de fuga: uma rota para a celula livre mais ESPACOSA num raio, com mais
## folga que a atual. Devolve false quando nao ha nada melhor (a escada segue
## para recusar a vaga). Uma vez por tentativa: `_bolso_resolvido` volta a zero
## no reset por progresso real, para um bolso DIFERENTE poder ser escapado.
## O carro esta ENCAIXADO? Medido como a folga real em volta: abaixo de duas
## vezes o raio varrido nao ha espaco para manobrar e nenhum objetivo novo o
## tira de la. Num corredor normal a folga e' de centenas de px e a resposta e'
## `false` — sem este teste o degrau disparava em encravamento de rotina e
## custava 28 s na Fase2 (medido 2026-10-01: `t` 44,9 -> 72,9 s, `cte_med`
## 9,1 -> 21,4 px).
func _sem_espaco_ao_redor() -> bool:
	var espaco := _espaco_de_fisica()
	if espaco == null:
		return false
	var folga := float(_folga_minima(espaco, global_position, 900.0)["d"])
	return folga < raio_varrido() * 2.0


func _sair_do_bolso() -> bool:
	if planejador == null:
		return false
	var espaco := _espaco_de_fisica()
	if espaco == null:
		return false
	var folga_aqui := float(_folga_minima(espaco, global_position, 600.0)["d"])
	planejador.set("_origem_busca", global_position)
	var destino: Vector2 = planejador.call("achar_celula_espacosa",
		raio_varrido() * 6.0 + 400.0, folga_aqui + 40.0, true)
	if destino == Vector2.INF or destino.distance_to(global_position) < 60.0:
		return false
	var rota: Array = _rota_a_star_ate(destino)
	if rota.size() < 2:
		return false
	_bolso_resolvido = true
	_aplicar_rota(rota)
	tentativa_mudou.emit(0, "Saiu do bolso (%.0f px de folga)" % folga_aqui)
	_mudar_estado(Estado.BUSCANDO)
	return true


func _recusar_vaga_atual() -> void:
	if _vaga_alvo != null and is_instance_valid(_vaga_alvo) and not (_vaga_alvo in _vagas_recusadas):
		_vagas_recusadas.append(_vaga_alvo)
	_alinhando_tentativas = 0
	_tempo_alinhando = 0.0
	_travado_tentativas = 0
	_ancora_deslocamento = global_position
	_sem_vagas = true
	pedir_nova_vaga.emit()
	_mudar_estado(Estado.BUSCANDO)


## Reversao curta de emergencia: `estrategia 2` e' a re prolongada de
## `_processar_recuperando` (1 s, freia sozinha se houver algo atras).
## Só o deslocamento REAL limpa `_travado_tentativas` (ver `_cravou`): se
## `_aplicar_rota` zerasse o contador, a escada nunca chegaria ao degrau que
## desiste da vaga e o carro ficaria replanejando para sempre.
func _comecar_reversao_de_emergencia() -> void:
	_reorientar_pos_reversao = true
	_cautela_tempo = CAUTELA_S
	estrategia = 2
	tempo_estrategia = 0.0
	fase_manobra = 0
	tentativas = 0
	tempo_no_waypoint = 0.0
	estercamento_alvo = 0.0
	_mudar_estado(Estado.RECUPERANDO)


## Distance to the END of the route (the preparation point, or the bay when the
## route is gone) — never to the current waypoint: a replanned route is born on
## the car's own cell (AGENTS #43), so waypoint 0 sits 0.02 px away and
## "closer" would always be true.
func _distancia_ao_alvo_da_rota() -> float:
	if waypoints.size() > 0:
		return global_position.distance_to(waypoints[waypoints.size() - 1])
	return global_position.distance_to(posicao_alvo)


func _cravou(delta: float) -> bool:
	if _ancora_deslocamento == Vector2.ZERO:
		_ancora_deslocamento = global_position
		_ancora_distancia = _distancia_ao_alvo_da_rota()
		return false
	# Andar um tanto NAO zera a escada (ver TRAVA_RESET_PX): quem zera e' o
	# progresso na ROTA (`_avancar_indice_rota`). Medido na Fase1: entre dois
	# engasgos o carro anda 100-200 px e volta a encravar no mesmo lugar, entao
	# o reset por deslocamento degradava a escada para "replanejar" para sempre
	# (75 s, 1167 frames de ré, nenhuma vaga conquistada).
	if global_position.distance_to(_ancora_deslocamento) >= TRAVA_RESET_PX:
		_ancora_deslocamento = global_position
		_ancora_distancia = _distancia_ao_alvo_da_rota()
		_travado_ha = 0.0
		_bolso_resolvido = false
		return false
	_travado_ha += delta
	if _travado_ha < TRAVA_MIN_S:
		return false
	_ancora_deslocamento = global_position
	_travado_ha = 0.0
	return true


func _aplicar_movimento_trilha(delta: float) -> void:
	_apply_brain_command()
	# CAUTELA pos-re: ver CAUTELA_S. Unico ponto por onde o comando do cerebro
	# passa, entao vale para o piloto autonomo E para o modo trilha.
	if _cautela_tempo > 0.0:
		velocidade_desejada = clampf(velocidade_desejada, -CAUTELA_VEL, CAUTELA_VEL)
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
		# ÁUDIO: batida de carroceria — a força escala com a velocidade que o
		# carro tinha no impacto (o próprio gate de folga já evita a maioria).
		if audio_motor != null:
			audio_motor.call("play_bump", clampf(absf(prev_vel) / 160.0, 0.0, 1.0))
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
	# v2 (F3): an active brain OWNS the command (see _aplicar_movimento ->
	# _apply_brain_command, called first). Skip the legacy solver so the
	# two do not fight over estercamento_alvo/velocidade_desejada.
	if auto_navegacao and _vaga_alvo != null:
		if _brain_command == null:
			_processar_rota(delta)
		else:
			_aplicar_movimento(delta)
			_avancar_indice_rota()
			# v2 (F3) watchdog: brain grinding against something (slow with
			# a close front ray) for >2.5s -> hand over to the FSM recovery
			# (reverse/turn-around) instead of pushing forever. The legacy
			# 30s travamento detector is far too slow for this failure.
			if absf(velocidade_atual) < 15.0 and distancia_frente() < 90.0:
				_tempo_parado += delta
				if _tempo_parado > 2.5:
					_tempo_parado = 0.0
					_iniciar_recuperacao()
			else:
				_tempo_parado = 0.0
		_brain_command = null
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
	# v2 (locked B5): floor arrows are IGNORED — no 35% seta blend.
	var alvo: Vector2 = waypoints[indice_waypoint]
	var angulo_erro: float = angle_difference(rotation, global_position.direction_to(alvo).angle())
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
	# Travamento por DESLOCAMENTO. Um detector so no ramo de colisao nao
	# funciona: encostado na parede o carro ESCORREGA (v = 3..7 px/s, colisao
	# intermitente) e nunca acumula 2 s. Medido na Fase3 seed 4: 50 s em RE-BRAIN
	# sem recuperar. A checagem vai no topo porque TODOS os ramos de
	# `_processar_rota` passam aqui.
	# MOVIDO para `_physics_process` em 2026-09-27: aqui dentro ele nao valia com
	# o cerebro no comando (que e' o caso das fases 2..7). Ver o comentario no
	# topo de `_physics_process` para a medicao.
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
	# v2 (locked B5): floor arrows are IGNORED — no 30% seta blend.
	var alvo := _ponto_lookahead(distancia_lookahead)
	var erro: float = angle_difference(rotation, global_position.direction_to(alvo).angle())
	# Deadband para não oscilar em reta: se CTE <20 e erro pequeno, suaviza
	# ERRO LATERAL COM SINAL: desvio do carro ate a rota, POSITIVO quando o carro
	# esta a DIREITA dela. `dir.orthogonal()` aponta para a direita do veiculo
	# (y para baixo), entao o produto escalar abaixo e o desvio com sinal. E o
	# termo do Stanley dentro de solve_error.
	var cte: float = INF
	var cte_dir: float = 0.0
	var dir := Vector2.RIGHT.rotated(rotation)
	for i in range(waypoints.size() - 1):
		var p := Geometry2D.get_closest_point_to_segment(global_position, waypoints[i], waypoints[i + 1])
		var d: float = global_position.distance_to(p)
		if d < cte:
			cte = d
			cte_dir = (global_position - p).dot(dir.orthogonal())
	var deadband: bool = cte < 20.0 and absf(erro) < 0.15
	estercamento_alvo = PurePursuit.solve_error(erro, max_estercamento, 2.8, deadband,
		cte_dir, velocidade_atual, ganho_erro_lateral).steering
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
		# PROGRESSO REAL: unico evento que zera a escada de fuga (AGENTS: o
		# contador nao pode ser zerado por "andar um pouco", senao o degrau que
		# desiste da vaga nunca acontece).
		# MEDIDO (Fase3 seed 2, 2026-09-27): "avancou o indice" NAO e' progresso
		# por si so. A rota replanejada nasce NA CELULA DO CARRO, entao os 4
		# primeiros waypoints ficam a 0,02 px um do outro e o indice andava 1->4
		# com o carro parado, zerando a escada depois de CADA degrau: 50 s preso
		# a 7,4 px/s, 0 re, 0 vaga recusada. O gate agora e' o DESLOCAMENTO
		# (`TRAVA_RESET_PX`), o mesmo criterio de `_cravou`.
		if global_position.distance_to(_ancora_deslocamento) >= TRAVA_RESET_PX:
			_travado_tentativas = 0
			_travado_ha = 0.0
			_ancora_deslocamento = global_position
			_ancora_distancia = _distancia_ao_alvo_da_rota()
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
	var rota: Array = _rota_a_star_ate(alvo)
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
			var rota: Array = _rota_a_star_ate(_alvo_trilha())
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
	# Vaga prioritária (marcada na cena) e livre ganha sempre — mesma regra de _escolher_vaga().
	# Em trilha ela é essencial: a rota desenhada termina na vaga prioritária, e escolher
	# a "mais próxima do spawn" apontava para OUTRA vaga e arrastava o carro para longe.
	if not vaga_prioritaria.is_empty():
		var prioritaria := get_node_or_null(vaga_prioritaria)
		if prioritaria != null and not prioritaria.ocupada:
			vaga_escolhida = prioritaria
	if vaga_escolhida == null:
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
	# Se a rua já termina em cima da própria vaga (rota desenhada para ENTRAR nela),
	# não acrescenta mid/prep: eles jogariam o carro para trás ("vira e volta").
	var fim_rua: Vector2 = rua[rua.size()-1]
	var rota_ja_entra_na_vaga: bool = fim_rua.distance_to(_vaga_alvo.global_position) < 150.0
	# Só adiciona ponto_prep se não estiver muito longe da última parte da rua (evita zig-zag)
	if not rota_ja_entra_na_vaga and rua[rua.size()-1].distance_to(ponto_prep) > 15.0:
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
	# v2 (F5 fix): re-enabled for crosser safety. When a crosser (or
	# obstacle) enters the front safety zone (df < seg), the car stops
	# instead of plowing through.
	var escala_media_trilha := (global_scale.x + global_scale.y) * 0.5
	var seg_trilha: float = 44.0 * maxf(escala_media_trilha, 1.0) + 22.0
	seg_trilha = maxf(seg_trilha, 48.0)
	var df_trilha := distancia_centro()
	# C2: mesmo gate de cruzamento do piloto autônomo (histerese + hold
	# mínimo). A banda de 140 px solta no mesmo instante em que entra, e o
	# carro "engatinhava" pelo trânsito; o crosser é BODY-LESS, então a decisão
	# é o único lugar onde a parada acontece. Distâncias menores que as do
	# gate autônomo porque a trilha legacy roda em corredores mais estreitos
	# (um exit de 340 px segurava o carro até a rota passar fome).
	var cross_near := false
	if get_tree() != null:
		var cross_dist := INF
		var cross_bear := 0.0
		for n in get_tree().get_nodes_in_group("crosser"):
			var c := n as Node2D
			if c == null:
				continue
			var d := global_position.distance_to(c.global_position)
			if d < cross_dist:
				cross_dist = d
				cross_bear = angle_difference(rotation,
					global_position.direction_to(c.global_position).angle())
		# a pedestrian has priority in the legacy trail path too
		# (docs/tasks_trafego.md T2): merged into the same latch so the trail
		# never runs over one either.
		for n in get_tree().get_nodes_in_group("pedestre"):
			var p := n as Node2D
			if p == null:
				continue
			var d2 := global_position.distance_to(p.global_position)
			if d2 < cross_dist:
				cross_dist = d2
				cross_bear = angle_difference(rotation,
					global_position.direction_to(p.global_position).angle())
		var gate := gate_cruzamento()
		gate.enter_distance = 140.0
		gate.exit_distance = 220.0
		gate.min_hold = 0.5
		cross_near = gate.should_yield(cross_dist, cross_bear, delta)
	var frente_bloqueada: bool = (df_trilha < seg_trilha or cross_near)
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
	# Sem vaga alvo nao existe manobra: o gatilho de AREA da vaga entrou em
	# ALINHANDO e fijou `posicao_alvo` sem que `_escolher_vaga` tivesse escolhido
	# nada (o cross-trigger do AGENTS #15b). O carro entonces dirigia para um
	# alvo fantasma e passeava pela fase (Fase4: 70 s sem estacionar, com
	# `_vaga_alvo` nulo o tempo todo). Volta para BUSCANDO e deixa o A* escolher.
	if _vaga_alvo == null or not is_instance_valid(_vaga_alvo):
		# Tenta descobrir QUAL vaga o gatilho de area marcou em
		# `posicao_alvo`. Se nao houver vaga a menos de 200 px, segue
		# manobrando para `posicao_alvo` mesmo assim (era assim que a
		# Fase4 estacionava em 9 s). Bloquear aqui deixava a fase
		# inteira sem rota, porque o _escolher_vaga dela falha em TODAS
		# as vagas (ponto de preparacao bloqueado) e so o gatilho de
		# area oferece alvo.
		_resolver_vaga_alvo()
	if _esta_100_dentro_da_vaga() and _perto_da_vaga_para_snap():
		# 100% dentro da vaga E perto do centro: PARA imediatamente.
		# Nao continua nem vira para evitar bater. Rotaciona em lugar se desalinhado.
		# O gate de distância evita o "slide fantasma" em vagas escaladas
		# (a vaga é enorme e "100% dentro" dispara ainda longe do centro).
		var _err: float = angle_difference(rotation, rotacao_alvo)
		var _dist_centro: float = global_position.distance_to(posicao_alvo)
		estercamento_alvo = 0.0
		velocidade_desejada = 0.0
		velocity = Vector2.ZERO
		velocidade_atual = 0.0
		global_position = global_position.lerp(posicao_alvo, delta * 6.0)
		rotation = lerp_angle(rotation, rotacao_alvo, delta * 6.0)
		# Só marca ESTACIONADO depois de DESLIZAR até o centro da vaga (o lerp
		# acima converge em ~0.3s). Sem o gate de distância o carro "estacionava"
		# a ~70px do centro e o _processar_estacionado não puxava mais.
		if absf(_err) < tolerancia_alinhamento and _dist_centro < 12.0:
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
		# Perto do centro (mesmo com o casco ainda fora da vaga, o que acontece
		# quando o carro chega TORTO): gira parado para alinhar primeiro. Sem
		# isso o carro chegava a 13 px do centro com o casco atravessando a
		# borda, o portao "100% dentro" nunca abria e ele voltava a manobrar para
		# sempre (Fase4, 2026-09-26).
		if distancia < maxf(160.0, tolerancia_chegada * 4.0) and absf(erro) > 0.08:
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


## Adota como `_vaga_alvo` a vaga livre mais proxima de `posicao_alvo` (dentro de
## 200 px). E o que conserta o cross-trigger: o gatilho de AREA sabe QUAL vaga o
## carro esta entrando, mesmo que o A* nao a tenha escolhido.
func _resolver_vaga_alvo() -> bool:
	if container_vagas == null:
		return false
	var cand: Node2D = null
	var cand_d: float = 200.0
	for v in container_vagas.get_children():
		if v.ocupada:
			continue
		var d: float = global_position.distance_to((v as Node2D).global_position)
		if d < cand_d:
			cand_d = d
			cand = v as Node2D
	if cand == null:
		return false
	_vaga_alvo = cand
	posicao_alvo = cand.global_position
	rotacao_alvo = float(cand.get("rotacao_alvo")) if "rotacao_alvo" in cand else 0.0
	print("[VAGA-RESOLVIDA] alvo=%s dist=%.0f" % [cand.name, cand_d])
	return true


## O Mooring do FAROL cuida da POSE FINAL: ele so assume o volante quando o
## carro ja chegou ao ponto de preparo. Antes disso o ALIGNING legado conduz
## pela rota (e' o caminho que os 9 niveis historicos mediram). Medido na Fase9
## seed 9003 (2026-10-01): o piloto assumia o volante a 200 px da vaga, ignorava
## o waypoint de preparo e ia direto contra o meio-fio das costas — 25 s em
## ALINHAR a 0,6 px/s, porque o Locomotion recusa girar abaixo de 1 px/s e a
## rampa que o Mooring exige para girar em parado estava bloqueada pelos raios.
func _no_ponto_de_preparo() -> bool:
	if _vaga_alvo == null or not is_instance_valid(_vaga_alvo):
		return true
	var prep: Vector2 = _ponto_prep_da_vaga(_vaga_alvo as Node2D)
	var escala: float = maxf((global_scale.x + global_scale.y) * 0.5, 1.0)
	return global_position.distance_to(prep) <= entre_eixos * escala * 1.5 + 60.0


func _processar_alinhando(delta: float) -> void:
	# Sem vaga alvo nao existe manobra: o gatilho de AREA da vaga entrou em
	# ALINHANDO e fijou `posicao_alvo` sem que `_escolher_vaga` tivesse escolhido
	# nada (o cross-trigger do AGENTS #15b). O carro entonces dirigia para um
	# alvo fantasma e passeava pela fase (Fase4: 70 s sem estacionar, com
	# `_vaga_alvo` nulo o tempo todo). Volta para BUSCANDO e deixa o A* escolher.
	if _vaga_alvo == null or not is_instance_valid(_vaga_alvo):
		# Tenta descobrir QUAL vaga o gatilho de area marcou em
		# `posicao_alvo`. Se nao houver vaga a menos de 200 px, segue
		# manobrando para `posicao_alvo` mesmo assim (era assim que a
		# Fase4 estacionava em 9 s). Bloquear aqui deixava a fase
		# inteira sem rota, porque o _escolher_vaga dela falha em TODAS
		# as vagas (ponto de preparacao bloqueado) e so o gatilho de
		# area oferece alvo.
		_resolver_vaga_alvo()
	# RECONSTRUIDA em 2026-09-26: um script meu de remocao apagou esta funcao e a
	# restauracao veio do HEAD, que e a versao ANTIGA (sem o portao de distancia
	# do AGENTS #16 e sem o giro parado dentro da vaga). Com ela a Fase3 subia
	# 431 frames de RE e a Fase4 nao estacionava. A logica abaixo espelha a irma
	# `_processar_alinhando_trilha`, que sobreviveu e e a referencia de manobra.
	if _esta_100_dentro_da_vaga() and _perto_da_vaga_para_snap():
		# 100% dentro da vaga E perto do centro: PARA e desliza ate o centro.
		# O gate de distancia existe porque a vaga e' grande e "100% dentro"
		# dispara ainda longe (slide fantasma, AGENTS #16).
		var _err := angle_difference(rotation, rotacao_alvo)
		var _dist := global_position.distance_to(posicao_alvo)
		estercamento_alvo = 0.0
		velocidade_desejada = 0.0
		velocity = Vector2.ZERO
		velocidade_atual = 0.0
		global_position = global_position.lerp(posicao_alvo, delta * 6.0)
		rotation = lerp_angle(rotation, rotacao_alvo, delta * 6.0)
		if absf(_err) < tolerancia_alinhamento and _dist < 12.0:
			if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
				_vaga_alvo.marcar_ocupada()
			_mudar_estado(Estado.ESTACIONADO)
		return
	var distancia: float = global_position.distance_to(posicao_alvo)
	var erro: float = angle_difference(rotation, rotacao_alvo)
	# FAROL · ATRACAÇÃO (S4): a cascata de `if` abaixo é a COPIA DE REFERÊNCIA
	# (medida, verificada pelos gates) e roda com farol_mode < 2. Com o rollout
	# ligado, quem decide o movimento deste frame é `Mooring.comando()`: uma
	# POSE alvo, com fases monotônicas (alinha -> arco -> desliza) em vez de uma
	# reavaliação independente a cada frame — que era o que fazia o arco passar
	# do ponto e voltar para a aproximação em loop.
	#
	# O COMMIT continua sendo do Carro: `_esta_100_dentro_da_vaga()` e a
	# tolerância abaixo são o gate real (AGENTS #16) e não são reimplementados
	# aqui — o Mooring diz para onde mover, nunca quando terminar.
	if farol_mode >= 2 and _no_ponto_de_preparo():
		var meia_eixos := _meia_eixos_do_carro()
		# The Mooring reads its numbers from a STATIC, so the spec has to be
		# pushed every frame: without this a scene's `farol_spec` would be
		# silently ignored here and the manoeuvre would always run on the
		# defaults (the `usar()` API existed but nothing called it).
		MooringRef.usar(_spec_do_farol())
		var plano := MooringRef.comando(global_position, rotation,
			posicao_alvo, rotacao_alvo, meia_eixos, velocidade_maxima)
		var alvo_mooring: Vector2 = plano["alvo"]
		var erro_dir := angle_difference(rotation,
			global_position.direction_to(alvo_mooring).angle())
		estercamento_alvo = clampf(erro_dir * 2.2, -max_estercamento, max_estercamento)
		velocidade_desejada = _velocidade_aproximacao_vaga(
			float((plano["comando"] as DriveCommand).throttle) * velocidade_maxima)
		if distancia_centro() < distancia_seguranca:
			velocidade_desejada = 0.0
		_aplicar_movimento(delta)
		if _esta_100_dentro_da_vaga() and absf(erro) < tolerancia_alinhamento and distancia < 12.0:
			if _vaga_alvo != null and _vaga_alvo.has_method("marcar_ocupada"):
				_vaga_alvo.marcar_ocupada()
			_mudar_estado(Estado.ESTACIONADO)
		return
	if distancia > tolerancia_chegada * 2.0:
		# Aproximacao: mira no centro, freia perto e muito devagar na boca.
		var erro_approach := angle_difference(rotation, global_position.direction_to(posicao_alvo).angle())
		estercamento_alvo = clampf(erro_approach * 1.8, -max_estercamento, max_estercamento)
		velocidade_desejada = _velocidade_aproximacao_vaga(75.0)
		if absf(erro_approach) > 0.6:
			velocidade_desejada = _velocidade_aproximacao_vaga(45.0)
		if distancia_centro() < distancia_seguranca:
			velocidade_desejada = 0.0
	else:
		# Perto do centro (mesmo com o casco ainda fora da vaga, o que acontece
		# quando o carro chega TORTO): gira parado para alinhar primeiro. Sem
		# isso o carro chegava a 13 px do centro com o casco atravessando a
		# borda, o portao "100% dentro" nunca abria e ele voltava a manobrar para
		# sempre (Fase4, 2026-09-26).
		if distancia < maxf(160.0, tolerancia_chegada * 4.0) and absf(erro) > 0.08:
			# Dentro da vaga: o UNICO lugar onde gira parado e permitido.
			estercamento_alvo = 0.0
			velocidade_desejada = 0.0
			rotation = lerp_angle(rotation, rotacao_alvo, delta * 2.0)
		elif absf(erro) > 0.7:
			# Muito torto: sobe devagar em arco, sem mergulhar em reta (a re da
			# versao antiga era o que gerava as centenas de frames de RE).
			estercamento_alvo = -sign(erro) * max_estercamento * 0.75
			velocidade_desejada = velocidade_alinhamento * 0.35
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
				velocidade_desejada = velocidade_alinhamento * 0.18
	_aplicar_movimento(delta)
	if _esta_100_dentro_da_vaga() and absf(erro) < tolerancia_alinhamento and distancia < 12.0:
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


## A MANOBRA final travou? true = o carro esta manobrando, se mexe, mas nao
## consegue entrar na vaga.
##
## Distingue dois casos que pareciam iguais (Fase5, 2026-09-26):
##   - manobra falha: o carro se mexe e nao entra -> DESISTE da vaga e pede
##     outra (e a blacklist impede que receba a mesma de volta);
##   - carro ENCAIXADO: o carro nao sai do lugar em absoluto -> aqui nao e' a
##     vaga que esta ruim, e' a posicao; responder dando manobras de re aqui
##     produzia 828 frames de re em 70 s, PIOR do que ficar parado.
## Por isso o teste exige movimento real na janela.
const _MANOBRA_MOV_MIN := 60.0

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
	# Manobra de três tempos (ré + giro): log para localizar o gatilho em jogo.
	print("[RECUPERACAO] estado=%d tentativas=%d estrategia=%d pos=%s rot=%.2f vel=%.0f wp=%d/%d" % [
		int(estado), tentativas + 1, estrategia, global_position, rotation,
		velocidade_atual, indice_waypoint, waypoints.size()])
	tentativas += 1
	tempo_no_waypoint = 0.0
	distancia_inicio_waypoint = global_position.distance_to(waypoints[indice_waypoint]) if indice_waypoint < waypoints.size() else 0.0
	contador_oscilacao = 0

	# Travamento detectado por DESLOCAMENTO: pula direto para a ultima
	# estrategia (replanejar), que e a unica que resolve "encostou na parede".
	if _tentativa_travada > 0:
		_tentativa_travada = 0
		tentativas = 2  # o proximo `if` cai na 3a (replanejamento)
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
			var nova_rota: Array = _rota_a_star_ate(alvo)
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
	if _reorientar_pos_reversao:
		_reorientar_pos_reversao = false
		_orientar_para_rota()
	_mudar_estado(Estado.BUSCANDO)


## Vira o nariz para a primeira PERNA REAL da rota (o primeiro waypoint a mais
## de 80 px), se ela apontar para tras (>~108 graus). Mesma regra que
## `_aplicar_rota` usa para um carro parado.
##
## Por que: na Fase3 seed 2 a re de emergencia tira o carro do solido
## (`inside` true -> false) mas o carro continua apontando para dentro do canto
## e volta a encravar. Medido nesse seed: a perna da rota saiu a apenas 18 graus
## do nariz, entao nao houve snap (o ganho ali e' zero) — a funcao existe para o
## caso em que a re deixa o carro virado para TRAS da rota, que e' o mesmo
## criterio que `_aplicar_rota` ja usa com o carro parado.
func _orientar_para_rota() -> void:
	if waypoints.size() < 2 or indice_waypoint >= waypoints.size() - 1:
		return
	var origem: Vector2 = global_position
	var dir: Vector2 = (waypoints[indice_waypoint] as Vector2) - origem
	for k in range(indice_waypoint, waypoints.size()):
		var cand: Vector2 = (waypoints[k] as Vector2) - origem
		if cand.length() > 80.0:
			dir = cand
			break
	if dir.length_squared() > 1.0 \
			and absf(angle_difference(rotation, dir.angle())) > PI * 0.6:
		rotation = dir.angle()
		velocidade_atual = 0.0


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


## O casco do carro (encolhido 35%) encosta em algum obstaculo solido?
## Buffer menor que a colisao real de proposito: o portão de estacionar nao pode
## reprovar o carro por estar PERTO da guia, so por estar SOBRE ela.
func _casco_em_cima_de_obstaculo() -> bool:
	var mundo := get_world_2d()
	if mundo == null:
		return false
	var forma: Shape2D = $CollisionShape2D.shape
	if forma == null:
		return false
	var rect := RectangleShape2D.new()
	rect.size = (forma as RectangleShape2D).size * global_scale * 0.65
	var xf := Transform2D(rotation, global_position)
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = rect
	q.transform = xf
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.margin = 0.0
	for r in mundo.direct_space_state.intersect_shape(q, 1):
		if r.is_empty():
			continue
		return true
	return false


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
	# Proibir estar EM CIMA da calçada. A versao anterior consultava a celula da
	# grade, que ja vem com a inflacao do raio varrido (137 px na Fase4): como a
	# vaga cola na guia, estar a poucos metros dela ja dava "solido" e o portao
	# NUNCA abria — a Fase4 ficava a 13 px do centro sem conseguir estacionar.
	# Agora e' a forma do casco encolhida contra a fisica (mask 2), que e' o que
	# a frase diz: o carro esta em cima da calçada, nao a 30 cm dela.
	return not _casco_em_cima_de_obstaculo()


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
	# v2 recorder contract (F1): 22 features, arrow slots DEAD (0.0).
	# See DatasetRecorder header for the column order.
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
	# [15..17] arrow slots: DEAD (setas ignored, locked B5) — always 0.0.
	f.append(0.0)
	f.append(0.0)
	f.append(0.0)
	# [18] yaw error to the spot heading, normalized by pi.
	var rot_v: float = rotacao_alvo
	if _vaga_alvo != null and "rotacao_alvo" in _vaga_alvo:
		rot_v = _vaga_alvo.rotacao_alvo
	f.append(clampf(angle_difference(rotation, rot_v) / PI, -1.0, 1.0))
	# [19] corridor width (px -> 0..1 over 2000px).
	var larg: float = minf(_distancia_ray(rays, SensorArrayRef.SIDE_LEFT),
			_distancia_ray(rays, SensorArrayRef.LATERAL_LEFT)) \
		+ minf(_distancia_ray(rays, SensorArrayRef.SIDE_RIGHT),
			_distancia_ray(rays, SensorArrayRef.LATERAL_RIGHT))
	f.append(clampf(larg / 2000.0, 0.0, 1.0))
	# [20] crosser distance (1.0 = none; crosser lands in F5).
	f.append(1.0)
	# [21] stuck time: progress watchdog, 0..1 over 10s.
	f.append(clampf(_tempo_parado / 10.0, 0.0, 1.0))
	return f


func _ml_gravar_linha() -> void:
	# Uma linha = (22 entradas v2, 2 ações do professor neste mesmo frame)
	if _ml_arquivo == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://ml/dados"))
		_ml_arquivo = FileAccess.open(ml_gravar_caminho, FileAccess.WRITE)
		if _ml_arquivo == null:
			push_warning("ML: falha ao abrir " + ml_gravar_caminho)
			ml_gravar = false
			return
	var f := _ml_features()
	if not DatasetRecorderRef.valid_row(f):
		push_warning("ML: linha descartada (%d feats, esperado %d)" % [f.size(), DatasetRecorderRef.FEATURE_COUNT])
		return
	# Row layout is the DatasetRecorder contract (22 feats + 2 labels).
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
	# ÁUDIO: campainha de vaga conquistada (uma vez, na transição).
	if novo == Estado.ESTACIONADO and audio_motor != null:
		audio_motor.call("play_park")
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
