# AGENTS.md — Autonomous Parking (Godot 4.x)

> Instructions for AI coding agents working in this repo. The user speaks
> PT-BR; code and docs are ENGLISH (see §1). Legacy PT-BR code lives in
> `scripts/` + `ml/*.gd`; new decoupled code lives in `src/`.

## 0. Ask, don't guess (mandatory)

- **Always ask the user when something is necessary** — an ambiguous
  request, two viable strategies, a requirement you would otherwise have to
  invent, a trade-off between speed and safety. Use the `ask_user` tool and
  WAIT for the answer before writing code; do not silently pick a default
  and mention it later as "I assumed".
- Ask especially before: touching a documented invariant/proof (AGENTS §5–§6,
  the locked decisions in `docs/tasks_*.md`), deleting or renaming files,
  running long/irreversible commands, changing a shared park gate, or
  choosing a third-party service.
- Ask ONE focused question with 2–4 concrete options plus your
  recommendation (and the evidence behind it). Never dump a wall of
  questions.
- Do NOT ask what the repo already answers: if the conventions, existing
  code or a previous decision settle it, decide and act. Ask only when the
  answer changes the outcome or the action is hard to undo.
- Questions may be in PT-BR (the user speaks PT-BR); code and docs stay
  English (§1).

## 0.1. Commits (one sentence, maximum)

- **The commit message is AT MOST ONE SENTENCE.** One line, one sentence,
  no body. If the change needs more explanation, that text goes in the
  docs (`docs/tasks_*.md`) or in the PR/issue — not in the log.
- **Commits are small.** One logical change each. Do not mix a bug fix,
  a refactor and a doc in the same commit.
- Do NOT write multi-paragraph commit bodies, do NOT paste gate logs or
  diffs into the message, and do NOT narrate the whole investigation.
- Subject in the existing house style, e.g.
  `:bug: fix(vehicle): close the cte boundary that made the brain reverse`
  (type(scope): short imperative summary).
- If a commit cannot be summarised in one sentence, the change is
  probably more than one commit.

## 0.2. Unattended work ("vou sair do pc")

- **When the user says they are leaving the PC** — "vou sair do pc, trabalhe
  o máximo sem mim", "continue, pois vou sair do pc", or anything to that
  effect — the AI works to the MAX without them: **forget about asking,
  forget about stopping, just CONTINUE** until the planned work is done or
  hits a wall only the user can decide.
- The questions it would have asked become **DECISIONS, made by the AI and
  RECORDED in the round's panel** (`docs/tasks_*.md`) with the evidence
  behind each — never silently assumed. A decision that is truly the user's
  (promoting a slower retrain to production, a paid service, deleting data,
  publishing) waits recorded in the panel instead of blocking everything
  else.
- **And the authority is explicit: while the user is away, the AI CREATES
  tasks for itself and RESOLVES the project's pendências on its own**
  (the backlog items, the open issues in `docs/tasks_*.md`) — it does not
  wait to be handed work. Pick the next item from the panel, do it, close it
  with its gates, open the next. Only a decision that is truly the user's
  waits recorded instead of blocking.
