#!/usr/bin/env tarantool

local log = require('log')
local socket = require('socket')
local websocket = require('websocket')
local json = require('json')

socket.tcp_server(
    '0.0.0.0',
    8080,
    function(sock)
        local wspeer = websocket.new(sock)

        while true do
            local message, err = wspeer:read()
            if message then
                if message.opcode == nil then
                    log.info('Normal close')
                    break
                end
                log.info('echo ' .. json.encode(message))
                wspeer:write(message)
            else
                log.info('Exception close ' .. tostring(err))
                if wspeer:error() then
                    log.info('Socket error '..wspeer:error())
                end
                break
            end
        end
end)

local console = require('console')
console.start()
