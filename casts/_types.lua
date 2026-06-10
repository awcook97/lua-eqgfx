--[[
  casts/_types.lua - types, classes and constants for cast tracking.
]]

---@class CastInfo
---@field spawnID integer
---@field casterName string
---@field spellID integer|nil    nil when the spell link couldn't be parsed
---@field spellName string|nil
---@field startedAt number       os.clock() when the cast was detected
---@field duration number        seconds (from Spell.CastTime; 3s fallback)
---@field isSelf boolean
---@field sawAnim boolean|nil    spawn was seen in a casting animation
---@field lastAnimAt number|nil  last time the cast animation was observed
---@field interrupted boolean|nil
---@field interruptedAt number|nil

local T = {}

-- EQ animation ids that indicate "this spawn is casting" (reliable <= ~400u).
T.CAST_ANIMS = { [27]=true, [43]=true, [44]=true, [134]=true, [135]=true }

---@param spawnID integer
---@param casterName string
---@param spellID integer|nil
---@param spellName string|nil
---@param duration number
---@param isSelf boolean
---@param now number
---@return CastInfo
function T.CastInfo(spawnID, casterName, spellID, spellName, duration, isSelf, now)
  return {
    spawnID    = spawnID,
    casterName = casterName,
    spellID    = spellID,
    spellName  = spellName,
    startedAt  = now,
    duration   = duration,
    isSelf     = isSelf,
  }
end

return T
