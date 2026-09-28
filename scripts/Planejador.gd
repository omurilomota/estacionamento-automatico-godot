extends Node2D
## PLANEJADOR GLOBAL — a "inteligência" (como Tesla/BYD fazem).
## Três camadas:
##  1) PERCEPÇÃO: varre o mundo (PhysicsDirectSpaceState2D) e monta um
##     MAPA DE OCUPAÇÃO — grade de células livres/bloqueadas, inflada com
##     o tamanho do carro (nunca planeja "espremer" entre obstáculos).
##  2) PLANEJAMENTO GLOBAL: roda A* (AStarGrid2D) na grade, do carro até
##     a vaga, e devolve a rota suavizada (vértices, sem zigue-zague).
##  3) VISUALIZAÇÃO: desenha a grade ocupada e a rota na tela (overlay de
##     raciocínio) — dá para VER o que o carro "enxerga" e o caminho dele.

@export var origem: Vector2 = Vector2(-640, -360)
@export var tamanho: Vector2 = Vector2(1280, 720)
@export var resolucao: int = 15
@export var inflar: float = 110.0
@export var mostrar_grade: bool = false
@export var mostrar_rota: bool = false

var _grade: AStarGrid2D
var _grade_pronta: bool = false
var _celulas_bloqueadas: Array[Vector2i] = []
var _imagem_grade: Image
var _textura_grade: ImageTexture
var _rota_desenhar: PackedVector2Array = []


func _n_cel_x() -> int:
	return maxi(1, int(ceil(tamanho.x / resolucao)))


func _n_cel_y() -> int:
	return maxi(1, int(ceil(tamanho.y / resolucao)))


func _celula_de(ponto: Vector2) -> Vector2i:
	var local: Vector2 = (ponto - origem) / resolucao
	return Vector2i(floori(local.x), floori(local.y))


func _centro_de(cel: Vector2i) -> Vector2:
	return origem + (Vector2(cel) + Vector2(0.5, 0.5)) * resolucao


func grade_pronta() -> bool:
	return _grade_pronta


## Invalida a grade para ser reconstruída no próximo plano. Usado quando a
## folga (inflar) muda em runtime — o carro ajusta a folga ao próprio raio
## varrido antes de planejar (ver Carro._garantir_folga_do_planejador()).
func invalidar_grade() -> void:
	_grade_pronta = false


# Monta o mapa de ocupação do zero (usa os valores atuais de origem/tamanho).
# O AStarGrid2D é criado AQUI (não no _ready) para que as fases possam
# configurar o tamanho do mundo antes do primeiro planejamento.
func construir() -> void:
	_grade = AStarGrid2D.new()
	_grade.cell_size = Vector2(resolucao, resolucao)
	_grade.offset = origem
	_grade.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_grade.region = Rect2i(0, 0, _n_cel_x(), _n_cel_y())
	_grade.update()

	# v2 (F3): use the exported inflation instead of the hard-coded 95px.
	# The 95px circle under-estimated the 2x-scaled car footprint
	# (88x74 local -> 176x148 world): A* returned paths that were valid
	# on the grid but physically too tight, and the pilot ground against
	# sidewalk corners. Level scenes tune this declaratively (inflar).
	var inflar_efetivo: float = clampf(inflar, 60.0, 240.0)
	var espaco := get_world_2d().direct_space_state
	var forma := CircleShape2D.new()
	forma.radius = inflar_efetivo
	var parametros := PhysicsShapeQueryParameters2D.new()
	parametros.collision_mask = 2
	parametros.collide_with_bodies = true
	parametros.collide_with_areas = false
	parametros.shape = forma

	_celulas_bloqueadas.clear()
	for y in range(_n_cel_y()):
		for x in range(_n_cel_x()):
			var centro: Vector2 = _centro_de(Vector2i(x, y))
			parametros.transform = Transform2D(0, centro)
			var acertos := espaco.intersect_shape(parametros, 1)
			if not acertos.is_empty():
				_grade.set_point_solid(Vector2i(x, y), true)
				_celulas_bloqueadas.append(Vector2i(x, y))
	# Preferência por setas (0.7 a favor — só se houver Node Setas)
	# v2 (F2/locked B5): arrows are IGNORED. The planner is a pure service
	# fed by injected RouteHints; legacy scene crawling stays below ONLY
	# for levels not yet migrated (Fase2/Fase3 scenes still carry Setas).
	# RouteHints overrides this block entirely when provided (see
	# aplicar_hints / _hints_ativas below).
	_aplicar_pesos_legado_setas()
	# v2 (F2): legacy arrow preference, extracted unchanged. Called by
