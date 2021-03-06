#!/usr/bin/env tarantool

local websocket = require('websocket')
local ssl = require('websocket.ssl')
local log = require('log')
local fiber = require('fiber')
local fio = require('fio')

local t = require('luatest')
local g = t.group('websocket.self.echo')

local script_dir = debug.sourcedir()

local function is_table_eq(t1,t2)
    for k1,v1 in pairs(t1) do
        local v2 = t2[k1]
        if v1 ~= v2 then return false end
    end
    for k2,v2 in pairs(t2) do
        local v1 = t1[k2]
        if v1 ~= v2 then return false end
    end
    return true
end

local function make_server_client(url, sslon, max_receive_payload)
    local client1 = nil

    local ctx = nil
    if sslon then
        ctx = ssl.ctx()

        t.assert(ctx ~= nil)

        if not ssl.ctx_use_private_key_file(ctx, fio.pathjoin(script_dir, 'certificate.pem')) then
            log.info('Error private key')
            return
        end

        if not ssl.ctx_use_certificate_file(ctx, fio.pathjoin(script_dir, 'certificate.pem')) then
            log.info('Error certificate')
            return
        end
    end

    local server, err = websocket.bind(url, {ctx=ctx, max_receive_payload=max_receive_payload})
    if not server then
        log.info(err)
        return
    end
    if not server:listen(1024) then
        log.info(server:error())
        return
    end

    local client2 = websocket.connect(url, nil, {max_receive_payload=max_receive_payload})
    client1 = server:accept()

    server:close()
    return client1, client2
end

g.test_basic = function()
   local urls = {
                  {url='ws://127.0.0.1:8080/asdf'},
                  {url='wss://127.0.0.1:8443/asdf', ssl=true}
              }

              for _, url in ipairs(urls) do
                  local client1, client2 = make_server_client(url.url, url.ssl)

                  local message = {opcode=websocket.TEXT, data='ASDF', fin=true, rsv=0}

                  client2:read(0.1) -- init handshake from client
                  client1:write(message, 0.1) -- approve and write

                  if url.ssl then
                      client2:read(0.1)
                      client1:write(message, 0.1)
                      client2:read(0.1)
                      client1:write(message, 0.1)
                  end

                  local received, err = client2:read(0.1) -- read from client

                  t.assert(is_table_eq(message, received), 'Basic')

                  client1:shutdown(1000, 'OK', 0.1)
                  client1:close()
                  client2:shutdown(1000, 'OK', 0.1)
                  client2:close()
              end
end

g.test_basic_echo = function()
   local urls = {
      {url='ws://127.0.0.1:8080/asdf'},
      {url='wss://127.0.0.1:8443/asdf', ssl=true}
   }

   for _, url in ipairs(urls) do
      local client1, client2 = make_server_client(url.url, url.ssl)

      local message = {opcode=websocket.TEXT, data='ASDF', fin=true, rsv=0}

      local stop = false
      local worker = fiber.create(function ()
            while client1:read() and not stop do
               client1:write(message)
            end
      end)

      client2:write('send me test')
      local received = client2:read()
      t.assert(is_table_eq(message, received), "Sended and received different")

      message = {opcode=websocket.BINARY, data='\xFF\xDE\xBE', fin=true, rsv=0}
      client2:write('send me binary')
      local received = client2:read()
      t.assert(is_table_eq(message, received), "Sended and received different")

      stop = true
      fiber.sleep(0)

      client2:shutdown(1000, 'OK', 0.1)
      client2:close()

      client1:shutdown(1000, 'OK', 1)
      client1:close()
   end
end

g.test_max_payload = function()
    local urls = {
       {url='ws://127.0.0.1:8080/asdf'},
       {url='wss://127.0.0.1:8443/asdf', ssl=true}
    }
 
    for _, url in ipairs(urls) do
       local client1, client2 = make_server_client(url.url, url.ssl, 65)

       local message = {opcode=websocket.TEXT, data=('x'):rep(90), fin=true, rsv=0}
       local stop = false
       local worker = fiber.create(function ()
             while client1:read() and not stop do
                client1:write(message)
             end
       end)
 
       client2:write('send me test')
       t.assert_error_msg_contains('limit', client2.read, client2)
       client2:close()
       client1:close()
    end
 end