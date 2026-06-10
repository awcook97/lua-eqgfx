--[[
  nameplates/_types.lua - types, classes and enums for the nameplate feature.
]]

local T = {}

---@enum NamePosition
T.NamePosition = { ABOVE = 1, BELOW = 2, INSIDE = 3, HIDDEN = 4 }
T.NamePositionLabels = { 'Above bar', 'Below bar', 'Inside bar', 'Hidden' }

---@enum BarTexture  procedural fill styles for HP + cast bars
T.BarTexture = { FLAT = 1, GRADIENT = 2, GLASS = 3, STRIPES = 4, SEGMENTS = 5 }
T.BarTextureLabels = { 'Flat', 'Gradient', 'Glass', 'Stripes', 'Segmented' }

---@class Plate
---@field id integer
---@field name string
---@field dispHp number      smoothed HP fraction 0..1 (what the bar shows)
---@field lastHp number      last raw HP fraction (damage-flash detection)
---@field alpha number       current fade alpha 0..1
---@field scale number       current appear-pop scale
---@field bornAt number      os.clock() when the plate appeared
---@field lostAt number|nil  set when the spawn despawns / leaves range
---@field flashAt number|nil damage flash start time
---@field sx number|nil      last projected screen x (fade-out anchor)
---@field sy number|nil

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
