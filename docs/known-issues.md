# Known issues and findings — Arcade-NMKMacPlus_MiSTer

Every entry is closed by a measurement, or says what would close it. Numbering
is `MP-n`. The oracle is MAME 0.289 (`~/mame`, patched per
`tools/mame-patches/macrossp-oracle.patch`, run with `MP_ORACLE=1`).

## MP-1 — MAME's picture F+1 is the composition of state F (closed, measured)

`sim/oracle/macplus_capture.lua` dumps the video state at `frame_done` and the
picture `screen:pixels()` returns at the same instant. `tools/macplus_model.py`
renders a state exactly as `macrossp.cpp` + `drawgfx` describe (PLAN 1.5).

- model(state F) against MAME picture F+1: **0 differing pixels** on every
  frame sampled.
- Against pictures F-1 and F, moving frames differ by thousands of pixels:
  e.g. attract frame 400 differs by 2,877 against both, frame 1100 by 33,074
  against F-1.
- Sweeps, every 25th frame (`tools/model_sweep.py`):

  | capture | exact | non-blank among them |
  |---|---|---|
  | macrossp attract, 1,800 frames | 72 / 72 | 70 |
  | macrossp scripted play, 5,400 frames | 216 / 216 | 214 |

- The play frames include 46-106 sprites on screen, alpha sprites (up to
  28), zoomed sprites (up to 23) and two zoomed BG layers.
- quizmoon attract: frames 300, 700, 1100 and 1500 are exact (86,016 pixels
  each, 17,199-86,016 non-black).

So PLAN 1.5 is right as written, including the implicit pri-31 claim, the
average-alpha and the zoom arithmetic. `screen:pixels()` does not include the
fade register's brightness: every sampled frame has fade byte 40 (full
brightness), so a fade scene is still needed to settle Q10.

## MP-2 — Q1: the executed main-CPU code is 68000 code (closed; quizmoon's coverage is thin)

`tools/q1_opcode_coverage.py` streams MAME's debugger trace through a FIFO and
keeps one line per unique PC. macrossp, 300 emulated seconds of attract and
scripted play (`sim/oracle/macplus_play.lua`, with the infinite-lives and
invincibility cheats so it reaches later scenes):
- **11,442 unique PCs, 60 mnemonics, no 68020-only instruction**: no
  bitfield, CAS, CHK2/CMP2, PACK/UNPK, MOVEC/MOVES, CALLM/RTM, 32-bit
  MUL/DIV, EXTB or TRAPcc.
- One 68020 addressing form: `btst #$1,($f177b4,A6)`, a 32-bit base
  displacement (full extension word). TG68K implements it (`extAddr_Mode`).
- PC-relative calls (`jsr (d16,PC)`) are ordinary 68000.

quizmoon, 300 emulated seconds, reached only 2,945 unique PCs, and they
include no 68020-only instruction or addressing form. Its scripted input
probably never started a quiz, so this coverage is thin; the whole-board
simulations will show any gap as an illegal-instruction trap.

A static disassembly of the whole ROM finds hundreds of "68020-only"
instructions, CALLM and BKPT among them. That is data decoded as code, and
not evidence. TG68K's own gaps, by its decoder comments, are MOVES ("TODO")
and CALLM/RTM; none is executed.

The trace starts at the reset vector: SSP `0x00F1FFFC`, PC `0x000800`
(quizmoon PC `0x02C73A`). That also confirms the `LOAD32_BYTE` order: u4 is
the most significant byte.

## MP-3 — Q3 / Q8: the per-line load, measured (closed)

`tools/q3_q8_measure.py`, every 5th frame:

| capture | sprites on screen (max) | worst line: sprites / tile columns / pixels |
|---|---|---|
| macrossp play | 97 | 38 / 63 / 950 |
| quizmoon attract | 377 | 49 / 53 / 848 |

