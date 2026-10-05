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

### T3 — Generated level "Fase11 · Trânsito" — RESOLVED, then PROMOTED (2026-10-03)
- `tools/gen_level.py` emits `pedestrians`/`tires`/`stalled_cars` from the
  spec; `vaga_prioritaria` forces the long route; **tecla P** opens it in
  `Mundo.gd`/`FaseBase.gd`; the HUD legend lists `1-9/0/P`.
- **The gauntlet (measured, canonical boot, farol_mode=2)**: Pedestre1 yield
  (min_gap 173,7 px, the give-way glide), Tire1/Tire2 dodged (172/142 px),
  the accident car met (163 px) — nobody touched, `NEG_FRAMES=0`,
  `REC_FRAMES=0`, **PARKED 34,3s**.
- **PROMOTED to `farol_mode=2`** (the A/B board, seed 9000):
  | | legacy (0) | Pilot (2) |
  |---|---|---|
  | t | 48,7 s | **42,9 s** |
  | cte_p95 | 107,4 | **82,7** |
  | sat | 33,7 % | **2,5 %** |
  | folga_min | **0,0 (touched!)** | **18,4** |
  The legacy TOUCHED the accident car (folga 0,0); the Pilot keeps 18,4 px.
- **THE ACCIDENT CAR IS PRE-STALED** (`pre_stalled`): a stalled car that
  DRIVES IN is invisible to the A* grid (off-region at build), so every
  route is born THROUGH it and the escape depends on the ladder — measured
  fragile across random spawns (3/5, oscillating 26-41 s). With `pre_stalled`
  the grid rasterises it from t=0 and the very first A* route goes around:
  canonical 34,3 s with ZERO ladder frames. The generator gained the
  invariant that would have caught it: the stall point must keep
  `swept + hull half-diagonal + 40` px from every bay centre and prep point
  (a stall 150 px from a prep makes the goal a SOLID cell after any replan —
  the A* snaps it and the car oscillates forever; measured on seed 9001).

### T2.1 — The yield suspension: measured in THREE variants, then REMOVED (2026-10-03)
- The give-way originally returned `steering 0`, which drove the car straight
  off its lane (255 px off-route after a yield at the spawn → the brain's
  cte branch fired the reverse: NEG=107). The FIX AT THE ROOT: the yield is
  now a THROTTLE CEILING (`give_way_ceiling`) applied after the drive path —
  the steering keeps coming from the route (the Pilot applies it at the
  return; the AutonomousDriver at `pursuit.speed`). With the ceiling, F11's
  NEG fell 107 → 22 with NO suspension at all.
- The `_cravou` suspension (freeze/reset during a yield latch) was then
  measured in every variant — **and all of them broke the Fase7 seed-9002
  escape cascade** (A/B against `3a7565b`: the old code parks in 62,3 s;
  reset: wander, not parked; freeze: >100 s not parked). The cascade needs
  the ladder firing at the ORIGINAL moments. The suspension was a workaround
  for the dead steering-0 bug → **removed** (commit `dec4938`).
- ModulesCheck re-pinned: the pedestrian label survives the drive step, the
  route-less yield is a stop (nothing to steer along), `fails=0`.

