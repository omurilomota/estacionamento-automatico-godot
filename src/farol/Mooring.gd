class_name Mooring
extends RefCounted
## FAROL · ATRACAÇÃO — the final pose, SEARCHED instead of guessed.
##
## `Carro._processar_alinhando()` is a cascade of `if`s on the arrival error
## (approach / 160 px + |err| > 0.08 -> turn in place / |err| > 0.7 -> arc /
## > 0.35 / else glide), and it re-decides from scratch every frame, so the
## phases can oscillate: an arc that overshoots re-enters the approach branch,
## which re-enters the align branch, and the car shuffles. AGENTS #38 already
## had to add a deadline (`ALINHA_MAX_S`) to stop ALINHANDO becoming eternal
## parking — a timeout is a symptom, not a fix.
##
## The Mooring replaces the cascade with a target POSE, computed once per
## (bay, approach side) and then TRACKED, so the phase sequence is monotonic:
##
##   ALIGN  — turn IN PLACE until the hull is parallel to the bay axis and
##            within `atracar_yaw_tol`. Turning in place is legal in this game
##            (the existing code already does it) and it is the only phase
##            that makes no forward commitment.
##   ARC    — follow the bay axis forward at `atracar_vel_arc` until the hull
##            is centred on the bay axis, correcting the lateral error.
##   SLIDE  — straight in at `atracar_vel_slide` to the bay centre.
##
## Every geometry comes from the EXISTING bay contract: the nose direction is
## `Vector2.RIGHT.rotated(rotacao_alvo)` and the preparation point is
## `centro - nariz * alcance_preparo` (the same formula `Carro` uses, AGENTS
## #15). Nothing here re-derives the bay, so there is no second source of
## truth for the geometry to disagree with.
##
## The decision to COMMIT (`marcar_ocupada()` / ESTACIONADO) is NOT the
## Mooring's: `Carro._esta_100_dentro_da_vaga()` is the real gate (AGENTS #16)
## and stays where it is. The Mooring only says which way to move this frame.

enum Fase { ALINHAR, ARCO, DESLIZAR, CHEGADO }

const MooringRef = preload("res://src/farol/Mooring.gd")
## The numbers in use. `usar()` lets a scene/script point the whole class at one
## FarolSpec instead of instantiating per call; the default is a fresh instance.
static var spec: FarolSpec = FarolSpec.new()


static func usar(p_spec: FarolSpec) -> void:
	spec = p_spec if p_spec != null else FarolSpec.new()


## The bay's axis, in world space. The nose points INTO the bay.
static func nariz(centro: Vector2, rot_alvo: float) -> Vector2:
	return Vector2.RIGHT.rotated(rot_alvo)


