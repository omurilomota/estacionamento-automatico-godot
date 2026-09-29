# Dificuldade das fases — avaliação e o que falta para a Fase 5

> Documento de avaliação (em português), para apresentação e discussão em
> equipe. Para operação técnica, ver `README.md`, `FASE.md`, `AGENTS.md`.
>
> **Conclusão em uma linha:** a **Fase 5 precisa de trabalho mais complexo para
> o carro realmente enxergar as vagas**; as **Fases 6 a 9 são muito simples e
> não oferecem dificuldade real** — elas provam que o pipeline de geração
> funciona, não que o agente está sendo desafiado.

## 1. A tese

Duas afirmações, por ordem de importância:

1. **Fase 5** — hoje o carro estaciona nela, mas não *exercita* a percepção de
   vagas. Todas as vagas estão livres e idênticas, não há nada para
   discriminar. Falta trabalho para o caso virar um teste de verdade.
2. **Fases 6 a 9** — geometria correta, mas sem pressão: zero trânsito, quase
   sem obstáculo, e o carro resolve em segundos. São fases de fumaça, não de
   dificuldade.

O resto deste documento é a medição que sustenta essa leitura — e que, em um
ponto, precisa corrigi-la.

## 2. O que foi medido

Rodado em **27/09/2026**, `tools/gate_boot.gd` com spawn aleatório, 75 s por
fase. As Fases 2 e 3 entram como referência de dificuldade real.

| Fase | Baias | Fileiras | Passo | Profun. | `car_scale` | Vagas ocupadas | Cones | Trânsito | Boot |
|------|------:|---------:|------:|--------:|------------:|----------------:|------:|--------:|-----:|
| **5** | 16 | 2 | 166 px | **240 px** | **1.0** | **0 de 16** | 0 | 0 | 7,7 s |
| 6 | 16 | 2 | 262 px | 439 px | 1.4 | 3 | 0 | 0 | 7,4 s |
| 7 | 21 | 3 | 257 px | 439 px | 1.4 | 3 | 0 | 0 | 1,2 s |
| 8 | 16 | 4 | 162 px | 439 px | 1.4 | 6 | 4 | 0 | 7,6 s |
| 9 | 10 | 2 | 360 px | 439 px | 1.4 | 3 | 4 | 0 | 6,8 s |
| *Fase 2* | *4* | *1* | *—* | *314 px* | *1.8* | *1* | *3* | *1* | *46,9 s* |
| *Fase 3* | *4* | *1* | *—* | *314 px* | *2.0* | *1* | *3* | *0* | *49,8 s* |

Fonte: `tools/specs/Fase{5..9}.json` (geometria) e `/tmp/gate_boot_FaseN.log`
(tempo e contadores). Todas com `NEG_FRAMES=0` e `CONES hits=0`.

## 3. Por que a Fase 5 precisa de trabalho para "enxergar" as vagas

**a) As 16 vagas estão todas livres.** O spec da Fase 5 é o único dos cinco sem
o campo `parked`. Não existe **uma única decisão de vaga** no nível inteiro: o
carro não escolhe, ele para na primeira vaga que encontra. Isso deixa de fora
exatamente o que a percepção deveria provar — distinguir vaga livre de ocupada e
comparar custo e rumo entre candidatas.

**b) Não há nada no caminho.** Zero cones, zero trânsito. Entre o carro e a
vaga só tem chão. Com a `PerceptionSnapshot` e o `PathPlanner` intocados, o
resultado é garantido: não é um teste.

**c) É a única fase com `car_scale = 1.0`.** As Fases 6 a 9 usam 1.4. A Fase 5
é a única em que o carro **não fica no mesmo tamanho de tela** das irmãs
geradas (AGENTS #27: o zoom compensa; aqui 1.0 com zoom 0.95, lá 1.4 com zoom
0.62 a 0.71). Comparar dificuldade da 5 com as outras mede duas coisas
diferentes.

**d) É a mais rasa e uma das mais apertadas.** A profundidade de 240 px é 55%
da das outras (439 px). Medindo a folga como área da baia dividida pela área do
carro (88 × 74 na escala 1.0; 123 × 104 na 1.4):

| Fase | Baia | Carro | Folga aprox. |
|------|------|-------|--------------|
| 8 | 162 × 439 | 123 × 104 | **5,6×** (a mais apertada) |
| **5** | 166 × 240 | 88 × 74 | **6,1×** |
| 7 | 257 × 439 | 123 × 104 | 8,8× |
| 6 | 262 × 439 | 123 × 104 | 9,0× |
| 9 | 360 × 439 | 123 × 104 | 12,4× (a mais folgada) |

Ou seja: a Fase 5 é apertada **e** a que tem menos obstáculos. O aperto nunca
chega a ser testado contra nada.

