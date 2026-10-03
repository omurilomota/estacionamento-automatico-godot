class_name Tire
extends StaticBody2D
## A small hazard that ROLLS across the lane: a deterministic path-follower
## with a REAL small body (collision_layer 2, circle r=12).
##
## WHY A BODY: a tire is an object to DODGE, not traffic to yield to. The
## static A* grid is built ONCE and never tracks it, so the vehicle reacts
## reactively: the rays (mask 2) see it live, the Locomotion veto cuts the
## accelerator, the Pilot's blocked_ahead -> detour routes around, and the
## legacy escape ladder's replan re-rasterises the grid with the tire at its
## CURRENT position (docs/tasks_trafego.md T2; backlog §1.27).
##
## Deterministic anyway: the body follows an authored path (enter off-scene,
## roll across, leave, pause, return — same cycle as the Crosser), never
## physics. Drawn in _draw() (no texture dependency): a dark ring with a hub.

@export var point_a: Vector2 = Vector2(-600, 0) ## one end of the roll
@export var point_b: Vector2 = Vector2(600, 0) ## the other end
@export var roll_speed: float = 70.0 ## px/s
@export var pause_time: float = 1.5 ## seconds out of sight between passes
@export var spawn_distance: float = 500.0 ## px before point_a it enters from
@export var initial_delay: float = 0.0 ## seconds before the FIRST entry
@export var running: bool = true

const RADIUS := 12.0

var _t: float = 0.0
var _phase: int = 0 ## 0: rolling, 1: out of sight
var _phase_t: float = 0.0
var _entry: Vector2 = Vector2.ZERO


func _ready() -> void:
	collision_layer = 2
	collision_mask = 0
	_entry = _off_scene()
	global_position = _entry
	visible = true
	if initial_delay > 0.0:
		_phase = 1
		_phase_t = -initial_delay


func _process(delta: float) -> void:
	if not running:
		return
	_t += delta
	_phase_t += delta
	match _phase:
		0:
			global_position = _advance(_entry, point_b, delta)
			rotation += roll_speed * delta / RADIUS
			if global_position.distance_to(point_b) < 4.0:
				_next_phase()
		1:
			if _phase_t >= pause_time:
				_next_phase()
	queue_redraw()


## Pure path helper (unit-testable, no tree): position along A->B at time t,
## clamped at B. The next pass is a fresh entry from behind point_a.
static func position_at(a: Vector2, b: Vector2, speed: float, t: float) -> Vector2:
	var length: float = a.distance_to(b)
	if length < 1.0 or speed <= 0.0:
		return a
	return a.lerp(b, minf(1.0, t * speed / length))


func _advance(from_p: Vector2, to_p: Vector2, delta: float) -> Vector2:
	var step: Vector2 = to_p - global_position
	var length: float = step.length()
	if length < 0.001:
		return to_p
	return global_position + step / length * minf(roll_speed * delta, length)


func _next_phase() -> void:
	_phase = (_phase + 1) % 2
	_phase_t = 0.0
	if _phase == 0:
		_entry = _off_scene()
		global_position = _entry
		rotation = 0.0
	visible = _phase == 0


## Where it waits/starts: `spawn_distance` BEHIND point_a, off the camera
## (same rule as `Crosser._off_scene()`).
func _off_scene() -> Vector2:
	var rumo := (point_b - point_a).normalized()
	if rumo == Vector2.ZERO:
		return point_a - Vector2(spawn_distance, 0.0)
	return point_a - rumo * spawn_distance


func _draw() -> void:
	# the tire itself — a dark ring that reads at every zoom
	draw_circle(Vector2.ZERO, RADIUS, Color(0.12, 0.12, 0.13))
	draw_circle(Vector2.ZERO, RADIUS - 4.0, Color(0.05, 0.05, 0.06))
	# hub, rotating with the roll
	var hub: Vector2 = Vector2(RADIUS - 6.0, 0).rotated(rotation)
	draw_circle(hub, 2.6, Color(0.55, 0.55, 0.58))
