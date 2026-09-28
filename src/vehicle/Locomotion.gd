class_name Locomotion
extends RefCounted
## Bicycle-model chassis (reference logic extracted from Carro.gd).
## Ramps steering/speed toward a DriveCommand; the caller (Vehicle)
## applies rotation via yaw_rate() and moves the body itself.
## Safety: refuses forward throttle while perception is blocked.

var max_speed: float = 160.0
var max_steer: float = 0.9
var steer_rate: float = 5.0
var accel_blend: float = 3.0 ## lerp rate speeding up
var brake_blend: float = 6.0 ## lerp rate slowing down
var wheelbase: float = 60.0
var safety_distance: float = 40.0

var speed: float = 0.0
var steering: float = 0.0


func tick(cmd: DriveCommand, perception: PerceptionSnapshot, delta: float) -> void:
	var want_steer: float = clampf(cmd.steering, -1.0, 1.0) * max_steer
	steering = move_toward(steering, want_steer, steer_rate * delta)
	var want_speed: float = clampf(cmd.throttle, -1.0, 1.0) * max_speed
	if want_speed > 0.0 and perception != null and perception.front_blocked(safety_distance):
		want_speed = 0.0
	var blend: float = brake_blend if want_speed < speed else accel_blend
	speed = lerpf(speed, want_speed, clampf(blend * delta, 0.0, 1.0))
	if absf(want_speed) < 0.01 and absf(speed) < 0.5:
		speed = 0.0


## Yaw applied by the caller: rotation += yaw_rate() * delta.
func yaw_rate() -> float:
	if absf(speed) < 1.0:
		return 0.0 # human drivers only turn while moving
	return speed / maxf(wheelbase, 1.0) * tan(steering)


func stop() -> void:
	speed = 0.0
	steering = 0.0


## Unit-style checks for the decoupled reference physics (no scene).
## Same inputs as the legacy FSM idioms — asserts steering ramp, braking
## ramp, safety cut, and reference yaw sign (Locomotion is the SPEC).
static func check() -> Dictionary:
	var report := {"fails": []}
	var loco := Locomotion.new()
	loco.max_speed = 160.0
	var free := PerceptionSnapshot.new()
	loco.tick(DriveCommand.make(1.0, 1.0), free, 0.5)
	if not loco.speed > 0.0:
		(report["fails"] as Array).append("accel")
	if not absf(loco.steering) > 0.0:
		(report["fails"] as Array).append("steer_ramp")
	var yaw: float = loco.yaw_rate()
	if signf(loco.steering) != 0.0 and signf(yaw) != signf(loco.steering):
		(report["fails"] as Array).append("yaw_sign")
	var blocked := PerceptionSnapshot.new()
	blocked.front_center = 10.0
	var guard := Locomotion.new()
	guard.tick(DriveCommand.make(0.0, 1.0), blocked, 0.5)
	if guard.speed != 0.0:
		(report["fails"] as Array).append("safety")
	loco.tick(DriveCommand.stop(), free, 2.0)
	if loco.speed != 0.0:
		(report["fails"] as Array).append("brake")
	return report
