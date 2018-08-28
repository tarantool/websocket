#!/usr/bin/env tarantool

local log = require('log')
local socket = require('socket')
socket = require('websocket.ssl')
local websocket = require('websocket')
local json = require('json')

local ctx = socket.ctx()
if not socket.ctx_use_private_key_file(ctx, './certificate.pem') then
    log.info('Error private key')
    return
end

if not socket.ctx_use_certificate_file(ctx, './certificate.pem') then
    log.info('Error certificate')
    return
end

socket.tcp_server(
    '0.0.0.0',
    8080,
    function(sock)
        local wspeer = websocket.new(sock, 15)

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
    60*60*24*10,
    ctx
)

local console = require('console')
console.start()
