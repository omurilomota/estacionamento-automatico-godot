extends SceneTree
## Headless sanity checks for the decoupled vehicle modules (no scene).
## Run: godot --headless --path . --script src/vehicle/ModulesCheck.gd
## Exits 0 when every check passes, 1 otherwise.
##
## The FAROL layer is asserted here too: those modules are pure and take no
## scene tree, so this is where their contract is pinned (see the FAROL block).

const MooringRef = preload("res://src/farol/Mooring.gd")
const FarolSpecRef = preload("res://src/farol/FarolSpec.gd")
const FarolShieldRef = preload("res://src/farol/FarolShield.gd")
const LocalMapRef = preload("res://src/farol/LocalMap.gd")

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
	# The registry owns BOTH lists and the HUD level-select reads them by index,
	# so the invariant is the ALIGNMENT, not a count: a hardcoded `== 5` went
	# stale (and failed) the moment Fase6..Fase9 were added.
	_check("LevelRegistry.levels", LevelRegistry.LEVELS.size() >= 5 \
			and LevelRegistry.LEVELS.size() == LevelRegistry.LEVEL_NAMES.size())
	_check("LevelRegistry.level_names", not str(LevelRegistry.LEVEL_NAMES[0]).is_empty())
	# One table, three payload shapes: legacy PT-BR name, VehicleState int and
	# the English display label must all land on the same PT-BR HUD text.
	_check("LevelRegistry.state_key_int", LevelRegistry.state_key(3) == "ESTACIONADO")
	_check("LevelRegistry.state_key_legacy", LevelRegistry.state_key("ALINHANDO") == "ALINHANDO")
	_check("LevelRegistry.state_key_label", LevelRegistry.state_key("Parked!") == "ESTACIONADO")
	_check("LevelRegistry.state_text", LevelRegistry.state_text("BUSCANDO") == "Procurando vaga")
	_check("LevelRegistry.state_color", LevelRegistry.state_color(3).g > 0.8)

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
	var snapped := SensorArray.snapshot_full({}, 0.0, 100.0, 0.2, 0.1, INF, 0.0, 0.0)
	_check("Snapshot.v2_yaw", absf(snapped.yaw_error - 0.1) < 0.0001)
	var cross := PerceptionSnapshot.new()
	cross.crosser_distance = 120.0
	cross.crosser_bearing = 0.1
	_check("Snapshot.crosser", cross.crosser_ahead(220.0))
	_check("Snapshot.no_crosser", not snapped.crosser_ahead(220.0))
	var auto := AutonomousDriver.new()
	_check("Auto.yields_crosser", auto.decide(cross, 0.016).throttle == 0.0)
	# C2: the gate is a LATCH, so a crosser that sits just outside the old bare
	# threshold must not release the car (that was the creep-through).
	var auto_gate := AutonomousDriver.new()
	_check("Gate.latches_at_threshold", auto_gate.gate().should_yield(120.0, 0.1, 0.016))
	_check("Gate.holds_outside_enter", auto_gate.gate().should_yield(260.0, 0.1, 0.016))
	_check("Gate.holds_past_exit_before_hold", auto_gate.gate().should_yield(900.0, 0.1, 0.016))
	_check("Gate.releases_past_exit", _releases_when(900.0, 400.0))
	_check("Gate.clears_on_missing_crosser",
		not auto_gate.gate().should_yield(INF, 0.0, 0.016))
	var straight: Array = [Vector2.ZERO, Vector2(100, 0)]
	_check("Auto.yaw_aligned", absf(AutonomousDriver.yaw_penalty(
		straight, Vector2.RIGHT.angle())) < 1.0)
	_check("Auto.yaw_rejects_reverse", AutonomousDriver.yaw_penalty(
		straight, Vector2.LEFT.angle()) == INF)
	# F3 lock: a stopped car ON the route must still be commanded to accelerate.
	var ctx := DriveContext.new()
	ctx.route = [Vector2.ZERO, Vector2(600, 0)]
	ctx.cte = 5.0
	var free_p := PerceptionSnapshot.new()
	var moving: DriveCommand = AutonomousDriver.new().decide_context(free_p, ctx, 0.016)
	_check("Auto.accelerates_from_stop", moving.throttle > 0.2)
	var row := DatasetRecorder.format_row(PackedFloat64Array([0.1, 0.2]), 0.5, 0.25)
	_check("Recorder.cols", row.split(",").size() == 4)
	# v1 rows (18 feats) are legacy training files, not live recorder output.
	_check("Recorder.v1_legacy", not DatasetRecorder.valid_row(PackedFloat64Array([
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
		and DatasetRecorder.is_v1_row(PackedFloat64Array([
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
	_check("Recorder.v2", DatasetRecorder.valid_row(PackedFloat64Array([
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
	_check("Recorder.v1_row", DatasetRecorder.is_v1_row(PackedFloat64Array([
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
	var c0: Vector2 = Crosser.position_at(Vector2(-600, 0), Vector2(600, 0), 120.0, 0.0)
	_check("Crosser.at_a", c0.distance_to(Vector2(-600, 0)) < 0.01)
	# t=5s @120px/s over a 1200px span = midpoint (x=0); t=16s = parked at B, it
	# never reverses on the lane (the next pass re-enters from the west).
	var c5: Vector2 = Crosser.position_at(Vector2(-600, 0), Vector2(600, 0), 120.0, 5.0)
	_check("Crosser.moves", c5.x > -600.0 and c5.x < 600.0)
	var c16: Vector2 = Crosser.position_at(Vector2(-600, 0), Vector2(600, 0), 120.0, 16.0)
	_check("Crosser.never_reverses", c16.distance_to(Vector2(600, 0)) < 0.01)

	# CrosserGate (C1/C2): pure hysteresis latch, no scene tree.
	var gate := CrosserGate.new()
	_check("Gate.idle_no_crosser", not gate.should_yield(INF, 0.0, 0.016))
	_check("Gate.enters", gate.should_yield(150.0, 0.2, 0.016))
	_check("Gate.hysteresis_keeps", gate.should_yield(300.0, 0.2, 0.016))
	# Past the exit distance but still inside min_hold: must KEEP yielding.
	_check("Gate.min_hold_blocks_release", gate.should_yield(400.0, 0.2, 0.2))
	var waited := 0.0
	while gate.should_yield(400.0, 0.2, 0.1):
		waited += 0.1
		if waited > 5.0:
			break
	_check("Gate.releases_after_hold", waited > 0.5 and not gate.is_latched())
	_check("Gate.free_after_release", not gate.should_yield(400.0, 0.2, 0.016))
	_check("Gate.releases_on_beside", _gate_free_after_hold(0.0, 1.5))
	var beside := CrosserGate.new()
	_check("Gate.ignores_behind", not beside.should_yield(100.0, PI, 0.016))
	beside.should_yield(100.0, 0.0, 0.016)
	_check("Gate.releases_on_beside_close", not beside.should_yield(100.0, 1.5, 2.0))
	beside.reset()
	_check("Gate.reset", not beside.is_latched())
	_check("Gate.no_crosser_clears", not _latched_then_lost(150.0))

	# LaneOffset: right-hand traffic (mão à direita). A straight eastbound route
	# must shift SOUTH (+y in screen coords = the driver's right) and never past
	# the requested offset; the ends stay on the planner's line so the parking
	# approach is not dragged sideways.
	var lane_route: Array = [Vector2(0, 0), Vector2(200, 0), Vector2(400, 0), Vector2(600, 0)]
	var open_probe := func(_p: Vector2, _r: Vector2) -> float: return 10000.0
	var lane: Array = LaneOffset.apply(lane_route, 110.0, open_probe, 120.0, 200.0, 200.0)
	_check("Lane.shifts_right", lane[1].y > 0.0 and lane[2].y > 0.0)
	_check("Lane.caps_at_desired", lane[1].y <= 110.0 + 0.001 and lane[2].y <= 110.0 + 0.001)
	_check("Lane.fades_at_ends", lane[0].is_equal_approx(lane_route[0])
		and lane[3].is_equal_approx(lane_route[3]))
	var wall_probe_none := func(_p: Vector2, _r: Vector2) -> float: return 0.0
	var tight: Array = LaneOffset.apply(lane_route, 110.0, wall_probe_none, 120.0, 200.0, 200.0)
	_check("Lane.no_slack_no_shift", tight.size() == lane_route.size()
		and (tight[1] as Vector2).is_equal_approx(lane_route[1])
		and (tight[2] as Vector2).is_equal_approx(lane_route[2]))
	var half_probe := func(_p: Vector2, _r: Vector2) -> float: return 300.0
	var half: Array = LaneOffset.apply(lane_route, 110.0, half_probe, 120.0, 200.0, 200.0)
	_check("Lane.caps_desired_not_slack", (half[2] as Vector2).y <= 110.0 + 0.001)
	# RULE (2026-09-26): the lane is the strip against the RIGHT WALL,
	# shift = free_r - keep_clear * (1 + LANE_EDGE_MARGIN 0.7), capped at
	# 2.2 swept radii. Above 6 radii with no wall on the right there IS no
	# right edge (open space) and the proportional bias takes over.
	# O esperado e DERIVADO da regra (fr - keep_clear*(1+margem)), nao chumbado:
	# medir a margem e mexer no codigo quebrava o teste toda vez.
	var f: float = 1.0 + LaneOffset.LANE_EDGE_MARGIN
	var asym := func(_p: Vector2, r: Vector2) -> float: return 350.0 if r.y > 0.0 else 650.0
	var right_edge: Array = LaneOffset.apply(lane_route, 1000.0, asym, 100.0, 0.0, 0.0)
	_check("Lane.right_edge", absf((right_edge[2] as Vector2).y - (350.0 - 100.0 * f)) < 0.001)
	_check("Lane.right_edge_keeps_floor",
		350.0 - (right_edge[2] as Vector2).y >= 100.0 - 0.001)
	# Right side too tight to host the lane (200 < 1.7 * 120): no shift at all,
	# which is the SAFE direction (the car stays on the planner's line).
	var left_heavy := func(_p: Vector2, r: Vector2) -> float: return 200.0 if r.y > 0.0 else 2000.0
	var left_heavy_route: Array = LaneOffset.apply(lane_route, 1000.0, left_heavy, 120.0, 0.0, 0.0)
	_check("Lane.tight_right_tight_shift",
		absf((left_heavy_route[2] as Vector2).y - (200.0 - 120.0 * f)) < 0.001)
	# The lane is at most 2.2 swept radii wide: without the cap, an open right
	# side (the probe returns its own reach) dragged the route out of the
	# corridor by ~900 px.
	var reta: Array = [Vector2(0, 0), Vector2(200, 0), Vector2(400, 0),
		Vector2(600, 0), Vector2(800, 0), Vector2(1000, 0)]
	var aberto := func(_p: Vector2, r: Vector2) -> float: return 2600.0 if r.y > 0.0 else 500.0
	var aberto_route: Array = LaneOffset.apply(reta, 1000.0, aberto, 120.0, 0.0, 0.0)
	_check("Lane.caps_lane_width",
		(aberto_route[3] as Vector2).y <= 120.0 * 6.0 + 0.001)
	# A one-sided probe (0 on the left) is read as SYMMETRIC: free_r 400,
	# free_l mirrored to 400 -> 400 - 100*(1+0.7) = 230.
	var one_sided := func(_p: Vector2, r: Vector2) -> float: return 400.0 if r.y > 0.0 else 0.0
	var one_route: Array = LaneOffset.apply(reta, 1000.0, one_sided, 100.0, 0.0, 0.0)
	_check("Lane.one_sided_fallback",
		absf((one_route[3] as Vector2).y - (400.0 - 100.0 * f)) < 0.001)
	# keep_clear floor: 400 to the right, 100 to the left, keep_clear 120 ->
	# shift 196 and the point still has 204 px of clearance on the right.
	var narrow := func(_p: Vector2, r: Vector2) -> float: return 400.0 if r.y > 0.0 else 100.0
	var narrow_route: Array = LaneOffset.apply(lane_route, 1000.0, narrow, 120.0, 0.0, 0.0)
	_check("Lane.floor_keeps_clear", 400.0 - (narrow_route[2] as Vector2).y >= 120.0 - 0.001)
	_check("Lane.floor_swept_radius", 400.0 - (narrow_route[2] as Vector2).y >= 120.0)
	var lane_off: Array = LaneOffset.apply(lane_route, 0.0, open_probe, 120.0, 200.0, 200.0)
	_check("Lane.zero_desired", lane_off[2].is_equal_approx(lane_route[2]))
	var lane_short: Array = LaneOffset.apply([Vector2.ZERO, Vector2(100, 0)], 110.0, open_probe, 120.0)
	_check("Lane.short_route_untouched", lane_short.size() == 2)
	# Ordinary 90 deg corners travel with the shift (the whole corner is
	# translated); a near-reversal (parking manoeuvre) must stay exactly put.
	var bent: Array = [Vector2(-600, 0), Vector2(-300, 0), Vector2(0, 0),
		Vector2(0, 300), Vector2(0, 600)]
	var bent_shifted: Array = LaneOffset.apply(bent, 110.0, open_probe, 120.0, 0.0, 0.0)
	_check("Lane.corner_shifted", bent_shifted[2].distance_to(bent[2]) > 100.0)
	var hairpin: Array = [Vector2(0, 0), Vector2(400, 0), Vector2(0, 0.5)]
	var hairpin_shifted: Array = LaneOffset.apply(hairpin, 110.0, open_probe, 120.0, 0.0, 0.0)
	_check("Lane.hairpin_holds", hairpin_shifted[1].is_equal_approx(hairpin[1]))
	_check("Lane.wall_probe_invalid", not LaneOffset.wall_probe(null).is_valid())

	# ---------------------------------------------------------------- FAROL ----
	# The five FAROL layers are pure and headless (AGENTS §3), so they are
	# asserted here with no scene. `farol_mode` is 0 in every scene today, so a
	# failure here means the SHADOW code is already wrong — the cheapest moment
	# to find out, before a level is promoted.
	MooringRef.usar(FarolSpecRef.new())
	# Shield (NERVO): the pupil may choose, the teacher may veto, a veto is about
	# collision and never about taste.
	var shield_rep: Dictionary = FarolShieldRef.check()
	_check("Shield.check", (shield_rep.get("fails", []) as Array).is_empty())
	# Mooring (ATRACAÇÃO): the phase sequence must be ALIGN -> ARC -> SLIDE and
	# monotone, because the legacy cascade re-decided every frame and the phases
	# oscillated (see src/farol/Mooring.gd).
	# The hull is 88x74 at the level scales; use a 690x314 bay (Fase2) and a
	# 162x439 one (Fase8, the tightest) — AGENTS #27: the BAY is the free
	# variable and the Mooring has to fit the ones that exist.
	var meia := Vector2(79.2, 49.6)
	var centro := Vector2.ZERO
	var spec: FarolSpecRef = FarolSpecRef.new()
	# (1) On the approach, aligned, still short -> ARC (drive in, no turning).
	var p_arc: Dictionary = MooringRef.passo(centro - Vector2(160, 0), 0.0, centro, 0.0, meia)
	_check("Mooring.arc_on_approach", int(p_arc["fase"]) == MooringRef.Fase.ARCO)
	# (2) REGRESSION: the same pose with 0.5 rad of yaw error must ALIGN. The
	# first version gated ALIGN on `ao_longo < 0.0`, which IS the approach (the
	# preparation point is `centro - nariz*alcance`), so this returned ARC and
	# the squaring-up phase was dead exactly where it was needed.
	var p_alinhar: Dictionary = MooringRef.passo(centro - Vector2(160, 0), 0.5, centro, 0.0, meia)
	_check("Mooring.aligns_when_twisted", int(p_alinhar["fase"]) == MooringRef.Fase.ALINHAR)
	# (3) REGRESSION: twisted INSIDE the bay, 13 px from the centre — the
	# AGENTS #38 case that turns ALIGNING into eternal parking — must also
	# ALIGN, and only then slide.
	var p_dentro: Dictionary = MooringRef.passo(centro - Vector2(13, 0), 1.2, centro, 0.0, meia)
	_check("Mooring.aligns_inside_bay", int(p_dentro["fase"]) == MooringRef.Fase.ALINHAR)
	# (4) The ALIGN aim point must be AHEAD of the hull, never behind it: a
	# target behind the car makes the pursuit steer the nose the wrong way.
	var t_alinhar: Vector2 = p_alinhar["target"]
	var carro_alinhar := Vector2(-160, 0)
	_check("Mooring.align_target_ahead",
		t_alinhar.dot(MooringRef.nariz(centro, 0.0)) > carro_alinhar.dot(MooringRef.nariz(centro, 0.0)))
	# (5) Aligned and on the centre -> SLIDE (the last 12 px, AGENTS #16).
	var p_slide: Dictionary = MooringRef.passo(centro - Vector2(10, 0), 0.0, centro, 0.0, meia)
	_check("Mooring.slides_at_centre", int(p_slide["fase"]) == MooringRef.Fase.DESLIZAR)
	# (6) A nose-WEST bay (rot_alvo = PI, how Fase2/Fase3 are really authored,
	# AGENTS #15) must be geometrically identical to the nose-east one, or the
	# arrival error is ~PI and the car reverses out (the AGENTS #15c defect).
	var p_oeste: Dictionary = MooringRef.passo(Vector2(160, 0), PI, centro, PI, meia)
	_check("Mooring.nose_west_same_phase", int(p_oeste["fase"]) == int(p_arc["fase"]))
	# (7) ALIGN must creep, never freeze: the Locomotion refuses to yaw below
	# 1 px/s, so a zero throttle would burn ALINHA_MAX_S and end in eternal
	# parking (the exact failure AGENTS #38 describes).
	var c_alinhar: Dictionary = MooringRef.comando(carro_alinhar, 0.5, centro, 0.0, meia, 160.0)
	_check("Mooring.align_creeps",
		float((c_alinhar["comando"] as DriveCommand).throttle) > 0.0)
	# (8) The tightest real bay must not change the decision: a 162x439 bay has
	# the car 1.60x longer than it is wide, so the arc threshold is the only
	# thing that could differ.
	var meia_estreita := Vector2(81.0, 49.6)
	var p_estreita: Dictionary = MooringRef.passo(centro - Vector2(160, 0), 0.0, centro, 0.0, meia_estreita)
	_check("Mooring.tight_bay_arc", int(p_estreita["fase"]) == MooringRef.Fase.ARCO)
	# (9) A DIAGONAL bay (yaw 0.7 rad) — no level has one today, so the Mooring
	# has never been asked to square up against a rotated aisle.
	var p_diag: Dictionary = MooringRef.passo(centro - Vector2(160, 0).rotated(0.7),
		0.7 + 0.4, centro, 0.7, meia)
	_check("Mooring.diagonal_aligns", int(p_diag["fase"]) == MooringRef.Fase.ALINHAR)
	# (10) The spec must actually reach the Mooring: `usar()` is what the vehicle
	# calls every frame, and without it a scene's `farol_spec` was ignored here.
	MooringRef.usar(spec)
	spec.atracar_yaw_tol = 0.9   # absurdly loose
	_check("Mooring.spec_is_used",
		int(MooringRef.passo(carro_alinhar, 0.5, centro, 0.0, meia)["fase"]) != MooringRef.Fase.ALINHAR)
	MooringRef.usar(FarolSpecRef.new())

	# REGRESSION (Fase9, 2026-09-29): a ray that hits NOTHING used to paint a
	# solid cell at its own MAXIMUM RANGE, because the contact cell was marked
	# unconditionally. With 19 rays that rings an empty aisle with 19 phantom
	# walls; the shield then vetoed every frame and the car stood still for 41 s.
	#
	# The rule lives in `_tracar_rastro`, and it has to be called DIRECTLY: an
	# earlier version of this check passed `{}` as the ray dictionary, which
	# never enters the loop and therefore proved nothing — reintroducing the bug
	# left the suite green. `_tracar_rastro` IS the unit under test here, and
	# ModulesCheck is in-repo, so calling it is the honest way to pin it.
	var lm := LocalMapRef.de_teste(8, 20.0)
	# An unobstructed beam: free to the end, and NO solid cell at its range.
	lm._tracar_rastro(Vector2.ZERO, 150.0, 0.0, false)
	_check("LocalMap.no_phantom_wall",
		lm.custo_em(Vector2(140.0, 0.0)) == LocalMapRef.LIVRE)
	_check("LocalMap.unhit_ray_marks_nothing", lm.celulas_ocupadas == 0)
	# A beam that REPORTED a contact ends solid, with the short shadow behind it
	# — the rule the fix must not have broken.
	lm._tracar_rastro(Vector2.ZERO, 100.0, 0.0, true)
	_check("LocalMap.hit_ray_marks_wall",
		lm.custo_em(Vector2(100.0, 0.0)) >= 0.99)
	_check("LocalMap.hit_ray_shadow",
		lm.custo_em(Vector2(120.0, 0.0)) > 0.0)
	# A cell OUTSIDE the window is unknown space, and reading it as solid is the
	# safe direction (the shield must not read past what the car can see).
	_check("LocalMap.outside_is_solid",
		lm.custo_em(Vector2(100000.0, 0.0)) == LocalMapRef.OBSTACULO)

	# Car menu (D1): 10 skins from TWO art families with different pixel sizes
	# (Kenney 70x121 full-bleed, assets/sprites 100x100 trimmed). The contract
	# that keeps the 88x74 collision box valid is no longer "same texture size"
	# but "same DRAWN box": region.size * sprite_scale == TARGET * 1.62, i.e.
	# every skin is drawn 113.4 x 196.0 px. Assert exactly that.
	var want_box := VehicleCatalog.TARGET * VehicleCatalog.SPRITE_BASE_SCALE
	_check("Catalog.ten_skins", VehicleCatalog.CARS.size() == 10)
	_check("Catalog.unique_ids", VehicleCatalog.ids().size() == VehicleCatalog.CARS.size())
	var all_load := true
	var labelled := true
	var normalized := true
	for id in VehicleCatalog.ids():
		var tex := VehicleCatalog.texture_for(id)
		if tex == null:
			all_load = false
			continue
		if VehicleCatalog.label_for(id).is_empty():
			labelled = false
		var region := VehicleCatalog.region_for(id)
		# region must be a real sub-rect of THIS texture
		var sz: Vector2i = tex.get_size()
		if region.size.x <= 0 or region.size.y <= 0 \
				or region.position.x < 0 or region.position.y < 0 \
				or region.end.x > sz.x or region.end.y > sz.y:
			normalized = false
			continue
		var drawn: Vector2 = Vector2(region.size) * VehicleCatalog.sprite_scale_for(id)
		if absf(drawn.x - want_box.x) > 0.05 or absf(drawn.y - want_box.y) > 0.05:
			normalized = false
	_check("Catalog.textures_load", all_load)
	_check("Catalog.labels_pt_br", labelled)
	_check("Catalog.same_drawn_box", normalized)
	_check("Catalog.kenney_scale_unchanged",
		VehicleCatalog.sprite_scale_for("blue") == Vector2(1.62, 1.62))
	_check("Catalog.clean_car_uses_whole_texture",
		VehicleCatalog.region_for("blue") == Rect2i(0, 0, 70, 121))
	_check("Catalog.trimmed_car_uses_subrect",
		VehicleCatalog.region_for("sedan") == Rect2i(31, 21, 38, 65))
	_check("Catalog.cycle_wraps", VehicleCatalog.id_at(VehicleCatalog.index_of("classic") + 1) == "blue")
	_check("Catalog.unknown_id_empty", VehicleCatalog.path_for("fusca") == "")
	var carro_scene: PackedScene = load("res://scenes/Carro.tscn")
	var carro_node: Node = carro_scene.instantiate() if carro_scene != null else null
	if carro_node == null:
		_check("Catalog.apply", false)
	else:
		var sprite := carro_node.get_node("Sprite2D") as Sprite2D
		var before: Texture2D = sprite.texture
		_check("Catalog.apply_red", VehicleCatalog.apply(carro_node, "red"))
		var after: Texture2D = sprite.texture
		_check("Catalog.texture_swapped", after != before and after != null)
		_check("Catalog.apply_trimmed_skin", VehicleCatalog.apply(carro_node, "sedan"))
		_check("Catalog.sedan_region_applied",
			sprite.region_enabled and sprite.region_rect == Rect2(Rect2i(31, 21, 38, 65)))
		_check("Catalog.sedan_scaled_up", sprite.scale.x > 2.0)
		_check("Catalog.apply_unknown", not VehicleCatalog.apply(carro_node, "fusca"))
		_check("Catalog.sprite_path_used", str(carro_node.get("sprite_path")) == "Sprite2D")
		carro_node.free()
	VehicleCatalog.current_id = VehicleCatalog.DEFAULT_ID

	print("MODULES_CHECK fails=%d" % _fails)
	quit(_fails)


## Latches, then lets a crosser sitting at the edge go: the release must
## happen once the hold expires even though the distance never grew.
func _gate_free_after_hold(enter_bearing: float, exit_bearing: float) -> bool:
	var g := CrosserGate.new()
	if not g.should_yield(100.0, enter_bearing, 0.016):
		return true
	for _i in range(200):
		if not g.should_yield(100.0, exit_bearing, 0.1):
			return true
	return false


## Latches at `inside_dist` and then asks at `outside_dist` every frame: the
## gate must eventually let go (hysteresis is a delay, not a deadlock).
func _releases_when(inside_dist: float, outside_dist: float) -> bool:
	var g := CrosserGate.new()
	if not g.should_yield(inside_dist, 0.1, 0.016):
		return true
	for _i in range(200):
		if not g.should_yield(outside_dist, 0.1, 0.1):
			return true
	return false


func _latched_then_lost(distance: float) -> bool:
	var g := CrosserGate.new()
	g.should_yield(distance, 0.1, 0.016)
	return g.should_yield(INF, 0.0, 0.016)




func _check(check_name: String, cond: bool) -> void:
	print(("PASS " if cond else "FAIL ") + check_name)
	if not cond:
		_fails += 1

