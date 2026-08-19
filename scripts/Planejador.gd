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
@export var resolucao: int = 20
@export var inflar: float = 50.0
@export var mostrar_grade: bool = true
@export var mostrar_rota: bool = true

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


# Monta o mapa de ocupação do zero (usa os valores atuais de origem/tamanho).
# O AStarGrid2D é criado AQUI (não no _ready) para que as fases possam
# configurar o tamanho do mundo antes do primeiro planejamento.
func construir() -> void:
	_grade = AStarGrid2D.new()
	_grade.cell_size = Vector2(resolucao, resolucao)
	_grade.offset = origem
	_grade.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grade.region = Rect2i(0, 0, _n_cel_x(), _n_cel_y())
	_grade.update()

	var espaco := get_world_2d().direct_space_state
	var forma := CircleShape2D.new()
	forma.radius = inflar
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
	_grade.update()
	_grade_pronta = true
	_gerar_imagem_grade()
	queue_redraw()


# A grade vira uma IMAGEM pequena (1 px por célula) esticada no mundo.
# Desenhar milhares de retângulos por frame seria caro; assim é baratíssimo.
func _gerar_imagem_grade() -> void:
	_imagem_grade = Image.create(_n_cel_x(), _n_cel_y(), false, Image.FORMAT_RGBA8)
	_imagem_grade.fill(Color(0, 0, 0, 0))
	var ocupado := Color(1, 0.25, 0.25, 0.28)
	for cel in _celulas_bloqueadas:
		_imagem_grade.set_pixel(cel.x, cel.y, ocupado)
	_textura_grade = ImageTexture.create_from_image(_imagem_grade)


# Encontra a célula livre mais próxima de uma posição (usada quando o alvo
# cai dentro de uma célula bloqueada pela inflação, ex.: borda de vaga).
func _celula_livre_proxima(cel: Vector2i) -> Vector2i:
	if not _grade.is_point_solid(cel):
		return cel
	for raio in range(1, maxi(_n_cel_x(), _n_cel_y())):
		for y in range(cel.y - raio, cel.y + raio + 1):
			for x in range(cel.x - raio, cel.x + raio + 1):
				var c := Vector2i(x, y)
				if _grade.region.has_point(c) and not _grade.is_point_solid(c):
					return c
	return cel


func achar_rota(origem_ponto: Vector2, destino_ponto: Vector2) -> Array:
	if not _grade_pronta:
		construir()
	var o := _celula_livre_proxima(_celula_de(origem_ponto))
	var d := _celula_livre_proxima(_celula_de(destino_ponto))
	if not _grade.region.has_point(o) or not _grade.region.has_point(d):
		return []
	var caminho := _grade.get_point_path(o, d)
	if caminho.size() < 2:
		return []
	return _decimar(caminho)


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
	return _rdp(caminho, 0, caminho.size() - 1, 12.0)


func _rdp(caminho: PackedVector2Array, inicio: int, fim: int, tolerancia: float) -> Array:
	if inicio >= fim:
		return [caminho[inicio]]
	var ponto_inicio: Vector2 = caminho[inicio]
	var ponto_fim: Vector2 = caminho[fim]
	var mais_longe: float = 0.0
	var indice_longe: int = -1
	for i in range(inicio + 1, fim):
		var dist := Geometry2D.get_distance_to_segment(caminho[i], ponto_inicio, ponto_fim)
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
	if mostrar_rota and _rota_desenhar.size() >= 2:
		draw_polyline(_rota_desenhar, Color(1, 0.85, 0.2, 0.9), 3.0)