#!/usr/bin/env python3
"""Q3 and Q8 from oracle captures.

Q3 -- sprite load: for every frame's displayed list (old2), per screen line:
  hits    sprites (entries) with at least one tile row on the line
  tiles   tile columns (16-px source units) crossing the line
  pixels  destination pixels those tiles cover on the line, clipped to 0..383,
          counting transparent ones too (the renderer must visit them)
Q8 -- BG zoom: per layer, when vr[2] enables zoom: min/max incx (from the
  line-zoom RAM, per visible line) and incy, as 16.16 values.

    tools/q3_q8_measure.py GAME TRACE_DIR [--step 1]"""
import argparse, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import macplus_model as m
ap = argparse.ArgumentParser(); ap.add_argument("game"); ap.add_argument("trace"); ap.add_argument("--step", type=int, default=1)
a = ap.parse_args()
T = Path(a.trace); H = 240 if a.game == "macrossp" else 224; W = 384
files = sorted(T.glob("s*.bin"))[:: a.step]
worst = {"hits": (0, 0, 0), "tiles": (0, 0, 0), "pixels": (0, 0, 0)}
maxent = (0, 0)
zoom = {i: None for i in range(3)}
for fp in files:
    F = int(fp.stem[1:]); st = m.State(fp); s = st.spr_old2
    hits = [0] * H; tiles = [0] * H; pix = [0] * H; ent = 0
    for i in range(1024):
        s0, s1, s2 = int(s[i*3]), int(s[i*3+1]), int(s[i*3+2])
        wide, high = (s0 >> 10) & 15, (s0 >> 26) & 15
        xpos, ypos = s0 & 0x3FF, (s0 >> 16) & 0x3FF
        xz, yz = s1 & 0x3FF, (s1 >> 16) & 0x3FF
        if xpos > 0x1FF: xpos -= 0x400
        if ypos > 0x1FF: ypos -= 0x400
        scx = (xz << 8) + (0x600 if xz < 0x100 else 0); scy = (yz << 8) + (0x600 if yz < 0x100 else 0)
        dw = (scx * 16 + 0x8000) >> 16; dh = (scy * 16 + 0x8000) >> 16
        if dw < 1 or dh < 1: continue
        on = set()
        for r in range(high + 1):
            y0 = ypos + ((r * yz * 16) >> 8)
            for y in range(max(y0, 0), min(y0 + dh, H)):
                on.add(y)
                for c in range(wide + 1):
                    x0 = xpos + ((c * xz * 16) >> 8); x1 = x0 + dw - 1
                    if x1 < 0 or x0 >= W: continue
                    tiles[y] += 1; pix[y] += min(x1, W - 1) - max(x0, 0) + 1
        if on: ent += 1
        for y in on: hits[y] += 1
    maxent = max(maxent, (ent, F))
    for k, arr in (("hits", hits), ("tiles", tiles), ("pixels", pix)):
        v = max(arr)
        if v > worst[k][0]: worst[k] = (v, F, arr.index(v))
    for L in range(3):
        vr = st.vr[L]
        if (vr[2] & 0xF0000000) == 0xE0000000:
            incy = (vr[2] & 0x01FF0000) >> 6
            incxs = [((st.lz[L][y // 2] & 0xFFFF) if (y & 1) else ((st.lz[L][y // 2] >> 16) & 0xFFFF)) << 10 for y in range(H)]
            lo, hi = min(incxs), max(incxs)
            z = zoom[L] or [1 << 40, 0, 1 << 40, 0, 0]
            zoom[L] = [min(z[0], lo), max(z[1], hi), min(z[2], incy), max(z[3], incy), z[4] + 1]
print(f"{a.game} {T.name}: {len(files)} frames")
print(f"  on-screen sprite entries per frame, max {maxent[0]} (frame {maxent[1]})")
for k, (v, F, y) in worst.items(): print(f"  worst line {k}: {v} (frame {F}, line {y})")
for L, z in zoom.items():
    if z: print(f"  layer {L} zoomed in {z[4]} frames: incx {z[0]/65536:.3f}..{z[1]/65536:.3f}, incy {z[2]/65536:.3f}..{z[3]/65536:.3f}")
    else: print(f"  layer {L} never zoomed")
