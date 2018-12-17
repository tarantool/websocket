#!/usr/bin/env tarantool

local log = require('log')

local ffi = require('ffi')
ffi.load('ssl')
local ssl = require('websocket.ssl')
local websocket = require('websocket')
local json = require('json')

local ctx = ssl.ctx()
if not ssl.ctx_use_private_key_file(ctx, './certificate.pem') then
    log.info('Error private key')
    return
end

if not ssl.ctx_use_certificate_file(ctx, './certificate.pem') then
    log.info('Error certificate')
    return
end

websocket.server(
    'wss://0.0.0.0:8443/',
    function(wspeer)
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
    end,
    {
        ping_timeout = 120,
        ctx = ctx
    }
)

local console = require('console')
console.start()
