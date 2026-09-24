-- Oracle capture for Arcade-NMKBP964_MiSTer (MAME 0.289, macrossp / quizmoon).
--
-- Every frame from MP_FROM to MP_FROM+MP_FRAMES-1, at frame_done, writes
--   <MP_OUT>/sNNNNN.bin  video state, fixed layout (all little-endian u32 words
--                        unless noted), see OFFSETS below
--   <MP_OUT>/pNNNNN.raw  screen:pixels() as MAME returns it (u32 0x00RRGGBB)
-- and appends one line per frame to <MP_OUT>/frames.txt:
--   F  fade_last  es_writes  latch_writes  latch_last  irq3_fetches
--
-- Which picture pairs with which state is measured, not assumed (MS1Z-5): the
-- M1 comparator searches the offset.
--
-- Lessons applied: taps are kept referenced in _G (MS1-10); tap callbacks run
-- under pcall and print their errors, since MAME swallows them (MS1Z-4); the
-- script is guarded against MAME re-running it after a machine reset (SS-7).
if _G.mp_cap_loaded then return end
_G.mp_cap_loaded = true

-- MP_PLAY=<path to macplus_play.lua> also plays the game (MAME runs one autoboot script).
if os.getenv("MP_PLAY") then dofile(os.getenv("MP_PLAY")) end

local OUT    = os.getenv("MP_OUT") or "."
local FROM   = tonumber(os.getenv("MP_FROM") or "0")
local FRAMES = tonumber(os.getenv("MP_FRAMES") or "600")
local cpu    = manager.machine.devices[":maincpu"]
local snd    = manager.machine.devices[":audiocpu"]
local mem    = cpu.spaces["program"]
local smem   = snd.spaces["program"]
local scr    = manager.machine.screens[":screen"]

-- OFFSETS in the state file (bytes)
--   0x00000 SCR A VRAM 16K   0x04000 SCR B 16K   0x08000 SCR C 16K   0x0C000 text 16K
--   0x10000 line zoom A,B,C,text 4 x 512
--   0x10800 video regs A,B,C,text 4 x 12 (0x30 bytes, padded to 0x40)
--   0x10840 palette 16K
--   0x14840 sprite RAM live 12K   0x17840 old 12K   0x1A840 old2 12K
--   0x1D840 end
local function dump_words(f, base, bytes)
  local t = {}
  for a = base, base + bytes - 1, 4 do
    local v = mem:read_u32(a)
    t[#t+1] = string.pack("<I4", v)
  end
  f:write(table.concat(t))
end

local items = manager.machine.devices[":"].items
local function item_block(name, bytes)
  local idx = items[name]
  if not idx then error("save item " .. name .. " not found") end
  return emu.item(idx):read_block(0, bytes)   -- host order (little-endian u32)
end

local fade_last, es_w, latch_w, latch_last, irq3 = -1, 0, 0, -1, 0
local function guard(fn) return function(...) local ok, e = pcall(fn, ...); if not ok then print("tap error: " .. tostring(e)) end end end
_G.mp_taps = {
  mem:install_write_tap(0xB00010, 0xB00013, "fade", guard(function(off, data, mask)
    if off == 0xB00010 and (mask & 0xFF00) ~= 0 then fade_last = (data >> 8) & 0xFF end
    if off == 0xB00012 and (mask & 0xFF00) ~= 0 then fade_last = (data >> 8) & 0xFF end
  end)),
  mem:install_write_tap(0xC00000, 0xC00003, "latch", guard(function(off, data, mask)
    latch_w = latch_w + 1; latch_last = data
  end)),
  smem:install_write_tap(0x400000, 0x40007F, "es5506", guard(function() es_w = es_w + 1 end)),
  mem:install_read_tap(0x00006C, 0x00006F, "irq3vec", guard(function() irq3 = irq3 + 1 end)),
}

local ftxt = io.open(OUT .. "/frames.txt", "w")
local F = 0
_G.mp_cap_sub = emu.add_machine_frame_notifier(guard(function()
  if F >= FROM and F < FROM + FRAMES then
    local f = io.open(string.format("%s/s%05d.bin", OUT, F), "wb")
    for _, b in ipairs({0x900000, 0x908000, 0x910000, 0x918000}) do dump_words(f, b, 0x4000) end
    for _, b in ipairs({0x904200, 0x90C200, 0x914200, 0x91C200}) do dump_words(f, b, 0x200) end
    for _, b in ipairs({0x905000, 0x90D000, 0x915000, 0x91D000}) do dump_words(f, b, 12) end
    f:write(string.rep("\0", 0x10))
    dump_words(f, 0xA00000, 0x4000)
    dump_words(f, 0x800000, 0x3000)
    f:write(item_block("0/m_spriteram_old", 0x3000))
    f:write(item_block("0/m_spriteram_old2", 0x3000))
    f:close()
    local p = io.open(string.format("%s/p%05d.raw", OUT, F), "wb")
    local px = scr:pixels()          -- returns (data, width, height): keep only the data (MS1-9)
    p:write(px)
    p:close()
    ftxt:write(string.format("%d %d %d %d %d %d\n", F, fade_last, es_w, latch_w, latch_last, irq3))
    ftxt:flush()
  end
  es_w, latch_w, irq3 = 0, 0, 0
  F = F + 1
  if F >= FROM + FRAMES then manager.machine:exit() end
end))
