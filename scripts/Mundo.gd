extends Node2D

const NOMES_ESTADO := {
	"BUSCANDO": "Buscando vaga",
	"DESVIANDO": "Desviando de obstáculo!",
	"ALINHANDO": "Alinhando para estacionar",
	"ESTACIONADO": "Estacionado!",
	"RECUPERANDO": "Recuperando...",
}

@onready var carro: Node2D = $Carro
@onready var waypoints: Node2D = $Waypoints
@onready var vagas: Node2D = $Vagas
@onready var label_status: Label = $UI/Control/StatusLabel
@onready var label_sensor: Label = $UI/Control/SensorLabel
@onready var label_tentativa: Label = $UI/Control/TentativaLabel


func _ready() -> void:
	var pontos: Array = []
	for wp in waypoints.get_children():
		pontos.append(wp.global_position)
	carro.definir_waypoints(pontos)
	carro.estado_mudou.connect(_ao_mudar_estado)
	carro.tentativa_mudou.connect(_ao_mudar_tentativa)
	carro.pedir_nova_vaga.connect(_ao_pedir_nova_vaga)
	label_status.text = "STATUS: " + NOMES_ESTADO.get(carro.nome_estado(), carro.nome_estado())
	label_sensor.text = "SENSOR: " + carro.descricao_sensor()
	label_tentativa.text = "TENTATIVA: 0"


func _process(_delta: float) -> void:
	label_sensor.text = "SENSOR: " + carro.descricao_sensor()


func _ao_mudar_estado(nome: String) -> void:
	label_status.text = "STATUS: " + NOMES_ESTADO.get(nome, nome)


func _ao_mudar_tentativa(tentativas: int, estrategia: String) -> void:
	label_tentativa.text = "TENTATIVA: %d — %s" % [tentativas, estrategia]


func _ao_pedir_nova_vaga() -> void:
	# O carro esgotou as tentativas no último waypoint: escolhe a primeira vaga livre.
	for vaga in vagas.get_children():
		if not vaga.ocupada:
			label_tentativa.text = "TENTATIVA: 0 — Procurando outra vaga"
			carro.definir_waypoints([vaga.global_position])
			return
	label_status.text = "STATUS: Sem vagas livres"