extends SceneTree
## Headless sanity checks for the decoupled vehicle modules (no scene).
## Run: godot --headless --path . --script src/vehicle/ModulesCheck.gd
## Exits 0 when every check passes, 1 otherwise.

var _fails: int = 0


func _init() -> void:
	var clamped := DriveCommand.make(2.0, -2.0)
	_check("DriveCommand.clamp", clamped.steering == 1.0 and clamped.throttle == -1.0)
	var stopped := DriveCommand.stop()
	_check("DriveCommand.stop", stopped.steering == 0.0 and stopped.throttle == 0.0)

	var blocked := PerceptionSnapshot.new()
	blocked.front_center = 30.0
	_check("Perception.clear->blocked", blocked.front_blocked(40.0))
	var clear := PerceptionSnapshot.new()
	_check("Perception.clear->free", not clear.front_blocked(40.0))
	clear.side_left = 100.0
	_check("Perception.corridor", clear.corridor_width() > 100.0)

	_check("SensorArray.null->INF", SensorArray.distance_of(null) == INF)

	var loco := Locomotion.new()
	_check("Locomotion.yaw_stopped", loco.yaw_rate() == 0.0)
	var free_perception := PerceptionSnapshot.new()
	loco.tick(DriveCommand.make(0.0, 1.0), free_perception, 0.5)
	_check("Locomotion.accelerates", loco.speed > 0.0)
	_check("Locomotion.yaw_moving", loco.yaw_rate() != 0.0 or loco.steering == 0.0)
	var guard := Locomotion.new()
	guard.tick(DriveCommand.make(0.0, 1.0), blocked, 0.5)
	_check("Locomotion.safety_brake", guard.speed == 0.0)

	_check("VehicleState.order", VehicleState.from_legacy_name("ESTACIONADO") == VehicleState.State.PARKED)
	_check("VehicleState.label", VehicleState.label(VehicleState.State.PARKED) == "Parked!")
	_check("LevelRegistry.levels", LevelRegistry.LEVELS.size() == 5)

	var loco_rep: Dictionary = Locomotion.check()
	_check("Locomotion.check", (loco_rep.get("fails", []) as Array).is_empty())

	print("MODULES_CHECK fails=%d" % _fails)
	quit(_fails)


func _check(check_name: String, cond: bool) -> void:
	print(("PASS " if cond else "FAIL ") + check_name)
	if not cond:
		_fails += 1
