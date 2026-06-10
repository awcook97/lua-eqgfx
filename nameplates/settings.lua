--[[
  nameplates/settings.lua - nameplate defaults, persisted via the shared
  scoped store (eqgfx.lib.settings):
      <config>/eqgfx/<Server>_<Name>_settings.lua   (default: per character)
      <config>/eqgfx/<Server>_settings.lua
      <config>/eqgfx/global_settings.lua
  Scope is switchable from /npmenu.

  Plain tables only. Colors are {r,g,b,a} floats 0..1 - directly usable by
  ImGui.ColorEdit4 / ColorConvertFloat4ToU32.
]]

local Store = require('eqgfx.lib.settings')
local types = require('eqgfx.nameplates._types')

local DEFAULTS = {
  enabled = true,
  radius  = 200,

  -- Which spawn TYPES get plates. Auras, objects, totems, corpses, traps and
  -- other non-creature spawns never do.
  show = {
    npcs = true,
    pcs  = true,
    pets = true,    -- pets & mercenaries
    self = false,
  },

  bar = {
    width           = 80,
    height          = 9,
    rounding        = 2.0,
    zOffset         = 4.0,   -- world units above the spawn's head
    opacity         = 1.0,
    borderThickness = 1.0,
    texture         = types.BarTexture.GLASS,
  },

  hp = {
    gradient = true,   -- low->mid->high color ramp by HP%; off = fixed color
    showPct  = false,  -- "63%" text inside the bar
  },

  name = {
    show     = true,
    position = types.NamePosition.ABOVE,
    size     = 13.0,   -- font pixel size (needs sized-text support; else default)
  },

  castbar = {
    show            = true,
    height          = 7,
    gap             = 3,     -- pixels between plate stack and cast bar
    showSpellName   = true,
    showTime        = true,
    interruptDetect = true,
  },

  anim = {
    -- event-driven
    hpSmoothing    = true,  hpSpeed        = 10.0,
    fadeIn         = true,  fadeInDur      = 0.20,
    fadeOut        = true,  fadeOutDur     = 0.50,
    damageFlash    = true,  flashThreshold = 0.05,  flashDur = 0.30,
    appearPop      = true,  popDur         = 0.25,
    castPulse      = true,

    -- passive (always running; per-plate phase offsets keep them desynced)
    sheen          = true,  sheenPeriod    = 3.0,    -- light sweep, seconds/cycle
    stripeScroll   = true,  stripeSpeed    = 24.0,   -- px/s (Stripes texture)
    lowHpPulse     = true,  lowHpThreshold = 0.30,  lowHpSpeed = 1.5,  -- Hz
    breathe        = false, breatheAmount  = 0.25,  breatheSpeed = 0.5, -- Hz
    borderGlow     = false, glowSpeed      = 1.0,    -- Hz
    bob            = false, bobAmount      = 2.0,   bobSpeed = 0.5,    -- px, Hz
  },

  colors = {
    barHigh       = { 0.16, 1.00, 0.16, 1.00 },
    barMid        = { 1.00, 1.00, 0.16, 1.00 },
    barLow        = { 1.00, 0.16, 0.16, 1.00 },
    barFixed      = { 0.20, 0.80, 0.20, 1.00 },
    barBack       = { 0.11, 0.11, 0.11, 1.00 },
    border        = { 0.00, 0.00, 0.00, 1.00 },
    name          = { 1.00, 1.00, 1.00, 1.00 },
    hpText        = { 1.00, 1.00, 1.00, 0.90 },
    flash         = { 1.00, 1.00, 1.00, 0.65 },
    lowHp         = { 1.00, 0.10, 0.10, 0.90 },
    glow          = { 1.00, 0.85, 0.30, 0.50 },
    castFill      = { 1.00, 0.65, 0.15, 0.95 },
    castBack      = { 0.08, 0.08, 0.08, 0.85 },
    castText      = { 1.00, 1.00, 1.00, 1.00 },
    castInterrupt = { 1.00, 0.20, 0.20, 0.90 },
  },
}

return Store.new{ section = 'nameplates', defaults = DEFAULTS }
