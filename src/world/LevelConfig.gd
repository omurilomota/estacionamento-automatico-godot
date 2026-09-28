class_name LevelConfig
extends Resource
## Per-level data (replaces hand-edited FaseN.tscn overrides).
##
## GOAL: a single `Level.tscn` template + one LevelConfig per level,
## instead of copying UI/camera/planner/vehicle overrides into 5 scenes.
## Legacy PT-BR fields (`mapa`, `escala_mapa`, `zoom_camera`,
## `posicao_aleatoria`) stay on FaseBase; new levels fill THIS resource.

@export var map_texture: Texture2D = null
@export var map_scale: float = 1.5
@export var camera_zoom: float = 0.8
@export var random_spawn: bool = true
@export var display_name: String = "Level"
