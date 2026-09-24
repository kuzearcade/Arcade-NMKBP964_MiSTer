#!/usr/bin/env python3
"""Generate the Arcade-NMKBP964_MiSTer .mra files from tools/macplus_romdata.py.

    tools/gen_macplus_mra.py            write releases/*.mra
    tools/gen_macplus_mra.py --check    build each set's DDR3 image from the zips
                                        exactly as the .mra lays it out, and
                                        compare it with the simulation images
                                        (tools/mk_macplus_images.py) region by
                                        region: the off-board load model (NMK-22)

The whole image goes to DDR3 at 0x30000000 through `address=` (PLAN D1):
Main_MiSTer writes it there itself and the core copies the SDRAM part at boot.

Interleave maps: the rightmost map character is the LOWEST-addressed output
byte (measured on the board by MS1BCD for output="16": map="01" is the even
byte). So lane 0 of a 32-bit interleave is map="0001".

DIPs come from MAME's own -listxml. MAME's DSW port is 32 bits with the
switches in [31:16]: SW1 = [23:16] is <switches> byte 0, SW2 = [31:24] byte 1.
Byte 2 is the game mode: bit 0 quizmoon, bit 7 the Autofire unlock
(tools/gen_autofire_mra.py sets it in autofire_releases/).
"""
import argparse, os, re, subprocess, sys, zipfile
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape as _xml_escape

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import macplus_romdata as R

ROOT = os.path.join(HERE, '..')
ROMS = os.path.join(ROOT, 'mame_roms')
RELEASES = os.path.join(ROOT, 'releases')
MAME = os.path.expanduser('~/mame/mame')

def x(v): return _xml_escape(str(v))
FAT_FORBIDDEN = {':': '-', '/': '-', '\\': '-', '?': '', '*': '', '<': '', '>': '', '|': '-', '"': "'"}
def fat_safe(desc): return ''.join(FAT_FORBIDDEN.get(c, c) for c in desc).rstrip('. ')

_COIN = re.compile(r'^(\d+) Coins?/(\d+) Credits?$')
def dip_id(name):
    if name == 'Free Play': return 'Free_Play'
    m = _COIN.match(name)
    return f'{m.group(1)}C_{m.group(2)}C' if m else name

def dips_from_mame(setname):
    xml = subprocess.run([MAME, '-listxml', setname], capture_output=True, text=True).stdout
    root = ET.fromstring(xml)
    mach = next(m for m in root.iter('machine') if m.get('name') == setname)
    default, dips = 0xFFFF, []
    for sw in mach.iter('dipswitch'):
        if sw.get('tag') not in ('DSW', ':DSW'):
            continue                                   # quizmoon's Test/Tilt are INPUTS bits, not switches
        mask = int(sw.get('mask')) >> 16
        lo = (mask & -mask).bit_length() - 1
        hi = mask.bit_length() - 1
        width = hi - lo + 1
        ids = ['Undefined'] * (1 << width)
        for v in sw.iter('dipvalue'):
            raw = (int(v.get('value')) >> 16) >> lo
            ids[raw] = v.get('name')
            if v.get('default') == 'yes':
                default = (default & ~mask) | (int(v.get('value')) >> 16)
        dips.append(dict(name=sw.get('name'), bits=(lo, hi), ids=ids))
    return default, dips

def switches_xml(setname, flags):
    default, dips = dips_from_mame(setname)
    out = [f'  <switches default="{default & 0xFF:02X},{default >> 8:02X},{flags:02X}">\n']
    for d in dips:
        if d['name'] in ('Unused', 'Unknown'):
            continue
        lo, hi = d['bits']
        bits = f'{lo}' if lo == hi else f'{lo},{hi}'
        out.append(f'    <dip bits="{bits}" name="{x(d["name"])}" ids="{",".join(x(dip_id(i)) for i in d["ids"])}"/>\n')
    out.append('  </switches>\n')
    return ''.join(out)

def crc_of(z, name):
    return z.getinfo(name).CRC

