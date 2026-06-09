---@module 'lwlogger'
--- A lightweight logger you can require and use at your convenience. Output goes
--- to the MQ console (color codes interpreted) and, optionally, to a file.
---
---@usage
---     local logger = require('eqgfx.lib.lwlogger')   -- or 'lib.lwlogger' in your own project
---
---     logger.SetAppName("My Application")
---     logger.SetModuleName("Module For Application")
---     logger.SetLevel(logger.INFO)                   -- or "INFO"
---     logger.SetColors(true)                         -- true | false | 'Full'
---                                                    -- | 'AppName' | 'ModuleName' | 'Level'
---                                                    -- | 'Time' | 'Character'
---                                                    -- | 'Variables' | 'MulticoloredVariables'
---     logger.SetIncludeTime('seconds')               -- true|false | 'hours'|'minutes'|'seconds'
---                                                    -- | 'deciseconds'|'centiseconds'|'milliseconds'
---     logger.SetIncludeCharacter(true)               -- true|false | 'Character' | 'Server.Character'
---                                                    -- | 'Server.Character.Zone' | 'Character.Zone'
---     logger.SetIncludeSource('trace')               -- false|true | 'trace' | 'short' | 'full'
---                                                    -- ('trace' = show file:line only at TRACE level; the default)
---     logger.SetOutputFile(true)                     -- true|false | "/path/to/file.log"
---
---     ---@param varA string # Some string variable
---     local function someFunction(varA)
---         logger.Trace("fn someFunction | varA: %s", varA)
---         logger.Debug("more detail: %d", 42)
---         logger.Info("Casting: %s", "Some Spell")
---         logger.Warn("low on mana (%d%%)", 12)
---         logger.Error("init failed: %s", err)
---         logger.Fatal("unrecoverable")
---     end
---
---     -- logger.Raw("...")  prints a prefix-less line (handy for aligned dumps).

local mq = require('mq')
local os = require('os')

-- Resolve our sibling COLORS module no matter where this package is dropped.
-- `...` is the module name Lua passed us (e.g. 'eqgfx.lib.lwlogger').
local modname = ...
local COLORS  = require((modname and (modname .. '.COLORS')) or 'COLORS')

-- Our own chunk source, so we can skip lwlogger frames when finding the caller.
local SELF_SRC = debug.getinfo(1, 'S').source

-- Level constants (ascending severity). OFF silences everything.
---@enum lwlogger.Level
local LEVEL = {
  TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5, FATAL = 6, OFF = 99,
}

--- A level passed by name instead of constant.
---@alias lwlogger.LevelName
---| '"TRACE"'
---| '"DEBUG"'
---| '"INFO"'
---| '"WARN"'
---| '"ERROR"'
---| '"FATAL"'
---| '"OFF"'

--- Accepted by `SetColors`. `true`/`'Full'` color everything; `false` nothing;
--- any other selects ONLY the named pieces.
---@alias lwlogger.ColorOption
---| '"Full"'
---| '"AppName"'    | '"App"'
---| '"ModuleName"' | '"Module"'
---| '"Level"'
---| '"Time"'
---| '"Character"'  | '"Char"'
---| '"Source"'
---| '"Variables"'  | '"Vars"' | '"Variable"'
---| '"MulticoloredVariables"' | '"MultiVars"'

--- Timestamp granularity for `SetIncludeTime`.
---@alias lwlogger.TimePrecision
---| '"hours"'
---| '"minutes"'
---| '"seconds"'
---| '"deciseconds"'
---| '"centiseconds"'
---| '"milliseconds"'

--- Character identifier shape for `SetIncludeCharacter`.
---@alias lwlogger.CharacterFormat
---| '"Character"'
---| '"Server.Character"'
---| '"Server.Character.Zone"'
---| '"Character.Zone"'

--- When to append the caller's `file:line` to a log line (`SetIncludeSource`):
---   false   -> never
---   true    -> always, basename:line
---   'trace' -> only while the active level is TRACE (the default)
---   'short' -> always, basename:line (same as true)
---   'full'  -> always, full path:line
---@alias lwlogger.SourceMode
---| boolean
---| '"trace"'
---| '"short"'
---| '"full"'

--- Per-piece on/off flags for coloring (mirrors `lwlogger.ColorOption`).
---@class lwlogger.ColorScope
---@field app       boolean
---@field module    boolean
---@field level     boolean
---@field time      boolean
---@field character boolean
---@field source    boolean
---@field var       boolean
---@field multivar  boolean