# construir() ONLY when no RouteHints were injected (empty hints =
# arrows ignored, locked B5). Kept for unmigrated levels.
func _aplicar_pesos_legado_setas() -> void:
	if _hints_ativas():
		return
	var setas_node := get_parent().get_node_or_null("Setas")
	if setas_node == null:
		return
	for seta in setas_node.get_children():
		if not ("direcao" in seta):
			continue
		var pos_seta: Vector2 = seta.global_position
		for y in range(_n_cel_y()):
			for x in range(_n_cel_x()):
				var cel := Vector2i(x, y)
				if _grade.is_point_solid(cel):
					continue
				var centro: Vector2 = _centro_de(cel)
				var dist_c := centro.distance_to(pos_seta)
				if dist_c < 70.0:
					_grade.set_point_weight_scale(cel, 0.7)
				elif dist_c < 140.0:
					if _grade.get_point_weight_scale(cel) == 1.0:
						_grade.set_point_weight_scale(cel, 0.85)


# --- v2 (F2): injected route hints (pure-service contract) ---------------
# LevelManager (or a test) sets these once; the planner never crawls the
# scene tree for them. Empty hints = no preference (weight 1.0 = ignored).
var _hints_lanes: Array = []
var _hints_points: Array = []
var _hints_radius: float = 70.0


func _hints_ativas() -> bool:
	return not _hints_lanes.is_empty() or not _hints_points.is_empty()


## Inject lane/arrow preferences (see src/navigation/RouteHints).
## Pass empty arrays to IGNORE all hints (locked B5 default).
func aplicar_hints(lanes: Array = [], points: Array = [], radius: float = 70.0) -> void:
	_hints_lanes = lanes
	_hints_points = points
	_hints_radius = radius
	_grade_pronta = false


func _aplicar_hints() -> void:
	for lane in _hints_lanes:
		if lane.size() < 2:
			continue
		for y in range(_n_cel_y()):
			for x in range(_n_cel_x()):
				var cel := Vector2i(x, y)
				if _grade.is_point_solid(cel):
					continue
				var centro: Vector2 = _centro_de(cel)
				var dist_r: float = INF
				for i in range(lane.size() - 1):
					dist_r = minf(dist_r, Geometry2D.get_closest_point_to_segment(
						centro, lane[i], lane[i + 1]).distance_to(centro))
					if dist_r < 45.0:
						break
				if dist_r < 45.0:
					_grade.set_point_weight_scale(cel, 0.65)
				elif dist_r < 90.0:
					if _grade.get_point_weight_scale(cel) == 1.0:
						_grade.set_point_weight_scale(cel, 0.85)


# Preferência por Rotas Line2D (ruas desenhadas): peso 0.65 perto da linha, 0.85 até 90px
	# v2 (F2): injected hints win; legacy scene crawl only when NO hints
	# were injected (empty = ignored, locked B5). Unmigrated levels keep
	# the old behavior until LevelManager feeds them hints.
	if _hints_ativas():
		_aplicar_hints()
	else:
		_aplicar_pesos_legado_rotas()
	# v2 (F2): legacy Line2D preference, extracted unchanged (see note on
