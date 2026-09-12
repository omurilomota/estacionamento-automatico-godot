class_name Obstacle
extends StaticBody2D
## English alias for parked cars / walls / curbs (legacy: Obstaculo.tscn).
##
## No logic — presence on collision_layer 2 is the contract the
## PathPlanner and SensorArray already understand. Exists so new scenes
## can instance `Obstacle` without the PT-BR name leaking further.

func _ready() -> void:
	if collision_layer == 0:
		collision_layer = 2
