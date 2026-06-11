--[[
  indicators/menu.lua - the in-game settings window (/aemenu).
]]

local ImGui    = require('ImGui')
local settings = require('eqgfx.indicators.settings')

local M = { open = false }

--- Show/hide the settings window (the /aemenu bind).
function M.toggle() M.open = not M.open end

local function mark() settings.mark_dirty() end

--- Checkbox bound to a top-level settings key; marks dirty on change.
---@param label string
---@param key string # key in settings.data
local function check(label, key)
  local cfg = settings.data or {}
  local v, pressed = ImGui.Checkbox(label, cfg[key])
  if pressed then cfg[key] = v; mark() end
end

--- Keep colors as plain number tables (pickle-safe) regardless of what the
--- binding hands back (table vs ImVec4).
---@param colorVal table|any # ImGui ColorEdit4 result
---@return number[] color # plain {r,g,b,a}
local function to_color(colorVal)
  if type(colorVal) == 'table' then return { colorVal[1], colorVal[2], colorVal[3], colorVal[4] } end
  return { colorVal.x, colorVal.y, colorVal.z, colorVal.w }
end

--- Color picker bound to settings.data.colors[key]; marks dirty on change.
---@param label string
---@param key string # key in settings.data.colors
local function color(label, key)
  local cfg = settings.data or {}
  local colorVal, changed = ImGui.ColorEdit4(label, cfg.colors[key])
  if changed then cfg.colors[key] = to_color(colorVal); mark() end
end

--- Integer slider bound to a top-level settings key; marks dirty on change.
---@param label string
---@param key string # key in settings.data
---@param lo integer
---@param hi integer
local function slideri(label, key, lo, hi)
  local cfg = settings.data or {}
  local v, changed = ImGui.SliderInt(label, cfg[key], lo, hi)
  if changed then cfg[key] = v; mark() end
end

--- Float slider bound to a top-level settings key; marks dirty on change.
---@param label string
---@param key string # key in settings.data
---@param lo number
---@param hi number
local function sliderf(label, key, lo, hi)
  local cfg = settings.data or {}
  local v, changed = ImGui.SliderFloat(label, cfg[key], lo, hi, '%.1f')
  if changed then cfg[key] = v; mark() end
end

--- Render the settings window (call every frame; no-op while closed).
function M.draw()
  if not M.open then return end
  local cfg = settings.data or {}
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
    ImGui.Text('Mob casts detected within ~%d units (anim limit ~400).', cfg.radius)
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
