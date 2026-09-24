# Known issues and findings — Arcade-NMKBP964_MiSTer

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

## MP-6 — The CPU's bus path was 2.4x slower than MAME's 68020 (fixed; D3 closed by MP-13)

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

### Gameplay work, 2026-09-24: inconclusive

Three runs at CE 21, 25 and 29 / 48 (`MP_PLAY=1`, 1,300 frames), measured
from the level-3 acknowledge (the earlier measure started at vblank and
counted 0.4 µs "frames"), against MAME with perfect quantum, frames 720-1040:

| | mean µs | median | p90 | max |
|---|---|---|---|---|
| MAME | 1,237 | 382 | 3,421 | 9,253 |
| CE 21 | 718 | 483 | 1,074 | 6,406 |
| CE 25 | 770 | 462 | 2,695 | 7,550 |
| CE 29 | 576 | 416 | 2,184 | 4,999 |

The core's play diverges from MAME's within a few frames: the best
frame-to-frame correlation is 0.2. The medians hardly move across a 1.38x
change of clock, so this measure cannot choose CE. The static attract screen
still can: 319 µs at CE 29 against MAME's 333 µs. The bitstream keeps CE 29
until a gameplay comparison drives both machines through the same states (MAME
state injection, or a scene with no randomness).

The first attempt at these runs was void: commit `7e42cf0` dropped `rom_req`'s
driver and used `S_FILL2` before declaring it, so the main CPU never fetched.
`-Wno-fatal` / `-Wno-IMPLICIT` hid both; `make lint` in
`sim/rtl/macplus_frames` now fails on undriven, implicit and
used-before-declared signals in `rtl/macplus`.

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

## MP-12 — Savestates: the gate passes with 2 words of ES5506 scan phase (closed, measured)

Design (docs/PLAN.md 2.9, Appendix C as built):
- **68020 park.** `ss_tg68_park.sv` serves the siblings' 68000 monitor from
  an overlay at 0x7F8000, unmapped on this board. It answers the cycles
  `macplus_cpu_bus` captures. Q1 found no `MOVEC` in the code either game
  runs, so VBR stays 0 (the level-7 vector is read at 0x7C) and VBR, CACR,
  SFC and DFC need no saving.
- **Sound.** The 68000 parks through `ss_m68k_park`. Then the ES5506's
  16 MHz enable stops, and once the engine has finished its voice the chip's
  voice rows and globals are read and written through a port added to the
  vendored chip.
- **The image path.** M10K is at 550 / 553, so the image goes through
  existing ports:
  - main RAM through its back door;
  - the video memories as ordinary cycles on the CPU's board bus;
  - the sprite stages through the copy port.
  The engine runs in a handshake mode (`VARLAT=1`) for that.
- **The vblank edge.** IRQ3 and the sprite copy are gated while the engine
  holds the machine. Saves freeze and loads release at a vblank edge, so both
  see the same machine. After a load the sprite extent table is rebuilt from
  the restored `old2`.
- **DDR3.** The engine is `macplus_rom_hw`'s lowest-priority DDR3 client.

The gate (SS-13's method, `sim/rtl/macplus_frames`, `obj_ss`,
`MP_SS=300,60`):
- slot 0 at frame 300 (attract);
- slot 1 60 frames after it resumes;
- load slot 0, then slot 2 60 frames after that resumes.

Slots 1 and 2 are one state reached two ways:

