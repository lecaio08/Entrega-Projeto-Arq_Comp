#!/usr/bin/env bash
# Uso: tests/run_sim.sh prog.asm|prog.lasm [data.hex]   (requer iverilog + python3)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ASM="$(realpath "$1")"
T="$(mktemp -d)"; cp "$ROOT/assembler/assembler.py" "$T/"; if [[ "$ASM" == *.lasm ]]; then python3 "$ROOT/tests/asmlabels.py" "$ASM" "$T/prog.asm"; else cp "$ASM" "$T/prog.asm"; fi
cp "${2:-$ROOT/tests/data.hex}" "$T/data.hex"
( cd "$T" && python3 assembler.py prog.asm >/dev/null && cp assembler/program.hex . 2>/dev/null || true )
[ -f "$T/program.hex" ] || cp "$T"/program.hex "$T/" 2>/dev/null || true
S="$ROOT/src"
sed -e 's/errors = compare_with_golden();/errors = 0;/' -e 's/\$stop;/$finish;/' \
    -e '/function automatic integer compare_with_golden/,/endfunction/d' "$S/pl_cpu_tb.sv" > "$T/tb.sv"
( cd "$T" && iverilog -g2012 -o sim "$S/pl_pipe_pkg.sv" "$S"/pl_{alu,alu_ctrl,control,sign_ext,hazard,forward,regfile,imem,dmem,uart,mmio,datapath,cpu}.sv tb.sv 2>&1 | grep -v 'sorry: constant selects' || true
  timeout 60 vvp sim < /dev/null > sim.log; grep -E 'Halt|AVISO' sim.log )
[ -n "$OUT" ] && cp "$T/output.txt" "$OUT"
grep FINAL "$T/output.txt" | grep -vi "xxxx" | sed -E "s/0x([0-9a-fA-F]+)/0x\U\1/" > "$T/dut.txt"
python3 "$ROOT/tests/ref_model.py" "$T/prog.asm" "$T/data.hex" "$T/ref.txt"
if diff "$T/ref.txt" "$T/dut.txt"; then echo "PASS $(basename "$ASM")"; else echo "FAIL $(basename "$ASM")"; exit 1; fi
