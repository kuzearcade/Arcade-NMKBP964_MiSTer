#!/usr/bin/env python3
"""Q1: which instructions does a game actually execute on its main CPU?

Runs MAME's debugger `trace` into a FIFO and keeps one line per unique PC
(the trace is far too large to store: tens of millions of instructions a
minute). Loop-collapse is left ON, so idle loops cost nothing. Input is played
by sim/oracle/macplus_play.lua.

Output: <out>.pcs  -- "PC<TAB>disassembly" for every PC executed, sorted
        <out>.ops  -- mnemonic (size suffix and operands stripped) -> count of PCs
and a list of the 68020-only mnemonics and addressing modes found, which is
what gets checked against TG68K's decode.

Usage: tools/q1_opcode_coverage.py macrossp OUTPREFIX --seconds 240
"""
import argparse, os, re, subprocess, sys, tempfile, threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAME = Path(os.environ.get("MAME", Path.home() / "Arcade-NMK16_MiSTer/mame/mame"))
LINE = re.compile(r"^\s*([0-9A-F]{6,8}):\s+(\S+)\s*(.*)$", re.I)

# Instructions a 68000/68010 does not have, and 68020 addressing forms.
ONLY_020 = {"bfchg","bfclr","bfexts","bfextu","bfffo","bfins","bfset","bftst","cas","cas2",
            "chk2","cmp2","pack","unpk","trapcc","traplt","trapeq","trapne","callm","rtm",
            "divsl","divul","extb","bkpt","movec","moves","rtd","link.l"}
def mode_020(ops):
    o = ops.lower()
    return ("[" in o) or bool(re.search(r"\*[248]\b", o)) or bool(re.search(r"\(\s*\$?[0-9a-f]{5,},?\s*[ad]\d", o))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game"); ap.add_argument("out")
    ap.add_argument("--seconds", type=int, default=240)
    ap.add_argument("--device", default=":maincpu")
    a = ap.parse_args()
    tmp = Path(tempfile.mkdtemp())
    fifo = tmp / "trace.fifo"; os.mkfifo(fifo)
    script = tmp / "dbg.txt"
    script.write_text(f"focus {a.device}\ntrace {fifo},{a.device}\ngo\n")
    pcs = {}
    def reader():
        with open(fifo, errors="replace") as f:
            for line in f:
                m = LINE.match(line)
                if m and m.group(1) not in pcs:
                    pcs[m.group(1)] = (m.group(2), m.group(3))
    t = threading.Thread(target=reader); t.start()
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy", DISPLAY="")
    cmd = [str(MAME), a.game, "-rompath", str(ROOT / "mame_roms"), "-video", "none", "-sound", "none",
           "-nothrottle", "-debug", "-debugscript", str(script), "-seconds_to_run", str(a.seconds),
           "-autoboot_script", str(ROOT / "sim/oracle/macplus_play.lua")]
    r = subprocess.run(cmd, cwd=tmp, env=env, capture_output=True, text=True)
    t.join()
    if r.returncode:
        print(r.stdout[-1500:], r.stderr[-1500:], file=sys.stderr)
    out = Path(a.out)
    with open(str(out) + ".pcs", "w") as f:
        for pc in sorted(pcs, key=lambda x: int(x, 16)):
            f.write(f"{pc}\t{pcs[pc][0]} {pcs[pc][1]}\n")
    ops = {}
    for mn, _ in pcs.values():
        base = mn.lower().split(".")[0]; ops[base] = ops.get(base, 0) + 1
    with open(str(out) + ".ops", "w") as f:
        for k in sorted(ops): f.write(f"{k}\t{ops[k]}\n")
    only = sorted({mn.lower() for mn, _ in pcs.values() if mn.lower().split(".")[0] in ONLY_020 or mn.lower() in ONLY_020})
    modes = sorted({f"{mn} {o}" for mn, o in pcs.values() if mode_020(o)})
    print(f"{a.game}: {len(pcs)} unique PCs, {len(ops)} mnemonics (rc={r.returncode})")
    print("68020-only mnemonics:", only or "none")
    print(f"68020 addressing forms ({len(modes)}):")
    for m in modes[:60]: print("  ", m)

if __name__ == "__main__":
    main()
