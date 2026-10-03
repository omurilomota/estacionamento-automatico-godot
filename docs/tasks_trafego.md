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

### T2 — Dynamic actors (`src/world/`, English, facade pattern)
| Actor | What it is | How the car reacts |
|---|---|---|
| `Pedestrian` | a person walking (sensor-only, group `pedestre`, deterministic like the `Crosser`) | yield/stop — NEVER run over; hysteresis + crossing-prediction gate |
| `Tire` | a small hazard that rolls across the lane (deterministic path + small solid body, layer 2) | the Pilot's reactive detour (DWA/LocalMap) — a moving body does NOT enter the static A* grid; that is exactly the Pilot's case |
| `StalledCar` | a car that drives and STOPS mid-lane (accident) | `blocked_ahead` → detour → replan — the S3 layer finally exercised for real (`desvios > 0`) |
- ModulesCheck assertions, headless, with mutations. Lesson of §1.27: a
  synthetic LocalMap scenario was NOT reliable — the scenario must come from
  a real Chart (as `tools/gate_chart.gd` does).
- **Decision layer** (the "decides the best in accidents"): an arbitration
  order in `Pilot` — safety (pedestrian / contact veto) > yield
  (crosser/pedestrian gate) > detour (`blocked_ahead`) > escape ladder >
  cruise; the `Crosser` already yields to a stopped vehicle (mutual-yield
  fix, `e541d12`) — extended to yield to an ACCIDENTED car in the conflict
  zone.

### T3 — Generated level "Fase11 · Trânsito"
- Extend `tools/gen_level.py` + `tools/render_lot.py` to emit the three new
  actor types (spec → scene/floor; the generator IS the gate — it aborts on
  clearance violations).
- `tools/specs/Fase11.json` + `LevelRegistry.LEVELS` + key handling (11
  levels) + `verify_scenes`. Never hand-edit a generated `.tscn` (AGENTS #41).

### T4 — Traffic gates
- `tools/gate_trafego.gd` (or gate_drive extension): `PARKED` + `desvios > 0`
  + `blocked_ahead` activations + pedestrian near-miss (min gap) + TTC +
  yields + `NEG_FRAMES=0`.
- `gate_boot` Fase11 + `gate_seeds` Fase11 (5 seeds, fixed seed) — the gates
  that see bad spawns.
- Full sweep of ALL levels in SEQUENCE (never two Godot at once, AGENTS §14).

### T5 — DAgger / Nervo (FAROL S5, never done)
- `ml/gravar.gd` records the new levels with the FAROL as PROFESSOR,
  including pedestrian/tire/accident scenarios and recovery states.
- Retrain + `FarolShield` (fallback to the professor when the LocalMap
  predicts collision). Meta: `ml/testar_ml.gd` green WITHOUT fallback.
- If it does not close: the shield keeps the professor and the number is
  recorded here (planned risk §6 of the FAROL plan).

### T6 — Publication and push (user decision: push to main)
- Final sweep → **push origin/main** → site: `export_site_data.sh` +
  `export_site_images.py` (discovers `gen_fase11.png`) → web export →
  `vercel --prod` from inside `site/` → verify the REAL alias with
  `vercel inspect` (never a noted URL) + 0 redirects (AGENTS #33).
- AGENTS.md §47+ with the new rules; update this file with measured numbers.

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
