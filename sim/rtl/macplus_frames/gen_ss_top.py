#!/usr/bin/env python3
# Regenerate ss_top.sv's pass-through ports from macplus_core's port list.
import re, sys
src = open('../../../rtl/macplus/macplus_core.sv').read()
i = src.index(') (') + 3
body = src[i:src.index(');', i)]
ports = []
for line in body.split('\n'):
    l = line.split('//')[0].strip().rstrip(',')
    if not l: continue
    if l.split()[-1].startswith('ss_'): continue
    ports.append('\t' + l.replace('output reg', 'output'))
top = open('ss_top.sv').read()
a = top.index('module ss_top (\n') + len('module ss_top (\n')
b = top.index('\tinput             save_req')
open('ss_top.sv', 'w').write(top[:a] + ',\n'.join(ports) + ',\n' + top[b:])
print(len(ports), 'ports')