# _aplicar_pesos_legado_setas). Only runs when no hints were injected.
func _aplicar_pesos_legado_rotas() -> void:
	var rotas_node := get_parent().get_node_or_null("Rotas")
	if rotas_node == null:
		return
	for child in rotas_node.get_children():
		if not (child is Line2D):
			continue
		var pts_rota: PackedVector2Array = child.points
		if pts_rota.size() < 2:
			continue
		for y in range(_n_cel_y()):
			for x in range(_n_cel_x()):
				var cel_r := Vector2i(x, y)
				if _grade.is_point_solid(cel_r):
					continue
				var centro_r: Vector2 = _centro_de(cel_r)
				var dist_r: float = INF
				for i in range(pts_rota.size() - 1):
					var a_r: Vector2 = child.to_global(pts_rota[i])
					var b_r: Vector2 = child.to_global(pts_rota[i + 1])
					dist_r = minf(dist_r, Geometry2D.get_closest_point_to_segment(centro_r, a_r, b_r).distance_to(centro_r))
					if dist_r < 45.0:
						break
				if dist_r < 45.0:
					_grade.set_point_weight_scale(cel_r, 0.65)
				elif dist_r < 90.0:
					if _grade.get_point_weight_scale(cel_r) == 1.0:
						_grade.set_point_weight_scale(cel_r, 0.85)


# HD-Map manual: viradas sempre pela faixa (peso 1.0 na faixa, 1.5 fora)
	var road_graph_res = load("res://resources/RoadGraph.tres")
	if road_graph_res != null and road_graph_res.get("lanes") != null:
		for y in range(_n_cel_y()):
			for x in range(_n_cel_x()):
				var cel := Vector2i(x, y)
				if _grade.is_point_solid(cel):
					continue
				var centro: Vector2 = _centro_de(cel)
				var menor_dist := INF
				var largura_faixa := 60.0
				for lane in road_graph_res.get("lanes"):
					var pts: PackedVector2Array = lane.pontos
					largura_faixa = lane.largura if "largura" in lane else 60.0
					for i in range(pts.size() - 1):
						var d := Geometry2D.get_closest_point_to_segment(centro, pts[i], pts[i+1]).distance_to(centro)
						menor_dist = minf(menor_dist, d)
						if menor_dist < largura_faixa * 0.5:
							break
					if menor_dist < largura_faixa * 0.5:
						break
				if menor_dist > 40.0:
					var w := _grade.get_point_weight_scale(cel)
					_grade.set_point_weight_scale(cel, maxf(w, 1.5))
	# _grade.update() aqui limpava sólidos — removido
	_grade_pronta = true
	_gerar_imagem_grade()
	queue_redraw()


# A grade vira uma IMAGEM pequena (1 px por célula) esticada no mundo.
# Desenhar milhares de retângulos por frame seria caro; assim é baratíssimo.
func _gerar_imagem_grade() -> void:
	_imagem_grade = Image.create(_n_cel_x(), _n_cel_y(), false, Image.FORMAT_RGBA8)
	_imagem_grade.fill(Color(0, 0, 0, 0))
	var ocupado := Color(1, 0.25, 0.25, 0.28)
	# Filtra borda do mapa: paredes do perímetro (geradas em FaseBase) não devem aparecer vermelhas
	var margem_borda: float = 100.0
	for cel in _celulas_bloqueadas:
		var centro: Vector2 = _centro_de(cel)
		if centro.x < origem.x + margem_borda or centro.x > origem.x + tamanho.x - margem_borda:
			continue
		if centro.y < origem.y + margem_borda or centro.y > origem.y + tamanho.y - margem_borda:
			continue
		_imagem_grade.set_pixel(cel.x, cel.y, ocupado)
	_textura_grade = ImageTexture.create_from_image(_imagem_grade)


# Encontra a célula livre mais próxima de uma posição (usada quando o alvo
# cai dentro de uma célula bloqueada pela inflação, ex.: borda de vaga).
# A região é checada ANTES de is_point_solid: um ponto fora da grid faz o
# AStarGrid2D emeter erro e devolver lixo (Fase1, 2026-09-26) — em vez disso
# devolvemos a célula livre mais próxima que DENTRO da região.
func _celula_livre_proxima(cel: Vector2i) -> Vector2i:
	if not _grade.region.has_point(cel):
		cel = Vector2i(
			clampi(cel.x, _grade.region.position.x, _grade.region.end.x - 1),
			clampi(cel.y, _grade.region.position.y, _grade.region.end.y - 1))
	if not _grade.is_point_solid(cel):
		return cel
	for raio in range(1, maxi(_n_cel_x(), _n_cel_y())):
		for y in range(cel.y - raio, cel.y + raio + 1):
			for x in range(cel.x - raio, cel.x + raio + 1):
				var c := Vector2i(x, y)
				if _grade.region.has_point(c) and not _grade.is_point_solid(c):
					return c
	return cel


