#!/usr/bin/env python3
"""D3 by state injection (MP-13): the core's busy time against MAME's, frame by frame.

    d3_inject_compare.py MAME_DIR LOG[:CE] ...

MAME_DIR holds macplus_inject.lua's work.txt; each LOG is the MP_INJECT
harness output for one main-CPU clock enable (CE/48), e.g. inj_ce29.log:29.
For every injected state F and handler j the core's busy time is paired with
MAME's on line F+1+j. j=0 starts from the same machine state, so it is the
clean comparison; j=1, 2 show how far the two stay together.

The ratio core/MAME of the summed busy time is reported per CE, and the CE at
which it is 1 is interpolated from busy = a + b/CE, the CPU-bound part scaling
with the clock and a fixed part (bus waits) not.
"""
import re, sys
import numpy as np

SAT = 15000.0     # us: a frame this busy is saturated
mame_dir = sys.argv[1]
busy = {}
for line in open(mame_dir + '/work.txt'):
    f = line.split()
    busy[int(f[0])] = float(f[4])

rows = []
for arg in sys.argv[2:]:
    log, ce = (arg.split(':') + [None])[:2]
    ce = int(ce or re.search(r'(\d+)', log.split('/')[-1]).group(1))
    core = {}
    for line in open(log):
        m = re.match(r'INJ (\d+) (\d+) ([\d.]+) ([\d.]+)', line)
        if m:
            core[(int(m[1]), int(m[2]))] = float(m[4])
    for j in (0, 1, 2):
        # a frame busy from end to end (stage loads: 16.67 ms on both) says
        # nothing about speed; only frames where both went idle count
        pairs = [(v, busy[F + 1 + j]) for (F, jj), v in core.items()
                 if jj == j and 0 < busy.get(F + 1 + j, 0) < SAT and v < SAT]
        if not pairs:
            continue
        c, m = np.array(pairs).T
        r = c / m
        print('CE %2d/48  j=%d  n=%3d  core/MAME: sum %.3f  median %.3f  p10 %.3f  p90 %.3f'
              % (ce, j, len(r), c.sum() / m.sum(), np.median(r), np.percentile(r, 10), np.percentile(r, 90)))
        if j == 0:
            rows.append((ce, c.sum() / m.sum(), len(r)))

if len(rows) >= 2:
    ces = np.array([r[0] for r in rows], float)
    ratio = np.array([r[1] for r in rows])
    # ratio(CE) = a + b / CE, least squares
    A = np.vstack([np.ones_like(ces), 1 / ces]).T
    (a, b), *_ = np.linalg.lstsq(A, ratio, rcond=None)
    ce1 = b / (1 - a) if a < 1 else float('nan')
    print('fit (j=0): ratio = %.3f + %.2f / CE  ->  ratio 1 at CE %.1f / 48 (%.2f MHz)' % (a, b, ce1, ce1 * 48 / 48))