A line is 3,125 clocks (MAME's raster, D4), so a line renderer with a
one-pixel-per-clock fill has about 3x headroom at the worst line measured. The
sprite design stays a line renderer (PLAN 2.6.4).

BG zoom (macrossp only; quizmoon never zooms):
- layers 1 and 2 are zoomed in 381 of 1,080 sampled frames, with `incx` and
  `incy` between 1.0 and 2.0;
- layer 0 once, with a zero table.

**Except line 0.** Its line-zoom halfword is `0xE0xx` (the zoom-control
pattern of `vr[2]`, 355 of 368 times `0xE080`). MAME uses it as that line's
`incx`, 898x. Line 0 of a zoomed layer is therefore noise in MAME. Whether the
board offsets the table by a line is unknown.

The engine does not need to care. With no shear, a line reads one map row,
and a map row has **64 tile columns**. So any `incx` needs at most 64 tile-row
fetches per layer per line. The BG engine is two passes over a 64-entry
per-line column cache: mark the needed columns, fetch them pipelined, then
draw. That bounds DDR3 traffic at 3 x 64 fetches per line, whatever the
zoom.

## MP-4 — MAME renders before the vblank handler runs; a live line renderer cannot (open, expected)

MAME's `vblank_begin` runs the `screen_vblank` callback (the `old2 <- old <-
live` sprite copy) and then the frame update, all at the vblank instant. The
game's IRQ3 handler only runs afterwards. So MAME's picture shows:
- the layers, palette and line-zoom state from **before** the handler;
- the sprite list copied at that same instant.

A line renderer reading live VRAM, as the board presumably does, shows the
handler's layer writes one frame earlier than MAME, while the sprite buffers
move at the same instant in both.

Expected consequence in the whole-board gate (M2): the layers match MAME at
one offset and the sprites at the next. MS1Z-12 had the same split for the
opposite reason. The sprite buffer depth is therefore a parameter (1 or 2
stages), chosen by that gate. The finding is recorded as MAME behaviour
versus the board: MAME's 2-stage comment was tuned by eye against its own
render instant.

## MP-5 — M1: the video RTL against MAME's pictures (closed for the captures so far)

`sim/rtl/video_state` loads a capture state through the CPU port, lets two
vblank copies carry the sprite list into `old2`, serves ROM rows with a set
latency (one BG response a clock, as the DDR3 arbiter will), and compares the
third frame with MAME picture F+1 (MP-1).

- Every 10th frame of the macrossp scripted-play capture: **540 / 540
  pixel-exact**, at 40 clocks of ROM latency. They cover 46-106 sprites on
  screen, alpha sprites, zoomed sprites and zoomed BG layers.
- The attract capture is also exact so far (96 of 96).
- Line budget: the sprite line renderer peaks at 1,018 of 3,125 clocks (18
  sprites on the line); BG lines take 907-976 clocks. There are 0 overruns.

Two bugs were found by this gate, neither visible to the Python model:

1. **The engines drew the line the beam was on.** At `vtick`, `vcount` is
   still the old line, so `vcount + 1` is the line about to be displayed.
   The target must be `vcount + 2`, the MS1Z sprline lesson again. It showed
   as a tear whose size grew with ROM latency: 2,566, 3,268 and 7,181 pixels
   at 1, 40 and 200 clocks. That growth is what made it a race and not a
   data error.
2. **The alpha blend misaligned the channels.** `({1'b0,a} + {1'b0,b}) >> 1`
   stays 9 bits wide inside a concatenation, so the 27-bit result was
   truncated into 24 bits. Blue was right and red and green were wrong.
   Found on the one alpha sprite of play frame 900 by splitting MAME's colour
   into its layer and sprite inputs.

The harness also measured the output latency: `rgb` is two pixels behind
`hcount` (the MS1-59 alignment). `sim/rtl/macplus_frames` uses the same
offset.

## MP-6 — The CPU's bus path is 2.4x slower than MAME's 68020 (open, D3)

The whole board boots from reset in `sim/rtl/macplus_frames`:
- TG68K runs the game and IRQ3 is acknowledged every frame;
- the sound 68000 reads its latch and programs the ES5506;
- core frames 50-119 are pixel-exact against MAME frames 43-45 (a static
  screen with 87,438 lit pixels).

D3 compares the idle loop's count (writes to `0xF1015A`) per frame with the
patched MAME (`MP_ORACLE=1`, `sim/oracle/macplus_idle.lua`) on that same
static screen:

| | idle iterations per frame |
|---|---|
| MAME (m68020, 25 MHz) | 20,114 |
| core, clock enable 25/48 | ~8,300 |
| core, clock enable 48/48 | ~9,000 |

Raising the enable barely helps, so the limit is the bus path. Each 16-bit
TG68K access costs about 8 fabric clocks: the adapter's capture and map
states, the board's registered acknowledge, the program-ROM latency, and then
the next enable. The loop is about ten such accesses (the absolute-long
operands); MAME's 68020 does it in about 21 of its cycles, roughly 40 of our
clocks.

To be done before the enable can be tuned:
- a program-fetch line buffer, so sequential words need no board cycle;
- RAM and I/O answering without the extra registered stages.

Then the enable is set so the idle count matches MAME across busy scenes, not
just this static one.
