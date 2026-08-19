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
		var pos: Vector2 = converter.call(carro.global_position)
		var dir: Vector2 = Vector2.RIGHT.rotated(carro.rotation)
		var tamanho: float = 5.0
		draw_colored_polygon(PackedVector2Array([
			pos + dir * tamanho,
			pos + dir.rotated(2.4) * tamanho * 0.8,
			pos + dir.rotated(-2.4) * tamanho * 0.8,
		]), Color(1, 0.6, 0, 1))


func _ponto(posicao: Vector2, raio: float, cor: Color) -> void:
	# Fora do retângulo do minimapa? Não desenha (evita borda poluída).
	if posicao.x < -raio or posicao.y < -raio or posicao.x > size.x + raio or posicao.y > size.y + raio:
		return
	draw_circle(posicao, raio, cor)