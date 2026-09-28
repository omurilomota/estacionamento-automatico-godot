class_name DirectionArrow
extends "res://scripts/Seta.gd"
## English facade over legacy `Seta.gd` (flow hint, never blocks).
## `heading` replaces PT-BR `direcao`; `preference/penalty` stay.

var heading: float:
	get:
		return direcao
	set(value):
		direcao = value
		rotation = value
