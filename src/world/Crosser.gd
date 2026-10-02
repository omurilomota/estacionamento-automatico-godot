class_name Crosser
extends Node2D
## Scripted crossing car: it ENTERS from off-screen, crosses, leaves, waits out
## of sight and comes back — always eastbound, so it reads as traffic instead
## of a car parked in the middle of the aisle doing a U-turn.
##
## SENSOR-ONLY by design (cheap, deterministic, modest-PC friendly): a plain
## Node2D in group "crosser" with NO physics body, so it never blocks
## move_and_slide nor pollutes the A* grid. The vehicle sees it through
## _build_brain_perception() (group broadcast ->
## PerceptionSnapshot.crosser_distance/bearing) and brains YIELD via
## crosser_ahead(); Locomotion safety still vetos any real contact.
##
## Phase (2026-09-26): the previous A->B->A ping-pong was a lawnmower, and the
## art was missing the +90 deg of Carro.tscn's Sprite2D, so the taxi drove
## sideways. Now `spawn_distance` authors the phase instead: the car starts
## that far WEST of point_a, so on a canonical boot it reaches the lane centre
## exactly when the player does (~12.2 s at cruise_speed 160). Every pass is
## eastbound — a westbound pass forces a double wait, so it must never happen.
##
## The sprite is a plain child in the scene, like Carro.tscn: the Kenney art
## faces -Y, so the CHILD carries `rotation = 1.5708` and this node's rotation
## stays the world heading.

@export var point_a: Vector2 = Vector2(-600, 0) ## west end of the crossing
@export var point_b: Vector2 = Vector2(600, 0) ## east end of the crossing
@export var cruise_speed: float = 120.0 ## px/s
@export var pause_time: float = 1.5 ## seconds out of sight between passes
@export var spawn_distance: float = 700.0 ## px before point_a it enters from (off-camera)
## Espera antes da PRIMEIRA entrada. O faseamento do yield e' isto: aumentar
## `spawn_distance` para alinhar a primeira passagem deixava o carro 20 s fora
## de cena por ciclo (e o ciclo inteiro ficava longo). Aqui a entrada e curta
## (ciclo ~11 s, varias passagens por minuto) e este atraso so desloca a fase.
@export var initial_delay: float = 0.0
## CEDENCIA DETERMINISTA (2026-09-26): o transito so sai quando ha um veiculo
## se aproximando da faixa, em vez de esperar uma "hora certa" da simulacao.
## O faseamento por `initial_delay` era uma quebra-cabeça sem fim: qualquer
## mudanca no traçado do carro invalidava a janela, e o gate voltava a
## `latches=0`. Agora a cedencia e uma RELACAO (o jogador se aproxima -> o
## transito cruza -> o jogador para), e ela existe em toda partida.
@export var trigger_distancia: float = 900.0
@export var running: bool = true

## CEDENCIA MUTUA (2026-09-26): o usuario viu o carro azul sendo "sobrescrito"
## pelo laranja. O Crosser e' sensor-only, sem corpo, entao ele simplesmente
## ATRAVESSAVA o jogador. Aqui ele procura um veiculo no grupo `veiculo` e
## segura enquanto houver alguem na zona de conflito — a sobreposicao deixa de
## ser possivel por construcao, em vez de depender do faseamento.
@export var vehicle_group: StringName = &"veiculo"
## meia-largura da zona de conflito, em px (2 x 81 do carro + folga)
@export var conflict_half_width: float = 120.0
## quanto a frente o Crosser olha ao longo do proprio caminho, em px
@export var conflict_lookahead: float = 300.0

var _t: float = 0.0
var _phase: int = 0 ## 0: driving east, 1: out of sight
var _phase_t: float = 0.0
var _entry: Vector2 = Vector2.ZERO


func _ready() -> void:
	add_to_group("crosser")
	_entry = _off_scene()
	global_position = _entry
	rotation = (point_b - point_a).angle()
	visible = true
	if initial_delay > 0.0:
		_phase = 1          # espera fora de cena antes da primeira entrada
		_phase_t = -initial_delay


