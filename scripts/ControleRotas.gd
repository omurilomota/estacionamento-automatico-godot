extends Control
# Controle runtime para rotas Line2D nomeadas e debug

@onready var check_grade: CheckBox = $VBox/CheckGrade
@onready var check_rota: CheckBox = $VBox/CheckRota
@onready var check_rotas: CheckBox = $VBox/CheckRotas
@onready var check_auto: CheckBox = $VBox/CheckAuto
@onready var combo_rotas: OptionButton = $VBox/ComboRotas
@onready var planejador: Node = _resolve("Planejador")
@onready var rotas_node: Node = _resolve("Rotas")
@onready var carro: Node = _resolve("Carro")

## Injeção opcional de referências (AGENTS #8). Preenchido por
## `set_routes`/`src/ui/DebugRoutePanel.gd`; quando vazio, vale a busca
## legada por nome relativo — é o que mantém as cenas antigas funcionando.
var _injetado: Dictionary = {}


## Resolve uma referência da nível pelo NOME, sem depender da PROFUNDIDADE do
## painel. As `../../../` fixas quebravam assim que a UI ganhasse um nível a
## mais (o painel agora vive dentro de `UI/Control/DebugPanel/`).
## A versão base sobe a árvore até achar o nó; subclasses (DebugRoutePanel)
## sobrescrevem com caminhos declarados na cena.
func _resolve(nome: String) -> Node:
	if _injetado.has(nome):
		return _injetado[nome]
	var n: Node = self
	while n != null:
		var alvo := n.get_node_or_null(nome)
		if alvo != null:
			return alvo
		n = n.get_parent()
	return null


## Injeta uma referência (o HUD chama com o nó `Rotas` da fase).
func set_routes(node: Node) -> void:
	_injetado["Rotas"] = node
	if node == null:
		return
	rotas_node = node
	_preencher_rotas()


func _preencher_rotas() -> void:
	if rotas_node == null or combo_rotas == null:
		return
	check_rotas.set_pressed_no_signal(rotas_node.visible)
	combo_rotas.clear()
	combo_rotas.add_item("Todas")
	for c in rotas_node.get_children():
		if c is Line2D:
			combo_rotas.add_item(c.name)

func _ready() -> void:
	if planejador:
		check_grade.button_pressed = planejador.mostrar_grade
		check_rota.button_pressed = planejador.mostrar_rota
	if rotas_node:
		_preencher_rotas()
	if carro:
		# O checkbox reflete o modo REAL do carro (autônomo = ligado).
		if carro.has_method("modo_atual"):
			check_auto.button_pressed = int(carro.call("modo_atual")) == 1
		elif "modo_trilha" in carro:
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

## Checkbox "Auto Navegação": LIGADO = piloto autônomo (rota A* própria),
## DESLIGADO = modo trilha (segue as Rotas Line2D). Equivale à tecla T.
func _on_auto_toggled(v: bool) -> void:
	if carro == null:
		return
	if carro.has_method("definir_modo"):
		carro.call("definir_modo", 1 if v else 0)
		return
	# Carro legado (sem definir_modo): comportamento antigo.
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
				# Focar uma rota individual = seguir ESSA linha no modo trilha.
				# manter_rota=true impede o replanejamento pendente de
				# sobrescrever a escolha no frame seguinte (bug antigo do combo).
				if carro.has_method("definir_modo"):
					carro.call("definir_modo", 0, true)
				if "modo_trilha" in carro and carro.modo_trilha:
					carro.definir_trilha(arr)
				else:
					carro.definir_waypoints(arr)
				check_auto.set_pressed_no_signal(false)