- The invariants do NOT loosen for autonomy: never two Godot at once, kill
  every spawned process at the end of each block (AGENTS §14), commit = one
  sentence (§0.1), never loosen a shared park gate (#42), bounded `/tmp`
  traces (#14), the ML contract and the other locked decisions stand.
- Heavy one-shots (exports, renders, long gates) run in the FOREGROUND with
  an explicit `timeout` whenever they fit the call budget; `setsid`+poll only
  for the few that truly exceed it, and ALWAYS finish them before ending the
  turn.

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
  Cone.tscn              # SOLID StaticBody2D traffic cone (layer 2, circle r=18)
  Seta.tscn              # legacy flow hint arrow (layer 8, never blocks)
  Hud.tscn               # THE shared HUD panel (instanced as UI/Control in every level)
  fases/Fase1..9.tscn    # level scenes; Fase5..Fase9 are GENERATED from tools/specs/*.json
                         # (never hand-edit a generated one: edit the spec + regen)
scripts/                 # LEGACY PT-BR (Carro.gd 2200+ lines = god object, FaseBase, Mundo, Planejador…)
src/                     # NEW English decoupled layer (facades + contracts)
  core/        VehicleState, LevelRegistry
  vehicle/     Vehicle, DriverBrain, DriveCommand, PerceptionSnapshot, NeuralBrain,
               CrosserGate, VehicleCatalog, EngineAudio
  navigation/  PathPlanner, RouteHints, LaneOffset
  parking/     ParkingSpot
  world/       LevelManager, LevelConfig, Obstacle, Crosser
  ui/          Hud, DebugRoutePanel
  flow/        DirectionArrow
ml/                      # behavior cloning: gravar.gd → treinar.py → testar_ml.gd; evoluir.py (GA)
  dados/                 # CSV datasets (git-ignored from imports via project.godot editor setting)
  modelo/                # pesos.json (net), pesos_bc.json (BC backup), evolucao_historico.json
estacionamento/          # real parking-lot images used as level floors
  gen_fase5..9.png       # floors COMPOSED by tools/render_lot.py (crops of the art)
resources/RoadGraph.tres # hand-made HD-map lane graph (Parkinglot5 layout)
tools/                   # versioned gates + the level generator (see §5)
  gate_boot/gate_seeds/gate_lane/gate_trail/gate_ml_probe/verify_scenes
  gate_reach.gd          # "can the car REACH the spots?" — BFS + per-bay route check
  gen_level.py           # spec -> .tscn (bay grid DERIVED from the car footprint)
  render_lot.py          # spec -> floor PNG (paint derived from the same geometry)
  specs/*.json           # the declarative level specs (Fase5/6/7)
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
- Play: open `scenes/Mundo.tscn`, F5. Keys **1–9** switch levels,
  **R** restarts, **T** toggles TRILHA ⇄ AUTÔNOMO at runtime (same as the
  "Auto Navegação" checkbox; `Carro.definir_modo()` clears the FSM state and
  re-plans, so the old route/spot is never inherited), **C** cycles the 10
  cars (`VehicleCatalog`), **H** shows/hides the HUD debug panel, F6 plays the
  open scene directly.
- Trail-mode parking check (Fase2): since 2026-09-24 the Fase2/Fase3
  scenes boot the AUTONOMOUS pilot (`auto_navegacao = true`,
  `modo_trilha = false`, `brain_enabled = true` on the `Carro` node — the
  car plans its own A* route instead of following the `Rotas` Line2D), so
  this proof must FORCE trail mode: set `modo_trilha = true` and call
  `iniciar_modo_trilha()` on the car BEFORE adding the scene to the tree
  (`tools/gate_trail.gd`; the UI "Auto Navegação" checkbox does the same
  in-game). Expect `ESTACIONADO` in `Vaga2` (≈35 s, distance to the spot
  centre < 12 px, `neg_frames = 0`).
- Autonomous parking gate (the deliverable): `tools/run_gates.sh` runs
  `tools/gate_boot.gd` over a list of levels IN SEQUENCE (never two Godot
  instances at once) and prints `PASS/FAIL` plus the `BOOT`/`CONES`/`NEG`
  lines; `tools/gate_seeds.gd` is the 5-seed matrix with random spawn.
- Right-hand traffic + cone clearance gate: `/tmp/lane_measure.gd
  --fase=Fase2|Fase3` prints per-point `free_l/free_r/shift/free_r'` for the
  RAW A* route, the SHIFTED route and after a forced replan, then sweeps 8
  random spawns for the worst cone distance. Targets: shift >= 150 px mean on
  the aisle legs, `free_r' >= raio_varrido` everywhere (0 violations) and
  every cone `>= raio_varrido + 18 + 40` px from the route. Bounded and in
  `/tmp` (AGENTS §14).
- HUD gate: `/tmp/hud_check.gd` boots Mundo + Fase1..5 and asserts the panel
  owns the text, the minimap still resolves `../../../Carro` through the
  instanced scene, **H** opens the debug section, **C** swaps the skin and
  `DebugRoutePanel` resolves the planner/vehicle from its exported paths.
  `/tmp/boot_smoke.gd --fase=FaseN` is the cheap "must not crash" boot.
- Re-run the Fase3 ML regression above after ANY change to
  `_processar_alinhando_trilha()` or `_construir_rota_sequencial_ruas()`.
- **Reachability gate** (the one that answers "can it get to the spots?"):
  `godot --headless --path . --script tools/gate_reach.gd -- --fase=FaseN`
  loads the level, rebuilds the SAME occupancy grid the car builds (FaseBase sizes
  it, `Carro` raises `inflar` to the swept radius), BFS-floods from the spawn and
  then calls `Planejador.achar_rota()` for every bay's preparation point exactly
  like `Carro._escolher_vaga()` does. It prints per-bay REACHABLE/UNREACHABLE and
  exits non-zero if not one bay is reachable. This is the gate that showed Fase1
  and Fase5 had **zero** usable bays.
- **Reachability is not "the point is routable"** (`tools/gate_reach.gd` only
  asks the planner for a route to the preparation point, and the planner will
  happily snap a goal that is INSIDE a wall to the nearest free cell). The
  generator is the real gate: the bay CENTRE and its preparation point must keep
  `raio varrido + 2.5 cells` from every wall except the one the row is built
  against (`tools/gen_level.py`, 2026-10-01). Two levels were shipping dead bays
  past `gate_reach`: Fase6 (3 of 13, its 221 px spikes sealed the aisle once the
  swept radius inflated it) and Fase9 (`N_4`'s prep point 10 px inside an
  interior wall). A perimeter wall the car parks *against* is not a clearance
  violation — the hull touches the kerb by design.
- **Level generator** (declarative, asserts before writing):
  `python3 tools/gen_level.py tools/specs/FaseN.json` emits the scene; the stall
  grid is derived from the car footprint and the script ABORTS if a bay would
  overlap its neighbour, stick out of the world or have its preparation point
  outside the drivable area. `python3 tools/render_lot.py tools/specs/FaseN.json`
  draws the floor from the same spec, so paint and collision cannot disagree.
- **Game gates live in `tools/`, not in `/tmp`** (a power cut on
  2026-09-26 wiped `/tmp` and took the whole suite with it — it is now versioned
  and reproducible):
  - `tools/gate_boot.gd -- --fase=FaseN --secs=75` — real boot: ESTACIONADO +
    cone hits + the OBSERVABLE yield (a car crossing within 340 px while the
    player is stopped; it deliberately does NOT read the car's `CrosserGate`,
    because with a brain active the gate in use is the brain's, AGENTS #20) +
    `neg_frames`. Non-zero exit on failure.
  - `tools/gate_seeds.gd -- --fases=Fase1,...,Fase10 --secs=80` — 5 seeds per
    level with random spawn (50 boots; the default is still Fase2,Fase3).
    This is the gate that catches what a single boot cannot — it is the one that
    caught Fase3 seed 2 wedging forever on an undrivable lane (§46).
  - `tools/gate_drive.gd -- --fase=FaseN --secs=75 [--ref=<json>]
    [--shift=X] [--farol=M] [--lane=M]` — the driving-quality board:
    `|CTE| med/p95`, steering saturation %, minimum hull clearance, replans,
    local detours, TTC and total time, on the fixed seed 9000 **per level**.
    `--ref` compares against a stored scoreboard and fails on a regression
    (a different seed between the two is itself a failure); `docs/farol_drive.json`
    is the current board (10 levels). Never judge a lane width from the scene:
    sweep it with `--shift=` (AGENTS §46).
  - `tools/gate_lane.gd -- --fase=FaseN --secs=32 [--shift=X]` — the right-hand
    rule by ABSOLUTE position: median x, distance to the right guide and the
    fraction inside the box the user drew (x 832..1206 in Fase2), plus the
    route's `free_r' >= raio varrido` invariant. Never judge the lane with a
    lateral offset in a wide aisle (#31). `--shift=` sweeps the lane width of a
    level without touching the scene (§46).
  - `tools/gate_trail.gd -- --secs=70` — Fase2 in forced trail mode.
  - `tools/gate_ml_probe.gd` + `tools/gate_ml_probe.js` (+ the fixed
    `tools/ml_probe_vector.json`) — the browser's MLP must equal the game's.
- **Site data** (`site/` is the deploy root, not Godot): `bash
  tools/export_site_data.sh` copies `ml/modelo/pesos.json` +
  `evolucao_historico.json` into `site/data/` and asserts the contract
  (`[22,32,16,2]`, 22 `x_mean`/`x_std`, every `x_std > 0`); prints
  `EXPORT_DATA_OK`. Re-run it after ANY retraining.
- **Site playground numeric gate** (proves the browser math == the game math):
  write a fixed 22-value vector to `/tmp/ml_probe_vector.json`, then
  `~/Downloads/Godot_v4.7.2-stable_linux.x86_64 --headless --path . --script
  /tmp/ml_probe.gd` (preloads `scripts/CerebroML.gd`, prints
  `GODOT_ESTERCAMENTO`/`GODOT_VELOCIDADE` with 12 decimals) and
  `node tools/gate_ml_probe.js <log>` (requires **the same** `site/js/ml.js` the
  browser loads, same vector, same `site/data/pesos.json`). Gate: worst
  `|diff| <= 1e-6` (measured 4.043e-13 — Godot's `tanh` is not libm's) and
  `GATE_ML_OK`.
- **Site preview / publish**: `python3 -m http.server 8137 --directory site`
  (8000 is already taken on this machine), kill by PID afterwards. Publish with
  `vercel --prod --yes` **from inside `site/`** — the project link lives in
  `site/.vercel/project.json` and `vercel.json` must exist ONLY there.
- **LIVE URL: `https://site-pi-tan-51.vercel.app`** (measured 200 on
  2026-10-01, deploy `estacionamento-automatico-ga6392lew`, after re-running
  `export_site_data.sh` + `export_site_images.py` and the Web export: `/`,
  `/game/index.html`, `/game/index.pck` (6,9 MB), `/game/index.wasm`,
  `/img/piso-fase10.png`, `/data/pesos.json`, `/js/ml.js` all 200 with
  **0 redirects**, which is the §33 check).
  The project is under the team `murilohenriquemota935-1958s-projects`, so the
  alias is SCOPED. **`estacionamento-automatico.vercel.app` is NOT an alias of
  this project and returns 404** — it is in old commit messages, so grep finds
  it and looks current. After every `vercel --prod`, read the real alias with
  `vercel inspect <deploy-url> | grep -A2 Aliases`; do not trust a URL written
  down months ago. The per-deployment URLs answer `302` to
  `vercel.com/sso-api` (Deployment Protection), which is expected and is NOT a
  broken site — test the alias, never the per-deployment URL.


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
7. `Fase3.tscn` is the reference for hand-made scenes (it has the Line2D
   routes the teacher follows well; ML datasets are Fase3-heavy). The old
   `Fase5.tscn` (32KB, 89 overlapping bays) is GONE: Fase5..Fase9 are all
   generated from `tools/specs/*.json` (see #41). The old pre-existing
   failures are also gone — **Fase1 stalls and the Fase4 mid-route hijack
   were FIXED on 2026-09-27** (#42): Fase1's car went to scale 1.1
   (swept radius 63 px instead of 86) so the 380 px gaps between the parked
   cars became drivable, and Fase4's bays were re-placed so all 8 are
   reachable. Do NOT "fix" anything by loosening the
   shared park gates; fix the scene or the level spec.
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

    **NEVER leave heavy or detached work running when the session ends
    (user complaint, 2026-09-25 — the machine got pegged by orphan
    processes):**
    - At the END of any work block, check `pgrep -fa "godot|python|node"`
      and KILL anything you spawned. Detached `setsid` survivors outlive
      the session and keep burning CPU while nobody watches them.
    - Run heavy one-shots (export, build, image composition, long
      simulations) in the FOREGROUND with an explicit `timeout` whenever
      they fit in the call budget; reserve `setsid`+poll for the few
      cases that truly exceed it, and ALWAYS finish them before ending
      the turn.
    - Never launch parallel Godot instances (seed matrix + export +
      screenshot at once = N× CPU and RAM); run them sequentially.
    - Image/SVG rasterisation is a CPU hog: cap it (small `scale`, few
      files, `timeout`), never loop unbounded over big SVGs.
    - If a background job is unavoidable, write a `/tmp/<job>.pid` and
      `kill $(cat /tmp/<job>.pid)` as the last action of the turn.

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

17. **FIXED (2026-09-28, issue #6) — `Vaga._atualizar_boca_pos()` scale**:
    it used to write `colisao_boca.position = -dir * 74.0` in the spot's
    LOCAL space, so a scaled Vaga (Fase2 `7.66×2.62`) landed the mouth
    `74 × scale` ≈ 567 px out with a 766×73 rect — a "prepare early"
    blob, not a mouth. The mouth is now anchored to the bay ENTRANCE in
    WORLD space: `offset_world = -dir * (world_half_depth + 29)` (margin
    const `MARGEM_BOCA_WORLD`), thickness fixed at 28 world px on the
    approach axis (`ESPESSURA_BOCA_WORLD`), across-width kept at 28 local
    (the base design's slit), all divided by `scale` back into local
    space. The shape is a PER-INSTANCE copy (`_forma_boca_propria`) —
    the `.tscn` rect resource is shared by every Vaga, so resizing it
    in place would leak to all of them. The literal "divide 74 by
    `global_scale`" recipe was REJECTED on purpose: 74 world px from
    the centre is INSIDE every scaled bay, i.e. after the Area trigger,
    which would make the mouth dead code. Keep the anchor world-space;
    any local-space offset is wrong under non-uniform scale.

18. **Right-hand traffic (`Carro.keep_right_shift`, default 110 px)**: A*
    minimizes DISTANCE, so on the measured routes the car ran ~40 px to the
    LEFT of the aisle axis on average and up to ~160 px on bends ("driving on
    the left", user report). `Carro._rota_a_star_ate()` post-processes the A*
    leg with `LaneOffset.apply()` (`src/navigation/LaneOffset.gd`): each point
    shifts up to `keep_right_shift` px along its own tangent's right normal,
    bounded by the REAL clearance on that side (physics ray, mask 2, via
    `LaneOffset.wall_probe`), so a shifted point always keeps at least a swept
    radius (`raio_varrido()`) from the wall. It is 0 at both route ends
    (smoothstep ramps in/out, so the prep point and the spot centre stay
    byte-identical) and 0 at a near-reversal (>~100 deg: the parking
    manoeuvre). Trail (authored Line2D) routes are NEVER shifted.
    **Rule (2026-09-26, proportional): the lane is the MIDDLE OF THE RIGHT
    HALF of the drivable corridor**, `shift = free_r - (free_r + free_l) * 0.25`
    — self-scaling, no magic constant. `free_l` is measured with the SAME
    direction-aware probe by passing `-right`; `free_l <= 0` (one-sided probe)
    falls back to `free_r` so the corridor is read as symmetric. The
    `min(shift, free_r - keep_clear)` floor is the SAFETY INVARIANT: it
    guarantees `free_r' >= keep_clear` by construction, so no swept-radius
    regression is possible. Never replace that floor with a bigger constant.
    **Why 110 was not enough:** `slack/2` in a 700-1000 px aisle yields
    ~48 px, which still reads as the middle/left. Fase2/Fase3 now declare
    `keep_right_shift = 260.0` on the `Carro` node (per-level, AGENTS §6) and
    the measured shift is 177-209 px mean on the aisle legs.
    **ONE entry point:** every autonomous A* route goes through
    `Carro._rota_a_star_ate(alvo)` (`achar_rota` + `_deslocar_para_direita`).
    3 of the 5 `achar_rota` call sites (replan, trail->A* fallback, recovery
    attempt 3) used to skip the rule, so the car went back to the left the
    moment it replanned. Line ~395 (cost measurement) and every
    trail/Line2D/snapshot route stay raw BY DESIGN (AGENTS §3).
    **Trap:** cancelling ordinary corners (e.g. a 0.5 rad `TURN_FADE`) makes
    the whole rule a no-op on A* routes — RDP decimation keeps almost ONLY
    vertices, so every point is already a 30-90 deg bend (`sum_shift=0` on
    Fase2, measured). Cancel only hairpins.
    Measured (real boot, 2026-09-26): Fase2 mean aisle shift 177 px / max
    260, Fase3 151 px mean with 260 on the long aisle leg and 310 px right of
    the axis; swept-radius violations **0** in both levels, prep point and
    spot centre unchanged, seed matrix still **10/10 parked**, Fase2 boot
    30.4 s, Fase3 boot 28.5 s, ML regression `ESTACIONADO` 78.4 s with
    fallback, Fase2 trail proof unchanged (35.2 s / 10.8 px /
    `neg_frames=0`).

19. **Cones are SOLID obstacles (`scenes/Cone.tscn`, layer 2)**: the 6 cone
    instances in Fase2/Fase3 used to override `collision_layer = 0`, which
    hid them from the car (mask 2), from the 11 raycasts AND from
    `Planejador.construir()`'s `intersect_shape` (mask 2) — the user saw the
    car drive straight through them. The overrides are gone; a cone is now a
    real `StaticBody2D` (circle r=18) that stops the kinematic mover, shows up
    on the rays and is rasterised into the A* grid.
    **A solid cone on the driving line breaks the route** — and the right-hand
    rule MOVED that line ~200 px east, so the Fase2 cones at x=470/620 ended
    up exactly on it. Rule when repositioning: the cone must be
    `>= raio_varrido + raio_cone + 40` px from the MEASURED (shifted) route
    for every spawn, and the cheapest place that provably satisfies it is
    inside a sidewalk body (the `inflar` band already seals that area, so no
    A* route can come near). Current Fase2 positions: (150,-1010), (60,-1120)
    on `CalcadaTopo` and (200,700) on `CalcadaBase` — worst distance over 8
    random spawns = 385 px. Fase3's cones sit on `CalcadaTopo` already
    (>= 956 px) and only became solid.
    **Contingency ladder (never skip a step):** move the cone further off the
    corridor -> shrink `Cone.tscn`'s `CircleShape2D.radius` -> NEVER re-zero
    the collision layer.

20. **The brain is CACHED, and it must be**: `_brain_for_current_mode()`
    used to return `AutonomousDriverRef.new()` on EVERY FRAME when
    `brain_enabled` was set and no brain was injected — which is exactly
    Fase2/Fase3 (only `LevelManager` injects one). Any per-brain state (the
    `CrosserGate` latch, timers) was discarded at 60 Hz and a RefCounted was
    re-allocated 60x/s. Now one instance per kind, invalidated in
    `set_driver_brain()`, `set_brain_enabled()` and `definir_modo()`
    (`_invalidar_brain()`). **Order matters:** the crosser gate (Track C) is
    meaningless without this fix — fix the cache FIRST.

21. **Crossing traffic yields with HYSTERESIS (`src/vehicle/CrosserGate.gd`)**:
    the `Crosser` is deliberately body-less (sensor-only), so the yield
    decision is the only place the player can be made to stop.
    `should_yield(distance, bearing, delta)` latches at `enter_distance` and
    releases only past `exit_distance` (or outside a wider `release_cone`) AND
    after `min_hold` seconds — the bare threshold made the car creep through.
    `AutonomousDriver` uses the gate as an INSTANCE var (autonomous default
    220/340 px, 1.0 s); the legacy trail path in `Carro._processar_trilha()`
    uses the same class with 140/220 px, 0.5 s because the trail corridors are
    narrower (a 340 px exit starved the route). `PerceptionSnapshot.
    crosser_ahead()` stays the RAW predicate — do not put state in it.
    **The Fase2 crossing is REAL and AUTHORED (2026-09-26).** `CarroDeTransito`
    used to run north-south at `x = 320`, i.e. PARALLEL to the aisle and 260 px
    west of the right-hand lane — a point-proximity gate can never see a car
    that is beside it, so the yield was dead code. It now crosses
    **east-west on `y = 700`**, `point_a (250,700) -> point_b (1000,700)`,
    `cruise_speed 160`, `pause_time 0.85`. Three geometry rules, all measured
    from the boot trace, keep it deadlock-free:
    - The lane crosses at `x ~= 588` (measured), and the car is inside the
      220 px danger strip only for `y in [480, 920]`, i.e. `t = 12.2..14.3 s`
      of a canonical boot. A point test only latches if the crosser's `x` is
      within `~130 px` of 588 in that window, so the **phase is authored**:
      `2*750/160 + 2*0.85` puts the eastbound pass over the lane centre at
      `t ~= 13.2 s`. Retune `cruise_speed`/`pause_time` TOGETHER if the car
      ever gets faster — the window is only ~2 s wide.
    - The path must extend `> 330 px` on the side the crosser escapes to,
      otherwise the car waits for the crosser's NEXT pass (measured release
      needs `|dx| > sqrt(340^2 - 90^2) = 328` once the car has stopped ~90 px
      short of the line). West 338 / east 412 — the west end sits 35 px off the
      `CalcadaBase` kerb, which reads as stopping at the give-way line.
    - A *westbound* pass forces a double wait, so the authored phase must
      always be the eastbound one. `/tmp/boot_proof.gd --fase=Fase2 --trace=1`
      prints the whole sequence; gate: `latches>=1`, standstill `>= min_hold`,
      release by distance, then park.
    Measured (canonical boot): latch `t=12.7` (`d=217`, `b=-0.18`) -> `v=0`
    for 1.2 s -> release `t=14.7` (`d=345 > 340`) -> `ESTACIONADO` 32.5 s
    (was 30.4 s, so the yield costs ~2 s), cones 0 hits, `neg_frames=0`.
    On RANDOM spawns the arrival time moves, so the yield is phase-dependent —
    `/tmp/seedmatrix.gd` reports `latches` per seed (measured: yield in **3/5**
    Fase2 seeds, 5/5 still parked).

22. **One shared HUD (`scenes/Hud.tscn`)**: the status/sensor/attempt triple
    used to be duplicated in 6 scenes and written by 3 orchestrators
    (`Mundo.gd`, `FaseBase.gd`, `LevelManager.gd`) on top of an orphan
    `Hud.gd`. Now ONE `Hud.tscn` instanced as `UI/Control` in Mundo +
    Fase1..5 — same name AND same depth, so every relative NodePath still
    resolves (the minimap's `../../../Carro`) and `tools/verify_scenes.gd`
    still finds the `UI` node. `Hud` owns all visible strings; the
    orchestrators keep their `@export var hud_path` and only hand over
    references (`bind_vehicle/bind_world/bind_routes/set_world_size`).
    The debug section is HIDDEN by default (button or **H** key) — the
    always-on checkboxes were part of the reported confusion. Visible strings
    are PT-BR everywhere, including `LevelRegistry.STATE_LABELS` VALUES (the
    KEYS stay English); `LevelRegistry.state_key()` normalises int / legacy
    name / English label into one key.
    `ControleRotas` moved one level deeper (`DebugPanel/ControleRotas`), so it
    resolves its nodes through the overridable `_resolve(nome)`;
    `DebugRoutePanel` injects `planner_node/routes_node/vehicle_node`
    declaratively and the base class falls back to a NAME search up the tree
    (AGENTS #8 debt closed for the new layout). **Do not re-introduce
    `../../../` in the panel.**

23. **Car menu (`src/vehicle/VehicleCatalog.gd`, 5 Kenney cars)**: the 5
    `assets/kenney/cars/car_*_5.png` are the same model at the same size
    (70x121 — asserted in ModulesCheck), so `scale = 1.62` and the 88x74
    collision box stay valid for every option: it is a SKIN menu, not a
    physics menu. The choice lives in a `static var` (a GDScript static
    survives `change_scene_to_file`), so levels 1-5 keep the car without an
    autoload or a `user://` file. **C** cycles (`Carro._unhandled_input`),
    the HUD `CarSelector` lists the same 5 and mirrors the current id. The
    `vehicles/` 435 MB pack stays `.gdignore`d — never take assets from it.

24. **Image/SVG rasterisation via Godot, never cairosvg at world scale**:
    composing site banner images, `cairosvg.svg2png(scale=1.0)` on
    `parking_lot3.svg` (9 MB source, pure-Python renderer) reached **13 GB
    RSS and was OOM-killed** (kernel log 2026-09-25 — the user's "RAM
    pegged" complaint). Correct pipeline: rasterise the SVG **once at 1x**
    with Godot itself (ThorVG, C++: load the imported texture and
    `get_image().save_png()`; script pattern in `/tmp/lotpng.gd`), then let
    PIL do the world-scale zoom mathematically — peak RAM a few MB.
25. **Exports**: `vehicles/` (435 MB raw asset-pack, **zero** references
    from game code) was being embedded in every export (first web .pck hit
    255 MB and blew the timeout). Fixed with `vehicles/.gdignore` — the
    editor stops scanning/importing it (also emptied `.godot/` of ~26k
    import files); delete that file to bring the pack back. `site/` also
    gets a `.gdignore` (static site is fully outside Godot's scan;
    `disable_imports_in_paths` does NOT stop texture imports, and generated
    `site/img/*.png.import` files kept reappearing). Result: web + Linux
    .pck are ~6.2 MB. Note: the export target folder must exist
    (`mkdir -p site/game`) or the export aborts.
26. **`site/data/` is a COPY, and the site's images are re-encoded, never
    copied raw** (2026-09-26). `ml/modelo/` is the source of truth;
    `site/data/*.json` is distribution for the browser playground and must be
    regenerated with `bash tools/export_site_data.sh`, never hand-edited (its
    contract check is what stops a shape change from reaching production).
    `site/.gdignore` keeps the Godot editor from importing the copy, and no
    `.import` file may ever be added under `site/`. For the gallery, do NOT
    copy the raw `estacionamento/` sources: `parking_lot.jpg` is 5.7 MB and
    `parking_lot3.svg` is 9 MB. The pipeline is: **SVG → Godot 1x raster
    (`/tmp/lotpng.gd`, ThorVG, `timeout 90`, see #24) → PIL resize only**, with
    the long side capped at 1600 px; the five Kenney car skins are 70x121 and go
    through a 4x NEAREST upscale. Result: `site/img` = 1.8 MB instead of 21 MB,
    and the whole deploy root stays at 46 MB (44 MB of that is the web export).
    `vercel.json` lives ONLY in `site/`: the Vercel project link is
    `site/.vercel/project.json`, and a root `vercel.json` would publish the repo
    root instead of the site.

27. **The per-level car scale is NOT an inconsistency — it compensates the
    camera zoom, so the car is already the same size on screen everywhere**
    (2026-09-26). Measured: Mundo is zoom 1.0 with the car at node scale 1.0
    (196 px sprite), the phases are zoom 0.45 with the car at 1.8-2.2, and
    196*k*0.45 ~= 194 px in all of them. "Normalising" the node scale to 1.0
    makes the car **2.2x smaller on screen in every phase**. Judge car size in
    SCREEN px, never in world px.
    **The bay is the free variable, and it is NOT free to resize**: growing a
    bay by only +10% in width (314 -> 345 px, Fase2/Fase3) made BOTH levels stop
    parking (`estado=2`, wp 5/10). The bay's `Area` trigger is the same rect as
    the bay, so a wider trigger re-enables the #15(b) cross-trigger: the car
    "enters" the neighbouring bay and `_vaga_alvo` stops being the target. Bay
    depth also has to stay generous: 1.16x the car length left only 69 px of
    slack for the 431 px car and the "100% inside" gate (#16) could not be met.
    1.60x is the measured-green ratio. Resizing bays requires re-running the
    boot proof of that level AND the seed matrix.
28. **The occupancy grid and the spawn bounds are different rects** (#27's
    sibling). `FaseBase._limites_de_planejamento()` sizes the grid to the map
    UNION the placed geometry UNION `Carro.alcance_preparo()`
    (`entre_eixos*escala*2.5 + 80`), because a bay's preparation point can
    otherwise fall OUTSIDE the region: A* errored, `achar_rota` returned empty
    and the car sat in BUSCANDO with 0 waypoints (Fase1). But that ring has free
    cells outside the lot, so the RANDOM SPAWN must still be bounded by the map
    rect — `Planejador.achar_posicao_livre(proibidos, limite_spawn)`. Without
    the bound the seed matrix collapsed from 10/10 to **4/10** because the car
    spawned in corner pockets with no route.
    `Planejador._celula_livre_proxima` also clamps into `region` BEFORE calling
    `is_point_solid`: AStarGrid2D errors and returns garbage otherwise.
29. **A scripted crossing car needs the same +90 deg as the player car.**
    The Kenney art faces -Y, so the CHILD Sprite2D carries `rotation = 1.5708`
    (see `Carro.tscn`); the node rotation stays the world heading. Without it the
    taxi drives sideways — it looked like a rendering bug and read as no traffic
    at all. For traffic that reads as traffic, it enters from off-screen, crosses
    and leaves, waits out of sight, and comes back; always eastbound, because a
    westbound pass forces a double wait (#21). `spawn_distance` is what authors
    the phase: the car starts that far west of `point_a`, so the first pass
    reaches the lane centre exactly when the player does (1692 px at
    cruise_speed 160, tuned by measurement, not by the old estimate).
30. **The web export is the recovery copy for the `.tscn` sources.** The `.pck`
    stores scenes as BINARY `.scn` (no `[gd_scene` text in it), and
    `ProjectSettings.load_resource_pack("res://site/game/index.pck")` +
    `load()` + `ResourceSaver.save(packed, "user://x.tscn")` brings them back as
    text — that is how six scene files were recovered after a rewrite script
    dropped every block header. Re-apply the edits of the day afterwards (the
    pack is only as new as the last export) and re-run `tools/verify_scenes.gd`.
    Lesson's rule: any scene rewrite script must RENDER both the header and the
    body and assert the header count before writing.
31. **"Driving on the right" is a LANE, not "right of the corridor centre".**
    The user drew a box (x 832..1206) on Fase2 to mark what they mean by
    `rua direita`, and the old rule missed it completely. Measured on the CAR
    with `/tmp/lane_right.gd` (absolute x + distance to the right wall, not a
    lateral offset): the car was at x=385, **620 px from the right guide, 0% of
    the samples inside the box**. The cause was `shift = free_r - width*0.25`
    (middle of the right half) in an aisle that is **1470 px wide — six car
    widths**; "half way into the right half" is the middle of the road there.
    The rule is now `shift = free_r - keep_clear`: the lane is the strip against
    the right wall, bounded by the swept radius, so the safety invariant
    `free_r' >= keep_clear` still holds by construction (measured
    `min_free_r=126.5`, `swept_violations=0`, `mean_shift` 156 -> 299 px).
    `keep_right_shift` is only a MAXIMUM and had to go 260 -> 900 in the phases
    (400 in Mundo), otherwise the rule silently degrades to "barely moved right".
    **Never judge this rule with a lateral offset in a wide aisle** — measure
    the absolute position against the marked box, or the gate is green while
    the car drives down the middle (that is exactly what happened).
32. **Right-hand lane vs. crossing yield are in GEOMETRIC CONFLICT in a narrow
    aisle, and the fix is the crossing's direction.** With the car hugging the
    right wall (94 px from it) an eastbound crosser has no room to clear: the
    gate releases at `d > 340`, so the crossing car must end 330 px beyond the
    player, which in Fase2 means driving over the sidewalk. A **westbound**
    crosser has the whole 1470 px aisle to escape west. So the canonical boot
    now authors a westbound pass: `point_a` east off-screen, `point_b` west
    inside the aisle, `spawn_distance` derived from the DIRECTION
    (`Crosser._off_scene()`), tuned by measurement to make the pass coincide
    with the player's arrival. This supersedes the "always eastbound" rule of
    #21/#29: that was measured with the car in the middle of the road, where an
    eastbound crosser did have escape room. Yield on the real boot: latch
    2,4 s, **standstill 1,6 s**, `min_gap=158 px`, `PARKED 37,1 s`.
33. **`cleanUrls` BREAKS the web export's relative paths** (2026-09-26, the
    user reported "o jogo não carrega no site"). With `"cleanUrls": true`,
    Vercel answers `/game/index.html` with a 308 to `/game` (no trailing
    slash), so the browser resolves the export's relative `src="index.js"`
    against `/` instead of `/game/` — `index.js`, `index.pck` and `index.wasm`
    all 404 and the loader never starts. `curl -L` on the HTML still returns
    200, so a naive smoke test passes while the game is dead in the browser.
    **Do not enable `cleanUrls` on this site**; the deploy root serves
    `/game/index.html` directly and the relative paths resolve correctly. The
    cheapest proof is `curl -o /dev/null -D- $URL/game/index.html | grep -c
    '^location'` — it must print 0.
34. **"Drive on the right" is a LANE, not "right of the corridor centre" (#31
    again, medido no CARRO).** `tools/gate_lane.gd` e o gate: posicao ABSOLUTA
    (x mediano), distancia ate a guia direita e fracao dentro do box que o
    usuario desenhou (x 832..1206 na Fase2). O offset lateral relativo ao centro
    dava verde num corredor de 1470 px (6 carros) enquanto o carro andava no
    MEIO. Medido antes: x=385, 620 px da guia, **0% dentro do box**. Agora:
    x=996, 206 px da guia, **100% dentro**, `swept_violations=0`.

35. **Ordem do pipeline de rota (medida, nao deduzida):**
    `A* cru -> Chaikin x3 -> reamostra 40 px -> desloca a faixa -> folga`.
    - Deslocar a **escadaria crua**: cada degrau encosta na guia e o segmento
      entre degraus corta quina de parede — o carro travava a 23 px/s.
    - Deslocar e so **depois** arredondar: o arredondamento encurta o caminho
      em ~17% cortando a quina para dentro e TIRA a rota da faixa (24% no box).
    - Arredondar a polilinha de 8 vertices (RDP tol. 18): hairpin vira laco e o
      carro faz meia-volta com o volante em batente (42 frames de RE).
    O que funciona e **Chaikin na escadaria antes de decimar**: o unico
    suavizador que limpa a quina sem nunca criar laco. `RouteShape.smooth` tem
    **auto-limite**: se o encurtamento passar de 15% (sinal de hairpin), reduz
    as iteracoes sozinho. `RouteShape.round_corners` ficou no codigo com
    `raio_curva = 0` (desligado) e um teste proprio.

36. **Pure pursuit sem termo lateral deixa erro PERMANENTE.** Com um vies
    lateral constante — que e exatamente a faixa deslocada — ele converge so
    assintoticamente e o carro assentava 75-130 px a oeste do meio da faixa.
    Nenhum ajuste de ganho ou de look-ahead tirava aquilo (reduzir o look-ahead
    de 180 para 90 moveu 5 px e deixou a rota instavel). O termo e o
    **Stanley**: `atan(k * erro_lateral / velocidade)`, com `erro_lateral`
    ASSINADO (positivo quando o veiculo esta a DIREITA da rota; corrige para a
    esquerda = negativo) e com teto de meia-estereo. `VELOCIDADE_MIN_STANLEY`
    = 60 px/s: abaixo disso o `atan` satura e o carro da meia-volta.

37. **Quase ninguem detectava "mandou andar e nao andou".** Tres Razoes, todas
    corrigidas em `Carro`: (a) com o cerebro no comando o `_physics_process`
    retorna ANTES do `_atualizar_progresso`/`_detectar_travamento`; (b) o
    watchdog do cerebro testa `|velocidade_atual| < 15` e o modelo cinematico
    nao sabe que esta travado ( lia 22,5 ); (c) o carro **escorrega** na parede
    (v = 3..7 px/s, colisao intermitente), entao um detector so no ramo de
    colisao nunca acumulava. O teste certo e por **DESLOCAMENTO**
    (`_cravou`, 2,0 s / 26 px), no topo de `_processar_rota`, e ele replaneja
    com a inflacao AUMENTADA — o oposto da 3a estrategia, que infla para 50 px
    e faz o A* desenhar por brechas por onde o casco nao passa (o carro
    reencrava no mesmo ponto).

38. **A manobra final precisa ALINHAR antes de fechar.** O portao
    `_esta_100_dentro_da_vaga()` exige o casco inteiro dentro da vaga; se o
    carro chega a 13 px do centro mas TORTO, o casco atravessa a borda, o
    portao nunca abre e o carro passa a manobrar para sempre (Fase4: 70 s).
    A manobra agora gira parado quando chega perto do centro (160 px) ainda que
    o casco ainda nao caiba. E o veto "esta em cima da calçada" do portao
    virou um teste FISICO do casco encolhido (65%): a versao anterior consultava
    a celula da grade, que ja vem com a inflacao de 137 px, e como a vaga cola
    na guia ela reprovava o carro por estar a poucos centimetros dela.

39. **A cedencia de trafego e uma RELACAO, nao um relogio.** O faseamento por
    `initial_delay` quebrava a cada mudanca de traçado (re-faseei 4 vezes num
    dia). Agora `Crosser` so sai quando ha veiculo a menos de
    `trigger_distancia` (900 px) da faixa, e CEDE MUTO: se ha veiculo na zona de
    conflito (120 px da faixa, 300 px a frente) ele segura. Sem isso o
    crosser, que e sensor-only e sem corpo, simplesmente ATRAVESSAVA o jogador
    — "o carro azul sendo sobrescrito pelo laranja". Sobreposicao agora e
    impossivel por construcao (`min_gap` de 78 px, carros de 163 px, para
    331 px).

40. **Um script de remocao de arquivo .tscn ja destruiu as 6 cenas** (perdeu
    todos os cabecalhos de bloco; duas vezes, por sombreamento de variavel no
    `for c, c in ...` e por um renderizador que emitia so os corpos). So da
    para recuperar porque o `.pck` do export guarda as cenas: `load_resource_pack`
    + `load()` + `ResourceSaver.save(..., "user://x.tscn")` traz o texto de
    volta (o pck guarda `.scn` BINARIO, entao nao da para grep). Regra: script
    que reescreve arquivo DEVE (a) renderizar cabecalho E corpo, (b) contar os
    cabecalhos antes e depois e abortar se perder algum, (c) rodar num
    `tools/verify_scenes.gd` logo em seguida. E a mesma coisa aconteceu com uma
    funcao de GDScript: `scripts/Carro.gd` perdeu `_processar_alinhando` e a
    restauracao veio de uma versao ANTIGA do HEAD — a forma de recuperar
   script do jogo NAO existe (o pck tem bytecode), entao a verificacao tem que
    ser por COMPORTAMENTO (os boots das fases), nao por diff.

41. **Nivel e' DADO, e a fase so entra no jogo depois de passar nos portoes.**
    `tools/gen_level.py tools/specs/FaseN.json` -> `.tscn`;
    `tools/render_lot.py` desenha o PISO do mesmo spec, entao pintura e colisao
    nao podem discordar. **Fase5..Fase9 sao TODAS geradas**: nunca editar uma
    cena gerada na mao (edite o spec e regenere). O gerador emite cones solidos
    e o carro que cruza (filho `Sprite2D` em `rotation = 1.5708`, #29), ABORTA se
    uma baia encostar em parede/vizinha, se o ponto de preparacao sair da area
    dirigivel, se um cone invadir a rota ou se a contagem de `[node` mudar na
    escrita (#40). `tools/gate_reach.gd` remonta a MESMA grade que o carro
    remonta, faz BFS do spawn e chama `Planejador.achar_rota()` para o ponto de
    preparacao de CADA baia (medido: **83/83** em 9 niveis). Uma fase nova nao
    esta "pronta" sem `gate_reach` + `gate_boot` + `gate_seeds` verdes nela.

42. **Fase1/Fase4/Fase5 eram defeitos de ESCALA e de CENA — e estao consertadas**
    (2026-09-27). (a) Fase1: vaos de 380 px contra **raio varrido 86 px** (carro
    em escala 1,5) deixavam a grade solida e **0 baia alcancavel**; com o carro
    em escala 1,1 (**raio 63 px**) e camera 0.9 ficou **5/5 seeds** (boot
    14-31 s). (b) Fase4: as baias saiam do eixo de entrada e o carro sequestrava
    a FSM; reposicionadas, **8/8 alcancaveis**, estaciona em 13,8 s. (c) Fase5:
    **89 baias** de 245x466 px num passo de 38 px = parede de baias sobrepostas,
    0 alcancavel; regenerada com **16 baias** derivadas do tamanho do carro.
    (d) Fase8: 4/5 -> 5/5 apenas movendo um carro ESTACIONADO que ficava na quina
    do corredor de passagem. A regra continua: **conserta a cena (ou o spec),
    nunca o portao compartilhado**.

43. **A escada de fuga do `Carro.gd` (classe "mandou andar e nao andou").** O
    detector e' por DESLOCAMENTO (`_cravou`: `TRAVA_MIN_S` 2,0 s sem andar
    `TRAVA_MIN_PX` 26 px) e vive no TOPO de `_physics_process`, fora dos ramos,
    para valer com o cerebro no comando (ele nao passa por `_processar_rota`).
    Degraus: **1-2** replanejar com inflacao maior, **3** re de emergencia
    (`estrategia 2`), **4** `_recusar_vaga_atual()` (a vaga entra em
    `_vagas_recusadas` e `_escolher_vaga` a pula, inclusive a
    `vaga_prioritaria`). Duas medicoes mandam no desenho:
    - **Quem zera a escada e' progresso REAL, nao "andar um pouco".**
      `TRAVA_RESET_PX` (78 px) e' o gate; entre dois engasgos o carro anda
      100-200 px e volta a encravar, entao um reset por deslocamento degradava a
      escada para "replanejar para sempre" (Fase1: 75 s, 1167 frames de re,
      nenhuma vaga).
    - **"Avancou o indice do waypoint" NAO e' progresso.** A rota replanejada
      nasce NA CELULA DO CARRO: os 4 primeiros pontos ficam a 0,02 px um do
      outro, o indice andava 1->4 com o carro CONGELADO e zerava a escada depois
      de cada degrau (medido: 50 s a 7,4 px/s, 0 re, 0 vaga recusada). O reset
      em `_avancar_indice_rota` tambem exige `TRAVA_RESET_PX` de deslocamento.
    - Depois da re o carro sai do solido mas continua apontando para dentro dele:
    `_orientar_para_rota()` e a **cautela** de `CAUTELA_S` s a `CAUTELA_VEL`
    px/s atacam o recravamento. Tambem existe um prazo para a manobra final
    (`ALINHA_MAX_S`), senao ALINHANDO vira estacionamento eterno.

44. **Os portoes separam re DELIBERADA de re INDEVIDA.** `tools/gate_boot.gd`
    conta `NEG_FRAMES` (re em estado de direcao: 0/1/2/3) e `REC_FRAMES` (a re
    do RECUPERANDO, que e' a manobra da escada, #43) com 25 frames de graca
    depois do ultimo frame em recuperacao (o carro sai a -64 px/s e a inercia
    leva ~0,4 s para virar). O gate continua exigindo **NEG 0**; sem a separacao,
    um carro que se desencrava sozinho e ESTACIONA era reprovado pelo proprio
    resgate. `tools/run_gates.sh --fases=... --secs=N` roda tudo em SEQUENCIA
    (nunca duas instancias de Godot, §14) e resume `PASS/FAIL`. A escada aparece
    no jogo como `[RECUPERACAO]` no log e `RECUPERANDO` no HUD.

45. **`tools/export_site_images.py` DESCOBRE os pisos gerados**
    (`estacionamento/gen_fase*.png`), em vez de listar dois na mao: uma lista
    fixa deixava Fase8/Fase9 sem imagem na galeria. Toda imagem do site continua
    sendo RE-CODIFICADA pelo script versionado (nunca copiada crua, §26) —
    o script roda em segundos porque o trabalho pesado (SVG -> PNG) e' feito
    pelo Godot a 1x (#24).

46. **A invariante da faixa (#18) vale num EIXO so — e o carro dirige o
    SEGMENTO, nao o vertice.** `shift = fr - keep_clear` garante folga na
    normal da rota e em mais nada. Medido em 2026-09-30 na Fase3 (seed 9001,
    `keep_right_shift=900`), por estagio, com 16 raios e raio varrido 115 px:

    | estagio | folga nos VERTICES | folga nos SEGMENTOS |
    |---|---|---|
    | A* cru | 213,4 px | 213,4 px |
    | Chaikin + reamostra | 213,4 px | 213,4 px |
    | depois da faixa | 73,3 px | **0,8 px** |
    | depois de `_garantir_folga` | 104,2 px | **0,8 px** |

    A polilinha deslocada passava a **0,8 px** da quina do `Obstaculo` de
    (247, -781): dois vertices com 121 px de folga tem um segmento que corta a
    quina convexa entre eles. O carro tentava dirigir a propria rota atraves da
    parede, `NEG_FRAMES` ficava 0 e `estado` continuava `SEEKING` — **nenhum
    portao via**. A escada de fuga (#43) ciclava replan -> re -> a mesma quina
    para sempre, porque cada re de ~30 px contava como "progresso real".
    **A correcao:** a garantia passou a ser sobre o **corredor varrido** —
    `Carro._casco_preso()` amostra cada perna a cada `passo_rota * 0.4` px e
    compara a distancia ate a parede com o alcance do **CASCO** (retangulo de
    176x148 px, alcance de 74 a 88 px por direcao), **nao com o circulo
    circunscrito de 115 px**: exigir o circulo "conserta" rotas que o carro
    dirigia (custou 10 s na Fase6 e aproximou o carro de um obstaculo). O ponto
    ofendido recua pelo **menor** trecho que resolve, por bisecao, em direcao a
    linha do planejador (que o A* prova dirigivel). Duas variantes foram
    medidas e REJEITADAS: reverter a perna inteira (Fase6 +10 s) e deslizar o
    ponto para longe da parede (Fase10 `cte_p95` 44 -> 97 px).
    **Corolario de nivel:** a faixa tem de caber no corredor. Na Fase10 o
    `keep_right_shift` de 300 nao cabia entre os dois refugios escalonados —
    medido com `gate_drive --shift=`: 300 -> 23,8 s / `cte_p95` 48,0 / folga
    91 px, 200 -> 19,8 s / 24,2 / 133, **120 -> 12,6 s / 19,9 / 217**. O spec
    passou a 120. Use `--shift=` para medir, `--fase=` para isolar; nunca
    edite a cena na mao para tunar isso (a fase e' DADO, #41).
    **A faixa NO CUSTO do A\* (`lane_cost_mode=1`) NAO e' substituto imediato
    do shift** (medido em 2026-10-01, `gate_drive --farol= --lane=` + o x do
    carro boot inteiro): nas fases feitas a mao ela MELHORA a pilotagem
    (Fase2 `t` 45 -> 31,5 s, `sat` 16 -> 9 %; Fase3 60 -> 29,3 s, 34 -> 6 %)
    e **DESTROI a faixa** (Fase2: 22% -> **0%** do tempo dentro do box do
    usuario, `x_max` 1003 -> 383): a rota deixa de usar o corredor leste e vai
    pelo diagonal curto, porque `w_faixa` ainda nao paga o corredor. Nas fases
    geradas e' pior (Fase8 `cte_p95` 8 -> 19 px, `sat` 21 -> 47 %). Regra:
    um modo de faixa so entra porNIVEL, com o placar de arbitro, e
    `gate_lane` agora **FALHA com menos de 20 amostras** — uma mediana de 9
    pontos ja deu um veredito falso ("55,6% dentro do box") neste dia.
    **E o custo tinha DOIS bugs que o tornavam inerte** (achados em 2026-10-01,
    backlog §1.23): (a) `alvo` era derivado do proprio `fr` da celula, entao
    `(alvo - fr)` era negativo em TODAS as celulas e a penalidade da metade
    direita era zero — `w_faixa` de 1.8 a 40 deu a mesma rota; (b)
    `Chart.dominante_eixo` estava ESPELHADO no eixo x (as varreduras de
    `_varrer_direcoes` acumulam a distancia para celulas de coordenada MENOR, e
    o indice 0 devolvia a distancia para -x), entao a faixa era lida do lado
    ESQUERDO num corredor vertical — o eixo y estava certo, por isso o defeito
    so aparecia em perna vertical. Corrigido: `alvo` e' a distancia da faixa ate
    a guia e a penalidade e' `|alvo - fr|` nos DOIS lados. Tres testes novos
    (`Lane.*`) com mutacao rodada.
    **Ainda assim nao promove a fase:** a rua leste da Fase2 nao esta no caminho
    (a vaga esta a x=-135 e o carro nasce a x=-742), e entrar nela e' um
    DETURNO — preco de distancia que peso por celula nao compra. Quem põe o
    carro naquela rua e' o shift pos-A*, que desloca o caminho ate 900 px.
    **E o numero certo para julgar a faixa** nao e' "tempo dentro do box" (o
    carro tem de SAIR da rua para entrar na vaga, 700 px a oeste): e' a distancia
    da ROTA ate a guia dentro da rua (mediana **190 px** = `1.5 x raio varrido`)
    e o erro lateral do carro nela (`_cte_para_rota`, media **17 px**).
