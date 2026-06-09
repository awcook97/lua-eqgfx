local mq = require('mq')
local log   = require('eqgfx.lib.lwlogger')

log.SetAppName('eqgfx')
log.SetModuleName('ae_caster')
log.SetColors(true)
log.SetIncludeTime("milliseconds")
log.SetLevel(log.INFO)
log.SetIncludeCharacter("Server.Character.Zone")
log.SetOutputFile(mq.configDir .. "/eqgfx.log")
log.SetIncludeSource("trace")

local helpers = {}

function helpers.Init()
    mq.event('GotResponse', "[#1#(msg)] eqgfx_QS_#2#_QE START_#3#_END", helpers.GotResponse)
    -- mq.event('NoSuchName', "# - #1#: No such name.", helpers.NoSuchName)
    helpers.QueryMap = {}
    helpers.ObserverList = {}
end

function helpers.query(peerName, query, timeout)
    if not mq.TLO.EQBC.Names():find(peerName) then return 0 end
    local myName = mq.TLO.EQBC.ToonName()
    local ogTimeout = timeout or 5000
    local myTimer = ogTimeout
    local data = nil
    helpers.QueryMap[query] = {}
    helpers.QueryMap[query][peerName] = data
    mq.cmdf('/noparse /bct %s //bct %s eqgfx_QS_%s_QE START_${%s}_END', peerName, myName, query, query)
    while myTimer > 0 do
        mq.doevents()
        mq.delay(30)
        myTimer = myTimer - 30
        data = helpers.QueryMap[query][peerName]
        if helpers.QueryMap[query][peerName] ~= nil then
            log.Info("lib.eqbchelpers", "helpers.QueryMap[%s][%s] = %s", query, peerName, data)
            -- printf('Query Completed in %s ms', ogTimeout - myTimer)
            myTimer = 0
        end
    end
    return data
end

function helpers.GotResponse(line, sender, query, data)
    helpers.QueryMap[query][sender] = data
end



helpers.Init()

return helpers