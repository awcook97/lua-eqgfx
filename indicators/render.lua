--[[
  indicators/render.lua - world-space AE geometry drawing.

  Projection via eqgfx.project (raw pixels + activeCast reliable in-front-of-camera
  bool per vertex); drawing via the ImGui foreground draw list - translucent
  filled polygons, anti-aliased outlines, caster->target lines.
]]

local mq       = require('mq')
local eqgfx    = require('eqgfx')
local ImGui    = require('ImGui')
local settings = require('eqgfx.indicators.settings')
local itypes   = require('eqgfx.indicators._types')

local TT              = eqgfx.TargetType
local CASTER_CENTERED = itypes.CASTER_CENTERED
local TARGET_CENTERED = itypes.TARGET_CENTERED
local SEGMENTS        = 48

local R = {}

-- ImGui draw list wants a packed ImU32; settings hold float4.
local function u32(c) return ImGui.ColorConvertFloat4ToU32({ c[1], c[2], c[3], c[4] }) end
R.u32 = u32

local function cols_for(cat)
  local C = (settings.data or {}).colors
  if     cat == 'self'   then return u32(C.selfFill),   u32(C.selfLine)
  elseif cat == 'friend' then return u32(C.friendFill), u32(C.friendLine)
  else                        return u32(C.enemyFill),  u32(C.enemyLine) end
end

-- EQ heading (deg, 0=N) -> world atan2 angle. heading increases clockwise; +90.
local function facing_rad(h) return math.rad(90 + (h or 0)) end

