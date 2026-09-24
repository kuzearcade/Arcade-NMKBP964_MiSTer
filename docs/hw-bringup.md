# Hardware bring-up — Arcade-NMKBP964_MiSTer

DE10-Nano at 192.168.1.138. Every file deployed is checked by md5 against the
local copy; the core is loaded through `/dev/MiSTer_cmd`.

## 2026-09-24 — first bitstreams

Deployed as `/media/fat/_Arcade/cores/Arcade-NMKBP964_20260924.rbf`, with
both `.mra` files in `_Arcade/`. The ROM zips went to `games/mame/`; the board
had neither.

| build (md5) | result |
|---|---|
| `0bcd566f...` | boots after the 22 MB copy; Banpresto screen and text layer correct; BG layer 2 scenes garbage (MP-11) |
| `5bb16d69...` (26-bit DDR3 offsets) | the attract runs correctly: Banpresto, specification page, zoomed tunnel and mech scenes, title |

The DDR3 image was read back through `/dev/mem` at 0x30000000 and is
byte-identical to the local image (MP-11).

Flip was checked the same day, with `5bb16d69`: the flipped screenshot equals
MAME's picture turned 180 degrees.

## 2026-09-24 — feature tests (`fe3887a4...`, savestates in)

Tools:
- the MiSTer's own screenshots, which capture the core's picture before
  `screen_rotate`;
- the EVGA XR1 capture box on this machine: `/dev/video0` for HDMI video and
  ALSA `hw:1,0` for its audio;
- `tools/mister_keys.py` on the board for keys, including OSD navigation.

OSD settings go in as `config/<set>.CFG`, the 16-byte status word.

| feature | result |
|---|---|
| Savestates | Alt+F1 save / F1 load round trip: the screenshot 1 s after the load equals the one 1 s after the save, **0 of 92,160 pixels** (the scene between differed by 77,313). The slot survives a core reload: reload, F1, 0 pixels against the original save. quizmoon: 0 of 86,016. `.ss` files written by the firmware. (MP-12) |
| Orientation | HDMI capture: Horz shows the raw 384x240 sideways; Vert 270 upright (MAME's ROT270 direction); Vert 90 the opposite quarter-turn; the scaler reports 240x384. |
| Pause | OSD Pause On: no pixel changes in 10 s of a moving scene; Off: 145K pixels change in 3 s. |
| High scores | Opening the OSD writes `config/nvram/Macross Plus.nvm`, 94 bytes (the `.mra`'s 0x5E: eight big-endian scores, then names). Patching every score to 1234567 and reloading, the attract's RANKING shows 1234567 on all seven visible ranks. Original file restored. |
| Cheats | Cheat 1 (Infinite Credits, F16FB1 = 9): the attract shows CREDIT 9 against CREDIT 0 without it, same moment. The other six are the same byte-poke path and need gameplay. |
| Autofire | `tools/gen_autofire_mra.py` (new, from MS1Z) writes `autofire_releases/` with byte 2 bit 7 set: the OSD then shows P1/P2 Autofire, and the release `.mra` does not. In play (coin, start, Button 1 held 6 s): Off shows no shots (the game needs presses), 10 Hz shows continuous shot streams. |
| DIP switches | OSD Coin A = Free Play resets the core and the attract shows FREE PLAY in place of CREDIT 0. The `.dip` was deleted afterwards (it would mask the autofire byte). |
| CRT Adjust | On at 0: capture identical to Off. V-Shift +10 moves the picture 11.6 capture pixels down. H-Position +20 only narrows the window 3 px a side: the HDMI scaler re-centres on the active area, so horizontal position needs a CRT to see (as for the siblings). |
| Audio, macrossp | 42 s of HDMI audio from load against MAME's 26 s WAV (`-wavwrite`, `MP_ORACLE=1`): best alignment 10.83 s (the load and copy), loudness-envelope correlation **0.998**, level **-0.39 dB**, peaks 1,207 / 1,210, band energy shares within 0.005. The ES5506 gain (`* 205 >> 11`) is right. |
| Audio, quizmoon | 40 s against MAME's WAV: correlation **0.985**, **-0.24 dB**, peaks 906 / 918 (the 16-bit sample banks). |
| quizmoon | Runs, 384x224; savestates and audio as above. |

The board was left at defaults: CFGs zeroed, no `.dip`, the test `.mra`
directory removed, the original `.nvm` restored.

## 2026-09-24 — sprite rows from DDR3, CPU at 33/48 (`dfd68645...`)

Timing met (worst setup slack +0.200 ns, fitter seed 12; seed 11 missed by
0.070 ns on the framework's HDMI clock). 35,957 ALMs (86 %), 550 / 553 M10K.

| check | result |
|---|---|
| Boot | the 6 MB copy (MP-14): the screenshot at 9 s equals MAME's attract picture 43, 0 pixels differ (the 22 MB copy needed 11 s) |
| Savestate round trip | 0 pixels between after-save and after-load |
| Explosions (MP-14) | 45 s of play with autofire: the explosion captures are solid, no line gaps (the interim `8960a7b6...` build showed the same) |
