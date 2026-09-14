class_name DriverBrain
extends RefCounted
## Strategy interface for deciding DriveCommands from perception.
## Replaces the `modo_trilha / auto_navegacao / modo_ml` boolean flags
## scattered across Carro.gd — instead of toggling flags, LevelManager
## injects the brain the vehicle should use.

enum Kind { TRAIL, AUTONOMOUS, ML }


func kind() -> int:
	return Kind.TRAIL


func decide(_perception: PerceptionSnapshot, _delta: float) -> DriveCommand:
	return DriveCommand.stop()


func decide_context(_perception: PerceptionSnapshot, _context: DriveContext, _delta: float) -> DriveCommand:
	return decide(_perception, _delta)
