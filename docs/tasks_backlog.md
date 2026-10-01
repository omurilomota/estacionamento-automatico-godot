# docs/tasks_backlog.md — consolidated backlog (2026-09-24)

> User goal: **deliver the autonomous car** and have **more parking lots** than
> the current 5 levels. This file is the panel (status + evidence + open
> decisions). Detailed decision logs stay in `docs/tasks_autonomy.md` and
> `docs/tasks_site.md`. Language: English (§1 of AGENTS.md).

## 0. Verified state today (evidence, not opinion)

| Check | Command | Result |
|---|---|---|
| Fase3 autonomous (A* pilot) | `/tmp/f3_auto.gd --fase=Fase3` | **PARKED 23.7 s** (was: never, ground the wall) |
| Fase2 autonomous | `/tmp/f3_auto.gd --fase=Fase2` | **PARKED 35.3 s** (was: oscillated inside Vaga2 forever) |
| Fase2 trail proof (AGENTS #15) | `/tmp/f2_trail.gd --secs=60` | **PARKED 35.3 s**, `ocupada=true`, `neg_frames=0` |
| ML regression (must stay green) | `ml/testar_ml.gd` | 72.8 s **with fallback** (pre-existing F4 damage; was 49.9 s no-fallback in v1. Was 85.5 s before the scene flags changed the mover path) |
| Module units | `src/vehicle/ModulesCheck.gd` | `fails=0` |
| D9 seed matrix (5x5) | `/tmp/seedmatrix.gd --secs=60` | **10/10 parked** (Fase2 5/5, Fase3 5/5, random spawn) |
| Right-hand traffic (§1.9) | `/tmp/lane_diff.gd`, `/tmp/lane_check.gd` | shift active on the aisle legs, **0** swept violations, park target untouched |

## 1. Real bugs found and fixed today

1. `PurePursuit.find_lookahead()` returned **`route[last]`** whenever the
   lookahead spanned more than one segment (the normal case on a fresh A*
   route). The pilot aimed at the final waypoint → zero steering + full
   throttle into `CalcadaEsq` = eternal grind. Fixed to return the
   interpolated point.
2. Corner cut: a 180 px chord chased wp5 while leaving wp4, clipping the
   `CalcadaBase` hull corner (rays reported `df/dl = inf`, so the old
   `df < 90` watchdog could never fire). Added `AutonomousDriver.turn_cap()`:
   the chord is capped at the next sharp bend (~26°), bends already passed
   are ignored.
3. **Spot triggers hijacked the target in autonomous mode**: Fase2 bays are
   689×314 with a mouth band ~567 px from the centre (AGENTS #17), so merely
   driving past `Vaga4` rewrote `posicao_alvo/rotacao_alvo` to Vaga4 while
   `_vaga_alvo` stayed `Vaga2` → `_processar_alinhando` aligned to one spot
   and gated on the other (`_esta_100_dentro_da_vaga()` false forever).
   Added `Carro._aceita_pedido_de_vaga()`: in autonomous mode only the
   assigned spot may retarget (§3 — spots never command the vehicle).
4. **The brain hijacked the ALINHANDO maneuver**: `_aplicar_movimento_trilha()`
   calls `_apply_brain_command()` first, so the brain overwrote
   `estercamento_alvo/velocidade_desejada` every frame and the FSM alignment
   commands never reached the wheels. `_apply_brain_command()` now returns
   early in `ALINHANDO` (the FSM owns the park maneuver).

5. **`PurePursuit.find_lookahead()` anchored the chord at `idx`**, but the
   vehicle is normally BETWEEN `idx-1` and `idx` (the FSM advances the index
   as soon as it is within tolerance). The chord therefore started a whole
   segment ahead (up to ~810 px on Fase3) and a far point could land at a
   coincidental bearing with the car's (wrong) heading → **zero steering** →
   the car drove straight into the sidewalk. Fixed by anchoring the
   closest-point search at `idx-1`.
6. **Fase3 `inflar` raised 125 → 150** (`scenes/fases/Fase3.tscn`): the A*
   corridor ran ~114 px from the `CalcadaBase` corner, but the 2x-scaled car
   needs ~117 px from its centre to that corner once rotated; the grid only
   guarantees the clearance at CELL CENTRES, not along the segment between
   two free cells, so the turning car clipped the corner and wedged. Per-level
   declarative knob (AGENTS #6).

## 1.5 D9 seed matrix (5 seeds x Fase2/Fase3, autonomous, random spawn)

Command: `godot --headless --path . --script /tmp/seedmatrix.gd -- --secs=60`
(boot mirrors `LevelManager._boot_vehicle()` exactly).

Re-run on the REAL game boot (scene flags only, zero injection):

| Level | Seed 1 | 2 | 3 | 4 | 5 | Total |
|---|---|---|---|---|---|---|
| Fase2 | 4.5 s | 8.0 s | 8.4 s | 12.0 s | 8.6 s | **5/5** |
| Fase3 | 8.8 s | 11.8 s | 18.6 s | 21.4 s | 13.4 s | **5/5** |

(**10/10** — the injected-boot run earlier gave the same 5/5 + 5/5 with
slightly longer times.) Before the align-phase fixes the same matrix gave
Fase2 1/5 and Fase3 0/5 (every failure: stuck ~60 px from the bay centre in
ALINHANDO).

## 1.6 Self-generated routes: the car plans instead of following the Line2D

The autonomous mode ALREADY generates its own route: `Planejador.achar_rota()`
runs A* on the occupancy grid built at runtime from the level's `Obstaculo`
colliders (with `resolucao` + `inflar` per level), and `_escolher_vaga()` picks
the bay by route cost + nose-alignment penalty. The `Rotas` Line2D nodes are
used ONLY by trail mode (the legacy demo) and by the legacy fallback boot.

What actually decides which one runs is `FaseBase._ready()`:

| `modo_trilha` | `auto_navegacao` | What the level does |
|---|---|---|
| `true` (default!) | any | `iniciar_modo_trilha()` — **follows the Line2D** |
| `false` | `true` | `iniciar_navegacao()` — **plans its own A* route** |
| `false` | `false` | manual fallback — `_coletar_pontos_rotas()` (Line2D/waypoints!) |

`brain_enabled = true` adds the `AutonomousDriver` pilot (the one validated
below); without it the legacy CTE follower drives the same A* route.

Declarative recipe per level (what `Fase2.tscn`/`Fase3.tscn` now set on their
`Carro` node): `auto_navegacao = true`, `modo_trilha = false`,
`brain_enabled = true`. Clearing `vaga_prioritaria` makes the car CHOOSE the
bay as well (planner cost + heading penalty); keeping it pins one bay.

Real-boot proof (loads the scene only, no injection, no hints, no Line2D):
`godot --headless --path . --script /tmp/boot_proof.gd -- --fase=Fase3`

| Level | Route source | Result |
|---|---|---|
| Fase3 | A* (self-planned, 2 waypoints after the mouth trigger) | **PARKED 26.2 s in Vaga3** |
| Fase2 | A* (self-planned) | **PARKED 33.1 s in Vaga2** |

New procedural lots do not need `Rotas`/`Waypoints`/`Setas` nodes at all:
floor art + `Obstaculo` colliders + `Vaga` instances + a `Planejador`
(`resolucao`, `inflar`) is enough for the car to route and park by itself.

## 1.7 Runtime mode switch: TRILHA ⇄ AUTÔNOMO

`Carro.definir_modo(Modo.[TRILHA|AUTONOMO])` + signal `modo_mudou`:

- **Key T** (handled by the car, so it works in `Mundo.tscn` and in every
  `FaseN`): toggles the mode.
- **"Auto Navegação" checkbox** (`ControleRotas`): checked = autonomous,
  unchecked = trail. It now reflects the REAL mode on scene load.
- **ComboRotas**: focusing a single Line2D switches to trail AND keeps that
  line (`definir_modo(TRILHA, manter_rota = true)`) instead of letting the
  pending replan overwrite the choice (old bug).
- HUD: the sensor label shows `MODO: AUTÔNOMO | TRILHA (linha)  [T]`
  (`FaseBase` and `Mundo`).

The switch clears `waypoints`, `_vaga_alvo`, `estrategia`, `_tempo_parado`
and `_rota_trilha_anterior` and returns the FSM to SEEKING, because inheriting
the previous mode's route left the car stuck (observed: it went back to
ALINHANDO with a stale tail).

Verified trace `/tmp/mode_toggle.gd` (Fase2, real boot): autonomous → T →
trail → T → autonomous, parks at t=91 s in autonomous. **Known:** switching to
trail MID-RUN did not park within 52 s in Fase2 — the authored sequential
route assumes the spawn area, so a mid-map switch replans a route the car
cannot follow. Switching from the spawn (or before starting) is the supported
path.

## 1.8 Vehicle clearance: the route must fit the car (reported: "scrapes and
keeps pushing a wall" / "weird reverse mid-route")

Measured with `/tmp/route_clearance.gd` (swept-radius sampling of every A*
leg + stuck/reverse/recovery frame counters):

| Level | swept radius | `inflar` | route samples violating | wall-pushing frames |
|---|---|---|---|---|
| Fase2 BEFORE | 126.5 px | 110 | 91 / 173 (worst 106 px) | 332 (5.42 s in a row) |
| Fase3 BEFORE | 115.0 px | 150 | 0 / 153 | 5 (0.08 s) |
| Fase2 AFTER | 126.5 px | 149 (auto) | **0 / 177** | **7 (0.12 s)** |
| Fase3 AFTER | 115.0 px | 150 | 0 / 153 | 4 (0.07 s) |

Root cause: the planner inflated obstacles by the level's `inflar`, which on
Fase2 (110) was SMALLER than the car's swept radius (half diagonal of the
scaled hull = 126.5 px). A* then returned paths that are physically too
tight; the kinematic solver slides the hull along the sidewalk, which looks
like scraping/pushing, and the FSM recovery (three-point reverse) fires on
the way.

Fix: `Carro._garantir_folga_do_planejador()` (called in `_ready()` and at the
start of `_planejar_rota()`) raises `Planejador.inflar` to
`raio_varrido() + resolucao * 1.5` and invalidates the grid, so the level's
`inflar` becomes a declarative MINIMUM. `Planejador.invalidar_grade()` added.

Also added two edge-triggered logs so a future sighting is diagnosable:
`[RE-BRAIN]` (first frame the brain commands reverse, with cte/target dist)
and `[RECUPERACAO]` (FSM three-point maneuver). Both are silent on the current
Fase2/Fase3 autonomous runs and on the Fase2 trail proof.

## 1.9 Right-hand traffic: the car must keep to the right of the aisle (SUPERSEDED by §1.10.1)

Reported by the user: "ele segue pela rua da esquerda" (it drives on the left
side of the aisle) — which, for someone from Brazil, looks wrong.

Measured first (`/tmp/lane_probe.gd`, real boot, free wall distance to each
side at every route point): the A* route ran LEFT of the aisle axis by ~41 px
on average in Fase2 and ~38 px in Fase3, up to ~160 px on bend legs — it cuts
the inside of every corner. Cause: A* minimizes distance and nothing in the
pipeline knows the traffic rule.

Fix: `src/navigation/LaneOffset.gd` (pure geometry, no scene tree) +
`Carro.keep_right_shift` (export, default 110 px). `Carro._rota_ate_vaga()`
post-processes ONLY the A* leg; the parking tail (prep -> spot centre) is
appended untouched, so the park target is never dragged sideways.

| Property | Value |
|---|---|
| shift per point | `clamp(slack/2, 0, keep_right_shift)`, `slack = free_right - raio_varrido()` |
| probe | physics ray, mask 2, from the point along its own right normal |
| ramps | smoothstep in from the vehicle over `max(2 * raio_varrido(), 200)` px, and back out to the route end |
| near-reversal | offset forced to 0 (turn > ~100 deg) — protects the park manoeuvre |
| trail routes | never shifted (authored by the teacher) |

Evidence (all on the real boot path, `/tmp/lane_diff.gd` + `/tmp/lane_check.gd`):

| Check | Result |
|---|---|
| Fase2 / Fase3 per-point shift | 0 at both ends and at the hairpin, 110 px on the aisle legs |
| swept-radius violations of the shifted route | **0** Fase2, **0** Fase3 |
| route side bias | Fase2 41 px LEFT -> **48 px RIGHT** of the axis |
| prep point + spot centre | byte-identical (the ramps force 0 at both ends) |
| seed matrix (5 seeds x Fase2/Fase3) | **10/10 parked** |
| A/B identical seeds, `--shift=0` vs `--shift=110` | parking times equal within ~1 s (the shift costs nothing) |
| Fase2 boot / Fase3 boot | 27.6 s (Vaga2) / 26.1 s (Vaga3) |
| Fase2 trail proof (AGENTS #15) | 35.2 s, `min_dist_centro=10.8`, `ocupada=true`, `neg_frames=0` |
| `src/vehicle/ModulesCheck.gd` | `fails=0` (+10 `Lane.*` checks) |
| `tools/verify_scenes.gd` | `scenes=10 failures=0` |
| ML regression (`ml/testar_ml.gd`) | 72.8 s with fallback — unchanged |

**Trap found while testing**: cancelling ordinary corners (the first version
used a 0.5 rad / 26 deg `TURN_FADE`) made the feature a complete no-op. RDP
decimation keeps almost ONLY vertices, so every point of an A* route is
already a 30-90 deg bend (`--shift=110` produced `sum_shift=0` on Fase2). The
cancel now only fires on a near-reversal (>~100 deg).

Housekeeping: the leftover `scenes/fases/_sceneedit_test.tscn` (scene-edit
plugin smoke test) was deleted; `verify_scenes` counts 10 scenes now.

## 1.10 The four user reports, closed (2026-09-26)

Plan: `.kilo/plans/1790383758062-quiet-circuit.md`. Five tracks: (A) the lane
rule, (B) solid obstacles, (C) crossing traffic, (D) car menu, (E) one HUD.

### 1.10.1 A — right-hand traffic is now PROPORTIONAL (supersedes §1.9)

`slack/2` capped the shift at ~48 px in a 700-1000 px aisle, which still reads
as the middle/left, and 3 of the 5 `achar_rota` call sites never applied the
offset at all. Both are fixed:

- **Rule** (`src/navigation/LaneOffset.gd`): the lane is the middle of the
  corridor's right half, `shift = free_r - (free_r + free_l) * 0.25`, floored
  by `free_r - keep_clear`. `free_l` comes from the SAME direction-aware probe
  (`-right`); `free_l <= 0` falls back to `free_r` (symmetric). The floor is
  the safety invariant: `free_r' >= keep_clear` by construction, so the
  swept-radius guarantee the old rule gave is preserved. Signatures unchanged.
- **One entry point**: `Carro._rota_a_star_ate(alvo)` = `achar_rota` +
  `_deslocar_para_direita`, used by the replan, the trail→A* fallback and
  recovery attempt 3. The cost-measurement call and every trail/Line2D/
  snapshot route stay raw by design (AGENTS §3).
- **Per-level cap**: `keep_right_shift = 260.0` on the `Carro` node of
  Fase2/Fase3. Mundo/Fase1/Fase4/Fase5 keep the 110 px default (Fase1/Fase4
  are pre-existing failures, B4 — not touched).
- ModulesCheck: `Lane.bounded_by_slack` is gone (it asserted the old rule).
  New checks: `Lane.right_half`, `Lane.right_half_clamped_zero`,
  `Lane.floor_keeps_clear`, `Lane.floor_swept_radius`,
  `Lane.one_sided_fallback`, `Lane.caps_desired_not_slack`.

| Measured (real boot, `/tmp/lane_measure.gd`) | Fase2 | Fase3 |
|---|---|---|
| mean shift on aisle legs | **177 px** (max 260) | **151 px** (max 260) |
| long aisle leg | — | shift 260, **310 px right of the axis** |
| swept-radius violations | **0** | **0** |
| prep point / spot centre | shift 0 at the tail (ramps) | idem |
| forced replan (`_rota_a_star_ate`) | same rule, 0 violations | idem |

Re-applying the rule to the already-shifted route is a no-op (`shift=0`
everywhere): the lane is a FIXED POINT of the rule, not an overshoot.

### 1.10.2 B — cones are real obstacles, and they moved

All 6 cone instances overrode `collision_layer = 0`, so they were invisible to
the car (mask 2), to the 11 raycasts and to `Planejador.construir()`'s
`intersect_shape` (mask 2) — the user saw the car drive through them. The
overrides are gone (`Cone.tscn` is a `StaticBody2D`, layer 2, circle r=18).

Making them solid exposed the second half of the bug: **the right-hand rule
moved the Fase2 driving line ~200 px east, onto the cones** at x=470/620.
Repositioned to the places that provably satisfy
`dist(cone, route) >= raio_varrido + 18 + 40` for EVERY spawn:

| Cone | Before | After | Why there |
|---|---|---|---|
| Cone1 | (470,-660) | (150,-1010) | inside `CalcadaTopo` (y<=-972) — the `inflar` band already seals that area |
| Cone2 | (470,-400) | (60,-1120) | idem |
| Cone3 | (620,300) | (200,700) | inside `CalcadaBase` (y>=586) |

Rejected on purpose: the bay-mouth shoulder (x≈300) and the corner pocket
outside `CalcadaTopo`. Both looked natural and both FAILED the 8-spawn sweep
(115.8 px and 77.2 px) because a route arriving from the north-east descends
straight through them. The corners of the aisle are exactly where a parking
manoeuvre happens — never put a solid cone there.

Fase3's cones sit on `CalcadaTopo` already (worst distance 956 px over 8
spawns) and only became solid.

| Gate | Result |
|---|---|
| worst cone distance over 8 random spawns | **385 px** (Fase2, min 184.5), **957 px** (Fase3) |
| cone/hull overlap during a full boot | **0** (`boot_proof.gd`, min gap 240 px Fase2 / 1499 px Fase3) |
| contingency ladder | used step 1 (move) only; the layer was never re-zeroed |

### 1.10.3 C — the crosser gate (and the brain cache it needed)

**Latent bug found on the way**: `Carro._brain_for_current_mode()` returned
`AutonomousDriverRef.new()` **every frame** in Fase2/Fase3 (no brain is
injected there — only `LevelManager` does that, and no scene uses
`LevelManager`). Any per-brain state was therefore discarded at 60 Hz. Fixed
first, because the gate is meaningless without it: one instance per kind,
invalidated in `set_driver_brain`/`set_brain_enabled`/`definir_modo`.

`src/vehicle/CrosserGate.gd` (RefCounted, pure, headless-unit-tested) latches
at `enter_distance` and releases only past `exit_distance` (or outside a wider
`release_cone`) AND after `min_hold`. `AutonomousDriver` uses it as an
INSTANCE var (220/340 px, 1.0 s); the legacy trail path in
`Carro._processar_trilha()` uses the same class with 140/220 px and 0.5 s
because the trail corridors are narrower (a 340 px exit starved the route —
the old B5 symptom). `PerceptionSnapshot.crosser_ahead()` stays the raw
predicate.

ModulesCheck: 13 new `Gate.*` checks (latch, hysteresis, min-hold, release
past exit, release beside/behind, reset, no-crosser clears) + the two
`Auto.*` gate checks.

**The gate was dead code, so the crossing was re-authored (2026-09-26).**
First measurement: on the Fase2 boot the gate **never latched** — the new
right-hand lane drives at x≈550-615 while `CarroDeTransito` ran north-south at
x=320, i.e. *parallel* to the aisle and 260 px west of it. A point-proximity
test can never see a car that is beside the player, so the yield could not
happen at all (that was the old B5 symptom, in a new dress).

`CarroDeTransito` is now a real perpendicular crossing: `y = 700`,
`(250,700) -> (1000,700)`, `cruise_speed 160`, `pause_time 0.85`. Three
measured rules (details in AGENTS §21) keep it deadlock-free:

| rule | why |
|---|---|
| phase is authored: the eastbound pass sits over the lane centre (x≈588) at `t ≈ 13.2 s` | the car is inside the 220 px danger strip only for `t = 12.2..14.3 s`; a point test only latches if the crosser's `x` is within ~130 px of 588 in that ~2 s window |
| the path extends > 330 px BOTH ways (west 338 / east 412) | a stopped car is ~90 px short of the line, so the distance release needs `|dx| > sqrt(340²-90²) = 328`; a short path = the car waits for the crosser's NEXT pass = deadlock |
| the authored pass is always the eastbound one | a westbound pass forces a double wait (clear the lane + come back) |

Measured on the canonical boot (`/tmp/boot_proof.gd --fase=Fase2 --trace=1`):
latch `t=12.7` (`d=217`, `b=-0.18`) → `v=0` for 1.2 s → release `t=14.7`
(`d=345 > 340`) → `ESTACIONADO` **32.5 s** (was 30.4 s, so the yield costs
~2 s), cones 0 hits, `neg_frames=0`. B5's yield is now genuinely exercised.
On RANDOM spawns the arrival time moves with the spawn, so the yield stays
phase-dependent — the matrix reports `latches` per seed (see §1.10.6).

### 1.10.4 D — car menu (5 Kenney skins)

`src/vehicle/VehicleCatalog.gd`: 5 entries (blue/black/green/red/yellow ->
PT-BR label + `res://assets/kenney/cars/car_*_5.png`), `static var current_id`
(a GDScript static survives `change_scene_to_file`, so levels 1-5 keep the car
with no autoload and no `user://` file), `texture_for`, `apply`. `Carro`
gained `@export var sprite_path` + `aplicar_skin()`; `Vehicle` gained
`set_skin/current_skin/skin_options`. **C** cycles in
`Carro._unhandled_input`; the HUD's `CarSelector` lists the same 5 and mirrors
the current id every frame. All 5 textures are 70x121 (asserted in
ModulesCheck), which is why `scale = 1.62` + the 88x74 box stay valid: it is
a skin menu, not a physics menu.

### 1.10.5 E — one shared HUD, one language

`scenes/Hud.tscn` (root `Control`) is instanced as `UI/Control` in Mundo +
Fase1..5, replacing the inline subtree that 3 orchestrators wrote into. Same
name AND same depth, so relative NodePaths still resolve — the minimap's
`../../../Carro` works through the instance (`hud_check.gd` asserts it) and
`verify_scenes` still finds `UI`.

```
UI/Control (Hud.tscn)
├── Fundo            Panel + StyleBoxFlat (rounded, 0.72 alpha, shadow)
├── StatusChip       Label 30px, colour per state  ← "PROCURANDO VAGA"
├── InfoLabel        Label 17px  ← "Vaga: Vaga2 | 312 px | 88 km/h | AUTONOMO"
├── CarSelector      OptionButton (5 cars)
├── DebugToggle      Button "DEBUG (H)"
├── LegendLabel      Label 13px (1-5 / R / T / C / H)
├── DebugPanel       VBoxContainer, visible = false  (H)
│   ├── SensorLabel / TentativaLabel
│   └── ControleRotas  → DebugRoutePanel (exports, no ../../../)
└── Minimap          Minimapa.gd subtree, exported paths unchanged
```

- `LevelRegistry.STATE_LABELS` VALUES are now PT-BR (KEYS stay English) and
  `LevelRegistry.state_key(payload)` normalises a `VehicleState` int, a legacy
  PT-BR name and an English display label into one key — the mixed
  "STATUS: Seeking spot" / "SENSOR: Obstáculo à frente" triple is gone.
- `ControleRotas` resolves through the overridable `_resolve(nome)` (name
  search up the tree); `DebugRoutePanel` overrides it with
  `planner_node/routes_node/vehicle_node`. AGENTS #8 debt closed for this
  layout — do not re-introduce `../../../` in the panel.
- `Mundo.gd`/`FaseBase.gd`/`LevelManager.gd` kept only `@export var hud_path`
  and hand over references; all label writes are gone. `LevelManager`'s four
  `*_label_path` exports collapsed into `hud_path`.

### 1.10.6 Gate results (2026-09-26, all re-run on the real boot)

| Check | Result |
|---|---|
| `src/vehicle/ModulesCheck.gd` | `fails=0` (85 checks, +30) |
| `tools/verify_scenes.gd` | `scenes=12 failures=0` (Hud.tscn included) |
| `/tmp/hud_check.gd` (6 levels) | **102/102** assertions, 0 script errors |
| `/tmp/boot_proof.gd` Fase2 | **PARKED 32.5 s** (30.4 s + 2.1 s for the crossing yield), **1 latch** (stop 1.2 s, release by distance), cone hits 0, min gap 240 px, `neg_frames=0` |
| `/tmp/boot_proof.gd` Fase3 | **PARKED 28.5 s**, cone hits 0, min gap 1499 px, `neg_frames=0` |
| `/tmp/seedmatrix.gd --secs=70` | **10/10 parked** (Fase2 5/5, Fase3 5/5); yield in **3/5** Fase2 seeds |
| `/tmp/lane_measure.gd` | shift 177/151 px mean, 0 swept violations, worst cone 385 px |
| Fase2 trail proof (AGENTS #15) | **unchanged**: 35.2 s, `min_dist_centro=10.8`, `neg_frames=0` |
| ML regression (`ml/testar_ml.gd`) | `ESTACIONADO` 78.4 s with fallback (was 72.8 s — the wider lane makes the final approach slightly longer; still green) |
| Fase1 / Fase4 / Fase5 smoke boot | alive, HUD bound, no crash (Fase1/Fase4 still the pre-existing B4 failures) |

Not done (out of scope per the plan): the manual play pass for the panel
layout (F5 → 1..5 by eye), and the `--shift=0/110/260` A/B (the seed matrix
plus the boot proofs already cover "no regression").

### 1.11 Site multi-seção + playground da rede + Vercel (2026-09-26)

The site was a single landing page with **stale numbers** (it still said "27,6 s"
and "110 px", from before the right-hand rule became proportional). It is now a
multi-section page whose every claim is a number measured in §1.10.6, plus an
in-browser playground of the network and a real deploy.

**A) The page** (`site/index.html`, `styles.css`, `main.js`). Fixed nav with
scrollspy, hero, "Jogar" (iframe + the real key bar `1–5 / T / R / C / H` — the
old one advertised `G` for the grid, which is not a binding), 7 "how it works"
cards (each with a *where to see it in the simulation* line), the FSM timeline,
the measured numbers, the gallery, the neural chapter, an architecture section,
the roadmap and the team. The **stale metrics were corrected to the AGENTS
§18–§23 measurements**: 177/151 px lane shift, 0 swept-radius violations, 32,5 s
Fase 2 (30,4 + 2,1 for the yield), 28,5 s Fase 3, 385 px worst cone distance,
35,2 s trail, 78,4 s ML. The honest-failures block now names **Fase1 (BUSCANDO,
wp 5/21)** and **Fase4 (ALINHANDO hijack, 12 waypoints left)** as pre-existing
geometry failures, and states the rule that was NOT used to hide them: never
loosen a shared park gate.

**B) `site/js/ml.js` — one math, two consumers.** The pure core (`MlpNet`,
`fromJSON`, `zScore`, `forward`) mirrors `scripts/CerebroML.gd` line for line:
`w[i][o]`, `maxf(std, 1e-8)`, `tanh` on both hidden layers, linear output,
same float64 accumulation order (bias first, then `i`). It is exported under a
`typeof module !== 'undefined'` guard so **node runs the exact browser file**;
the UI (22 sliders, live steering/speed, 32+16+2 activations, three weight
matrices with column highlight, per-input z-score) only builds when `document`
exists. Zero dependencies, zero CDN, `data/pesos.json` is the only fetch.

