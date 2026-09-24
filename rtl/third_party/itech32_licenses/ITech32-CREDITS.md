# Credits and Third-Party Notices

Source-distribution notice prepared 2026-08-30.

This core depends on the work of the developers below. Code reuse and behavioral
references are listed separately; referencing another emulator does not mean
its implementation was copied into RTL.

## Included and Adapted Code

| Component | Credit and source | Notes |
| --- | --- | --- |
| MiSTer integration and `sys/` | [Template_MiSTer at `3ea1134cf05d62c2b1db30362277a823d739ced2`](https://github.com/MiSTer-devel/Template_MiSTer/commit/3ea1134cf05d62c2b1db30362277a823d739ced2), Alexey Melnikov (Sorgelig), Till Harbaum, and the MiSTer contributors | `sys/` was replaced wholesale with this pinned upstream snapshot on 2026-09-03; its individual notices are retained. |
| Main CPU, `rtl/cpu/tg68k/` | Tobias Gubener (TobiFlex), with patches credited in the files to MikeJ, Till Harbaum, Rok Krajnk, and others; [TG68K.C](https://github.com/TobiFlex/TG68K.C/tree/ade33e396a1e647c2de9daf71ff9d5b3979639b2) | LGPL-3.0-or-later. Local ALU and kernel changes are documented below. |
| Sound CPU, `rtl/sound/third_party/mc6809i/` | [Greg Miller's mc6809](https://github.com/cavnex/mc6809), plus [JTFRAME](https://github.com/jotego/jtcores) contributors; imported through [Batsugun](https://github.com/TheJesusFish/Arcade-Batsugun_MiSTer/tree/29c36e1518f273e4a753767620c1547d1cb4531a) | Original BSD-3-Clause source-redistribution option; the JTFRAME donor's GPLv3 notice is also retained. This is a modified donor, not the untouched original. |
| CRT sync repositioning, `itech32_video_resync.sv` | Jose Tejada Gomez (Jotego), [JTFRAME `jtframe_resync.v`](https://github.com/jotego/jtcores/blob/master/modules/jtframe/hdl/video/jtframe_resync.v) | Modified adaptation; GPL-3.0-or-later. |
| Analog horizontal scaling, `itech32_video_hscale.sv` | Copyright 2026 Martin Donlon, [PGM `video_hscale.sv`](https://github.com/MiSTer-devel/Arcade-IGSPGM_MiSTer/blob/9a685bab3152f45a7d3b3d252ae4be620f2b6cb1/rtl/video_hscale.sv) | Modified adaptation; GPL-3.0-or-later. |
| PLL and reconfiguration support | Intel / Altera | Vendor-generated/support sources retain their own notices. The Quartus installation supplies vendor libraries; they are not copied into this repository. |

Framework source headers also credit **TEMLIB** (`ascal.vhd`), **Ludvig Strigeus**
(`hq2x.sv`), **bellwood420** (`f2sdram_safe_terminator.sv`), **Ultra-Embedded.com**
(`spdif.v`), **Mike Simone** (`yc_out.sv`), **Grabulosaure** (`video_freak.sv`), and
**Kitrinx** (`mt32pi.sv`), among others. Those headers remain authoritative and
are preserved, including their license conditions and disclaimers.

### TG68K.C Changes

The upstream reference is commit
`ade33e396a1e647c2de9daf71ff9d5b3979639b2`. Ignoring line endings,
`TG68K_Pack.vhd` matches that source. `TG68K_ALU.vhd` contains a local
static hardware/iterative-multiplier selection change for synthesis portability.
`TG68KdotC_Kernel.vhd` contains a reset-latched CPU-mode selector to reduce live
selector fanout. These are local modifications, not upstream behavior claims.

The LGPL text, including its incorporated GPL terms, is provided in
[`LICENSES/LGPL-3.0-or-later.txt`](LICENSES/LGPL-3.0-or-later.txt).
This also supplies the license text for LGPL-marked framework components.

### mc6809i Provenance

The included file matches the JTFRAME copy in Batsugun commit
`29c36e1518f273e4a753767620c1547d1cb4531a`, ignoring line endings. That donor
includes single-clock `cen_E`/`cen_Q`, opcode/debug, and Verilator changes
relative to Greg Miller's original.

Greg Miller's [upstream licensing document](https://github.com/cavnex/mc6809/blob/master/documentation/LICENSE.md)
offers a standard BSD license for source redistribution. This repository uses
that option for the original code, not the alternate binary-only option.
The complete notice is in
[`LICENSES/BSD-3-Clause-Greg-Miller.txt`](LICENSES/BSD-3-Clause-Greg-Miller.txt).
The [GPLv3 license supplied with the JTFRAME donor](rtl/sound/third_party/mc6809i/LICENSE)
is retained as well; the original BSD notice does not relicense later donor
modifications.

## Behavioral and Design References

- **ENSONIQ**, [OTTO (ES5506) Specification Revision 2.3](https://gjcp.net/pdf/es5506.pdf): primary reference for the sound arithmetic, register maps, envelopes, looping, mixing and interrupt audit. The scan is not redistributed; interpretations and FPGA interface limits are documented in `docs/SOUND.md`.
- **Aaron Giles and Brian Troha**, [MAME ITech32 driver](https://github.com/mamedev/mame/blob/mame0288/src/mame/itech/itech32.cpp): board maps, game configuration, inputs, and device behavior.
- **Aaron Giles**, [MAME ITech32 video](https://github.com/mamedev/mame/blob/mame0288/src/mame/itech/itech32_v.cpp): blitter and video behavior.
- **Aaron Giles**, [MAME ES5506](https://github.com/mamedev/mame/blob/mame0288/src/devices/sound/es5506.cpp): sound-device behavior. The local ES5506 implementation is original behavioral RTL, not a mechanical translation of MAME.
- [Arcade-Batsugun_MiSTer](https://github.com/TheJesusFish/Arcade-Batsugun_MiSTer), [Arcade-Cave_MiSTer](https://github.com/MiSTer-devel/Arcade-Cave_MiSTer), and [Arcade-IGSPGM_MiSTer](https://github.com/MiSTer-devel/Arcade-IGSPGM_MiSTer): menu organization and integration examples, in addition to the explicit adaptations above.
- [Awesome Retro Docs](https://github.com/TinyRetroWarehouse/Awesome-Retro-Docs) and the original document authors: hardware documentation references.
- [visions85/sftm](https://github.com/visions85/sftm): independent implementation comparisons and test ideas; no RTL was imported from that project.

MAME is a behavioral reference, not a substitute for measured hardware timing.
Do not treat a MAME implementation assumption as a confirmed PCB specification.

## License Scope

The root [LICENSE](LICENSE) contains GPLv3. First-party files retain their
per-file notices; GPL-2.0-or-later notices permit distribution under GPLv3.
Included LGPL, BSD, framework, and vendor material retains its respective terms.
This is not a blanket relicensing of every file in the repository.

Game names belong to their respective owners. No game ROMs, disassemblies,
extracted graphics/audio, or ROM-derived test fixtures are included.
