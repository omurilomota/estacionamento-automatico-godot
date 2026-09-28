#!/usr/bin/env bash
# Web export into site/game/ (AGENTS §2.1: build artifacts stay unversioned).
# Usage: bash tools/export_web.sh
set -euo pipefail
GODOT="${GODOT:-$HOME/Downloads/Godot_v4.7.2-stable_linux.x86_64}"
OUT="site/game"

mkdir -p "$OUT"
"$GODOT" --headless --path . --export-release "Web" "$OUT/index.html" 2>&1 | tail -5 || true
# Fallback: nothreads template (works on hosts without SharedArrayBuffer COOP/COEP)
if [ ! -f "$OUT/index.pck" ]; then
  "$GODOT" --headless --path . --export-release "Web (nothreads)" "$OUT/index.html" 2>&1 | tail -5 || true
fi

ls -la "$OUT"
[ -f "$OUT/index.pck" ] || { echo "FAIL: no index.pck"; exit 1; }
echo "EXPORT_OK $OUT"