func snapshot() -> Dictionary:
	return {
		"origem": origem,
		"tamanho": tamanho,
		"resolucao": resolucao,
		"region": _grade.region if _grade != null else Rect2i(0,0,0,0),
		"celulas": _celulas_bloqueadas.duplicate(),
		"pronta": _grade_pronta,
	}


func achar_rota_snapshot(origem_ponto: Vector2, destino_ponto: Vector2, snap: Dictionary) -> Array:
	if not snap.pronta:
		return achar_rota(origem_ponto, destino_ponto)
	var resol_snap: int = snap.resolucao
	var origem_snap: Vector2 = snap.origem
	var _celula_de_snap = func(p: Vector2) -> Vector2i:
		var local: Vector2 = (p - origem_snap) / resol_snap
		return Vector2i(floori(local.x), floori(local.y))
	var _centro_de_snap = func(cel: Vector2i) -> Vector2:
		return origem_snap + (Vector2(cel) + Vector2(0.5, 0.5)) * resol_snap
	var _celula_livre_proxima_snap = func(cel: Vector2i, g_local: AStarGrid2D) -> Vector2i:
		if not g_local.is_point_solid(cel):
			return cel
		for raio in range(1, maxi(g_local.region.size.x, g_local.region.size.y)):
			for y in range(cel.y - raio, cel.y + raio + 1):
				for x in range(cel.x - raio, cel.x + raio + 1):
					var c := Vector2i(x, y)
					if g_local.region.has_point(c) and not g_local.is_point_solid(c):
						return c
		return cel
	var grade_local := AStarGrid2D.new()
	grade_local.region = snap.region
	grade_local.cell_size = Vector2(resol_snap, resol_snap)
	grade_local.offset = origem_snap
	grade_local.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grade_local.update()
	for cel in snap.celulas:
		grade_local.set_point_solid(cel, true)
	# Copia pesos de setas se houver (preferência)
	var setas_node := get_parent().get_node_or_null("Setas")
	if setas_node != null:
		for seta in setas_node.get_children():
			if not ("direcao" in seta):
				continue
			var pos_seta: Vector2 = seta.global_position
			for y in range(grade_local.region.size.y):
				for x in range(grade_local.region.size.x):
					var cel := Vector2i(x, y)
					if grade_local.is_point_solid(cel):
						continue
					var centro: Vector2 = _centro_de_snap.call(cel)
					var dist_s := centro.distance_to(pos_seta)
					if dist_s < 70.0:
						grade_local.set_point_weight_scale(cel, 0.7)
					elif dist_s < 140.0 and grade_local.get_point_weight_scale(cel) == 1.0:
						grade_local.set_point_weight_scale(cel, 0.85)
	# Rotas Line2D snapshot: preferir rua
	var rotas_node_snap := get_parent().get_node_or_null("Rotas")
	if rotas_node_snap != null:
		for child_snap in rotas_node_snap.get_children():
			if not (child_snap is Line2D):
				continue
			var pts_snap: PackedVector2Array = child_snap.points
			if pts_snap.size() < 2:
				continue
			for y in range(grade_local.region.size.y):
				for x in range(grade_local.region.size.x):
					var cel_r2 := Vector2i(x, y)
					if grade_local.is_point_solid(cel_r2):
						continue
					var centro_r2: Vector2 = _centro_de_snap.call(cel_r2)
					var dist_r2: float = INF
					for i in range(pts_snap.size() - 1):
						var a_s: Vector2 = child_snap.to_global(pts_snap[i])
						var b_s: Vector2 = child_snap.to_global(pts_snap[i + 1])
						dist_r2 = minf(dist_r2, Geometry2D.get_closest_point_to_segment(centro_r2, a_s, b_s).distance_to(centro_r2))
						if dist_r2 < 45.0:
							break
					if dist_r2 < 45.0:
						grade_local.set_point_weight_scale(cel_r2, 0.65)
					elif dist_r2 < 90.0 and grade_local.get_point_weight_scale(cel_r2) == 1.0:
						grade_local.set_point_weight_scale(cel_r2, 0.85)
	# HD-Map manual snapshot
	var road_graph_res_snap = load("res://resources/RoadGraph.tres")
	if road_graph_res_snap != null and road_graph_res_snap.get("lanes") != null:
		for y in range(grade_local.region.size.y):
			for x in range(grade_local.region.size.x):
				var cel2 := Vector2i(x, y)
				if grade_local.is_point_solid(cel2):
					continue
				var centro2: Vector2 = _centro_de_snap.call(cel2)
				var menor_dist2 := INF
				for lane in road_graph_res_snap.get("lanes"):
					var pts2: PackedVector2Array = lane.pontos
					for i in range(pts2.size() - 1):
						var d2 := Geometry2D.get_closest_point_to_segment(centro2, pts2[i], pts2[i+1]).distance_to(centro2)
						menor_dist2 = minf(menor_dist2, d2)
						if menor_dist2 < 30.0:
							break
					if menor_dist2 < 30.0:
						break
				if menor_dist2 > 40.0:
					var w2 := grade_local.get_point_weight_scale(cel2)
					grade_local.set_point_weight_scale(cel2, maxf(w2, 1.5))
	var o_snap = _celula_livre_proxima_snap.call(_celula_de_snap.call(origem_ponto), grade_local)
	var d_snap = _celula_livre_proxima_snap.call(_celula_de_snap.call(destino_ponto), grade_local)
	if not grade_local.region.has_point(o_snap) or not grade_local.region.has_point(d_snap):
		return []
	var caminho = grade_local.get_point_path(o_snap, d_snap)
	if caminho.size() < 2:
		return []
	return _decimar(caminho)


