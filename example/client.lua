#!/usr/bin/env tarantool

local log = require('log')
local websocket = require('websocket')
local json = require('json')

local ws, err = websocket.connect('wss://echo.websocket.org',
                                  nil, {timeout=3})
if err ~= nil then
    log.info(err)
    return
end

local ok, err = ws:write('HELLO')
if err ~= nil then
   log.info(err)
   os.exit(1)
end
local response, err = ws:read()
if err ~= nil then
   log.info(err)
   os.exit(1)
end
assert(response.data == 'HELLO')
log.info(response)
log.info("Echo ok")