def rom_xml(setname):
    s = R.SETS[setname]
    z = zipfile.ZipFile(os.path.join(ROMS, s['zips'][0]))
    out = []
    for region, base, size in R.REGIONS:
        out.append(f'    <!-- {region}: 0x{size:07X} bytes at image 0x{base:07X} -->\n')
        used = 0
        for p in s['pieces'][region]:
            if p[0] == 'file':
                out.append(f'    <part crc="{crc_of(z, p[1]):08x}" name="{x(p[1])}"/>\n')
                used += z.getinfo(p[1]).file_size
            elif p[0] == 'pad':
                out.append(f'    <part repeat="0x{p[1]:X}">{p[2]:02X}</part>\n'); used += p[1]
            else:
                w, lanes = p[1], p[2]
                out.append(f'    <interleave output="{8 * w}">\n')
                for f, lane in lanes:
                    m = ''.join('1' if k == lane else '0' for k in reversed(range(w)))
                    out.append(f'      <part crc="{crc_of(z, f):08x}" name="{x(f)}" map="{m}"/>\n')
                out.append('    </interleave>\n')
                used += w * z.getinfo(lanes[0][0]).file_size
        if used < size:
            out.append(f'    <part repeat="0x{size - used:X}">00</part>\n')
    return ''.join(out)

BUTTONS = {'macrossp': ('Shot,Bomb,Button 3,Button 4,Start,Coin', 'A,B,X,Y,Start,R'),
           'quizmoon': ('Answer 1,Answer 2,Answer 3,Answer 4,Start,Coin', 'A,B,X,Y,Start,R')}

def mra(setname):
    s = R.SETS[setname]
    flags = 0x01 if s['quiz'] else 0x00
    names, defaults = BUTTONS[setname]
    return f"""<!--
  {x(s['desc'])}: {x(s['manufacturer'])} {s['year']}, MAME nmk/macrossp.cpp ({setname}).
  Generated by tools/gen_macplus_mra.py from tools/macplus_romdata.py; do not
  hand-edit. The whole 62 MB image goes to DDR3 at 0x30000000 (address=); the
  core copies its first 22 MB into SDRAM at boot. <switches> byte 2: bit 0 =
  quizmoon, bit 7 = Autofire unlock.
-->
<misterromdescription>
  <name>{x(s['desc'])}</name>
  <mratimestamp>202609240000</mratimestamp>
  <mameversion>0289</mameversion>
  <setname>{setname}</setname>
  <year>{s['year']}</year>
  <manufacturer>{x(s['manufacturer'])}</manufacturer>
  <category>Arcade</category>
  <rbf>NMKBP964</rbf>
  <rotation>{s['rotation']}</rotation>

{switches_xml(setname, flags)}
  <buttons names="{names}" default="{defaults}"/>

  <rom index="0" zip="{'|'.join(s['zips'])}" md5="none" address="0x30000000">
{rom_xml(setname)}  </rom>
</misterromdescription>
"""

CARRY_RE = re.compile(r'\n  <!-- (?:High scores|Cheats).*?</rom>\n(?:  <nvram index="4"[^/]*/>\n)?', re.S)
def carry_over(path):
    if not os.path.exists(path): return ''
    return ''.join(CARRY_RE.findall(open(path, encoding='utf-8').read()))

def check():
    import hashlib
    for sn, s in R.SETS.items():
        z = zipfile.ZipFile(os.path.join(ROMS, s['zips'][0]))
        img = R.build_image(sn, z.read)
        simdir = os.path.expanduser(f'~/mp_images/{sn}')
        cmp = {'main': 'main.bin', 'snd': 'snd.bin', 'spr': 'spr.bin', 'bg0': 'bg0.bin', 'bg1': 'bg1.bin', 'bg2': 'bg2.bin'}
        bad = 0
        for region, base, size in R.REGIONS:
            if region in cmp and os.path.exists(os.path.join(simdir, cmp[region])):
                ref = open(os.path.join(simdir, cmp[region]), 'rb').read()
                n = min(len(ref), size)
                if img[base:base + n] != ref[:n]:
                    bad += 1; print(f'  {sn} {region}: DIFFERS from {cmp[region]}')
        print(f'{sn}: image {len(img):#x} bytes, md5 {hashlib.md5(img).hexdigest()}, {bad} regions differ from the sim images')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--image', metavar='SET', help='write the DDR3 image for the hardware-path sim')
    a = ap.parse_args()
    if a.check: return check()
    if a.image:
        z = zipfile.ZipFile(os.path.join(ROMS, R.SETS[a.image]['zips'][0]))
        out = os.path.expanduser(f'~/mp_images/{a.image}/ddr_image.bin')
        open(out, 'wb').write(R.build_image(a.image, z.read)); print('wrote', out); return
    os.makedirs(RELEASES, exist_ok=True)
    for sn, s in R.SETS.items():
        path = os.path.join(RELEASES, fat_safe(s['desc']) + '.mra')
        keep = carry_over(path)
        open(path, 'w', encoding='utf-8').write(mra(sn).replace('</misterromdescription>', keep + '</misterromdescription>'))
        print('wrote', os.path.relpath(path, ROOT))

if __name__ == '__main__':
    main()
