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

local T = {}

-- The category sets live in core/_types.lua (shared with the nameplates AE
-- cast highlight); these aliases keep the established local names.
T.CASTER_CENTERED = core.CasterCentered
T.TARGET_CENTERED = core.TargetCentered

return T
