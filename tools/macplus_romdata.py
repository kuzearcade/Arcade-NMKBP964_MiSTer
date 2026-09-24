"""The one ROM table of Arcade-NMKBP964_MiSTer (docs/PLAN.md Appendix D).

The DDR3 image is 62 MB at 0x30000000, the same layout for both games:

    0x0000000  main program    4 MB   32-bit interleave, u4 = most significant byte
    0x0400000  sound program   1 MB   16-bit interleave, even chip high
    0x0500000  text tiles      1 MB   (512 KB used on macrossp; none on quizmoon)
    0x0600000  sprites        16 MB   32-bit interleave (u12 at +0 .. u9 at +3)
    0x1600000  BG0             8 MB
    0x1E00000  BG1             8 MB
    0x2600000  BG2             8 MB
    0x2E00000  samples 0/1     8 MB   quizmoon: 16-bit words; macrossp: 4 MB of raw bytes
    0x3600000  samples 2/3     8 MB   quizmoon only
    0x3E00000  end

Each region is a list of pieces:
    ('il', width, [(file, lane), ...])   interleave; lane 0 = lowest address byte
    ('file', name)                        the file as it is
    ('pad', nbytes, byte)                 filler
Pieces are packed in order and the region is padded to its size with 0x00.
"""

REGIONS = [
    ('main',  0x0000000, 0x0400000),
    ('snd',   0x0400000, 0x0100000),
    ('text',  0x0500000, 0x0100000),
    ('spr',   0x0600000, 0x1000000),
    ('bg0',   0x1600000, 0x0800000),
    ('bg1',   0x1E00000, 0x0800000),
    ('bg2',   0x2600000, 0x0800000),
    ('smp01', 0x2E00000, 0x0800000),
    ('smp23', 0x3600000, 0x0800000),
]
TOTAL = 0x3E00000

SETS = {
    'macrossp': dict(
        desc='Macross Plus', year='1996', manufacturer='MOSS / Banpresto', zips=['macrossp.zip'],
        rotation='vertical (ccw)', quiz=False, parent=None,
        pieces={
            'main': [('il', 4, [('bp964a-c.u4', 0), ('bp964a-c.u3', 1), ('bp964a-c.u2', 2), ('bp964a-c.u1', 3)])],
            'snd':  [('il', 2, [('bp964a.u21', 0), ('bp964a.u20', 1)])],
            'text': [('file', 'bp964a.u19')],
            'spr':  [('il', 4, [('bp964a.u12', 0), ('bp964a.u11', 1), ('bp964a.u10', 2), ('bp964a.u9', 3)])],
            'bg0':  [('file', 'bp964a.u13'), ('file', 'bp964a.u14')],
            'bg1':  [('file', 'bp964a.u15'), ('file', 'bp964a.u16')],
            'bg2':  [('file', 'bp964a.u17'), ('file', 'bp964a.u18')],
            'smp01': [('file', 'bp964a.u24')],     # raw bytes; the core pads each word with 0xFF
            'smp23': [],
        }),
    'quizmoon': dict(
        desc='Quiz Bishoujo Senshi Sailor Moon - Chiryoku Tairyoku Toki no Un', year='1997',
        manufacturer='Banpresto', zips=['quizmoon.zip'], rotation='horizontal', quiz=True, parent=None,
        pieces={
            'main': [('il', 4, [('u4.bin', 0), ('u3.bin', 1), ('u2.bin', 2), ('u1.bin', 3)]),
                     ('pad', 0x200000 - 0x80000, 0x00),
                     ('il', 4, [('u8.bin', 0), ('u7.bin', 1), ('u6.bin', 2), ('u5.bin', 3)])],
            'snd':  [('il', 2, [('u21.bin', 0), ('u20.bin', 1)])],
            'text': [],
            'spr':  [('il', 4, [('u12.bin', 0), ('u11.bin', 1), ('u10.bin', 2), ('u9.bin', 3)])],
            'bg0':  [('file', 'u13.bin')],
            'bg1':  [('file', 'u15.bin')],
            'bg2':  [('file', 'u17.bin')],
            'smp01': [('il', 2, [('u26.bin', 0), ('u24.bin', 1)])],
            'smp23': [('il', 2, [('u27.bin', 0), ('u25.bin', 1)])],
        }),
}


def build_image(setname, read):
    """The DDR3 image exactly as the .mra produces it. read(name) -> bytes."""
    img = bytearray(TOTAL)
    for region, base, size in REGIONS:
        pos = base
        for p in SETS[setname]['pieces'][region]:
            if p[0] == 'file':
                d = read(p[1]); img[pos:pos + len(d)] = d; pos += len(d)
            elif p[0] == 'pad':
                img[pos:pos + p[1]] = bytes([p[2]]) * p[1]; pos += p[1]
            else:
                w, lanes = p[1], p[2]
                n = len(read(lanes[0][0]))
                for f, lane in lanes:
                    d = read(f)
                    img[pos + lane: pos + lane + w * n: w] = d
                pos += w * n
        if pos - base > size:
            raise SystemExit(f'{setname}: region {region} overflows ({pos - base:#x} > {size:#x})')
    return img
