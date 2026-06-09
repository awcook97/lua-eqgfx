--[[
  ae_caster_indicator.lua - draw the affected area of the spell you're casting.

  DEBUG TOOLS:
    /aering [r]   toggle a fixed debug ring of radius r (default 40) around YOU,
                  drawn continuously regardless of casting. Verifies the ring is
                  centered on you and renders cleanly.
    /aerad  r     set the debug ring radius.
  Verbose logging prints every spell's raw geometry + the shape/center/radius
  it decides to draw.

  Run:  /lua run ae_caster_indicator
  Stop: /lua stop ae_caster_indicator
]]

local mq    = require('mq')
local eqgfx = require('eqgfx')
local log   = require('eqgfx.lib.lwlogger')

log.SetAppName('eqgfx')
log.SetModuleName('ae_caster')
log.SetColors(true)
log.SetIncludeTime("milliseconds")
log.SetLevel(log.INFO)        -- verbose: show per-spell geometry (Debug/Trace)
log.SetIncludeCharacter("Server.Character.Zone")
log.SetOutputFile(mq.configDir .. "/eqgfx.log")
log.SetIncludeSource("trace")

local ok, err = eqgfx.init()
if not ok then log.Error('init failed: %s', err) return end
eqgfx.set_thickness(4)
log.Info('running.  /aering [r] = toggle a debug ring on you.')

local TT       = eqgfx.TargetType
local SEGMENTS = 48
local COLOR    = eqgfx.argb(200, 255, 60, 60)
local DBGCLR   = eqgfx.argb(200, 0, 255, 255)

local TTNAME = {}
for k, v in pairs(TT) do TTNAME[v] = k end

local CASTER_CENTERED = {
  [TT.PBAE]=true, [TT.AEPC_v1]=true, [TT.Group_v1]=true, [TT.AEPC_v2]=true,
  [TT.Group_v2]=true, [TT.CasterAreaPC]=true, [TT.CasterAreaNPC]=true,
}
local TARGET_CENTERED = {
  [TT.TargetArea]=true, [TT.AreaDetrimental]=true, [TT.TargetAEDrain]=true,
  [TT.TargetAEUndead]=true, [TT.TargetAESummoned]=true, [TT.FreeTarget]=true,
}

local debugRing, debugRadius = false, 40
mq.bind('/aering', function(r)
  if r and r ~= '' then debugRadius = tonumber(r) or debugRadius end
  debugRing = not debugRing
  log.Info('debug ring = %s (radius %g)', tostring(debugRing), debugRadius)
end)
mq.bind('/aerad', function(r)
  debugRadius = tonumber(r) or debugRadius
  log.Info('debug ring radius = %g', debugRadius)
end)

-- EQ heading (deg, 0=N) -> world atan2 angle in TLO (X=E/W, Y=N/S). Correct at
-- 0 and rotates the right way (heading increases clockwise; +90 not -90).
local function facing_rad(h) return math.rad(90 + h) end

local lastId = -1

local function draw_for_spell(g)
  local me = mq.TLO.Me
  local cx, cy, cz, heading = me.X(), me.Y(), me.Z(), me.Heading.Degrees()
  local radius = (g.aeRange and g.aeRange > 0) and g.aeRange or g.range
  if radius <= 0 then radius = 1 end
  local tt = g.targetType

  if tt == TT.DirectionalCone then
    local facing = facing_rad(heading)
    log.Debug('  CONE caster (%.1f,%.1f,%.1f) r=%.1f face=%.0f arc=%d..%d',
              cx, cy, cz, radius, heading, g.coneStart, g.coneEnd)
    if math.abs(g.coneEnd - g.coneStart) < 0.5 then
      eqgfx.add_circle(cx, cy, cz, radius, COLOR, SEGMENTS)
    else
      eqgfx.add_arc(cx, cy, cz, radius, facing + math.rad(g.coneStart), facing + math.rad(g.coneEnd), COLOR, 24)
    end
  elseif tt == TT.Beam then
    local f   = facing_rad(heading)
    local len = (g.range and g.range > 0) and g.range or radius
    local hw  = (g.aeRange and g.aeRange > 0) and g.aeRange or 5
    log.Debug('  BEAM caster (%.1f,%.1f,%.1f) len=%.1f hw=%.1f face=%.0f', cx, cy, cz, len, hw, heading)
    local fx, fy = math.cos(f), math.sin(f)
    local px, py = -fy, fx
    local function corner(d, w) return cx + fx*d + px*w, cy + fy*d + py*w end
    local ax, ay = corner(0, hw); local bx, by = corner(len, hw)
    local dx, dy = corner(len, -hw); local ex, ey = corner(0, -hw)
    eqgfx.add_line(ax, ay, cz, bx, by, cz, COLOR)
    eqgfx.add_line(bx, by, cz, dx, dy, cz, COLOR)
    eqgfx.add_line(dx, dy, cz, ex, ey, cz, COLOR)
    eqgfx.add_line(ex, ey, cz, ax, ay, cz, COLOR)
  elseif CASTER_CENTERED[tt] then
    log.Debug('  PBAE caster (%.1f,%.1f,%.1f) r=%.1f', cx, cy, cz, radius)
    eqgfx.add_circle(cx, cy, cz, radius, COLOR, SEGMENTS)
  elseif TARGET_CENTERED[tt] then
    local t = mq.TLO.Target
    if t.ID() and t.ID() > 0 and t.X() then
      log.Debug('  TGTAE target "%s" (%.1f,%.1f,%.1f) r=%.1f', t.CleanName() or '?', t.X(), t.Y(), t.Z(), radius)
      eqgfx.add_circle(t.X(), t.Y(), t.Z(), radius, COLOR, SEGMENTS)
    else
      log.Debug('  TGTAE but no target')
    end
  else
    log.Trace('  (single/self/other - nothing to draw)')
  end
end

while true do
  eqgfx.clear()

  if debugRing then
    local me = mq.TLO.Me
    local x, y, z = me.X(), me.Y(), me.Z()
    if x then
      eqgfx.add_circle(x, y, z, debugRadius, DBGCLR, SEGMENTS)
      -- spoke from center (you) straight out +X to the edge: its inner end marks
      -- where your position projects.
      eqgfx.add_line(x, y, z, x + debugRadius, y, z, eqgfx.argb(255, 255, 255, 0))
      if os.clock() - (debugLast or 0) >= 1.0 then
        local sx, sy, vis = eqgfx.world_to_screen(x, y, z)
        log.Debug('you world=(%.1f,%.1f,%.1f) -> screen=(%.0f,%.0f) vis=%s', x, y, z, sx, sy, tostring(vis))
        debugLast = os.clock()
      end
    end
  end

  local id = mq.TLO.Me.Casting.ID()
  if id and id > 0 then
    local g = eqgfx.spell_geom(id)
    if g then
      if id ~= lastId then
        log.Info('CAST id=%d "%s" tt=%d(%s) aeRange=%.1f range=%.1f cone=%d..%d',
                 id, mq.TLO.Spell(id).Name() or '?', g.targetType, TTNAME[g.targetType] or '?',
                 g.aeRange, g.range, g.coneStart, g.coneEnd)
        lastId = id
      end
      draw_for_spell(g)
    end
  else
    lastId = -1
  end

  mq.delay(50)
end
