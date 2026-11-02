#!/usr/bin/env python3
"""Modelo de referencia (ISA) independente do RTL. Uso: ref_model.py prog.asm data.hex out.txt
Escreve as linhas 'FINAL REG' / 'FINAL MEM' no mesmo formato do testbench."""
import re, sys
M = 0xFFFFFFFF
s32 = lambda v: v - (1 << 32) if v & 0x80000000 else v
def run(lines, data):
    r = [0] * 32; mem = [0] * 256
    for i, w in enumerate(data): mem[i] = w
    prog = [re.split(r'[\s,()]+', l.strip().lower()) for l in lines if l.strip()]
    pc = 0
    for _ in range(5000):
        t = prog[pc // 4]; op = t[0]
        reg = lambda x: int(x[1:])
        if op in ('lw', 'sw'):
            a = (r[reg(t[3])] + int(t[2], 0)) & M
        if op == 'beq':
            if r[reg(t[1])] == r[reg(t[2])]:
                off = int(t[3], 0)
                if off == 0: break
                pc = (pc + off) & M; continue
            pc += 4; continue
        elif op == 'lw': res = mem[a >> 2]
        elif op == 'sw': mem[a >> 2] = r[reg(t[1])]; pc += 4; continue
        elif op == 'lui': res = (int(t[2], 0) << 12) & M
        elif op == 'auipc': res = (pc + (int(t[2], 0) << 12)) & M
        else:
            a = r[reg(t[2])]
            imm = op.endswith('i')
            b = (int(t[3], 0) & M) if imm else r[reg(t[3])]
            o = op[:-1] if imm else op
            sh = b & 31
            res = {'add': a + b, 'sub': a - b, 'and': a & b, 'or': a | b, 'xor': a ^ b,
                   'sll': a << sh, 'srl': a >> sh, 'sra': s32(a) >> sh,
                   'slt': int(s32(a) < s32(b)), 'sltu': int(a < b)}[o] & M
        d = reg(t[1])
        if d: r[d] = res
        pc += 4
    return r, mem
if __name__ == '__main__':
    asm, hexf, out = sys.argv[1:4]
    data = [int(x, 16) for x in open(hexf).read().split()]
    r, mem = run(open(asm).readlines(), data)
    with open(out, 'w') as f:
        for i in range(1, 32):
            if r[i]: f.write("FINAL REG %2d = 0x%08X\n" % (i, r[i]))
        for i in range(16):
            if mem[i]: f.write("FINAL MEM[%3d] = 0x%08X\n" % (i, mem[i]))
