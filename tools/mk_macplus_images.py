#!/usr/bin/env python3
"""Build the flat ROM images the simulations read, from mame_roms/<game>.zip.
Output (gitignored, copyrighted): <dir>/{main,snd,spr,bg0,bg1,bg2,fg,smp}.bin
  main  4 MB, big-endian 32-bit (LOAD32_BYTE: u4 = MSB at offset 0)
  snd   1 MB, big-endian 16-bit (LOAD16_BYTE: u21 even, u20 odd)
  spr   16 MB, LOAD32_BYTE (u12 at +0 ... u9 at +3)
  bg0-2 the three BG regions, flat
  fg    the text region (512 KB on macrossp, empty on quizmoon)
  smp   the ES5506 regions as 16-bit words, BIG-endian as MAME's ROMREGION16_BE:
        macrossp 8 MB (u24 in the high bytes, 0xFF low: ERASEFF), quizmoon 16 MB
    tools/mk_macplus_images.py GAME DIR"""
import sys, zipfile
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
game, out = sys.argv[1], Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
z = zipfile.ZipFile(ROOT / "mame_roms" / f"{game}.zip"); r = z.read
def il(parts, size, step, fill=0):
    b = bytearray([fill]) * size
    for name, base, lane in parts:
        d = r(name); b[base + lane: base + lane + step * len(d): step] = d
    return b
if game == "macrossp":
    main = il([("bp964a-c.u4", 0, 0), ("bp964a-c.u3", 0, 1), ("bp964a-c.u2", 0, 2), ("bp964a-c.u1", 0, 3)], 0x400000, 4)
    snd  = il([("bp964a.u21", 0, 0), ("bp964a.u20", 0, 1)], 0x100000, 2)
    spr  = il([("bp964a.u12", 0, 0), ("bp964a.u11", 0, 1), ("bp964a.u10", 0, 2), ("bp964a.u9", 0, 3)], 0x1000000, 4)
    bg   = [r("bp964a.u13") + r("bp964a.u14"), r("bp964a.u15") + r("bp964a.u16"), r("bp964a.u17") + r("bp964a.u18")]
    fg   = r("bp964a.u19")
    smp  = il([("bp964a.u24", 0, 0)], 0x800000, 2, fill=0xFF)
else:
    main = il([("u4.bin", 0, 0), ("u3.bin", 0, 1), ("u2.bin", 0, 2), ("u1.bin", 0, 3),
               ("u8.bin", 0x200000, 0), ("u7.bin", 0x200000, 1), ("u6.bin", 0x200000, 2), ("u5.bin", 0x200000, 3)], 0x400000, 4)
    snd  = il([("u21.bin", 0, 0), ("u20.bin", 0, 1)], 0x100000, 2)
    spr  = il([("u12.bin", 0, 0), ("u11.bin", 0, 1), ("u10.bin", 0, 2), ("u9.bin", 0, 3)], 0x1000000, 4)
    bg   = [r("u13.bin"), r("u15.bin"), r("u17.bin")]
    fg   = b""
    smp  = il([("u26.bin", 0, 0), ("u24.bin", 0, 1)], 0x800000, 2) + il([("u27.bin", 0, 0), ("u25.bin", 0, 1)], 0x800000, 2)
for n, d in [("main", main), ("snd", snd), ("spr", spr), ("bg0", bg[0]), ("bg1", bg[1]), ("bg2", bg[2]), ("fg", fg), ("smp", smp)]:
    (out / f"{n}.bin").write_bytes(bytes(d))
print(game, "->", out, [f"{n}:{len(d)}" for n, d in [("main", main), ("spr", spr), ("bg0", bg[0]), ("smp", smp)]])