**Finding that changed the text on the page**: 8 of the 22 inputs are
**constant** in the v2 dataset (`x_std` falls to the 1.0 floor of
`treinar.py` for a zero-variance column → slots 0,1,2,3,4,5,9,10,20). The net
therefore sees a nearly flat signal, which is the mechanical reason parking
still needs the FSM fallback. The playground derives this from the model
(`slotsConstantes`) and prints the list instead of claiming coverage.

### 1.11.1 Gate results (2026-09-26)

| Check | Result |
|---|---|
| `bash tools/export_site_data.sh` | `contrato OK: arquitetura [22, 32, 16, 2], val_mse 0.000248386` + **`EXPORT_DATA_OK`** |
| `/tmp/ml_probe.gd` (CerebroML, real weights) | `GODOT_ESTERCAMENTO -1.418664513600`, `GODOT_VELOCIDADE 0.895881088178` |
| `node /tmp/ml_js_probe.js` (**the same `site/js/ml.js`**) | identical to 12 decimals; worst diff **4.043e-13** (gate 1e-6) → **`GATE_ML_OK`** |
| `node /tmp/ml_ui_smoke.js` (DOM shim) | 1674 nodes, 22 sliders, 6 buttons, 3 matrices, 1298 painted cells, both readouts numbered → **`GATE_UI_OK`** (caught 2 real bugs: unpainted weight cells, missing output activation cells) |
| SVG raster (Godot 1x, ThorVG) | `parking_lot2/3.svg` 794x1123 each, 242 KB after PIL, `timeout 90`, peak RSS a few MB |
| `site/img` total | **1.8 MB** for 10 new images (5 floors + 5 cars), long side <= 1600 px |
| `site/` total | **46 MB**, of which 44 MB is the web export (no re-export: build of 09:39 is current) |
| `python3 -m http.server 8137 --directory site` | 24/24 refs 200 (`/`, css, both js, both data JSON, `game/index.{html,pck,wasm}`, 10 images, icon, `vercel.json`); `pesos.json` served with the right contract |
| HTML/CSS static check | 0 unbalanced tags, 0 broken refs, 0 broken anchors, 0 classes without a rule |
| `vercel --prod --yes` from inside `site/` | **https://site-pi-tan-51.vercel.app** (production, aliased) — `/` `no-cache`, `index.pck`/`index.wasm` `immutable` + `nosniff`, `vercel.json` and `.env.local` correctly NOT served (404) |

