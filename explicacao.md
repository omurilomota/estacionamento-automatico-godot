# Estacionamento Autônomo — explicação completa do projeto

> Documento de apresentação do projeto (em português). Para operação técnica
> dia a dia, ver `README.md`, `FASE.md`, `GUIDE.md`, `ml/README.md` e `AGENTS.md`.

## 1. O que é o projeto (resumo de 30 segundos)

É uma simulação 2D, vista de cima, feita no **Godot 4**, de um **carro-robô que
estaciona sozinho em vagas de estacionamentos reais**. O carro **não segue um
script fixo**: ele lê o mundo em tempo real com sensores (`RayCast2D`), decide
o que fazer com uma **máquina de estados** (missão) e dirige com **física de
modelo bicicleta**. Por cima disso, uma **rede neural aprende a dirigir
imitando o próprio “professor”** (*behavior cloning*) e um **algoritmo
genético evolui os pesos da rede** (*neuroevolução*).

Números que provam que funciona:

- **Fase 2 (modo trilha):** o carro percorre a rota desenhada e estaciona na
  `Vaga2` em **~35 s**, a 10,8 px do centro da vaga, alinhado (erro ≈ 0,02 rad),
  **sem dar ré nenhuma**.
- **Fase 3 (modo rede neural):** a MLP dirige sozinha e estaciona em
  **~50 s** sem cair no piloto automático de segurança (`usou_fallback=false`).
- **Neuroevolução:** melhor fitness **2979,25** (ou seja: estacionou em ~21 s no
  simulador determinístico).
- **Dataset:** 15.956 quadros gravados do professor, **rede 18→32→16→2** com
  erro de validação **MSE ≈ 0,004**.

## 2. O problema (por que estacionar sozinho é difícil)

Estacionar parece fácil para um humano, mas para um robô são três problemas
juntos:

1. **Percepção** — como o carro “enxerga” paredes, carros estacionados,
   calçadas e a vaga-alvo sem câmera de verdade?
2. **Decisão** — quando procurar vaga, quando desviar, quando alinhar, quando
   desistir e tentar de novo?
3. **Controle** — como transformar “quero ir para lá” em volante + acelerador
   suaves, sem bater, em cada quadro de física (60× por segundo)?

Nossa resposta: separar esses três papéis em **módulos com contratos claros**
(ver §10) e dar ao carro **três cérebros intercambiáveis** — um deles uma rede
neural de verdade.

## 3. A ideia central: um robô que sente, pensa e age

Todo quadro de física o carro faz o mesmo ciclo:

```
SENTIR  →  12 sensores RayCast2D medem distância até obstáculos
PENSAR  →  máquina de estados (missão) + cérebro (Trail / ML / A*)
escolhem volante + velocidade (DriveCommand)
AGIR    →  física de bicicleta move o carro; a cena reage
            (vaga muda de cor, minimapa atualiza, HUD mostra o estado)
```

Nada é “mágica”: cada decisão é uma função pura de números (distâncias,
ângulos, velocidades), o que permite **testar tudo sem abrir o jogo** —
rodamos fases inteiras no terminal (`--headless`) e medimos.

## 4. Os três cérebros (`DriverBrain`: Trail, ML, Autônomo)

O carro tem **três formas de dirigir**, trocáveis sem mexer no resto do código
(estratégia `DriverBrain`, tipos `TRAIL / AUTONOMOUS / ML`):

| Cérebro | Arquivo | Como dirige | Quando usar |
|---|---|---|---|
| **Trilha (Trail)** | `src/vehicle/TrailFollower.gd` + `PurePursuit.gd` | Segue uma rota pré-desenhada por `Line2D` (cada fase tem a sua). Só **para** se um obstáculo aparecer na frente — não improvisa. | Fases com rota desenhada (demo e gravação do professor). |
| **Rede neural (ML)** | `MlDriver` + `NeuralBrain` (pesos em `ml/modelo/pesos.json`) | Dirige **só pelos sensores**, sem rota desenhada, 60×/s. | A “mágica” da apresentação: o carro aprendeu a dirigir. |
| **Autônomo (A\*)** | `AutonomousDriver` + `PathPlanner` | Planeja sozinho sobre uma **grade de ocupação** (`AStarGrid2D`) até a vaga livre mais próxima. | Qualquer mapa novo: importa o que importa é vaga + obstáculo. |

A máquina de estados continua sendo o “juiz”: ela escolhe a vaga, decreta
`ALINHANDO`/`ESTACIONADO` e aplica camadas de segurança **acima** de qualquer
cérebro (freio de emergência, fallback para a trilha se a rede travar).

