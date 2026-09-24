-- Scripted play for oracle captures (MAME 0.289). Coin at frame F0, start at
-- F0+60, then fire held (pulsed every 4 frames), a move pattern that changes
-- every 60 frames, button 2 every 300 frames. For macrossp it also pokes the
-- Pugsy 0.279 cheats "P1 Infinite Lives" (F173C1=04) and "P1 Invincibility"
-- (F07183=0D) every frame, so an unattended run reaches later stages.
-- Environment: MP_PLAY_FROM (default 600), MP_CHEATS (default 1 for macrossp).
-- Guarded against MAME re-running the autoboot script after a reset (SS-7).
if _G.mp_play_loaded then return end
_G.mp_play_loaded = true
local F0 = tonumber(os.getenv("MP_PLAY_FROM") or "600")
local game = emu.romname()
local cheats = (os.getenv("MP_CHEATS") or (game == "macrossp" and "1" or "0")) == "1"
local ports = manager.machine.ioport.ports
local inp = ports[":INPUTS"]
local function field(n) return inp.fields[n] end
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local moves = { {}, {"P1 Up"}, {"P1 Left"}, {"P1 Down"}, {"P1 Right"}, {"P1 Up","P1 Right"}, {"P1 Down","P1 Left"} }
local held = {}
local function set(n, v) local f = field(n); if f then f:set_value(v) end end
local F = 0
_G.mp_play_sub = emu.add_machine_frame_notifier(function()
  F = F + 1
  for n,_ in pairs(held) do set(n, 0) end
  held = {}
  local function press(n) set(n, 1); held[n] = true end
  if F >= F0 and F < F0 + 6 then press("Coin 1") end
  if F >= F0 + 60 and F < F0 + 66 then press("1 Player Start") end
  if F >= F0 + 120 then
    if (F % 8) < 4 then press("P1 Button 1") end
    if (F % 300) < 4 then press("P1 Button 2") end
    for _,n in ipairs(moves[(F // 60) % #moves + 1]) do press(n) end
    if game == "quizmoon" then press(({"P1 Button 1","P1 Button 2","P1 Button 3","P1 Button 4"})[(F // 30) % 4 + 1]) end
    if cheats and game == "macrossp" then mem:write_u8(0xF173C1, 0x04); mem:write_u8(0xF07183, 0x0D) end
  end
end)
