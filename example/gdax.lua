#!/usr/bin/env tarantool

local log = require('log')
local websocket = require('websocket')
local json = require('json')

local ws, err = websocket.connect(
    'wss://ws-feed.pro.coinbase.com', nil, {timeout=3, ping_timeout=15})

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

local packet = ws:read()
while packet ~= nil do
    log.info(packet)
    packet = ws:read()
end
