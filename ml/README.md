# Machine Learning — self-driving car (imitation)

Phased plan to remove the Line2D dependency: the car drives **on sensors
only**, using a neural net trained from the current brain (behavior
cloning). The FSM stays the mission judge.

## Architecture

```
FSM (Carro.gd / Vehicle) = mission: pick spot, ALIGNING, PARKED
NeuralBrain (CerebroML)  = perception -> action (MLP 18-32-16-2, pure GDScript)
ml/train.py              = offline training (numpy), exports ml/modelo/pesos.json
```

- **Inputs (18):** 11 normalized rays + speed + distance/angle to the
  spot + floor arrow (dist, cos, sin).
- **Outputs (2):** steering (-1..1) and speed (0..1 × max speed).
- Hard-coded safety layers stay (center-distance braking, fallback to
  the trail brain if the net stalls).

## Phases

1. **Record** (teacher): `godot --headless --script ml/gravar.gd`
   → `ml/dados/<Fase>_ep<N>.csv` (~10k samples).
2. **Train**: `python3 ml/treinar.py` (numpy only)
   → `ml/modelo/pesos.json` + validation metrics.
3. **Evaluate**: `godot --headless --script ml/testar_ml.gd`
   → runs the level with `modo_ml = true` (new: `set_ml_driving(true)`,
   no drawn trail) and reports the outcome.

## In-game use

In the vehicle inspector: `modo_ml = true` (new: `ml_driving`). The net
loads from JSON; if missing it falls back to trail mode automatically.

## Known limitations (honest)

- Imitation only matches the teacher — no novel maneuvers (e.g.
  three-point turns). Phase 3 is next: **neuroevolution** (GA over the
  weights, pure GDScript).
- The model learns the recorded layouts; new levels may need re-recording.

