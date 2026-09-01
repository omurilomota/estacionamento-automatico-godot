#!/usr/bin/env python3
"""FASE 3 — NEUROEVOLUÇÃO: algoritmo genético sobre os pesos da MLP.

Parte dos pesos do behavior cloning (ml/modelo/pesos.json) e evolui com
fitness medido pelo simulador (ml/avaliar.gd, determinístico e 4x rápido).
O melhor genoma substitui ml/modelo/pesos.json (o BC é preservado em
ml/modelo/pesos_bc.json).

Uso:  python3 ml/evoluir.py [pop] [geracoes]
      python3 ml/evoluir.py 12 8
"""

import json
import os
import shutil
import subprocess
import sys

import numpy as np

BASE = os.path.dirname(os.path.abspath(__file__))
MODELO = os.path.join(BASE, "modelo", "pesos.json")
BC_BACKUP = os.path.join(BASE, "modelo", "pesos_bc.json")
GODOT = os.environ.get("GODOT_BIN", "/home/murilo/Downloads/GODOT.x86_64")
PROJETO = os.path.dirname(BASE)

CHAVES = ["w1", "b1", "w2", "b2", "w3", "b3"]


def carregar_parametros():
    with open(MODELO) as f:
        m = json.load(f)
    shapes = {k: np.array(m[k]).shape for k in CHAVES}
    vetor = np.concatenate([np.array(m[k]).ravel() for k in CHAVES])
    return vetor, shapes, m


def salvar_parametros(vetor, shapes, destino, extra=None):
    m = dict(extra or {})
    i = 0
    for k in CHAVES:
        s = shapes[k]
        n = int(np.prod(s))
        m[k] = vetor[i:i + n].reshape(s).tolist()
        i += n
    with open(destino, "w") as f:
        json.dump(m, f)


def avaliar():
    """Roda o Godot headless e devolve o fitness do pesos.json atual."""
    r = subprocess.run(
        [GODOT, "--headless", "--path", PROJETO, "--script", "ml/avaliar.gd"],
        capture_output=True, text=True, timeout=120)
    for linha in r.stdout.splitlines():
        if linha.startswith("FITNESS"):
            return float(linha.split()[1])
    print("AVISO: sem FITNESS na saída do avaliador")
    print(r.stdout[-500:], r.stderr[-500:])
    return -9999.0


def principal(pop=12, geracoes=8):
    rng = np.random.default_rng(7)
    if not os.path.exists(BC_BACKUP):
        shutil.copy(MODELO, BC_BACKUP)
        print("backup do modelo BC salvo em", BC_BACKUP)
    base, shapes, meta = carregar_parametros()
    print(f"genoma: {base.size} pesos | pop {pop} | gerações {geracoes}")

    # população inicial: BC + mutações crescentes + 2 aleatórios leves
    pop_v = [base.copy()]
    for i in range(1, pop - 2):
        sigma = 0.02 + 0.06 * i / max(1, pop - 3)
        pop_v.append(base + rng.normal(0, sigma, base.size))
    pop_v.append(base + rng.normal(0, 0.15, base.size))
    pop_v.append(base + rng.normal(0, 0.30, base.size))

    melhor_v, melhor_f = None, -1e9
    historico = []
    for g in range(geracoes):
        fits = []
        for i, v in enumerate(pop_v):
            salvar_parametros(v, shapes, MODELO, meta)
            f = avaliar()
            fits.append(f)
            print(f"  g{g} ind{i:02d}: fitness {f:9.2f}", flush=True)
            if f > melhor_f:
                melhor_f, melhor_v = f, v.copy()
        ordem = np.argsort(fits)[::-1]
        historico.append((float(np.max(fits)), float(np.mean(fits))))
        print(f"GERAÇÃO {g}: melhor {max(fits):.2f} | média {np.mean(fits):.2f} | recorde {melhor_f:.2f}", flush=True)

        # nova população: elite + torneio + cruzamento + mutação
        elite_n = max(2, pop // 4)
        nova = [pop_v[j].copy() for j in ordem[:elite_n]]
        def torneio():
            a, b = rng.integers(0, pop, 2)
            return pop_v[a] if fits[a] >= fits[b] else pop_v[b]
        while len(nova) < pop:
            pa, pb = torneio(), torneio()
            mask = rng.random(base.size) < 0.5
            filho = np.where(mask, pa, pb)
            filho += rng.normal(0, 0.05, base.size)
            nova.append(filho)
        pop_v = nova

    # grava o melhor de todos os tempos
    salvar_parametros(melhor_v, shapes, MODELO, meta)
    with open(os.path.join(BASE, "modelo", "evolucao_historico.json"), "w") as f:
        json.dump({"historico": historico, "melhor_fitness": melhor_f}, f, indent=1)
    print(f"EVOLUCAO_CONCLUIDA melhor_fitness={melhor_f:.2f} (recorde gravado em pesos.json)")


if __name__ == "__main__":
    p = int(sys.argv[1]) if len(sys.argv) > 1 else 12
    g = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    principal(p, g)
