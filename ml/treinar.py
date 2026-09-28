#!/usr/bin/env python3
"""FASE 2 — TREINO (behavior cloning) do estacionamento automático.

Lê os CSVs gravados pelo cérebro atual (godot --headless --script ml/gravar.gd),
treina uma MLP com numpy puro e exporta os pesos para ml/modelo/pesos.json,
que o CerebroML.gd carrega no Godot.

Uso:  python3 ml/treinar.py
"""

import glob
import json
import os

import numpy as np

DADOS = os.path.join(os.path.dirname(__file__), "dados")
SAIDA = os.path.join(os.path.dirname(__file__), "modelo", "pesos.json")

# v2 contract (F1/F4): recorders emit 22 features -> 24-col rows.
# v1 files in ml/dados/*.csv have 20 cols (18 feats); they are kept for
# the v1 18-32-16-2 net and SKIPPED here (locked C8: retrain, don't mix).
N_ENTRADAS = 22
N_V1_ENTRADAS = 18
N_OCULTA1 = 32
N_OCULTA2 = 16
N_SAIDAS = 2
EPOCAS = 400
BATCH = 256
TAXA = 1e-3
Semente = 42


def carregar_dados(min_vel=0.0):
    """Filtra frames onde o professor NÃO queria andar (vel_desejada baixa):
    travamentos, paradas de recuperação. Mantém a largada (v=0, des=136).
    O freio por obstáculo fica a cargo da camada de segurança do CerebroML."""
    xs, ys = [], []
    total, mantidos = 0, 0
    for caminho in sorted(glob.glob(os.path.join(DADOS, "*.csv"))):
        try:
            m = np.loadtxt(caminho, delimiter=",", ndmin=2)
        except ValueError:
            # Killed run (timeout) leaves a truncated last line: reload
            # with genfromtxt, which pads/drops ragged rows instead of dying.
            try:
                m = np.genfromtxt(caminho, delimiter=",")
            except Exception as e2:
                print(f"PULADO (ilegivel): {os.path.basename(caminho)} ({e2})")
                continue
            if m.size == 0 or np.isnan(m).all():
                print(f"PULADO (vazio): {os.path.basename(caminho)}")
                continue
            m = m[~np.isnan(m).any(axis=1)]
            if m.size == 0:
                print(f"PULADO (vazio): {os.path.basename(caminho)}")
                continue
            if m.ndim == 1:
                m = m.reshape(1, -1)
        if m.size == 0:
            continue
        if m.shape[1] == N_V1_ENTRADAS + N_SAIDAS:
            print(f"PULADO (v1, 20 cols): {os.path.basename(caminho)} — rode ml/gravar.gd p/ gerar 24 cols")
            continue
        if m.shape[1] != N_ENTRADAS + N_SAIDAS:
            print(f"AVISO: {caminho} tem {m.shape[1]} colunas, ignorado")
            continue
        total += m.shape[0]
        if min_vel > 0.0:
            m = m[m[:, 19] > min_vel / 160.0]  # col 19 = vel_desejada/160 (última)
        mantidos += m.shape[0]
        if m.shape[0] == 0:
            continue
        xs.append(m[:, :N_ENTRADAS])
        ys.append(m[:, N_ENTRADAS:])
        print(f"  {os.path.basename(caminho)}: {m.shape[0]} amostras")
    print(f"filtro min_des={min_vel}: {mantidos}/{total} mantidas")
    if not xs:
        raise SystemExit("Nenhum CSV em ml/dados — rode ml/gravar.gd primeiro")
    return np.vstack(xs).astype(np.float64), np.vstack(ys).astype(np.float64)


