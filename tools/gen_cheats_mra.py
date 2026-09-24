#!/usr/bin/env python3
"""Add a <rom index="5"> cheat table to each .mra, from Pugsy's MAME cheat XML.

Derived from Arcade-JalecoMS1Z_MiSTer's tools/gen_cheats_mra.py (table layout,
masked kind). One .rbf serves two games here, so the OSD's seven slots are
named generically ("Cheat 1".."Cheat 7", MacPlus.sv) and each game chooses its
seven below; the .mra comment names them. Only continuous cheats are taken
(script state="run"): the engine (rtl/cheats.sv) applies a slot every frame,
which would be wrong for one-shot "on" cheats and cannot express parameters.

Table layout, big-endian, 6 bytes per action, 3 actions per slot, 7 slots:
    1 byte count (0..3), 1 byte reserved,
    then 3 x { 3 bytes address, 1 byte kind, 2 bytes value }
    kind 0 byte, 1 word, 2 masked byte (value = {mask, byte})
Addresses are the 68EC020's (main RAM F00000-F1FFFF); MacPlus.sv maps them
onto the 32-bit big-endian RAM's byte lanes.
"""
import re, glob, os, sys

SLOTS = {
    'macrossp': ["Infinite Credits", "P1 Infinite Lives", "P1 Infinite Bombs", "P1 Invincibility",
                 "P1 Maximum Fire Power", "P2 Infinite Lives", "P2 Invincibility"],
    'quizmoon': ["Infinite Credits", "P1 Infinite Lives", "P2 Infinite Lives"],
}
MAXACT = 3
ACT = re.compile(r'<action(?:\s+condition="[^"]*")?\s*>'
                 r'maincpu\.([pr])([bw])@([0-9A-Fa-f]+)=([0-9A-Fa-f]+)</action>')

def parse(path, wanted):
    t = open(path, encoding='utf-8', errors='replace').read()
    out = {}
    for m in re.finditer(r'<cheat desc="([^"]*)"\s*>(.*?)</cheat>', t, re.S):
        d, body = m.group(1).strip(), m.group(2)
        if d not in wanted or '<parameter' in body or 'state="run"' not in body or d in out:
            continue
        acts = [(int(a, 16), 1 if sz == 'w' else 0, int(v, 16)) for _, sz, a, v in ACT.findall(body)]
        if 0 < len(acts) <= MAXACT:
            out[d] = acts
    return out

def table(found, slots):
    rows = []
    for i in range(7):
        acts = found.get(slots[i], []) if i < len(slots) else []
        rec = [len(acts), 0]
        for k in range(MAXACT):
            if k < len(acts):
                a, sz, v = acts[k]
                rec += [(a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF, sz, (v >> 8) & 0xFF, v & 0xFF]
            else:
                rec += [0] * 6
        rows.append(rec)
    return rows

def main():
    D = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/Downloads/cheat0279/cheat')
    root = os.path.dirname(os.path.abspath(__file__)) + '/..'
    for p in sorted(glob.glob(root + '/releases/*.mra')):
        t = open(p, encoding='utf-8').read()
        if 'index="5"' in t:
            continue
        sn = re.search(r'<setname>([^<]+)', t).group(1).strip()
        slots = SLOTS.get(sn, [])
        src = f'{D}/{sn}.xml'
        if not slots or not os.path.exists(src):
            continue
        found = parse(src, slots)
        body = '\n'.join('        ' + ' '.join(f'{b:02X}' for b in r) for r in table(found, slots))
        names = '; '.join(f'Cheat {i+1} = {n}' for i, n in enumerate(slots) if n in found)
        blk = (f'\n  <!-- Cheats (Pugsy\'s MAME cheat database 0.279). {names}.\n'
               f'       See tools/gen_cheats_mra.py. -->\n'
               f'  <rom index="5" md5="none">\n    <part>\n{body}\n    </part>\n  </rom>\n')
        open(p, 'w', encoding='utf-8').write(t.replace('</misterromdescription>', blk + '</misterromdescription>'))
        print(f'{sn}: {len(found)} cheats ({names})')

if __name__ == '__main__':
    main()
