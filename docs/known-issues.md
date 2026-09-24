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

## MP-5 — M1: the video RTL against MAME's pictures (closed: 900 / 900)

`sim/rtl/video_state` loads a capture state through the CPU port, lets two
vblank copies carry the sprite list into `old2`, serves ROM rows with a set
latency (one BG response a clock, as the DDR3 arbiter will), and compares the
third frame with MAME picture F+1 (MP-1).

Every 10th frame of each capture, at 40 clocks of ROM latency:

| capture | pixel-exact | non-blank among them |
|---|---|---|
| macrossp scripted play (46-106 sprites, alpha, zoomed sprites, zoomed BG) | **540 / 540** | 535 |
| macrossp attract | **180 / 180** | 175 |
| quizmoon attract (up to 377 sprites) | **180 / 180** | 175 |

The sprite line renderer peaks at 1,451 of 3,125 clocks (quizmoon: 1,267),
and BG lines take 907-976 clocks. There are 0 overruns anywhere.

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

## MP-6 — The CPU's bus path was 2.4x slower than MAME's 68020 (fixed; D3 calibration in progress)

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

**Fix: `rtl/macplus/macplus_cpu_bus.sv`.** TG68K, a lean adapter derived from
ITech32's, main RAM and a 4 KB program-ROM cache (256 lines of 16 bytes, filled
from the ROM port) in one module:
- a RAM write takes 2 clocks;
- a RAM read or cache hit takes 3;
- video, I/O, the latch and cache misses keep the board handshake.

The idle count on the same static screen, at each clock enable:

| enable (of 48 MHz) | idle iterations per frame |
|---|---|
| 25/48 | ~17,300 |
| 28/48 | ~19,400 |
| **29/48** | **20,198** |
| 30/48 | ~20,800 |
| 32/48 | ~21,600 |
| 48/48 | ~22,900 |
| MAME | 20,114 |

29/48 (about 29 MHz of TG68K microsteps) is within 0.4 % of MAME on this
screen, and the core uses it for now.

**The idle loop is a poor calibration lever.** Per frame, the static screen
gives:

| enable | idle iterations |
|---|---|
| 18/48 | 16,063 |
| 21/48 | 16,061 |
| 25/48 | 17,427 |
| 29/48 | 20,196 |

The loop is memory-bound: each of its accesses costs at least three fabric
clocks whatever the enable. Below about 24/48 the enable barely changes it.

