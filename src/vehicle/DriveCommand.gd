class_name DriveCommand
extends RefCounted
## Output of a DriverBrain: what the locomotion should do this tick.
## Pure data — no nodes, no physics. Lets brains be unit-tested
## without instantiating the vehicle scene.

var steering: float = 0.0 ## -1..1 (positive = right)
var throttle: float = 0.0 ## -1..1 (positive = forward)


static func make(p_steering: float = 0.0, p_throttle: float = 0.0) -> DriveCommand:
	var cmd := DriveCommand.new()
	cmd.steering = clampf(p_steering, -1.0, 1.0)
	cmd.throttle = clampf(p_throttle, -1.0, 1.0)
	return cmd


static func stop() -> DriveCommand:
	return DriveCommand.make(0.0, 0.0)
