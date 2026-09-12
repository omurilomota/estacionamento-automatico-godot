# Autonomous Parking — Godot 4.x top-down 2D simulation.
# The car drives with RayCast2D sensors + a finite-state mission brain
# (SEEKING / AVOIDING / ALIGNING / PARKED / RECOVERING), planned over an
# A* occupancy grid (`src/navigation/`).

## Objective

Build an autonomous agent: the car is NOT on a fixed script — it reads
the world in real time (sensors) and decides when to seek a spot, avoid
a hazard and align to park. Path planning runs on A* (`PathPlanner`).

## Team & ownership

| Member  | Role               | Owns |
| ------- | ------------------ | ---- |
| Gian    | Designer / Artist  | Top-down sprites, spot (free/occupied), obstacles, walls, UI. Transparent PNGs, one scale (e.g. 64x64 or 128x128). |
| Murilo  | Programmer (Brain) | Vehicle scene + `src/vehicle/*`: locomotion (CharacterBody2D), sensor array, state machine (SEEKING, AVOIDING, ALIGNING, PARKED, RECOVERING), navigation. |
| Matheus | Programmer (World) | Level scene, `ParkingSpot` logic, HUD, waypoints. |

## Architecture (decoupled, English)

```
src/
  core/        VehicleState, LevelRegistry   # enums, level list, labels
  vehicle/     Vehicle, Locomotion*, SensorArray*, brains/*
  navigation/  PathPlanner, OccupancyGrid*, RouteHints
  parking/     ParkingSpot
  world/       LevelManager, LevelConfig, Obstacle
  ui/          Hud, Minimap, DebugRoutePanel
  flow/        DirectionArrow
scripts/       LEGACY PT-BR shims (Carro, Vaga, Mundo, FaseBase, ...)
```

Rules for new code:

- Depend on ABSTRACTIONS (signals / groups / Resources), never on
  sibling paths (`get_node("../Rotas")`) or `has_method` bridges.
- `Vehicle` exposes `state_changed / attempt_changed /
  spot_change_requested` + `set_waypoints() / start_navigation() /
  start_trail_mode()` — use these, not `estado_mudou / definir_waypoints`.
- `ParkingSpot` only exposes `is_occupied / mark_occupied()` + signals;
  it never calls vehicle methods.
- `PathPlanner` is a pure service: `build_grid() / find_route() /
  find_free_spawn()` with injected `RouteHints` — no `get_parent()` lookups.
- `LevelManager` (one class) replaces the `Mundo.gd + FaseBase.gd`
  duplication; per-level data lives in `LevelConfig` resources.

### Mission states

| State        | Meaning |
| ------------ | ------- |
| `SEEKING`    | Follow the route target with smooth accel/steering. |
| `AVOIDING`   | Front sensor blocked: steer until the fan is clear. |
| `ALIGNING`   | Near the spot: stop driving, yaw to the target heading. |
| `PARKED`     | Inside the spot and aligned: stopped, spot occupied. |
| `RECOVERING` | Back out (reverse + steering) without scraping sides. |

### Sensors

Twelve `RayCast2D` nodes on the vehicle (front fan, sides, rear,
long-range lookahead, floor-arrow reader). `SensorArray` folds them into
a `PerceptionSnapshot` that brains consume — brains never touch rays.

### Navigation

- **PathPlanner (A\*)** — route between waypoints over the occupancy grid.
- **RouteHints** — injected lane/arrow preferences (no scene crawling).
- **Waypoints** — `Marker2D` nodes placed in the level.

### Locomotion

- Bicycle model: steering ramps, cornering only while moving.
- Wheelbase scales with the visual sprite size.
- Smooth accel ramp (0–160 on straights, lower in corners).

## How to run

1. Open the project in **Godot 4.x**.
2. Play `scenes/Mundo.tscn` (legacy demo) — new levels use `LevelManager`.
3. Keys **1**–**5** switch levels, **R** restarts the current one.
4. The vehicle starts `SEEKING`, follows waypoints, avoids obstacles,
   aligns and parks; the spot turns occupied.

## Scene layout

```
scenes/
├── Mundo.tscn          # Legacy demo: floor, walls, UI, vehicle instance.
├── Carro.tscn          # Legacy vehicle (CharacterBody2D + rays). New: Vehicle.
├── Vaga.tscn           # Legacy spot (Area2D). New: ParkingSpot.
├── Obstaculo.tscn      # StaticBody2D obstacle / parked car.
├── Seta.tscn           # Legacy flow hint. New: DirectionArrow.
└── fases/
    ├── Fase1..5.tscn   # Legacy per-level scenes (being unified via LevelConfig)

src/
├── vehicle/Vehicle.gd        # English facade (IS-A legacy Carro)
├── parking/ParkingSpot.gd    # English facade (IS-A legacy Vaga)
├── navigation/PathPlanner.gd # English facade (IS-A legacy Planejador)
├── world/LevelManager.gd     # Unified Mundo+FaseBase orchestrator
└── ...
```

## Team ground rules

- Don't edit the same `.tscn` at the same time — Godot merges scenes badly.
- `pull` before coding, `push` when a feature lands.
- Assets go to `res://assets/sprites/` with clear names.

## 🗣️ Pitch

> "Our project simulates an autonomous robot. The car is not on a fixed
> script; it uses sensors (RayCast2D) to read the world in real time.
> The code is a state machine: it decides when to seek the spot, when to
> avoid danger and when to align to park — applied autonomous
> decision-making."

