#!/usr/bin/env bash
# Roda TODOS os testes localmente (iverilog + python3). Uso: bash tests/run_all.sh
# Sai com codigo 0 se tudo passar, 1 se algum falhar.
#   - Etapas 01, 02 e 03 (tests/*.asm|*.lasm) comparados com tests/ref_model.py
#   - Regressao: programa original da base contra modelsim/golden.txt
#   - Testes do professor: todo tests/professor/<nome>.asm com
#     tests/professor/resultados_esperados_<nome>.csv (basta soltar os novos la)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
for c in iverilog python3; do
  command -v $c >/dev/null || { echo "ERRO: '$c' nao encontrado (sudo apt install iverilog python3)"; exit 2; }
done
PASS=0; FAIL=0; FALHAS=()
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FALHAS+=("$1"); }
sim() { # nome, args do run_sim.sh...
  local n="$1"; shift
  local out; out="$(timeout 120 bash tests/run_sim.sh "$@" 2>&1)"
  if grep -q '^PASS' <<<"$out"; then ok "$n"; else bad "$n"; echo "$out" | sed 's/^/        /' | tail -15; fi
}

echo "== Etapa 01 (R-type: XOR SLL SRL SRA SLTU)"
sim etapa1_rtype        tests/etapa1_rtype.asm
echo "== Etapa 02 (I-type aritmetico, LUI, AUIPC)"
sim etapa2_imm_upper    tests/etapa2_imm_upper.asm
echo "== Etapa 03 (loads/stores parciais, branches, JAL/JALR)"
sim etapa3_mem          tests/etapa3_mem.lasm tests/data_etapa3.hex
sim etapa3_branch_jump  tests/etapa3_branch_jump.lasm tests/data.hex

echo "== Regressao: programa original da base vs golden.txt"
T="$(mktemp -d)"
(cat assembler/hello.asm; echo; echo "beq x0,x0,0") | grep -v '^$' > "$T/base.asm"
if OUT="$T/out.txt" bash tests/run_sim.sh "$T/base.asm" modelsim/data.hex >/dev/null 2>&1 \
   && diff <(tr -d '\r' < "$T/out.txt" | tr A-F a-f) <(tr -d '\r' < modelsim/golden.txt | tr A-F a-f) >/dev/null
then ok "base_hello == golden.txt"; else bad "base_hello == golden.txt"; fi

echo "== Testes do professor (tests/professor)"
shopt -s nullglob; ACHOU=0
for a in tests/professor/*.asm tests/professor/*.lasm; do
  n="$(basename "$a")"; n="${n%.*}"; csv="tests/professor/resultados_esperados_${n}.csv"
  [ -f "$csv" ] || { echo "  [skip] $n (sem $csv)"; continue; }
  ACHOU=1
  out="$(timeout 120 bash tests/run_csv.sh "$a" "$csv" 2>&1)"
  if grep -q 'RESULTADO: PASS' <<<"$out"; then ok "$n ($(grep -c '^OK' <<<"$out") resultados conferem)"
  else bad "$n"; grep -E 'ERRO|FAIL|diff|^[<>]' <<<"$out" | sed 's/^/        /' | head -15; fi
done
[ $ACHOU = 1 ] || echo "  (nenhum teste do professor encontrado)"

echo
echo "RESUMO: $PASS passaram, $FAIL falharam"
[ $FAIL = 0 ] && { echo "TUDO OK"; exit 0; } || { printf 'FALHAS: %s\n' "${FALHAS[*]}"; exit 1; }
