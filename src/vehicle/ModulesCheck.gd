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

	var aligned := PurePursuit.solve(Vector2.ZERO, 0.0, 1,
		[Vector2.ZERO, Vector2(100, 0)], 0.9)
	_check("PurePursuit.straight", absf(aligned.steering) < 0.05)
	var side := PurePursuit.solve(Vector2(0, 0), 0.0, 1,
		[Vector2(0, 0), Vector2(0, 100)], 0.9)
	_check("PurePursuit.turns_side", side.steering > 0.5 and not side.arrived)
	_check("PurePursuit.curve_slow", PurePursuit.curve_speed(160.0, 0.1, 160.0) < 100.0)
	_check("PurePursuit.fsm_gain", absf(PurePursuit.solve_error(0.3, 0.9, 3.0).steering - 0.9) < 0.001)
	_check("PurePursuit.default_gain", absf(PurePursuit.solve_error(0.3, 0.9).steering - 0.66) < 0.001)
	_check("PurePursuit.halve", absf(PurePursuit.solve_error(0.1, 0.9, 2.2, true).steering - 0.11) < 0.001)

	var rev := TrailFollower.solve_trail(Vector2.ZERO, 0.0, 0,
		[Vector2.ZERO, Vector2(100, 0)], 120.0, 0.0, 500.0, 0.0, 120.0, 0.9)
	_check("Trail.reverse_on_cte", rev.reverse and rev.speed < 0.0)
	var auto_rev := AutonomousDriver.solve_route(Vector2.ZERO, 0.0, 0,
		[Vector2.ZERO, Vector2(100, 0)], 300.0, 0.0, 500.0, 0.0, 160.0, 0.9)
	_check("Auto.reverse_deadend", auto_rev.reverse and auto_rev.speed < 0.0)
	var ml_cmd := MlDriver.map_outputs(0.5, 0.5, 1000.0, 160.0, 160.0)
	_check("Ml.maps_outputs", ml_cmd.steering == 0.5 and ml_cmd.throttle > 0.0)
	var ml_brake := MlDriver.map_outputs(0.0, 1.0, 30.0, 160.0, 160.0)
	_check("Ml.center_brake", ml_brake.throttle == 0.0)
	_check("Ml.stuck", MlDriver.likely_stuck(5.0, 1.0))
	var row := DatasetRecorder.format_row(PackedFloat64Array([0.1, 0.2]), 0.5, 0.25)
	_check("Recorder.cols", row.split(",").size() == 4)
	_check("Recorder.valid", DatasetRecorder.valid_row(PackedFloat64Array([
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])))

	print("MODULES_CHECK fails=%d" % _fails)
	quit(_fails)


func _check(check_name: String, cond: bool) -> void:
	print(("PASS " if cond else "FAIL ") + check_name)
	if not cond:
		_fails += 1
