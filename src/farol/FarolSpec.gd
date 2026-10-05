class_name FarolSpec
extends Resource
## FAROL — the numbers, in ONE place.
##
## Every constant the five FAROL layers (Chart, Route, Pilot, Mooring, Nervo)
## use lives here, so retuning a rule is a number in the scene inspector and
## never a code edit inside a 3000-line god object (`scripts/Carro.gd`).
##
## `scripts/Carro.gd` and `scripts/Planejador.gd` both hold a nullable copy and
## fall back to `FarolSpec.default()` — a scene can override any single number
## without inheriting a whole `.tres`.
##
## Units are PIXELS and SECONDS everywhere. `resolucao` (px per grid cell) is
## NOT here: it belongs to the planner, which owns the grid.

# --- CHART: the map finally knows how much fits ---------------------------
## Extra clearance, in CELLS, on top of the swept radius before a cell counts
## as solid. Same invariant the legacy `inflar` circle has
## (`Carro.FOLGA_EXTRA_CELULAS` = 1.5); kept as a number so both paths agree.
@export var folga_extra_celulas: float = 1.5
## Seconds a cell stays "this is where the car got stuck" after it was marked.
## The Chart memory decays ONLY here (wall-clock TTL), never per frame: the
## LocalMap's fast decay is for dynamics, this is for dead ends that must be
## remembered for a whole approach.
@export var memoria_ttl_s: float = 30.0
## Weight added to a remembered cell by the Route cost (0 = memory off).
@export var memoria_peso: float = 2.5
## A cell is forgotten faster when it is hit repeatedly (dead end, not a
## one-off scrape): each extra hit divides the TTL by this.
@export var memoria_decaimento_por_acerto: float = 2.0
@export var memoria_max_hits: int = 4

# --- ROUTE: right-hand traffic as a COST, not a post-hoc shift -------------
## How strongly the planner prefers the middle of the corridor
## (`w_folga = 1 + k / (clearance - swept)`). This is what makes the planner
## refuse a one-car-wide gap instead of discovering the dead end afterwards.
@export var w_folga: float = 0.35
## How strongly the planner prefers the right-hand lane strip.
@export var w_faixa: float = 1.8
## Extra penalty multiplier for cells on the LEFT half of the corridor, on top
## of `w_faixa`. Without it, "far from the right wall" is ambiguous in a wide
## aisle and the A* settles in the middle again (AGENTS #31).
@export var w_esquerda: float = 0.6
## Margin kept from the right wall ON TOP of the swept radius, as a fraction of
## it. Mirrors `LaneOffset.LANE_EDGE_MARGIN` so the cost-based lane and the
## post-A* shift agree (both are right-hand traffic; they must not disagree).
@export var lane_edge_margin: float = 0.5
## A side with no wall within this many swept radii is OPEN SPACE, not a lane:
## the proportional bias takes over (mirrors `LaneOffset.LANE_OPEN_EDGE`).
@export var lane_open_edge: float = 6.0
## Anti-runaway cap on the lane target, in swept radii.
@export var lane_max_largura: float = 6.0
## Shortcut smoothing: a chord is only accepted when every point of it keeps
## `swept_radius + shortcut_margem_px` of clearance. This is the "smoothing
## WITH PROOF" of the plan — rounding a corner into a wall is impossible here.
@export var shortcut_margem_px: float = 14.0
## Maximum number of shortcut passes (each pass removes one vertex).
@export var shortcut_passes: int = 6

# --- PILOT: the local layer that does not exist today ---------------------
## Ego-centric costmap: `local_half` cells of `local_cell` px on each side, so
## 61x61 cells at the defaults = 1220 px of horizon.
@export var local_half: int = 30
@export var local_cell: float = 20.0
## Seconds between LocalMap rebuilds. The map is REBUILT from the rays (a
## free operation over 3721 cells) and the old obstacles are decayed, so a
## cone that vanished does not haunt the car forever.
@export var local_rebuild_s: float = 0.5
## Diagonal rays added to the sensor array so the hull's corners are seen
## (the 11 original rays are all along the car's axes).
@export var diagonal_reach: float = 150.0
@export var diagonal_reach_curto: float = 85.0

## DWA: 9 steering x 3 speeds = 27 arcs, rolled `dwa_horizonte_s` in
## `dwa_passo_s` steps against the local costmap.
## Steering samples across the symmetric -1..+1 window. `Dwa.avaliar()` reads
## this field and it was MISSING from the spec, so the DWA raised every frame
## and the pilot never produced a command (measured on Fase9, 2026-09-29).
@export var dwa_steer_steps: int = 9
@export var dwa_horizonte_s: float = 1.2
@export var dwa_passo_s: float = 0.1
@export var dwa_periodo_s: float = 0.1
## Speeds rolled, as fractions of the commanded cruise (0.0 = creep).
@export var dwa_velocidades: PackedFloat32Array = PackedFloat32Array([0.0, 0.55, 1.0])
## Cost weights (all normalised: progress is in px, the rest are 0..1).
@export var w_progresso: float = 1.0
@export var w_colisao: float = 6.0
@export var w_folga_piloto: float = 1.1
@export var w_faixa_piloto: float = 0.8
@export var w_suavidade: float = 0.55
@export var w_roteiro: float = 0.9
## Charge per px/s of speed ABOVE the route/choke profile (soft ceiling).
## Hard-filtering the sampled fractions froze the window on its floor fraction
## whenever the profile dipped for one tick (measured 40 px/s cruise through
## wide corridors, Fase2 2026-09-29); charging the excess lets the profile win
## exactly where it matters (a choke) and cost almost nothing on open-road
## dips. 0.0 = profile ignored (the DWA would then never slow for chokes).
@export var w_excesso_vel: float = 1.5
## `blocked_ahead`: how far along the route counts as "the plan is blocked",
## and how many consecutive bad cells are needed before it is a signal rather
## than noise. Distinct from the stuck watchdog (which measures DISPLACEMENT):
## this one fires at ~3 m while the car is still moving.
@export var bloqueado_dist_px: float = 460.0
@export var bloqueado_celulas: int = 4
@export var bloqueado_clearance_px: float = 0.0
## Minimum seconds between two detour replans (a detour that does not take in
## 3 s of movement is not a detour, it is a stall).
@export var desvio_periodo_s: float = 2.5
## BFS horizon for the detour goal, in cells.
@export var desvio_raio_celulas: int = 34

# --- MOORING: the final pose, searched instead of guessed ------------------
## Yaw error under which the car may be declared aligned.
@export var atracar_yaw_tol: float = 0.08
## Distance to the bay centre under which the car is declared berthed.
@export var atracar_dist_px: float = 12.0
## The pose lattice: yaw samples x longitudinal samples searched inside the
## bay's containment region. Forward entry only (locked A2).
@export var atracar_passos_yaw: int = 9
@export var atracar_passos_long: int = 5
## Pose cost weights: yaw error, off-centre, arrival angle.
@export var atracar_peso_yaw: float = 1.0
@export var atracar_peso_centro: float = 0.6
@export var atracar_peso_chegada: float = 0.5
## Speeds of the three phases (align in place / arc / slide into the bay).
@export var atracar_vel_arc: float = 0.35
@export var atracar_vel_slide: float = 0.5


## A fresh instance with the documented defaults (callers must NOT share one).
static func default() -> FarolSpec:
	return FarolSpec.new()
