extends Control
## MINIMAPA — visão "de cima" do mapa todo + posição do carro.
## Desenha tudo com _draw (leve, sem câmera extra). Usado pela cena de
## demonstração e pelas fases, configurando mundo_centro/mundo_tamanho.

@export var mundo_centro: Vector2 = Vector2(640, 360)
@export var mundo_tamanho: Vector2 = Vector2(1280, 720)
@export var carro_path: NodePath
@export var vagas_path: NodePath
@export var waypoints_path: NodePath
@export var obstaculos_path: NodePath

@onready var carro: Node2D = get_node_or_null(carro_path)
@onready var vagas: Node2D = get_node_or_null(vagas_path)
@onready var waypoints: Node2D = get_node_or_null(waypoints_path)
@onready var obstaculos: Node2D = get_node_or_null(obstaculos_path)


func _process(_delta: float) -> void:
	# O carro se move todo frame => redesenha.
	queue_redraw()


func _draw() -> void:
	# Fundo e moldura.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55), true)
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.6), false, 1.0)

	var canto: Vector2 = mundo_centro - mundo_tamanho * 0.5
	var escala: Vector2 = size / mundo_tamanho

	# Converte uma posição do MUNDO em posição do minimapa.
	var converter := func(p: Vector2) -> Vector2:
		return (p - canto) * escala

	if obstaculos != null:
		for filho in obstaculos.get_children():
			_ponto(converter.call(filho.global_position), 3.0, Color(0.6, 0.6, 0.6, 0.8))

	if waypoints != null:
		for wp in waypoints.get_children():
			_ponto(converter.call(wp.global_position), 2.5, Color(1, 1, 1, 0.7))

	if vagas != null:
		for vaga in vagas.get_children():
			var cor: Color = Color(0.95, 0.3, 0.3, 0.9) if vaga.ocupada else Color(0.3, 0.9, 0.35, 0.9)
			_ponto(converter.call(vaga.global_position), 4.0, cor)

	if carro != null:
		# Triângulo laranja apontando na direção do carro.
		if mundo_tamanho.x < 1.0 or mundo_tamanho.y < 1.0 or size.x < 1.0 or size.y < 1.0:
			return
		if not carro.global_position.is_finite() or not is_finite(carro.rotation):
			return
		var pos: Vector2 = converter.call(carro.global_position)
		if not pos.is_finite():
			return
		var dir: Vector2 = Vector2.RIGHT.rotated(carro.rotation)
		if not dir.is_finite() or dir.length() < 0.5:
			return
		var tamanho: float = 6.0
		var p1: Vector2 = pos + dir * tamanho
		var p2: Vector2 = pos + dir.rotated(2.6) * tamanho * 0.7
		var p3: Vector2 = pos + dir.rotated(-2.6) * tamanho * 0.7
		if not p1.is_finite() or not p2.is_finite() or not p3.is_finite():
			return
		# Se o triângulo sai muito do minimapa, desenha círculo em vez de polígono
		if p1.x < -5 or p1.y < -5 or p1.x > size.x+5 or p1.y > size.y+5:
			draw_circle(pos, 3.0, Color(1, 0.6, 0, 1))
			return
		if p1.distance_squared_to(p2) < 2.0 or p2.distance_squared_to(p3) < 2.0 or p3.distance_squared_to(p1) < 2.0:
			return
		var area: float = absf((p2.x - p1.x)*(p3.y - p1.y) - (p3.x - p1.x)*(p2.y - p1.y)) * 0.5
		if area < 2.0:
			draw_circle(pos, 3.0, Color(1, 0.6, 0, 1))
			return
		draw_colored_polygon(PackedVector2Array([p1, p2, p3]), Color(1, 0.6, 0, 1))


func _ponto(posicao: Vector2, raio: float, cor: Color) -> void:
	# Fora do retângulo do minimapa? Não desenha (evita borda poluída).
	if posicao.x < -raio or posicao.y < -raio or posicao.x > size.x + raio or posicao.y > size.y + raio:
		return
	draw_circle(posicao, raio, cor)
