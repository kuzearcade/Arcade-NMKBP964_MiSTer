# Hardware bring-up — Arcade-NMKMacPlus_MiSTer

DE10-Nano at 192.168.1.138. Every file deployed is checked by md5 against the
local copy; the core is loaded through `/dev/MiSTer_cmd`.

## 2026-09-24 — first bitstreams

Deployed as `/media/fat/_Arcade/cores/Arcade-NMKMacPlus_20260924.rbf`, with
both `.mra` files in `_Arcade/`. The ROM zips went to `games/mame/`; the board
had neither.

| build (md5) | result |
|---|---|
| `0bcd566f...` | boots after the 22 MB copy; Banpresto screen and text layer correct; BG layer 2 scenes garbage (MP-11) |
| `5bb16d69...` (26-bit DDR3 offsets) | the attract runs correctly: Banpresto, specification page, zoomed tunnel and mech scenes, title |

The DDR3 image was read back through `/dev/mem` at 0x30000000 and is
byte-identical to the local image (MP-11).

Not yet done on the board: audio (needs ears or a capture), gameplay, flip,
orientation, CRT Adjust, pause, high scores, cheats, autofire, quizmoon.