-- Fan-fill a perimeter of WORLD points around a WORLD center, then outline it.
-- Each filled wedge (center, p_i, p_{i+1}) is drawn only when all three
-- vertices are in front of the camera, so a ring you stand inside degrades
-- gracefully.
local function fill_and_outline(drawList, cx, cy, cz, pts, closed, fillCol, lineCol)
  local csx, csy, cIn = eqgfx.project(cx, cy, cz)
  local n = #pts
  local sx, sy, infront = {}, {}, {}
  for i = 1, n do
    local p = pts[i]
    sx[i], sy[i], infront[i] = eqgfx.project(p.x, p.y, p.z)
  end

  if cIn then
    local last = closed and n or (n - 1)
    for i = 1, last do
      local j = (i % n) + 1
      if infront[i] and infront[j] then
        drawList:AddTriangleFilled(ImVec2(csx, csy), ImVec2(sx[i], sy[i]),
                             ImVec2(sx[j], sy[j]), fillCol)
      end
    end
  end

  local run = {}
  local function flush()
    if #run >= 2 then drawList:AddPolyline(run, lineCol, 0, 2.0) end
    run = {}
  end
  for i = 1, n do
    if infront[i] then run[#run + 1] = ImVec2(sx[i], sy[i]) else flush() end
  end
  if closed and infront[1] and infront[n] and #run >= 1 then
    run[#run + 1] = ImVec2(sx[1], sy[1])
  end
  flush()
end
R.fill_and_outline = fill_and_outline

-- N world points on a circle (clockwise) at ground z.
local function circle_pts(cx, cy, cz, radius, n)
  local pts = {}
  for i = 0, n - 1 do
    local activeCast = -2 * math.pi * (i / n)
    pts[i + 1] = { x = cx + radius * math.cos(activeCast), y = cy + radius * math.sin(activeCast), z = cz }
  end
  return pts
end
R.circle_pts = circle_pts

-- Arc wedge perimeter from a0..a1 (center supplied by fill_and_outline).
local function arc_pts(cx, cy, cz, radius, a0, a1, n)
  if a1 < a0 then a0, a1 = a1, a0 end
  local pts = {}
  for i = 0, n do
    local t = i / n
    local activeCast = a1 + (a0 - a1) * t
    pts[#pts + 1] = { x = cx + radius * math.cos(activeCast), y = cy + radius * math.sin(activeCast), z = cz }
  end
  return pts
end

-- Filled quad (beam) from four world corners in order.
local function fill_quad(drawList, activeCast, b, c, d, fillCol, lineCol)
  local function P(w) return eqgfx.project(w.x, w.y, w.z) end
  local ax, ay, ai = P(activeCast); local bx, by, bi = P(b)
  local cx, cy, ci = P(c); local dx, dy, di = P(d)
  if ai and bi and ci then drawList:AddTriangleFilled(ImVec2(ax,ay), ImVec2(bx,by), ImVec2(cx,cy), fillCol) end
  if ai and ci and di then drawList:AddTriangleFilled(ImVec2(ax,ay), ImVec2(cx,cy), ImVec2(dx,dy), fillCol) end
  local sc = { {ax,ay,ai}, {bx,by,bi}, {cx,cy,ci}, {dx,dy,di} }
  for i = 1, 4 do
    local p, q = sc[i], sc[(i % 4) + 1]
    if p[3] and q[3] then drawList:AddLine(ImVec2(p[1],p[2]), ImVec2(q[1],q[2]), lineCol, 2.0) end
  end
end

local function spawn_ground(spawn)
  return spawn.X(), spawn.Y(), spawn.Z() - (settings.data or {}).groundOffset
end

-- Draw one active cast's area / line.
---@param activeCast ActiveCast
function R.draw_active(drawList, activeCast)
  local cfg = settings.data or {}
  local spawn = mq.TLO.Spawn(activeCast.id)
  if not (spawn() and spawn.X()) then return end

  local cat = activeCast.isSelf and 'self' or (activeCast.friend and 'friend' or 'enemy')
  if cat == 'enemy'  and not cfg.showEnemies  then return end
  if cat == 'friend' and not cfg.showFriendly then return end
  if cat == 'self'   and not cfg.showSelf     then return end
  local fillCol, lineCol = cols_for(cat)

  local cx, cy, cz = spawn_ground(spawn)
  local spellGeom = activeCast.geom

  if not spellGeom then
    if cfg.genericMarker and cfg.showAoE then
      fill_and_outline(drawList, cx, cy, cz, circle_pts(cx, cy, cz, 8, SEGMENTS), true, fillCol, lineCol)
    end
    return
  end

  local tt = spellGeom.targetType
  local radius = (spellGeom.aeRange and spellGeom.aeRange > 0) and spellGeom.aeRange or spellGeom.range
  if radius <= 0 then radius = 1 end

  if tt == TT.DirectionalCone then
    if not cfg.showCones then return end
    local facing = facing_rad(spawn.Heading.Degrees())
    if math.abs(spellGeom.coneEnd - spellGeom.coneStart) < 0.5 then
      fill_and_outline(drawList, cx, cy, cz, circle_pts(cx, cy, cz, radius, SEGMENTS), true, fillCol, lineCol)
    else
      local a0, a1 = facing + math.rad(spellGeom.coneStart), facing + math.rad(spellGeom.coneEnd)
      fill_and_outline(drawList, cx, cy, cz, arc_pts(cx, cy, cz, radius, a0, a1, SEGMENTS), false, fillCol, lineCol)
    end

  elseif tt == TT.Beam then
    if not cfg.showBeams then return end
    local f   = facing_rad(spawn.Heading.Degrees())
    local len = (spellGeom.range and spellGeom.range > 0) and spellGeom.range or radius
    local hw  = (spellGeom.aeRange and spellGeom.aeRange > 0) and spellGeom.aeRange or 5
    local fx, fy = math.cos(f), math.sin(f)
    local px, py = -fy, fx
    local function corner(d, w) return { x = cx + fx*d + px*w, y = cy + fy*d + py*w, z = cz } end
    fill_quad(drawList, corner(0, hw), corner(len, hw), corner(len, -hw), corner(0, -hw), fillCol, lineCol)

  elseif CASTER_CENTERED[tt] then
    if not cfg.showAoE then return end
    fill_and_outline(drawList, cx, cy, cz, circle_pts(cx, cy, cz, radius, SEGMENTS), true, fillCol, lineCol)

  elseif TARGET_CENTERED[tt] then
    if not cfg.showTargetAoE then return end
    local tsp = activeCast.targetID and mq.TLO.Spawn(activeCast.targetID) or (activeCast.isSelf and mq.TLO.Target or nil)
    if tsp and tsp() and tsp.X() then
      local tx, ty, tz = spawn_ground(tsp)
      fill_and_outline(drawList, tx, ty, tz, circle_pts(tx, ty, tz, radius, SEGMENTS), true, fillCol, lineCol)
    end

  else
    -- single target / direct: line from caster to target.
    if not cfg.showLines then return end
    local tsp = activeCast.targetID and mq.TLO.Spawn(activeCast.targetID) or (activeCast.isSelf and mq.TLO.Target or nil)
    if tsp and tsp() and tsp.X() then
      local tx, ty, tz = spawn_ground(tsp)
      local ax, ay, ai = eqgfx.project(cx, cy, cz)
      local bx, by, bi = eqgfx.project(tx, ty, tz)
      if ai and bi then drawList:AddLine(ImVec2(ax, ay), ImVec2(bx, by), u32(cfg.colors.line), 3.0) end
    end
  end
end

-- Cyan reference ring around the player (toggled from the menu / /aering).
function R.draw_debug_ring(drawList)
  local cfg = settings.data or {}
  local me = mq.TLO.Me
  local x, y, z = me.X(), me.Y(), me.Z()
  if x then
    fill_and_outline(drawList, x, y, z, circle_pts(x, y, z, cfg.debugRadius, SEGMENTS),
                     true, u32(cfg.colors.debugFill), u32(cfg.colors.debugLine))
  end
end

return R