**The stale link was the one real surprise**: `site/.vercel/project.json` named the
project `site` under a team the current token cannot see, so the first deploy
died with `Error: Not authorized` even though `auth.json` was valid.
`vercel link --project estacionamento-automatico --yes` fixed it — the **project
id was right, only the name was stale** — and the deploy reused the existing
production URL instead of creating a second site. (The CLI also wrote
`site/.env.local` with an OIDC token and appended `.env*` to `site/.gitignore`;
the token is not deployed, `/.env.local` returns 404 on the public URL.)

Not done (out of scope): re-exporting the game (nothing in `scenes/`/`scripts/`
changed, so the 09:39 build is the truth), a headless-browser screenshot of the
playground (no chromium/jsdom on this box — `ml_ui_smoke.js` covers wiring,
`ml_js_probe.js` covers the math), and `.x86_64` on a release (the button still
says "em breve").


### 1.12 O carro dirige à direita, o trânsito parece trânsito (2026-09-26, tarde)

Three user reports, in the user's words: *"ainda não acontece, ele continua
andando na esquerda"*, *"um carro muito nada a ver andando de lado para lá e
para cá que não significa trânsito"*, *"o carro está muito grande para a cena"*.

#### What the three reports actually were

1. **The right-hand rule did not exist in 3 of 6 scenes.** `keep_right_shift =
   260` was declared **only** in Fase2/Fase3; Mundo/Fase1/Fase4/Fase5 had the
   `110.0` default — and Fase1/Fase4/Fase5 booted `modo_trilha = true`, where
   `LaneOffset` is 0 *by design* ("rota de trilha autorada nunca é deslocada",
   AGENTS #18). The authored `Line2D` went wherever the author drew it. The
   site was advertising 177 px as if it were global. **Mundo, Fase2, Fase3 and
   Fase4 now boot the same autonomous pilot with `keep_right_shift = 260`**;
   the trail stays the `T` teaching mode.
2. **The crossing car was missing `rotation = 1.5708` on its sprite child** —
   the Kenney art faces -Y and `Carro.tscn` compensates on the CHILD, so
   `Crosser.rotation` (the world heading) turned the taxi 90° off: it drove
   sideways. Compounding it, the A->B->A ping-pong read as a lawnmower. It now
   **enters from 1692 px off-screen, crosses, leaves, waits out of sight and
   returns — always eastbound** (a westbound pass forces a double wait, #21).
   `spawn_distance` is what authors the phase: 1692 px makes the first pass
   reach the lane centre at t=12.7 s, measured, not estimated.
3. **The car is NOT too big — the BAY was.** The per-level car scale (1.0 in
   Mundo, 1.8-2.2 in the phases) is a deliberate compensation for the camera
   zoom (1.0 vs 0.45), so on screen the car is ~194 px in **every** scene. The
   outlier was Mundo's bay: 90x120 px for a 196 px car — it did not fit. Mundo's
   bays are now 157x313 px. Normalising the node scale to 1.0 (as "make the car
   the same everywhere" naively suggests) would have made it **2.2x smaller on
   screen in every phase**.

#### Two real bugs found on the way

- **The planner grid only covered the map rect.** A bay's preparation point
  lives `entre_eixos*escala*2.5 + 80` px beyond the bay centre, which fell
  OUTSIDE the region: AStarGrid2D errored, `achar_rota` returned empty and the
  car sat in BUSCANDO with 0 waypoints. `FaseBase._limites_de_planejamento()`
  now sizes the grid to map ∪ placed geometry ∪ `Carro.alcance_preparo()`.
- **`_celula_livre_proxima` queried `is_point_solid` before checking the
  region** — an out-of-region point made A* error and return garbage. It now
  clamps into the region first (AGENTS #28).

#### The bay resize FAILED, and why (the useful part)

Resizing every bay to 1.16x car length x 1.39x car width made **Fase2 and
Fase3 stop parking** (`estado=2`, wp 5/10). Two independent reasons, both
measured:
- Depth 1.16x left 69 px of slack for the 431 px car, and the "100% inside"
  gate (#16) could not be met.
- Then depth 1.60x (the green ratio) still failed: the **width** +10%
  (314->345 px) re-enabled the #15(b) cross-trigger — the bay's `Area` is the
  same rect as the bay, so the wider trigger made the car "enter" the
  neighbouring bay and `_vaga_alvo` stopped being the target.
So **a bay is not a free variable**: resizing it requires the boot proof AND
the seed matrix of that level. The phases were reverted to the measured
scales; only Mundo's (where the car genuinely did not fit) was changed.

#### The spawn regression, caught by the seed matrix

With the grid now bigger (geometry + prep reach), the ring outside the lot has
free cells, and `achar_posicao_livre` scanned all of them: the random spawn
landed in corner pockets with no route and the matrix **collapsed 10/10 ->
4/10**. The grid bound and the spawn bound are different rects — the spawn now
takes the map rect explicitly (`achar_posicao_livre(proibidos, limite_spawn)`,
AGENTS #28). Back to **10/10**.

#### 1.12.1 Gate results (2026-09-26 afternoon, all re-run after the changes)

| Check | Result |
|---|---|
| `/tmp/boot_proof.gd` Fase2 | **PARKED 30,6 s**, `latches=1`, standstill **1,0 s**, latch 1,8 s, min_gap 204 px, cone hits 0, `neg_frames=0` |
| `/tmp/boot_proof.gd` Fase3 | **PARKED 27,9 s**, cone hits 0, `neg_frames=0` |
| `/tmp/boot_proof.gd` Fase4 | **PARKED 9,0 s** — it used to hijack the FSM into ALINHANDO and circulate |
| `/tmp/seedmatrix.gd` (5 seeds x 2 fases) | **10/10 parked** (Fase2 8,2-19,9 s, Fase3 13,2-27,0 s); the yield did not trigger on any of the 10 random spawns (the crossing is phase-authored for the canonical boot, #21) |
| `/tmp/lane_side.gd` Fase2 (**new gate**) | 579 samples, `lateral_mediano = +53,1 px` -> **DIREITA** (min -305 on the bay entry, max +251) — the CAR, not the route |
| `/tmp/lane_measure.gd` Fase2 | `aisle_legs=8 mean_shift=156 px max 260`, **`swept_violations=0`**, `min_free_r=138`; cones at 184,5 px = `raio_varrido + raio_cone + 40` (at the limit, OK) |
| Fase2 trail proof (#15) | **unchanged**: `PARKED 35,2 s`, `min_dist_centro=10,8`, `neg_frames=0` |
| `ml/testar_ml.gd` | `ESTACIONADO` **77,2 s** with fallback |
| `/tmp/hud_check.gd` (6 levels) | `fails=0` |
| `tools/verify_scenes.gd` / `ModulesCheck` | `scenes=12 failures=0` / `fails=0` |

#### Left as debt (measured, not guessed)

- **Fase1 is a scene redesign, not a routing bug.** Its gaps between the
  parked cars are ~380 px; the car at its authored scale needs 423 px
  (2x137,5 inflation + 148 width), so the occupancy grid is ~60% solid and the
  flood-fill from the spawn reaches **1 cell** (556 at k=1,4). No car scale
  makes a bay reachable: 0 reachable bays at 1,0 / 1,2 / 1,4 / 2,0. Two
  minimal redesigns were tried and measured — opening a driveway in the
  100%-width `CalcadaCentro` (free cells grew, but the car still walled in at
  the spawn) and letting the level pick a free spawn (still `wp=0/0`) — so it
  was reverted to the authored state. Its 853 reverse frames in trail mode are
  **pre-existing**: identical A/B with and without today's changes.
- **Fase5 is the same class of debt**: 89 bays with a 38,3 px pitch in a
  245 px grid, i.e. the bays overlap 6x into a wall. The world's metric scale
  is inconsistent with the car; fixing it means re-laying out the whole stall
  grid, not a number.



### 1.13 A RuaDireita: o gate antigo media a coisa errada (2026-09-26, noite)

The user drew a box on Fase2 to mark what they mean by `rua direita`
(**x 832..1206**) and said "in case you don't know, I left it here so it's
clear". The previous gate reported "+53 px to the right of the corridor
centre -> DIREITA" and I had written that as proof the rule worked. It was
proving nothing:

- Fase2 has **one** aisle, x in [-431, 1039] — **1470 px wide, six car widths**.
  "53 px right of the centre" of a six-car-wide road is the middle of the road.
- Measured on the CAR by absolute position (`tools/gate_lane.gd`): median
  **x = 385**, **620 px from the right guide**, **0% of the samples inside the
  box**.

**The rule was wrong for a wide aisle.** `shift = free_r - width*0.25` (the
middle of the right half) was tuned for a 700-1000 px aisle. It is now
`shift = free_r - keep_clear * (1 + LANE_EDGE_MARGIN)`: the lane is the strip
against the **right wall**, bounded by the swept radius, so
`free_r' >= keep_clear` still holds by construction (`swept_violations=0`,
`min_free_r=126.5`, `mean_shift` 156 -> 299 px). `LANE_EDGE_MARGIN = 0.5` is
needed because a hard 0 pins the car on the kerb and the tracking error
(the car measured 100 px above the floor) is what wedged it.

Also: `keep_right_shift` is only a MAXIMUM and was 260 — smaller than the shift
the rule now wants in a 1470 px aisle — so it silently degraded to "barely moved
right". It is 900 in the phases, 400 in Mundo.

#### The right-hand lane and the crossing yield are in geometric conflict

With the car hugging the right wall (94 px from it, x~945) an eastbound
crosser has **no room to clear**: the gate releases at `d > 340`, so the
crossing car must end 330 px past the player, which in Fase2 means driving over
the sidewalk. A **westbound** crosser has the whole aisle to escape west. So
`Crosser._off_scene()` now derives the entry point from the DIRECTION (so a
westbound pass is just a matter of authoring two points) and Fase2 authors
`point_a (1400, 700) -> point_b (450, 700)`, `spawn_distance` solved so the
crosser occupies the crossing point when the player does. This supersedes the
"always eastbound" rule of #21/#29, which was measured with the car in the
MIDDLE of the road, where an eastbound crosser did have escape room. Measured
yield on the real boot: latch **1,9 s**, standstill **1,9 s**, min_gap 179 px.

#### A bug nobody had: nothing detected "commands motion, does not move"

Fase3 seed 2 sat at (349, -1108) for **70 s** in BUSCANDO with
`velocidade_atual = 22.5 px/s`. Three reasons, all fixed:
1. `_physics_process` returns early when a brain owns the command, so
   `_atualizar_progresso`/`_detectar_travamento` never ran;
2. the brain's own watchdog tests `|velocidade_atual| < 15` — the kinematic
   model does not know it is blocked, so it read 22.5;
3. the car was **sliding** along a wall (v = 3..7 px/s, intermittent
   collision), so a detector placed in the collision branch never accumulated.

The fix is a displacement test (`_cravou`, `TRAVA_MIN_S = 2.0`,
`TRAVA_MIN_PX = 26`) checked at the top of `_processar_rota`, and the stuck path
replans with the inflation **raised** — the opposite of strategy 2 (which
inflates to 50 px and makes A* draw through gaps the hull cannot pass, which
re-wedged the car in the same spot).


### 1.14 O olho no frame, nao so no numero (2026-09-26, noite)

Three things I only found by **rendering the level and looking at it**:

1. **O jogo nao carregava no site** (user report). `cleanUrls: true` made
   `/game/index.html` 308-redirect to `/game`, and a document served at
   `/game` resolves the export's relative `src="index.js"` against `/`:
   `index.js`, `index.pck` and `index.wasm` all 404. `curl -L` returns 200 the
   whole time, so the smoke test passed while the game was dead. Fixed by
   dropping `cleanUrls`; the gate is now `curl -D- $URL/game/index.html |
   grep -c '^location'` must print 0 (AGENTS #33).
2. **"O carro anda torto"**: it was grinding the right kerb — the right-lane
   rule put the swept circle exactly ON the floor and the pure-pursuit
   tracking error (measured ~100 px) is what pinned it. `LANE_EDGE_MARGIN`
   0.5 -> 0.7 keeps the lane against the right side and leaves room to
   correct.
3. **"Para bem em cima do carro que vem simulando"**: the yield latched at
   220 px and the brain's `stop()` zeroes the velocity instantly, so the car
   stopped exactly where it was — 71 px short of the crossing, with two
   163 px wide cars = overlapping bodies. `CrosserGate` gained a constructor
   and the autonomous driver latches at 320 px. 420 px proved no better: the
   stop position IS the latch position, so the gap is set by geometry, not by
   the threshold. The car now waits before the line and the crosser passes in
   front. A comfortable gap needs the yield to target a **give-way line**
   instead of braking wherever it latches — a real feature, not a threshold
   tweak, and not in this batch.


### 1.15 Estrada de verdade: faixas, curvas e cedência (2026-09-26, noite)

O usuário: *"ele tá porcamente seguindo o caminho, corta caminho pela rua, vamos
treinar esse modelo direito, trace um caminho que já tem e que é respeitoso às
leis de andar pela rua direita e curvas normais, poderia ter setas também. Ele
anda muito torto."*

#### 1. O caminho era o problema, não o carro

`Planejador._decimar` (RDP, tolerância 18 px) reduzia 1900 px de rota a **8
vértices com quinas de ~90°**. O pure-pursuit mira um ponto à frente, então
cortava cada quina por dentro; e cada vértice ia para a SUA parede no
deslocamento da faixa, o que virava zigue-zague. Três ordens de pipeline foram
**medidas** antes da que funciona (AGENTS #35):

| ordem | resultado medido |
|---|---|
| deslocar a escadaria crua | degrau encosta na guia, segmento corta quina — carro travava a 23 px/s |
| decimar → deslocar → arredondar vertices | arredondamento encurta 17% e tira a rota da faixa (24% no box) |
| decimar → **arredondar** os 8 vertices | hairpin vira laco, meia-volta com volante em batente, 42 frames de RE |
| **A\* cru → Chaikin ×3 → reamostra 40 px → desloca → folga** | **100% dentro do box, 0 violações, 73 waypoints** |

`RouteShape.smooth` (Chaikin) tem auto-limite: encurtamento > 15% = hairpin, e
ele reduz as iterações sozinho. `round_corners` ficou no código **desligado**
(`raio_curva = 0`), com teste próprio.

#### 2. O termo lateral (Stanley) — 100% dentro do box

`PurePursuit.solve_error` recebia só o erro de proa; com o viés lateral da
faixa ele convergia só assintoticamente e o carro assentava 75-130 px a oeste.
`atan(k·e/v)`, com `e` **assinado** e teto de meio esterço.
`tools/gate_lane.gd` (posição absoluta, nunca offset lateral):

| | antes | depois |
|---|---|---|
| x mediano | 385 | **996** |
| distância da guia direita | 620 px | **206 px** |
| dentro do box do usuário | **0%** | **100%** |
| `swept_violations` | 0 | 0 |

#### 3. Três bugs que só o frame e o gate revelaram

- **Mandou andar e não andou** (AGENTS #37): o detector de deslocamento, mais
  o replanejamento com inflação **aumentada**.
- **Ré do cérebro por ponto de mira atrasado**: `angular_error > 2.2` (≥126°)
  gave ré mesmo com o carro colado na rota (`cte` pequeno) — 51 frames de RE.
  Agora só dá ré se o carro estiver realmente perdido.
- **A manobra final alinhava tarde** (AGENTS #38): o carro chegava a 13 px do
  centro **torto**, o casco atravessava a borda e o portão nunca abria.

#### 4. A cedência virou relação, e o trânsito cede também

O faseamento por `initial_delay` quebrou 4 vezes seguidas (cada mudança de
traçado invalidava a janela). Agora o `Crosser` só sai quando há veículo a
menos de 900 px da faixa, e **segura** se houver alguém na zona de conflito —
sobreposição impossível por construção (`min_gap` 78 → **331 px**, carros de
163 px).

#### 1.15.1 Gate results (todos reexecutados depois de cada passo)

| Gate | Resultado |
|---|---|
| `gate_boot` Fase2 | **PARKED 46,9 s**, cedência 1,0 s, `min_gap 331 px`, 0 cones, **NEG_FRAMES 0** |
| `gate_boot` Fase3 | **PARKED 43,8 s**, 0 cones, NEG_FRAMES 0 |
| `gate_boot` Fase4 | **PARKED 27,2 s**, NEG_FRAMES 0 (antes: não estacionava) |
| `gate_lane` Fase2 / Fase3 | **100% dentro do box**, 0 violações nas duas |
| `gate_trail` | **PARKED 39,2 s**, `dist_centro 10,8`, NEG_FRAMES 0 |
| `gate_seeds` | **9/10** (Fase2 5/5, Fase3 4/5) |
| `ml/testar_ml.gd` | **ESTACIONADO 115,4 s** (a rede dirige na faixa sozinha, x≈1020) |
| `verify_scenes` / `ModulesCheck` | 12 scenes 0 failures / **fails=0** |

#### Dívida que resta (medida, com causa identificada)

- **Fase1**: vãos de 380 px contra 423 px exigidos; a grade fica sólida e
  nenhuma vaga é alcançável em nenhuma escala de carro testada. Reprojetar a
  cena. Hoje: `NOT_PARKED wp=4/21`, NEG_FRAMES 996 (pior que os 853 pré-existentes
  — a causa é a manobra em trilha, sem replay do gate para esta fase).
- **Fase5**: **89 vagas cobrindo x[−556..537] y[−194..247] com cada uma de
  245×466 px** — ou seja, as vagas se sobrepõem numa parede e o carro nasce
  dentro dela; e **zero obstáculos** na cena. Reprojetar a cena.
- **1 seed da Fase3** (de 5) encrava num bolsão do corredor estreito.
- **Não resolvido de propósito**: com a faixa colada na guia o carro às vezes
  encosta na calçada e a manobra trava; o termo do Stanley foi limitado a meia
  esterço e a margem da faixa a 0,5 raio varrido, o que resolve o caso comum mas
  não o canto.


### 1.16 Tudo chega na vaga: 9 níveis, 83 vagas, 44/45 spawns (2026-09-27)

O pedido: *"analisar e consertar tudo — principalmente o carro CHEGAR nas vagas"*,
manter a direção boa, atualizar o site e somar extras (mais níveis, mais carros,
som). O que segue é o que a bancada mediu, na ordem em que foi resolvido.

#### 1. As fases "quebradas" quebravam por ESCALA, não por rota

| fase | defeito medido | conserto |
|---|---|---|
| **Fase 1** | vãos de 380 px entre os carros estacionados contra **raio varrido 86 px** (carro em escala 1,5): a grade ficava sólida, 0 vaga alcançável | carro em escala **1,1** (raio varrido **63 px**), câmera 0,9 e um carro estacionado 32 px ao sul. **5/5 seeds**, boot 14–31 s |
| **Fase 4** | baias fora do eixo de entrada; o carro **sequestrava a FSM** para ALINHANDO com 12 waypoints pendentes | baias reposicionadas: **8/8 alcançáveis**, estaciona em 13,8 s |
| **Fase 5** | **89 vagas** de 245×466 px num passo de 38 px = parede de vagas sobrepostas, 0 alcançável | regenerada: **16 vagas** derivadas do tamanho do carro |
| **Fase 8** | 4/5 seeds: o carro encravava na quina de um **carro estacionado no canto do corredor de passagem** | o carro estacionado mudou de baia: **5/5**. Conserto de cena, nunca de portão |

#### 2. Nível virou DADO (e ganhou um portão de alcance)

- `tools/gen_level.py` (+`tools/specs/FaseN.json`) emite a cena — vagas, cones
  **sólidos** e o carro que cruza (com o `Sprite2D` filho em `rotation=1.5708`,
  AGENTS #29). Ele **aborta** se uma baia encostar em parede/na vizinha, se a
  celula do cone invadir a rota ou se a contagem de `[node` mudar na escrita
  (AGENTS #40). `tools/render_lot.py` desenha o piso do MESMO spec, então pintura
  e colisão não podem discordar.
- `tools/gate_reach.gd` monta a grade de ocupação que o carro monta, faz BFS do
  spawn e chama `Planejador.achar_rota()` para o ponto de preparação de CADA baia.
  Resultado: **Fase1 3/3, Fase2 4/4, Fase3 4/4, Fase4 8/8, Fase5 16/16, Fase6
  13/13, Fase7 18/18, Fase8 10/10, Fase9 7/7 = 83/83**.
- **Fase 8 (Cruzamento)** e **Fase 9 (Labirinto)** entram na lista: o cruzamento
  perpendicular num lote largo e as paredes internas escalonadas que forçam
  serpentina. `LevelRegistry` passou a 9 níveis (o HUD e as teclas **1–9** leem a
  lista, ninguém a repete).

#### 3. A escada de fuga (a classe "mandou andar e não andou")

O carro preso a 7 px/s com a rota apontando para a mesma parede não era detectado
no caminho do cérebro (o detector vivia dentro de `_processar_rota`, que o cérebro
não chama — AGENTS #37). O detector por DESLOCAMENTO subiu para o topo do
`_physics_process` e ganhou escada: **1–2** replanejar com inflação maior, **3** ré
de emergência, **4** desistir daquela vaga (`_vagas_recusadas`). Medições que
custaram caro:

- **Não é o deslocamento que zera a escada.** Entre dois engasgos o carro anda
  100–200 px e volta a encravar; com reset por deslocamento a escada degradava
  para "replanejar para sempre" (Fase1: 75 s, 1167 frames de ré, 0 vaga).
- **"Avançou o índice do waypoint" também NÃO é progresso.** A rota replanejada
  nasce NA CÉLULA DO CARRO, então os 4 primeiros pontos ficam a **0,02 px** um do
  outro: medido em trace, o índice andava 1→4 com o carro congelado e zerava a
  escada depois de CADA degrau — 50 s preso a 7,4 px/s, 0 ré, 0 vaga recusada. O
  reset agora exige `TRAVA_RESET_PX` de deslocamento real.
- **Sair do sólido não basta**: a ré tirava o carro de dentro do obstáculo
  (`inside` true → false) e ele voltava para o mesmo canto. Ganhou reorientação
  para a perna da rota (`_orientar_para_rota`) e **cautela** de 6 s a 55 px/s.
- O portão aprendeu a diferença: `NEG_FRAMES` (ré na direção) continua obrigado a
  **0**; a ré da recuperação sai em `REC_FRAMES` (com 25 frames de graça da
  inércia de saída). Sem isso um carro que se desencrava **e estaciona** era
  reprovado pelo próprio resgate.

#### 4. Extras da rodada

- **10 carros** (`VehicleCatalog`): 5 Kenney + 5 do time, com estilos de arte
  diferentes; o catálogo recorta cada textura para o MESMO box visual 70×121 e o
  `ModulesCheck` verifica o produto nos dez.
- **Áudio** procedural (`EngineAudio`): motor segue a velocidade, bump por
  impacto, silêncio em ESTACIONADO.
- **`tools/run_gates.sh`**: roda os portões em SEQUÊNCIA (AGENTS §14) e resume
  `PASS/FAIL` + `BOOT/CONES/NEG`.
- **`tools/export_site_images.py`**: agora DESCOBRE os pisos gerados
  (`gen_fase*.png`) em vez de listar dois na mão — Fase8/Fase9 apareceriam como
  imagem faltando.
- **Site**: o hero, os números, a galeria (4 pisos gerados + 10 carros), a
  máquina de estados, o roadmap e a nota de reprodutibilidade passaram a falar de
  `tools/`, não de scripts em `/tmp`.

#### 1.16.1 Gate results (2026-09-27, todas as medições com o código final)

| Gate | Resultado |
|---|---|
| `tools/run_gates.sh` (boot real, 9 fases) | **9/9 PASS**, 0 hit de cone, **NEG 0**, `REC 0` em oito fases (Fase1 21,6 s / 62 frames de ré de recuperação) |
| Fase2 / Fase3 boot | **46,9 s** (cedência 586,7 px) / **49,8 s** |
| Fase4..Fase9 boot | 13,8 / 7,2 / 8,0 / 12,7 / 7,1 / 13,2 s |
| `gate_seeds` (5 seeds × 9 níveis) | **44/45** (Fase1 5/5, Fase2 5/5, Fase3 4/5, Fase4..Fase9 5/5 cada) |
| `gate_reach` | **83/83 vagas alcançáveis** |
| `gate_lane` Fase2 / Fase3 | x mediano **978,4 / 888,3**, guia direita **222 / 361 px**, **100%** dentro do box, `swept_violations` **0** |
| `gate_trail` | **PARKED 39,2 s**, `dist_centro 10,8`, `neg_frames 0` |
| `ml/testar_ml.gd` | **ESTACIONADO 129,5 s** (fallback) |
| `verify_scenes` / `ModulesCheck` | **16 cenas, 0 falhas** / **fails=0** |

#### 1.16.2 O que sobra (medido, com causa identificada)

- **1 seed em 45 (Fase3 seed 2)** continua encravando. Causa medida em trace +
  diagnóstico de sobreposição: o carro chega a **22 px** da quina do `Obstaculo`
  do corredor e o que encosta é a **quina da carroceria girada** (~114 px do
  centro a 140°), maior que o círculo do raio varrido — o motor cinemático então
  não o tira de lá e ele escorrega a 7 px/s. **Não é inflação da grade**: com
  `inflar` 150 → 200 o A* desvia mais, mas o seed que falha apenas MUDOU de lugar
  (revertido). O conserto certo é a folga da rota enxergar a quina do obstáculo
  (sonda de FORMA, não de raio). **TENTADO em §1.17.2 e revertido**: a sonda de
  FORMA com o círculo do raio varrido conserta a Fase3 (4/5 → 5/5) mas quebra
  a Fase1 (5/5 → 3/5), porque o círculo circunscrito tem ~1,4× a largura da
  carroceria. O que resolve é sondar com a **caixa orientada**, que vê a quina e
  é mais justa — sessão dedicada, com o `gate_seeds` como juiz.
- **A rede neural ainda usa o fallback** na manobra final (129,5 s). O dataset v2
  tem 8 das 22 entradas constantes; o caminho é DAgger.

### 1.17 Release v0.4.0: a fronteira do `cte`, a sonda que eu rever­ti, e o alias que mudou (2026-09-27)

O objetivo era gerar a release. Ela virou duas correções, uma **tentativa
revertida** e uma armadilha de deploy — todas com gate como juiz.

#### 1.17.1 Fase8: ré indevida por 12 frames (CORRIGIDO, no ar)

`gate_boot` reprovou a Fase8 com `NEG_FRAMES=12` (12 frames de ré em `estado=0`).
O log apontava a linha: `[RE-BRAIN] cte=80 dist_alvo=381`. A causa era o guarda
da ré do cérebro em `AutonomousDriver.gd`:

```gdscript
and not (is_finite(context.cte) and context.cte < 80.0)
```

Com o carro parado em `cte = 80.0` **exatos** esse teste dá `not(false) = true` e
a ré dispara no caso que o **próprio comentário da linha** manda não reverter (o
carro colado na rota, mira deixada para trás). Era uma fronteira **aberta**.
Corrigido para `cte <= 80.0`.

| | antes | depois |
|---|---|---|
| Fase8 (5 boots, spawn aleatório) | 1 **FALHA** em 5 (~20%) | **5/5**, `NEG_FRAMES=0` |
| seed que falhava | `parked=false` ou ré indevida | 13,1 / 44,2 / 53,2 s, ré zero |

`TrailFollower.gd` **não** tinha o mesmo defeito: usa `cte > 90.0` direto, sem
negação, então não existe fronteira aberta ali.

#### 1.17.2 A sonda de FORMA: tentada, provada regressão, revertida

A §1.16.2 apontava o conserto certo da Fase3 seed 2 — *"a folga da rota
enxergar a quina do obstáculo (sonda de FORMA, não de raio)"*. Foi implementado
(`LaneOffset.wall_probe` com `body_radius`: o círculo do raio varrido, que
contém a carroceria em qualquer rotação).

**Funcionou na Fase3 e quebrou a Fase1.** Medido:

| | Fase1 | Fase3 | total |
|---|---|---|---|
| sonda de RAIO (original) | 5/5 | 4/5 | **9/10** |
| sonda de FORMA (círculo) | **3/5** | 5/5 | 8/10 |
| forma + margem corrigida | **3/5** | 5/5 | 8/10 |
| forma "adaptativa" | 3/5 | 5/5 | 8/10 |

Duas descobertas no caminho:

1. **A conta dupla era minha.** Com a sonda de forma, `fr` já desconta o corpo,
   e o `apply()` ainda subtraía `keep_clear * 1.5` por cima: a faixa perdia
   exatamente um raio varrido (189 px na Fase2) e o box caía de 100% → 87%/61%.
   Corrigido por um parâmetro `body_in_probe` (a margem vira só a margem de
   borda quando a sonda já contém o corpo).
2. **A versão "adaptativa" não mudou nada** (3/5 igual). A hipótese de que o
   problema fosse o `return 0` quando o corpo já encosta estava **errada**: a
   causa é o **círculo ser ~1,4× mais largo que a carroceria** (é a
   circunferência da caixa), e nos vãos de 380 px da Fase1 ele trava o
   deslocamento onde o raio via livre.

Depois de corrigida a conta dupla, a faixa ficou até **melhor** que a linha de
base (Fase2 `x_mediano` 1000 px, 191 px da guia, **100%** no box), mas a Fase1
continuava 3/5. **Revertido** (`05231fa`): a sonda de forma é perda líquida de
1 seed, e trocar um defeito conhecido por uma regressão minha não é um conserto.

**O caminho que resolve de verdade** é sondar com a **caixa orientada** (o
retângulo real, não a circunferência): vê a quina e é ~1,4× mais justo que o
círculo. É sessão dedicada, com `gate_seeds` como juiz — não passo de release.

#### 1.17.3 Placar da release v0.4.0 (tudo re-rodado no estado final)

| Gate | Resultado |
|---|---|
| `verify_scenes` | **16 cenas, 0 falhas** |
| `ModulesCheck` | **fails=0** |
| `gate_boot` 9 fases | **9/9**, `NEG_FRAMES=0` em todas |
| `gate_boot` Fase8 ×3 | **3/3**, `NEG_FRAMES=0` (o fix do `cte` sobrevive ao revert) |
| `gate_seeds` 5×9 | **44/45** (só a Fase3 seed 2, o defeito pré-existente) |
| `gate_reach` 9 níveis | **9/9 `GATE_REACH_OK`**, 83/83 vagas |
| `gate_lane` Fase2 / Fase3 | 978,4 / 888,3 px, **100%** no box, `swept_violations` 0 |
| `gate_trail` | **39,2 s**, `dist_centro` 10,8, `neg_frames 0` |
| `ml/testar_ml.gd` | **129,5 s** (fallback) — o número do site continua exato |

O revert devolviu a Fase1 a 5/5 **e** o box a 100%: os números do site não
precisaram mudar.

#### 1.17.4 O alias do site mudou e nada no repo dizia

Publicar deu um susto honesto: `estacionamento-automatico.vercel.app` responde
**404** na raiz. O projeto está no time
`murilohenriquemota935-1958s-projects`, então o alias de produção é **scoped**:
**https://site-pi-tan-51.vercel.app** (medido 200 em `/`, `/game/index.html`,
`/game/index.pck`, `/game/index.wasm`; `index.pck` = 6 648 520 B = o build
local; **0 headers `location`**, AGENTS #33).

A URL morta sobrevive em **mensagens de commit** (`aaaf037`), então o `grep`
acha e ela parece autoritativa. Duas armadilhas na mesma verificação: a URL por
deploy responde `302` para `vercel.com/sso-api` (Deployment Protection, **não**
site quebrado) e o `vercel ls` lista vários "Ready" — o certo é ler `Aliases`
no `vercel inspect`, nunca o primeiro URL da lista. Registrado no AGENTS §5.



### 1.18 A boca da vaga em espaço global (2026-09-28, issue #6 — AGENTS #17)

O defeito latente mais antigo do projeto: a boca (o trigger que anuncia
"preparar para entrar") era `-dir * 74` no espaço LOCAL, então a escala do
no a esticava — na Fase2 a banda ficava a **567 px** do centro (222 px
alem da entrada) com um retângulo de **766×73** (766 de espessura no eixo
de aproximação, 73 de largura). Nas geradas (nariz em ±90°) a boca ja
quase acertava (~28 px fora da entrada), mas com espessura 2x e largura
de baia inteira.

A boca agora e ancorada na ENTRADA da baia em espaço GLOBAL:
`offset_world = -dir * (meia_profundidade_escalada + 29)`, espessura
fixa de 28 px no mundo, largura proporcional (28 locais, a fresta do
design base) e copia propria do retângulo (`_forma_boca_propria`) porque
o resource do `.tscn` e compartilhado por todas as instâncias. A receita
literal "dividir 74 pela escala" foi rejeitada de proposito: 74 px do
CENTRO ficam DENTRO de toda baia escalada (depois do trigger da Area) e
mataria a banda de preparação. Na Fase2 a boca passou de 567 para
**373,7 px** do centro (entrada + 29).

| Gate | Resultado |
|---|---|
| `verify_scenes` / `ModulesCheck` | 16 cenas, 0 falhas / fails=0 |
| `gate_trail` Fase2 | **PARKED 39,4 s**, dist_centro 10,8, neg_frames 0 (ref 39,2) |
| `gate_boot` 9 fases | **9/9 PASS**, NEG_FRAMES=0 em todas (Fase1 8,1 / Fase2 45,7 / Fase3 49,8 / Fase4 13,5 / Fase5 7,2 / Fase6 16,6 / Fase7 9,5 / Fase8 11,7 / Fase9 10,5 s) |
| `gate_seeds` 5×2 | **9/10** = referência (só a Fase3 seed 2, o defeito pré-existente da sonda de raio, §1.17.2) |
| `ml/testar_ml.gd` | **ESTACIONADO 129,6 s** com fallback (ref 129,5) |

Fase6 apareceu 1 boot com `REC_FRAMES=59` (escada de fuga, 16,6 s):
3 reboots deram **3/3 PARKED em 6,0–21,5 s** — variação de spawn, não
regressão.

### 1.19 S0 — o placar de pilotagem, e a fragilidade de spawn que ele revelou (2026-09-29)

O plano do FAROL exige um placar ANTES de qualquer código (§3 S0): sem número
não há como provar que o carro entendeu mais. `tools/gate_drive.gd` mede, no
boot real, `|CTE| médio/p95`, % de saturação do volante, folga do casco,
replans, desvios, TTC e standstill.

**O gate não media nada comparável.** `FaseBase.posicao_aleatoria` é `true`
(AGENTS #28) e **nenhum gate fixava seed** — só o `gate_seeds` fixava
(`seed(9000+i)`). O spawn sorteado decide todas as métricas. Medido na Fase7,
mesmo commit, 3 processos:

| Spawn sorteado | `sat_pct` | `folga_min` | `t` |
|---|---|---|---|
| (744, 352) | 58,5 % | 12,4 | 33,4 s |
| (583, 383) | 77,4 % | 148,7 | 10,1 s |

Um A/B com sorteios diferentes mede o **sorteio**, não o código. Foi assim que
um `--all` de 9 fases deu `NOT_PARKED` na Fase7 **e** na Fase8 enquanto o
`gate_boot` (processo novo, outro sorteio) dava 7,1 s e 6,6 s nas mesmas duas.
Corrigido: `--seed` com **padrão 9000**, fixado **por fase** (`seed(9000 +
hash(nome_da_fase))`, senão num `--all` o sorteio da Fase8 depende de quantas
vezes o RNG foi consumido antes), a seed entra no JSON e uma seed diferente
entre `--ref` e a nova medição **reprova** em vez de atribuir ao código uma
diferença que veio do sorteio. O spawn também vai para o JSON: o placar sem a
entrada que o produziu não é reproduzível nem julgável. Verificado: 3 runs
seguidas da Fase7 deram saída **byte-idêntica**.

**O placar (seed 9000, `farol_mode=0`, `docs/baseline_drive.json`):**

| Fase | Resultado | `t` | `cte_med` | `cte_p95` | `sat` | `folga_min` | `ttc_min` | replans | spawn |
|---|---|---|---|---|---|---|---|---|---|
| Fase1 | PARKED | 12,4 | 18,1 | 35,3 | 26,1 % | 118,4 | 7,9 | 1 | (309, 103) |
| Fase2 | PARKED | 45,0 | 9,1 | 29,0 | 16,3 % | 78,7 | 1,4 | 0 | (-744, 1511) |
| Fase3 | PARKED | 64,3 | 13,6 | 46,9 | 34,1 % | 57,4 | 1,3 | 2 | (-983, 1490) |
| Fase4 | PARKED | 24,8 | 21,3 | 38,9 | **58,4 %** | 399,7 | 8,6 | 3 | (-600, -15) |
| Fase5 | PARKED | 7,6 | 18,9 | 31,0 | **73,3 %** | 316,4 | 4,3 | 1 | (462, 54) |
| Fase6 | PARKED | 14,8 | 17,7 | 51,3 | 38,6 % | **53,5** | 0,9 | 0 | (948, 458) |
| Fase7 | PARKED | 6,4 | 11,1 | 12,8 | 0,0 % | 228,1 | — | 0 | (72, -337) |
| Fase8 | PARKED | 7,7 | 5,2 | 8,4 | 21,1 % | 112,5 | 7,5 | 1 | (-562, 93) |
| Fase9 | **NOT_PARKED** | 75,0 | 18,0 | 46,9 | 3,4 % | **8,9** | 1,5 | **16** | (-797, -192) |

Média de saturação **30,1 %**, `desvios=0` em todas (esperado: o piloto local
só conta com o FAROL promovido).

**O achado que o placar pagou: o carro é frágil ao spawn.** Na seed 9000 a
**Fase9 não estaciona em 75 s** — e a falha é **reproduzível** (2 runs
idênticos: 16 replans, `parado_max` 6,9 s, `folga_min` 8,9 px = casco
encostando). O mesmo `gate_boot` com o spawn (-66, -271) estaciona em 8,5 s.
Somando os três sorteios medidos hoje, **três fases diferentes já falharam**
(Fase7 e Fase8 no sorteio livre, Fase9 na seed 9000), todas com o mesmo
assinatura: `folga_min` < 60 px, 15–16 replans e ~7 s parado. É a
escada de fuga (`AGENTS #43`) sendo consumida por um obstáculo que ela não
resolve — exatamente o defeito que o FAROL · PILOTO ataca (`blocked_ahead` →
replan com goal deslocado, em vez de dar ré).

A saturação média de 30,1 % (73,3 % na Fase5) é a tradução numérica do
"burro" do usuário: o volante no batente não é falta de tentativa, é a
**lacuna entre a rota e a roda** que o plano §1 diagnostica.

### 1.21 The right-hand lane produced routes the car could not drive (2026-09-30)

The full-gate sweep on 2026-09-30 (10 levels: `gate_reach` + `run_gates.sh` +
`gate_drive` + `gate_seeds` + `gate_lane` + `gate_trail` + ML) found **one
regression and one rule that was weaker than documented**.

**The regression: Fase3 seed 2 never parked.** `gate_seeds` printed
`parked=false t=80.0s parado=40.1s` — the car sat at (451, -637) for 40 s,
reversed, drove forward 2 s, wedged again, forever. `NEG_FRAMES` stayed 0 and
`estado` stayed `SEEKING`, so no existing gate could see it. A/B on a worktree
at `6e4b9a7` (the commit before the FAROL series):

| Code | Fase3 scene | 5 seeds |
|---|---|---|
| `6e4b9a7` | as of `6e4b9a7` (trail, `keep_right_shift` default) | **5/5** (seed 2 took 75,0 s) |
| `6e4b9a7` | as of HEAD (autonomous, shift 900, `vaga_prioritaria`) | **0/5** |
| HEAD | as of HEAD | 4/5 |

So the trigger is `8b0a48a` ("fix the SCENE, not the shared park gate"), which
rewrote `Fase3.tscn` and switched it from trail to autonomous with
`keep_right_shift = 900`. The proximate cause is **not** the scene: it is the
lane rule.

**The rule was weaker than AGENTS #18 claims.** That entry states the safety
invariant `free_r' >= keep_clear` holds *by construction*. It holds on the axis
the shift was measured on (the route normal) and **nowhere else**. Measuring
each stage of the pipeline on the failing run (16 rays, layer 2, swept radius
115 px):

| Stage | min clearance at the VERTICES | min clearance along the SEGMENTS |
|---|---|---|
| raw A* | 213,4 px | 213,4 px |
| Chaikin + resample | 213,4 px | 213,4 px |
| after the right-hand shift | 73,3 px | **0,8 px** |
| after `_garantir_folga` | 104,2 px | **0,8 px** |

The shifted polyline passed **0,8 px** from the corner of the `Obstaculo` at
(247, -781) — the car was asked to drive its own route through a wall, because
two vertices that are each 121 px clear have a *segment* that cuts the convex
corner between them. `_garantir_folga` only ever looked at vertices, so it
repaired 73 → 104 px and never saw the segment. The car then pressed its nose
into that corner, and the escape ladder (`AGENTS #43`) cycled replan → reverse
→ the same corner forever: each reverse gave it 30 px of "real progress", and
that is what resets the ladder.

**The fix** (`scripts/Carro.gd`): the guarantee now runs over the swept
corridor, not the vertices. For each leg it samples every `passo_rota * 0.4`
px and asks `_casco_preso()`: for each of 12 wall directions, the distance from
the centre to the first wall **minus the distance the car BODY reaches in that
direction** (the hull is a 176×148 rectangle, so its reach is 74–88 px — *not*
the 115 px circumscribed circle). When a leg is inside that reach, the point is
pulled toward the planner's line by the **smallest** amount that clears it, by
bisection. Two earlier variants were measured and rejected: reverting the whole
leg cost Fase6 ten seconds and brought the car 19 px closer to an obstacle;
sliding the point sideways instead cost Fase10 `cte_p95` 44 → 97 px.

**Fase10's lane was the level-level cause** (its corridor between the two
staggered refuges cannot hold a 300 px lane): sweeping `keep_right_shift` with
the new `gate_drive --shift=` gave 300 → 23,8 s / `cte_p95` 48,0 / `folga` 91,
200 → 19,8 s / 24,2 / 133, **120 → 12,6 s / 19,9 / 217**. The spec now declares
120 (the cost: the car sits ~156 px left of where it sat, still ~505 px from
the right guide in that 1000 px corridor). **Fase6's cones** were the other
half: at (±1050, 0) they sat 110 px inside the sidewalk, and the car passed
48–57 px from a solid cone on 1 of 3 free spawns. They now sit on
`CalcadaOeste`/`CalcadaLeste` (±1180), where the `inflar` band already seals the
area, so no route can come near (AGENTS #19's cheapest placement).

**After the fix — the whole board, all green:**

| Gate | Result |
|---|---|
| `ModulesCheck` | `fails=0` |
| `verify_scenes` | `scenes=17 failures=0` |
| `gate_chart --all` | 10 levels, `dif_sym=0` |
| `gate_reach` | 10/10 levels (Fase6 10/13 bays) |
| `run_gates.sh --fases=Fase1..Fase10` | **10/10 PARKED**, `CONES hits=0`, `NEG_FRAMES=0` |
| `gate_seeds` (5 seeds × **10** levels) | **50/50 parked** |
| `gate_drive --all` | `GATE_DRIVE_OK` — 10/10 PARKED, `docs/farol_drive.json` |
| `gate_lane` Fase2/Fase3 | `GATE_LANE_OK`, `min_free_r` 145,2 / 118,8 px, 0 violations |
| `gate_trail` (Fase2 forced trail) | `PARKED 39,5 s`, `dist_centro 10,8`, `neg_frames=0` |
| `ml/testar_ml.gd` | `ESTACIONADO 68,1 s` (`usou_fallback=true`) |
| `gate_ml_probe` (game vs site MLP) | `pior_diff 4,0e-13`, `GATE_ML_OK` |

Fase6 and Fase10 got **better than the pre-fix board** on every metric, and the
cone scrapes disappeared from both boots (Fase10: 27,1 s → 6,4 s,
`ray_finite_while_passing` 269 → 0, `min_gap` 34,3 → 272,4 px, `REC_FRAMES`
68 → 0).

**Still open, measured, not fixed:** `gate_lane` on Fase2 is deterministic
(3 identical runs) and reports `x_mediano=745,7`, **459 px from the right
guide**, 21,4 % inside the box the user drew (832..1206). AGENTS #34 records
`x=996`, 206 px, **100 %** — that number came from a `/tmp` script with a
different sampling rule and is **not reproducible with the versioned gate**. The
route itself does reach x ≈ 1001 (the wall is at 1206), so the lane exists; the
car spends much of the run on legs that are not aisle legs. This is a tuning
question about `LaneOffset`'s open-aisle branch (`LANE_OPEN_EDGE` →
`RIGHT_HALF_BIAS`), not a regression: the numbers are identical before and
after this fix.

### 1.22 The A* cost lane is NOT a drop-in for the post-hoc shift (2026-10-01)

§1.21 fixed the invariant. The obvious next move — the FAROL · S2 direction —
is to move the right-hand rule from the post-hoc shift INTO the A* cost
(`lane_cost_mode = 1`, the `Chart`), because that is what the planning
literature does (Ferguson & Likhachev's *constrained cost map*: staying in the
desired lane is a **soft cost** over the whole corridor, not an offset applied
afterwards). Measured per level with `gate_drive --farol= --lane=` and the
car's x tracked over the whole boot:

| Fase | config | `t` | `cte_p95` | `sat` | `x_max` reached | time in the user's box |
|---|---|---|---|---|---|---|
| Fase2 | post-hoc shift (legacy) | 45,0 s | 29,1 | 16,1 % | **1003** | **22 %** |
| Fase2 | lane as A* cost | **31,5 s** | 25,3 | **9,3 %** | 383 | **0 %** |
| Fase3 | post-hoc shift (legacy) | 60,0 s | 24,0 | 33,8 % | **1019** | 11 % |
| Fase3 | lane as A* cost | **29,3 s** | 24,1 | **5,9 %** | 406 | **0 %** |

**The driving metrics are much better and the lane is much worse.** With the
cost the route stops using the eastern corridor altogether (x range
[-746, 364] in Fase2) — it takes the short diagonal to the bay. So `w_faixa`
does not yet buy "keep right", it buys "go straight", and promoting it would
have taken the user's complaint ("dirige no meio") from 22 % to **0 %** inside
the box. **Not promoted** — the promotion was applied, measured and reverted.

Two lessons worth keeping:

1. **A verdict from 9 samples is not a verdict.** The first attempt measured
   `x_mediano = 994,6`, 55,6 % inside the box — which is exactly what AGENTS
   #34 claims and looked like the fix. It was 9 samples out of a 32 s window
   (the gate only counts frames inside a corridor ≥ 1000 px wide), from a run
   whose shell quoting had already mangled the flags. `tools/gate_lane.gd` now
   **FAILS below 20 samples** instead of printing a median of a handful.
2. **Per-level data, never a global switch.** The same `--farol=1 --lane=1`
   run improved Fase2/3/4 (t −33 %, sat −70 %) and **hurt** Fase5, Fase8 and
   Fase10 (`cte_p95` 8 → 19 and 20 → 49, `sat` 21 → 47 %): in the generated
   levels the lane cost runs the route past the parked cars. This is the
   promotion rule of the plan (one level at a time, with the board as the
   referee), and `--farol=`/`--lane=` on both gates is how the next person runs
   it.

**What is left, precisely:** the post-hoc shift can only move the lane so far
before the route stops fitting the car (§1.21: 260/400/900 all wedge in
Fase3), and the A* cost currently abandons the corridor. The missing piece is
`w_faixa` in `FarolSpec` tuned so the corridor is worth more than the diagonal
— the plan's own diagnosis, now with the two ends of the trade-off measured.

### 1.23 Two bugs in the lane cost, and what "rua direita" actually means (2026-10-01)

§1.22 rejected the lane-as-cost because it sent the car away from the eastern
street. Two real bugs turned up while chasing that, both of which made the
weight `w_faixa` **unable to reorder anything**:

1. **`alvo` was derived from the cell's own `fr`** (`alvo = fr - band` /
   `fr - largura * 0.25`), so `(alvo - fr)` was negative for EVERY cell and the
   right-half penalty was identically **zero**. Measured on Fase2,
   `w_faixa` from 1.8 to 40 gave the same route to the metre (x_med 272→277).
   `alvo` is now the lane target **as a distance from the right guide** (the
   same number `LaneOffset` leaves between lane and guide) and the penalty is
   `|alvo - fr|` — on **both** sides of the target, because measuring only "too
   close to the wall" leaves everything from the target to the middle free.
2. **`Chart.dominante_eixo` was mirrored on x.** The four sweeps in
   `_varrer_direcoes` accumulate the distance to solid cells at *smaller*
   coordinates, so index 0 reported the distance toward −x while
   `dominante_eixo(+x)` returned 0. `Route.custo_celula` therefore read the lane
   off the **LEFT** side of a northbound corridor. y was correct, which is why
   the bug only showed on vertical legs — and why the lane looked plausible.

Both are pinned in `ModulesCheck` with a synthetic corridor Chart
(`Lane.alvo_mais_barato_que_o_meio/que_a_parede`, `Lane.meio_mais_barato_que_a_esquerda`),
and **all three mutations were run**: mirrored axis → 3 FAIL, dead penalty → 2
FAIL, one-sided penalty → 1 FAIL. The ordering they now enforce, measured on a
1000 px corridor: target **1.16** < wall hug 2.60 < middle 2.77 < left half
3.40.

**But promoting it to Fase2 is still wrong, and now for a reason that is not a
bug.** With the cost working, the car *still* does not enter the eastern street
(`x_max` 431, 0 % inside the box, at any `w_faixa`): the street is not on the
way. The bay is at x = −135 and the car starts at x = −742; driving to x ≈ 1000
and back is a **detour**, and a per-cell weight cannot buy a detour that costs
distance. What actually puts the car on that street is the **post-hoc shift**,
which displaces the path sideways by up to 900 px. So the shift stays, and
`lane_cost_mode = 1` remains Fase9's promotion.

**What the lane actually measures, with the right instrument.** `tools/lane_track.gd`
added in §1.22 counts boot time in a box, and that number is a poor proxy: the
car *must* leave the eastern street to reach a bay 700 px west of it. Measuring
the thing the rule is about:

| pergunta | como | resultado |
|---|---|---|
| a rota encosta na guia leste? | `folga_dir` dos pontos da rota na rua leste | mediana **190 px** = `1.5 × raio varrido` (o mínimo seguro), 17 de 29 pontos dentro do box |
| o carro segue a faixa? | `Carro._cte_para_rota()` no boot inteiro | média **17,3 px**; os piores momentos (257 px) são todos na manobra final (`estado = ALINHANDO`) |
| o carro usa a rua? | `lane_track` | `x_max` = **1003** (a guia está em 1206), entrada pela corner sul-leste |

Ou seja: **a faixa está certa**, e o número de "100% dentro do box" do §34 nunca
existiu. O que a varredura entregou foram dois bugs reais no caminho do custo,
um portão novo que recusa julgar uma faixa com menos de 20 amostras, e a
correção do número publicado.

### 1.24 Duaslevels com baias mortas, e a invariante que faltava no gerador (2026-10-01)

A pendência "3 baias inalcançáveis na Fase6" era a ponta: **o gerador não tinha a
invariante**. Ele abortava se a baia *encostava* numa parede, mas o planejador
marca solida toda célula dentro de `raio varrido + 1.5 células` da parede — e
uma baia a 110 px da guia tem o **centro** dentro dessa faixa. Duas variantes do
mesmo defeito foram measure e corrigidas:

| nível | defeito | como foi discovered |
|---|---|---|
| **Fase6** | 3 de 13 baias inalcançáveis (`N_8`, `S_7`, `S_8`): os **espigões** de 221 px de altura fechavam a faixa com a inflação de 118 px, e o ponto de preparo da fileira ficava dentro da faixa dos espigões | `gate_reach` (10/13) + a nova invariante |
| **Fase9** | a prep de `N_4` ficava a **10 px DENTRO** do `MuroLeste` — o planejador só salvava arredondando o objetivo para a célula livre, e o gate_reach chamava a baia de alcançável | a nova invariante (o gate_reach sozinho não via) |

**A invariante nova** (`tools/gen_level.py`): o **centro** da baia e o **ponto de
preparo** precisam de `raio varrido + 2,5 células` de qualquer parede — exceto a
parede contra a qual a fileira nasce (ali o carro encosta a traseira de
propósito, como numa vaga de verdade). A margem de 2,5 células (e não 1,5) é o
arrendondamento de célula: um centro a 103 px pode cair em célula sólida.

**A correção da Fase6 preservou a dificuldade e MELHOROU a pilotagem.** Os
espigões de 221 px viraram **meios-fios de 40×60 px** nos vãos entre baias (passo
285,7 px): ainda obrigam a mudar de faixa, e deixam 381 px de faixa dirigível
(o carro precisa de 2×103 = 206 px). O destino é a place where the car drives
*worse* without them:

| Fase6 | antes | depois |
|---|---|---|
| baias alcançáveis | **10/13** | **13/13** |
| `t` | 6,4 s | 7,5 s |
| `cte_med` | 12,6 px | **3,8 px** |
| `cte_p95` | 17,2 px | **7,6 px** |
| `sat` | 0 % | 0 % |
| `folga_min` | 294,7 px | **312,6 px** |

Ou seja: a faixa aberta e sem guia fazia o carro *pior*, não melhor.

**E um bug do piloto (Fase9), encontrado de passagem**: com `farol_mode >= 2` o
`Mooring` assumia o volante a 200 px da vaga, ignorava o waypoint de preparo e ia
direto contra o meio-fio das costas — 25 s em `ALINHAR` a 0,6 px/s, porque o
Locomotion recusa girar abaixo de 1 px/s e a rampa que o Mooring exige para girar
em parado estava bloqueada pelos raios da frente. Agora `_no_ponto_de_preparo()`
só entrega o volante ao Mooring quando o carro chegou ao ponto de preparo; antes
disso o `ALINHANDO` legado conduz pela rota (o caminho que os 9 níveis
históricos mediram). A seed 9003 da Fase9 passou de **não estaciona em 80 s** para
**6,0 s**.

### 1.25 Duas correções que eu aplicuei e reverti (a sorte de medir)

Duas mudanças de comportamento compartilhado pareceram certas e **foram
revertidas** porque a matriz de seeds reprovou:

1. **Margem de spawn = `inflar` do planejador** (era 50 px fixos): com 50 px o carro
   pode nascer com o nariz dentro da vaga (Fase9 seed 9003). Com a margem nova a
   Fase9 seed 3 passou, **mas** a Fase8 e a Fase10 passaram a nascer dentro do
   bolso do chicane e a falhar (50 s parado cada). Revertido.
2. **Escada de fuga zera por aproximação, não por deslocamento**: dentro de um
   bolso o carro dá ~50 px de ré por ciclo, o que contava como progresso. Troquei
   por "chegou mais perto do alvo" e o sintoma mudou de nome — o carro passou a
   **recusar todas as vagas** (`_recusar_vaga_atual` até `_sem_vagas`) e parar, em
   vez de replanejar para sempre. Nenhum dos dois é o conserto; o que falta é o
   **degrau que tira o carro do bolso** (o §43 tem "replanejar → ré → largar a
   vaga" e não tem "sair do bolso"). Revertido, e registrado aqui como pendência.

### 1.26 A escada de fuga ganhou o degrau que faltava: SAIR DO BOLSO (2026-10-01)

O §1.25 deixou claro o buraco: a escada tem "replanejar → ré → largar a vaga", e
**nenhum dos três tira o carro de um bolsão** — as duas primeiras devolvem o
carro ao mesmo ponto e a terceira esgota o orçamento de desistências sem mover
um pixel. Medido na Fase8 seed 9000: 66 s parado, `wp=0/39`, a escada recomeçando
a cada ~30 px de ré.

**O degrau novo** (`Carro._sair_do_bolso` + `Planejador.achar_celula_espacosa`):
no 4º degrau, em vez de recusar a vaga, o carro planeja uma rota para **a célula
livre mais espaçosa num raio**, com mais folga que a sua. O planejador lê a
folga **real** (12 raios contra o layer 2, o mesmo que a grade usa para decidir
solidez) e só aceita um destino que o A* sabe alcançar daqui. Uma vez por
tentativa: `_bolso_resolvido` reabre no reset por progresso real, para um bolso
*diferente* poder ser escapado.

**O degrau só dispara quando o carro está DE FATO sem espaço.** A primeira
versão disparava em qualquer engravamento de rotina e custou **28 s na Fase2**
(`t` 44,9 → 72,9 s, `cte_med` 9,1 → 21,4 px): o desvio era um custo, não um
resgate. Com a guarda `_sem_espaco_ao_redor()` (folga real em volta < 2× o raio
varrido — num corredor normal são centenas de px), o degrau só entra onde
manobrar é impossível.

**Verificação**: seeds **50/50** nas 10 fases · `gate_drive` **GATE_DRIVE_OK**
(sem regressão em nenhuma métrica) · boots 10/10 · `ModulesCheck fails=0` ·
`verify_scenes 17/0`.

**A margem de spawn, re-testada com o degrau novo** (medido, ainda em aberto):
com a margem do `inflar` a **Fase8 seed 9000 passou a estacionar em 42,0 s**
(antes: 80 s sem estacionar) — o degrau do bolso é o que faltava. A **Fase10
continua falhando**, e a causa é geometria: com a margem o carro nasce em
(-46, 48), no corredor entre os dois refúgios escalonados, e a 177 px de folga
real ele fica com o nariz contra um `Estacionado` da fileira sul
(`RayFrente* = Estacionado_S_3`), cycling recovery até (14, -197) aos 80 s. Não
é bolsão (folga 177 px > 2× o raio varrido), então o degrau corretamente não
dispara: é o corredor central da Fase10 que é apertado demais para nascer E
atravessar.

**O que fica em aberto (medido, não resolvido)**: a margem de spawn. Com 50 px o
carro pode nascer com o nariz dentro de uma vaga (Fase9 seed 9003: 25 s em
ALINHAR a 0,6 px/s — agora contornado pela guarda do Mooring, §1.24). Com a
margem do `inflar` a Fase8 e a Fase10 passam a nascer dentro do bolso do chicane e
não estacionam em 80 s. **O conserto não é a margem: é a Fase8 não ter bolsões
que uma diferença de 30 px de spawn alcance** — o degrau novo evita o laço
infinito, mas o carro ainda gasta os 80 s saindo e voltando. Isso é geometria de
nível (`tools/specs/Fase8.json`), e é o candidato natural a seguir.

## 2. Blockers for the deliverable

### B1/B2 — autonomous parking in Fase2 + Fase3 — **FIXED** (§1.5: 10/10 seeds)

Final fix (in addition to §1.3/§1.4): the AUTONOMOUS align phase now uses the
trail path's converge gate — inside `_perto_da_vaga_para_snap()` (< 80 px) the
velocity is zeroed and the car glides/rotates to the target with a lerp, and
PARKED is only marked at the centre (< 12 px) and aligned — plus the
continuous approach profile (`_velocidade_aproximacao_vaga`) instead of
`0.6 * sensor_speed`, which used to arrive at ~96 px/s and overshoot the bay
centre. Original diagnosis (kept for the record):
Evidence (`/tmp/f3_auto.gd --fase=Fase2 --debug=1`): car stops at
`(-94, -330)`, `dist_vaga = 60 px`, `yaw_err = 0.72 rad`, `dentro = false`,
`NEAR(1)` (nothing within 140 px), `cmdhi = 60/60 frames`,
`moved ≈ 4.2 px/s` → it **oscillates in place** exactly at the
`absf(erro) > 0.7` knife-edge of `_processar_alinhando()` (reverse-with-lock
below, forward above): no hysteresis, and rotation only happens while moving.
Why is the error 0.72 at all? `_penalidade_rumo()` accepts route ends up to
100° off the bay nose, so the A* route arrives ~41° askew; a forward-only
parking (locked A2) cannot close that from inside a 314 px-deep bay.
Options: (A) tighten the planner gate + make the route end on the nose axis
(prep point) so the car arrives aligned; (B) give the autonomous align phase
a real maneuver (hysteresis + rotate-in-place when inside the spot, like
`_processar_alinhando_trilha()`); (C) both.

### B2 — "100 % inside" gate vs. scaled bays
`_esta_100_dentro_da_vaga()` tests the car's rotated hull corners against
`Area.size * vaga.scale`; with the car sideways (nose north) it pokes ~12 px
out of the 314 px depth and reports false, so the park gate can never fire.
Also AGENTS #17 is still latent: `Vaga._atualizar_boca_pos()` writes
`-dir * 74.0` in LOCAL space, so scaled bays put the mouth band ~567 px into
the aisle (this is what fed B1's hijack). Fixing #17 shifts trigger timing in
every level → needs its own per-level validation.

### B3 — ML v2 regressed
`ml/testar_ml.gd` = 85.5 s **with fallback** (v1 was 49.9 s without). The
recorded teacher is fine (22 inputs, val_mse 0.00025); the policy does not
close the loop alone. Order matters: freeze the deterministic brain first
(B1/B2), then re-train with it as teacher + safety shield (imitation
learning inside a verified controller), then DAgger/GA.

### B4 — Pre-existing, NOT regressions (AGENTS #7)
Fase1 stalls in `BUSCANDO` (obstacle on its route, wp 5/21); Fase4 hijacks to
`ALINHANDO` mid-route (12 waypoints left). Their route/trigger geometry, not
shared park gates — do not "fix" them by loosening the shared gates.

### B5 — F5 crosser
Best known state 4/5 seeds (stop threshold reverted to 140 px today). Crosser
has **no sprite** (invisible). Gate per `docs/tasks_autonomy.md`: 5/5 avoids,
`neg_frames = 0`. Superseded in part by §1.10.3: the yield is now a real
hysteresis latch (`CrosserGate`) instead of a bare threshold, and the
**Fase2** crosser — which the right-hand lane rule had orphaned 260 px west of
the driving line — is now a real perpendicular crossing of the lane, so the
gate is exercised on a real boot again (latch, standstill, release by
distance, +2.1 s to the park time; yield in 3/5 random-spawn seeds). F5's own
crosser (invisible sprite, no `_process` yield evidence) is still ungated —
that needs F5 to instance the same crossing geometry before B5 can be closed
at 5/5.

### B6 — More parking lots (user request)
Current art in `estacionamento/`: `parking_lot.jpg`, `parking_lot2.svg`,
`parking_lot3.svg`, `parking_lot4.jpg`, `Parkinglot5.jpeg` (5 images = the 5
current fases). `resources/RoadGraph.tres` is a hand-made lane graph for the
Parkinglot5 layout. Need a decision on how new layouts are produced
(see §4 Q1): remix/reuse the existing art, import new art supplied by the
user, or generate layouts procedurally with the existing gate as validation.

### B7 — Delivery
`export_presets.cfg` exists and the repo root already has
`Estacionamento Autônomo.{pck,sh,x86_64}` (build artifacts, per AGENTS §2.1
to be kept unversioned). Need a decision on the delivery target (desktop
Linux/Windows build, HTML5/web, or repo+site only) and on the acceptance
evidence (which levels must park, how many seeds).

### B8 — Legacy cleanup / F6
`scripts/Carro.gd` is 2313 lines (god object: sensors + FSM + locomotion +
ML + trail + parking gates). F6 (legacy cut + honest review of the task
files) was never done. `summary.md` run log stops at F4.

### B9 — Site (S2/S3 of `docs/tasks_site.md`)
Static PT-BR site exists and serves (HTTP 200). Missing: `exclude_filter` in
the export (Godot imported `site/assets/icon.svg` → generated `.import`),
screenshots, publish.

## 3. Housekeeping
- `docs/`, `site/`, `src/world/Crosser.gd`, `ml/modelo/pesos_v1_backup.json`,
  `summary.md` are **untracked**; `ml/`, `scripts/`, `src/`, `scenes/` have
  uncommitted changes. Nothing committed this session.
- New rules: AGENTS §0 (ask before assuming) and AGENTS §14 (bounded `/tmp`
  traces, no long custom sims in the workspace).

## 4. Decisions taken (2026-09-24)

- **Q1 (more lots): reuse the existing art, procedurally.** New levels are
  generated by composing/re-cutting the five floor images already in
  `estacionamento/` (bay, aisle, sidewalks, Line2D routes) and validated with
  the same headless gate. No new art needed for the first batch.
- **Q2 (delivery): web build + published site.** HTML5 export served from
  `site/`, on top of the desktop export preset that already exists.
- **Q3 (next): finish B1/B2 first** (autonomous parking in Fase2 + Fase3),
  then move on.

## 5. Previous open questions (answered above)

- **Q1 (more lots)** where do new layouts come from: reuse/compose the
  existing floor art (cheap, procedural variants), new art supplied by the
  user (I build the image→level pipeline), or the hand-made `RoadGraph.tres`
  route as a template?
- **Q2 (delivery)** what is the deliverable artifact: desktop export
  (Linux/Windows), web export, or the running repo + site? And what is the
  acceptance gate: Fase2+Fase3 autonomous parking only (locked A1) or all 5
  levels, over how many seeds (`docs/tasks_autonomy.md` D9 says 5/5)?
- **Q3 (next)** after B1/B2 (finish the autonomous park), what comes next:
  more lots (B6), the ML policy (B3), F5 (B5), or the legacy cut (B8)?
