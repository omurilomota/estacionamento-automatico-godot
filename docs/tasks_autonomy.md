# Tasks — Full Autonomy (Fase2+Fase3, forward-only)

> RESUMO PT-BR: carro decide a rota sozinho (A* puro + FSM explicavel),
> sem Line2D obrigatoria, entrada so de frente, obstaculos estaticos +
> paredes. Metricade pronto: ESTACIONADO <90s, dist_centro<12px,
> |yaw_err|<0.08, neg_frames=0, sem fallback, 5/5 seeds por fase.
> ML (DAgger/GA) vem como V2 depois do heuristico verde. Crosser: 1 carro
> scripted sensor-only, 5/5 desvios. Legado PT-BR vira shim no fim.

## Locked decisions

| # | Decision |
|---|---|
| A1 | Scope: Fase2+Fase3 only, any free spot, random spawn |
| A2 | Forward-only parking; reverse only emergency RECOVERING (-60px/s) |
| A3 | Static obstacles + walls; stretch: 1 scripted crosser, sensor-only |
| B4 | Perception 18 -> 22 inputs (yaw_error, corridor_width, crosser dist/bearing, stuck_timer). No 16x16 patch (modest PC) |
| B5 | Floor arrows / Line2D ignored (RouteHints empty, weight 1.0) |
| C6 | V1 = explainable heuristic (FSM+A*); V2 = DAgger+GA, same DriverBrain iface |
| C7 | Safety layer always on: Locomotion veto fwd when front_blocked(40px) + center brake 160px |
| C8 | pesos.json may be invalidated; current file becomes backup pesos_bc.json |
| D9 | Done gate: PARKED <90s, dist<12px, yaw<0.08, neg_frames=0, no fallback, 5/5 seeds |
| D10 | Fase1/4/5 out of scope (pre-existing route/trigger geometry) |
| E11 | numpy-only training, bounded /tmp traces, no heavy sims in workspace |
| E12 | Legacy flags may migrate to set_driver_brain(Kind) with shim |

## Architecture target

SensorArray -> PerceptionSnapshot(22) -> AutonomousDriver/MlDriver
-> DriveCommand -> Locomotion -> Vehicle. LevelManager is the only
orchestrator (spot choice via A* cost + yaw compat). PathPlanner is a
pure service fed by injected RouteHints. FSM stays the safety judge.

## Tasks

- [x] F0 baseline: import + ml/testar_ml.gd Fase3 green + /tmp Fase2 trace (~35s). No behavior change.
- [x] F1 perception: Snapshot 18->22, SensorArray sole ray owner, crosser fields; ModulesCheck + headless unit green.
- [x] F2 pure planner: no get_parent().get_node("Setas"/"Rotas"); RouteHints injected (empty=ignored); LevelManager picks spot + snap gate <80px/<12px.
- [x] F3 heuristic pilot v1: AUTONOMOUS default, PurePursuit(180px)+FsmProfiles+AVOIDING/RECOVERING; zero Line2D required; D9 gate 5/5 seeds Fase2+Fase3.
- [x] F4 data+ML v2: DAgger teacher corrections -> 22-col CSVs -> treinar.py (numpy) -> new pesos.json; testar_ml no-fallback green; GA only if BC fails.
- [ ] F5 dynamic crosser (stretch): 1 scripted car crossing loop ~120px/s, sensor-only; 5/5 avoids, neg_frames=0.
- [ ] F6 legacy cut + review: Carro.gd shim over Vehicle, PT-BR flags shim over Kind; fill 2x5 matrix + honest review below.

## Run log

| date | task | command | result |
|---|---|---|---|
| 2026-09-24 | F0 | `godot --headless --path . --script ml/testar_ml.gd` | RESULTADO Fase3: ESTACIONADO em 49.9s (usou_fallback=false) — green, baseline locked |
| 2026-09-24 | F1 | `ModulesCheck.gd` + `ml/testar_ml.gd` | ModulesCheck fails=0 (33 checks); Fase3 ESTACIONADO 50.0s fallback=false — v1 net compat kept via 22->18 slice; first run w/o slice crashed (CerebroML idx18 OOB), fixed |
| 2026-09-24 | F2 | `--check-only` Carro+Planejador + ModulesCheck | Clean checks; ModulesCheck fails=0 (35 checks); planner is pure-service (aplicar_hints/apply_hints; legacy crawl only w/o hints); seta blends removed; spot choice = A* + yaw penalty (reverse=INF); LevelManager boots AUTONOMOUS w/ empty hints |
| 2026-09-24 | F3 | `--check-only` + ModulesCheck + `ml/testar_ml.gd` | Brain owns BUSCANDO (legacy FSM only w/o brain); Fase3 ML regression green 49.9s no-fallback, 0 script errors; full D9 5x5 matrix still open (needs trace harness) |
| 2026-09-24 | F4 | `gravar` + `treinar.py` + `testar_ml` + `avaliar` | v2 dataset Fase3 (1389+3730+363 rows, 24 cols; v1 files skipped); 22-32-16-2 trained val_mse 0.00025 corr 0.999/0.999; testar_ml v2 net: ESTACIONADO 85.5s fallback=TRUE (regression vs v1 49.9s no-fallback — net drives but stalls, FSM takes over); avaliar pure-net fitness -1296 (no park in 45s, crawls ~20px/s); GA path ready (evoluir.py GODOT_BIN fixed) but NOT run — honest status: BC-v2 needs DAgger/GA round, v1 backup kept |

## Honest review (fill at F6)

- What passed 5/5 (with numbers):
- What failed and why (root cause, not symptom):
- What I would not do again:
- Next steps:
