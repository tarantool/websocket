#!/usr/bin/env tarantool

local log = require('log')
local fiber = require('fiber')
local wsserver = require('websocket')
local frame = require('websocket.frame')

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
                                log.info('Closing reading fiber')
                                break
                            end
                            log.info(message)
                            log.info('sended back')
                            if not channel:write(message) then
                                log.info('Closing reading fiber#2')
                            end
                        end
                    end, channel)

                fiber.create(
                    function (channel)
                        while true do
                            if not channel:write({op=frame.TEXT,
                                                  data='qwerty'}) then
                                log.info('Closing writing fiber')
                                break
                            end
                            fiber.sleep(5)
                        end
                    end, channel)

                fiber.create(
                    function (channel)
                        fiber.sleep(20)
                        log.info('User closes websocket channel')
                        if not channel:is_closed() then
                            log.info('Success closing')
                            channel:shutdown(1000, 'Closing by user')
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
