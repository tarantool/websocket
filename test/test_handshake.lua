#!/usr/bin/env tarantool

local tap = require('tap')

local handshake = require('websocket.handshake')

local request = {
    ['host'] = 'server.example.com',
    ['upgrade'] = 'websocket',
    ['connection'] = 'Upgrade',
    ['sec-websocket-key'] = 'dGhlIHNhbXBsZSBub25jZQ==',
    ['sec-websocket-protocol'] = 'chat, superchat',
    ['sec-websocket-version'] = '13',
    ['origin'] = 'http://example.com',
}

local test = tap.test('The handshake module')
test:plan(2)


test:test(
    'RFC 1.3: calculate the correct accept sum',
    function(test)
        test:plan(1)
        local sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ=="
        local accept = handshake.sec_websocket_accept(sec_websocket_key)
        test:is(accept,"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
end)

test:test(
    'generates correct upgrade response',
    function(test)
        test:plan(2)
        local response = handshake.accept_upgrade(request)

        test:is(type(response),'string')
        test:ok(response:match('^HTTP/1.1 101 Switching Protocols\r\n'))
end)