## 5. A máquina de estados — o “juiz” da missão

Cinco estados, ordem fixa (`SEEKING=0 … RECOVERING=4`, espelhada em PT-BR
`BUSCANDO…RECUPERANDO` para compatibilidade):

- **SEEKING (buscando)** — segue a rota / dirige com aceleração e volante
  suaves em direção ao alvo.
- **AVOIDING (desviando)** — sensor frontal bloqueado: para de ir para frente
  e vira até o leque de sensores limpar.
- **ALIGNING (alinhando)** — perto da vaga: aproxima devagar e gira até a
  proa bater com o ângulo-alvo da vaga (`rotacao_alvo`).
- **PARKED (estacionado)** — 100% dentro da vaga e alinhado: trava, marca a
  vaga como ocupada (ela fica vermelha).
- **RECOVERING (recuperando)** — travou? Faz manobra de 3 tempos (ré girando,
  pausa, frente girando) ou ré prolongada, em vez de “tentar na sorte”.

Sinais em inglês (`state_changed`, `attempt_changed`,
`spot_change_requested`) alimentam o HUD; a regra de ouro do projeto é que a
**vaga nunca chama método do carro** — quem decide “quem estaciona onde” é o
orquestrador (`LevelManager`), não o `Area2D`.

## 6. Sensores — os “olhos” do carro

São **12 `RayCast2D`** presos ao carro, lidos a cada quadro (`SensorArray`):

- **Leque frontal curto** (centro, esquerda, direita) — freio e desvio.
- **Laterais** (esquerda/direita, perto/longe) — não raspar nas paredes da vaga.
- **Traseira** — ré segura nas manobras.
- **Longo alcance** (centro/esquerda/direita) — “visão de longe”: antecipa e
  desvia **antes** de chegar perto do obstáculo.
- **Seta do piso** — lê as setas de fluxo pintadas no chão e mistura a direção
  delas na decisão (como um motorista que segue a sinalização).

Regra de projeto: **cérebros nunca tocam nos raios** — recebem um
`PerceptionSnapshot` (distâncias + velocidade + alvo). Isso permite testar a
“inteligência” sem abrir o Godot.

## 7. Física — modelo bicicleta (locomoção)

O carro é um `CharacterBody2D` que se move como bicicleta real (`Locomotion`):

- O volante tem **rampa** (vira aos poucos, não teleporta).
- **Só vira andando** — com velocidade ~0 o giro é zero, como motorista real.
- O **entre-eixos escala com o tamanho visual** do carro.
- Acelera forte na reta (até 160) e **alivia nas curvas** (freio preditivo por
  curvatura do caminho).
- Travas de segurança do motor Godot (`#94928`, velocidade zero) documentadas
  para não quebrar a física.

## 8. Planejamento de rota — A\* e trilhas desenhadas

- **Planejador A\*** (`PathPlanner` sobre `AStarGrid2D`): constrói a grade de
  ocupação **depois** que os obstáculos entram no mundo, traça a rota até a
  vaga e acha posição livre para nascer (nunca dentro de vaga).
- **Trilhas `Line2D`**: cada fase tem faixas desenhadas no editor
  (`Rota1/Rota2/Rota3…`); o seguidor usa **pure pursuit** (mira num ponto à
  frente da rota, não no ponto exato — por isso as curvas saem suaves, como
  as de um motorista).
- **Setas** dão peso ao custo do A\* (a favor = 0,7; contra = 1,4).
- **Grafo viário** (`resources/RoadGraph.tres`): mapa HD artesanal do
  estacionamento 5 (faixas com largura e sucessores) — a direção futura para
  rotas “de rua”, como num carro autônomo de verdade.

## 9. Vagas e os dois gatilhos

Cada vaga (`Vaga.tscn`, nova API `ParkingSpot`) é um `Area2D` com:

- **Área** (o retângulo da vaga): carro entrou → estado de alinhamento.
- **Boca** (a “entrada”): carro passou pela boca → ponto de preparação para
  ter espaço de manobra.
- **Ângulo-alvo** (`rotacao_alvo`): para onde o nariz do carro deve apontar
  parado (0 = leste, ±1,57 = norte/sul, 3,14 = oeste). Tem que bater com o
  lado de onde o carro chega — foi exatamente esse desencontro que travou a
  Fase 2 (“vira e volta”) e que corrigimos.

