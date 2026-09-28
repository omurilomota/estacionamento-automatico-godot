#!/usr/bin/env bash
# tools/run_gates.sh — roda os gates de boot em SEQUENCIA (nunca em paralelo:
# AGENTS §14 proibe N instancias de Godot ao mesmo tempo) e resume o resultado.
#
# Uso:
#   bash tools/run_gates.sh                    # Fase1..Fase7, 75 s cada
#   bash tools/run_gates.sh --secs=90
#   bash tools/run_gates.sh --fases=Fase2,Fase3
#
# Saida: uma linha por fase (PASS/FAIL + motivo) e um resumo final.
# Codigo de saida != 0 se alguma fase falhar. Existe porque as provas de boot
# eram digitadas a mao em /tmp e se perderam num power cut (AGENTS §5).
set -u

GODOT="${GODOT:-$HOME/Downloads/Godot_v4.7.2-stable_linux.x86_64}"
SECS=75
FASES="Fase1,Fase2,Fase3,Fase4,Fase5,Fase6,Fase7"

for a in "$@"; do
	case "$a" in
		--secs=*)  SECS="${a#*=}" ;;
		--fases=*) FASES="${a#*=}" ;;
		--godot=*) GODOT="${a#*=}" ;;
	esac
done

cd "$(dirname "$0")/.." || exit 2
if [ ! -x "$GODOT" ]; then
	echo "run_gates: binario do Godot nao encontrado em $GODOT" >&2
	exit 2
fi

falhas=0
total=0
echo "run_gates: godot=$GODOT secs=$SECS fases=$FASES"

IFS=',' read -r -a LISTA <<< "$FASES"
for f in "${LISTA[@]}"; do
	total=$((total + 1))
	log="/tmp/gate_boot_${f}.log"
	timeout $((SECS + 45)) "$GODOT" --headless --path . --script tools/gate_boot.gd \
		-- --fase="$f" --secs="$SECS" > "$log" 2>&1
	code=$?
	linha=$(grep -E "^GATE_BOOT_" "$log" | tail -1)
	resumo=$(grep -E "^(BOOT|CONES|NEG_FRAMES)" "$log" | tr '\n' ' ')
	linha="$linha | $resumo"
	if [ -z "$linha" ]; then linha=$(tail -3 "$log" | tr '\n' ' '); fi
	if [ $code -eq 0 ]; then
		echo "  [$f] PASS  $linha"
	else
		falhas=$((falhas + 1))
		echo "  [$f] FAIL  $linha   (log: $log)"
	fi
done

echo "run_gates: $((total - falhas))/$total passaram"
[ "$falhas" -eq 0 ] || exit 1
