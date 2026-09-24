-- D3 by state injection (MP-13): MAME's machine at a vblank, as a savestate
-- the core can load, plus MAME's own work time for the frames that follow.
--
-- Plays as macplus_play.lua (MP_PLAY=<path>) with MP_ORACLE=1 and perfect
-- quantum (-cheat off, the patched MAME). Writes into MP_OUT:
--   work.txt      one line per frame: F idle_writes irq3_fetches work_us busy_us
--                 work: IRQ3 vector fetch to the first idle-loop write after
--                 it, as macplus_idle.lua; the handler that runs after
--                 frame_done F is logged on line F+1. It depends on where the
--                 interrupt lands in the game's logic, so D3 uses busy:
--                 busy: the time outside the idle loop in the frame, i.e. the
--                 sum of the gaps between idle-loop writes longer than
--                 BUSY_GAP (5 us; the loop writes about every 1 us), a gap
--                 still open at frame_done split there (macplus_main dbg_busy
--                 measures the same way)
--   iNNNNN.bin    at frame_done F for F = MP_FROM, MP_FROM+MP_EVERY, ...:
--                   0x00000 main RAM F00000-F1FFFF    (memory byte order)
--                   0x20000 VRAM A, B, C, text        4 x 0x4000
--                   0x30000 line zoom A, B, C, text   4 x 0x200
--                   0x30800 layer registers           4 x 12, padded to 0x40
--                   0x30840 palette                   0x4000
--                   0x34840 sprite RAM live, old, old2 3 x 0x3000
--                   0x3D840 end
--   iNNNNN.txt    every main-CPU state register ("NAME value"), then
--                 sndpending, snd_toggle, fade (the last byte written, -1 none)
-- tools/mk_inject_image.py turns a pair into a savestate slot.
if _G.mp_inj_loaded then return end
_G.mp_inj_loaded = true
if os.getenv("MP_PLAY") then dofile(os.getenv("MP_PLAY")) end

local OUT    = os.getenv("MP_OUT") or "."
local FROM   = tonumber(os.getenv("MP_FROM") or "700")
local EVERY  = tonumber(os.getenv("MP_EVERY") or "20")
local N      = tonumber(os.getenv("MP_FRAMES") or "5000")
local cpu    = manager.machine.devices[":maincpu"]
local mem    = cpu.spaces["program"]
local items  = manager.machine.devices[":"].items
local function guard(fn) return function(...) local ok, e = pcall(fn, ...); if not ok then print("tap error: " .. tostring(e)) end end end

local function words_be(base, bytes)
  local t = {}
  for a = base, base + bytes - 1, 4 do t[#t+1] = string.pack(">I4", mem:read_u32(a)) end
  return table.concat(t)
end
local function item(name)
  local idx = items[name]
  if not idx then error("save item " .. name .. " not found") end
  return emu.item(idx)
end
local function item_be(name, bytes)
  local raw = item(name):read_block(0, bytes)           -- host order u32
  local t = {}
  for i = 1, bytes, 4 do t[#t+1] = string.pack(">I4", (string.unpack("<I4", raw, i))) end
  return table.concat(t)
end

local n, irq, work, t_irq, fade = 0, 0, 0, nil, -1
local BUSY_GAP = 5e-6
local busy, t_last = 0, nil
_G.mp_inj_taps = {
  mem:install_write_tap(0xF10158, 0xF1015B, "idle", guard(function(off, data, mask)
    if (mask & 0xFFFF) ~= 0 then
      n = n + 1
      local now = manager.machine.time
      if t_irq then work = (now - t_irq):as_double() * 1e6; t_irq = nil end
      if t_last then local g = (now - t_last):as_double(); if g > BUSY_GAP then busy = busy + g end end
      t_last = now
    end
  end)),
  mem:install_read_tap(0x00006C, 0x00006F, "irq3", guard(function() irq = irq + 1; t_irq = manager.machine.time end)),
  mem:install_write_tap(0xB00010, 0xB00013, "fade", guard(function(off, data, mask)
    if off == 0xB00010 and (mask & 0xFF00) ~= 0 and ((data >> 8) & 0xFF) ~= 0xFF then fade = (data >> 8) & 0xFF end
    if off == 0xB00012 and (mask & 0xFF00) ~= 0 and ((data >> 8) & 0xFF) ~= 0xFF then fade = (data >> 8) & 0xFF end
  end)),
}

local wtxt = io.open(OUT .. "/work.txt", "w")
local F = 0
_G.mp_inj_sub = emu.add_machine_frame_notifier(guard(function()
  local now = manager.machine.time
  if t_last then local g = (now - t_last):as_double(); if g > BUSY_GAP then busy = busy + g end end
  t_last = now
  wtxt:write(string.format("%d %d %d %.1f %.1f\n", F, n, irq, work, busy * 1e6)); wtxt:flush()
  n, irq, work, busy = 0, 0, 0, 0
  if F >= FROM and (F - FROM) % EVERY == 0 then
    local f = io.open(string.format("%s/i%05d.bin", OUT, F), "wb")
    f:write(words_be(0xF00000, 0x20000))
    for _, b in ipairs({0x900000, 0x908000, 0x910000, 0x918000}) do f:write(words_be(b, 0x4000)) end
    for _, b in ipairs({0x904200, 0x90C200, 0x914200, 0x91C200}) do f:write(words_be(b, 0x200)) end
    for _, b in ipairs({0x905000, 0x90D000, 0x915000, 0x91D000}) do f:write(words_be(b, 12)) end
    f:write(string.rep("\0", 0x10))
    f:write(words_be(0xA00000, 0x4000))
    f:write(words_be(0x800000, 0x3000))
    f:write(item_be("0/m_spriteram_old", 0x3000))
    f:write(item_be("0/m_spriteram_old2", 0x3000))
    f:close()
    local t = io.open(string.format("%s/i%05d.txt", OUT, F), "w")
    local names = {}
    for k, _ in pairs(cpu.state) do names[#names+1] = k end
    table.sort(names)
    for _, k in ipairs(names) do t:write(string.format("%s %d\n", k, cpu.state[k].value)) end
    t:write(string.format("sndpending %d\nsnd_toggle %d\nfade %d\n",
      item("0/m_sndpending"):read(0), item("0/m_snd_toggle"):read(0), fade))
    t:close()
  end
  F = F + 1
  if F >= N then manager.machine:exit() end
end))
