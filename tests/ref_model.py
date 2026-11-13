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
    reg = lambda x: int(x[1:])
    pc = 0
    for _ in range(20000):
        t = prog[pc // 4]; op = t[0]; npc = (pc + 4) & M; res = None
        if op in ('lw', 'lb', 'lh', 'lbu', 'lhu', 'sw', 'sb', 'sh'):
            a = (r[reg(t[3])] + int(t[2], 0)) & M
            w = mem[a >> 2]; sh = (a & 3) * 8
            if op == 'lw': res = w
            elif op == 'lb': res = (s32(((w >> sh) & 0xFF) << 24) >> 24) & M
            elif op == 'lbu': res = (w >> sh) & 0xFF
            elif op == 'lh': res = (s32(((w >> sh) & 0xFFFF) << 16) >> 16) & M
            elif op == 'lhu': res = (w >> sh) & 0xFFFF
            elif op == 'sw': mem[a >> 2] = r[reg(t[1])]
            elif op == 'sb': mem[a >> 2] = (w & ~(0xFF << sh) & M) | ((r[reg(t[1])] & 0xFF) << sh)
            elif op == 'sh': mem[a >> 2] = (w & ~(0xFFFF << sh) & M) | ((r[reg(t[1])] & 0xFFFF) << sh)
        elif op in ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu'):
            a, b = r[reg(t[1])], r[reg(t[2])]; off = int(t[3], 0)
            c = {'beq': a == b, 'bne': a != b, 'blt': s32(a) < s32(b), 'bge': s32(a) >= s32(b),
                 'bltu': a < b, 'bgeu': a >= b}[op]
            if c:
                if off == 0: break          # halt: salto para si mesmo
                npc = (pc + off) & M
        elif op == 'jal':
            off = int(t[2], 0); res = (pc + 4) & M
            if off == 0: break
            npc = (pc + off) & M
        elif op == 'jalr':
            res = (pc + 4) & M; npc = ((r[reg(t[2])] + int(t[3], 0)) & M) & ~1
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
        if res is not None and reg(t[1]): r[reg(t[1])] = res
        pc = npc
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
