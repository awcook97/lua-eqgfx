--[[
  indicators/_types.lua - types and target-type category sets for the
  AE caster indicator feature.
]]

local TT = require('eqgfx.core._types').TargetType

---@class ActiveCast
---@field id integer          caster spawn ID
---@field spellID integer|nil
---@field castStart number    tracker startedAt (change detection)
---@field geom SpellGeom|nil
---@field name string
---@field isSelf boolean
---@field friend boolean
---@field targetID integer|nil  resolved victim (possibly via EQBC broadcast)
---@field stub boolean|nil      built from an EQBC broadcast, not local detection
---@field expireAt number|nil   stubs only: when to drop the entry

local T = {}

T.CASTER_CENTERED = {
  [TT.PBAE]=true, [TT.AEPC_v1]=true, [TT.Group_v1]=true, [TT.AEPC_v2]=true,
  [TT.Group_v2]=true, [TT.CasterAreaPC]=true, [TT.CasterAreaNPC]=true,
}

T.TARGET_CENTERED = {
  [TT.TargetArea]=true, [TT.AreaDetrimental]=true, [TT.TargetAEDrain]=true,
  [TT.TargetAEUndead]=true, [TT.TargetAESummoned]=true, [TT.FreeTarget]=true,
}

return T
