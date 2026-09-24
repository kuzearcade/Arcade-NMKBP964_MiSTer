#!/usr/bin/env python3
"""Build a savestate slot from MAME's machine at a vblank (D3, MP-13).

    mk_inject_image.py BASE_SLOT MAME_DUMP_PREFIX OUT_SLOT

BASE_SLOT is a slot the core wrote itself (the MP_SS harness's MP_SS_DUMP),
taken at a vblank edge. It supplies what MAME's dump does not: the sound board
(sound RAM, the 68000's park frame, the ES5506). MAME_DUMP_PREFIX names the
pair sim/oracle/macplus_inject.lua writes (iNNNNN.bin / iNNNNN.txt). The
main-board side of the slot is replaced by MAME's: main RAM, VRAM, line zoom,
layer registers, the three sprite stages, palette, {toggle, irq3, fade} and
the sound-pending bit.

The 68020 resumes through ss_tg68_park's monitor: it reloads A7 from the SSP
register, pops D0-D7/A0-A6 (movem.l (sp)+) and RTEs a format-0 frame. So the
image gets, below MAME's SSP, the fifteen registers and then {SR, PC, 0x007C}
(vector 31), and the SSP register points at them. USP is MAME's. VBR, CACR,
SFC and DFC are 0 in MAME's dump as in the core (Q1).

Image layout: docs/PLAN.md Appendix C (16-bit words; a slot is a header
qword, then the image four words to a little-endian qword).
"""
import struct, sys

base, pre, out = sys.argv[1:4]
slot = bytearray(open(base, 'rb').read())
dump = open(pre + '.bin', 'rb').read()
regs = {}
for line in open(pre + '.txt'):
    k, v = line.split()
    regs[k] = int(v)
assert len(dump) == 0x3D840, hex(len(dump))
for k in ('VBR', 'CACR', 'SFC', 'DFC', 'MSP'):
    assert regs[k] == 0, (k, regs[k])
assert regs['SR'] & 0x3000 == 0x2000, 'expected supervisor mode on the interrupt stack'

def put(w, v):
    q = 8 * (1 + w // 4) + 2 * (w % 4)
    struct.pack_into('<H', slot, q, v & 0xFFFF)

def put_bytes(w0, b, pad_to=None):
    for i in range(0, len(b), 2):
        put(w0 + i // 2, (b[i] << 8) | b[i + 1])

ram = bytearray(dump[0:0x20000])
# the monitor's frame below MAME's supervisor stack pointer
ssp = regs['ISP']
frame = ssp - 8 - 60
assert 0xF00000 <= frame and ssp <= 0xF20000
o = frame - 0xF00000
vals = [regs['D%d' % i] for i in range(8)] + [regs['A%d' % i] for i in range(7)]
struct.pack_into('>15I', ram, o, *[v & 0xFFFFFFFF for v in vals])
struct.pack_into('>HIH', ram, o + 60, regs['SR'] & 0xFFFF, regs['PC'] & 0xFFFFFFFF, 0x007C)

put_bytes(0x00000, ram)                                   # main RAM
for L in range(4):
    put_bytes(0x10000 + L * 0x2000, dump[0x20000 + L * 0x4000:0x24000 + L * 0x4000])   # VRAM
    put_bytes(0x18000 + L * 0x100, dump[0x30000 + L * 0x200:0x30200 + L * 0x200])      # line zoom
    for i in range(32):
        put(0x18400 + L * 0x20 + i, 0)
    put_bytes(0x18400 + L * 0x20, dump[0x30800 + L * 12:0x30800 + L * 12 + 12])      # registers
put_bytes(0x1E000, dump[0x30840:0x34840])                 # palette
put_bytes(0x18800, dump[0x34840:0x37840])                 # sprite RAM live
put_bytes(0x1A000, dump[0x37840:0x3A840])                 # old
o2 = dump[0x3A840:0x3D840]
for e in range(1024):                                      # old2: eight words an entry
    put_bytes(0x1C000 + e * 8, o2[e * 12:e * 12 + 12])
    put(0x1C000 + e * 8 + 6, 0); put(0x1C000 + e * 8 + 7, 0)
fade = regs['fade'] if regs['fade'] >= 0 else 0xFF
put(0x24800, (regs['snd_toggle'] & 1) << 9 | 1 << 8 | fade)   # irq3 raised at this vblank
# sound pending (main CPU's view); keep the base's irq2 and command
q = 8 * (1 + 0x24810 // 4) + 2 * (0x24810 % 4)
sc = struct.unpack_from('<H', slot, q)[0]
put(0x24810, (sc & ~1) | (regs['sndpending'] & 1))
put(0x24880, frame >> 16); put(0x24881, frame)            # SSP register -> the frame
put(0x24882, regs['USP'] >> 16); put(0x24883, regs['USP'])
open(out, 'wb').write(slot)
