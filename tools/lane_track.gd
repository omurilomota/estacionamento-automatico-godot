extends SceneTree
## ONDE o carro passou, em x, no boot INTEIRO — sem filtro de corredor e sem
## mediana de punhado. `tools/gate_lane.gd` julga a faixa dentro de corredores
## largos (≥ 1000 px), o que produziu um veredito falso de 9 amostras em
## 2026-10-01 (backlog §1.22). Este gate responde a pergunta mais simples e mais
## honesta: "o carro passou dentro da caixa que o usuario desenhou?".
##
## Uso: godot --headless --path . --script tools/lane_track.gd -- \
##        --fase=Fase2 [--boxx1=832] [--boxx2=1206] [--secs=60]
## Sai != 0 se o carro nunca entrou na caixa (ele tem de usar a via).
##
## O spawn de cada fase e o dela (posicao_aleatoria=false nas fases feitas a
## mao), entao a saida e reproduzivel byte a byte, como a do gate_lane.

var _fase := "Fase2"
var _box := Rect2(832.0, -1.0e9, 374.0, 2.0e9)
var _secs := 60.0


func _init() -> void:
	var x1 := 832.0
	var x2 := 1206.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fase="):
			_fase = a.split("=")[1]
		elif a.begins_with("--secs="):
			_secs = float(a.split("=")[1])
		elif a.begins_with("--boxx1="):
			x1 = float(a.split("=")[1])
		elif a.begins_with("--boxx2="):
			x2 = float(a.split("=")[1])
	_box = Rect2(x1, -1.0e9, x2 - x1, 2.0e9)
	var cena = load("res://scenes/fases/%s.tscn" % _fase).instantiate()
	root.add_child(cena)
	await process_frame
	var carro: Node2D = cena.get_node_or_null("Carro") as Node2D
	if carro == null:
		printerr("LANE_TRACK: sem Carro em " + _fase)
		quit(1)
		return
	await physics_frame
	var t := 0.0
	var xs: Array = []
	var dentro := 0
	while t < _secs:
		await physics_frame
		t += 1.0 / 60.0
		if fmod(t, 0.25) > 0.02:
			continue
		if int(carro.get("estado")) == 3:
			break
		var x: float = carro.global_position.x
		xs.append(x)
		if _box.has_point(carro.global_position):
			dentro += 1
	if xs.is_empty():
		printerr("LANE_TRACK %s: nenhuma amostra" % _fase)
		quit(1)
		return
	xs.sort()
	var pct: float = 100.0 * float(dentro) / float(xs.size())
	print("LANE_TRACK %-6s amostras=%3d x_min=%7.0f x_med=%7.0f x_max=%7.0f dentro_do_box=%5.1f%% (box %.0f..%.0f) t=%.1f" % [
		_fase, xs.size(), xs[0], xs[xs.size() / 2], xs[xs.size() - 1], pct,
		_box.position.x, _box.end.x, t])
	var ok: bool = pct > 0.0
	print("LANE_TRACK_%s" % ("OK" if ok else "NUNCA_ENTROU_NA_FAIXA"))
	quit(0 if ok else 1)
