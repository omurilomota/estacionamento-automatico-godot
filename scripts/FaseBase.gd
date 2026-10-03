extends Node2D
## FASE BASE — esqueleto de cada mapa (fase) do estacionamento.
## Cobre o mapa, cria a câmera que segue o carro, paredes no perímetro
## e a mesma UI de status/sensores/tentativas da cena de demonstração.
## Teclas: 1/2/3/4/5 trocam de fase, R reinicia a fase atual.

const FASES := Fases.FASES
const NOMES_ESTADO := Fases.NOMES_ESTADO

# Qual imagem usar como chão da fase e em quanto ampliar (no mundo).
@export var mapa: Texture2D
@export var escala_mapa: float = 1.5
@export var zoom_camera: float = 0.8
# Sorteia uma posição de partida para o carro (nunca em cima de uma vaga).
@export var posicao_aleatoria: bool = true
## Painel único de HUD (scenes/Hud.tscn, instanciado como UI/Control). Esta
## cena não escreve mais em labels: quem escreve é o `Hud`, via sinais.
@export var hud_path: NodePath = NodePath("UI/Control")

@onready var sprite_mapa: Sprite2D = $Mapa
@onready var paredes: Node2D = $Paredes
@onready var carro: Node2D = $Carro
@onready var vagas: Node2D = $Vagas
@onready var waypoints: Node2D = $Waypoints
@onready var planejador: Node2D = $Planejador
@onready var camera: Camera2D = $Camera
@onready var hud: Control = get_node_or_null(hud_path)

# Tamanho do mundo em pixels (centrado na origem).
var largura_mundo: float = 1280.0
var altura_mundo: float = 720.0

var _posicionar_pendente: bool = true


func _ready() -> void:
	_configurar_mapa()
	_criar_paredes()
	_configurar_camera()

	# O minimapa acompanha o tamanho real do mundo (mapa * escala).
	if hud != null and hud.has_method("set_world_size"):
		hud.call("set_world_size", Vector2(largura_mundo, altura_mundo))

	# O planejador global precisa cobrir a GEOMETRIA REAL da fase, não só o
	# retângulo do mapa: o ponto de preparação de uma vaga fica ~2,5 entre-eixos
	# além do centro dela, e em Fase1 esse ponto caía FORA da grade — o A* erro,
	# `achar_rota` voltava vazio e o carro ficava em BUSCANDO com 0 waypoints.
	var limites := _limites_de_planejamento()
	planejador.origem = limites.position
	planejador.tamanho = limites.size

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
	if carro.has_signal("modo_mudou"):
		carro.modo_mudou.connect(_ao_mudar_modo)
	# HUD é o DONO dos textos: esta cena só entrega as referências.
	if hud != null and hud.has_method("bind_vehicle"):
		hud.call("bind_vehicle", carro)
	if hud != null and hud.has_method("bind_world"):
		hud.call("bind_world", planejador, vagas)
	if hud != null and hud.has_method("bind_routes"):
		hud.call("bind_routes", get_node_or_null("Rotas"))


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
	# O spawn vem do retângulo do MAPA, nunca da grade inteira: a grade cobre
	# também o anel de preparação, e esse anel tem células livres fora do lote.
	var limite_mapa := Rect2(-largura_mundo / 2.0, -altura_mundo / 2.0, largura_mundo, altura_mundo)
	var posicao: Vector2 = planejador.achar_posicao_livre(proibidos, limite_mapa)
	if posicao == Vector2.INF:
		return
	carro.global_position = posicao
	carro.rotation = 0.0


func _process(_delta: float) -> void:
	_seguir_carro()


func _ao_mudar_modo(_modo: int) -> void:
	# O HUD escuta `modo_mudou` diretamente; nada a fazer aqui.
	pass


func _unhandled_input(event: InputEvent) -> void:
	# Teclas de teste: 1/2/3/4 trocam de fase, R reinicia a atual.
	if event is InputEventKey and event.pressed and not event.echo:
		# 1..9 e 0 para a decima (ver Mundo.gd: KEY_1 + 9 seria KEY_COLON).
		# P abre a Fase11 (Trânsito): o teclado so tem dez digitos, e a
		# decima primeira fase ficou sem digito — a letra e o mnemonico
		# do nivel de pedestres/pneus/acidente (docs/tasks_trafego.md).
		var indice: int = event.keycode - KEY_1
		if event.keycode == KEY_0:
			indice = 9
		elif event.keycode == KEY_P:
			indice = 10
		if indice >= 0 and indice < FASES.size():
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


## Retângulo que a grade de ocupação precisa cobrir: o mapa, UNIDO à geometria
## realmente colocada na cena (vagas, obstáculos, ponto de partida) e
## estendido pelo alcance de preparação do carro. Tudo é declarativo — a fase
## não fica procurando o carro no mundo, só lê os filhos que ela já tem.
func _limites_de_planejamento() -> Rect2:
	var r := Rect2(-largura_mundo / 2.0, -altura_mundo / 2.0, largura_mundo, altura_mundo)
	if vagas != null:
		for v in vagas.get_children():
			r = r.merge(_retangulo_do_no(v))
	if waypoints != null:
		for wp in waypoints.get_children():
			r = r.merge(_retangulo_do_no(wp))
	var obst: Node2D = get_node_or_null("Obstaculos") as Node2D
	if obst != null:
		for o in obst.get_children():
			r = r.merge(_retangulo_do_no(o))
	if carro != null:
		r = r.merge(Rect2(carro.global_position, Vector2.ZERO))
	# O ponto de preparação vive `alcance_preparo()` além do centro da vaga.
	var folga: float = 80.0
	if carro != null and carro.has_method("alcance_preparo"):
		folga = float(carro.alcance_preparo())
	return r.grow(folga)


## AABB de um nó da cena a partir das CollisionShape2D que ele contém.
func _retangulo_do_no(no: Node2D) -> Rect2:
	var r := Rect2(no.global_position, Vector2.ZERO)
	for filho in no.get_children():
		if filho is CollisionShape2D:
			var cs := filho as CollisionShape2D
			if cs.shape is RectangleShape2D:
				var tam: Vector2 = (cs.shape as RectangleShape2D).size * no.global_scale
				var centro: Vector2 = no.global_position + cs.position * no.global_scale
				r = r.merge(Rect2(centro - tam * 0.5, tam))
	return r


func _criar_paredes() -> void:
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


func _ao_mudar_estado(_nome: String) -> void:
	# O HUD escuta `estado_mudou` e monta o texto (inclusive o caso
	# "parado por obstáculo" do modo trilha).
	pass


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


func _ao_mudar_tentativa(_tentativas: int, _estrategia: String) -> void:
	# O HUD escuta `tentativa_mudou` e escreve a linha.
	pass


func _ao_pedir_nova_vaga() -> void:
	# No modo automático o próprio carro escolhe outra vaga (Planejador).
	if carro.auto_navegacao:
		return
	# Modo manual: escolhe a primeira vaga livre.
	for vaga in vagas.get_children():
		if not vaga.ocupada:
			if hud != null and hud.has_method("set_attempt"):
				hud.call("set_attempt", 0, "Procurando outra vaga")
			carro.definir_waypoints([vaga.global_position])
			return
	if hud != null and hud.has_method("set_attempt"):
		hud.call("set_attempt", 0, "Sem vagas livres")
