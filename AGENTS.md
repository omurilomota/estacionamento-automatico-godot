# AGENTS.md — Autonomous Parking (Godot 4.x)

> Instructions for AI coding agents working in this repo. The user speaks
> PT-BR; code and docs are ENGLISH (see §1). Legacy PT-BR code lives in
> `scripts/` + `ml/*.gd`; new decoupled code lives in `src/`.

## 1. Language rule

- **New code: English only** — file names, `class_name`, signals, methods,
  exports, comments. (`Vehicle`, `ParkingSpot`, `PathPlanner`, `LevelManager`…)
- **Legacy code stays PT-BR until its module is migrated** — `Carro`,
  `Vaga`, `Planejador`, `FaseBase`, `Mundo`, `rotacao_alvo`,
  `posicao_aleatoria`, `escala_mapa`, `BUSCANDO/DESVIANDO/ALINHANDO/
  ESTACIONADO/RECUPERANDO`. Do NOT rename legacy symbols in place; instead
  add an English facade in `src/` that `extends` the legacy script
  (see §3) and migrate call sites gradually.
- Docs (`README.md`, `FASE.md`, `ml/README.md`) are already in English.

## 2. Project map

```
project.godot            # main scene: res://scenes/Mundo.tscn, Godot 4.7, GL Compatibility
scenes/
  Mundo.tscn             # legacy demo scene (floor, walls, UI, vehicle)
  Carro.tscn             # legacy vehicle: CharacterBody2D + 12x RayCast2D
  Vaga.tscn              # legacy parking spot: Area2D + Boca (mouth) Area2D
  Obstaculo.tscn         # StaticBody2D obstacle (collision_layer = 2)
  Seta.tscn              # legacy flow hint arrow (layer 8, never blocks)
  fases/Fase1..5.tscn    # legacy level scenes (Fase5.tscn is 32KB vs ~7KB others — diverged, be careful)
scripts/                 # LEGACY PT-BR (Carro.gd 2200+ lines = god object, FaseBase, Mundo, Planejador…)
src/                     # NEW English decoupled layer (facades + contracts)
  core/        VehicleState, LevelRegistry
  vehicle/     Vehicle, DriverBrain, DriveCommand, PerceptionSnapshot, NeuralBrain
  navigation/  PathPlanner, RouteHints
  parking/     ParkingSpot
  world/       LevelManager, LevelConfig, Obstacle
  ui/          Hud, Minimap, DebugRoutePanel
  flow/        DirectionArrow
ml/                      # behavior cloning: gravar.gd → treinar.py → testar_ml.gd; evoluir.py (GA)
  dados/                 # CSV datasets (git-ignored from imports via project.godot editor setting)
  modelo/                # pesos.json (net), pesos_bc.json (BC backup), evolucao_historico.json
estacionamento/          # real parking-lot images used as level floors
resources/RoadGraph.tres # hand-made HD-map lane graph (Parkinglot5 layout)
```

## 2.1. Declarative scenes, resources, and generated metadata

- `.tscn` and `.tres` files are declarative data: node/resource composition,
  properties, and external references only. They MUST NOT contain
  `[sub_resource type="GDScript"]`, `source_code`, or any inline behavior.
- Keep behavior in separate `.gd` files. Attach scripts with `ExtResource`;
  scene properties, signals, groups, and NodePaths remain declarative
  configuration. Signal connections declared in a scene are configuration,
  not orchestration logic; mediation belongs in `LevelManager` or injected
  services.
- Treat `.uid` and `.import` files as Godot-generated metadata, never as
  source of behavior, and never edit them manually. Do not add newly
  generated metadata to version control. Existing tracked metadata remains
  in place until Godot import/remapping validation confirms it is safe to
  remove it from the index.
- Do not mix build artifacts (`.pck`, `.x86_64`, `.sh`,
  `export_presets.cfg`, `.tmp_analise/`) into functional changes; keep them
  unversioned.
- Audit result: all 11 tracked `.tscn`/`.tres` files were scanned. No inline
  GDScript, `source_code`, or suspicious executable resource was found; all
  26 script properties use external `.gd` resources. At audit time, 27
  `.uid` and 6 `.import` files were tracked; after successful Godot remap
  validation they were removed from the index and remain ignored/regenerable.

Collision layers: **1** = vehicle, **2** = obstacles/walls, **4** = spot
area, **8** = spot mouth + direction arrows.

## 3. Decoupling pattern (mandatory for new code)

