# Arcade-NMKBP964_MiSTer — Project Plan (approved 2026-09-23; implementation under way)

**Macross Plus** (MOSS / Banpresto, 1996) and **Quiz Bishoujo Senshi Sailor
Moon - Chiryoku Tairyoku Toki no Un** (Banpresto, 1997) as a MiSTer FPGA core.
The reference is MAME's `nmk/macrossp.cpp` (driver by **David Haywood** and
**Paul Priest**). Local copy: `~/mame/src/mame/nmk/macrossp.cpp`, 1,170 lines.
It is identical to `master` as of today (`diff` against the raw GitHub file:
no difference).

The method is the one the four previous cores used. The RTL behaves like the
board, and MAME is the behavioural oracle. Verilator harnesses run before any
hardware work, and the DE10-Nano is the final proof. Every claim is closed by
a measurement.

**One `.rbf` — `Arcade-NMKBP964` — one board (BP964A / BP965A), two
parents.**

| set | MAME description | orientation | main program | notes |
|---|---|---|---|---|
| `macrossp` | Macross Plus (1996) | ROT270 | 4 x 512 KB, 32-bit interleave | MACHINE_SUPPORTS_SAVE, no imperfect flags |
| `quizmoon` | Quiz Bishoujo Senshi Sailor Moon (1997) | ROT0 | 4 x 128 KB + 4 x 512 KB | `IMPERFECT_GRAPHICS \| IMPERFECT_SOUND` in MAME |

Both are parents; there are no clones in MAME 0.289.

| | Macross Plus board | for comparison: the previous cores |
|---|---|---|
| main CPU | **MC68EC020 @ 25 MHz**, 32-bit bus | 68000 @ 6-12 MHz (fx68k) |
| sound CPU | 68000 @ **16 MHz** | Z80, 68000 @ 7 MHz, TLCS-90 |
| sound chip | **Ensoniq ES5506 (OTTO)**, 32 voices, sample ROM | YM2151/YM2203 + OKIM6295 |
| layers | **3 x 8 bpp 16x16 tilemaps with per-line X zoom, and a 4 bpp text layer** | 2-3 x 4 bpp, no zoom |
| sprites | **1,024 entries, up to 16x16 tiles each, 8 bpp, X/Y zoom, 50 % alpha** | 128-256, 4 bpp, no zoom |
| palette | 4,096 x RGB888, plus a global fade register | 1,024-2,048 x RGB444/555 |
| ROM total | **47.5 MB (macrossp), 44.8 MB (quizmoon)** | 1-15 MB |

**Prerequisites.**
- **ROMs: present.** `macrossp.zip` and `quizmoon.zip` are in
  `~/Arcade-NMKBP964_MiSTer/mame_roms/`, and `mame -verifyroms` (0.289)
  reports both as good. The directory is gitignored and never committed.
- **The GHDL synthesis toolchain is missing.** TG68K.C (§2.4) is VHDL, and
  Verilator needs a Verilog netlist of it. NMK16's
  `docs/t80-vhdl-toolchain.md` builds GHDL with `--enable-synth` and the
  ghdl-yosys-plugin. That build is no longer on this machine (only Ubuntu's
  GHDL 5.0.1 without synth, and Yosys 0.52). Rebuilding it is an M0 task.

Contents:
- Section 0: the facts that shape the plan.
- Section 1: the hardware as MAME describes it, with source line references.
- Section 2: the architecture and a file-by-file reuse map.
- Section 3: milestones, tasks and gates.
- Section 4: every lesson from the four previous cores, mapped onto this
  board.
- Section 5: the risk register.
- Section 6: open questions, each written as a measurement.
- Section 7: decisions for you before M0.
- Section 8: day one.
- Appendices: the OSD string, the memory maps, the savestate image, the M10K
  budget and the ROM layout.

---

## 0. Facts that shape the plan

1. **Nothing in the video can be adapted; it is all new.** The previous
   cores' tilemaps are 4 bpp 16x16 with 16-bit VRAM, and their sprites are
   unzoomed and 4 bpp. This board has:
   - 8 bpp tiles, 32-bit tile words, 1024x1024-pixel maps and a per-line X
     zoom;
   - 1,024 zoomed sprites with alpha.

   What carries over is the **method and the building blocks**:
   - the one-line-ahead line renderer with a ping-pong buffer (MS1Z-12);
   - direction-aware prefetch (NMK-21b);
   - the ROM caches and SDRAM arbiters (SS-12);
   - RAMs that infer as M10K (NMK-10, SS-14, MS1-37, MS1Z-6);
   - the palette as block RAM with a registered read;
   - `video_retime` / `crt_chain` / screen rotation.
2. **The main CPU is a 68EC020, and no cycle-accurate 68020 core exists.**
   fx68k is 68000-only. The proven MiSTer choice is **TG68K.C** in 68020 mode.
   It is what Minimig AGA uses, and what Arcade-ITech32 ships for Street
   Fighter: The Movie (also a 68EC020 at 25 MHz). Taking ITech32's copy brings
   three things:
   - its local ALU and kernel changes;
   - its bus adapter, which completes odd-address longwords and IACK cycles
     locally;
   - evidence that it runs a 25 MHz 68EC020 game on this FPGA at 47.7 MHz.

   The consequences:
   - TG68K has a **16-bit data bus**, so a 32-bit access is two bus cycles.
   - It is **not cycle-exact** against a 68020, and MAME's m68020 is not
     either. Instruction-for-instruction timing against MAME is therefore
     out of reach.
   - The gate becomes **per-frame CPU work**, which this game exposes
     directly: its idle loop counts at `0xF1015A` (fact 9).
3. **The ROMs do not fit the standard 32 MB SDRAM.** macrossp is
   2 + 1 + 16 + 24 + 0.5 + 4 = **47.5 MB**, and quizmoon is
   **44.8 MB**. MiSTer's answer is DDR3:
   - An `.mra` `<rom ... address="0x30000000">` makes Main_MiSTer write the
     ROM image straight into DDR3 and only toggle `ioctl_download`. ITech32's
     release `.mra` does exactly this; checked in its `releases/`.
   - That avoids a ~60 s `ioctl` stream. NMK-22 measured raphero's 15 MB at
     ~18 s.
   - The plan loads the whole image into DDR3. It then **copies the
     latency-critical regions into SDRAM** at boot: both CPU programs, the
     sprites and the text tiles, 21.5 MB.
   - The three BG layers and the samples are served from DDR3 through
     line-ahead prefetch and the ES5506's own cache (§2.3). This is a
     decision for you (§7 D1).
4. **The game is vertical (ROT270), so the rotation framebuffer is in play,
   and it also lives in DDR3.** `screen_rotate` has **no backpressure**
   (NMK-28). Every DDR3 client of this core must therefore yield to it, and
   the BG and sample paths must meet their deadlines with it running. Its
   base is `0x24000000` (3 x 8 MB, `sys/arcade_video.v:204`). Savestates are
   at `0x3E000000`. The ROM image at `0x30000000-0x33DFFFFF` sits between
   them with no overlap.
5. **The Ensoniq ES5506 is vendored, not written.** It comes from
   `TheJesusFish/Arcade-ITech32_MiSTer` at commit `d461e21d` (2026-09-08),
   `rtl/sound/itech32_es5506.sv` (2,376 lines):
   - It is GPL-3.0-or-later, which is compatible with the GPL-3.0 of all
     four previous cores.
   - Its sample port is **byte-addressed, 2-bit bank, 22-bit address, held
     request/acknowledge**. That is exactly this board's four 4 MB banks.
   - It already contains a per-voice sample cache designed for DDR latency;
     its notes measure a 665-clock DDR tail.
   - Its host port is the ES5506's 8-bit window, which is what the sound
     68000 drives (`umask16(0x00ff)`, `macrossp.cpp:847`).
