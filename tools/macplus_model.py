#!/usr/bin/env python3
"""Reference model of the Macross Plus video, straight from MAME's code.

Renders one frame from a capture state file (sim/oracle/macplus_capture.lua
layout) and the game's graphics ROMs, following macrossp.cpp's screen_update,
draw_layer and draw_sprites and drawgfx's zoom / priority / alpha rules
(docs/PLAN.md section 1.5). It exists to (a) prove that reading of the driver
against MAME's own pictures, (b) measure which state pairs with which picture,
and (c) be the specification the RTL is compared with, pixel for pixel.

    tools/macplus_model.py GAME TRACE_DIR F [--pic-offset K] [--png out.png]

compares model(state F) with MAME picture F+K and prints the differing pixels.
"""
import argparse, struct, sys, zipfile
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------- ROMs
def _load32(z, names, size, base=0):
    b = np.zeros(size, np.uint8)
    for lane, n in enumerate(names):
        d = np.frombuffer(z.read(n), np.uint8)
        b[base + lane: base + lane + 4 * len(d): 4] = d
    return b

class Roms:
    def __init__(self, game):
        z = zipfile.ZipFile(ROOT / "mame_roms" / f"{game}.zip")
        cat = lambda *ns: np.concatenate([np.frombuffer(z.read(n), np.uint8) for n in ns])
        if game == "macrossp":
            self.spr = _load32(z, ["bp964a.u12", "bp964a.u11", "bp964a.u10", "bp964a.u9"], 0x1000000)
            self.bg = [cat("bp964a.u13", "bp964a.u14"), cat("bp964a.u15", "bp964a.u16"), cat("bp964a.u17", "bp964a.u18")]
            fg = np.frombuffer(z.read("bp964a.u19"), np.uint8)
        else:
            self.spr = _load32(z, ["u12.bin", "u11.bin", "u10.bin", "u9.bin"], 0x1000000)
            self.bg = [cat("u13.bin"), cat("u15.bin"), cat("u17.bin")]
            fg = np.zeros(0, np.uint8)
        self.fg = np.zeros(0x400000, np.uint8); self.fg[:len(fg)] = fg     # region is 4 MB (ERASE00 / zero fill)
        # element counts: code %= elements() (NMK-25)
        self.spr_n = len(self.spr) // 256
        self.bg_n = [len(b) // 256 for b in self.bg]
        self.fg_n = len(self.fg) // 128

# ---------------------------------------------------------------- state
class State:
    def __init__(self, path):
        d = open(path, "rb").read()
        w = lambda off, n: np.frombuffer(d[off:off + 4 * n], "<u4")
        self.vram = [w(0x0000, 4096), w(0x4000, 4096), w(0x8000, 4096)]
        self.text = w(0xC000, 4096)
        self.lz = [[int(v) for v in w(0x10000 + i * 0x200, 128)] for i in range(4)]
        self.vr = [[int(v) for v in w(0x10800 + i * 12, 3)] for i in range(4)]
        self.pal = w(0x10840, 4096)
        self.spr_live = w(0x14840, 3072); self.spr_old = w(0x17840, 3072); self.spr_old2 = w(0x1A840, 3072)

def pal_rgb(p):
    return np.stack([(p >> 24) & 0xFF, (p >> 16) & 0xFF, (p >> 8) & 0xFF], -1).astype(np.int32)

# ---------------------------------------------------------------- tile pixels
def bg_tile_px(roms, layer, code, row, col):
    code %= roms.bg_n[layer]
    return int(roms.bg[layer][code * 256 + row * 16 + col])

def fg_tile_px(roms, code, row, col):
    code %= roms.fg_n
    b = int(roms.fg[code * 128 + row * 8 + (col >> 1)])
    return (b >> 4) if (col & 1) == 0 else (b & 15)      # gfx_16x16x4_packed_msb

def layer_colour(vr0, attr):
    m = vr0 & 0xC00
    if m == 0x800: return (attr & 0x000E0000) >> 15
    if m == 0x400: return (attr & 0x003E0000) >> 17
    return None                                            # MAME: rand() (Q2)

# ---------------------------------------------------------------- render
def render(st, roms, W=384, H=240):
    pal = st.pal
    colour = np.zeros((H, W), np.int64) - 1                # palette index, -1 = black background
    prio = np.zeros((H, W), np.int32)
    unknown = 0
    layerpri = [(st.vr[i][0] & 0xC000) >> 14 for i in range(3)]
    for pri in range(4):
        for y in range(H):
            for layer in (2, 1, 0):
                if layerpri[layer] != pri: continue
                vr, lr, vram = st.vr[layer], st.lz[layer], st.vram[layer]
                if (vr[2] & 0xF0000000) == 0xE0000000:
                    incx = ((lr[y // 2] & 0xFFFF) if (y & 1) else ((lr[y // 2] >> 16) & 0xFFFF)) << 10
                    startx = ((vr[0] & 0x3FF) << 16) - 184 * (incx - 0x10000)
                    starty = (vr[0] & 0x03FF0000) - 120 * (((vr[2] & 0x01FF0000) >> 6) - 0x10000)
                    incy = (vr[2] & 0x01FF0000) >> 6
                    cy = (starty + y * incy) & 0xFFFFFFFF
                    cx = startx & 0xFFFFFFFF
                    for x in range(W):
                        sx = ((cx + x * incx) & 0xFFFFFFFF) >> 16 & 1023
                        sy = (cy >> 16) & 1023
                        attr = int(vram[(sy >> 4) * 64 + (sx >> 4)])
                        px = _bg_px(roms, layer, attr, sy, sx)
                        if px:
                            c = layer_colour(int(vr[0]), attr)
                            if c is None: unknown += 1; c = 0
                            colour[y, x] = 0x800 + 64 * (c % 32) + px; prio[y, x] |= 1 << pri
                else:
                    sxo, syo = int(vr[0]) & 0x3FF, (int(vr[0]) >> 16) & 0x3FF
                    sy = (y + syo) & 1023
                    for x in range(W):
                        sx = (x + sxo) & 1023
                        attr = int(vram[(sy >> 4) * 64 + (sx >> 4)])
                        px = _bg_px(roms, layer, attr, sy, sx)
                        if px:
                            c = layer_colour(int(vr[0]), attr)
                            if c is None: unknown += 1; c = 0
                            colour[y, x] = 0x800 + 64 * (c % 32) + px; prio[y, x] |= 1 << pri
    # text: no scroll, priority value 8
    for y in range(H):
        for x in range(W):
            attr = int(st.text[(y >> 4) * 64 + (x >> 4)])
            px = fg_tile_px(roms, attr & 0xFFFF, y & 15, x & 15)
            if px:
                colour[y, x] = 0x800 + 16 * (((attr & 0x00FE0000) >> 17) % 128) + px; prio[y, x] |= 8
    rgb = np.zeros((H, W, 3), np.int32)
    have = colour >= 0
    rgb[have] = pal_rgb(pal[(colour[have] & 0xFFF)])      # index wrap is Q9; & 0xFFF here
    unknown += draw_sprites(st.spr_old2, roms, pal, rgb, prio, W, H)
    return rgb, unknown

def _bg_px(roms, layer, attr, sy, sx):
    code = attr & 0xFFFF
    row, col = sy & 15, sx & 15
    if attr & 0x80000000: row = 15 - row          # TILE_FLIPYX((attr & 0xc0000000) >> 30): bit 1 = Y
    if attr & 0x40000000: col = 15 - col
    return bg_tile_px(roms, layer, code, row, col)

def draw_sprites(spr, roms, pal, rgb, prio, W, H):
    unknown = 0
    for i in range(1023, -1, -1):
        s0, s1, s2 = int(spr[i * 3]), int(spr[i * 3 + 1]), int(spr[i * 3 + 2])
        wide, high = (s0 >> 10) & 15, (s0 >> 26) & 15
        xpos, ypos = s0 & 0x3FF, (s0 >> 16) & 0x3FF
        xzoom, yzoom = s1 & 0x3FF, (s1 >> 16) & 0x3FF
        tile = s2 & 0xFFFF
        flipx, flipy = (s2 >> 30) & 1, (s2 >> 31) & 1
        alpha = (s2 >> 29) & 1
        pri = (s2 >> 26) & 3
        m = s0 & 0xC000
        if m == 0x8000: col = (s2 & 0x00380000) >> 17
        elif m == 0x4000: col = (s2 & 0x00F80000) >> 19
        else: col = None                                   # MAME: rand() (Q2); counted per pixel drawn
        if xpos > 0x1FF: xpos -= 0x400
        if ypos > 0x1FF: ypos -= 0x400
        pmask = 0
        for p, bit in ((0, 0xAAAA), (1, 0xCCCC), (2, 0xF0F0), (3, 0xFF00)):
            if pri <= p: pmask |= bit
        pmask |= 1 << 31
        ys = range(high, -1, -1) if flipy else range(0, high + 1)
        xs = range(wide, -1, -1) if flipx else range(0, wide + 1)
        yoff = high * yzoom * 16 if flipy else 0
        loopno = 0
        for ycnt in ys:
            xoff = wide * xzoom * 16 if flipx else 0
            for xcnt in xs:
                sx = (xzoom << 8) + (0x600 if xzoom < 0x100 else 0)
                sy = (yzoom << 8) + (0x600 if yzoom < 0x100 else 0)
                drawn = _zoom_tile(roms, pal, rgb, prio, (tile + loopno) % roms.spr_n, (col or 0) % 32, flipx, flipy,
                                   xpos + (xoff >> 8), ypos + (yoff >> 8), sx, sy, pmask, alpha, W, H)
                if col is None: unknown += drawn
                xoff += xzoom * 16 * (-1 if flipx else 1)
                loopno += 1
            yoff += yzoom * 16 * (-1 if flipy else 1)
    return unknown

def _zoom_tile(roms, pal, rgb, prio, code, col, flipx, flipy, dx0, dy0, scalex, scaley, pmask, alpha, W, H):
    dstw = (scalex * 16 + 0x8000) >> 16
    dsth = (scaley * 16 + 0x8000) >> 16
    if dstw < 1 or dsth < 1: return 0
    if scalex == 0x10000 and scaley == 0x10000:
        dstw = dsth = 16; dx = dy = 0x10000                # prio_alpha / prio_transpen: 1:1
    else:
        dx = (16 << 16) // dstw; dy = (16 << 16) // dsth
    ex, ey = dx0 + dstw - 1, dy0 + dsth - 1
    if dx0 > W - 1 or ex < 0 or dy0 > H - 1 or ey < 0: return 0
    srcx = 0; x0 = dx0
    if x0 < 0: srcx = (0 - x0) * dx; x0 = 0
    ex = min(ex, W - 1)
    srcy = 0; y0 = dy0
    if y0 < 0: srcy = (0 - y0) * dy; y0 = 0
    ey = min(ey, H - 1)
    if flipx: srcx = (dstw - 1) * dx - srcx; dx = -dx
    if flipy: srcy = (dsth - 1) * dy - srcy; dy = -dy
    base = code * 256
    cbase = 64 * col
    drawn = 0
    for y in range(y0, ey + 1):
        row = srcy >> 16; srcy += dy
        cx = srcx
        for x in range(x0, ex + 1):
            p = int(roms.spr[base + row * 16 + (cx >> 16)]); cx += dx
            if p == 0: continue
            drawn += 1
            if ((1 << (int(prio[y, x]) & 0x1F)) & pmask) == 0:
                c = pal_rgb(pal[(cbase + p) & 0xFFF])
                rgb[y, x] = (c + rgb[y, x]) >> 1 if alpha else c   # alpha_blend_r32(d, s, 0x80)
            prio[y, x] = 31
    return drawn

# ---------------------------------------------------------------- compare
def load_pic(path, W=384, H=240):
    a = np.frombuffer(open(path, "rb").read(), "<u4")
    n = len(a) // W
    a = a[: n * W].reshape(n, W)
    return np.stack([(a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF], -1).astype(np.int32)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game"); ap.add_argument("trace"); ap.add_argument("frame", type=int)
    ap.add_argument("--pic-offset", type=int, default=0)
    ap.add_argument("--png")
    a = ap.parse_args()
    H = 240 if a.game == "macrossp" else 224
    roms = Roms(a.game)
    st = State(Path(a.trace) / f"s{a.frame:05d}.bin")
    rgb, unknown = render(st, roms, 384, H)
    pic = load_pic(Path(a.trace) / f"p{a.frame + a.pic_offset:05d}.raw", 384, H)
    diff = np.any(rgb != pic, -1)
    print(f"model(state {a.frame}) vs MAME picture {a.frame + a.pic_offset}: {int(diff.sum())} differing of "
          f"{diff.size}, MAME non-black {int(np.any(pic != 0, -1).sum())}, unknown-colour-mode draws {unknown}")
    if a.png:
        from PIL import Image
        Image.fromarray(np.concatenate([rgb, pic, diff[..., None].repeat(3, -1) * 255], 1).astype(np.uint8)).save(a.png)

if __name__ == "__main__":
    main()
