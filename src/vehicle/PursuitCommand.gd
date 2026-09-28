class_name PursuitCommand
extends RefCounted
## Pure-pursuit output for ONE tick (no nodes, no physics).
## Extracted from Carro._processar_rota / _processar_trilha so brains are
## unit-testable. Angles in radians, speeds in px/s.

var steering: float = 0.0 ## -max_steer..max_steer
var speed: float = 0.0
var reverse: bool = false
var arrived: bool = false
var lookahead_index: int = 0