Só vira ocupada (vermelha) quando o carro está **100% dentro + alinhado +
perto do centro** — critério de humano, não de “encostou, valeu”.

## 10. Redes neurais — a parte de IA (behavior cloning)

A rede neural do carro **não foi programada para dirigir**: ela **aprendeu
assistindo o professor dirigir**. É *behavior cloning* (clonagem de
comportamento), a mesma ideia dos primeiros carros autônomos:

1. **GRAVAR — o professor dirige** (`ml/gravar.gd` no Godot): o cérebro atual
   (modo trilha) dirige as fases e a cada quadro salvamos uma linha CSV:
   **18 entradas → 2 ações tomadas naquele instante**.
2. **TREINAR — Python puro** (`ml/treinar.py`, só `numpy`): uma MLP aprende a
   mapear entradas → ações por regressão (erro quadrático, otimizador Adam,
   parada antecipada). Os pesos saem em `ml/modelo/pesos.json`.
3. **DIRIGIR — a rede no volante** (`CerebroML.gd`, forward-pass 100% em
   GDScript, sem dependência externa): em `modo_ml` a FSM vira “juíza”
   (escolhe a vaga e declara `ESTACIONADO`) e a rede decide volante +
   velocidade 60×/s. Sem modelo, cai de volta para a trilha sozinha.
4. **AVALIAR** (`ml/testar_ml.gd`): roda a fase de ponta a ponta e imprime o
   veredito — hoje: `ESTACIONADO em ~50s (usou_fallback=false)`.

### A rede, em números

- **Arquitetura: MLP 18 → 32 (tanh) → 16 (tanh) → 2 (linear)** — ~1.200
  parâmetros, cabe num JSON de ~25 KB e roda em microssegundos por quadro.
- **18 entradas:** 11 raios normalizados (0 = colado, 1 = livre) +
  velocidade + distância até a vaga + seno/cosseno do erro angular até a
  vaga + seta do piso (achou? 0/1, cosseno e seno da direção relativa).
- **2 saídas:** volante (−1…1) e velocidade desejada (0…1 × máxima).
- **Treino:** 400 épocas máx., lotes de 256, taxa 0,001, semente 42,
  10% para validação, paciência de 30 épocas — **MSE de validação ≈ 0,004**.
- **Dataset real do projeto:** **15.956 quadros**
  (`Fase1_ep0` 3.726, `Fase2_ep0` 3.726, `Fase3_ep0` 1.516,
  `Fase3_ep1` 3.729, `Fase3_ep2` 3.259), cada linha com 20 colunas
  (18 entradas + 2 ações do professor).
- **Segurança honesta:** a rede só imita o que viu — manobra inédita
  (ex.: baliza em 3 tempos) ela não inventa; por isso há freio de
  emergência por distância e fallback automático.

## 11. Neuroevolução — a rede que evolui sozinha

Depois da imitação vem a evolução (`ml/evoluir.py` + `ml/avaliar.gd`): um
**algoritmo genético** parte dos pesos clonados e os muta/cruza; cada
candidato é testado **de verdade no simulador** (Fase 3 determinística, 4×
mais rápida) e ganha um **fitness**: `estacionou → 3000 − tempo`, senão
`−distância até a vaga`. Elite + torneio + mutação, geração após geração; o
melhor genoma vira o novo `pesos.json` (o clone original fica guardado em
`pesos_bc.json`, com histórico em `evolucao_historico.json`).

- Melhor fitness registrado: **2979,25** — ou seja, estacionou em ~21 s.
- É a ponte clássica da IA entre *aprender com exemplos* (clonagem) e
  *aprender tentando* (evolução/reforço).

## 12. Robôs, inovação e por que isso importa

Um “robô” não precisa ter braços: precisa **perceber, decidir e agir em malha
fechada no mundo real (ou simulado)**. Este projeto é um robô completo nesse
sentido — e uma maquete fiel de como a indústria faz carro autônomo:

- **Percepção → decisão → ação** separados e testáveis (como nos stacks
  reais: sensores, planejamento, controle).
- **Simulação antes da rua**: tudo é medido no simulador headless — velocidade,
  distância ao centro da vaga, quadros em ré, tempo até estacionar. Nenhuma
  afirmação aqui é “achismo”: cada número tem um comando que o reproduz.
- **Aprendizado de máquina de verdade**: dataset próprio, treino com validação,
  modelo versionado, avaliação ponta a ponta e evolução por fitness — o ciclo
  completo de MLOps em miniatura, sem biblioteca mágica (numpy no treino,
  GDScript puro na inferência).
