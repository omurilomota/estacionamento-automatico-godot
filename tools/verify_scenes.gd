extends SceneTree
## tools/verify_scenes.gd — headless gate for EVERY scene in the project.
## Loads each .tscn, instantiates it, and checks the level contract, so a bad
## edit (hand-made or scripted) fails here instead of in the middle of a run.
##
## Run: godot --headless --path . --script tools/verify_scenes.gd
## Exit code: 0 = all scenes valid, 1 = at least one failure.

const REQUIRED_LEVEL_NODES := ["Mapa", "Obstaculos", "Vagas", "Carro", "Planejador", "Camera", "UI"]
const SCAN_DIRS := ["res://scenes"]


func _init() -> void:
	var paths: Array[String] = []
	for dir in SCAN_DIRS:
		_collect(dir, paths)
	paths.sort()
	var failures := 0
	for path in paths:
		failures += _check_scene(path)
	print("VERIFY_SCENES scenes=%d failures=%d" % [paths.size(), failures])
	quit(1 if failures > 0 else 0)


func _collect(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			_collect(full, out)
		elif name.ends_with(".tscn"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


func _check_scene(path: String) -> int:
	var packed: PackedScene = load(path)
	if packed == null:
		print("VERIFY FAIL %s: does not load" % path)
		return 1
	var root: Node = packed.instantiate()
	if root == null:
		print("VERIFY FAIL %s: cannot instantiate" % path)
		return 1
	var problems: Array[String] = []
	var is_level := root.get_script() != null and _is_level_scene(path)
	if is_level:
		for required in REQUIRED_LEVEL_NODES:
			if root.get_node_or_null(NodePath(required)) == null:
				problems.append("missing node '%s'" % required)
		var carro := root.get_node_or_null("Carro")
		if carro != null:
			# The car must be able to find its planner declaratively.
			var planner_path: NodePath = carro.get("planejador_path")
			if planner_path.is_empty() or carro.get_node_or_null(planner_path) == null:
				problems.append("Carro.planejador_path does not resolve")
			if not "brain_enabled" in carro or not "modo_trilha" in carro:
				problems.append("Carro is missing the mode flags")
		var vagas := root.get_node_or_null("Vagas")
		if vagas != null:
			if vagas.get_child_count() == 0:
				problems.append("no parking spots under Vagas")
			for vaga in vagas.get_children():
				if not "rotacao_alvo" in vaga:
					problems.append("%s has no rotacao_alvo" % vaga.name)
				elif vaga.get_node_or_null("Area") == null:
					problems.append("%s has no Area shape" % vaga.name)
	if problems.is_empty():
		print("VERIFY OK   %s (%s)" % [path, "level" if is_level else "prop"])
		root.free()
		return 0
	print("VERIFY FAIL %s: %s" % [path, ", ".join(problems)])
	root.free()
	return 1


## A level scene is one whose root script is the legacy FaseBase (fases/*).
func _is_level_scene(path: String) -> bool:
	return path.contains("/fases/")
