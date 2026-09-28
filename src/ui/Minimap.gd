class_name Minimap
extends "res://scripts/Minimapa.gd"
## English facade: same decoupled draw, EN property names.
## `world_center/world_size` replace `mundo_centro/mundo_tamanho`;
## `vehicle_path/spots_path/waypoints_path/obstacles_path` replace
## `carro_path/vagas_path/...`. Old properties keep working via base.

var world_center: Vector2:
	get:
		return mundo_centro
	set(value):
		mundo_centro = value
		queue_redraw()

var world_size: Vector2:
	get:
		return mundo_tamanho
	set(value):
		mundo_tamanho = value
		queue_redraw()
