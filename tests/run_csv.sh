#!/usr/bin/env bash
# Uso: tests/run_csv.sh prog.asm resultados.csv [data.hex]
# Acrescenta halt (beq x0,x0,0) se faltar, simula e confere dmem[] com o CSV do professor.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; T="$(mktemp -d)"
cp "$1" "$T/p.asm"; [ -n "$(tail -c1 "$T/p.asm")" ] && echo >> "$T/p.asm"
grep -qiE '^beq +x0, *x0, *0 *$' "$T/p.asm" || echo "beq x0,x0,0" >> "$T/p.asm"
OUT="$T/output.txt" bash "$ROOT/tests/run_sim.sh" "$T/p.asm" ${3:+"$3"}
python3 "$ROOT/tests/check_csv.py" "$2" "$T/output.txt"