--- Internal mutable state, one instance per Lua VM (per `/lua run`).
---@class lwlogger.State
---@field appName       string?
---@field moduleName    string?
---@field level         lwlogger.Level
---@field useColor      boolean
---@field scope         lwlogger.ColorScope
---@field includeTime   false|lwlogger.TimePrecision
---@field character     false|lwlogger.CharacterFormat
---@field includeSource lwlogger.SourceMode
---@field outFile       string?

---@class lwlogger
---@field TRACE lwlogger.Level
---@field DEBUG lwlogger.Level
---@field INFO  lwlogger.Level
---@field WARN  lwlogger.Level
---@field ERROR lwlogger.Level
---@field FATAL lwlogger.Level
---@field OFF   lwlogger.Level
---@field ColorStrength lwlogger.ColorScope # the active color scope (read-only view)
---@field SetColorScheme fun(rules: table<lwlogger.Role, lwlogger.Color>) # override role colors
---@field SetIncludetime fun(v: boolean|lwlogger.TimePrecision)           # alias of SetIncludeTime
local M = {}

M.TRACE = LEVEL.TRACE
M.DEBUG = LEVEL.DEBUG
M.INFO  = LEVEL.INFO
M.WARN  = LEVEL.WARN
M.ERROR = LEVEL.ERROR
M.FATAL = LEVEL.FATAL
M.OFF   = LEVEL.OFF

---@type table<lwlogger.Level, string>
local LEVEL_LABEL = { [1] = 'TRACE', [2] = 'DEBUG', [3] = 'INFO',
                      [4] = 'WARN',  [5] = 'ERROR', [6] = 'FATAL' }
---@type table<lwlogger.Level, lwlogger.Role>
local LEVEL_ROLE  = { [1] = 'trace', [2] = 'debug', [3] = 'info',
                      [4] = 'warn',  [5] = 'error', [6] = 'fatal' }

-- All logger state lives here. One instance per Lua VM (per `/lua run`).
---@type lwlogger.State
local state = {
  appName       = nil,
  moduleName    = nil,
  level         = M.INFO,
  useColor      = true,
  -- which prefix/message pieces get colored when useColor is on:
  scope         = { app = true, module = true, level = true, time = true,
                    character = true, source = true, var = false, multivar = false },
  includeTime   = false,    -- false | precision string
  character     = false,    -- false | character-format string
  includeSource = 'trace',  -- show file:line automatically while at TRACE level
  outFile       = nil,      -- nil | path string
}

M.ColorStrength = state.scope

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

---@param name string?
function M.SetAppName(name) state.appName = name and tostring(name) or nil end

---@param name string?
function M.SetModuleName(name) state.moduleName = name and tostring(name) or nil end

--- Set the minimum level that will be emitted.
---@param level lwlogger.Level|lwlogger.LevelName  # e.g. logger.INFO or "INFO"
function M.SetLevel(level)
  if type(level) == 'string' then
    state.level = LEVEL[level:upper()] or state.level
  elseif type(level) == 'number' then
    state.level = level
  end
end

--- A settable flag inside `lwlogger.ColorScope`.
---@alias lwlogger.ScopeKey
---| '"app"'
---| '"module"'
---| '"level"'
---| '"time"'
---| '"character"'
---| '"source"'
---| '"var"'
---| '"multivar"'

-- 'AppName' | 'ModuleName' | ... -> internal scope key
---@type table<lwlogger.ColorOption, lwlogger.ScopeKey>
local SCOPE_ALIAS = {
  AppName = 'app', App = 'app',
  ModuleName = 'module', Module = 'module',
  Level = 'level',
  Time = 'time',
  Character = 'character', Char = 'character',
  Source = 'source',
  Variables = 'var', Vars = 'var', Variable = 'var',
  MulticoloredVariables = 'multivar', MultiVars = 'multivar',
}

--- Control coloring.
---   SetColors(true) / SetColors('Full')  -> color everything
---   SetColors(false)                     -> no color
---   SetColors('AppName', 'Time', ...)    -> color ONLY the named pieces
---@param ... boolean|lwlogger.ColorOption
function M.SetColors(...)
  local args = { ... }
  if #args == 0 then return end
  local first = args[1]

  if first == false then
    state.useColor = false
    return
  end

  if first == true or first == 'Full' then
    state.useColor = true
    for k in pairs(state.scope) do state.scope[k] = true end
    state.scope.multivar = false        -- mutually exclusive with single-color vars
    return
  end

  -- Explicit list: enable color, turn on only the named pieces.
  state.useColor = true
  for k in pairs(state.scope) do state.scope[k] = false end
  for _, a in ipairs(args) do
    local key = SCOPE_ALIAS[a]
    if key == 'multivar' then
      state.scope.multivar, state.scope.var = true, true
    elseif key then
      state.scope[key] = true
    end
  end
