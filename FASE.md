# Parking levels (real maps)

Each map in `estacionamento/` is a **test situation** (level). The car
already drives agentically (retry strategies), so each level tests how it
handles a different layout.

## How to run

| Key | Action |
|---|---|
| `1` / `2` / `3` / `4` / `5` | Switch level (demo AND levels) |
| `R` | Restart the current scene |

To run a level in the editor: **Play** or **F5** runs the main scene
(`Mundo.tscn`). To open one level, double-click it
(`scenes/fases/FaseN.tscn`) and press **F6** (play current scene).

> **To SEE the parking image:** all 5 levels already load the real map
> (`Mapa` → `mapa` = `estacionamento/parking_lot.jpg`, `parking_lot2.svg`,
> `parking_lot3.svg`, `parking_lot4.jpg`, `Parkinglot5.jpeg`). Play the demo
> (F5), then press **1**–**5**. `FaseBase.gd` (legacy; new: `LevelManager`)
> positions the image, builds walls, frames the camera and minimap
> automatically (size = `image width × map_scale`).
>
> To use **your own image**: drop it in `estacionamento/`, open the level
> scene and on the root node drag the image into `mapa`
> (tune `escala_mapa`/`zoom_camera` in the Inspector; new API:
> `LevelConfig.map_texture / map_scale / camera_zoom`).

## Vehicle spawn

- `posicao_aleatoria` (root export; new: `LevelConfig.random_spawn`):
  on by default — the vehicle spawns in a **random free cell**
  (never on an obstacle or spot).
- Off (`false`) → uses the `Carro` node position from the scene.

## What each level already has

- **Map** (`Mapa`): the parking image renders in the editor (texture +
  scale baked in the scene) and in game (`escala_mapa`). Your floor.
- **Perimeter walls** (`LimiteAutomatico`): auto-generated around the map.
- **Camera** (`Camera`): follows the car, clamped to the edges
  (`zoom_camera` tunes zoom).
- **UI**: status, sensor and attempt (same as the demo scene).
- **Vehicle**: already instanced (placeholder position — move it freely).

> **Automatic mode:** with `Carro.auto_navegacao = true` (new:
> `Vehicle.set_autonomous(true)`), the car **ignores waypoints** — it plans
> its own A* route to the nearest spot. What matters is **SPOTS** (the goal)
> and **OBSTACLES** (what to avoid).

## How to build a level (step by step)

> Recommended order: **1st spots → 2nd obstacles → 3rd tuning**.

### 1. Place the GOAL (spots where the car parks)

1. Open the level: double-click `scenes/fases/FaseN.tscn`.
2. In **FileSystem**, find `scenes/Vaga.tscn` (new: `ParkingSpot`) and
   **drag** an instance under `Vagas`.
3. Position it **over a drawn bay** (green outlines are the contour).
4. Set `rotacao_alvo` in the Inspector (new: `target_yaw`) — nose heading
   when parked:
   - nose **up** → `-1.5708`
   - nose **right** → `0`
   - nose **down** → `1.5708`
   - nose **left** → `3.14159`
5. (Optional) Force one spot: select `Carro` → `vaga_prioritaria` →
   drag the spot in (new API: pass the spot to the brain directly).
6. Duplicate (Ctrl+D) for the rest, rotating each as needed.

Playing the level (F6): the car picks the nearest free spot, draws the
yellow route + floor grid, parks, and the spot turns **red**.

### 2. Place OBSTACLES (parked cars, curbs, planters)

- **Parked cars (blocked):** drag `scenes/Obstaculo.tscn` (new:
  `Obstacle`) under `Obstaculos`. Rotate to match the map. It already has
  `collision_layer = 2` — the route avoids it.
- **Walls/columns:** `Paredes` → **+** → `StaticBody2D` → **+** →
  `CollisionShape2D` (rectangle over the wall), `collision_layer = 2`.

### 3. Final tuning

- **Spawn:** root `posicao_aleatoria` (`LevelConfig.random_spawn`) =
  `false` → scene `Carro` position; `true` → random free cell.
- **Scale/zoom:** root `escala_mapa` + `zoom_camera`.
- The **minimap** (bottom-right) shows spots (green = free, red = occupied)
  and the car automatically.

## File layout

```
scenes/fases/
  Fase1.tscn      # estacionamento/parking_lot.jpg   (escala_mapa = 0.4)
  Fase2.tscn      # estacionamento/parking_lot2.svg  (escala_mapa = 3.0)
  Fase3.tscn      # estacionamento/parking_lot3.svg  (escala_mapa = 3.0)
  Fase4.tscn      # estacionamento/parking_lot4.jpg  (escala_mapa = 3.8)
  Fase5.tscn      # estacionamento/Parkinglot5.jpeg  (escala_mapa = 1.0)
estacionamento/   # real maps (JPG/SVG) used as level floors
```