**e) O defeito que governa a entrada na vaga — CORRIGIDO em 28/09/2026
(issue #6, AGENTS #17).** `Vaga._atualizar_boca_pos()` escrevia
`colisao_boca.position = -dir * 74.0` no espaço **local**, mas o nó da
vaga tem escala. A boca — o trigger que anuncia "entre na vaga" — acabava
a `74 × escala` do centro: ~140 px na Fase 5 e ~165 px nas Fases 6 a 9.
A boca agora é ancorada na ENTRADA em espaço global (meia-profundidade
escalada + 29 px, espessura 28 px no mundo); gates 9/9 boot, 9/10 seeds
(referência) e trail inalterado — ver docs/tasks_backlog.md §1.18.


## 4. Por que as Fases 6 a 9 são simples

**a) Nenhuma das cinco tem trânsito.** `Crosser` = 0 em todas. A cedência com
histerese (`CrosserGate`, AGENTS #21 e #32) só é exercitada na Fase 2 — a única
que registra `latches=1` no gate. Nas cinco geradas, essa lógica **nunca roda**.

**b) Três delas não têm obstáculo nenhum.** Cones = 0 nas Fases 5, 6 e 7. Só a
8 e a 9 têm 4 cones, e mesmo assim o gate mede folga de 231 px e 950 px: o
carro passa longe demais para o cone ser ameaça.

**c) O tempo de resolução é o argumento mais forte.** As fases geradas
estacionam em **1,2 s a 7,7 s**. As fases difíceis do projeto — as feitas à
mão, Fase 2 e Fase 3 — levam **46,9 s e 49,8 s**, com trânsito cedendo passagem,
rota A* longa e manobra final. Fator de ~7×. A diferença não é de ajuste de
parâmetro: é de conteúdo.

**d) A única com layout de verdade é a 7** (3 fileiras, 21 vagas), e ainda
assim resolve em 1,2 s. Uma fileira no meio não cria dificuldade quando as
outras duas são idênticas e livres.

## 5. Ressalva honesta: a Fase 8 não é trivial

A leitura "6 a 9 sem dificuldade" precisa de uma exceção honesta. **A Fase 8
já produziu um defeito real de pilotagem:**

- Em um boot de 5, o carro parou em `cte = 80.0` **exatos** — a fronteira do
  guarda em `src/vehicle/AutonomousDriver.gd` — e disparou **ré indevida por 12
  frames** (`NEG_FRAMES=12`), reprovando o `gate_boot`.
- Taxa medida: **1 falha em 5 boots (~20%)**, todas com o mesmo código.
- O carro **estacionou nas 5 observações**. O defeito não era não estacionar;
  era a ré indevida.
- Correção: incluir a fronteira no guarda (`cte < 80.0` → `cte <= 80.0`).
  Revalidado: **9/9 boots verdes e Fase8 ×5 = 5/5 com `NEG_FRAMES=0`**.

A Fase 8 é a única das quatro que já mordeu de verdade, e mordeu por geometria
apertada (4 fileiras, passo de 162 px, a menor folga do conjunto). **A Fase 9 é
a genuinamente trivial:** 10 vagas, passo de 360 px, 12,4× de folga, resolvida
em 6,8 s.

## 6. O que tornaria a Fase 5 um teste de percepção de verdade

Ordem de ataque sugerida — do que destrava mais pelo menos esforço:

1. ~~**Corrigir o AGENTS #17** (posição da boca em espaço global).~~ **FEITO
   em 28/09/2026** (issue #6) — ver docs/tasks_backlog.md §1.18.
2. **Ocupar vagas** no spec (`parked: [...]`), pelo menos metade das 16. Só isso
   cria a decisão que hoje não existe.
3. **Cones na faixa de circulação**, respeitando a folga medida do AGENTS #19
   (≥ `raio_varrido + raio_cone + 40` px da rota já deslocada) para virar
   obstáculo de verdade, e não enfeite a 231 px.
4. **Subir `car_scale` para 1.4** e reavaliar a profundidade de 240 px contra o
   casco escalado. Se não couber, aumentar a profundidade junto — e revalidar
   com `gate_boot` e `gate_seeds` da fase (AGENTS #27 e #41).
5. **Dar trânsito à Fase 5**, usando a geometria do `Crosser` da Fase 2, para
   a cedência passar a ser testada em layout gerado.

Só depois disso a Fase 5 vale como dificuldade. No estado atual ela serve como
**teste de sanidade do pipeline do gerador** — que é o que os gates medem hoje.

## 7. Como reproduzir estas medições

```bash
# geometria (sem Godot, instantâneo)
python3 - <<'PY'
import json
for n in range(5, 10):
    s = json.load(open(f"tools/specs/Fase{n}.json"))
    occ = sum(len(r.get("parked", [])) for r in s["rows"])
    print(f"Fase{n}: {sum(r['count'] for r in s['rows'])} baias, "
          f"{occ} ocupadas, {len(s.get('cones', []))} cones, "
          f"{len(s.get('crosser', []))} crosser")
PY

# boot real, uma fase por vez (nunca dois Godot juntos, AGENTS §14)
bash tools/run_gates.sh --fases=Fase5,Fase6,Fase7,Fase8,Fase9 --secs=75
```

Toda linha da tabela da §2 sai desses dois comandos. Nada aqui é opinião sem
lastro — exceto a tese da §1, que é avaliação da equipe.