end

local TIME_PRECISION = {
  hours = true, minutes = true, seconds = true,
  deciseconds = true, centiseconds = true, milliseconds = true,
}

--- Include a timestamp in the prefix.
---@param v boolean|lwlogger.TimePrecision  # true => 'seconds'; false => off
function M.SetIncludeTime(v)
  if v == false then
    state.includeTime = false
  elseif v == true then
    state.includeTime = 'seconds'
  elseif type(v) == 'string' and TIME_PRECISION[v] then
    state.includeTime = v --[[@as lwlogger.TimePrecision]]
  end
end
M.SetIncludetime = M.SetIncludeTime     -- accept the lowercase spelling too

local CHAR_MODE = {
  ['Character'] = true, ['Server.Character'] = true,
  ['Server.Character.Zone'] = true, ['Character.Zone'] = true,
}

--- Include the active character (and optionally server/zone) in the prefix.
---@param v boolean|lwlogger.CharacterFormat  # true => 'Character'; false => off
function M.SetIncludeCharacter(v)
  if v == false then
    state.character = false
  elseif v == true then
    state.character = 'Character'
  elseif type(v) == 'string' and CHAR_MODE[v] then
    state.character = v --[[@as lwlogger.CharacterFormat]]
  end
end

--- Append the caller's source `file:line` to each line. Defaults to 'trace'
--- (shown only while the active level is TRACE).
---@param v lwlogger.SourceMode
function M.SetIncludeSource(v)
  if v == false or v == true or v == 'trace' or v == 'short' or v == 'full' then
    state.includeSource = v
  end
end

--- Mirror output to a file (plain text, color codes stripped).
---@param v boolean|string  # true => "<AppName>.log"; or a path; false => off
function M.SetOutputFile(v)
  if v == false then
    state.outFile = nil
  elseif v == true then
    local base = (state.appName or 'lwlogger'):gsub('%s+', '_')
    state.outFile = base .. '.log'
  elseif type(v) == 'string' then
    state.outFile = v
  end
end

--- Override role colors, e.g. SetColorScheme{ app='cyan', warn='o' }.
M.SetColorScheme = COLORS.SetColorRules

-- ---------------------------------------------------------------------------
-- Prefix pieces
-- ---------------------------------------------------------------------------

-- Sub-second fraction (0..999 ms). Prefer MQ's millisecond clock; fall back to
-- fractional CPU time (not wall-aligned, but fine for log ordering).
---@return integer
local function millis()
  local ok, t = pcall(function() return mq.gettime() end)
  if ok and type(t) == 'number' then return math.floor(t % 1000) end
  return math.floor((os.clock() % 1) * 1000)
end

--- The timestamp segment text, or nil when timestamps are disabled.
---@return string?
local function time_string()
  local p = state.includeTime
  if not p then return nil end
  ---@type string
  local base
  if p == 'hours' then base = tostring(os.date('%H'))
  elseif p == 'minutes' then base = tostring(os.date('%H:%M'))
  else base = tostring(os.date('%H:%M:%S')) end
  if p == 'deciseconds' or p == 'centiseconds' or p == 'milliseconds' then
    local digits = (p == 'deciseconds' and 1) or (p == 'centiseconds' and 2) or 3
    base = base .. '.' .. string.format('%03d', millis()):sub(1, digits)
  end
  return base
end

--- The character segment text, or nil when disabled.
---@return string?
local function character_string()
  local mode = state.character
  if not mode then return nil end
  local function tlo(fn)
    local ok, v = pcall(fn)
    if ok and v ~= nil and v ~= '' then return tostring(v) end
    return '?'
  end
  local me     = tlo(function() return mq.TLO.Me.Name() end)
  local server = tlo(function() return mq.TLO.MacroQuest.Server() end)
  local zone   = tlo(function() return mq.TLO.Zone.ShortName() end)
  if mode == 'Server.Character' then       return server .. '.' .. me
  elseif mode == 'Server.Character.Zone' then return server .. '.' .. me .. '.' .. zone
  elseif mode == 'Character.Zone' then     return me .. '.' .. zone
  else                                     return me end
