# docs/tasks_trafego.md — dynamic traffic + decision layer (2026-10-02)

> Panel for the TRAZEGO round (working name): the user asked for a real
> traffic system — cars capable of **deciding the best action in accident
> situations**, **dodging people**, and **objects like tires**. This is the
> content decision that `docs/tasks_backlog.md` §1.27 said was missing: the
> FAROL reactive layer (`Pilot` → `blocked_ahead` → detour) runs but has
> never been exercised (`desvios = 0` in all 10 levels, because routes are
> always clear and every dynamic actor is sensor-only).
>
> Decisions closed with the user before starting (2026-10-02):
> 1. **ML retrain: retrain and promote if it is better** (§1.28 pendência —
>    the retrained weights kill the launch deadlock but the end-to-end
>    regression was ~15 s slower; measured, not guessed).
> 2. **Push the ~40 unpushed local commits to origin/main** at the end.
> 3. **Full scope**: traffic actors + decision layer + level + ML/DAgger.
>
> Language: English (AGENTS §1). Every number in this file is measured.

## 0. State at the start of the round (evidence)

| Gate | Result (2026-09-30 sweep, comanda §2) |
|---|---|
| `run_gates.sh --fases=Fase1..Fase10` | **10/10 PARKED**, cones 0, `NEG_FRAMES=0` |
| `gate_seeds` (5 seeds × 10 fases) | **50/50** |
| `gate_drive --all` | `GATE_DRIVE_OK`, `cte_med` mean 12,1 px, sat mean 21,0 % |
| `ml/testar_ml.gd` | `ESTACIONADO 68,1 s` (with fallback) |
| `desvios` | **0 in all 10 levels** — the reactive layer has no scenario |

## 1. Issues (the work items of this round)

### T1 — ML retrain promotion — RESOLVED: revert, same number as §1.28
- `python3 ml/treinar.py 40` retrained on the CSVs already on disk (4 new
  episodes, §1.28): val_mse **0,00711**, corr 0,919/0,948.
- Regression re-measured on the current code (2026-10-02):
  **`ESTACIONADO em 83,6 s (usou_fallback=true)`** — byte-identical outcome to
  §1.28 (deterministic, fixed seed). Reference **68,1 s** → **15,5 s WORSE**.
  The trace shows a recovery maneuver mid-run (t=40, `RECUPERANDO`).
- The launch deadlock IS fixed (the network drives from t=0, handover only at
  t=25 s, vs t=4,0 s after 5 px on the old weights) — but per the user's rule
  ("promote if better") the weights were REVERTED
  (`git checkout ml/modelo/pesos.json`). The 68,1 s published weights and the
  game×site parity stay as they were.
- The dataset stays on disk for DAgger (T5) — that is where the launch
  distribution gets fixed with more data, not by promoting a slower policy.

### T2 — Dynamic actors — RESOLVED (2026-10-02, commits `2239ef3` + `b00f648`)
| Actor | What it is | How the car reacts |
|---|---|---|
| `Pedestrian` | a person walking (sensor-only, group `pedestre`, deterministic path-follower, drawn in `_draw()` — no texture dependency) | yield/stop — NEVER run over; hysteresis latch (`CrosserGate` 360/480 px, hold 0,8 s) |
| `Tire` | a small hazard that rolls across the lane (deterministic path + REAL body: StaticBody2D, circle r=12, layer 2, built in `_ready()`) | the rays see it live, the Locomotion veto cuts the accelerator, the Pilot's blocked_ahead → detour routes around, the legacy ladder's replan re-rasterises the grid with the tire at its current position |
| `StalledCar` | a car that drives and STOPS on the driving line (accident; collision 190×88, Kenney texture, hazard pulse) | `blocked_ahead` → detour → replan — the S3 layer's scenario (backlog §1.27) |
- **Decision order** (`Pilot.decide_context`, renumbered): 1. SAFETY
  (pedestrian gate — a pedestrian has priority) → 2. YIELD (crosser gate)
  → 3. SENSE → 4. `blocked_ahead` → 5. DETOUR → 6. DRIVE. The
  `AutonomousDriver` got the same order in both decide paths; the legacy
  trail block merges pedestrians into the same latch.
- **Perception**: `PerceptionSnapshot` gained runtime-only
  `pedestrian_distance`/`pedestrian_bearing` — the 22-field ML contract is
  UNTOUCHED (the recorders keep writing 22 columns).
- **Bug found on the way**: the first version of Tire/StalledCar had NO
  `CollisionShape2D` — a StaticBody2D without a shape has no body, so the
  rays, the mover and the planner could never see them. Built in `_ready()`
  (behavior in the `.gd`, allowed by AGENTS §2.1) — committed `b00f648`.
