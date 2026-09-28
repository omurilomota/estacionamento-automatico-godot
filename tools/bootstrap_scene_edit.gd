extends SceneTree
## tools/bootstrap_scene_edit.gd — enables the "Scene Edit CLI" plugin through
## the ProjectSettings API (idempotent). project.godot is written by Godot, not
## by hand. Run once after cloning:
##   godot --headless --path . --script tools/bootstrap_scene_edit.gd

const PLUGIN := "res://addons/scene_edit/plugin.cfg"


func _init() -> void:
	var enabled: PackedStringArray = ProjectSettings.get_setting(
		"editor_plugins/enabled", PackedStringArray())
	if PLUGIN in enabled:
		print("BOOTSTRAP already enabled: %s" % PLUGIN)
		quit(0)
		return
	enabled.append(PLUGIN)
	ProjectSettings.set_setting("editor_plugins/enabled", enabled)
	var err := ProjectSettings.save()
	print("BOOTSTRAP enabled %s (save err=%d)" % [PLUGIN, err])
	quit(0 if err == OK else 1)