end

-- Is the source segment wanted for the message currently being built?
---@return boolean
local function source_wanted()
  local m = state.includeSource
  if not m then return false end
  if m == 'trace' then return state.level == M.TRACE end
  return true     -- true | 'short' | 'full'
end

-- "file:line" of the first stack frame outside this module, or nil. `full`
-- keeps the whole path; otherwise just the basename.
---@param full boolean
---@return string?
local function caller_location(full)
  for lvl = 2, 16 do
    local info = debug.getinfo(lvl, 'Sl')
    if not info then break end
    if info.source ~= SELF_SRC and info.what ~= 'C' then
      local path = info.source:gsub('^@', '')
      local name = full and path or (path:match('[^/\\]+$') or path)
      return name .. ':' .. (info.currentline or 0)
    end
  end
  return nil
end

-- Build one "[text]" segment, coloring the inner text if asked.
---@param role    lwlogger.Role
---@param text    string
---@param colored boolean?
---@return string
local function seg(role, text, colored)
  if colored then return '[' .. COLORS.ColoredRole(role, text) .. ']' end
  return '[' .. text .. ']'
end

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

---@param plainLine string
local function append_file(plainLine)
  if not state.outFile then return end
  local f = io.open(state.outFile, 'a')
  if f then
    local stamp = tostring(os.date('%Y-%m-%d %H:%M:%S'))
    f:write(stamp, ' ', plainLine, '\n')
    f:close()
  end
end

--- Format `fmt` with its args, applying variable coloring when enabled.
---@param fmt any
---@param ... any
---@return string
local function format_msg(fmt, ...)
  if select('#', ...) == 0 then return tostring(fmt) end
  if state.useColor and (state.scope.var or state.scope.multivar) then
    return COLORS.ColoredVars(state.scope.multivar, COLORS.SCHEME.var, tostring(fmt), ...)
  end
  local ok, s = pcall(string.format, tostring(fmt), ...)
  return ok and s or tostring(fmt)
end

--- Emit a message at `level`. Usually called via Trace/Debug/Info/... below.
---@param level lwlogger.Level
---@param fmt   string
---@param ...   any
function M.log(level, fmt, ...)
  if level < state.level then return end

  local colorOn = state.useColor
  local msg     = format_msg(fmt, ...)

  local parts = {}
  if state.appName then
    parts[#parts + 1] = seg('app', state.appName, colorOn and state.scope.app)
  end
  if state.moduleName then
    parts[#parts + 1] = seg('module', state.moduleName, colorOn and state.scope.module)
  end
  parts[#parts + 1] = seg(LEVEL_ROLE[level] or 'info',
                          LEVEL_LABEL[level] or '?',
                          colorOn and state.scope.level)
  if source_wanted() then
    local loc = caller_location(state.includeSource == 'full')
    if loc then parts[#parts + 1] = seg('source', loc, colorOn and state.scope.source) end
  end
  local ts = time_string()
  if ts then parts[#parts + 1] = seg('time', ts, colorOn and state.scope.time) end
  local ch = character_string()
  if ch then parts[#parts + 1] = seg('character', ch, colorOn and state.scope.character) end

  local line = table.concat(parts) .. ' ' .. msg
  print(line)                              -- MQ console interprets \a color codes
  append_file(COLORS.strip(line))
end

--- Print a prefix-less line (no brackets/level). Useful for aligned dumps.
---@param fmt string
---@param ... any
function M.Raw(fmt, ...)
  local msg = format_msg(fmt, ...)
  print(msg)
  append_file(COLORS.strip(msg))
end

-- Per-level convenience functions: logger.Info("fmt", ...) etc.

---@param fmt string  # printf-style format
---@param ... any     # format arguments
function M.Trace(fmt, ...) M.log(M.TRACE, fmt, ...) end
---@param fmt string
---@param ... any
function M.Debug(fmt, ...) M.log(M.DEBUG, fmt, ...) end
---@param fmt string
---@param ... any
function M.Info(fmt, ...)  M.log(M.INFO,  fmt, ...) end
---@param fmt string
---@param ... any
function M.Warn(fmt, ...)  M.log(M.WARN,  fmt, ...) end
---@param fmt string
---@param ... any
function M.Error(fmt, ...) M.log(M.ERROR, fmt, ...) end
---@param fmt string
---@param ... any
function M.Fatal(fmt, ...) M.log(M.FATAL, fmt, ...) end

return M
