class_name DebugRoutePanel
extends "res://scripts/ControleRotas.gd"
## English facade over legacy ControleRotas (debug checkboxes).
## Removes the `../../../Planejador` coupling for NEW scenes: assign
## `planner_node`, `routes_node`, `vehicle_node` in the inspector.
## Legacy scenes keep working through the base class paths.
