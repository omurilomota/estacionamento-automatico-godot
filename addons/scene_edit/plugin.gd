@tool
extends EditorPlugin
## Scene Edit CLI — mutates .tscn files THROUGH the Godot editor serializer,
## so scene files are never hand-edited (AGENTS.md §2.1).
##
## Why an EditorPlugin and not an EditorScript: running an EditorScript from
## the command line is not supported (godot-proposals #8664 — EditorScript is
## UI-only, "File > Run"). EditorPlugins ARE loaded by the editor on startup,
## so this works headless.
##
## Why not PackedScene.pack() + ResourceSaver.save(): measured on Fase2.tscn,
## that path keeps the nodes but DROPS the scene `uid` and the ext_resource
## uids and flattens instance overrides. Opening the scene in the editor,
## setting the property and calling save_scene() is the same code path the
## inspector uses: uids, instance metadata and canonical formatting survive.
##
## Usage (from the project root):
##   godot --headless --editor --quit --path . -- \
##     --scene=res://scenes/fases/Fase3.tscn \
##     --set="Planejador:inflar=150.0" \
##     --set="Carro:brain_enabled=true" \
##     --set="Carro:vaga_prioritaria=NodePath(../Vagas/Vaga3)" \
##     --set="Vagas/Vaga2:rotacao_alvo=3.14159"
##
## Values: true/false -> bool, int -> int, decimal -> float,
## NodePath(...) -> NodePath, Vector2(x,y) -> Vector2, else String.
## With no --scene/--set arguments the plugin is inert (normal editor start).

const PREFIX := "SCENE_EDIT"


func _enter_tree() -> void:
	var scene_path := ""
	var edits: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scene="):
			scene_path = a.trim_prefix("--scene=")
		elif a.begins_with("--set="):
			edits.append(a.trim_prefix("--set="))
	if scene_path.is_empty() or edits.is_empty():
		return
	_run_edits(scene_path, edits)


func _run_edits(scene_path: String, edits: Array[String]) -> void:
	var failures := 0
	if not ResourceLoader.exists(scene_path):
		print("%s ERROR: scene not found: %s" % [PREFIX, scene_path])
		_shutdown(1)
		return
	EditorInterface.open_scene_from_path(scene_path)
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		print("%s ERROR: could not open scene: %s" % [PREFIX, scene_path])
		_shutdown(1)
		return
	for spec in edits:
		if not _apply(root, spec):
			failures += 1
	if failures == 0:
		var err := EditorInterface.save_scene()
		if err != OK:
			print("%s ERROR: save_scene() failed with error %d" % [PREFIX, err])
			failures += 1
		else:
			print("%s saved %s (%d edits)" % [PREFIX, scene_path, edits.size()])
	print("%s failures=%d" % [PREFIX, failures])
	_shutdown(1 if failures > 0 else 0)


func _apply(root: Node, spec: String) -> bool:
	var colon := spec.find(":")
	if colon <= 0:
		print("%s ERROR: bad --set (expected Node:property=value): %s" % [PREFIX, spec])
		return false
	var node_path := spec.substr(0, colon)
	var rest := spec.substr(colon + 1)
	var eq := rest.find("=")
	if eq <= 0:
		print("%s ERROR: bad --set (missing '='): %s" % [PREFIX, spec])
		return false
	var prop := rest.substr(0, eq)
	var raw := rest.substr(eq + 1)
	var node: Node = root
	if not (node_path.is_empty() or node_path == "."):
		node = root.get_node_or_null(NodePath(node_path))
	if node == null:
		print("%s ERROR: node not found: %s" % [PREFIX, node_path])
		return false
	if not prop in node:
		print("%s ERROR: property '%s' does not exist on %s" % [PREFIX, prop, node_path])
		return false
	node.set(prop, _parse_value(raw))
	print("%s set %s:%s = %s" % [PREFIX, node_path, prop, str(node.get(prop))])
	return true


func _parse_value(raw: String) -> Variant:
	var value := raw.strip_edges()
	if value == "true":
		return true
	if value == "false":
		return false
	if value.begins_with("NodePath(") and value.ends_with(")"):
		return NodePath(value.substr(9, value.length() - 10))
	if value.begins_with("Vector2(") and value.ends_with(")"):
		var parts := value.substr(8, value.length() - 9).split(",")
		if parts.size() == 2:
			return Vector2(parts[0].to_float(), parts[1].to_float())
	if value.is_valid_int():
		return value.to_int()
	if value.is_valid_float():
		return value.to_float()
	return value


func _shutdown(code: int) -> void:
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).quit(code)
