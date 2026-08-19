# Fases do Estacionamento (mapas reais)

Cada mapa de `estacionamento/` virou uma **situação-teste** (fase). O carro já tem o comportamento agêntico (recuperação com tentativas), então cada fase serve para testar como ele se sai em cenários diferentes.

## Como rodar

| Tecla | Ação |
|---|---|
| `1` / `2` / `3` | Troca de fase |
| `R` | Reinicia a fase atual |

Para rodar uma fase direto no editor: menu **Play** ▶ ou **F5** roda a cena principal (`Mundo.tscn`). Para abrir uma fase específica, dê dois cliques na cena (`scenes/fases/FaseN.tscn`) e aperte **F6** (rodar cena atual).

## O que cada fase já tem

- **Mapa** (`Mapa`): a imagem do estacionamento já posicionada e ampliada (`escala_mapa`).
- **Paredes do perímetro** (`LimiteAutomatico`): geradas automaticamente em volta do mapa — o carro não sai dele.
- **Câmera** (`Camera`): segue o carro, sem sair das bordas (`zoom_camera` ajusta o zoom).
- **UI**: status, sensor e tentativa (igual à cena de demonstração).
- **Carro**: já instanciado (posição provisória — mova para onde quiser).

## O que falta montar em cada fase (seu trabalho no editor)

> Ordem recomendada: **paredes → obstáculos → waypoints → vagas**.

### 1. Paredes (muros, guias, colunas)
1. Selecione `Paredes` (segure **Ctrl** e clique num nó para adicionar filho).
2. **+** → `StaticBody2D`.
3. **+** → `CollisionShape2D` e desenhe o retângulo (`RectangleShape2D`) sobre o muro.
4. Repita para cada parede. Dica: para muros retos, duplique o primeiro e arraste.
5. Deixe `collision_layer = 2` (mesma máscara dos sensores do carro).

### 2. Obstáculos (carros estacionados)
Duplique um obstáculo pronto da cena `Mundo.tscn` (ex.: `Obstaculos/SedanVermelho`):
1. Abra `Mundo.tscn`, selecione o obstáculo, **Ctrl+D** (duplicar) e **Ctrl+C/Ctrl+V** na sua fase (arraste para `Obstaculos`).
2. O obstáculo tem: `StaticBody2D` (layer 2) + `Sprite2D` (o desenho) + `CollisionShape2D`.
3. Gire o `Sprite2D` junto com o `StaticBody2D` para a orientação do carro no mapa.

### 3. Waypoints (a rota do carro)
1. Em `Waypoints`, adicione `Marker2D` (ícone de bandeira) em pontos da via: entrada, curvas, área da vaga.
2. Nomeie em ordem: `W1`, `W2`, `W3`... A ordem dos filhos é a ordem da rota.
3. Deixe espaço entre os waypoints (eles servem de guia, não de trilho rígido).

### 4. Vagas (onde o carro estaciona)
1. Em `Vagas`, adicione `Vaga.tscn` (do `FileSystem`, arraste para o nó `Vagas`).
2. Posicione sobre uma vaga do desenho e ajuste `rotacao_alvo` no Inspector:
   - vaga vertical (entrada pela lateral) → `-1.5708` ou `1.5708` (PI/2)
   - vaga horizontal → `0` ou `3.14159`
3. Quando o carro entra na área, a vaga fica vermelha e ele alinha automaticamente.

## Ajustes úteis

- **Escala do mapa**: selecione o nó raiz da fase → Inspector → `escala_mapa` (o mapa fica centralizado na origem).
- **Zoom**: nó raiz → `zoom_camera` (menor que 1 = mais zoom out).
- **Posição do carro**: nó `Carro` → arraste na cena.
- **Limites do perímetro**: todos os mapas têm margens; se o mapa não preencher a área, aumente `escala_mapa` ou mova o `Mapa`.

## Estrutura de arquivos

```
scenes/fases/
  FaseBase.gd     # esqueleto compartilhado (mapa, câmera, paredes, UI, teclas)
  Fase1.tscn      # parking_assets.png
  Fase2.tscn      # parking_assets_map.svg (importado pelo Godot)
  Fase3.tscn      # parking_assets_map_02.png
assets/mapas/     # mapas já pré-renderizados (PNG) ou copiados (SVG)
```