func _process(delta: float) -> void:
	if not running:
		return
	_t += delta
	_phase_t += delta
	match _phase:
		0:
			rotation = (point_b - point_a).angle()
			if _conflito():
				return   # segura o carro que cruza: o veiculo tem prioridade
			global_position = _advance(_entry, point_b, delta)
			if global_position.distance_to(point_b) < 4.0:
				_next_phase()
		1:
			if _phase_t >= pause_time and (trigger_distancia <= 0.0 or _veiculo_se_aproximando()):
				_next_phase()


## Pure path helper (unit-testable, no tree): position along A->B at time t,
## clamped at B. There is no reverse trip: the next pass is a fresh entry from
## the west, which is what makes it read as traffic.
static func position_at(a: Vector2, b: Vector2, speed: float, t: float) -> Vector2:
	var length: float = a.distance_to(b)
	if length < 1.0 or speed <= 0.0:
		return a
	return a.lerp(b, minf(1.0, t * speed / length))


## Ha veiculo se aproximando da faixa de cruzamento? (distancia perpendicular)
func _veiculo_se_aproximando() -> bool:
	if get_tree() == null:
		return false
	var d: Vector2 = point_b - point_a
	if d.length_squared() < 1.0:
		return false
	var u: Vector2 = d.normalized()
	for n in get_tree().get_nodes_in_group(vehicle_group):
		var v := n as Node2D
		if v == null or not is_instance_valid(v):
			continue
		if absf((v.global_position - point_a).dot(u.orthogonal())) <= trigger_distancia:
			return true
	return false


## Ha veiculo na zona de conflito (dentro da faixa, a frente do Crosser)?
## E' isto que garante, por construcao, que o carro que cruza NAO atravesse o
## jogador: o usuario viu o azul "sobrescrito" pelo laranja.
##
## Deadlock (2026-10-01, Fase10 seed=3): se o carro esta PARADO dentro da zona
## de conflito, o Crosser segura esperando o carro sair — mas o carro esta parado
## justamente porque CEDE ao Crosser (CrosserGate). Ninguem se move. O carro
## parado nao vai atravessar ninguem, entao o Crosser so segura se o veiculo
## estiver se movendo.
func _conflito() -> bool:
	if get_tree() == null:
		return false
	var d: Vector2 = point_b - point_a
	var comprimento: float = d.length()
	if comprimento < 1.0:
		return false
	var u: Vector2 = d / comprimento
	for n in get_tree().get_nodes_in_group(vehicle_group):
		var v := n as Node2D
		if v == null or not is_instance_valid(v):
			continue
		if absf(float(v.get("velocidade_atual"))) < 5.0:
			continue
		var rel: Vector2 = v.global_position - global_position
		var ao_longo: float = rel.dot(u)
		if ao_longo < 0.0 or ao_longo > conflict_lookahead:
			continue
		if absf(rel.dot(u.orthogonal())) <= conflict_half_width:
			return true
	return false


func _advance(from_p: Vector2, to_p: Vector2, delta: float) -> Vector2:
	var step: Vector2 = to_p - global_position
	var length: float = step.length()
	if length < 0.001:
		return to_p
	return global_position + step / length * minf(cruise_speed * delta, length)


func _next_phase() -> void:
	_phase = (_phase + 1) % 2
	_phase_t = 0.0
	if _phase == 0:
		_entry = _off_scene()
		global_position = _entry
	visible = _phase == 0

## Where it waits/starts: `spawn_distance` BEHIND point_a, i.e. on the side it
## comes FROM, always off the camera. Derived from the direction instead of
## assuming a westward entry, so a westbound pass (point_b west of point_a) is
## just a matter of authoring the two points.
func _off_scene() -> Vector2:
	var rumo := (point_b - point_a).normalized()
	if rumo == Vector2.ZERO:
		return point_a - Vector2(spawn_distance, 0.0)
	return point_a - rumo * spawn_distance
