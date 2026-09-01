# Estacionamento Autônomo

Simulação 2D (vista de cima) de estacionamento autônomo em Godot 4.x. O carro percorre a pista usando sensores Raycast2D e uma máquina de estados, decidindo sozinho quando buscar a vaga, desviar de obstáculos e alinhar-se para estacionar.

## Objetivo

Criar um robô autônomo onde o carro não segue um script fixo: ele coleta dados do ambiente em tempo real usando sensores Raycast2D e toma decisões baseadas em uma máquina de estados finitos (FSM), aplicando planejamento de trajetória via navegação A*.

## Integrantes e Responsabilidades

| Integrante | Papel | Responsabilidades |
| --- | --- | --- |
| Gian | Designer / Artista | Sprites top-down do carro, vaga (livre/ocupada), obstáculos, paredes e UI. Exportar PNG com fundo transparente e manter a mesma escala (ex: 64x64 ou 128x128). |
| Murilo | Programador (Cérebro do Carro) | Lógica do carro em `Carro.tscn` e `scripts/Carro.gd`: física (CharacterBody2D), sensores Raycast2D, máquina de estados (BUSCANDO, DESVIANDO, ALINHANDO, ESTACIONADO, RECUPERANDO) e navegação. |
| Matheus | Programador (Mundo e Interação) | Cenário em `Mundo.tscn`, lógica das vagas em `Vaga.tscn` e `scripts/Vaga.gd`, interface (UI) e waypoints. |

## Arquitetura

### Máquina de Estados (FSM)

O carro passa por estados que refletem o comportamento de direção humano:

| Estado | Descrição |
| --- | --- |
| `BUSCANDO` | Segue um waypoint alvo com aceleração e direção suaves. |
| `DESVIANDO` | Raycast da frente detectou obstáculo: vira o volante até o sensor limpar. |
| `ALINHANDO` | Perto da vaga: para de andar e gira sobre o próprio eixo até a rotação correta. |
| `ESTACIONADO` | Dentro da vaga e alinhado: carro parado, vaga marcada como ocupada. |
| `RECUPERANDO` | Sai da vaga (ré com estercamento) sem bater nas laterais. |

### Sensores

Três nós `RayCast2D` no carro:
- **Frente** — freia ao detectar obstáculo à frente.
- **Esquerda / Direita** — freia ao detectar obstáculo na lateral, influenciando a tomada de curva.

### Navegação

- **Planejador (A*)** — `scripts/Planejador.gd` calcula a rota entre waypoints.
- **ControleRotas** — `scripts/ControleRotas.gd` gerencia a lista de waypoints por fase.
- **Waypoints** — nós `Marker2D` posicionados no cenário por Matheus.

### Física do Carro

- Modelo de bicicleta: o estercamento vira aos poucos e o carro só curva quando em movimento.
- Entre-eixos escalável conforme o tamanho visual do sprite.
- Rampa suave de aceleração (0–160 em reta, cai em curva).

## Como Executar

1. Abra o projeto no **Godot 4.x**.
2. Execute a cena `scenes/Mundo.tscn`.
3. Selecione a fase com as teclas **1** a **5** (cada fase tem waypoints e vagas distintas).
4. Pressione **R** para reiniciar a fase a qualquer momento.
5. O carro inicia em `BUSCANDO`, segue os waypoints, desvia de obstáculos com os sensores, alinha-se e estaciona na vaga.

## Estrutura de Cenas

```
scenes/
├── Mundo.tscn          # Cena principal: chão, paredes, UI, instância do carro.
├── Carro.tscn          # CharacterBody2D com sprites, RayCast2D e script Carro.gd.
├── Vaga.tscn           # Area2D com lógica de ocupação (sprite livre/ocupada).
├── Obstaculo.tscn      # StaticBody2D representando obstáculos ou carros parados.
├── Seta.tscn           # Indicador visual (opcional) para direção/alvo.
└── fases/
    ├── Fase1.tscn
    ├── Fase2.tscn
    ├── Fase3.tscn      # Waypoints manuais (auto_navegacao = false).
    ├── Fase4.tscn
    └── Fase5.tscn

scripts/
├── Carro.gd            # Lógica do carro, FSM e física.
├── Vaga.gd             # Estado da vaga e comunicação com o carro.
├── FaseBase.gd         # Base de fase: câmera, paredes, waypoints, UI.
├── Planejador.gd       # Navegação A*.
├── ControleRotas.gd    # Gerenciamento de waypoints.
├── Mundo.gd            # Orquestração da cena principal.
└── Minimapa.gd         # Renderização do minimapa (opcional).
```

## Regras de Ouro da Equipe

- Não editem a mesma cena (`.tscn`) ao mesmo tempo — o Godot não lida bem com isso.
- Sempre façam `pull` antes de codar e `push` ao concluir uma funcionalidade.
- Assets entregues na pasta `res://assets/sprites/` com nomes claros.

## 🗣️ Discurso para o Professor

> "Prof, nosso projeto simula um robô autônomo. O carro não segue um script fixo; ele usa sensores (Raycast2D) para coletar dados do ambiente em tempo real. O código é baseado em uma Máquina de Estados: ele decide sozinho quando buscar a vaga, quando desviar de um risco e quando alinhar para estacionar. É a aplicação prática de tomada de decisão autônoma que vimos em aula."
