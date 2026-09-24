#!/usr/bin/env python3
"""Sweep tools/macplus_model.py over a capture: model(state F) vs MAME picture
F+K (K=+1, measured) every STEP frames. Prints one line per frame and a total,
with the non-blank count beside every exact count (NMK-21).
    tools/model_sweep.py GAME TRACE_DIR [--step 25] [--k 1]"""
import argparse, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import macplus_model as m, numpy as np
ap = argparse.ArgumentParser(); ap.add_argument("game"); ap.add_argument("trace")
ap.add_argument("--step", type=int, default=25); ap.add_argument("--k", type=int, default=1)
a = ap.parse_args()
T = Path(a.trace); roms = m.Roms(a.game); H = 240 if a.game == "macrossp" else 224
n = len(list(T.glob("s*.bin")))
exact = lit = tot = 0; unk = 0
first = min(int(p.stem[1:]) for p in T.glob("s*.bin"))
for F in range(first, first + n - a.k, a.step):
    st = m.State(T / f"s{F:05d}.bin")
    rgb, u = m.render(st, roms, 384, H)
    pic = m.load_pic(T / f"p{F + a.k:05d}.raw", 384, H)
    d = int(np.any(rgb != pic, -1).sum()); nb = int(np.any(pic != 0, -1).sum())
    tot += 1; exact += d == 0; lit += (d == 0 and nb > 0); unk += u
    print(f"{F} diff {d} nonblank {nb} unk {u}", flush=True)
print(f"TOTAL {a.game} {T.name}: {exact}/{tot} exact, {lit} of them non-blank, unknown-colour draws {unk}")
