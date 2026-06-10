--[[
  indicators/settings.lua - AE indicator defaults, persisted via the shared
  scoped store (eqgfx.lib.settings) under <config>/eqgfx/ (see lib/settings).
  An old-style <config>/eqgfx_indicator.lua is imported once if present.
]]

local mq    = require('mq')
local Store = require('eqgfx.lib.settings')

local DEFAULTS = {
  showEnemies   = true,
  showFriendly  = false,
  showSelf      = true,
  showAoE       = true,   -- caster-centered circles (PBAE etc.)
  showCones     = true,
  showBeams     = true,
  showTargetAoE = true,   -- target-centered circles
  showLines     = true,   -- single-target caster->target lines
  showDebugRing = false,
  genericMarker = true,   -- show a marker when the spell can't be identified
  radius        = 250,
  groundOffset  = 5.0,
  debugRadius   = 40,
  colors = {
    enemyFill  = { 1.00, 0.51, 0.51, 0.27 },
    enemyLine  = { 1.00, 0.24, 0.24, 0.86 },
    friendFill = { 0.51, 0.71, 1.00, 0.27 },
    friendLine = { 0.30, 0.60, 1.00, 0.86 },
    selfFill   = { 0.51, 1.00, 0.51, 0.27 },
    selfLine   = { 0.24, 1.00, 0.24, 0.86 },
    line       = { 1.00, 0.85, 0.20, 0.90 },  -- single-target line
    debugFill  = { 0.00, 1.00, 1.00, 0.20 },
    debugLine  = { 0.00, 1.00, 1.00, 0.86 },
  },
}

return Store.new{
  section  = 'indicators',
  defaults = DEFAULTS,
  legacy   = mq.configDir .. '/eqgfx_indicator.lua',
}
