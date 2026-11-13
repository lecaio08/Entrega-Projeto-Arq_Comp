#!/usr/bin/env python3
"""Confere o output.txt do testbench contra um CSV do professor.
Uso: check_csv.py resultados.csv output.txt
CSV: Instrucao;Operacao;Resultado (decimal);Resultado (hex);Destino  (Destino = dmem[N])"""
import re, sys
exp = {}
for l in open(sys.argv[1], encoding='utf-8-sig').read().splitlines()[1:]:
    c = l.split(';')
    if len(c) >= 5:
        m = re.search(r'dmem\[(\d+)\]', c[4])
        if m: exp[int(m.group(1))] = (c[0], int(c[3], 16))
got = {}
for l in open(sys.argv[2]):
    m = re.match(r'FINAL MEM\[\s*(\d+)\] = 0x([0-9A-Fa-f]+)', l)
    if m: got[int(m.group(1))] = int(m.group(2), 16)
bad = 0
for n in sorted(exp):
    ins, v = exp[n]; g = got.get(n, 0)
    ok = g == v; bad += not ok
    print("%s dmem[%2d] %-22s esperado=0x%08X obtido=0x%08X" % ("OK  " if ok else "ERRO", n, ins, v, g))
print("RESULTADO:", "PASS" if not bad else "FAIL (%d)" % bad)
sys.exit(1 if bad else 0)
