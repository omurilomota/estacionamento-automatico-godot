extends Node2D

const NOMES_ESTADO := {
	"BUSCANDO": "Buscando vaga",
	"DESVIANDO": "Desviando de obstáculo!",
	"ALINHANDO": "Alinhando para estacionar",
	"ESTACIONADO": "Estacionado!",
}

@onready var carro: Node2D = $Carro
@onready var waypoints: Node2D = $Waypoints
@onready var label_status: Label = $UI/Control/StatusLabel
@onready var label_sensor: Label = $UI/Control/SensorLabel


func _ready() -> void:
	var pontos: Array = []
	for wp in waypoints.get_children():
		pontos.append(wp.global_position)
	carro.definir_waypoints(pontos)
	carro.estado_mudou.connect(_ao_mudar_estado)
	label_status.text = "STATUS: " + NOMES_ESTADO.get(carro.nome_estado(), carro.nome_estado())
	label_sensor.text = "SENSOR: " + carro.descricao_sensor()


func _process(_delta: float) -> void:
	label_sensor.text = "SENSOR: " + carro.descricao_sensor()


func _ao_mudar_estado(nome: String) -> void:
	label_status.text = "STATUS: " + NOMES_ESTADO.get(nome, nome)