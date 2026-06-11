--[[
  nameplates/_types.lua - types, classes and enums for the nameplate feature.
]]

local T = {}

---@enum NamePosition
T.NamePosition = { ABOVE = 1, BELOW = 2, INSIDE = 3, HIDDEN = 4 }
T.NamePositionLabels = { 'Above bar', 'Below bar', 'Inside bar', 'Hidden' }

---@enum UiOccludeMode  what happens to plates behind open EQ windows
T.UiOccludeMode = { CLIP = 1, HIDE = 2 }
T.UiOccludeModeLabels = { 'Clip (plates pass under windows)', 'Hide whole plate' }

---@enum BarTexture  procedural fill styles for HP + cast bars
T.BarTexture = { FLAT = 1, GRADIENT = 2, GLASS = 3, STRIPES = 4, SEGMENTS = 5 }
T.BarTextureLabels = { 'Flat', 'Gradient', 'Glass', 'Stripes', 'Segmented' }

---@enum BuffPosition  which side of the plate a buff row anchors to
T.BuffPosition = { TOP = 1, BOTTOM = 2, LEFT = 3, RIGHT = 4, HIDDEN = 5 }
T.BuffPositionLabels = { 'Top', 'Bottom', 'Left', 'Right', 'Hidden' }

---@enum BuffDirection  how icons stack within a row
T.BuffDirection = { HORIZONTAL = 1, VERTICAL = 2 }
T.BuffDirectionLabels = { 'Horizontal', 'Vertical' }

---@class BuffEntry
---@field id integer        spell ID
---@field icon integer      SpellIcon cell in the A_SpellIcons atlas
---@field ben boolean       beneficial?
---@field name string       spell name (lowercased matching for lists/overrides)
---@field mine boolean      cast by me?
---@field caster string|nil who cast it (tooltip)
---@field dur number|nil    duration seconds (tooltip)
---@field addedAt number|nil tick stamp when first seen (appear flash)
---@field scale number|nil  per-buff size multiplier (from overrides)
---@field prio number|nil   sort priority (higher = first, survives the cap)
---@field _i integer|nil    stable-sort tiebreaker

T.BuffFilterMode = { ALL = 1, WHITELIST = 2, BLACKLIST = 3 }
T.BuffFilterLabels = { 'Show all', 'Whitelist only', 'Hide blacklisted' }

T.BuffBorderMode = { BY_TYPE = 1, BY_CASTER = 2 }
T.BuffBorderLabels = { 'By buff type (ben/det)', 'By caster (mine/others)' }

---@enum AnonMode  how PC names are anonymized
T.AnonMode = { OFF = 1, CLASS = 2, CLASS_SHORT = 3, SCRAMBLE = 4,
               ASTERISKS = 5, ASTERISKS8 = 6, FIRST_LAST = 7 }
T.AnonModeLabels = { 'Real names', 'Class (Magician)', 'Class short (MAG)',
                     'Scrambled (SDMFLKI)', 'Asterisks (******)',
                     'Asterisks x8 (********)', 'First+last (C****e)' }

---@enum NameAnim  passive name text animation (4+ animate per character)
T.NameAnim = { NONE = 1, BREATHE = 2, RAINBOW = 3, RAINBOW_WAVE = 4,
               WAVE = 5, BOUNCE = 6, JITTER = 7, PULSE = 8, TYPEWRITER = 9 }
T.NameAnimLabels = { 'None', 'Breathe (alpha)', 'Rainbow (whole name)',
                     'Rainbow wave (per letter)', 'Wave (per letter)',
                     'Bounce (per letter)', 'Jitter (per letter)',
                     'Pulse size (per letter)', 'Typewriter' }

---@enum HpTextPos
T.HpTextPos = { IN_LEFT = 1, IN_CENTER = 2, IN_RIGHT = 3, ABOVE = 4, BELOW = 5 }
T.HpTextPosLabels = { 'Inside left', 'Inside center', 'Inside right',
                      'Above bar', 'Below bar' }

---@enum ResScope  who gets mana/endurance bars
T.ResScope = { OFF = 1, SELF = 2, GROUP = 3, PCS = 4, ALL = 5 }
T.ResScopeLabels = { 'Off', 'Self only', 'Self + group', 'All PCs', 'Everything' }

---@class Plate
---@field id integer
---@field name string
---@field dispHp number       smoothed HP fraction 0..1 (what the bar shows)
---@field lastHp number       last raw HP fraction (damage-flash detection)
---@field alpha number        current fade alpha 0..1
---@field scale number        current appear-pop scale
---@field bornAt number       frame-timebase stamp when the plate appeared
---@field lostAt number|nil   set when the spawn despawns / leaves range
---@field lossAlpha number|nil alpha at the moment the plate was lost
---@field flashAt number|nil  damage flash start (frame timebase)
---@field sx number|nil       last projected screen x (fade-out anchor)
---@field sy number|nil       last projected screen y
---@field dist number|nil     squared 3D distance to me (draw-order sort)
---@field isPC boolean|nil    spawn type PC?
---@field isSelf boolean|nil  this is my own plate
---@field inGroup boolean|nil spawn is in my group
---@field kind string|nil     spawn category: 'npc'|'pc'|'pet'|'merc'|'other'
---@field aeKind string|nil   'det'|'ben' while AE casts mark this plate (lingers through the fade)
---@field aeAmt number|nil    smoothed AE highlight amount 0..1 (stack alpha curve)
---@field ext number[]|nil    drawn extents last frame, relative to sx/sy: {left, top, right, bottom}
---@field cls string|nil      class name (PC anonymization)
---@field clsShort string|nil class short name
---@field mana number|nil     0..1 when the mana bar applies
---@field endu number|nil     0..1 when the endurance bar applies
---@field buffsB BuffEntry[]|nil  cached beneficial buffs
---@field buffsD BuffEntry[]|nil  cached detrimental buffs
---@field _scr string|nil     cached scrambled name
---@field _scrFor string|nil  name the scramble cache was built for

local Plate = {}
T.Plate = Plate

---@param id integer
---@param name string
---@param hp number  0..1
---@param now number
---@return Plate
function Plate.new(id, name, hp, now)
  return {
    id     = id,
    name   = name,
    dispHp = hp,
    lastHp = hp,
    alpha  = 0,
    scale  = 1,
    bornAt = now,
  }
end

return T
