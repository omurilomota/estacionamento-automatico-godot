extends Control
# Controle runtime para rotas Line2D nomeadas e debug

@onready var check_grade: CheckBox = $VBox/CheckGrade
@onready var check_rota: CheckBox = $VBox/CheckRota
@onready var check_rotas: CheckBox = $VBox/CheckRotas
@onready var check_auto: CheckBox = $VBox/CheckAuto
@onready var combo_rotas: OptionButton = $VBox/ComboRotas
@onready var planejador: Node = get_node("../../../Planejador")
@onready var rotas_node: Node = get_node("../../../Rotas")
@onready var carro: Node = get_node("../../../Carro")

func _ready() -> void:
	if planejador:
		check_grade.button_pressed = planejador.mostrar_grade
		check_rota.button_pressed = planejador.mostrar_rota
	if rotas_node:
		check_rotas.button_pressed = rotas_node.visible
		combo_rotas.clear()
		combo_rotas.add_item("Todas")
		for c in rotas_node.get_children():
			if c is Line2D:
				combo_rotas.add_item(c.name)
	if carro:
		# Em modo trilha, o checkbox reflete modo_trilha + auto_navegacao
		if "modo_trilha" in carro:
			check_auto.button_pressed = carro.modo_trilha or carro.auto_navegacao
		else:
			check_auto.button_pressed = carro.auto_navegacao
	# Conectar sinais
	check_grade.toggled.connect(_on_grade_toggled)
	check_rota.toggled.connect(_on_rota_toggled)
	check_rotas.toggled.connect(_on_rotas_toggled)
	check_auto.toggled.connect(_on_auto_toggled)
	combo_rotas.item_selected.connect(_on_rota_selected)

func _on_grade_toggled(v: bool) -> void:
	if planejador:
		planejador.mostrar_grade = v
		planejador.queue_redraw()

func _on_rota_toggled(v: bool) -> void:
	if planejador:
		planejador.mostrar_rota = v
		planejador.queue_redraw()

func _on_rotas_toggled(v: bool) -> void:
	if rotas_node:
		rotas_node.visible = v
		for c in rotas_node.get_children():
			c.visible = v

func _on_auto_toggled(v: bool) -> void:
	if carro:
		carro.auto_navegacao = v
		if "modo_trilha" in carro:
			carro.modo_trilha = v
			if v and carro.has_method("iniciar_modo_trilha"):
				carro.iniciar_modo_trilha()

func _on_rota_selected(idx: int) -> void:
	if rotas_node == null:
		return
	var nome = combo_rotas.get_item_text(idx)
	if nome == "Todas":
		for c in rotas_node.get_children():
			c.visible = true
			c.default_color = Color(0.2, 0.8, 1, 0.6)
	else:
		for c in rotas_node.get_children():
			var is_sel = c.name == nome
			c.visible = true
			c.default_color = Color(1, 0.9, 0.2, 1) if is_sel else Color(0.2, 0.8, 1, 0.3)
		# Opcional: focar carro nessa rota (usa trilha se modo_trilha ativo)
		if carro and rotas_node.has_node(nome):
			var line: Line2D = rotas_node.get_node(nome)
			var pts: PackedVector2Array = line.points
			if pts.size() >= 2:
				var arr: Array[Vector2] = []
				for p in pts:
					arr.append(line.to_global(p))
				if "modo_trilha" in carro and carro.modo_trilha:
					carro.definir_trilha(arr)
				else:
					carro.definir_waypoints(arr)
				carro.auto_navegacao = false
				if "modo_trilha" in carro:
					carro.modo_trilha = false
				check_auto.button_pressed = false
