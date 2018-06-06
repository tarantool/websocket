#!/usr/bin/env tarantool

local clock = require('clock')
local frame = require('websocket.frame')

local encode = frame.encode
local TEXT = frame.TEXT
local s = string.rep('abc',100)

local tests = {
    ['---WITH XOR---'] = true,
    ['---WITHOUT XOR---'] = false
}

for name,do_xor in pairs(tests) do
    print(name)
    local n = 1000000
    local t1 = clock.time()
    for i=1,n do
        encode(s,TEXT,do_xor)
    end
    local dt = clock.time() - t1
    print('n=',n)
    print('dt=',dt)
    print('ops/sec=',n/dt)
    print('microsec/op=',1000000*dt/n)
end
