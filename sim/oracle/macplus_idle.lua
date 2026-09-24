-- D3 calibration (docs/PLAN.md fact 9): count the idle loop's writes to
-- 0xF1015A per frame. Needs the patched MAME with MP_ORACLE=1, or MAME's
-- speedup parks the loop and the count means nothing.
-- MP_OUT=file MP_FRAMES=n. Also counts IRQ3 vector fetches per frame.
if _G.mp_idle_loaded then return end
_G.mp_idle_loaded = true
local out = io.open(os.getenv("MP_OUT") or "idle.txt", "w")
local N = tonumber(os.getenv("MP_FRAMES") or "1500")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local n, irq, F = 0, 0, 0
_G.mp_idle_taps = {
  mem:install_write_tap(0xF10158, 0xF1015B, "idle", function(off, data, mask) if (mask & 0xFFFF) ~= 0 then n = n + 1 end end),
  mem:install_read_tap(0x00006C, 0x00006F, "irq3", function() irq = irq + 1 end),
}
_G.mp_idle_sub = emu.add_machine_frame_notifier(function()
  out:write(string.format("%d %d %d\n", F, n, irq)); out:flush()
  n, irq = 0, 0; F = F + 1
  if F >= N then manager.machine:exit() end
end)
