class_name FarolShield
extends RefCounted
## FAROL · NERVO — the learned driver's safety net.
##
## The pupil (`MlDriver`) sees 22 numbers and nothing else: it has no idea
## where the walls are, and a net trained on a 30 s demo WILL eventually emit
## a full-lock command into a kerb. The legacy answer was to cut the throttle
## (`MlDriver.map_outputs`: `dist_centro < brake_dist -> throttle 0`), which
## protects the ARRIVAL and is blind everywhere else.
##
## The shield is the one rule that is never learned: **the pupil may choose,
## the teacher may veto, and the veto is about collision, not about taste.**
## It is a pure function of (command, what the LocalMap can see), so
## `ModulesCheck` asserts it headless with no scene — the plan's requirement,
## and the reason it lives in its own file instead of inside `Carro`.
##
## It NEVER invents a command: a veto falls back to the teacher's, and a
## teacherless vehicle falls back to stop. That is the invariant the gates
## check: a shielded command must be at least as safe as the teacher's.

const LocalMapRef = preload("res://src/farol/LocalMap.gd")
const FarolSpecRef = preload("res://src/farol/FarolSpec.gd")
const FarolShieldRef = preload("res://src/farol/FarolShield.gd")

## Local cost at which the hull is "about to touch".
##
## POLARITY: the LocalMap cost is 0 for free room and grows as the cell nears an
## obstacle (`LocalMap.LIVRE`/`OBSTACULO`, and `misturar_carta` writes
## `1 - (clearance - raio)/raio`, i.e. 1 exactly at the hull). So HIGH cost is
## DANGER. The first version compared `minf(...) < PROXIMIDADE`, which is the
## double inversion: it took the FREEST sample along the beam (the worst
## possible reduction for a "is something in my way" question) and then asked
## possible reduction for a "is something in my way" question) and then asked
## whether that freest sample was cheap. The shield therefore vetoed the pupil
## in the middle of an empty aisle and never vetoed it in front of a wall — and
## the two cases that looked green (veto / no teacher) were green for exactly
## that wrong reason.
const PROXIMIDADE := 0.75


## Returns the command the vehicle should actually execute.
##
## aluno    : what the learned brain wants this frame (may be null).
## professor: what the rule-based pilot wants (may be null).
## local    : the LocalMap (may be null -> the shield abstains and returns the
##            pupil untouched, because a shield that cannot see must not
##            silently become a "stop everything" governor).
static func aplicar(aluno: DriveCommand, professor: DriveCommand,
		local: LocalMapRef, hull: Vector2, pos: Vector2, rot: float) -> DriveCommand:
	if aluno == null:
		return professor if professor != null else DriveCommand.stop()
	if local == null or hull == Vector2.ZERO:
		return aluno
	# Look AHEAD along the pupil's own heading, not along the route: the
	# pupil is the one whose intent we are checking.
	var dir := Vector2.RIGHT.rotated(rot)
	var alcance: float = hull.x * 2.0
	var passo: float = maxf(hull.x * 0.5, 8.0)
	# MAX cost along the beam = the closest thing to the hull, which is the only
	# number that answers "am I about to hit it".
	var mais_perto := 0.0
	for k in range(1, int(alcance / passo) + 1):
		mais_perto = maxf(mais_perto, local.custo_em(pos + dir * (passo * k)))
	if mais_perto > PROXIMIDADE and aluno.throttle > 0.0:
		# The pupil is pushing into something. Hand over to the teacher; if
		# there is none, stop — a car that stops is never a car that crashes.
		if professor != null:
			return professor
		return DriveCommand.stop()
	return aluno


## Headless unit checks. Returns {"fails": [...]}; empty means the shield
## behaves as specified.
static func check() -> Dictionary:
	var report := {"fails": []}
	# `de_teste(4, 20)` is a 9x9 window of 20 px cells anchored at (-80, -80),
	# so the car's own cell (0,0) is the CENTRE and the wall has to sit on a
	# column the beam actually visits. With a 40 px half-hull the beam samples
	# x = 20/40/60/80 from the origin, i.e. columns 4..8 of the window; the old
	# wall at column 5 covered x = 20 only, so cases 1 and 2 passed because free
	# space tripped the (inverted) veto, not because a wall was seen.
	var local := LocalMapRef.de_teste(4, 20.0)
	# A wall filling every column the beam can reach: 20 px ahead, so the hull
	# is 20 px from it — inside PROXIMIDADE.
	for y in range(local.dim):
		for x in range(4, local.dim):
			local.custo[y * local.dim + x] = LocalMapRef.OBSTACULO
	var frente := DriveCommand.make(0.0, 0.6)
	var recuo := DriveCommand.make(0.0, 0.0)
	# 1. A wall ahead vetoes the pupil and falls back to the teacher.
	var r1: DriveCommand = FarolShieldRef.aplicar(frente, recuo, local,
		Vector2(40.0, 37.0), Vector2.ZERO, 0.0)
	if r1.throttle > 0.0:
		(report["fails"] as Array).append("veto")
	# 2. No teacher, wall ahead: stop, never push.
	var r2: DriveCommand = FarolShieldRef.aplicar(frente, null, local,
		Vector2(40.0, 37.0), Vector2.ZERO, 0.0)
	if r2.throttle > 0.0 or absf(r2.steering) > 0.001:
		(report["fails"] as Array).append("sem professor")
	# 3. Clear ahead: the pupil is passed through untouched. This is the case
	# that caught the inverted polarity — a shield that vetoes in open space is
	# worse than no shield, because it stops the car in the middle of the aisle.
	var limpo := LocalMapRef.de_teste(4, 20.0)
	var r3: DriveCommand = FarolShieldRef.aplicar(frente, recuo, limpo,
		Vector2(40.0, 37.0), Vector2.ZERO, 0.0)
	if absf(r3.throttle - frente.throttle) > 0.001:
		(report["fails"] as Array).append("passa thru")
	# 3b. Same, but with a WALL BEHIND: the shield looks along the pupil's own
	# heading only, so a wall it is driving away from must not veto it.
	var atras := LocalMapRef.de_teste(4, 20.0)
	for y in range(atras.dim):
		for x in range(0, 4):
			atras.custo[y * atras.dim + x] = LocalMapRef.OBSTACULO
	var r3b: DriveCommand = FarolShieldRef.aplicar(frente, recuo, atras,
		Vector2(40.0, 37.0), Vector2.ZERO, 0.0)
	if absf(r3b.throttle - frente.throttle) > 0.001:
		(report["fails"] as Array).append("parede atras")
	# 4. Blind shield (no map) must ABSTAIN, not stop everything.
	var r4: DriveCommand = FarolShieldRef.aplicar(frente, recuo, null,
		Vector2(40.0, 37.0), Vector2.ZERO, 0.0)
	if absf(r4.throttle - frente.throttle) > 0.001:
		(report["fails"] as Array).append("abstine")
	return report
