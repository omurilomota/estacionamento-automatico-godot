# Machine Learning — carro que dirige sozinho (imitação)

Plano em fases para tirar a dependência das linhas (Line2D): o carro passa a
dirigir **só com os sensores**, usando uma rede neural treinada a partir do
cérebro atual (behavior cloning). A FSM continua sendo o "juiz" da missão.

## Arquitetura

```
FSM (Carro.gd)  = missão: escolher vaga, ALINHANDO, ESTACIONADO
CerebroML.gd    = percepção -> ação (MLP 18-32-16-2, GDScript puro)
ml/treinar.py   = treino offline (numpy), exporta ml/modelo/pesos.json
```

- **Entradas (18):** 11 raios normalizados + velocidade + distância/ângulo
  até a vaga + seta do piso (dist, cos, sin).
- **Saídas (2):** estercamento (-1..1) e velocidade (0..1 × velocidade_maxima).
- Camadas de segurança continuam hard-coded (freio por distância_centro,
  fallback para o cérebro de trilha se a rede travar).

## Fases

1. **Gravar** (professor): `godot --headless --script ml/gravar.gd`
   → gera `ml/dados/<Fase>_ep<N>.csv` (~10k amostras).
2. **Treinar**: `python3 ml/treinar.py` (só numpy)
   → gera `ml/modelo/pesos.json` + métricas de validação.
3. **Testar**: `godot --headless --script ml/testar_ml.gd`
   → roda a fase com `modo_ml = true` (sem trilha) e reporta resultado.

## Uso no jogo

No inspetor do Carro: `modo_ml = true` (a rede carrega do JSON; se não
existir, cai automaticamente no modo trilha).

## Limitações conhecidas (honestas)

- Imitação só alcança o nível do professor — não inventa manobras novas
  (manobra de três tempos, por exemplo). Para isso vem a Fase 3:
  **neuroevolução** (GA sobre os pesos, GDScript puro).
- O modelo aprende os layouts gravados; fases novas podem exigir regravação.
