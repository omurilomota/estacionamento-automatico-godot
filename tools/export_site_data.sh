#!/usr/bin/env bash
# Reproducible copy of the ML artifacts into the static site, plus a contract
# check so a broken model can never reach the published playground.
#
# ml/modelo/ is the SOURCE OF TRUTH; site/data/ is a distribution copy and must
# never be edited by hand (AGENTS #26). site/.gdignore keeps the Godot editor
# from importing the copy.
set -euo pipefail

GODOT="${GODOT:-$HOME/Downloads/Godot_v4.7.2-stable_linux.x86_64}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

DESTINO="site/data"
mkdir -p "$DESTINO"

ARQUIVOS=(
	"ml/modelo/pesos.json"
	"ml/modelo/evolucao_historico.json"
)

for origem in "${ARQUIVOS[@]}"; do
	if [ ! -f "$origem" ]; then
		echo "export_site_data: fonte ausente: $origem" >&2
		exit 1
	fi
	cp -f "$origem" "$DESTINO/$(basename "$origem")"
	echo "copiado $origem -> $DESTINO/$(basename "$origem")"
done

# Contract check: the playground hardcodes 22-32-16-2, so a shape change must
# fail the build instead of silently rendering garbage in the browser.
python3 - "$DESTINO/pesos.json" <<'PY'
import json
import sys

CAMINHO = sys.argv[1]
with open(CAMINHO) as f:
    m = json.load(f)

esperadas = ["w1", "b1", "w2", "b2", "w3", "b3", "x_mean", "x_std", "arquitetura", "val_mse"]
faltando = [k for k in esperadas if k not in m]
if faltando:
    raise SystemExit("CONTRATO: chaves ausentes em pesos.json: %s" % faltando)

if list(m["arquitetura"]) != [22, 32, 16, 2]:
    raise SystemExit("CONTRATO: arquitetura %s != [22, 32, 16, 2]" % m["arquitetura"])


def dim(v, nome):
    return len(v), (len(v[0]) if isinstance(v[0], list) else None)


n_in, n_h1 = dim(m["w1"], "w1")
n_h1b, n_h2 = dim(m["w2"], "w2")
n_h2b, n_out = dim(m["w3"], "w3")
if (n_in, n_h1) != (22, 32) or (n_h1b, n_h2) != (32, 16) or (n_h2b, n_out) != (16, 2):
    raise SystemExit("CONTRATO: shapes w1=%s w2=%s w3=%s" % ((n_in, n_h1), (n_h1b, n_h2), (n_h2b, n_out)))
if len(m["b1"]) != 32 or len(m["b2"]) != 16 or len(m["b3"]) != 2:
    raise SystemExit("CONTRATO: tamanhos de bias divergem")
if len(m["x_mean"]) != 22 or len(m["x_std"]) != 22:
    raise SystemExit("CONTRATO: normalizacao com %d/%d entradas (esperado 22)" % (len(m["x_mean"]), len(m["x_std"])))
ruins = [i for i, s in enumerate(m["x_std"]) if not (s > 0.0)]
if ruins:
    raise SystemExit("CONTRATO: x_std <= 0 nos slots %s" % ruins)

print("contrato OK: arquitetura %s, val_mse %.6g" % (m["arquitetura"], m["val_mse"]))
PY

echo "EXPORT_DATA_OK"
