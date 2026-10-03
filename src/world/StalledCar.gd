class_name StalledCar
extends StaticBody2D
## An ACCIDENT car: drives in from off-scene, STOPS on the driving line and
## stays — the scenario that finally exercises the blocked_ahead -> detour ->
## replan reactive layer (docs/tasks_trafego.md T2; backlog §1.27 asked for a
## scenario with dynamic blocking, and this is it).
##
## A REAL obstacle on purpose (unlike the body-less `Crosser`): a stalled car
## blocks the lane physically, so the vehicle must route AROUND it. The static
## A* grid is built once (the car is at its entry, off the lane), so the
## escape ladder's replan — which re-rasterises the grid with the stalled car
## at its CURRENT position — and the Pilot's detour are the ways out.
##
## Deterministic: the body follows an authored path (drive in, stop at
## `stall_after_px` past point_a, stay forever with a hazard pulse), never
## physics. The art faces -Y and the CHILD carries `rotation = 1.5708`
## (AGENTS #29), so the node rotation IS the world heading and the car never
## drives sideways; the collision box (190x88) has its long axis on node X,
## the facing axis, so a stalled car reads exactly like a parked car turned
## to its heading.

@export var point_a: Vector2 = Vector2(-600, 0) ## off-scene entry end
@export var point_b: Vector2 = Vector2(600, 0) ## direction of travel
@export var drive_speed: float = 140.0 ## px/s until the stall
## How far PAST point_a the car stops (the stall point, ON the driving line).
## Authoring this is what decides WHERE the accident happens.
@export var stall_after_px: float = 600.0
@export var spawn_distance: float = 700.0 ## px before point_a it enters from
@export var initial_delay: float = 0.0 ## seconds before the car enters
@export var running: bool = true

const HALF_LONG := 95.0
const HALF_WIDE := 44.0

var _t: float = 0.0
var _stalled: bool = false
var _entry: Vector2 = Vector2.ZERO


func _ready() -> void:
	collision_layer = 2
	collision_mask = 0
	# the body IS the contract: a car-sized box (190x88 node-space, long axis
	# on node X = the facing axis) the rays see and the mover bumps into.
	# Built here because the generator emits the actor as script + params.
	var forma := CollisionShape2D.new()
	var retangulo := RectangleShape2D.new()
	retangulo.size = Vector2(HALF_LONG * 2.0, HALF_WIDE * 2.0)
	forma.shape = retangulo
	forma.name = "Colisao"
	add_child(forma)
	_entry = _off_scene()
	global_position = _entry
	rotation = (point_b - point_a).angle()
	visible = true


func _process(delta: float) -> void:
	if not running:
		return
	_t += delta
	if not _stalled:
		rotation = (point_b - point_a).angle()
		var step: Vector2 = point_b - global_position
		var length: float = step.length()
		if length > 0.001:
			global_position += step / length * minf(drive_speed * delta, length)
		# the stall: `stall_after_px` past point_a, ON the driving line
		if (global_position - point_a).length() >= stall_after_px \
				or global_position.distance_to(point_b) < 4.0:
			_stalled = true
	else:
		# hazard pulse — a stalled car reads as a broken-down car
		var s := get_child(0) as Sprite2D if get_child_count() > 0 else null
		if s != null:
			s.modulate.a = 0.72 + 0.28 * absf(sin(_t * 5.0))


## Pure path helper (unit-testable, no tree): position along A->B at time t,
## clamped at the STALL point — once stalled, the car never moves again.
static func position_at(a: Vector2, b: Vector2, speed: float,
		stall_after: float, t: float) -> Vector2:
	var length: float = a.distance_to(b)
	if length < 1.0 or speed <= 0.0:
		return a
	var stall_len: float = minf(stall_after, length)
	var travel: float = minf(t * speed, stall_len)
	return a.lerp(b, travel / length)


func _off_scene() -> Vector2:
	var rumo := (point_b - point_a).normalized()
	if rumo == Vector2.ZERO:
		return point_a - Vector2(spawn_distance, 0.0)
	return point_a - rumo * spawn_distance