func achar_rota(origem_ponto: Vector2, destino_ponto: Vector2) -> Array:
	var caminho := achar_rota_crua(origem_ponto, destino_ponto)
	if caminho.size() < 2:
		return []
	return _decimar(caminho)


## Caminho A* SEM decimar (a escadaria de células, um ponto a cada ~15 px).
## O `LaneOffset` precisa dele: deslocar a escadaria densa produz uma faixa
## contínua e paralela, enquanto deslocar a polilinha JÁ decimada (8 pontos em
## 1900 px, com tangentes alternando ~90 graus) produz um zigue-zague — foi o
## que deixou o carro no meio da rua em 2026-09-26. Deslocar e só depois
## chamar `decimar()` é a ordem certa (ver Carro._rota_a_star_ate).
func achar_rota_crua(origem_ponto: Vector2, destino_ponto: Vector2) -> PackedVector2Array:
	if not _grade_pronta:
		construir()
	var o := _celula_livre_proxima(_celula_de(origem_ponto))
	var d := _celula_livre_proxima(_celula_de(destino_ponto))
	if not _grade.region.has_point(o) or not _grade.region.has_point(d):
		return PackedVector2Array()
	var caminho := _grade.get_point_path(o, d)
	if caminho.size() < 2:
		return PackedVector2Array()
	return caminho


## RDP público: o chamador que compõe o caminho final (deslocado) o simplifica
## depois de aplicar as transformações geométricas.
func decimar(caminho: PackedVector2Array) -> Array:
	return _decimar(caminho)


# Ponto de partida ALEATÓRIO: uma célula livre qualquer (não colide com
# obstáculos — a grade já é inflada) e fora dos retângulos proibidos
# (ex.: as vagas, para o carro nunca nascer em cima de uma vaga).
#
# `limite_spawn` (a fase passa o retângulo do MAPA) é obrigatório na prática:
# a grade de ocupação cobre a geometria INTEIRA mais o alcance de preparação
# (FaseBase._limites_de_planejamento), e esse anel tem células livres fora do
# lote — sem o limite o carro nasce num bolso de canto e a matriz de seeds
# caiu de 10/10 para 4/10 em 2026-09-26.
func achar_posicao_livre(retangulos_proibidos: Array[Rect2] = [], limite_spawn: Rect2 = Rect2()) -> Vector2:
	if not _grade_pronta:
		construir()
	var livres: Array[Vector2i] = []
	for y in range(_n_cel_y()):
		for x in range(_n_cel_x()):
			var cel := Vector2i(x, y)
			if _grade.is_point_solid(cel):
				continue
			var centro: Vector2 = _centro_de(cel)
			if limite_spawn.size != Vector2.ZERO and not limite_spawn.has_point(centro):
				continue
			var bloqueado := false
			for r in retangulos_proibidos:
				if r.has_point(centro):
					bloqueado = true
					break
			if not bloqueado:
				livres.append(cel)
	if livres.is_empty():
		return Vector2.INF
	return _centro_de(livres[randi() % livres.size()])