## One decision for one frame. Pure: same pose in, same phase out.
##
## pos/rot  : the car's pose in the world.
## centro   : the bay's centre (world).
## rot_alvo : the bay's `rotacao_alvo`.
## meia_eixos : the hull's half extents (px, already scaled).
## Returns { fase, target: Vector2, target_yaw: float, speed: float, erro: float }
static func passo(pos: Vector2, rot: float, centro: Vector2, rot_alvo: float,
		meia_eixos: Vector2) -> Dictionary:
	var eixo := nariz(centro, rot_alvo)
	var erro_yaw: float = angle_difference(rot_alvo, rot)
	# Position in the BAY FRAME: `ao_longo` is along the nose (negative =
	# behind the bay, i.e. still on the approach), `ao_travess` is across it.
	var rel := pos - centro
	var ao_longo: float = rel.dot(eixo)
	var ao_travess: float = rel.dot(eixo.orthogonal())
	var _lateral := ao_travess
	# ALIGN has NO positional gate, and that is the correction.
	#
	# The first version read `dentro_da_baia := ao_longo < 0.0`, which is the
	# APPROACH (the preparation point is `centro - nariz * alcance`, i.e.
	# negative — see `Carro._ponto_prep_da_vaga`). So the flag was true exactly
	# where the car had NOT committed yet and false once it was inside, which
	# inverted both branches: a hull arriving 160 px out with 0.5 rad of yaw
	# error went straight to ARC (measured), and a hull twisted 13 px from the
	# centre — the AGENTS #38 case that turns ALIGNING into eternal parking —
	# went straight to SLIDE without ever straightening.
	#
	# Turning in place is legal in this game (the legacy cascade already does
	# it), so squaring up is correct wherever the car is, and the phase
	# sequence stays monotonic: ALIGN -> ARC -> SLIDE.
	if absf(erro_yaw) > spec.atracar_yaw_tol:
		# ALIGN: no forward commitment, but a real aim point. The target is a
		# point ON the bay axis strictly AHEAD of the hull, so the pursuit
		# always has something in front to converge on while the car squares
		# up. Aiming at a fixed offset from the centre was wrong twice over: at
		# the preparation point the car sits `alcance` behind the centre, so
		# `centro - nariz*meia` lands BEHIND the hull and the Stanley term
		# steers the nose the wrong way round.
		var passo_frente: float = maxf(meia_eixos.x * 0.8, 40.0)
		var alvo: Vector2 = centro + eixo * (ao_longo + passo_frente)
		return {
			"fase": Fase.ALINHAR,
			"target": alvo,
			"target_yaw": rot_alvo,
			"speed": 0.0,
			"erro": erro_yaw,
		}
	# Aligned (or already inside): ARC while still short of the centre, SLIDE
	# once the hull is on axis.
	if ao_longo < -meia_eixos.x * 0.5:
		return {
			"fase": Fase.ARCO,
			"target": centro,
			"target_yaw": rot_alvo,
			"speed": spec.atracar_vel_arc,
			"erro": erro_yaw,
		}
	return {
		"fase": Fase.DESLIZAR,
		"target": centro,
		"target_yaw": rot_alvo,
		"speed": spec.atracar_vel_slide,
		"erro": erro_yaw,
	}


## Convenience: the same decision expressed as a target the pure-pursuit can
## follow, with the phase's speed already mapped to the vehicle's units.
static func comando(pos: Vector2, rot: float, centro: Vector2, rot_alvo: float,
		meia_eixos: Vector2, max_speed: float) -> Dictionary:
	var p: Dictionary = passo(pos, rot, centro, rot_alvo, meia_eixos)
	var fase: int = int(p["fase"])
	var erro: float = float(p["erro"])
	var vel: float = float(p["speed"]) * max_speed
	# Steering that converges on the target, with the same Stanley-shaped
	# lateral term the route follower uses (AGENTS #36) — not a new
	# controller, and not a cascade.
	var alvo: Vector2 = p["target"]
	var d: Vector2 = alvo - pos
	var rumo: float = rot if d.length_squared() < 1.0 else d.angle()
	var erro_dir: float = angle_difference(rot, rumo)
	var v: float = maxf(absf(vel), 40.0)
	var e_lat: float = d.dot(Vector2.RIGHT.rotated(rot + PI * 0.5))
	var steer: float = clampf(erro_dir * 2.2 - atan(1.4 * e_lat / v), -1.0, 1.0)
	if fase == Fase.ALINHAR:
		# Turn in place: no throttle, pure steering. The locomotion refuses to
		# yaw below 1 px/s (human drivers only turn while moving), so zero
		# throttle would freeze the phase and burn the deadline — a creep is
		# REQUIRED, not an optimisation.
		vel = max_speed * 0.12
		steer = clampf(erro_dir * 2.2, -1.0, 1.0)
	var cmd := DriveCommand.make(steer, clampf(vel / maxf(max_speed, 1.0), 0.0, 1.0))
	return {
		"fase": fase,
		"comando": cmd,
		"alvo": alvo,
		"erro": erro,
		"deslizando": fase == Fase.DESLIZAR,
	}
