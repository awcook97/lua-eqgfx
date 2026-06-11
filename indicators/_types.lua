--[[
  indicators/_types.lua - types and target-type category sets for the
  AE caster indicator feature.
]]

local core = require('eqgfx.core._types')

---@class ActiveCast
---@field id integer          caster spawn ID
---@field spellID integer|nil
---@field castStart number|nil  tracker startedAt (change detection; nil on EQBC stubs)
---@field geom SpellGeom|nil
---@field name string
---@field isSelf boolean
---@field friend boolean
---@field targetID integer|nil  resolved victim (possibly via EQBC broadcast)
---@field stub boolean|nil      built from an EQBC broadcast, not local detection
---@field expireAt number|nil   stubs only: when to drop the entry

---@class IndicatorsColors   per-category area colors
---@field enemyFill RGBA
---@field enemyLine RGBA
---@field friendFill RGBA
---@field friendLine RGBA
---@field selfFill RGBA
---@field selfLine RGBA
---@field line RGBA # single-target caster->target line
---@field debugFill RGBA
---@field debugLine RGBA

---@class IndicatorsConfig   the whole settings tree (defaults in settings.lua)
---@field showEnemies boolean
---@field showFriendly boolean
---@field showSelf boolean
---@field showAoE boolean # caster-centered circles (PBAE etc.)
---@field showCones boolean
---@field showBeams boolean
---@field showTargetAoE boolean # target-centered circles
---@field showLines boolean # single-target caster->target lines
---@field showDebugRing boolean
---@field genericMarker boolean # marker when the spell can't be identified
---@field radius number # cast detection radius, world units
---@field groundOffset number # how far below reported Z to draw areas
---@field debugRadius number # /aering ring radius
---@field colors IndicatorsColors

local T = {}

-- The category sets live in core/_types.lua (shared with the nameplates AE
-- cast highlight); these aliases keep the established local names.
T.CASTER_CENTERED = core.CasterCentered
T.TARGET_CENTERED = core.TargetCentered

return T