Depend on ABSTRACTIONS (signals / groups / Resources), never on concrete
siblings. The original sin was `get_node("../Rotas")`,
`get_parent().get_node("Setas")`, `get_node("../../../Planejador")` and
`has_method("iniciar_modo_trilha")` bridges — forbidden in `src/`.

- **Facade pattern**: `src/X/Foo.gd` does
  `class_name Foo extends "res://scripts/Legacy.gd"`, adds English
  API + bridges legacy signals to English ones in `_ready()`.
  Examples: `Vehicle`, `ParkingSpot`, `PathPlanner`, `Minimap`,
  `DebugRoutePanel`, `NeuralBrain`, `DirectionArrow`. Pure-new types
  (`DriveCommand`, `PerceptionSnapshot`, `DriverBrain`, `RouteHints`,
  `LevelConfig`, `LevelManager`, `Hud`, `Obstacle`, `VehicleState`,
  `LevelRegistry`) extend RefCounted/Resource/Node directly.
- **Vehicle ↔ Spot contract**: spots NEVER call vehicle methods. Spots
  expose `is_occupied`, `mark_occupied()` + signals
  (`vehicle_at_mouth`, `vehicle_awaiting_alignment`). Mediation (who
  parks where) belongs to `LevelManager`, not to Area2D callbacks.
- **Planner is a pure service**: `build_grid() / find_route(from, to) /
  find_free_spawn(excluded) / set_route()`. Preferences arrive via
  injected `RouteHints` — the planner must NOT crawl the scene tree.
  Legacy auto-discovery stays in the base class until call sites migrate.
- **One orchestrator**: `LevelManager` replaces the ~90% duplicated
  `Mundo.gd + FaseBase.gd`. It duck-types the vehicle
  (`start_trail_mode()` → `iniciar_modo_trilha()` →
  `start_navigation()` → `iniciar_navegacao()`), working with legacy
  `Carro` AND new `Vehicle`. Per-level data goes in `LevelConfig`.
- **Canonical logic in ONE place**: `LevelRegistry` (levels list, state
  labels, `collect_route_points()`). `scripts/Fases.gd` is a thin PT-BR

## 4. PT-BR → EN dictionary (use when migrating)

`Carro→Vehicle`, `Vaga→ParkingSpot` (`ocupada→is_occupied`,
`rotacao_alvo→target_yaw`, `marcar_ocupada()→mark_occupied()`),
`Mundo/FaseBase/Fase→Level/LevelManager/Level01..`,
`Fases→LevelRegistry` (`FASES→LEVELS`, `NOMES_ESTADO→STATE_LABELS`),
`Planejador→PathPlanner` (`grade_pronta→is_grid_ready`,
`construir→build_grid`, `achar_rota→find_route`,
`achar_posicao_livre→find_free_spawn`,
`mostrar_grade/rota→show_grid/route`),
`ControleRotas→DebugRoutePanel`, `Seta→DirectionArrow`
(`direcao→heading`), `Minimapa→Minimap`
(`mundo_centro/tamanho→world_center/size`), `Obstaculo→Obstacle`,
states `BUSCANDO/DESVIANDO/ALINHANDO/ESTACIONADO/RECUPERANDO→
SEEKING/AVOIDING/ALIGNING/PARKED/RECOVERING`, flags
`modo_trilha/auto_navegacao/modo_ml→follow_trail/autonomous/
ml_driving` (a `DriverBrain` Kind, not booleans), signals
`estado_mudou/tentativa_mudou/pedir_nova_vaga→state_changed/
attempt_changed/spot_change_requested`, methods
`definir_waypoints/trilha→set_waypoints/trail`,
`iniciar_navegacao/modo_trilha→start_navigation/trail_mode`,
`get_sensor_text()→sensor_summary()`,
`posicao_aleatoria/escala_mapa/zoom_camera/mapa→random_spawn/
map_scale/camera_zoom/map_texture` (moved into `LevelConfig`).
`LevelRegistry` (`LEVELS`, `STATE_LABELS`, `collect_route_points()`) is the
canonical owner of the levels list / state labels; `scripts/Fases.gd` is a
thin PT-BR shim delegating to it. `VehicleState`
(`SEEKING/AVOIDING/ALIGNING/PARKED/RECOVERING`) keeps the legacy int order
so `estado == 3` still means PARKED during migration.

## 5. Toolchain (exact commands)

- Godot is NOT on PATH. Use `~/Downloads/Godot_v4.7.2-stable_linux.x86_64`
  (4.7.2 stable, GL Compatibility renderer).
