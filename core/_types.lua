--[[
  core/_types.lua - types, classes and enums for the eqgfx core binding.
]]

---@class SpellGeom
---@field targetType integer  eSpellTargetType (-1 if lookup failed)
---@field range number
---@field aeRange number
---@field coneStart integer   degrees
---@field coneEnd integer     degrees

local T = {}

-- eSpellTargetType values (src/eqlib/include/eqlib/game/Spells.h)
T.TargetType = {
  AEPC_v1         = 2,   Group_v1        = 3,   PBAE            = 4,
  Single          = 5,   Self            = 6,   TargetArea      = 8,
  TargetAEDrain   = 20,  TargetAEUndead  = 24,  TargetAESummoned= 25,
  CasterAreaPC    = 36,  CasterAreaNPC   = 37,  AEPC_v2         = 40,
  Group_v2        = 41,  DirectionalCone = 42,  Beam            = 44,
  FreeTarget      = 45,  AreaDetrimental = 50,
}

-- Where each area target type anchors its footprint (how the client resolves
-- the AE center). Shared by indicators (area drawing) and nameplates (AE
-- cast highlight) so both always agree on the same shapes.
local TT = T.TargetType
T.CasterCentered = {
  [TT.PBAE]=true, [TT.AEPC_v1]=true, [TT.Group_v1]=true, [TT.AEPC_v2]=true,
  [TT.Group_v2]=true, [TT.CasterAreaPC]=true, [TT.CasterAreaNPC]=true,
}
T.TargetCentered = {
  [TT.TargetArea]=true, [TT.AreaDetrimental]=true, [TT.TargetAEDrain]=true,
  [TT.TargetAEUndead]=true, [TT.TargetAESummoned]=true, [TT.FreeTarget]=true,
}

return T
