#!/usr/bin/env tarantool

local log = require('log')
local socket = require('socket')
local websocket = require('websocket')
local json = require('json')
local fiber = require('fiber')

local agent = 'Tarantool/1.10'

local urls = {
    '/runCase?casetuple=1.1.2&',
    '/updateReports?',
}

local i = 1
local limit = nil
while true do
    local url
    if i == nil then
        break
    end
    if limit == nil then
        url = '/getCaseCount?'
    else
        if i > limit then
            url = '/updateReports?'
            i = nil
        else
            url = ('/runCase?case=%d&'):format(i)
            i = i + 1
        end
    end
    url = url .. 'agent='..agent

    local sock, err = socket.tcp_connect('127.0.0.1', 9001)
    if not sock then
        log.info(sock)
        log.info(err)
        break
    end

    log.info(url)
    local request = {
        uri = url,
        host = 'localhost:9001',
    }

    local ws = websocket.new(sock, 15, true, false, request)

    while true do
        local message, err = ws:read()
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

    fiber.sleep(0.1)
end
