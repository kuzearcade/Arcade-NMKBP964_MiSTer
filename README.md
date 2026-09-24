# Arcade-NMKMacPlus_MiSTer

A MiSTer FPGA core for the Banpresto BP964A / BP965A board:

| set | game | orientation |
|---|---|---|
| `macrossp` | Macross Plus (MOSS / Banpresto, 1996) | vertical |
| `quizmoon` | Quiz Bishoujo Senshi Sailor Moon - Chiryoku Tairyoku Toki no Un (Banpresto, 1997) | horizontal |

**In development; not yet run on a DE10-Nano.**

The board has:
- a 68EC020 at 25 MHz (TG68K.C here);
- a sound 68000 at 16 MHz (fx68k) with an Ensoniq ES5506;
- three zoomable 8 bpp tilemaps, a 4 bpp text layer, and 1,024 zoomable
  sprites with 50 % translucency.

MAME's `nmk/macrossp.cpp` (David Haywood, Paul Priest) is the behavioural
reference, and every claim below is a measurement against it
(`docs/known-issues.md`):

- **Video block:** MAME's pictures reproduced **pixel for pixel** from MAME's
  own state. 540 of 540 gameplay frames and every attract frame tried so far,
  including sprites, zoom, alpha and zoomed layers.
- **Whole board from reset:** boots, runs the attract, and matches MAME frame
  for frame at a constant offset. It plays sound through the ES5506. The
  68EC020's speed is being tuned to MAME's work per frame (D3, MP-6).
- **Memory:** the 62 MB ROM image loads into DDR3 (`address=` in the `.mra`),
  and the program, sprite and text ROMs are copied into SDRAM at boot. It
  runs on the standard 32 MB SDRAM.

See `docs/PLAN.md` for the plan and its gates, `docs/known-issues.md` for
every finding (MP-n), and `docs/provenance.md` for where every file came from.

## Features

DIP switches in the OSD, pause, high scores (macrossp), cheats (seven slots,
named in each `.mra`), autofire (macrossp, unlocked by the `.mra`),
orientation (both quarter turns), flip, CRT Adjust, scandoubler/HQ2x, MAME's
keyboard layout, savestates (four slots; Alt+F1/F5/F3/F4 save, F1/F5/F3/F4
load; `docs/known-issues.md` MP-12).

## Credits

- MAME's driver: David Haywood, Paul Priest.
- TG68K.C: Tobias Gubener, as shipped (with its documented changes) by
  TheJesusFish's Arcade-ITech32_MiSTer.
- The ES5506 model, and the TG68K wrapper and bus adapter this core's CPU
  block derives from: TheJesusFish (Arcade-ITech32_MiSTer).
- fx68k: Jorge Cwik. CRT Adjust: Umberto Parisi (rmonic79). Hiscore module:
  Alan Steremberg, Jim Gregory. MiSTer framework: Sorgelig and contributors.

GPL-3.0 (see `LICENSE`); third-party files keep their own notices.
