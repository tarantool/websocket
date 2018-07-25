#!/usr/bin/env tarantool

local log = require('log')
local fiber = require('fiber')
local wsserver = require('websocket')

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
                        local buffer = {}
                        while true do
                            local message = channel:read()
                            if message == nil then
                                log.info('Closed while read')
                                break
                            end

                            table.insert(buffer, message)

                            if message.fin then
                                for _, tosend in ipairs(buffer) do
                                    log.info('sended back')
                                    log.info(tosend)
                                    local rc, err = channel:write(tosend)
                                    if rc == nil then
                                        log.info('Closed while write %s', err)
                                        break
                                    end
                                end
                                buffer = {}
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
