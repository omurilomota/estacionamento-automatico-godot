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
scripts/                 # LEGACY PT-BR (Carro.gd 1900+ lines = god object, FaseBase, Mundo, Planejador…)
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
   ML datasets are Fase3-heavy).
8. `ControleRotas.gd` uses `get_node("../../../…")` — breaks if the
   Control moves. `DebugRoutePanel` must use injected refs instead.
9. `Minimap` redraws every `_process`; keep the non-finite guards
   (levels use huge coords, Fase3 ≈ ±1500px).
10. `ml/dados/*.csv` are excluded from editor import

## 7. Roadmap (incremental, no flag day)

1. DONE — `src/` facades + `LevelRegistry`/`VehicleState` + docs in EN
   (+ `Fases.gd` shim, regression green).
2. DONE — `Carro.gd` delegates distance helpers to `SensorArray`;
   `Locomotion.check()` is the reference-physics spec.
3. DONE — brains split: `PurePursuit` (shared solver) +
   `TrailFollower` / `AutonomousDriver` / `MlDriver` (pure idioms) +
   `DatasetRecorder` (CSV contract); `_ml_gravar_linha` delegates;
   `ModulesCheck.gd` 24 PASS headless; regression ESTACIONADO 50s.
4. NEXT — wire FSM steering/speed through the brain solvers (behind a
   flag, trajectory-diffed), then Fase3 pilot on `LevelManager`.

## 8. Agent workflow rules

- Plan mode: explore + align, NO edits. Act mode: implement + validate.
- Always gather context first (read scenes + scripts, not just `.gd`).
- Batch independent reads/searches/commands in ONE block (parallel).
- Use absolute paths. Prefer `read_files` over `cat`.
- After edits: `--check-only` every touched script + `--import` if
  `class_name` changed + run `ml/testar_ml.gd` if behavior changed.
- Never commit build garbage (`*.pck`, `*.x86_64`, `*.sh`,
  `export_presets.cfg`, `.tmp_analise/`) — all present as untracked
  clutter in this checkout; leave them alone.
- Pre-existing dirty files (`Carro.gd`, `Mundo.gd`, `FaseBase.gd`,
  `Fase2.tscn`, `project.godot`, `Fase3_ep0.csv`) were dirty BEFORE the
  refactor — don't "fix" them opportunistically; keep diffs focused.

    (`import/disable_imports_in_paths`); `treinar.py` expects exactly
    20 cols (18 inputs + 2 outputs), col 19 = desired-speed/160.
11. `CerebroML` has NO `class_name` on purpose (headless runs lack the
    global cache) — `Carro.gd` uses `preload`. Keep that until ML
    migrates to injected-`NeuralBrain`.
12. THIS environment's `editor` tool rejects `new_text` > ~6000 chars —
    split big files; long heredocs belong in `run_commands`.

  **R** restarts. F6 plays the open scene directly.

`get_sensor_text()→sensor_summary()`,
`posicao_aleatoria/escala_mapa/zoom_camera/mapa→random_spawn/
map_scale/camera_zoom/map_texture` (moved into `LevelConfig`).

  shim delegating to it. `VehicleState`
  (`SEEKING/AVOIDING/ALIGNING/PARKED/RECOVERING`) keeps the legacy int
  order so `estado == 3` still means PARKED during migration.

