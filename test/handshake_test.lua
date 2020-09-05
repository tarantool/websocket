#!/usr/bin/env tarantool

local t = require('luatest')
local g = t.group('websocket.handshake')

local handshake = require('websocket.handshake')

g.test_checksum = function()
   local sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ=="
   local accept = handshake.sec_websocket_accept(sec_websocket_key)
   t.assert_equals(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
end

g.test_accept = function()
   local request = {}
   request.headers = {
      ['host'] = 'server.example.com',
      ['upgrade'] = 'websocket',
      ['connection'] = 'Upgrade',
      ['sec-websocket-key'] = 'dGhlIHNhbXBsZSBub25jZQ==',
      ['sec-websocket-protocol'] = 'chat, superchat',
      ['sec-websocket-version'] = '13',
      ['origin'] = 'http://example.com',
   }
   local response = handshake.accept_upgrade(request)

   t.assert_equals(type(response), 'table')
   t.assert_equals(response.version, 'HTTP/1.1')
   t.assert_equals(response.code, '101')
end
