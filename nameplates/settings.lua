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
  enabled     = true,
  radius      = 200,
  hideUnderUI = true,   -- occlude plates behind open EQ windows
  uiOccludeMode = types.UiOccludeMode.CLIP,  -- clip plates around windows, or hide them whole
  extraWindows = {},    -- additional EQ window names for occlusion (/npui add)

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
    showPct  = false,
    textPos  = types.HpTextPos.IN_RIGHT,
    textSize = 11.0,
  },

  resources = {        -- thin mana/endurance bars under the HP bar
    manaScope = types.ResScope.SELF,
    enduScope = types.ResScope.OFF,
    height    = 4,
  },

  name = {
    show      = true,
    position  = types.NamePosition.ABOVE,
    size      = 13.0,  -- font pixel size (needs sized-text support; else default)
    offsetX   = 0,
    offsetY   = 0,
    anonMode  = types.AnonMode.OFF,   -- PC name anonymization
    background = false,
    bgPadding  = 2,
    shadow     = true,                -- 1px drop shadow under the text
    anim       = types.NameAnim.NONE,
    animSpeed  = 1.0,
    animAmount = 2.0,    -- px amplitude for per-letter wave/bounce/jitter
  },

  castbar = {
    show            = true,
    height          = 7,
    gap             = 3,     -- pixels between plate stack and cast bar
    widthScale      = 1.0,   -- relative to bar width
    showIcon        = true,  -- spell icon left of the bar
    iconSize        = 18,
    showSpellName   = true,
    showTime        = true,
    showTotal       = false, -- "1.2s / 3.0s" instead of "1.2s"
    textSize        = 12.0,
    onlyTarget      = false, -- cast bars only on your current target
    interruptDetect = true,
  },

  buffs = {
    enabled    = true,
    onlyTarget = false,
    iconSize   = 16,
    spacing    = 1,
    maxIcons   = 20,    -- total cap (highest priority survive)
    maxPerRow  = 8,     -- wrap to a new row/column after this many
    borders    = true,
    combine    = false, -- one combined group at the beneficial position
    beneficial  = { position = types.BuffPosition.TOP,   direction = types.BuffDirection.HORIZONTAL },
    detrimental = { position = types.BuffPosition.RIGHT, direction = types.BuffDirection.VERTICAL },

    -- filters
    filterMode = types.BuffFilterMode.ALL,
    whitelist  = {},     -- spell names
    blacklist  = {},
    mineOnly   = false,  -- only buffs/debuffs I cast

    -- my casts vs others
    borderMode  = types.BuffBorderMode.BY_TYPE,
    mineBorder  = { 1.00, 0.85, 0.20, 1.00 },
    otherBorder = { 0.55, 0.55, 0.55, 0.90 },
    dimOthers   = 0.0,   -- 0..0.8 dark overlay on icons not cast by me

    -- per-buff overrides keyed by lowercase spell name:
    --   { scale = 1.0..3.0, priority = -10..10, hide = bool }
    overrides = {},

    tooltip          = true,  -- hover an icon: name / caster / duration
    rightClickInspect = true, -- hold right-click on an icon: spell display
    appearFlash      = true,  -- new buffs flash an expanding outline
    detPulse         = false, -- detrimental icon borders pulse continuously
  },

  target = {
    distinguish     = true,  -- style your current target's plate differently
    scale           = 1.25,
    border          = true,  -- override border color/thickness
    borderColor     = { 1.00, 0.95, 0.25, 1.00 },
    borderThickness = 2.0,
    glow            = true,  -- force border glow on the target
  },

  aehl = {               -- highlight plates that in-flight AE casts will affect
    enabled     = true,
    fromMe      = true,  -- my own casts
    fromPCs     = true,  -- other players (and their pets/mercs)
    fromNPCs    = true,  -- NPC casts (mark PC plates - the "move!" cue)
    tintBar     = true,  strength    = 0.65,  -- HP fill lerp toward the AE color
    tintBorder  = true,
    glow        = true,  -- pulsing rings around marked plates
    pulse       = true,  pulseSpeed  = 1.2,   pulseAmount = 0.35,  -- Hz, depth
    fadeSpeed   = 8.0,   -- highlight fade in/out speed (per second)
    -- overlapping areas deepen the highlight: alpha = base + step*(count-1)
    stackBase   = 0.5,   -- one AE
    stackStep   = 0.1,   -- each additional AE
    stackMax    = 5,     -- count cap (5 -> 0.9 with the defaults)
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
    nameBg        = { 0.00, 0.00, 0.00, 0.55 },
    nameShadow    = { 0.00, 0.00, 0.00, 0.90 },
    manaFill      = { 0.25, 0.45, 1.00, 1.00 },
    enduFill      = { 1.00, 0.80, 0.20, 1.00 },
    resourceBack  = { 0.08, 0.08, 0.08, 0.90 },
    castFill      = { 1.00, 0.65, 0.15, 0.95 },
    castBack      = { 0.08, 0.08, 0.08, 0.85 },
    castText      = { 1.00, 1.00, 1.00, 1.00 },
    castInterrupt = { 1.00, 0.20, 0.20, 0.90 },
    aeDet         = { 1.00, 0.55, 0.10, 1.00 },   -- my detrimental AE will hit this spawn
    aeBen         = { 0.45, 0.80, 1.00, 1.00 },   -- my beneficial AE will help this spawn
  },
}

return Store.new{ section = 'nameplates', defaults = DEFAULTS }
