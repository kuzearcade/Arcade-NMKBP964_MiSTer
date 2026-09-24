-- D3 calibration (docs/PLAN.md fact 9): count the idle loop's writes to
-- 0xF1015A per frame. Needs the patched MAME with MP_ORACLE=1, or MAME's
-- speedup parks the loop and the count means nothing.
-- MP_OUT=file MP_FRAMES=n. Also counts IRQ3 vector fetches per frame.
if _G.mp_idle_loaded then return end
_G.mp_idle_loaded = true
-- MP_PLAY=<path to macplus_play.lua> also plays (MAME runs one autoboot script)
if os.getenv("MP_PLAY") then dofile(os.getenv("MP_PLAY")) end
local out = io.open(os.getenv("MP_OUT") or "idle.txt", "w")
local N = tonumber(os.getenv("MP_FRAMES") or "1500")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local n, irq, F = 0, 0, 0
-- work time: from the IRQ3 vector fetch to the first idle-loop write after it (us)
local t_irq, work = nil, 0
_G.mp_idle_taps = {
  mem:install_write_tap(0xF10158, 0xF1015B, "idle", function(off, data, mask)
    if (mask & 0xFFFF) ~= 0 then
      n = n + 1
      if t_irq then work = (manager.machine.time - t_irq):as_double() * 1e6; t_irq = nil end
    end
  end),
  mem:install_read_tap(0x00006C, 0x00006F, "irq3", function() irq = irq + 1; t_irq = manager.machine.time end),
}
_G.mp_idle_sub = emu.add_machine_frame_notifier(function()
  out:write(string.format("%d %d %d %.1f\n", F, n, irq, work)); out:flush()
  n, irq, work = 0, 0, 0; F = F + 1
  if F >= N then manager.machine:exit() end
end)
