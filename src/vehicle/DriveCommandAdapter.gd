class_name DriveCommandAdapter
extends RefCounted

static func from_pursuit(cmd: PursuitCommand, max_steer: float, max_speed: float) -> DriveCommand:
	var normalized_steer := 0.0
	if absf(max_steer) > 0.0001:
		normalized_steer = cmd.steering / max_steer
	var normalized_speed := 0.0
	if absf(max_speed) > 0.0001:
		normalized_speed = cmd.speed / max_speed
	return DriveCommand.make(normalized_steer, normalized_speed)


static func to_legacy_targets(cmd: DriveCommand, max_steer: float, max_speed: float) -> Dictionary:
	return {
		"steering": clampf(cmd.steering, -1.0, 1.0) * max_steer,
		"speed": clampf(cmd.throttle, -1.0, 1.0) * max_speed,
	}


static func compare(cmd: DriveCommand, legacy_steering: float, legacy_speed: float,
		max_steer: float, max_speed: float) -> Dictionary:
	var targets := to_legacy_targets(cmd, max_steer, max_speed)
	return {
		"steering_diff": absf(float(targets["steering"]) - legacy_steering),
		"speed_diff": absf(float(targets["speed"]) - legacy_speed),
	}
