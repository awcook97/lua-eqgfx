---@module 'lwlogger'
--- A lightweight logger that you can require and then easily use at your convenience.
--- 
---@usage 
---     local logger = require('lib.lwlogger')
---     logger.SetColors(true|false|'Full'|'AppName'|'ModuleName'|'Time'|'Variables'|'MulticoloredVariables')
---     logger.SetAppName("My Application")
---     logger.SetLevel(lwlogger.INFO)
---     logger.SetModuleName("Module For Application")
---     logger.SetIncludetime(true|false|'hours'|'minutes'|'seconds'|'deciseconds'|'centiseconds'|'milliseconds')
---     logger.SetOutputFile(true|false|path)
---     logger.SetIncludeCharacter(true|false|'Character'|'Server.Character'|'Server.Character.Zone'|'Character.Zone')
---     
---     ---@param varA string # Some string Variable
---     local function someFunction(varA)
---         logger.Trace("fn someFunction | varA: %s", varA)
--- fill in the rest

local mq = require('mq')
local os = require('os')

---@class lwlogger
---@field UseColor boolean
---@field ColorStrength table # Change this, just set up everything correctly. I just need the functions listed above to work properly.