6. **Sprites are double-buffered twice, like NMK16.** At vblank MAME does
   `old2 <- old <- live` (`macrossp.cpp:752-753`, with the comment "looks
   like sprites are *two* frames ahead, like nmk16") and draws `old2`. So the
   list a frame shows is fixed **a whole frame before it is drawn**. That
   frees the sprite engine to index the list during the previous frame
   (§2.6.3). It is also the lag NMK-1 measured, lag 2, on the NMK16 family.
7. **Sprite composition reduces to "frontmost sprite per pixel, then a
   priority test".** MAME draws the list from the last entry down to entry 0
   (`macrossp.cpp:506-510`) with `prio_zoom_alpha`. That call ORs in the
   implicit bit 31 (`drawgfx.cpp:1474`) and sets the priority byte to 31 on
   every opaque source pixel, even one hidden behind a layer
   (`drawgfxt.ipp:403-414`). Therefore:
   - the **highest index is in front**, first writer wins, exactly as in
     MS1Z-7;
   - a sprite hidden by a layer **still hides the sprites behind it**;
   - alpha only ever blends a sprite with the **layers**, never with another
     sprite.

   A one-line buffer holding `{colour, priority, alpha}` of the frontmost
   sprite reproduces MAME exactly (§2.6.4).
8. **Alpha is a plain average.** `alpha_blend_r32(d, s, 0x80)`
   (`drawgfx.h:506-511`) is `(s*128 + d*128) >> 8` per channel, which is
   `(s + d) >> 1`. It needs no multiplier.
9. **MAME's speedup hides the best CPU gate.** `init_macrossp` installs
   `macrossp_speedup_w` (`macrossp.cpp:1136-1157`). The game's idle loop at
   PC `0x18104` counts `addq.w #1,$F1015A` until vblank changes `$F10140`.
   MAME then `spin_until_interrupt`s, so the counter no longer measures
   spare CPU time. A **MAME patch that disables the speedup** (like MS1Z's
   sound-isolation patch) makes it a per-frame measure of spare CPU time,
   comparable between MAME and the core. MAME also
   `spin_until_time(50 us)`s after every sound command (`:782`), which the
   board does not. The patched oracle removes that too, or the gate records
   it.
10. **MAME is unsure about much of this board, and says so.** Every item
    below is a MAME guess; each gets an open question (§6):
    - zoom enable is `== 0xE` "guess, surely wrong" (`:628`);
    - the undefined colour mode is `rand()` (`:446`, `:560`);
    - the sprite zoom "fudge" of +0x600 (`:601-603`);
    - the 368-pixel zoom centre (`:644`);
    - the unused `vr[1]` (`:403`, `:647-651`);
    - the unmapped "BIOS" ROM (`:11`, `:1056`);
    - the ES5506 IRQ that is never seen (`:979-981`);
    - sound status bit 0 "expected to toggle, vblank?" (`:765`);
    - the fade curve (`:797-801`);
    - `quizmoon`'s wrong title graphics and sound (`:13`);
    - interrupt levels 1 and 2 "unknown" (`:15-22`).
11. **The raster is only half known.** The board notes give **HSync
    15.83 kHz, VSync 60 Hz** (`:234-235`), which is ~264 lines. MAME uses a
    512x256 total at 60 Hz with vblank at the end of the visible area
    (`:1008-1011`).
    - Hypothesis: the dot clock is **27 MHz / 4 = 6.75 MHz**. With an
      HTOTAL of 426 that gives 15.845 kHz; the 27 MHz crystal has no other
      stated use. This is Q4.
    - As in MS1Z: the simulations run MAME's 512x256 raster for gate
      equality, and the core ships the board's.
12. **Two games, one board, two differences in the machine config:**
    - quizmoon's visible area is 224 lines, not 240 (`:1035`);
    - it adds ES5506 banks 2 and 3 (`:1037-1039`).

    Everything else is shared. The `.mra`'s game-mode byte selects them, as
    in MS1BCD (MS1-53: the core must not run before the switches arrive).

---

## 1. The hardware, from the driver

### 1.1 CPUs and clocks (`macrossp.cpp:996-1030`, PCB notes `:230-235`)

| part | clock | source |
|---|---|---|
| MC68EC020 (main) | 25 MHz | 50 MHz / 2 |
| TMP68HC000 (sound) | 16 MHz | 32 MHz / 2 |
| ES5506 | 16 MHz | 32 MHz / 2 |
| video (IKM-AA004 / AA0062 / 2 x AA005) | unknown | 27 MHz crystal, presumably (Q4) |

Other facts:
- The 68EC020 has a 24-bit address bus (hence "EC") and a 256-byte
  instruction cache. MAME models neither the cache timing nor wait states.
- Main RAM is MCM6206 25 ns SRAM (zero wait states at 25 MHz, presumably).
- The program ROMs are 27C040 EPROMs (wait states on the board, presumably;
  Q6).

### 1.2 Main CPU memory map (`main_map`, `:807-841`), 32-bit bus

| range | what | notes |
|---|---|---|
| `000000-3FFFFF` | program ROM | macrossp fills 0-1FFFFF; quizmoon 0-7FFFF and 200000-3FFFFF |
| `800000-802FFF` | sprite RAM, 12 KB | 1,024 entries of 3 longwords |
| `900000-903FFF` | SCR A VRAM, 4,096 longwords | 64x64 map |
| `904200-9043FF` | SCR A line zoom, 128 longwords = 256 halfwords | one halfword per line |
| `905000-90500B` | SCR A registers, 3 longwords | |
| `908000-90BFFF`, `90C200-90C3FF`, `90D000-90D00B` | SCR B, same shape | |
| `910000-913FFF`, `914200-9143FF`, `915000-91500B` | SCR C, same shape | |
| `918000-91BFFF`, `91C200-91C3FF`, `91D000-91D00B` | text layer, same shape | line zoom and registers unused by MAME's draw |
| `A00000-A03FFF` | palette, 4,096 x 32-bit, `RGBx_888` | read/write |
| `B00000-B00003` | INPUTS (32-bit) | |
| `B00004-B00007` | sound status (read); write ignored | bit 1 pending, bit 0 toggles per read |
| `B00008-B0000B` | write ignored ("irq related?") | |
| `B0000C-B0000F` | DSW (read); write ignored | DIPs in bits 31-16, bits 15-0 read `FFFF` |
| `B00012-B00013` | palette fade (16-bit write, high byte) | `:794-803` |
| `B00020-B00023` | write ignored | |
| `C00000-C00003` | sound command; only the **upper halfword** acts | `:775` `ACCESSING_BITS_16_31` |
| `F00000-F1FFFF` | main RAM, 128 KB | the speedup hook sits at `F10158` |

Unmapped reads are a question for the oracle (Q13), as in MS1Z.

### 1.3 Interrupts (`:15-22`, `:1001`)

- **Only IRQ3 is generated**, at vblank start (`set_vblank_int`,
  `irq3_line_hold`). HOLD_LINE means it is held until the CPU acknowledges
  it. MS1-23 applies: one IACK cycle retires one interrupt.
- The vector table has live handlers for levels 1 and 2
  (`0x84C`, `0x882`). Nothing in MAME raises them. On the board they could be
  raster or sound-status interrupts (Q5).
- Sound CPU: **IRQ2 on every sound-command write** (HOLD_LINE, `:780`). The
  ES5506 IRQ is wired to levels 1 and 4 "definitely", but MAME never sees it
  asserted, and its handler only logs (`:979-981`).

### 1.4 Sound board (`sound_map`, `:843-859`; config `:1019-1039`)

| range (68000) | what |
|---|---|
| `000000-0FFFFF` | program ROM, 1 MB (macrossp fills it; quizmoon uses 256 KB) |
| `200000-207FFF` | RAM, 32 KB |
| `400000-40007F` | ES5506, on the **low byte** of each word: register = `(A >> 1) & 0x3F` |
| `600000-600001` | sound latch read (16-bit); clears the pending bit |

- The latch is 16-bit (`generic_latch_16`). The main CPU writes it; the sound
  CPU reads it. `sndpending` is set on write and cleared on read. The main
  CPU sees it as bit 1 of `B00004`.
- **ES5506 banks** (the sample address space is 21-bit, in 16-bit words):

  | bank | macrossp | quizmoon |
  |---|---|---|
  | 0 | `ensoniq.0` words 0-2M | `ensoniq.0` words 0-2M |
  | 1 | `ensoniq.0` words 2M-4M | `ensoniq.0` words 2M-4M |
  | 2 | unmapped | `ensoniq.2` words 0-2M |
  | 3 | unmapped | `ensoniq.2` words 2M-4M |

- **Sample format trap.** macrossp loads `bp964a.u24` with
  `ROM_LOAD16_BYTE` into an 8 MB `ROMREGION16_BE ... ROMREGION_ERASEFF`
  (`:1080-1081`). Every sample word is therefore `(byte << 8) | 0xFF`, so the
  low byte is **0xFF, not 0x00**. quizmoon's two ROMs per region fill both
  bytes (`:1125-1131`). The load path, or the wiring in front of the ES5506,
  must reproduce the `0xFF`. ITech32's notes put "narrow-ROM padding" at the
  wiring boundary.
- The output is `set_channels(1)`: one stereo channel pair, routed with a gain
  of **1.6** to each side (`:1026-1029`). The board has a uPD6376 16-bit DAC.

### 1.5 Video (`:391-755`)

**Screen (MAME).** The total is 512x256 at 60 Hz, vblank time 0. The visible
area is 384x240 (macrossp) or 384x224 (quizmoon). The board's raster is §0
fact 11.

**SCR A, B, C** (`:418-451`, `:622-664`):
- 64x64 tiles of 16x16 at 8 bpp, which is 1024x1024 pixels. Pen 0 is
  transparent.
- Tile word: `tileno = attr[15:0]`, `flip = attr[31:30]` (Y in 31, X in 30).
- Colour depends on `vr[0][11:10]`:
  - mode `10` (`0x800`): `col = attr[19:17] << 2`, that is 256-colour banks;
  - mode `01` (`0x400`): `col = attr[21:17]`, that is 64-colour banks;
  - anything else: `rand()`.
- Pen = `0x800 + 64*col + pixel`. The `granularity(64)` is set at `:491-494`,
  so an 8-bit pixel indexes up to 255 above a 64-aligned base. The sum can
  exceed 0xFFF (Q9).
- Tile codes wrap: `code %= elements()`. macrossp has 32,768 tiles per
  layer; quizmoon has 16,384 / 16,384 / 8,192 (NMK-25: use a true modulo).
- `vr[0]`:
  - `[9:0]` scroll X;
  - `[25:16]` scroll Y;
  - `[11:10]` colour mode;
  - `[15:14]` priority 0-3;
  - `[31:28]` "always 9", unused by MAME.
- `vr[2]`:
  - `[31:28] == 0xE` turns on zoom (MAME's guess);
  - `[24:16]` is `incy`, where `0x40` = 1:1.
- **Zoom** (`draw_roz`, wraparound on, `:628-657`):

  ```
  incx   = (line even ? lr[line/2][31:16] : lr[line/2][15:0]) << 10
  incy   = vr[2][24:16] << 10
  startx = (vr[0][9:0]   << 16) - 184 * (incx - 0x10000)
  starty = (vr[0][25:16] << 16) - 120 * (incy - 0x10000)
  source(x, y) = ((startx + x*incx) >> 16 & 1023, (starty + y*incy) >> 16 & 1023)
  ```

  This is `tilemap.cpp:1442-1520`: `startx += left*incxx`,
  `starty += top*incyy`, and a wraparound fetch per pixel with
  `(c >> 16) & mask`. Because MAME draws each line with a one-line cliprect,
  `incx` is **per line** and `incy` is per frame.
- Not zoomed: plain scroll, with `set_scrollx` / `set_scrolly` from
  `vr[0]`.

**Text layer** (`:453-469`):
- 64x64 of 16x16, **4 bpp packed MSB-first**, pen 0 transparent.
- `tileno = [15:0]`, `colour = [23:17]` (128 banks of 16), base `0x800`.
  There is no flip.
- It is drawn with **no scroll** (MAME never reads the text registers) and
  priority value 8.
- quizmoon has no text ROM; its region is `ERASE00`.

**Layer composition** (`:666-727`):
- `bitmap = black`, `priority = 0`.
- For pri = 0..3, for each line, for layer = 2, 1, 0: if `layerpri[layer]`
  is pri, draw it (opaque pixels overwrite) and OR `1 << pri` into the
  priority byte.
- Then the text is drawn over everything with priority value 8.
- So the colour on screen is the topmost opaque pixel of: the text; then the
  layers sorted by (priority descending, index ascending). Within equal
  priority, layer 0 is on top ("quizmoon map requires...", `:711`).
- The priority byte is the **OR of every opaque layer's `1 << pri`**, plus
  bit 3 for opaque text.

**Sprites** (`:502-619`). Each entry is 3 longwords, and the list is read
backwards from entry 1023:

```
w0: --hh hhyy yyyy yyyy  CCww wwxx xxxx xxxx
     high[29:26] y[25:16]  colmode[15:14] wide[13:10] x[9:0]
w1: ---- --zz zzzz zzzz  ---- --ZZ ZZZZ ZZZZ     yzoom[25:16] xzoom[9:0], 0x100 = 1.0
w2: fFa- pp-- cccc c---  tttt tttt tttt tttt     flipy[31] flipx[30] alpha[29] pri[27:26] col tile[15:0]
```

- **Colour:**
  - mode `10`: `col = w2[21:19] << 2`;
  - mode `01`: `col = w2[23:19]`;
  - else `rand()`.
  - Pen = `64*(col % 32) + pixel`, from sprite base 0.
- **Position:** x and y are sign-folded (`> 0x1FF` → `- 0x400`).
- **Size:** `(wide+1) x (high+1)` tiles, numbered `tile + loopno` in row
  order. Flip reverses the iteration order and starts the offsets at
  `wide*xzoom*16`.
- **Zoom:** `scalex = xzoom << 8`, plus `0x600` if `xzoom < 0x100`; the same
  for Y. Tile *i* is placed at `xpos + ((i*xzoom*16) >> 8)` (with the flipped
  variant).
- Each tile is drawn by `drawgfxzoom_core` (`drawgfxt.ipp:738-850`):

  ```
  dstw = (scalex*16 + 0x8000) >> 16    (skip if < 1)
  dx   = (16 << 16) / dstw
  srcx starts at 0 (clipped: (left-destx)*dx), flip: (dstw-1)*dx - srcx, dx = -dx
  pixel at dest x uses src column (srcx + k*dx) >> 16; rows likewise with dy
  ```

  A scale of exactly `0x10000` in both axes takes the unzoomed
  `prio_alpha` / `prio_transpen` path, which gives identical pixels.
- **Priority mask:** sprite pri `p` is hidden where the priority byte has any
  bit `b >= p` among bits 0-3. Text (bit 3) therefore hides every sprite.
- **Alpha:** `w2[29]` gives level `0x80`, else `0xFF` (opaque).
- **The pri-31 claim is unconditional** (§0 fact 7).

**Palette and fade** (`:794-803`, `:1016`):
- 4,096 entries of `RGBx_888`: R = `[31:24]`, G = `[23:16]`, B = `[15:8]`.
- The fade register is the high byte `d` of a 16-bit write to `B00012`. It is
  ignored when `d == 0xFF`. Otherwise
  `fade = u8(((d - 40) / 212.0) * 255.0)` and
  `screen brightness = 255 - fade`.
- MAME applies screen brightness **in the renderer**, not in the bitmap, so
  `screen:pixels()` may well not include it (Q10). The oracle records `d`
  per frame whatever the answer.

### 1.6 Inputs and DIPs (`:863-961`)

- `INPUTS` (active low):
  - `[0]` Start 1, `[1]` Start 2, `[2]` Coin 1, `[3]` Coin 2, `[5]` Service 1;
  - `[23:16]` P1 up/down/left/right + buttons 1-4;
  - `[31:24]` the same for P2.
- quizmoon adds a Test DIP at `[4]` and Tilt at `[6]`.
- `DSW[31:16]`:
  - SW1: Coin A `[19:16]`, Coin B `[23:20]`;
  - SW2: Difficulty `[25:24]`, Lives `[27:26]`, Demo Sounds `[28]`,
    Flip Screen `[29]`, Language `[30]` (MAME default English; unused on
    quizmoon), Service `[31]`.
- **Flip Screen is a DIP the game reads.** MAME's video has no flip at all,
  and the MACHINE_NO_COCKTAIL flag is set. What the game does with the DIP is
  Q7. The OSD Flip in the core is rot180 of the finished frame, as on every
  previous core (NMK-21, MS1-13).

### 1.7 ROMs (`:1045-1132`), sizes in bytes

| region | macrossp | quizmoon | layout |
|---|---|---|---|
| maincpu (4 MB) | u1-u4, 4 x 512 KB `LOAD32_BYTE` (u4 = byte 0, MSB) | u1-u4 4 x 128 KB at 0; u5-u8 4 x 512 KB at 0x200000 | big-endian 32-bit |
| audiocpu (1 MB) | u20 (odd), u21 (even), 2 x 512 KB | u20/u21, 2 x 128 KB | `LOAD16_BYTE` |
| user1 "BIOS" (128 KB) | u49 | u49 | **not mapped by MAME** |
| sprites (16 MB) | u9-u12, 4 x 4 MB `LOAD32_BYTE` | same | raw 16x16x8, 256 bytes/tile |
| bgtiles0/1/2 | 8 MB each (u13+u14, u15+u16, u17+u18) | 4 MB, 4 MB, 2 MB | raw 16x16x8 |
| fgtiles (4 MB region) | u19, 512 KB | none (`ERASE00`) | 16x16x4 packed, 128 bytes/tile |
| ensoniq.0 (8 MB) | u24, 4 MB `LOAD16_BYTE` at 0, `ERASEFF` | u26 (even) + u24 (odd) | 16-bit BE |
| ensoniq.2 (8 MB) | -- | u27 (even) + u25 (odd) | 16-bit BE |
| plds | 3 x GAL16V8 | -- | not used |

The `LOAD32_BYTE` order is the MS1-49 trap in 32-bit form: u4 is the most
significant byte, at offset 0. It is verified in M0 against MAME's
`memory` dump of the first 256 bytes.

### 1.8 What the driver does not tell us

This consolidates §0 fact 10 into a list the oracle can check, one item per
question in §6:
- zoom enable;
- the colour-mode `rand()`;
- the zoom fudge;
- `vr[1]`;
- the 368 centre;
- the BIOS ROM;
- IRQ 1 and 2;
- the ES5506 IRQ;
- the status toggle;
- the fade curve;
- the raster;
- CPU wait states;
- the unmapped read values;
- the flip DIP;
- the text layer's registers and line-zoom RAM (written, never read);
- the palette index overflow above 0xFFF.

---

## 2. Architecture and reuse

### 2.1 Block diagram

```
                +-----------------------------+      DDR3 (HPS, 64-bit)
 HPS / .mra --> | ROM image @ 0x3000_0000     |<---- screen_rotate FB @ 0x2400_0000 (priority)
 address=0x30.. | copier -> SDRAM (boot only) |<---- savestate slots @ 0x3E00_0000
                +-------------+---------------+
                              | BG0-2 line prefetch, ES5506 sample fills
   SDRAM (96 MHz, 4 ports)    |
   main prog | sound prog | sprites | text tiles
       |           |          |          |
   TG68K 020   fx68k 16 MHz  sprite     text
   @25 MHz ce  + latch       line eng.  line eng.
       |        + ES5506        |          |
   main bus: RAM 128K, VRAM x4, spriteram + old + old2, palette, I/O
                              |
              compositor: layers -> text -> sprite pri/alpha -> palette -> fade
                              |
         video_retime -> crt_chain -> sys/ (scaler, rotation, HQ2x, OSD)
```

### 2.2 Clocks

- **`clk_sys` = 48 MHz**, as in every previous core:
  - It gives the ES5506's `ce_16m` exactly (1 in 3).
  - It gives the sound 68000's fx68k phase enables at 32 MHz as 2 of every
    3 clocks. fx68k needs strict phi1/phi2 alternation, not an even spacing.
    NMK-24 is the proof that masking the phases independently breaks it.
  - TG68K closes timing at 47.7 MHz in ITech32.
- **The 68EC020's 25 MHz** is a fractional clock enable (25/48). Its
  accumulator is checked for width (MS1-28). The rate is a **calibration
  point, not a constant**: M2's CPU-work gate decides whether TG68K needs
  more or fewer enables than 25 MHz to do a real 68EC020's work per frame
  (§7 D3).
- **`clk_ram` = 96 MHz** for the SDRAM, with the existing toggle handshake
  (NMK16's `sdram.sv`, SS-12).
- **DDR3** runs through `sys/`'s `DDRAM_*` on `clk_sys`, as ITech32 does.
- **Video:** `ce_pix` from `clk_sys`. For simulation gates it is MAME's
  512x256. For the shipped core it is the board's raster (Q4; a
  parameterised HTOTAL/VTOTAL as in MS1Z).

### 2.3 Memory architecture

**Load.** The `.mra` names one `<rom index="0" address="0x30000000">`
containing every region at a **fixed offset** (Appendix D, built as in Appendix E), padded with
`<part repeat>` so both games share the layout. `index 1` carries the
game-mode `<switches>`-independent data (none so far). Cheats and hiscore use
their usual indices.

**Copier.** A boot-time DDR3-to-SDRAM copier (`macplus_copier.sv`) moves:

| region | bytes | SDRAM port |
|---|---|---|
| main program | 4 MB (whole region; quizmoon's hole included) | 0 |
| sound program | 1 MB | 1 |
| sprites | 16 MB | 2 |
| text tiles | 512 KB | 3 |

That is 21.5 MB. At DDR3 burst rate against the SDRAM's write rate it
should take well under a second; measured in M3. Both CPUs stay in reset
until the copier reports done (the SS-15 lesson: the download handshake must
survive every reset the framework raises).

**DDR3 clients**, in priority order:
1. `screen_rotate` writes. They have no backpressure, so they always win.
2. BG0-2 tile rows, prefetched one line ahead: 16-byte runs, 2 qwords each.
3. ES5506 sample fills, from its own cache with an urgent path.
4. The savestate engine (existing, yields to rotation, NMK-32).
5. The copier (boot only).

**Bandwidth budget.** To be measured, not assumed; these are the planning
numbers. A line is 63.2 us at 15.83 kHz, or 3,034 clocks at 48 MHz.
- **Unzoomed BG:** 3 layers x 25 tile rows = 75 requests of 2 qwords per
  line. At a pessimistic 200 ns each, serialised, that is 15 us, or 24 % of a
  line.
- **Zoomed BG is the unknown.** At `incx` = 2.0, each layer needs about 48
  tile rows per line. Beyond about 16x, every pixel is a new tile row:
  1,152 requests per line, which does **not** fit. Q8 measures the zoom
  range the games actually use, from MAME taps on the line-zoom RAM. The
  fallback is a per-layer tile-row cache.
- **Samples:** ITech32's measured budget holds at 31 kHz output with up to 32
  voices.
- **Rotation writes:** 384 x 240 x 60 x 2 bytes = 11 MB/s.

**The alternative (§7 D1)** is to require a **64 MB or larger SDRAM** and put
everything except the samples in SDRAM. That is simpler, and fatal for
32 MB owners.

### 2.4 The main board — `macplus_main.sv`

1. **CPU.** ITech32's `itech32_tg68_cpu.sv` and
   `itech32_tg68_bus_adapter.sv`, renamed `macplus_tg68_*`, with ITech32's
   TG68K.C copy (`rtl/cpu/tg68k/`, commit `ade33e39` plus ITech32's
   documented ALU/kernel changes):
   - `CPU = 2'b11` (68020).
   - The adapter completes the IACK cycle locally with an autovector, and
     splits longwords into two 16-bit cycles.
   - **M0 checks that the TG68K subset covers every instruction the two
     programs execute** (Q1): an opcode histogram from a MAME trace, against
     TG68K's decode.
2. **Bus.** A 24-bit address, 32-bit data, byte enables. Decode per §1.2.
   Wait states come from the ROM cache's ready, and are 0 for RAM, VRAM and
   I/O (Q6 for the board's real numbers).
3. **Program ROM.** From SDRAM through a 16-bit, 2-way ROM cache (NMK16/MS1
   `rom_cache_n` lineage, sized in M3). The cache sees a **held address**
   when the CPU is not selecting ROM (MS1-50, SS-12 #2).
4. **Main RAM.** 128 KB as four 8-bit lane arrays in Quartus's true-dual-port
   template (NMK-10, MS1Z-6). Port B serves hiscore, cheats and savestate.
5. **VRAM x4.** 16 KB each, 32-bit. Port A is the CPU; port B is the video
   prefetch. Line-zoom RAMs are 512 B each. The registers are flops, since
   the video reads them every line.
6. **Sprite RAM.**
   - The live 12 KB array takes CPU writes.
   - `old` and `old2` are two 12 KB copies. A vblank copy engine moves
     3,072 longwords twice, within vblank (Q3 for the exact instant).
   - The sprite engine reads only `old2`, through a second port.
7. **Palette.** 4,096 x 24 bits in M10K. The CPU reads and writes the full 32
   bits (the low byte is kept, since the CPU reads back what it wrote; Q13);
   the video has a registered read.
8. **I/O.**
   - The INPUTS and DSW words.
   - The sound status: bit 1 `sndpending`; bit 0 toggles per read, as MAME
     does, while Q11 is open.
   - The fade register.
   - The sound command: writing the upper halfword latches the 16-bit value,
     sets pending and raises sound IRQ2. There is **no main-CPU stall**.
9. **Interrupts.** IRQ3 at vblank start, held until acknowledged; one IACK
   retires one interrupt (MS1-23). Levels 1 and 2 are wired to nothing until
   Q5 says otherwise.

### 2.5 The sound board — `macplus_sound.sv`

1. **CPU.** fx68k at 16 MHz, program from SDRAM through `rom_cache_n` (1 MB),
   RAM 32 KB in M10K. The pause gating keeps phase alternation (NMK-24).
2. **Latch.** 16-bit, `sndpending` as in §1.4. IRQ2 is HOLD_LINE, cleared by
   its IACK.
3. **ES5506.** `itech32_es5506.sv` vendored verbatim into
   `rtl/third_party/es5506/` with its license, CREDITS entry and `deps.lock`
   pin.
   - Host: `host_addr = A[6:1]`, `host_wdata = D[7:0]`, DTACK from
     `host_ack`.
   - Samples: `sample_bank` and `sample_addr` map to DDR3 per Appendix D, and
     empty banks return zero without traffic. macrossp's padding is applied
     here: `{byte, 8'hFF}` from a 4 MB byte image, so the DDR image stores
     4 MB, not 8.
   - PAR comparator tied inactive, as ITech32 does.
   - **IRQ wired to sound IRQ 1 and 4, and measured** (Q12). MAME never sees
     it. If the core's ES5506 does assert it, the game's handler runs where
     MAME's does not. Recorded either way.
4. **Output.** Channel 0, stereo, 20-bit. MAME routes it with a gain of 1.6.
   ITech32 normalises the full 20-bit range to 16 bits and warns that
   applying gain first clips valid output. Here the level is **measured
   against MAME in dB** (MS1Z-13 method), and the gain is chosen from the
   measurement with a saturating stage, never assumed.
5. **Savestate.** The ES5506 needs its voice RAM and global registers saved.
   Two ways:
   - (a) a savestate port added to the vendored module (a documented local
     patch, like `sdram.sv` / `hiscore`), which dumps and restores its
     `voice_state` row RAMs and globals;
   - (b) reading every voice register through the host port.

   (b) has side effects (reading IRQV clears the IRQ) and costs 32 x pages of
   host cycles, so the plan is **(a)**. The sample cache is not saved; its
   valid bits reset. MS1-61 and MS1-62 apply as principles: capture from the
   real state, never freeze a clock the restore depends on, and release
   cleanly.

### 2.6 Video

#### 2.6.1 Raster and timing — `macplus_timing.sv`

A parameterised HTOTAL/VTOTAL/visible area, as MS1Z's `ms1z_core.sv`. It has:
- a sim mode of 512x256 (MAME);
- a ship mode from Q4;
- a 224-line visible area for quizmoon.

`hcount`/`vcount` are aligned to the RGB pipeline latency (MS1-59).

#### 2.6.2 BG layers — `macplus_bgline.sv`, three instances

One line ahead, into a ping-pong line buffer of `{pen[11:0], opaque}` x 512.
For the next line:
- **Unzoomed:** `y_src = (vcount + scrolly) & 1023`, and 25 tile words from
  VRAM, each tile row a 16-byte fetch. The ROM data comes from the DDR3
  prefetch queue, and the buffer is written as the bytes arrive.
- **Zoomed:** `cx = startx`, `cy = starty + y*incy`, both 32-bit
  accumulators per §1.5, with `incx` read from the line-zoom RAM for that
  line. Per output pixel: `tile = map[cy>>20][cx>>20]` (from `>> 16` and
  `/ 16`) and `pixel = row[(cx >> 16) & 15]`. A small tile-row cache
  (8-16 entries) absorbs repeats. Its miss rate against Q8's measured zoom
  range is an M1 gate.
- Tile flip X/Y is applied at the fetch. The colour mode comes from `vr[0]`.
- The `rand()` modes (Q2) output colour 0 and are counted by a debug counter.
- A priority field from `vr[0][15:14]`.
- The prefetch direction is flip-aware from the start. NMK-21b was exactly
  this bug, and OSD flip here is a readout mirror, so the line engine never
  flips.

#### 2.6.3 Sprite indexing — `macplus_sprindex.sv`

Because the displayed list (`old2`) is fixed a frame ahead (§0 fact 6), during
frame N the indexer walks the list that frame N+1 will show:
- 1,024 entries, 2 words each, roughly 2,048 clocks;
- for each, it computes the vertical extent: `ypos` to
  `ypos + ((high*yzoom*16) >> 8) + dsth(last row)`;
- it sets that entry's bit in each 16-line band it touches. There are 16
  bands of 1,024 bits, 16 Kbit in two M10K, double-buffered.

The line renderer then scans only the entries flagged in the current line's
band, highest index first. This removes the 1,024-entry scan per line that
would otherwise eat a third of the line budget.

#### 2.6.4 Sprite line renderer — `macplus_sprline.sv`

The MS1Z-12 structure, extended. For line L:
- Walk the band's set bits from index 1023 down.
- For each hit, compute the tile row, `srcy`, and the destination runs of
  each tile column, per §1.5's exact arithmetic. Integer division is a
  64-entry `dx = 0x100000 / dstw` table, since `dstw` is 1..64.
- Write pixels **first-writer-wins** into `{pen[11:0], pri[1:0], alpha, valid}`
  of the back half of a ping-pong buffer.
- The pri-31 claim is honoured by marking `valid` whether or not the sprite
  is hidden. Visibility is decided at composition time.
- ROM reads come from the SDRAM sprite port: 8 bpp, so a 16-bit word is 2
  pixels, and the burst is a tile row of 16 bytes.
- Tile codes wrap `% 65536` (NMK-25).
- Budget counters from MS1Z are carried: `dbg_overruns`, `dbg_max_hits`,
  `dbg_max_cycles`.
- **The fill budget is the design risk** (R3). About 2,800 pixels per line
  at 1 pixel per clock is roughly 7x overdraw. Q3 measures MAME's worst
  line; the fallback is a DDR3 sprite framebuffer drawn over the whole frame.

#### 2.6.5 Text — `macplus_txtline.sv`

The unzoomed BG engine, 4 bpp, no scroll (Q14: are the text registers really
unused?), from SDRAM. Its prefetch needs 25 x 8 bytes per line.

#### 2.6.6 Compositor — `macplus_mix.sv`

Per pixel:

```
layer_col, layer_bits = top opaque of (text; layers by pri desc, index asc); bits = OR of opaque layers' 1<<pri, | 8 if text opaque
sprite shown     = spr.valid & ~|(layer_bits[3:0] >> spr.pri)     -- any bit b >= pri
out_idx / rgb    = text ? text : shown ? (spr.alpha ? avg(rgb(layer), rgb(spr)) : rgb(spr)) : rgb(layer)
background       = black (bitmap.fill(black_pen)), not palette 0
```

The palette read comes first, because alpha averages RGB, not indices. That
means two palette reads per pixel (layer and sprite), so the palette has two
read ports, or a duplicated copy (six more M10K). The fade is applied last:
three 8x8 multiplies, with the exact integer form of MAME's brightness
decided by Q10. Screen flip is rot180 of the finished frame, applied at the
readout (NMK-21 / MS1-13).

### 2.7 Repository layout (as the siblings)

```
MacPlus.sv  JalecoMS1Z-style top: hps_io, CONF_STR, reset, DDR/SDRAM mux, features
rtl/macplus/     macplus_core, _main, _sound, _timing, _bgline, _txtline, _sprindex,
                 _sprline, _mix, _copier, _rom_hw, _ddr_arb, macplus_rom_map.vh
rtl/savestate/   savestate.sv, savestate_ui.sv (F1 F5 F3 F4), ss_m68k_park.sv (sound),
                 ss_m68020_park.sv (new)
rtl/third_party/ tg68k/ (from ITech32), es5506/ (from ITech32), fx68k/, hiscore/, crt_adjust/
rtl/third_party_gen/tg68k/   generated Verilog for Verilator (NMK16 T80 method)
rtl/  sdram.sv sdram_arb.sv sdram_req.sv rom_cache_n.sv video_retime.sv crt_chain.sv cheats.sv
sys/             Template_MiSTer at the siblings' pin
sim/rtl/         video_state/ (M1), macplus_frames/ (M2), macplus_snd/ (sound), macplus_hw/ (M3)
sim/oracle/      macplus_capture.lua, traces/ (gitignored)
tools/           romdata, mk_images, gen_macplus_mra, gen_hiscore_mra, gen_cheats_mra,
                 gen_autofire_mra, frame_compare, mk_video_state, board/ (mr, mrcp, build.sh)
mame-patches/    macrossp-no-speedup.patch (+ README)
docs/            PLAN, known-issues (MP-n), provenance, hw-bringup, README
```

### 2.8 Reuse map

| file | from | how |
|---|---|---|
| `sys/` | Template_MiSTer `3ea1134c` (all siblings) | verbatim |
| `rtl/sdram.sv`, `sdram_arb.sv`, `sdram_req.sv` | MS1Z | verbatim (MODIFIED upstream copy, as recorded in their `deps.lock`) |
| `rtl/rom_cache_n.sv`, `rom_cache1.sv` | MS1Z | verbatim; a 32-bit-aware wrapper for the TG68K side if needed |
| `rtl/video_retime.sv`, `crt_chain.sv`, `third_party/crt_adjust` | MS1Z | verbatim |
| `rtl/cheats.sv` | MS1Z (ACTS=3, masked kind) | extended for conditions if Q16 needs them |
| `rtl/third_party/hiscore` | MS1Z (validating, M10K-inferring copy) | verbatim |
| `rtl/savestate/savestate.sv`, `savestate_ui.sv` | MS1Z | verbatim |
| `rtl/savestate/ss_m68k_park.sv` | MS1Z | verbatim, sound 68000 |
| `rtl/savestate/ss_m68020_park.sv` | new, from `ss_m68k_park.sv` | 68020 frames, VBR, ISP/MSP/USP, CACR (§2.9) |
| `rtl/third_party/fx68k` | MS1Z pin `0602ee46` | verbatim |
| `rtl/third_party/tg68k` | ITech32 `d461e21d` (TG68K.C `ade33e39` + local changes) | verbatim, LGPL-3.0 text carried |
| `rtl/macplus/macplus_tg68_cpu.sv`, `_bus_adapter.sv` | ITech32 `itech32_tg68_*` | renamed; GPL-2.0-or-later headers kept |
| `rtl/third_party/es5506` | ITech32 `itech32_es5506.sv` (+ `_par*.sv` if referenced) | verbatim, plus a savestate-port patch kept as a `.patch` |
| `MacPlus.sv` | `MS1Z.sv` | derived: CONF_STR, DDR mux, copier, features |
| `rtl/macplus/macplus_sprline.sv` | `ms1z_sprline.sv` | derived: zoom, alpha, bands, 8 bpp |
| `macplus_rom_hw.sv` | `ms1z_rom_hw.sv` | derived: SDRAM regions after the copier |
| `macplus_ddr_arb.sv` | new, patterned on ITech32's `itech32_ddr_memory.sv` | rotation priority, BG queue, sample, savestate, copier |
| everything else in `rtl/macplus/` | new | |
| `tools/*` | MS1Z generators and compare tools | derived |
| `tools/board/*` | the scratch `mr`, `mrcp`, `build_z.sh`, `mister_keys.py` | committed without the password (4.G) |
| `sim/oracle/macplus_capture.lua` | MS1Z `ms1_capture.lua` | derived (§3 M1) |

### 2.9 Savestates

The engine is unchanged: four slots at `0x3E000000`, park at the vblank edge,
F1 F5 F3 F4 with Alt to save (NMK-34). What is new:

- **68020 park.** A level-7 interrupt into a monitor overlay. The monitor
  must be written for the 68020:
  - `MOVEC` to save VBR, CACR, SFC, DFC, USP and MSP/ISP;
  - format-0 stack frames on RTE.

  The overlay must also answer the **vector fetch at `VBR + 0x7C`**. If the
  game moves VBR (Q15), the overlay follows it.

  TG68K's 68020 exception frames and MOVEC coverage are checked in M0 (Q1).
- **The sound 68000** parks through the existing `ss_m68k_park.sv`.
- **The ES5506** saves and restores through its port (§2.5 item 5).
- **Sprite buffers.** `old` and `old2` are saved. That is cheaper than
  NMK-32's two-extra-frames hold, and exact.
- **The image**, Appendix C: about 0x47200 bytes, so the slot is 0x80000.
- **The gate is SS-13's three-save diff**, word for word, per region. The
  sound harness runs the savestate sequence itself (the MS1BCD lesson: a
  sound bug needs the sound harness).

### 2.10 Feature parity with the siblings

| feature | plan | notes |
|---|---|---|
| DIPs in the OSD | `DIP;` from `.mra` (gen from `mame -listxml`) | Language, Flip DIP as the game reads them |
| Service | F2 = Service 1 (INPUTS[5]); the Test DIP via the OSD | NMK-34: savestate slot 2 on F5 |
| Pause | gates TG68K ce, fx68k phases (NMK-24), ES5506 ce, mutes audio | |
| Savestates | 4 slots, §2.9 | |
| High scores | macrossp: `maincpu,program,f16ddc,5e,00,14` (hiscore.dat); quizmoon: no entry | byte lanes of the 32-bit RAM (MS1Z `gen_hiscore_mra.py` base handling) |
| Cheats | macrossp 15, quizmoon 12 (Pugsy 0.279 XML, all `maincpu.pb@` byte writes) | parameter and condition cheats (Q16) |
| Autofire | macrossp (a shooter), OSD-unlocked by the `.mra` bit, `autofire_releases/` | quizmoon: none |
| Orientation | `vertical (ccw)` in the `.mra` (NMK-35: text, not a number); OSD Horz/Vert 90/Vert 270 | scandoubler off while rotating (NMK-28) |
| Flip screen | OSD rot180 of the finished frame, all outputs | |
| CRT Adjust | `crt_chain` as the siblings | |
| Scandoubler / HQ2x / aspect | as the siblings | |
| Keyboard | MAME keys | |
| Buttons | macrossp: the number actually used (Q17); quizmoon: 4 answer buttons | `.mra` `<buttons>` matches `J1` positionally |

### 2.11 Tools, `.mra`, releases

The same pipeline as MS1Z:
- `macplus_romdata.py` (the one ROM table, from `mame -listxml`);
- `gen_macplus_mra.py`: DIPs, the DDR3 `address=`, the fixed-offset layout,
  game-mode switches, and `carry_over()` of the hiscore and cheat blocks
  (checksummed before and after);
- `gen_hiscore_mra.py`, `gen_cheats_mra.py`, `gen_autofire_mra.py`;
- `releases/` holds the `.mra` files and `Arcade-NMKBP964_<date>.rbf`;
- M6 adds the core to kuzecores.

### 2.12 No baked ROM data, and licences

- Nothing ROM-derived goes into the bitstream or git. No PROM exists here,
  and the "BIOS" ROM is not loaded unless Q18 finds a use (NMK-22).
- Licences:
  - TG68K is LGPL-3.0-or-later;
  - the ES5506 and ITech32's adapters are GPL-3.0/2.0-or-later;
  - fx68k is GPL-3.0;
  - `sys/` is GPL-2.0.

  That is the same Template_MiSTer GPL-2.0 caveat the siblings' `deps.lock`
  already flags. `CREDITS`/`provenance.md` carry ITech32's notices and its
  record of local changes to TG68K.

---

## 3. Milestones, tasks and gates

### M0 — Foundation (no RTL judged yet)

- `git init`, `deps.lock`, `bootstrap.sh`, the verbatim set from §2.8, and a
  `.gitignore` that includes `sim/rtl/*/V*` binaries from the start (the
  MS1Z `Vms1z_aud` accident).
- Rebuild GHDL with `--enable-synth` and the ghdl-yosys-plugin
  (`t80-vhdl-toolchain.md`). Generate `rtl/third_party_gen/tg68k/TG68K.v`.
  Run ITech32's two TG68K odd-longword checks under Verilator against the
  netlist (it ran them under ModelSim).
- **Q1:** a MAME trace of both programs through boot, attract and
  (macrossp) the first stage. Take an opcode-class histogram and check it
  against TG68K's 68020 decode, with the bitfield, `CAS`, `CHK2`/`CMP2`,
  `PACK`, 64-bit MUL/DIV, memory-indirect modes, `MOVEC`/`MOVES` and
  `RTD`/`TRAPcc` cases listed. **Any gap stops the plan** until resolved.
- MAME patch: `macrossp-no-speedup.patch` (and the 50 us spin, made
  optional).
- MAME oracle scripts. The lessons: MS1-9, MS1-10 (keep taps referenced),
  MS1Z-4 (no `vpos()`; use `time_until_vblank_start`), MS1Z-5 (what
  `pixels()` returns relative to the palette), SS-2 (dump at the IRQ3 vector
  fetch). Captures:
  - VRAM x4, line zoom x4, registers x4, `old`/`old2` via save items, the
    palette, fade, the INPUTS/DSW reads, the sound latch and ES5506 writes;
  - 600-frame macrossp attract, 400-frame quizmoon attract, and a macrossp
    title/zoom segment (§1.5's test cases 1-4 need play; inputs scripted).
- ROM image builder (`mk_macplus_images.py`), and the `LOAD32_BYTE` order
  verified against MAME's memory view (1.7).
- Offline answers to Q3, Q8, Q9, Q13 and Q14 from the captures.

### M1 — Video against MAME state

- `sim/rtl/video_state`: the video block alone from a MAME state dump, at real
  raster pacing (MS1Z's `video_state_zl` method), against MAME's picture.
  Built in steps, each with its own gate:
  1. Unzoomed BG x3 plus text plus composition, no sprites: pixel-exact on
     attract frames with **zero** sprites visible.
  2. Sprites unzoomed and opaque, then with priority, then alpha: exact on
     attract.
  3. Zoomed sprites: exact frames, and the fudge seams reproduced.
  4. BG zoom: the title logo and stage 2 (§1.5 cases 1-3). A near-miss is
     measured, not waved away (MAME's zoom enable is a guess, R6).
- Report non-blank counts beside every exact count (NMK-21's vacuous-match
  lesson). Record every intentional divergence as MP-n.
- Budget counters: sprite max hits per line, max clocks per line and
  overruns. BG zoom cache misses per line against Q8.

### M2 — Full reference sim (from reset, arrays for ROM)

- `sim/rtl/macplus_frames`: TG68K netlist, fx68k, ES5506, video, zero-latency
  ROM arrays, MAME's raster. Gates:
  1. **Boot:** both CPUs reach the attract, and the frame sequence matches
     MAME at a constant offset k (a diagonal, not one number; NMK/SS-11).
  2. **Frames:** pixel-exact attract and title runs, with non-blank counts.
  3. **CPU work:** the idle counter `$F1015A` per frame against patched MAME,
     same scenes. This calibrates the TG68K clock enable (§7 D3). Recorded as
     a table of frames and counts.
  4. **Sound traffic:** ES5506 register writes per frame against MAME, within
     one write across a frame boundary (MS1BCD gate 3).
  5. **Audio:** `sim/rtl/macplus_snd` (the sound board alone, driven by the
     captured latch sequence): band correlation and dB against MAME's
     `-wavwrite`. MS1-14: SDL dummy drivers, never `-sound none`, never pipe
     stdout.
  6. **Savestate:** the three-save diff (SS-13), in both harnesses, forced
     through every divider phase (MS1-61).

### M3 — Hardware-path sim

- `sim/rtl/macplus_hw`: the real SDRAM model with `sdram.sv`, a DDR3 model
  with configurable latency, and the Main_MiSTer DDR preload plus the copier,
  arbiters and caches. The same gates as M2 against the M2 frames.
  Specifically:
  - the LOOKAHEAD/prefetch paths against the oracle directly (MS1-57);
  - a DDR3 latency sweep (100-400 ns) with rotation traffic injected at full
    rate, to find the first latency at which a BG line or sample misses;
  - the copier's timing and the CPUs held until it is done.
- The Makefile depends on every file `-y` finds (MS1-58). A harness that
  fails to build or run must say so (MS1-45).

### M4 — Quartus and the board

- `quartus_map` first: every RAM infers (MS1-37, MS1Z-6, SS-14), checked
  from the Analysis & Synthesis RAM summary, not trusted. M10K against
  Appendix C.
- The full compile; the build script requires "Full Compilation was
  successful" and a fresh `.rbf`. Timing is met with TG68K at 48 MHz (it is
  a known long path, per ITech32). Revert Quartus's `.qsf` append before
  committing.
- Board:
  - deploy by md5;
  - a black screen is diagnosed with the SS-15 method: the screenshot
    geometry proves the raster, and counters prove the load;
  - attract compared to MAME frames;
  - savestate, flip, pause, rotation, HQ2x, CRT Adjust;
  - sound listened to and captured.

### M5 — Feature parity

- DIPs, service, hiscore (a power cycle, NMK-33's method, and a validated
  dump), cheats, autofire (and its `.mra` tree), orientation (`vertical
  (ccw)`, NMK-35), and the keyboard.
- quizmoon: the same gates, plus its known MAME imperfections recorded as
  "matches MAME", not "correct".
- A board sweep of both `.mra` files, judged by the A→B screenshot diff and
  not by blankness (NMK-24).

### M6 — Release

- README, provenance, known-issues, a checkpoint doc, `releases/` with the
  `.rbf`, a GitHub push, and kuzecores (the `CORES` entry pinned to the
  release commit, `--keep-pins`, the workflow run and the `db.json.zip`
  checked).

---

## 4. Lessons carried in, mapped onto this board

### 4.A ROMs, `.mra`, loading
- `LOAD32_BYTE`/`LOAD16_BYTE` order is a byte-swap trap (MS1-49): u4 is the
  MSB. Checked against MAME memory in M0.
- `ERASEFF` padding in the sample region is data, not filler (§1.4).
- MiSTer never sends an empty `<switches>` (MS1-47). The core must not run
  on defaults before they arrive (MS1-53).
- `config/dips/<mra name>.dip` overrides the switches, flags byte included
  (NMK-21 harness trap; MS1Z autofire). `.nvm` files are named by the
  description, `.CFG` by setname (NMK-24).
- The DDR3 `address=` load bypasses `ioctl_wr`. The core must still see the
  download's end, and must hold the CPUs until the copier finishes. Any
  reset during the load must not lose that state (SS-15).
- `carry_over()` must have a source when regenerating `.mra` trees; checksum
  before and after.

### 4.B SDRAM, DDR3, caches, buses
- Caches see a held address when the CPU is not selecting ROM (MS1-50,
  SS-12 #2). Every port gets an arbiter; caches hold their request (SS-12
  #3). Download backpressure and a held request (SS-12 #4 and #5) apply to
  the copier.
- A held `valid` passes a per-clock sanity check it should fail (MS1-27).
- `screen_rotate` cannot be stalled (NMK-28). Everything else on DDR3
  yields.
- **Dump the value, not just the address**: a cache that serves stale data
  from a correct address is invisible to address traces (NMK-21b).

### 4.C Quartus
- Arrays must infer as M10K: lane arrays, the true-dual-port template, the
  lane select after the register, no logic between the read and its
  register (NMK-10, SS-14, MS1-37, MS1Z-6). An initial loop is limited to
  5,000 iterations.
- Restores go inside the owning always block (MS1-34, MS1-38).
- Per-pixel paths stay short. Move modulo or wrap maths to the per-tile or
  per-unit register (NMK-25: -6.2 ns went to +0.1 ns).
- Multicycle islands and high-fanout mode bytes are constrained, not timed
  as data (MS1-43, MS1-44). The game-mode byte here is a candidate.

### 4.D Video
- Test the SDRAM/DDR prefetch path against the oracle directly (MS1-57).
  Prefetch direction under flip (NMK-21b).
- Align `hcount`/`vcount` to the pipeline latency (MS1-59).
- A line engine must finish before the beam; count overruns (MS1-60,
  MS1Z-12).
- Flip is rot180 of the finished frame. Never verify it as "flip ==
  rot180(no flip)" of your own output (NMK-21).
- Sprite order and lag come from MAME's *code*, measured, not from its
  comments (MS1-16, MS1Z-7, NMK-1).
- Tile codes use a true modulo (NMK-25).
- Mid-frame writes tear on a line renderer and not in MAME's whole-frame
  draw (SS-11, MS1Z-12's residual). Expect it at the top rows, and record
  it.
- Capture alignment: dump at the handler's first act (SS-2). Understand what
  `pixels()` pairs with what (MS1Z-5).

### 4.E Audio
- Judge each source isolated. Here there is one chip, but 32 voices: compare
  per-voice register traffic, then the mix (SS-10).
- `-wavwrite` with `-sound none` is silent (SS-10); use the SDL dummy
  drivers (MS1-14); never pipe MAME's stdout.
- Level against MAME in dB before and after the output gain (MS1Z-13).
- Savestate: capture live state, never freeze the clock the restore needs,
  release on completion (MS1-61, MS1-62).

### 4.F Simulation harnesses
- The Makefile depends on everything `-y` pulls in (MS1-58). Check that the
  binary rebuilt before believing a result.
- Park on the vblank edge like the engine, and force every divider phase
  (MS1-61).
- A sound bug needs the sound harness (MS1-62).
- `stdbuf -oL` on long runs; `pkill` patterns must not match the invoking
  shell (the MS1Z session's exit 144).
- `--public-flat-rw` is 10x slower; use ports (NMK-21b).

### 4.G Board and process
- Deploy by md5, reload the core before judging, keep the board tools in
  `tools/board/` without the password.
- States saved before a format fix are not recoverable; say so.
- A `.gitignore` for build products from commit 1. Never rewrite pushed
  history; check for binaries before the first push.

### 4.H Working method
- Every claim is a measurement. Report non-blank counts. State corrections
  plainly. Do not retract a diagnosis on a harness that cannot see the bug.
- "Matches MAME" and "matches the board" are different claims. Where MAME is
  a guess (§1.8), say which one a result is.

---

## 5. Risk register

| # | risk | likelihood | impact | mitigation |
|---|---|---|---|---|
| R1 | TG68K's 68020 subset misses an instruction or addressing mode the games use | medium | a hang or wrong behaviour, hard to find late | Q1 in M0, before any other RTL |
| R2 | TG68K per-frame throughput differs from a 25 MHz 68EC020 | high | slowdown or speedup vs the board | M2 gate 3 calibrates the ce; D3 |
| R3 | Sprite fill exceeds the per-line budget | medium | missing sprites on heavy lines | Q3 measures MAME's worst line; band index; fallback to a DDR3 sprite framebuffer |
| R4 | BG zoom range defeats DDR3 prefetch | medium | torn zoomed lines | Q8; per-layer tile-row cache; D1's 64 MB alternative |
| R5 | DDR3 latency plus rotation traffic starves BG or samples | medium | tearing and audio gaps with Vert orientation | M3 latency sweep with rotation injected; priority order §2.3 |
| R6 | MAME's zoom/colour/fudge guesses are wrong for the board | certain in places | "matches MAME", not the board | mirror MAME, record as MP-n with evidence |
| R7 | The ES5506 port behaves differently from MAME's device on this game | medium | wrong instruments or envelopes | gate 4 (register traffic) and gate 5 (audio) |
| R8 | M10K budget (128 KB of main RAM, three sprite copies, two palette ports) | medium | does not fit | Appendix F budget; move `old`/`old2` to SDRAM as the first relief |
| R9 | TG68K timing at 48 MHz with this design's fanout | medium | timing failure | ITech32's registered IRQ and reset localisation; seeds; the high-fanout lesson |
| R10 | The 68020 savestate monitor (frames, VBR, MOVEC) on TG68K | medium | savestates break or hang | M2 gate 6; Q15 |
| R11 | quizmoon is imperfect in MAME | certain | a gate that matches MAME is not proof | record; compare to the YouTube reference (`:13`) where it helps |
| R12 | The board raster (Q4) is wrong | medium | scaler/CRT sync issues | parameterised timing; CRT Adjust |
| R13 | Load or copy time is long | low | slow start | measure in M3/M4 |
| R14 | Audio level or clipping against MAME's 1.6 gain | medium | too quiet or clipped | measured gain (MS1Z-13) |
| R15 | The hiscore window crosses 32-bit lanes | low | scores corrupt | generator lane mapping, and the NMK-33 power-cycle test |

---

## 6. Open questions — each settled by a measurement

- **Q1 CPU instruction coverage.** MAME `trace` over boot, attract and
  stage 1 (macrossp) and a quiz round (quizmoon). Take the unique opcode
  words, classified with `unidasm -arch 68020`, and check them against
  TG68K's decode. Also: MOVEC registers used, and exception frame formats
  taken.
- **Q2 Colour modes used.** A tap on `vr[0][11:10]` and sprite `w0[15:14]`
  across the captures. Is the `rand()` case ever hit?
- **Q3 Sprite load and timing.**
  - Per frame: the entry count with a non-zero size on screen.
  - Per line: covered pixels (MAME-side Python over the `old2` dumps), and
    the maximum.
  - The instant the game writes the list, relative to vblank.
- **Q4 Raster.** The dot clock and totals. Candidates: 27 MHz / 4 with
  HTOTAL about 426 and 264 lines. Evidence: PCB video capture, the monitor
  manual, or the 15.83 kHz / 60 Hz notes. Ship a parameter.
- **Q5 IRQ 1 and 2.** What their handlers do (disassembly at `0x84C` and
  `0x882`). Does the game rely on them (e.g. a raster split) in a way MAME
  misses?
- **Q6 Wait states.** ROM and RAM speeds on the BP964A. They affect only the
  calibration in D3.
- **Q7 Flip DIP.** Does the game flip anything itself? MAME with the DIP on
  vs off: frame diff.
- **Q8 Zoom range.** A tap on every line-zoom write and `vr[2]`: the min and
  max `incx`/`incy`, and the scenes. It sets the BG cache design.
- **Q9 Palette index overflow.** Do BG pens ever exceed 0xFFF? A tap and
  Python over the captures.
- **Q10 Fade.** Does `screen:pixels()` include `set_brightness`? Compare a
  fade frame. What is MAME's exact integer brightness application?
- **Q11 Sound status bit 0.** How the game uses the toggle (disassembly of
  its readers).
- **Q12 ES5506 IRQ.** Does the core's ES5506 ever assert it with this
  game's programming, and what the handler at the sound CPU's level 1/4
  vectors does.
- **Q13 Unmapped reads and palette low byte.** Unmapped read values from
  MAME's debugger, for every unmapped address the programs touch; the
  palette's readback of bits 7-0.
- **Q14 Text layer registers.** Does the game write non-zero scroll or
  line-zoom values for the text layer? If yes, MAME ignores them; record it.
- **Q15 VBR.** Does either game execute `MOVEC ...,VBR`? It decides the
  savestate overlay's vector address.
- **Q16 Cheat forms.** Parameters (Select Ship, Starting Area), the
  conditional action and `state="on"` one-shots: which `cheats.sv` can
  express, and which become fixed OSD variants.
- **Q17 Buttons.** Which of the 4 buttons macrossp uses (the service-mode
  input test), for `<buttons>` and autofire.
- **Q18 The "BIOS" ROM.** Any program read in the `0x400000-0x7FFFFF` or
  other unmapped windows that could be it (a tap), or data matching its
  bytes in RAM.
- **Q19 quizmoon's title.** Record MAME's picture against the reference
  video, so "matches MAME" is not mistaken for right.

---

## 7. Decisions for you before M0

**Answered 2026-09-23:** D1 the DDR3 + 32 MB SDRAM split (recommended); D2
both games in one bitstream from the start; D3 tune TG68K's clock enable to
MAME's per-frame CPU work with the speedup removed; D4 ship MAME's 512x256
screen timing.


- **D1 Memory.**
  - *Recommended:* DDR3 load, with CPU programs, sprites and text copied to
    SDRAM, and BGs and samples served from DDR3. Works on 32 MB SDRAM.
  - *Alternative:* require 64 MB or more of SDRAM, and serve everything but
    the samples from SDRAM. Simpler, and excludes 32 MB boards.
- **D2 Scope.** Both parents in one `.rbf` from the start (recommended; they
  differ in two machine-config lines), or macrossp first with quizmoon in M5.
- **D3 CPU speed policy.**
  - *Recommended:* calibrate TG68K's clock enable so per-frame CPU work
    matches MAME without its speedup, then document the effective rate.
  - *Alternative:* fix 25 MHz and accept whatever throughput TG68K gives.
- **D4 Raster.** Ship MAME's 512x256 until Q4 has evidence, or ship the
  27 MHz / 4 hypothesis. Recommended: MAME's, parameterised, with the board
  value added when measured.

---

## 8. Day one

1. D1-D4 answered.
2. `git init`, `.gitignore`, `deps.lock`, `bootstrap.sh`, the verbatim copies.
3. Rebuild GHDL synth and generate the TG68K netlist; run the adapter checks.
4. The MAME no-speedup patch and the capture script. Record the macrossp
   attract, the title with zoom, and stage 1 with scripted input; record the
   quizmoon attract.
5. Q1 (instruction coverage) before anything else in RTL. It is the one
   answer that can change the CPU choice.
6. Q3 and Q8 from the captures. They decide the sprite and BG engine
   designs.

---

## Appendix A — OSD string (draft)

```
"NMKBP964;SS3E000000:80000;",
"-;",
"HBO[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
"HBO[3:1],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
"O[9:8],Orientation,Horz,Vert 90,Vert 270;",
"O[17],Flip screen,Off,On;",
"P3,CRT Adjust;",   ... (as MS1Z, P3O[101], [100:96], [85:79], [78:74], [107:104], [108])
"h1O[12:10],P1 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
"h1O[15:13],P2 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
"-;",
"DIP;",
"-;",
"O[29],Pause,Off,On;",
"P1,Scores;", "P1O[39],High Scores,Off,On;", "P1-;", "dAP1R[30],Save Scores;", "dAP1R[31],Reset Scores;",
"P2,Cheats;", "P2-;", "h3P2O[32],<slot 1>,Off,On;" ... up to 15 slots, named per game by the .mra,
"P4,Savestates;", "P4O[41:40],Slot,1,2,3,4;", "P4-;",
"P4R[42],Save state (Alt+F1 F5 F3 F4);", "P4R[43],Load state (F1 F5 F3 F4);",
"-;",
"R[0],Reset;",
"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin;",
"I,...(savestate messages as MS1Z)...;",
"V,v",`BUILD_DATE
```

The cheat names differ per game (15 and 12). Either the slot names are
generic ("Cheat 1" ...) with the `.mra` table naming them in its comments,
or the core carries one menu per game, selected by the game mode through
`h` bits. Decided with Q16.

## Appendix B — Main-bus memory in the core (bytes)

| block | size | where | ports |
|---|---|---|---|
| main RAM | 128 K | M10K, 4 lanes | CPU / hiscore+cheats+savestate |
| SCR A/B/C VRAM | 3 x 16 K | M10K | CPU / video |
| text VRAM | 16 K | M10K | CPU / video |
| line zoom x4 | 4 x 512 | M10K or MLAB | CPU / video |
| layer registers x4 | 4 x 12 | flops | |
| sprite RAM live / old / old2 | 3 x 12 K | M10K (old/old2 in SDRAM if needed) | CPU; copy engine; sprite indexer + renderer |
| palette | 4096 x 24 bits | M10K x 2 copies | CPU / layer read, sprite read |
| sound RAM | 32 K | M10K | sound CPU / savestate |

## Appendix C — Savestate image (as built, 16-bit word addresses)

| words | contents | owner |
|---|---|---|
| `00000-0FFFF` | main RAM, big-endian halves of F00000-F1FFFF | `macplus_main` (RAM back door) |
| `10000-17FFF` | VRAM, layer = a[14:13] (SCR A, B, C, text) | main, over the board bus |
| `18000-183FF` | line zoom, layer = a[9:8] | main, board bus |
| `18400-1847F` | layer registers, 32 words per layer, 6 used | main, board bus |
| `18800-19FFF` | live sprite RAM | main, board bus |
| `1A000-1B7FF` | sprites `old`, big-endian halves | `macplus_sprites` |
| `1C000-1DFFF` | sprites `old2`, 8 words per entry (6 used) | `macplus_sprites` |
| `1E000-1FFFF` | palette | main, board bus |
| `20000-23FFF` | sound RAM | `macplus_sound` |
| `24000-243FF` | ES5506 voices: 32 rows of 32 words (27 used, 431 bits, MSB first) | sound, the chip's `ss_*` port |
| `24400-2441F` | ES5506 globals (29 words, 460 bits) | sound |
| `24800` | `{toggle, irq3, fade}` | main |
| `24810-24811` | `{irq2, pending}`, the sound command | sound |
| `24880-24883` | 68020 park frame: SSP, USP | `ss_tg68_park` |
| `24884-24887` | 68000 park frame: SSP, USP | `ss_m68k_park` |

`SS_WORDS = 0x24900` (0x49200 bytes), so the slot is 0x80000. The rest of the
CPUs' registers are on their own stacks, in main and sound RAM. Unlisted words
are holes the core answers with 0.

## Appendix D — Memory maps

**DDR3 image at `0x30000000`**, loaded by Main_MiSTer:

| offset | region | size |
|---|---|---|
| `0x0000000` | main program (4 MB region; quizmoon's gap zero) | 0x400000 |
| `0x0400000` | sound program | 0x100000 |
| `0x0500000` | text tiles (512 KB used) | 0x080000 |
| `0x0580000` | pad | 0x080000 |
| `0x0600000` | sprites | 0x1000000 |
| `0x1600000` | BG0 | 0x800000 |
| `0x1E00000` | BG1 | 0x800000 |
| `0x2600000` | BG2 | 0x800000 |
| `0x2E00000` | samples, bank pair 0/1 (macrossp: 4 MB of bytes; quizmoon: 8 MB of words) | 0x800000 |
| `0x3600000` | samples, bank pair 2/3 (quizmoon only) | 0x800000 |
| `0x3E00000` | end, 62 MB | |

**SDRAM after the copier:**

| byte address | region | port |
|---|---|---|
| `0x0000000` | main program 4 MB | 0 |
| `0x0400000` | sound program 1 MB | 1 |
| `0x0500000` | text tiles 512 KB | 3 |
| `0x0600000` | sprites 16 MB | 2 |
| `0x1600000` | spare 10 MB (`old`/`old2` if R8 needs them) | |

## Appendix E — `.mra` ROM layout

One `<rom index="0" zip="macrossp.zip" address="0x30000000">` in Appendix D
order:
- `<interleave output="32">` for the main program (u4, u3, u2, u1 as bytes
  0..3 — M0 confirms the order);
- `output="16"` for the sound program (u21 even, u20 odd);
- plain parts for text and BGs;
- `output="32"` for the sprites (u12, u11, u10, u9 as bytes 0..3 — M0
  confirms);
- the samples as bytes (macrossp) or 16-bit interleave (quizmoon);
- `<part repeat="0x.." >00</part>` to pad each region to its fixed offset.

Game mode in `<switches>` byte 2:
- `[0]` quizmoon;
- `[7]` autofire unlock, as in MS1BCD/MS1Z.

## Appendix F — M10K budget (estimate; the `quartus_map` probe decides)

| item | M10K (est.) |
|---|---:|
| main RAM 128 KB | 128 |
| VRAM 4 x 16 KB | 64 |
| sprite RAM x 3 (12 KB each) | 36 |
| palette 4K x 24, two copies | 24 |
| sound RAM 32 KB | 32 |
| line zoom x4 | 4 |
| BG line buffers 3 x 2, text x 2, sprite x 2 | 10 |
| sprite band index, double-buffered | 4 |
| ES5506 (voice rows x 2, sample cache 64 Kbit) | 12-16 |
| TG68K program cache | 16-24 |
| sound program cache | 4-8 |
| DDR3 BG prefetch queues and zoom tile caches | 6-12 |
| hiscore, cheats, savestate | 8-12 |
| `video_retime`, `crt_adjust`, `sys/` (scaler, HQ2x, OSD) | 80-110 |
| **total** | **~430-490 of 553** |

The first relief if it does not fit: `old`/`old2` to SDRAM (-24), and one
palette copy replaced by a two-read-per-pixel schedule at 48 MHz, since the
pixel clock is well under 8 MHz (-12).
