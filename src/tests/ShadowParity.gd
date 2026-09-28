extends SceneTree
## Trajectory-parity harness: runs Fase3 twice and diffs the trajectories.
##
## BASE  (A): legacy FSM, shadow_brains off.
## CTS   (B): ml/testar_ml.gd (already green: ESTACIONADO ~50s).
##
## With steering delegated to PurePursuit.solve_error, both steps run the
## SAME code; the diff now measures harness context + run-to-run jitter
## (threshold 0.15s, the measured same-code jitter band). The shadow flag
## stays off-by-default for the speed/reverse shadow comparisons next.
## Two-step driver (each step fits a ~50s sim):
##   PARITY_MODE=base   godot --headless --path . --script src/tests/ShadowParity.gd
##   PARITY_MODE=shadow godot --headless --path . --script src/tests/ShadowParity.gd
## The shadow step loads the base step's result and prints PARITY OK/DRIFT.
## PARITY_TRAIL=1 runs the trail brain instead (modo_trilha, no ML):
## legacy sequential-streets route following (CTE idiom path).

const LIMITE_SEGUNDOS := 110.0
const RESULT_PATH := "/tmp/parity_base.json"


func _run_fase3(shadow: bool, trail: bool) -> Dictionary:
	var fase = load("res://scenes/fases/Fase3.tscn").instantiate()
	var carro = fase.get_node("Carro")
	if trail:
		carro.modo_ml = false
		carro.modo_trilha = true
		if carro.has_method("start_trail_mode"):
			carro.call("start_trail_mode")
		else:
			carro.iniciar_modo_trilha()
	else:
		if carro.has_method("set_ml_driving"):
			carro.call("set_ml_driving", true)
		else:
			carro.modo_ml = true
	carro.shadow_brains = shadow
	root.add_child(fase)
	await process_frame
	await process_frame
	var park_t: float = -1.0
	var frames := int(LIMITE_SEGUNDOS * 60.0)
	var samples: Array = []
	for i in range(frames):
		await process_frame
		if shadow and carro.has_method("shadow_drift"):
			var drift: Dictionary = carro.call("shadow_drift")
			samples = [drift.get("samples", 0), drift.get("worst", 0.0), drift.get("drifts", 0)]
		var parked_ok: bool = bool(carro.call("is_parked")) if carro.has_method("is_parked") else carro.estado == 3
		if parked_ok:
			park_t = i / 60.0
			break
	root.remove_child(fase)
	fase.queue_free()
	await process_frame
	return {"park_s": park_t, "shadow": samples}


func _init() -> void:
	var trail := OS.get_environment("PARITY_TRAIL") == "1"
	var mode := OS.get_environment("PARITY_MODE")
	if mode == "base":
		var a: Dictionary = await _run_fase3(false, trail)
		var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
		f.store_string(JSON.stringify(a))
		f.close()
		print("PHASE_RESULT mode=base park_s=%s" % str(a.get("park_s")))
		quit(0)
	elif mode == "shadow":
		var base_park: float = -1.0
		if FileAccess.file_exists(RESULT_PATH):
			var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULT_PATH))
			if typeof(data) == TYPE_DICTIONARY:
				base_park = float(data.get("park_s", -1.0))
		var b: Dictionary = await _run_fase3(true, trail)
		var sh: Array = b.get("shadow", [])
		var shadow_park: float = float(b.get("park_s", -2.0))
		print("PHASE_RESULT mode=shadow park_s=%s samples=%s worst=%.4f drifts>0.03=%s" % [
			str(b.get("park_s")), str(sh[0] if sh.size() > 0 else -1),
			sh[1] if sh.size() > 1 else -1.0, str(sh[2] if sh.size() > 2 else -1)])
		# Parity = trajectory identity. Identical code still varies
		# run-to-run (measured: three same-code trail runs spanned
		# 0.10s), so the smoke threshold is 0.15s; real solver drift
		# shows up as seconds. Also requires zero steering drifts
		# beyond the 0.03 threshold.
		var same: bool = absf(base_park - shadow_park) <= 0.15
		print("PARITY %s (base %.2fs vs shadow %.2fs, delta %.2fs)" % [
			"OK" if same else "DRIFT", base_park, shadow_park,
			absf(base_park - shadow_park)])
		print("SHADOW samples=%s worst=%.6f drifts=%s" % [
			str(sh[0] if sh.size() > 0 else -1),
			sh[1] if sh.size() > 1 else -1.0, str(sh[2] if sh.size() > 2 else -1)])
		# Parity = trajectory identity. Parking time quantized at 1/60s:
		# <=2 frames delta is cross-process jitter (same trajectory);
		# real solver drift shows up as seconds. Also requires zero
		# steering drifts beyond the 0.03 threshold.
		var zero_drift: bool = (sh[2] if sh.size() > 2 else 1) == 0
		quit(0 if (same and zero_drift) else 1)
	else:
		print("usage: PARITY_MODE=base|shadow godot --headless --path . --script src/tests/ShadowParity.gd")
		quit(1)