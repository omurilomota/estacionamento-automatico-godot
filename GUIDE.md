# GUIDE — PROJECT GUIDE: AUTONOMOUS PARKING (Godot 2D)

Goal: a top-down 2D sim where a car parks itself, dodging obstacles with
"sensors". Short deadline: functionality over AAA graphics.

## 🛠️ Team golden rules

- Don't edit the same scene (`.tscn`) at the same time — Godot merges
  scenes badly. If Murilo is on the vehicle, Matheus is on the world.
- Asset handoff: Gian names files clearly (e.g. `red_car.png`,
  `spot_free.png`) and delivers them in organized folders.
- Git: always `pull` before coding, `push` when a feature lands.

## 🎨 1. GIAN (Designer / Artist)

Mission: game visuals, "clean / minimalist" style (well-made shapes).
Deliver transparent PNGs:

- **Vehicle:** top-down view. Tip: a rectangle with a windshield at the
  front so we know which way is forward.
- **Parking spot:** 2 versions (or a dashed rectangle the code recolors):
  `spot_free.png` (green/white dashes), `spot_occupied.png` (red dashes).
- **Obstacles:** parked cars (same sprite, new color), concrete walls
  (gray rectangles).
- **UI (optional, recommended):** top panel reading
  `STATUS: [Seeking spot]`, `SENSOR: [Clear]`.
- Keep one sprite scale (64x64 or 128x128) to help programmers.

## 💻 2. MURILO (Programmer — vehicle brain)

Mission: vehicle logic + "intelligence" (state machine). Works in
`Vehicle` (`src/vehicle/`, legacy: `Carro.tscn` / `scripts/Carro.gd`).

- **Locomotion:** `CharacterBody2D` driving forward/back + steering
  (`src/vehicle/Locomotion.gd`, bicycle model).
- **Sensors (`RayCast2D`):** front/left/right arrays, `is_colliding()`
  detection, red debug lines on hit (`src/vehicle/SensorArray.gd` →
  `PerceptionSnapshot`).
- **State machine:** `SEEKING, AVOIDING, ALIGNING` (+ `PARKED`,
  `RECOVERING`) — see `src/core/VehicleState.gd`.
  - `SEEKING`: accelerate + steer smoothly toward the waypoint.
  - `AVOIDING`: front ray hit → stop forward, steer aside until clear.
  - `ALIGNING`: near the spot → stop driving, yaw to target heading.

## 3. MATHEUS (Programmer — world & interaction)

Mission: level, spot logic, UI. Works in `LevelManager`
(`src/world/`, legacy: `Mundo.tscn`, `Vaga.tscn`, UI).

- **Level:** floor (big `ColorRect`/`TileMap` or parking image),
  walls (`StaticBody2D + CollisionShape2D`), `Marker2D` waypoints.
- **Spot (`ParkingSpot`):** `Area2D`; on `body_entered` recolor
  free→occupied and signal the vehicle (never call it directly).
- **UI:** labels bound to vehicle signals (`state_changed` →
  `"Avoiding obstacle!"`).

## 🤝 Integration

1. Gian drops PNGs in `res://assets/sprites/`.
2. Matheus builds the level (walls, spots, waypoints) + vehicle instance.
3. Murilo skins the vehicle, wires rays to Matheus's colliders.
4. Final test: car goes A→B on Matheus's waypoints, dodges with
   Murilo's sensors, parks in Matheus's spot.

## 🎤 The pitch (everyone must know it)

> "Our project simulates an autonomous robot. The car is not on a fixed
> script; it uses sensors (RayCast2D) to read the world in real time.
> The code is a state machine: it decides when to seek the spot, when
> to avoid danger and when to align to park — applied autonomous
> decision-making."
