--[[
  eqgfx_calibrate.lua

  Magenta box is now self-centered using the real display size (pure 2D).
  Green crosshair = where world->screen currently projects your character.

  KEY: type /eqdump (stand still), and paste me the output. It now prints the
  engine's OWN world->camera transform for your position and for +50 along each
  TLO axis. From those deltas I can derive the exact projection - no guessing.

  Run:   /lua run eqgfx_calibrate
  Stop:  /lua stop eqgfx_calibrate
]]

local mq    = require('mq')
local eqgfx = require('eqgfx')

local ok, err = eqgfx.init()
if not ok then printf('[eqgfx_cal] init failed: %s', err) return end

eqgfx.set_thickness(4)

local flipx, flipy = true, true
mq.bind('/eqflipx', function()
  flipx = not flipx
  eqgfx.set_flipx(flipx)
  printf('[eqgfx_cal] flipx = %s', tostring(flipx))
end)
mq.bind('/eqflipy', function()
  flipy = not flipy
  eqgfx.set_flipy(flipy)
  printf('[eqgfx_cal] flipy = %s', tostring(flipy))
end)

mq.bind('/eqdump', function()
  local me = mq.TLO.Me
  local x, y, z = me.X() or 0, me.Y() or 0, me.Z() or 0
  local ex, ey, ez = eqgfx.get_eye()
  local w, h = eqgfx.get_screen()
  printf('[eqgfx_cal] screen = %d x %d', w, h)
  printf('[eqgfx_cal] player world = (%.2f, %.2f, %.2f)  heading=%.1f',
         x, y, z, (me.Heading and me.Heading.Degrees() or 0))
  printf('[eqgfx_cal] camera eye   = (%.2f, %.2f, %.2f)', ex, ey, ez)
  -- Engine world->camera for the player and +50 along each TLO axis.
  local function cam(px, py, pz, tag)
    local cx, cy, cz = eqgfx.world_to_camera(px, py, pz)
    printf('[eqgfx_cal] cam(%s) = (%.3f, %.3f, %.3f)', tag, cx, cy, cz)
  end
  cam(x,      y,      z,      'P    ')
  cam(x + 50, y,      z,      'P+Xx ')
  cam(x,      y + 50, z,      'P+Yy ')
  cam(x,      y,      z + 50, 'P+Zz ')
  cam(ex,     ey,     ez,     'EYE  ')   -- camera-space of the eye itself
  local t = mq.TLO.Target
  if t.ID() and t.ID() > 0 and t.X() then
    printf('[eqgfx_cal] target "%s" world=(%.2f, %.2f, %.2f)', t.CleanName() or '?', t.X(), t.Y(), t.Z())
    cam(t.X(), t.Y(), t.Z(), 'TGT  ')
  end
  local m = eqgfx.dump_matrix()
  print('[eqgfx_cal] matrixViewProj (4 rows):')
  printf('  [ %10.4f %10.4f %10.4f %10.4f ]', m[1],  m[2],  m[3],  m[4])
  printf('  [ %10.4f %10.4f %10.4f %10.4f ]', m[5],  m[6],  m[7],  m[8])
  printf('  [ %10.4f %10.4f %10.4f %10.4f ]', m[9],  m[10], m[11], m[12])
  printf('  [ %10.4f %10.4f %10.4f %10.4f ]', m[13], m[14], m[15], m[16])
end)

print('[eqgfx_cal] running. Stand still, then: /eqdump  and paste the output.')

local MAGENTA = eqgfx.argb(255, 255, 0, 255)
local GREEN   = eqgfx.argb(255, 0, 255, 0)
local last    = os.clock()

local function box(cx, cy, half, color)
  eqgfx.add_screen_line(cx-half, cy-half, cx+half, cy-half, color)
  eqgfx.add_screen_line(cx+half, cy-half, cx+half, cy+half, color)
  eqgfx.add_screen_line(cx+half, cy+half, cx-half, cy+half, color)
  eqgfx.add_screen_line(cx-half, cy+half, cx-half, cy-half, color)
end

local function crosshair(cx, cy, len, color)
  eqgfx.add_screen_line(cx-len, cy, cx+len, cy, color)
  eqgfx.add_screen_line(cx, cy-len, cx, cy+len, color)
end

while true do
  eqgfx.clear()

  -- Self-centered reference box (pure 2D): drawing works + center mark.
  local w, h = eqgfx.get_screen()
  if w > 0 then box(w * 0.5, h * 0.5, 60, MAGENTA) end

  -- ONLY your current target, big and red. Target a NAMED dummy you can see, and
  -- tell me where the red crosshair lands relative to it.
  local t = mq.TLO.Target
  if t.ID() and t.ID() > 0 and t.X() then
    local sx, sy, vis = eqgfx.world_to_screen(t.X(), t.Y(), t.Z())
    if vis then crosshair(sx, sy, 60, eqgfx.argb(255, 255, 0, 0)) end  -- red = target
    if os.clock() - last >= 10.0 then
      printf('[eqgfx_cal] target "%s" -> screen=(%.0f, %.0f) vis=%s',
             t.CleanName() or '?', sx, sy, tostring(vis))
      last = os.clock()
    end
  end

  mq.delay(10)
end
