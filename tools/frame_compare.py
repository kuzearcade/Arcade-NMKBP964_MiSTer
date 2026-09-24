#!/usr/bin/env python3
"""Compare a run of RTL frames with MAME's, at a fixed offset.

    frame_compare.py <rtl frame dir> <mame frame dir> [max]

M2 gate (2) asks for frames "pixel-exact over the attract at a fixed offset".
The offset is real and has to be found rather than assumed: the board and MAME
do not leave reset on the same frame boundary. This searches for it, then
reports the longest CONTIGUOUS run of exact frames at that offset, which is
the honest measure -- a scattered majority of matching frames would not mean
the video is right.

Frames where MAME's own output is its uninitialised-RAM boot pattern are
reported separately: a simulation that starts from zeroed memory cannot
reproduce them, and counting them as failures would be misleading.
"""
import sys, os
import numpy as np

W, H = 256, 224
GARBAGE = 49952          # MAME's uninitialised-RAM frame, avspirit

def load(d, i):
    p = os.path.join(d, f'f{i}.raw')
    if not os.path.exists(p):
        return None
    a = np.fromfile(p, dtype='<u4')
    return (a & 0xFFFFFF) if a.size == W * H else None

def main():
    if len(sys.argv) < 3:
        print(__doc__); return 1
    R, M = sys.argv[1], sys.argv[2]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 200

    best = None
    for k in range(0, 120):
        ex = cnt = 0
        for i in range(0, n, 3):
            r, m = load(R, i), load(M, i + k)
            if r is None or m is None:
                continue
            cnt += 1
            ex += int((r != m).sum()) == 0
        if cnt > 20 and (best is None or ex > best[1]):
            best = (k, ex)
    if best is None:
        print('no comparable frames'); return 1
    k = best[0]

    res = []
    for i in range(n):
        r, m = load(R, i), load(M, i + k)
        if r is None or m is None:
            continue
        res.append((i, int((r != m).sum()), int((m != 0).sum())))

    garbage = sum(1 for _, _, nb in res if nb == GARBAGE)
    real = [t for t in res if t[2] != GARBAGE]
    exact = sum(1 for _, d, _ in real if d == 0)

    run = (0, 0); cur = 0; start = 0
    for f, d, _ in res:
        if d == 0:
            if cur == 0: start = f
            cur += 1
            if cur > run[0]: run = (cur, start)
        else:
            cur = 0

    inrun = [nb for f, d, nb in res if run[1] <= f < run[1] + run[0]]
    print(f'fixed offset                 : {k}')
    print(f'frames compared              : {len(res)}  ({garbage} of MAME\'s boot-garbage frames excluded below)')
    print(f'exact, excluding boot garbage: {exact}/{len(real)}')
    print(f'longest contiguous exact run : {run[0]} frames, from rtl frame {run[1]}')
    if inrun:
        print(f'non-blank pixels in that run : {min(inrun)}..{max(inrun)} of {W*H}')
    return 0 if run[0] >= 100 else 2

if __name__ == '__main__':
    sys.exit(main())
