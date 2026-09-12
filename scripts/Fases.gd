class_name Fases
## Utilitário comum das fases — fonte ÚNICA das regras compartilhadas
## entre Mundo.gd e FaseBase.gd (evita duplicação e divergência).
## Legacy PT-BR shim: new code must use `LevelRegistry` (src/core/LevelRegistry.gd).
## Important: renomear nós ou rotas NAS CENAS não quebra este script;
## a ordem das rotas vem da ordem dos filhos no nó `Rotas` (Carro.gd).

const FASES := [
	"res://scenes/fases/Fase1.tscn",
	"res://scenes/fases/Fase2.tscn",
	"res://scenes/fases/Fase3.tscn",
	"res://scenes/fases/Fase4.tscn",
	"res://scenes/fases/Fase5.tscn",
]

const NOMES_ESTADO := {
	"BUSCANDO": "Buscando vaga",
	"DESVIANDO": "Desviando de obstáculo!",
	"ALINHANDO": "Alinhando para estacionar",
	"ESTACIONADO": "Estacionado!",
	"RECUPERANDO": "Recuperando...",
}


# Melhor rota Line2D para o carro (fallback qdo não há A*).
# `rotas_node` é o nó que contém as Line2D (ex.: Rotas); `posicao_carro`
# e `vagas` servem como referência para a pontuação de cada rota.
static func coletar_pontos_rotas(rotas_node: Node, posicao_carro: Vector2, vagas: Node) -> Array:
	# Legacy PT-BR shim -> canonical logic in LevelRegistry.
	return LevelRegistry.collect_route_points(rotas_node, posicao_carro, vagas)