| region | words | differ |
|---|---|---|
| main RAM (incl. both parked stacks' frames) | 65,536 | 0 |
| VRAM, line zoom, layer registers, live sprite RAM, palette | 49,152 | 0 |
| sprites `old`, `old2` | 14,336 | 0 |
| sound RAM | 16,384 | 0 |
| ES5506 voices | 1,024 | 1 |
| ES5506 globals | 32 | 1 |
| scalars, park frames | 256 | 0 |

**Pictures after each resume: identical, 60 / 60.**

The two words are one phase offset. The globals word holds `scan_voice` and
`slot_count`: voice 5 tick 13 against voice 12 tick 3, about 110 ticks of
16 MHz, or 7 µs. The voice word is voice 5's `filtcnt`: that voice was
processed once more on one path. The ES5506 stops only after the sound CPU
reaches an instruction boundary, and that moves by microseconds relative to
the vblank edge. This is the equivalent of the siblings' park-PC floor.

The harness needed one fix: it cleared the request pulse before the clock
edge that should have sampled it, so the first run never saved.

On the board (bitstream md5 `fe3887a4...`; timing met; 35,605 ALMs (85 %),
550 / 553 M10K):
- Alt+F1 saved and the firmware wrote `savestates/Arcade/Macross Plus_1.ss`;
- 10 s later F1 loaded, and the screenshot 1 s after the load is pixel-identical
  to the one 1 s after the save (0 of 92,160 pixels; the scene between them
  differed by 77,313);
- the attract then went on from the restored point.

## MP-13 — D3: the main CPU runs at 33/48, set by MAME state injection (closed, measured)

MP-6's gameplay comparison failed because the two machines drift apart within
a few frames, and because `work` (IRQ3 to the first idle-loop write) measures
where the interrupt lands in the game's logic, not how much logic there is:
light frames are the handler alone (~380 µs), heavy ones the rest of a logic
pass the interrupt cut into.

**The measure: busy time.** Busy is the time per frame outside the idle loop:
the sum of the gaps longer than 5 µs between the loop's writes to F1015A,
which it makes about every 1 µs. A gap still open at vblank is split there.
MAME measures it in `sim/oracle/macplus_inject.lua`, the core with
`macplus_main.dbg_busy` (held through savestates). It is smooth frame to
frame: 5.5-9 ms in play, 634 µs on the static attract screen.

**The comparison: the same state on both machines.**
1. `macplus_inject.lua` plays MAME (`MP_ORACLE=1`, perfect quantum, the play
   script) and dumps its machine at frame_done every 20th frame from 700:
   main RAM, video state and every CPU register.
2. `tools/mk_inject_image.py` makes a savestate slot of each. A core slot
   supplies the sound board, and the 68020's registers go on the stack the
   park monitor pops.
3. The harness (`MP_INJECT`, `obj_ssNN` built at CE NN/48) loads each slot
   and measures the next three frames against MAME's frames F+1..F+3, with
   MAME's inputs, set at vblank.

That is 115 states and 327 frame pairs, with fully busy frames (stage loads)
left out. The second and third frames agree with the first, so the machines
stay together.

**Memory latency matters.** A first set at the frames harness's 3-clock ROM
latency gave 25/48, but the board's program ROM comes through SDRAM. The M3
harness (`macplus_rom_hw`, `sdram.sv`) measures its fill requests at a mean
of 14 clocks (maximum 21), and the runs below use `MP_MLAT=13` to match:

| CE / 48 | core / MAME busy, median | summed | mean abs(r-1) | static screen busy (MAME 634 µs) |
|---|---|---|---|---|
| 29 | 1.046 | 1.026 | 0.063 | 652 µs |
| 31 | 0.997 | 0.957 | 0.070 | 621 µs |
| 32 | 0.969 | 0.896 | 0.113 | |
| **33** | **1.017** | **0.998** | **0.052** | **635 µs** |
| 34 | 1.065 | 1.044 | 0.073 | |
| 35 | 1.118 | 1.085 | 0.126 | 702 µs |
| 36 | 1.184 | 1.163 | 0.175 | 746 µs |

**33/48 is the setting** (`MacPlus.sv`): the static handler within 0.2 %
and gameplay within 2 % (median) / 0.2 % (sum).

The table is not monotonic, and that is real: the static screen, with no
injection involved, shows it, and so does the idle loop's rate (20,020 /
20,985 / 21,863 / 18,869 / 17,369 iterations a frame at 29 / 31 / 33 / 35 / 36;
MAME 20,042). Above about 33/48 each bus access costs more: the
`macplus_cpu_bus` / TG68K handshake loses efficiency when the enable is
dense. 33 is below that knee. (32/48's figures include harness artefacts: a
release racing the vblank sample made some first frames read 0.)

Caveats:
- The oracle is MAME's 68020 timing model, not a measured board.
- The ROM latency is the attract's; busier play adds SDRAM contention.
- The sound board in the injected slots is the core's own, from the attract.

## MP-14 — Lines through exploding sprites: sprite rows were fetched one at a time (fixed)

Reported on the board: enemy sprites showed horizontal lines when they
exploded.

**Cause.** On the board, sprite rows came from SDRAM port 2:
- each 16-byte row as four single-word pair reads, one after another, one
  row at a time;
- at the ~14 clocks a read measured on the port-0 path, about 60 clocks a
  row, or about 50 rows in a 3,125-clock line.

The dense lines need more: in the play capture, 27 of 940 sampled frames have
a line over 45 tile columns (one row fetch each), and the worst has 63
(frames 3845-3850, 3090-3115, 4740: explosions, whose sprites are zoomed).
The line renderer runs out of time and leaves the rest of that line's sprites
out. The reference harnesses served rows pipelined, so M1/M2 never saw it.

**Reproduced.** M1 with `MP_SPR_SERIAL=60`, a board-like fetch, on the ten
heaviest frames:
- 8-32 overrun lines a frame, 228-1,793 wrong pixels each;
- the difference is exactly horizontal line segments through the explosion
  and the player's ship;
- the default pipelined service is exact on the same frames.

**Fix.** `macplus_rom_hw` now reads sprite rows from DDR3, where the image
already holds them, as a fifth DDR3 channel just below BG priority, with up
to 7 rows in flight:
- the 48 MHz request queue is read on clk_ddr through its Gray-coded write
  pointer;
- each row is one 2-beat read into an 8-row return ring, whose Gray-coded
  write pointer crosses back;
- both sides reset on power-on only, so the two rings stay in step;
- the ring is in registers (M10K is at 550 / 553).

SDRAM port 2 is idle now. The boot copy shrinks from 22 MB to the 6 MB that
SDRAM still serves (program, sound program, text).

**Checked:**
- M1 with at most 7 rows in flight (`MP_SPR_DEPTH=7`) at 60 and 100 clocks
  of latency: all heavy frames exact, worst line 1,803 of 3,125 clocks.
- M3 (`MP_PLAY=1`, the real `macplus_rom_hw`, to frame 820): 670,768 sprite
  rows, 0 differ from the image; no sprite or BG overruns.
- Board (`8960a7b6`): 30 s of play with autofire, the six captures with the
  most explosion show solid explosions with no gaps.

MP-8's BG path still crosses one row at a time. It is in time on every M3
frame so far, and the same ring would lift it if a zoomed scene ever
overruns.
