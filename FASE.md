# Fases do Estacionamento (mapas reais)

Cada mapa de `estacionamento/` virou uma **situação-teste** (fase). O carro já tem o comportamento agêntico (recuperação com tentativas), então cada fase serve para testar como ele se sai em cenários diferentes.

## Como rodar

| Tecla | Ação |
|---|---|
| `1` / `2` / `3` / `4` / `5` | Troca de fase (funciona na demo E nas fases) |
| `R` | Reinicia a cena atual |

Para rodar uma fase direto no editor: menu **Play** ▶ ou **F5** roda a cena principal (`Mundo.tscn`). Para abrir uma fase específica, dê dois cliques na cena (`scenes/fases/FaseN.tscn`) e aperte **F6** (rodar cena atual).

> **Para VER a imagem do estacionamento:** as 5 fases já têm o mapa real carregado
> (`Mapa` → `mapa` = `estacionamento/parking_lot.jpg`, `parking_lot2.svg`,
> `parking_lot3.svg`, `parking_lot4.jpg` e `Parkinglot5.jpeg`). Rodando a demo (F5), aperte **1**,
> **2**, **3**, **4** ou **5** para abrir cada uma. O `FaseBase.gd` posiciona a imagem,
> cria as paredes, ajusta a câmera e o minimapa automaticamente (tamanho =
> `largura da imagem × escala_mapa`).
>
> Para usar **uma imagem sua**: coloque o arquivo em `estacionamento/`, abra a
> cena da fase e no nó raiz (`FaseBase`) arraste a imagem para `mapa`
> (ajuste `escala_mapa`/`zoom_camera` no Inspector).

## Posição de partida do carro

- `posicao_aleatoria` (export no nó raiz): ligado por padrão — o carro nasce
  em uma **célula livre sorteada** (nunca em cima de obstáculo nem de vaga).
- Desligue (`false`) para usar a posição que você deixar no nó `Carro` da cena.

## O que cada fase já tem

- **Mapa** (`Mapa`): a imagem do estacionamento **já aparece no editor** (textura +
  escala gravadas na cena) e em jogo (`escala_mapa`). É o seu "chão" de trabalho.
- **Paredes do perímetro** (`LimiteAutomatico`): geradas automaticamente em volta do mapa — o carro não sai dele.
- **Câmera** (`Camera`): segue o carro, sem sair das bordas (`zoom_camera` ajusta o zoom).
- **UI**: status, sensor e tentativa (igual à cena de demonstração).
- **Carro**: já instanciado (posição provisória — mova para onde quiser).

> **Importante (modo automático):** com `Carro.auto_navegacao = true`, o carro
> **ignora os waypoints** — ele traça a própria rota (A*) até a vaga mais próxima.
> O que realmente importa montar são as **VAGAS** (o objetivo) e os **OBSTÁCULOS**
> (o que ele deve evitar).

## Como montar uma fase (passo a passo)

> Ordem recomendada: **1º vagas → 2º obstáculos → 3º ajustes**.

### 1. Colocar o OBJETIVO (as vagas onde o carro estaciona)

1. Abra a fase: clique duas vezes em `scenes/fases/FaseN.tscn` (o mapa aparece no editor).
2. No **FileSystem**, ache `scenes/Vaga.tscn` e **arraste** uma instância para o nó `Vagas` (no painel Scene).
3. Posicione a vaga **sobre uma vaga desenhada no mapa** (os retângulos verdes são o contorno).
4. Ajuste `rotacao_alvo` no Inspector da vaga — é a direção em que o **nariz do carro** aponta quando estacionado:
   - nariz para **cima** → `-1.5708`
   - nariz para a **direita** → `0`
   - nariz para **baixo** → `1.5708`
   - nariz para a **esquerda** → `3.14159`
5. (Opcional) Force o carro a ir **sempre para uma vaga específica**: selecione o nó `Carro` → Inspector → `vaga_prioritaria` → arraste a vaga para o campo.
6. Duplique (Ctrl+D) para as demais vagas, girando cada uma conforme a orientação.

Rodando a fase (F6): o carro escolhe a vaga livre mais próxima, desenha a rota
amarela e a grade no chão, estaciona e a vaga fica **vermelha**.

### 2. Colocar OBSTÁCULOS (carros estacionados, guias, canteiros)

- **Carros estacionados (proibidos):** arraste `scenes/Obstaculo.tscn` para o nó
  `Obstaculos`. Gire o nó para a orientação do carro no mapa. Ele já tem
  `collision_layer = 2` — o carro não vai conseguir entrar nessa vaga (rota desvia).
- **Muros/colunas:** `Paredes` → **+** → `StaticBody2D` → **+** → `CollisionShape2D`
  (retângulo sobre o muro), `collision_layer = 2`.

### 3. Ajustes finais

- **Posição de partida:** `posicao_aleatoria` (nó raiz) = `false` → use a posição
  que você arrastar no nó `Carro`. Com `true`, o carro nasce numa célula livre sorteada.
- **Escala/zoom:** nó raiz → `escala_mapa` e `zoom_camera`.
- O **minimapa** (canto inferior direito) mostra as vagas (verde = livre, vermelha = ocupada) e o carro automaticamente.

## Estrutura de arquivos

```
scenes/fases/
  Fase1.tscn      # estacionamento/parking_lot.jpg   (escala_mapa = 0.4)
  Fase2.tscn      # estacionamento/parking_lot2.svg  (escala_mapa = 3.0)
  Fase3.tscn      # estacionamento/parking_lot3.svg  (escala_mapa = 3.0)
  Fase4.tscn      # estacionamento/parking_lot4.jpg  (escala_mapa = 3.8)
  Fase5.tscn      # estacionamento/Parkinglot5.jpeg  (escala_mapa = 1.0)
estacionamento/   # mapas reais (JPG/SVG) usados como chão das fases
```