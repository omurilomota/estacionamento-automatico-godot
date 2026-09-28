class_name VehicleState
extends RefCounted
## Canonical vehicle mission states (English).
## Replaces the legacy PT-BR `Estado { BUSCANDO, DESVIANDO, ... }`.
## Order is intentionally identical to the legacy enum so raw indices
## (e.g. `estado == 3` in ml/*.gd) keep working during migration:
##   SEEKING(0) == BUSCANDO, AVOIDING(1) == DESVIANDO,
##   ALIGNING(2) == ALINHANDO, PARKED(3) == ESTACIONADO,
##   RECOVERING(4) == RECUPERANDO.

enum State { SEEKING, AVOIDING, ALIGNING, PARKED, RECOVERING }

const LABELS := {
	State.SEEKING: "Seeking spot",
	State.AVOIDING: "Avoiding obstacle!",
	State.ALIGNING: "Aligning to park",
	State.PARKED: "Parked!",
	State.RECOVERING: "Recovering...",
}

const _LEGACY_TO_STATE := {
	"BUSCANDO": State.SEEKING,
	"DESVIANDO": State.AVOIDING,
	"ALINHANDO": State.ALIGNING,
	"ESTACIONADO": State.PARKED,
	"RECUPERANDO": State.RECOVERING,
}

const _STATE_TO_LEGACY := {
	State.SEEKING: "BUSCANDO",
	State.AVOIDING: "DESVIANDO",
	State.ALIGNING: "ALINHANDO",
	State.PARKED: "ESTACIONADO",
	State.RECOVERING: "RECUPERANDO",
}


static func label(state: int) -> String:
	return LABELS.get(state, "Unknown")


static func from_legacy_name(legacy_name: String) -> int:
	return _LEGACY_TO_STATE.get(legacy_name, State.SEEKING)


static func to_legacy_name(state: int) -> String:
	return _STATE_TO_LEGACY.get(state, "BUSCANDO")