class MLP:
    """MLP 18-32-16-2 com tanh nas ocultas, linear na saída, Adam manual."""

    def __init__(self, n_in, n_h1, n_h2, n_out, rng):
        self.w1 = rng.normal(0, np.sqrt(2 / n_in), (n_in, n_h1))
        self.b1 = np.zeros(n_h1)
        self.w2 = rng.normal(0, np.sqrt(2 / n_h1), (n_h1, n_h2))
        self.b2 = np.zeros(n_h2)
        self.w3 = rng.normal(0, np.sqrt(2 / n_h2), (n_h2, n_out))
        self.b3 = np.zeros(n_out)
        self._adam_reset()

    def _adam_reset(self):
        self.m = [np.zeros_like(p) for p in self.parametros()]
        self.v = [np.zeros_like(p) for p in self.parametros()]
        self.t = 0

    def parametros(self):
        return [self.w1, self.b1, self.w2, self.b2, self.w3, self.b3]

    def forward(self, x):
        h1 = np.tanh(x @ self.w1 + self.b1)
        h2 = np.tanh(h1 @ self.w2 + self.b2)
        return h2 @ self.w3 + self.b3

    def loss(self, x, y):
        return float(np.mean((self.forward(x) - y) ** 2))

    def passo(self, x, y, lr):
        n = x.shape[0]
        h1 = np.tanh(x @ self.w1 + self.b1)
        h2 = np.tanh(h1 @ self.w2 + self.b2)
        y_hat = h2 @ self.w3 + self.b3

        # retropropagação (MSE)
        d3 = 2.0 * (y_hat - y) / n
        gw3 = h2.T @ d3
        gb3 = d3.sum(0)
        dh2 = d3 @ self.w3.T
        dh1_pre = dh2 * (1 - h2 ** 2)
        gw2 = h1.T @ dh1_pre
        gb2 = dh1_pre.sum(0)
        dh0 = dh1_pre @ self.w2.T
        gx = dh0 * (1 - h1 ** 2)
        gw1 = x.T @ gx
        gb1 = gx.sum(0)

        self.t += 1
        for i, g in enumerate([gw1, gb1, gw2, gb2, gw3, gb3]):
            p = self.parametros()[i]
            self.m[i] = 0.9 * self.m[i] + 0.1 * g
            self.v[i] = 0.999 * self.v[i] + 0.001 * g * g
            m_hat = self.m[i] / (1 - 0.9 ** self.t)
            v_hat = self.v[i] / (1 - 0.999 ** self.t)
            p -= lr * m_hat / (np.sqrt(v_hat) + 1e-8)
        return float(np.mean((y_hat - y) ** 2))


def main():
    import sys
    min_vel = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
    rng = np.random.default_rng(Semente)
    print("Carregando dataset...")
    x, y = carregar_dados(min_vel)
    print(f"Total: {x.shape[0]} amostras, {x.shape[1]} entradas, {y.shape[1]} saídas")

    # normalização (mesma exportada para o GDScript)
    mu = x.mean(0)
    sigma = x.std(0)
    sigma[sigma < 1e-8] = 1.0
    xn = (x - mu) / sigma

    # separa treino/validação por episódio (sem vazamento de frames vizinhos)
    idx = rng.permutation(len(xn))
    n_val = max(1, int(0.1 * len(xn)))
    val, tr = idx[:n_val], idx[n_val:]

    rede = MLP(N_ENTRADAS, N_OCULTA1, N_OCULTA2, N_SAIDAS, rng)
    melhor = float("inf")
    paciencia = 30
    sem_melhora = 0
    for epoca in range(1, EPOCAS + 1):
        ordem = rng.permutation(len(tr))
        perdas = []
        for i in range(0, len(ordem), BATCH):
            lote = tr[ordem[i:i + BATCH]]
            perdas.append(rede.passo(xn[lote], y[lote], TAXA))
        vl = rede.loss(xn[val], y[val])
        if epoca % 25 == 0 or epoca == 1:
            print(f"época {epoca:4d}  treino {np.mean(perdas):.5f}  validação {vl:.5f}")
        if vl < melhor - 1e-6:
            melhor = vl
            sem_melhora = 0
            melhor_pesos = [p.copy() for p in rede.parametros()]
        else:
            sem_melhora += 1
            if sem_melhora >= paciencia:
                print(f"parada antecipada na época {epoca} (melhor val {melhor:.5f})")
                break

    for p, m in zip(rede.parametros(), melhor_pesos):
        p[...] = m

    # qualidade por saída (correlação com o professor)
    pred = rede.forward(xn[val])
    for j, nome in enumerate(["estercamento", "velocidade"]):
        c = np.corrcoef(pred[:, j], y[val][:, j])[0, 1]
        print(f"validação {nome}: MSE {np.mean((pred[:, j] - y[val][:, j]) ** 2):.5f}  corr {c:.3f}")

    os.makedirs(os.path.dirname(SAIDA), exist_ok=True)
    w1, b1, w2, b2, w3, b3 = melhor_pesos
    with open(SAIDA, "w") as f:
        json.dump({
            "w1": w1.tolist(), "b1": b1.tolist(),
            "w2": w2.tolist(), "b2": b2.tolist(),
            "w3": w3.tolist(), "b3": b3.tolist(),
            "x_mean": mu.tolist(), "x_std": sigma.tolist(),
            "arquitetura": [N_ENTRADAS, N_OCULTA1, N_OCULTA2, N_SAIDAS],
            "val_mse": melhor,
        }, f)
    print(f"modelo salvo em {SAIDA} (val_mse {melhor:.5f})")


if __name__ == "__main__":
    main()
