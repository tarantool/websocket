#!/usr/bin/env tarantool

local log = require('log')
local websocket = require('websocket')
local json = require('json')

local base = 'wss://localhost:9001'
local agent = 'Tarantool/1.10'

local cases = {
    --1,
}

local i = 1
local limit = nil
while true do
    local url
    if i == nil then
        break
    end

    local found = false
    if i ~= nil then
        if limit == nil then
            found = true
        elseif i > limit then
            found = true
        elseif cases == nil or #cases == 0 then
            found = true
        else
            for _, case in ipairs(cases) do
                if i == case then
                    found = true
                end
            end
        end
    else
        found = true
    end

    if limit == nil then
        url = base .. '/getCaseCount?'
    else
        if i > limit then
            url = base .. '/updateReports?'
            i = nil
        else
            url = base .. ('/runCase?case=%d&'):format(i)
            i = i + 1
        end
    end
    url = url .. 'agent='..agent

    if found  then
        local ws, err = websocket.connect(url, nil, {timeout=3,
                                                     ping_timeout=15})
        if not ws then
            log.info(err)
            return
        end

        while true do
            local message, err = ws:read()
            log.info(message)
            if message then
                if message.opcode == nil then
                    log.info('Normal close')
                    break
                else
                    if limit == nil then
                        limit = tonumber(message.data)
                    else
                        log.info('echo'..json.encode(message))
                        local rc, err = ws:write(message)
                        if rc == nil then
                            log.info(err)
                            break
                        end
                    end
                end
            else
                log.info('Exception close ' .. tostring(err))
                --if websocket:error() then
                --    log.info('Socket error'..websocket:error())
                --end
                break
            end
        end

        ws:shutdown()

    end
end
