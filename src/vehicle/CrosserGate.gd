class_name CrosserGate
extends RefCounted
## Yield latch for crossing traffic, with hysteresis.
##
## WHY: the scripted crossing car (`src/world/Crosser.gd`) is deliberately
## BODY-LESS, so the player's car never collides with it — visually it drives
## right through. The only way to make the yield believable is the DECISION:
## once the player commits to stopping for a crosser, it must stay committed
## for a while. The raw predicate `PerceptionSnapshot.crosser_ahead()` is a
## bare threshold, so a crosser hovering near the limit makes the car
## creep/release/creep again.
##
## Hysteresis: latch ON at `enter_distance` inside `enter_cone`; release only
## past `exit_distance` (or once the crosser leaves the wider `release_cone`)
## AND after `min_hold` seconds. Pure + headless-testable (ModulesCheck).

## Latch when the crosser is closer than this and roughly ahead (px).
const ENTER_DIST := 220.0
## Keep yielding until the crosser is farther than this (px).
const EXIT_DIST := 340.0
## Never release sooner than this after latching (s).
const MIN_HOLD := 1.0
## Half-angle of the "crosser is in my way" cone (rad).
const ENTER_CONE := 0.6
## Wider half-angle: outside it the crosser is beside/behind, not a hazard.
const RELEASE_CONE := 1.2

var enter_distance: float = ENTER_DIST
var exit_distance: float = EXIT_DIST
var min_hold: float = MIN_HOLD
var enter_cone: float = ENTER_CONE
var release_cone: float = RELEASE_CONE
## Release only when BOTH the distance AND the bearing are clear. The default
## (OR) is the crosser's measured-green rule; the PEDESTRIAN gate sets this:
## an OR release let the car creep forward mid-crossing (the pedestrian was
## still 288+ px lateral, well inside the lane) and it re-latched — 30 latches
## measured on Fase11. Strict AND holds until the person is genuinely clear.
var strict_release: bool = false

## Autonomia: 320/430 px. O padrao (220/340) era curto demais para o carro
## PARAR: a 220 px da faixa de cruzamento ele freava colado no carro que
## cruzava, quase sobreposto (foto de 2026-09-26). A 320 px ele espera na
## linha de preferencia e o transito passa NA FRENTE, com folga visivel.
const AUTO_ENTER_DIST := 320.0
const AUTO_EXIT_DIST := 430.0

## PEDESTRE — a LINHA DE PREFERENCIA (docs/tasks_trafego.md T2; a divida do
## backlog #14: "a parada acontece onde o latch pegou" fazia o carro parar
## SOBRE a linha de travessia do pedestre, e a pessoa caminhava ATRAVES do
## carro — min_gap medido 9,2 px). A cedencia ao pedestre nao e um stop()
## seco: e um GLIDE ate `PED_GIVEWAY_GAP` px do pedestre (o throttle cai
## linearmente ao longo de `PED_GIVEWAY_RAMP` px), entao o carro para ANTES
## da pessoa e ela cruza NA FRENTE, com folga. So o yield do PEDESTRE usa
## isso: o yield do crosser e autorado por fase e esta medido-verde (a parada
## dele ~90 px antes da faixa e o release por distancia que o boot da Fase2
## prova) — mexer nele muda a geometria medida.
const PED_GIVEWAY_GAP := 120.0
const PED_GIVEWAY_RAMP := 240.0


func _init(p_enter: float = ENTER_DIST, p_exit: float = EXIT_DIST) -> void:
	enter_distance = p_enter
	exit_distance = p_exit

var _latched: bool = false
var _held: float = 0.0


## distance: px to the nearest crosser (INF/absent = no crosser).
## bearing: signed radians, 0 = straight ahead (see PerceptionSnapshot).
## delta: seconds since the last call, so the hold is measured in wall time.
func should_yield(distance: float, bearing: float, delta: float) -> bool:
	if not is_finite(distance):
		_latched = false
		_held = 0.0
		return false
	if not _latched:
		if distance < enter_distance and absf(bearing) < enter_cone:
			_latched = true
			_held = 0.0
		return _latched
	_held += maxf(delta, 0.0)
	var livre := distance > exit_distance or absf(bearing) > release_cone
	if strict_release:
		livre = distance > exit_distance and absf(bearing) > release_cone
	if _held >= min_hold and livre:
		_latched = false
		_held = 0.0
	return _latched


## True while the gate holds the vehicle for a crosser.
func is_latched() -> bool:
	return _latched


## Seconds spent in the current latch (0 when released).
func held_for() -> float:
	return _held


## Forget the latch (mode change, new level, respawn).
func reset() -> void:
	_latched = false
	_held = 0.0