The measure D3 needs is the fraction of a frame spent working, 1 - idle /
(that setting's full-idle count). On the attract (frames 400-558, against
MAME's frames +1) it is:

| | busy frames (12) | all frames |
|---|---|---|
| MAME | 9.3 % | 4.7 % |
| 18/48 | 4.8 % | 5.4 % |
| 21/48 | 4.8 % | 5.3 % |
| 29/48 | 4.0 % | 4.4 % |

The attract is too light a load to calibrate on, and the core's work time is
also mostly bus-bound. The calibration needs gameplay: the M2 harness is to
get the same scripted play and cheat pokes as `macplus_play.lua`. Until then
29/48 stands, because it matches MAME's idle count and its all-frame average
work.

## MP-7 — The video output clock: 625 dots of 9.6 MHz per line (open, analog width)

MAME's raster is 512 x 256 at exactly 60 Hz, a 7.864 MHz dot clock, which is
3,125 clk_sys at 48 MHz or 6,250 clk_ram at 96 MHz per line. `video_retime`
re-times the picture onto clk_ram with an integer number of clocks per dot
and needs dots x divider = clocks per line exactly. The exact fits are
625 x 10 and 1,250 x 5, and the retimer does not double pixels, so the
output is **625 dots of 9.6 MHz** with the picture in dots 0..383.
- Line and frame are exactly MAME's (15.36 kHz, 60.00 Hz, 256 lines), so the
  scaler and HDMI see a correct 384 x 240 (224) picture.
- On an analog CRT the active width is 40 us of a 65 us line instead of
  MAME's 48.8 us: about 18 % narrower. CRT Adjust's H-Size widens it.
- `video_retime` gained parameters for its vertical window and vsync offset
  (it had the NMK16 rows 16..239 and a vsync 24 lines into the blank
  hard-coded, which on a 16-line blank would never fire). The defaults keep
  the siblings' geometry.

OSD Flip currently uses `screen_rotate`'s framebuffer flip. NMK-21 moved the
siblings to a flip inside the core, so that it reaches the analog output and
does not force the framebuffer; that is still to do here.

## MP-8 — The BG path keeps one DDR3 row in flight (open, measure in M3)

`macplus_rom_hw`'s BG front end sends one tile row at a time across the
48-to-96 MHz handshake, with two-flop synchronisers each way. At about
25 clk_sys per row that is fine unzoomed (75 rows a line, ~1,900 of 3,125
clocks). The zoomed scenes measured in MP-3 need up to ~121 rows a line,
which is close to the limit. The DDR3 side already pipelines up to 8 reads;
the front end needs a queue across the crossing to use them. The M3 run
decides with the BG overrun counters.

## MP-9 — The BG engine paired a column with its neighbour's tile word after a stall (fixed; M1 now injects stalls)

The first hardware-path run (`sim/rtl/macplus_hw`: `macplus_rom_hw`, the real
`sdram.sv` against its model, and a DDR3 model) did the following:
- copied the 22 MB SDRAM part in 3.52 s of board time;
- booted, with sound traffic identical to the reference sim (936 ES5506
  writes by frame 10 in both).

But its picture differed from MAME by 9,665 pixels on the first static
screen, where the reference sim was exact. The difference was exactly **one
16-pixel tile**: M3's pixel x was MAME's pixel x + 16, with 0 differences at
that offset. Only layer 0 draws that screen (the model, with each layer
removed in turn), so the fault was on the DDR3 BG path.

Cause, in `macplus_bgline`'s fetch stage:
- The two-stage VRAM read pipeline froze its valid flags while a ROM request
  waited for `rom_ready`.
- The VRAM's registered output did not freeze; it kept sampling the next
  column's address.
- After a stall, column C was issued with column C+1's tile word.

The reference harnesses accept every request on the clock it is raised, so
they never stall. Behind `macplus_rom_hw` `ready` comes a clock later.

Fix: the tile word is latched on the clock it arrives, independent of the
request stage, with one VRAM read in flight.

Gate change: the M1 harness takes `MP_RDY=n` (accept only every n-th clock).
With the fix, frames 900, 2250 and 4500 are exact at n = 1, 3 and 7. The
pre-fix engine passes at n = 1 and fails at n = 3 with **62,293** differing
pixels, so the gate can see this class now (MS1-18).

## MP-10 — First full compiles: M10K duplication and two timing faults (fixed)

1. **M10K 565 of 553 (estimated).** Every VRAM lane, line-zoom lane and
   sprite-RAM CPU lane was built twice: a CPU read, a CPU write and an
   engine read in one always block cannot map onto one M10K pair. That is
   NMK-10 again. Port A (the CPU's read and write) now has its own always
   block and port B (the engine) another, which is Quartus's
   true-dual-port template. The line-zoom RAMs are MLAB. Result: **550 of
   553**, which fits but with 3 blocks to spare.
2. **Main RAM with two write ports** (CPU and back door) in two always blocks
   was not inferred at all, which cost a megabit of registers. It now has
   one muxed port, as MS1Z's work RAM does: the back-door users only drive
   it with the CPU paused.
3. **Setup -32 ns:** the sprite engine's `0x100000 / dst` was a
   combinational 21-bit divider fed straight from the `old2` RAM (51 ns).
   It is now a 64-entry table read from a registered size, one state later.
4. **Setup -10.8 ns inside TG68K:** its asynchronous-read register file was
   inferred as an M10K with read-during-write bypass, putting the RAM's
   clock-to-out into the CPU's address and ALU paths.
   `AUTO_RAM_RECOGNITION OFF` on that instance makes it 512 flip-flops.

## MP-11 — First board run: the DDR3 offsets were 25 bits wide, the image is 62 MB (fixed)

The first bitstream on the DE10-Nano (md5 `0bcd566f...`, 2026-09-24):
- booted: the 22 MB copy, then the Banpresto screen pixel-exact and the
  attract with a correct text layer;
- but the scenes built from BG layer 2 were garbage: vertical stripes and
  broken artwork.

The DDR3 image itself was not at fault. `/dev/mem` at 0x30000000 read back
byte-identical to the local image in every region sampled.

The hardware-path simulation reproduced it once it reached those scenes
(frame 400 on). A response checker in `sim/rtl/macplus_hw` (every ROM
response against the image, in request order, per stream) named it:

| stream | bad / responses |
|---|---|
| BG0 | 0 / 2,486,151 |
| BG1 | 0 / 2,486,151 |
| BG2 | **79,210** / 2,486,151 |
| text | 0 / 2,476,776 |

The offsets from BG2 up need 26 bits: BG2 starts at 0x2600000 and the samples
at 0x2E00000, both above 32 MB. `bg_off` and the sample address were 25 bits
wide, so BG2 wrapped into the sprite region. That wrapped data is the
"garbled sprites" on the board; this scene has no sprites at all, and its
mech and starfield are layer 2. The samples wrapped too, so the board's sound
was wrong as well. BG1 wraps above its first 2 MB, which this scene does not
use.

The reference harnesses index each region separately and cannot see an
image-offset bug. The response checker is the gate for it now.

With the offsets 26 bits wide (bitstream md5 `5bb16d69...`, timing met: the
system clock at +0.831 ns; 33,052 ALMs, 548 / 553 M10K) the board runs the
attract correctly: the Banpresto screen, the specification page with its
mech, the zoomed tunnel and mech scenes, and the title screen.