- **ModulesCheck** (+13 traffic tests, 151 PASS / `fails=0`): path helpers,
  body presence (tree-entry test — the `root` Window is not active during
  `_init`, so the check moved to an `await process_frame` continuation, the
  `gate_boot` pattern), and the arbitration order with 3 synthetic
  perceptions. **Mutations run**: dropping the pedestrian yield → 1 FAIL;
  unclamping the stall → 2 FAIL.

### T3 — Generated level "Fase11 · Trânsito" — PARTIAL (generator only)
- DONE: `tools/gen_level.py` emits `pedestrians`/`tires`/`stalled_cars` from
  the spec (`90c1326`) — node + script + params, the stalled car shares the
  skin dedup list with the crossers, the collision boxes are built by the
  scripts in `_ready()`.
- **NOT done — what remains**:
  - `tools/specs/Fase11.json` (the level itself: rows/bays with `parked`,
    sidewalks, the actors authored so the stall point sits ON the driving
    line, pedestrians crossing the aisle, tires rolling across it);
  - `python3 tools/gen_level.py` + `tools/render_lot.py` (the floor) + `godot
    --headless --import` (a new PNG needs the import before any gate —
    comanda §6);
  - `LevelRegistry.LEVELS` + the key handling: keys 1–9 + 0 are taken
    (`Mundo.gd:98`/`FaseBase.gd:125`), so Fase11 needs a NEW key (keyboard
    digits are exhausted — suggest **P**, mnemonic "pedestre/transito", or
    the HUD level list) in BOTH `Mundo.gd` and `FaseBase.gd`;
  - `tools/verify_scenes.gd` after regenerating.

### T4 — Traffic gates — OPEN
- `tools/gate_trafego.gd` (or gate_drive extension): `PARKED` + `desvios > 0`
  + `blocked_ahead` activations + pedestrian near-miss (min gap) + TTC +
  yields + `NEG_FRAMES=0`. The Pilot already counts `pedestrian_latches`,
  `desvios`, `bloqueados` — the gate reads those.
- `gate_boot` Fase11 + `gate_seeds` Fase11 (5 seeds, fixed seed) — the gates
  that see bad spawns.
- Full sweep of ALL levels in SEQUENCE (never two Godot at once, AGENTS §14).

### T5 — DAgger / Nervo (FAROL S5, never done) — OPEN
- `ml/gravar.gd` records the new levels with the FAROL as PROFESSOR,
  including pedestrian/tire/accident scenarios and recovery states.
- Retrain + `FarolShield` (fallback to the professor when the LocalMap
  predicts collision). Meta: `ml/testar_ml.gd` green WITHOUT fallback.
- If it does not close: the shield keeps the professor and the number is
  recorded here (planned risk §6 of the FAROL plan).

### T6 — Publication and push (user decision: push to main) — OPEN
- Final sweep → **push origin/main** (the work lives on `develop`; main is at
  `331b667`, a merge of develop — the repo workflow is develop → merge to
  main) → site: `export_site_data.sh` + `export_site_images.py` (discovers
  `gen_fase11.png`) → web export → `vercel --prod` from inside `site/` →
  verify the REAL alias with `vercel inspect` (never a noted URL) + 0
  redirects (AGENTS #33).
- AGENTS.md §47+ with the new rules; update this file with measured numbers.
- `comanda.md` was DELETED (2026-10-02): its work was verified realized (all
  §5 commits in the history), per the user's request.

## 2. Invariants (NOT to be broken)
- Never loosen a shared park gate — fix the scene or the spec (AGENTS #42).
- `estado == 3` stays PARKED; the `VehicleState` order does not change.
- ML contract: 22 inputs, 24 columns, `site/data/` only via
  `bash tools/export_site_data.sh` (AGENTS #26).
- Bay mouth anchored in world space (AGENTS #17) — not touched.
- Generated phases are DATA (`tools/specs/*.json`).
- No inline scripts in `.tscn`; `tools/verify_scenes.gd` stays green.
- Never two Godot at once; every child process killed at the end (AGENTS §14).
- Commit = one sentence (AGENTS §0.1), one logical change each.

## 3. Open items carried from the backlog (registered, not scheduled)
- **Fase2 lane tuning**: `gate_lane` reports `x_mediano = 745,7`, 459 px from
  the right guide, 21,4 % inside the user's box (backlog §1.21 / §4 — a
  tuning question on `LaneOffset`'s open-aisle branch, not a regression).
- **Fase10 middle corridor**: with the `inflar` spawn margin the car is born
  in the corridor between the two staggered refuges and fails (backlog
  §1.26) — level geometry, `tools/specs/Fase10.json`.
- **`bloqueado_celulas` headless test gap** (backlog §1.27): the gate has no
  test; a synthetic LocalMap scenario was unreliable. The StalledCar level
  (T2/T3) covers the runtime path; the headless test must use a real Chart.
