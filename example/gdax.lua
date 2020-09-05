#!/usr/bin/env tarantool

local log = require('log')
local websocket = require('websocket')
local json = require('json')

local ws, err = websocket.connect(
    'wss://ws-feed.pro.coinbase.com', nil, {timeout=3})

if not ws then
    log.info(err)
    return
end

ws:write(
    json.encode(
        {type="subscribe",
         product_ids={"ETH-USD","ETH-EUR"},
         channels={"level2", "heartbeat",
                   {name="ticker",
                    product_ids={"ETH-BTC","ETH-USD"}}}}))

local packet, err = ws:read()
if err ~= nil then
   log.info(err)
end
while packet ~= nil do
    log.info(packet)
    packet, err = ws:read()
    if err ~= nil then
       log.info(err)
    end
end
