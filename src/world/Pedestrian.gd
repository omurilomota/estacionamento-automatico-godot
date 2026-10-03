class_name Pedestrian
extends Node2D
## Scripted pedestrian: walks in from off-scene, crosses, waits out of sight
## and comes back — a deterministic path-follower with NO physics body, the
## same design as the `Crosser` (cheap, deterministic, modest-PC friendly).
##
## The vehicle sees it through the group broadcast ("pedestre" ->
## PerceptionSnapshot.pedestrian_distance/bearing) and brains YIELD via the
## pedestrian gate: a pedestrian has PRIORITY and must never be run over
## (docs/tasks_trafego.md T2). Being body-less, the yield decision is the only
## protection — the latch must stay generous.
##
## Drawn in _draw() (no texture dependency): a hi-vis figure that reads as a
## person at every camera zoom, with a subtle bob so it reads as WALKING.

@export var point_a: Vector2 = Vector2(-600, 0) ## one end of the walk
@export var point_b: Vector2 = Vector2(600, 0) ## the other end
@export var walk_speed: float = 55.0 ## px/s — a person, not a runner
@export var pause_time: float = 2.0 ## seconds out of sight between passes
@export var spawn_distance: float = 700.0 ## px before point_a it enters from
@export var initial_delay: float = 0.0 ## seconds before the FIRST entry
## HEAD START: the person begins this far ALONG its path (a person already
## mid-crossing when the scene starts — a parking lot has people in it). The
## walk from a sidewalk takes ~17.8 s to reach an aisle lane, so a crossing
## that must coincide with the car's arrival NEEDS the head start; a negative
## `initial_delay` is just a longer wait, not one.
@export var head_start_px: float = 0.0
@export var running: bool = true

## Collision-free radius the vehicle keeps from the figure (info only — there
## is no body; the gate's enter_distance is what actually protects).
const RADIUS := 14.0

var _t: float = 0.0
var _phase: int = 0 ## 0: walking, 1: out of sight
var _phase_t: float = 0.0
var _entry: Vector2 = Vector2.ZERO


func _ready() -> void:
	add_to_group("pedestre")
	_entry = _off_scene()
	global_position = _entry
	if head_start_px > 0.0:
		var comprimento := point_a.distance_to(point_b)
		if comprimento > 1.0:
			global_position = point_a.lerp(point_b,
				minf(1.0, head_start_px / comprimento))
	rotation = (point_b - point_a).angle()
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
			rotation = (point_b - point_a).angle()
			global_position = _advance(_entry, point_b, delta)
			if global_position.distance_to(point_b) < 4.0:
				_next_phase()
		1:
			if _phase_t >= pause_time:
				_next_phase()
	queue_redraw()


## Pure path helper (unit-testable, no tree): position along A->B at time t,
## clamped at B. There is no reverse trip: the next pass is a fresh entry.
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
	return global_position + step / length * minf(walk_speed * delta, length)


func _next_phase() -> void:
	_phase = (_phase + 1) % 2
	_phase_t = 0.0
	if _phase == 0:
		_entry = _off_scene()
		global_position = _entry
	visible = _phase == 0


## Where it waits/starts: `spawn_distance` BEHIND point_a, on the side it
## comes FROM, always off the camera (same rule as `Crosser._off_scene()`).
func _off_scene() -> Vector2:
	var rumo := (point_b - point_a).normalized()
	if rumo == Vector2.ZERO:
		return point_a - Vector2(spawn_distance, 0.0)
	return point_a - rumo * spawn_distance


func _draw() -> void:
	var bob: float = sin(_t * 9.0) * 2.0 if _phase == 0 else 0.0
	# torso — a hi-vis vest reads as a person at every zoom
	draw_line(Vector2(0, -8 + bob), Vector2(0, 10 + bob),
		Color(0.95, 0.55, 0.05), 11.0)
	# head
	draw_circle(Vector2(0, -16 + bob), 6.0, Color(0.87, 0.72, 0.55))
	# legs
	draw_line(Vector2(0, 10 + bob), Vector2(-4, 20 + bob * 0.5),
		Color(0.2, 0.24, 0.34), 5.0)
	draw_line(Vector2(0, 10 + bob), Vector2(4, 20 - bob * 0.5),
		Color(0.2, 0.24, 0.34), 5.0)