- **Mapa HD artesanal** (`RoadGraph.tres`) apontando para navegação por faixas.
- **Inovação prática**: estacionamento autônomo resolve dor real (tempo
  procurando vaga, batidas em manobra, acessibilidade) — e o mesmo cérebro
  (sensores → estados → controle) serve para robôs de armazém, aspiradores e
  cadeiras de rodas autônomas.

## 13. As 5 fases (os “cenários de teste”)

Cada fase usa foto/mapa real de estacionamento como chão, com vagas,
obstáculos (carros parados, calçadas, paredes), rotas e minimapa. Teclas
**1–5** trocam de fase, **R** reinicia:

| Fase | Mapa | Situação | Estado atual |
|---|---|---|---|
| **1** | `parking_lot.jpg` | Ruas norte/sul, 3 vagas | Rota pronta; carro trava parado por obstáculo na rota (caso documentado, não é regressão) |
| **2** | `parking_lot2.svg` | Corredor até a fileira de 4 vagas | **Estaciona na Vaga2 em ~35 s**, centrado (10,8 px), alinhado, sem ré ✅ |
| **3** | `parking_lot3.svg` | Curva + retas, 4 vagas | **Referência**: professor e rede neural estacionam (~50 s, sem fallback) ✅ |
| **4** | `parking_lot4.jpg` | Circuito retangular, 8 vagas | Rota pronta; entra em alinhamento no meio da rota (caso documentado, não é regressão) |
| **5** | `Parkinglot5.jpeg` | Mapa HD com rotatória | Cena maior/divergente; usa o grafo viário artesanal |

Dá para jogar qualquer imagem própria como chão: basta arrastar para o campo
`mapa` da fase e ajustar `escala_mapa`/`zoom_camera`.

## 14. Para a banca: roteiro de demonstração (5 minutos)

1. **(30 s) O problema** — “Estacionar exige ver, decidir e manobrar ao mesmo
   tempo. Nosso carro-robô faz os três em malha fechada, 60 vezes por segundo.”
2. **(1 min) Os olhos** — abrir a Fase 3 e mostrar os 12 raios + HUD
   (`STATUS`/`SENSOR`); aproximar de obstáculo e ver o `DESVIANDO`.
3. **(1 min) O cérebro clássico** — Fase 2 (tecla **2**): o carro segue a rota
   azul, entra na baia e estaciona sozinho (~35 s, sem ré).
4. **(1 min 30 s) O cérebro neural** — explicar o pipeline em 3 frases
   (professor grava CSV → Python treina MLP 18-32-16-2 → GDScript dirige) e
   rodar `ml/testar_ml.gd`: `ESTACIONADO em ~50s (usou_fallback=false)`.
5. **(30 s) A evolução** — mostrar `evolucao_historico.json` (fitness 2979,25:
   estacionou em ~21 s) e dizer que o simulador virou “academia” da rede.
6. **(30 s) Fechamento** — “Sensores, estados, controle, aprendizado e
   evolução — o mesmo ciclo dos carros autônomos reais, aqui simulado e
   medido de ponta a ponta.”

### Perguntas difíceis (e respostas honestas)

- *“A rede dirige sozinha mesmo?”* — Sim, **só com os sensores**, sem rota
  desenhada — mas com freio de emergência e fallback; o teste registra se o
  fallback foi usado (hoje: não foi).
- *“Por que não aprende baliza em 3 tempos?”* — Porque imitação só repete o
  que viu; manobra nova é papel da neuroevolução (fase seguinte).
- *“E se mudar o mapa?”* — Regrava-se o professor naquele mapa (minutos) e
  retreina-se (minutos). Modelo é dado versionado, não código.
- *“Qual a maior limitação?”* — Os gatilhos das vagas e a física são da
  simulação 2D; migrar para 3D/LiDAR seria o próximo degrau (a arquitetura
  em módulos foi feita exatamente para permitir isso).

## 15. Equipe e papéis

| Membro | Papel | Entrega |
|---|---|---|
| Gian | Designer / Artista | Sprites top-down, vagas livre/ocupada, obstáculos, UI |
| Murilo | Programador (cérebro) | Veículo, sensores, máquina de estados, navegação, ML |
| Matheus | Programador (mundo) | Fases, lógica das vagas, HUD, waypoints |

Feito em **Godot 4.7** (renderizador GL Compatibility), GDScript + Python
(só `numpy` no treino). Controles: **1–5** trocam de fase, **R** reinicia.