### OPEN (registered, measured, not blocking) — the F11 seed matrix 4/5
- The accident car in the middle of the aisle creates a POCKET in its
  inflated band for some random spawns: the car drives into the band (the
  lane shift pushes it there; the folga check passes because the corridor is
  PHYSICALLY drivable — 92 px vs the hull's 88), but the LocalMap mixes the
  CHART's cost (0,84 — "tight"), the DWA rejects every arc and the car
  freezes at ~5 px/s with `df inf`; the ladder cycles (parado_max 26-41 s).
  Measured on seeds 9000 (stall @ x=150) and 9003 (stall @ x=-200); the
  stall position moves the pocket, never removes it — the aisle's middle
  always has one for SOME spawn.
- **The right fix is the Pilot's**: the DWA freezing on chart-cost that
  contradicts physical drivability is the same defect class as the earlier
  "stuck at 0,6 px/s with df inf" (NOT_PARKED 130 s). The LocalMap's
  `misturar_carta` uses the chart's circle-based clearance; the #46 lesson
  (guarantee by the HULL, not the circumscribed circle) was applied to
  `_garantir_folga` but not to the Pilot's cost. That is the registered
  follow-up — a dedicated session, `gate_seeds` as the judge.

### T4 — Traffic gates — RESOLVED (2026-10-05, in `gate_boot`)
- The `PEDESTRE` line (observable latches + min gap to a pedestrian node)
  and the `TRAFICO` line (min gap to every tire and every accident car),
  plus `seed(9000 + hash(fase))` — the canonical boot is DETERMINISTIC.
- The full sweep: `bash tools/run_gates.sh --fases=Fase1,...,Fase11` —
  **11/11 PASS, NEG_FRAMES=0** on the hardened levels.

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

## 4. The A2 round — the levels 6-11 got HARD (2026-10-05, user request)

The user: *"achei bem ruim a simplicidade das fases 6 a 11 — dê uma complicada
com vários passo a passo, tráfego, desviar de pessoas/obstáculos"*.
The axis chosen (user decision): **the TRAZEGO actors + few free bays** —
the bay choice and the decision sequence become the challenge.

| Level | Free bays | The step-by-step (measured canonical boot) | Matrix |
|---|---|---|---|
| F6 | 9→**5** | 2 pedestrians crossing the corridor + 2 rolling tires + the chicane kerbs → 23,0 s, ped yield at 257 px, NEG=0 | **5/5** |
| F7 | 12→**6** | 2 pedestrians + 2 tires in the twin-cone corridor; the CAR CHOOSES the bay (6 candidates) → the seeds drive 7,9-72 s through the traffic | **5/5** |
| F8 | 7→**4** | 2 pedestrians + 2 tires around the chicane → **46,9 s** (was 14 s!), ped 137 px, tire dodged at 67 px, NEG=0 | **5/5** |
| F9 | 3 | **the ACCIDENT car in the serpentine aisle** (pre-stalled at (0,0) — the 782 px aisle is the only corridor that can host it) + pedestrian + 2 tires → 25,1 s, ped 95,5 px, stall met at 281 px | **4/5** |
| F10 | 4→**3** | 2 pedestrians + 2 tires across the central corridor → 11,4 s, ped 133 px, NEG=0 | **5/5** |
| F11 | 5 | the gauntlet (unchanged — the +1 ped/+1 tire densification broke seed 9003 and was REVERTED) | **4/5** |

The full boot sweep after the hardening: **11/11 PASS, NEG_FRAMES=0
everywhere** (12,4-64,2 s; the generated levels went from the 5-16 s
"fumaça" range to 6-47 s).

**The physics rule discovered (the generator enforces what it can):**
- The ACCIDENT car needs `swept + hull-half-diagonal + 40` px from every
  bay centre and prep (the new `gen_level.py` invariant — a stall 150 px
  from a prep makes the goal a SOLID cell after any replan: the A* snaps
  it and the car oscillates 26-41 s; measured on F11 seed 9001 before the
  fix).
- **A corridor hosts a stalled car only when one side keeps
  `box-half (44) + car (161) + 2×inflation (103)` ≈ 450 px** — F6/F7/F8
  corridors (398 px, the preps lining them at ~167 px) and F10's C-S aisle
  (342 px) are SEALED by a stall; only the 782 px aisles (F9, F11) host it.
- A stall that DRIVES IN is invisible to the A* grid (off-region at build)
  → every route is born through it → the ladder-dependent escape is
  fragile across spawns (3/5 measured). `pre_stalled: true` (the accident
  already happened) puts it in the grid from t=0 — the F11 canonical went
  83 s → 33,4 s with ZERO ladder frames.

**The pedestrian WALKS AROUND stopped vehicles** (`Pedestrian.
_passo_contornando`): the give-way stops the CAR ~120 px short, but the
person kept walking THROUGH the stopped hull (measured 3×: F11 seeds
9-24 px, F6 70,8, F9 23,9). The person now slides around the hull circle
on the tangent toward the goal — F9's min_gap went 23,9 → **95,5 px** —
and the would-be mutual-yield deadlock dissolves for free (the car waits,
the person walks around, both proceed).

**The two 4/5s — both instances of REGISTERED shared defects, with the
full chains mapped:**
- **F9 seed 9001** — the THIRD instance of the inflated-band freeze: the
  pursuit's corner-cut enters the grid-solid-but-physically-free band
  around `MuroOeste` (the shift probe and `_garantir_folga` check the
  PHYSICAL walls only; the band is `inflar ≈ 103 px`, the physical
  guarantee is the hull's 88) → the LocalMap's `misturar_carta` writes
  cost 0,9 there → the DWA rejects every arc → the car freezes at 5-8 px/s
  with `df inf` → the ladder cycles. The fix is the #46 lesson applied to
  the Pilot's cost: the chart's clearance must be read by the HULL, not
  the circumscribed circle (a dedicated session; `gate_seeds` is the judge).
- **F11 seed 9003** — the ladder churn at the bay approach: the car
  reaches `N_1`'s rect at a bad angle (from the NW), the replans inflate
  the route 46→80 points and the recovery cycles at the approach. The
  boot is otherwise green (33,4 s canonical, NEG=0, nobody touched). The
  pre-sidestep matrix was 5/5 here — the choreography shifted; the #43
  ladder-at-the-approach class.

## 2. Invariants (NOT to be broken)
**The gate instrument (T4, in `gate_boot` now):** the `PEDESTRE` line
(observable latches + min gap to a pedestrian node) and the `TRAFICO`
line (min gap to every tire — r=12 solid — and every accident car), plus
**`seed(9000 + hash(fase))`** — the canonical boot is now DETERMINISTIC
(the gate_drive pattern, AGENTS #1.19: an unseeded boot is a lottery; the
hardened F6 measured 6,5 s green in one run and NEG=22 in the next, same
code, different spawn).
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
