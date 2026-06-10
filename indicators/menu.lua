--[[
  indicators/menu.lua - the in-game settings window (/aemenu).
]]

local ImGui    = require('ImGui')
local settings = require('eqgfx.indicators.settings')

local M = { open = false }

function M.toggle() M.open = not M.open end

local function mark() settings.mark_dirty() end

local function check(label, key)
  local S = settings.data
  local v, pressed = ImGui.Checkbox(label, S[key])
  if pressed then S[key] = v; mark() end
end

-- Keep colors as plain number tables (pickle-safe) regardless of what the
-- binding hands back (table vs ImVec4).
local function to_color(c)
  if type(c) == 'table' then return { c[1], c[2], c[3], c[4] } end
  return { c.x, c.y, c.z, c.w }
end

local function color(label, key)
  local S = settings.data
  local c, changed = ImGui.ColorEdit4(label, S.colors[key])
  if changed then S.colors[key] = to_color(c); mark() end
end

local function slideri(label, key, lo, hi)
  local S = settings.data
  local v, changed = ImGui.SliderInt(label, S[key], lo, hi)
  if changed then S[key] = v; mark() end
end

local function sliderf(label, key, lo, hi)
  local S = settings.data
  local v, changed = ImGui.SliderFloat(label, S[key], lo, hi, '%.1f')
  if changed then S[key] = v; mark() end
end

function M.draw()
  if not M.open then return end
  local S = settings.data
  local open, show = ImGui.Begin('EQGFX Spell Indicators', M.open)
  M.open = open
  if show then
    ImGui.Text('Save for:')
    ImGui.SameLine()
    if ImGui.RadioButton('This character', settings.scope == 'char') then settings.set_scope('char') end
    ImGui.SameLine()
    if ImGui.RadioButton('This server', settings.scope == 'server') then settings.set_scope('server') end
    ImGui.SameLine()
    if ImGui.RadioButton('All characters', settings.scope == 'global') then settings.set_scope('global') end
    ImGui.Separator()
    ImGui.Text('Mob casts detected within ~%d units (anim limit ~400).', S.radius)
    slideri('Detection radius', 'radius', 20, 400)
    sliderf('Ground offset', 'groundOffset', 0.0, 15.0)
    ImGui.Separator()
    check('Show enemies',  'showEnemies')
    check('Show friendly', 'showFriendly')
    check('Show self',     'showSelf')
    ImGui.Separator()
    check('AoE (caster-centered)', 'showAoE')
    check('Cones',                 'showCones')
    check('Beams',                 'showBeams')
    check('Target-centered AoE',   'showTargetAoE')
    check('Single-target lines',   'showLines')
    check('Generic marker (unknown spell)', 'genericMarker')
    check('Debug ring',            'showDebugRing')
    ImGui.Separator()
    if ImGui.CollapsingHeader('Colors') then
      color('Enemy fill',      'enemyFill')
      color('Enemy outline',   'enemyLine')
      color('Friendly fill',   'friendFill')
      color('Friendly outline','friendLine')
      color('Self fill',       'selfFill')
      color('Self outline',    'selfLine')
      color('Single-target line', 'line')
      color('Debug fill',      'debugFill')
      color('Debug outline',   'debugLine')
    end
  end
  ImGui.End()
end

return M