- Validate one script:
  `godot --headless --check-only --script <path>`
  NOTE: `--check-only` resolves `class_name` globals ONLY after the
  editor cache exists — run `godot --headless --import` first, else you
  get fake `Identifier "X" not declared` errors.
- Regression (must stay green): `ml/testar_ml.gd`
  `timeout 120 godot --headless --path . --script ml/testar_ml.gd`
  Expect: `RESULTADO Fase3: ESTACIONADO em ~50s (usou_fallback=false)`.
- ML pipeline: `godot --headless --path . --script ml/gravar.gd`
  (→ `ml/dados/*_ep*.csv`), `python3 ml/treinar.py` (numpy only →
  `ml/modelo/pesos.json`), `ml/avaliar.gd` (fitness for `ml/evoluir.py`).
- Play: open `scenes/Mundo.tscn`, F5. Keys **1–5** switch levels,
  **R** restarts, F6 plays the open scene directly.
- Trail-mode parking check (Fase2): bounded `/tmp` trace (see #14/#15) —
  expect `ESTACIONADO` in `Vaga2` (≈35 s, `dist_centro < 12`,
  `neg_frames=0`). Re-run the Fase3 ML regression above after ANY change
  to `_processar_alinhando_trilha()` or `_construir_rota_sequencial_ruas()`.

## 6. Gotchas learned the hard way

1. `Carro.gd estado` int order == `VehicleState.State` order — keep in
   sync; `ml/*.gd` compares `estado == 3` (PARKED).
2. `Vaga.gd` has TWO triggers: `Area` (body → aligning) and `Boca`
   (mouth → prepare). `ParkingSpot` re-emits both as signals but keeps
   base wiring; don't double-connect.
3. `Vehicle`/`ParkingSpot` bridge signals in `_ready()` with
   `is_connected` guards — legacy scenes connect too; duplicates spam UI.
4. `Planejador.construir()` MUST run after obstacles exist (first
   physics frame: `_plano_pendente` / `_posicionar_pendente`). Random
   spawn: build grid → `find_free_spawn(spot rects grown 50px)` →
   place vehicle. Never spawn inside a spot.
5. `AStarGrid2D` quirk: calling `_grade.update()` after setting solids
   WIPES them (already removed — do NOT re-add).
6. `move_and_slide()` Godot #94928 guard in `Carro._aplicar_movimento`
   (zero-velocity, `test_move`, predictive `move_and_collide` normal
   checks) — keep until Locomotion is extracted.
7. `Fase5.tscn` (32KB) diverged from Fase1–4 (~7KB); use `Fase3.tscn`
   as reference (only one with Line2D routes the teacher follows well;
   ML datasets are Fase3-heavy). In trail mode Fase2 also parks now
   (see #15, in-game it is key **2**). Fase1 stalls in `BUSCANDO`
   (blocked by an obstacle on its route, wp 5/21) and Fase4 hijacks to
   `ALINHANDO` mid-route with 12 waypoints left, circulating — both are
   PRE-EXISTING (their route/trigger geometry), NOT regressions from the
   Fase2 work; don't "fix" them by loosening the shared park gates.
8. `ControleRotas.gd` uses `get_node("../../../…")` — breaks if the
   Control moves. `DebugRoutePanel` must use injected refs instead.
9. `Minimap` redraws every `_process`; keep the non-finite guards
   (levels use huge coords, Fase3 ≈ ±1500px).
10. `ml/dados/*.csv` are excluded from editor import
    (`import/disable_imports_in_paths`); `treinar.py` expects exactly
    20 cols (18 inputs + 2 outputs), col 19 = desired-speed/160.
11. `CerebroML` has NO `class_name` on purpose (headless runs lack the
    global cache) — `Carro.gd` uses `preload`. Keep that until ML
    migrates to injected-`NeuralBrain`.
12. THIS environment's `editor` tool rejects `new_text` > ~6000 chars —
    split big files; long heredocs belong in `run_commands`.
13. **Fase2 fix — missing preparation point**: In `Carro.gd`,
    `_construir_rota_sequencial_ruas()` declared `ponto_prep` but never
    initialized it before use. The car would reach the end of the street
    route and then circle endlessly because it had no approach point
    before the parking spot. Fixed by initializing `ponto_prep` using the
    same formula as `preparar_estacionamento()`:
    `var dir_vaga := Vector2.RIGHT.rotated(_vaga_alvo.rotacao_alvo);
    var ponto_prep := _vaga_alvo.global_position - dir_vaga * (entre_eixos * 2.5 + 80.0)`.
    NOTE: that was only the FIRST of THREE Fase2 defects — see **#15**.

14. **Keep diagnostics lightweight**: Do not run long custom headless
    simulations (for example, 60–100 second scene traces) or create
    workspace debug scripts unless a short bounded run cannot reproduce
    the issue. Prefer syntax checks, targeted unit/static checks, and
    short smoke runs; use a full regression only when the planned
    validation requires it.
    Verified technique: Godot accepts a script OUTSIDE the project
    (`--path . --script /tmp/trace.gd`, with `-- --fase=Fase2 --secs=70`),
    so bounded traces live in `/tmp` and never pollute the workspace.
    `--headless` + `await physics_frame` reproduces trail-mode runs.
    A single tool call is time-boxed (~30 s), so run anything longer as
    `setsid bash -c 'timeout N godot … > /tmp/log 2>&1' &` and poll the log.
    Printing `estado / pos / rot / vel / wp / neg_frames` every ~1 s is
    enough to localise a wrong-waypoint or reverse-gear bug.

15. **Fase2 trail parking — THREE defects, they must be fixed together**:
    the car never reached its spot. (a) `_construir_rota_sequencial_ruas()`
    chose the free spot nearest the **spawn**, but the authored route
    (Rota1→Rota2→Rota3) physically ends ON TOP of a different spot
    (Vaga2); it then appended the wrong spot's `ponto_prep`/mid, dragging
    the car away with 2 extra waypoints. (b) Driving that tail, the car
    crossed other spots' `Area`/`Boca` triggers, whose callbacks
    overwrote `posicao_alvo`/`rotacao_alvo` while `_vaga_alvo` stayed
    wrong, so `_processar_alinhando_trilha()` followed the stale route at
    cruise speed and never parked anywhere. (c) Spot orientation must
    match the approach: Fase2 bays are entered **nose-west**, so their
    `rotacao_alvo` is `3.14159` (as in Fase3); with the default `0.0` the
    arrival error is ≈π and the `|erro| > 0.7` branch drives in
    **reverse** ("vira para trás e volta"). Fixes applied:
    - `vaga_prioritaria` (NodePath export) is now honoured by the trail
      branch too, exactly like `_escolher_vaga()`; `Fase2.tscn` sets
      `NodePath("../Vagas/Vaga2")`. This is the declarative knob for
      "which spot should the authored route end in".
    - No `mid`/`ponto_prep` is appended when the route already ends on the
      target spot (`< 150 px`).
    - `Fase2.tscn`: `rotacao_alvo = 3.14159` on all four vagas.
    Proof (must stay true): Fase2 `ESTACIONADO` in ≈35 s, `dist_centro ≈
    10.8`, `rot ≈ 3.139`, `ocupada=true`, `neg_frames=0`; Fase3 ML
    regression stays green. NOTE: the bay layout was confirmed against the
    floor art (`estacionamento/parking_lot2.svg`, 794×1123 → world
    2382×3369 at scale 3): divider lines at world y ≈ −565/−184/+197,
    stall span x ∈ [−524, +191], opening eastward into the aisle.

16. **`_processar_alinhando_trilha()` park gate**: the "100 % inside" fast
    path must ALSO require `_perto_da_vaga_para_snap()` (< 80 px from the
    spot centre) and arrival at the centre (`_dist_centro < 12.0`) before
    `marcar_ocupada()`/`ESTACIONADO`. A scaled spot (Fase2 bay =
    690×314 px) reports "100 % inside" ~248 px out; without the distance
    gate the car "parked" ~70 px off-centre and `_processar_estacionado()`
    (which only lerps below 8 px) never pulled it in. The snap gate keeps
    the finish as a short glide instead of a ~250 px "ghost slide".

17. **Latent, NOT fixed — `Vaga._atualizar_boca_pos()` scale**: it writes
    `colisao_boca.position = -dir * 74.0` in the spot's LOCAL space, but
    the Vaga node is scaled (Fase2 `7.66×2.62`), so the mouth lands
    `74 × scale` ≈ 567 px from the centre (and the mouth rect is scaled
    too). Today it acts as a harmless "prepare early" band (Fase2 triggers
    prep on Rota3 near `(600, −340)`); dividing the offset by
    `global_scale` shifts trigger timing in EVERY level, so do it as its
    own change with per-level validation.

