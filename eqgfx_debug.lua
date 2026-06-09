--[[
  eqgfx_debug.lua - isolate WHY nothing draws.

  Draws a fixed marker on your own character every frame (independent of any
  spell logic): a tall vertical line + a ground ring. Also prints the render
  counters once a second.

  Run:  /lua run eqgfx_debug

  Read the printout:
    * scene=0 (never increasing)  -> MQ is NOT calling our render callback
                                     (hook/registration/ABI problem).
    * scene>0 but draws=0         -> callback fires but the queue was empty.
    * scene>0 and draws>0 but you
      see nothing on screen        -> DrawLine3D ran but the geometry is
                                     offscreen/underground/wrong-color: a
                                     coordinate-frame or vtable-index issue.
]]

local mq    = require('mq')
local eqgfx = require('eqgfx')
local log   = require('eqgfx.lib.lwlogger')

log.SetAppName('eqgfx')
log.SetModuleName('debug')
log.SetColors(true)
log.SetIncludeTime('seconds')
log.SetLevel(log.DEBUG)        -- show the periodic scene/draw counters

local ok, err = eqgfx.init()
if not ok then log.Error('init failed: %s', err) return end

-- One-time vtable sanity check: should print your real screen resolution.
local w, h = eqgfx.probe()
log.Info('probe: display = %d x %d  (should be your resolution)', w, h)

-- Turn on the fixed 2D test line (top-left diagonal). If THIS shows but the 3D
-- pole/ring don't, the vtable is right and only the 3D coord path is wrong.
eqgfx.test2d(true)
log.Info('running - look for: a yellow 2D diagonal AND giant red/green/blue 3D lines through you')

local RED   = eqgfx.argb(255, 255, 0, 0)
local GREEN = eqgfx.argb(255, 0, 255, 0)
local BLUE  = eqgfx.argb(255, 80, 160, 255)
local last  = os.clock()
local D     = 3000   -- giant: 6000-unit lines through the player, unmissable

while true do
  local me = mq.TLO.Me
  local x, y, z = me.X(), me.Y(), me.Z()
  eqgfx.clear()
  if x then
    -- Three giant axis lines crossing the player. If 3D rendering works at all,
    -- at least one spans the whole view. Color tells us the axis:
    --   RED = along TLO X,  GREEN = along TLO Y,  BLUE = along TLO Z (height)
    eqgfx.add_line(x - D, y, z, x + D, y, z, RED)
    eqgfx.add_line(x, y - D, z, x, y + D, z, GREEN)
    eqgfx.add_line(x, y, z - D, x, y, z + D, BLUE)
  end

  if os.clock() - last >= 1.0 then
    local scene, draws = eqgfx.stats()
    log.Debug('scene=%d draws=%d  me=(%.1f, %.1f, %.1f)',
              scene, draws, x or -1, y or -1, z or -1)
    last = os.clock()
  end
  mq.delay(50)
end
