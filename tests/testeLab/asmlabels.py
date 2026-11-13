#!/usr/bin/env python3
"""Pre-processador: .lasm (labels + comentarios '#') -> .asm do assembler da base.
Labels em beq/bne/blt/bge/bltu/bgeu/jal viram offsets em bytes relativos ao PC."""
import re, sys
src = [l.split('#')[0].strip() for l in open(sys.argv[1])]
lab, ins = {}, []
for l in src:
    while re.match(r'^\w+:', l):
        n, l = l.split(':', 1); lab[n] = len(ins) * 4; l = l.strip()
    if l: ins.append(l)
out = []
for i, l in enumerate(ins):
    m, rest = l.split(None, 1); a = [x.strip() for x in rest.split(',')]
    if m in ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu') and a[2] in lab: a[2] = str(lab[a[2]] - i * 4)
    if m == 'jal' and a[1] in lab: a[1] = str(lab[a[1]] - i * 4)
    out.append(m + ' ' + ','.join(a))
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