# A rota que o carro está seguindo (desenhada na tela).
func definir_rota(rota: Array) -> void:
	_rota_desenhar.clear()
	for ponto in rota:
		_rota_desenhar.append(ponto)
	queue_redraw()


# Simplifica a rota com Ramer-Douglas-Peucker: tira os "degraus" do grid e
# os micro-desvios que só fariam o carro virar à toa. Sobra uma polilinha
# com poucos vértices, que o pure pursuit segue de forma suave e reta nas
# frestas largas (onde daria para ir sem raspar).
func _decimar(caminho: PackedVector2Array) -> Array:
	if caminho.size() < 3:
		return Array(caminho)
	return _rdp(caminho, 0, caminho.size() - 1, 18.0)


func _rdp(caminho: PackedVector2Array, inicio: int, fim: int, tolerancia: float) -> Array:
	if inicio >= fim:
		return [caminho[inicio]]
	var ponto_inicio: Vector2 = caminho[inicio]
	var ponto_fim: Vector2 = caminho[fim]
	var mais_longe: float = 0.0
	var indice_longe: int = -1
	for i in range(inicio + 1, fim):
		var dist := caminho[i].distance_to(
			Geometry2D.get_closest_point_to_segment(caminho[i], ponto_inicio, ponto_fim)
		)
		if dist > mais_longe:
			mais_longe = dist
			indice_longe = i
	if mais_longe <= tolerancia:
		return [ponto_inicio, ponto_fim]
	var esquerda: Array = _rdp(caminho, inicio, indice_longe, tolerancia)
	var direita: Array = _rdp(caminho, indice_longe, fim, tolerancia)
	esquerda.pop_back()
	for p in direita:
		esquerda.append(p)
	return esquerda


func _draw() -> void:
	if mostrar_grade and _textura_grade != null:
		draw_texture_rect(_textura_grade, Rect2(origem, tamanho), false)
	if mostrar_setas and _rota_desenhar.size() >= 2:
		_desenhar_rota_com_setas()


## A rota que o carro vai seguir, com SETAS no rumo (2026-09-26, pedido do
## usuario: "poderia ter setas também"). Desenhadas aqui, e nao com o
## scenes/Seta.tscn, porque aquele nó é PISTAS de fluxo para o custo do A* —
## uma coisa e legibilidade de rota sao coisas diferentes e nao se confundem.
@export var mostrar_setas: bool = true
@export var espaco_setas: float = 190.0 ## px entre uma seta e a seguinte
@export var cor_rota := Color(0.2, 0.85, 1.0, 0.75)
@export var cor_seta := Color(1.0, 0.82, 0.25, 0.95)


func _desenhar_rota_com_setas() -> void:
	draw_polyline(_rota_desenhar, cor_rota, 4.0, true)
	var acumulado: float = espaco_setas
	for i in range(1, _rota_desenhar.size()):
		var a: Vector2 = _rota_desenhar[i - 1]
		var b: Vector2 = _rota_desenhar[i]
		var seg: Vector2 = b - a
		var comprimento: float = seg.length()
		if comprimento < 1.0:
			continue
		var u: Vector2 = seg / comprimento
		var d: float = acumulado
		while d < comprimento:
			var p: Vector2 = a + u * d
			# chevao como triangulo, orientada para a tangente local
			var pts := PackedVector2Array([
				p + u * 26.0,
				p - u * 18.0 + u.orthogonal() * 22.0,
				p - u * 18.0 - u.orthogonal() * 22.0,
			])
			draw_colored_polygon(pts, cor_seta)
			d += espaco_setas
		acumulado = maxf(0.0, d - comprimento)
