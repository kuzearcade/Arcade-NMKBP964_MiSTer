#!/usr/bin/env python3
"""Mirror part of releases/ into autofire_releases/ with the Autofire menu shown.

`MacPlus.sv` hides its "P1/P2 Autofire" options (CONF_STR `h1`) unless the
loaded .mra's third <switches> byte sets bit 7 (`autofire_unlock`). The
shipped .mra files in releases/ never set it, so this script writes a second
tree with the same file names and that bit set. Nothing else changes, so each
copy keeps its ROM parts, DIPs, buttons, hiscore and cheat tables byte for
byte. (From Arcade-JalecoMS1Z_MiSTer; there byte 2 carries other fields too,
here only bit 0 = quizmoon is used.)

Only macrossp (a shooter) gets a copy; quizmoon is a quiz game.

autofire_releases/ is git-ignored: a derived local tree. Re-run this whenever
releases/ changes:

    python3 tools/gen_autofire_mra.py          # rebuilds autofire_releases/
    python3 tools/gen_autofire_mra.py --check  # only reports what is stale

MiSTer caveat (NMK16, seen on the board 2026-09-19): the firmware copies a
saved config/dips/<mra name>.dip over the WHOLE switches value, byte 2
included, so a game whose DIPs were ever changed in the OSD keeps its old
byte 2 and the Autofire options stay hidden until that file is deleted or
System > "Reset settings" writes the defaults back. The copies share the .mra
<name> with releases/, so the two trees collide in exactly that way.
"""
import argparse
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "releases")
DST = os.path.join(ROOT, "autofire_releases")

# Parent titles (the releases/ file name, or an `_alternatives/_<Parent>`
# directory) that get an autofire copy, matched as a prefix.
INCLUDED = (
    "Macross Plus",
)

AUTOFIRE_BIT = 0x80  # <switches> byte 2, bit 7 -> autofire_unlock

# The real element sits on its own line; a header comment may quote the tag
# mid-line and must not match.
SWITCHES_RE = re.compile(
    r'^(\s*<switches default=")([0-9A-Fa-f]{2}),([0-9A-Fa-f]{2}),([0-9A-Fa-f]{2})(")',
    re.MULTILINE,
)


def parent_of(rel):
    """Parent title for a releases-relative .mra path."""
    parts = rel.split(os.sep)
    if parts[0] == "_alternatives":
        return parts[1][1:]          # strip the leading underscore
    return os.path.splitext(parts[-1])[0]


def included(rel):
    p = parent_of(rel)
    return any(p.startswith(x) for x in INCLUDED)


def transform(text, rel):
    hits = SWITCHES_RE.findall(text)
    if len(hits) != 1:
        raise SystemExit(f'{rel}: expected exactly one <switches default="a,b,c"> '
                         f'line, found {len(hits)}')

    def repl(m):
        b2 = int(m.group(4), 16) | AUTOFIRE_BIT
        return f"{m.group(1)}{m.group(2)},{m.group(3)},{b2:02X}{m.group(5)}"

    out = SWITCHES_RE.sub(repl, text, count=1)
    note = ("  <!-- autofire_releases/ copy (tools/gen_autofire_mra.py): identical to\n"
            "       releases/ except that <switches> byte 2 has bit 7 set, which unhides\n"
            "       the P1/P2 Autofire options in the core's OSD (bit 0 of this byte\n"
            "       selects quizmoon). -->\n")
    # Directly above the element, so a diff against releases/ is one hunk.
    return re.sub(r'^(\s*<switches default=")',
                  lambda m: note + m.group(0), out, count=1, flags=re.MULTILINE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="report stale/missing files, write nothing")
    args = ap.parse_args()

    files = []
    for dp, _, fns in os.walk(SRC):
        for fn in fns:
            if fn.endswith(".mra"):
                files.append(os.path.relpath(os.path.join(dp, fn), SRC))
    files.sort()

    wanted, skipped = {}, []
    for rel in files:
        if not included(rel):
            skipped.append(rel)
            continue
        with open(os.path.join(SRC, rel), encoding="utf-8") as f:
            wanted[rel] = transform(f.read(), rel)

    if args.check:
        stale = 0
        for rel, text in wanted.items():
            p = os.path.join(DST, rel)
            if not os.path.exists(p) or open(p, encoding="utf-8").read() != text:
                print("STALE  ", rel)
                stale += 1
        if os.path.isdir(DST):
            for dp, _, fns in os.walk(DST):
                for fn in fns:
                    rel = os.path.relpath(os.path.join(dp, fn), DST)
                    if rel not in wanted:
                        print("EXTRA  ", rel)
                        stale += 1
        print(f"{len(wanted)} wanted, {len(skipped)} not in INCLUDED, {stale} stale/extra")
        sys.exit(1 if stale else 0)

    if os.path.isdir(DST):
        shutil.rmtree(DST)
    for rel, text in wanted.items():
        p = os.path.join(DST, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
    print(f"wrote {len(wanted)} .mra into {os.path.relpath(DST, ROOT)}/ "
          f"({len(skipped)} not in INCLUDED):")
    for rel in sorted(wanted):
        print("  autofire:", rel)


if __name__ == "__main__":
    main()
