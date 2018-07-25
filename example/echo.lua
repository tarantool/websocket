#!/usr/bin/env tarantool

local log = require('log')
local fiber = require('fiber')
local wsserver = require('websocket')
local json = require('json')
--------------------
wsd = wsserver.new('127.0.0.1', 8080)

wsd:listen()

fiber.create(
    function(wsd)
        while wsd:is_listen() do
            local channel = wsd:accept()

            if channel ~= nil then
                fiber.create(
                    function (channel)
                        while true do
                            local message = channel:read()
                            if message == nil then
                                log.info('Closed while read')
                                break
                            end
                            log.info('echo '..json.encode(message))
                            local rc, err = channel:write(message)
                            if rc == nil then
                                log.info('Closed while write %s', err)
                                break
                            end
                        end
                    end, channel)
            else
                log.info('Websocket server is closed')
                break
            end
        end
    end, wsd)

-- if wsserver:is_listen() then
--   wsd:close()

local console = require('console')
console.start()
