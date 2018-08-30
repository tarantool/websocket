#!/usr/bin/env tarantool

local tap = require('tap')
local websocket = require('websocket')
local ssl = require('websocket.ssl')
local log = require('log')
local fiber = require('fiber')

local test = tap.test('Websocket self testing server/client')

test:plan(2)

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

local function make_server_client(url, sslon)
    local client1 = nil

    local ctx = nil
    if sslon then
        ctx = ssl.ctx()
        if not ssl.ctx_use_private_key_file(ctx, './certificate.pem') then
            log.info('Error private key')
            return
        end

        if not ssl.ctx_use_certificate_file(ctx, './certificate.pem') then
            log.info('Error certificate')
            return
        end
    end

    local server, err = websocket.bind(url, {ctx=ctx})
    if not server then
        log.info(err)
        return
    end
    if not server:listen(1024) then
        log.info(server:error())
        return
    end

    local client2 = websocket.connect(url)
    client1 = server:accept()

    server:close()
    return client1, client2
end

test:test('Basic',
          function (test)
              test:plan(2)

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

                  test:ok(is_table_eq(message, received), 'Basic')

                  client1:shutdown(1000, 'OK', 0.1)
                  client1:close()
                  client2:shutdown(1000, 'OK', 0.1)
                  client2:close()
              end
end)

test:test('Echo',
          function (test)
              test:plan(2)

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

                  client2:write('aaa')
                  local received = client2:read()

                  test:ok(is_table_eq(message, received))

                  stop = true
                  fiber.sleep(0)

                  client2:shutdown(1000, 'OK', 0.1)
                  client2:close()

                  client1:shutdown(1000, 'OK', 1)
                  client1:close()
              end
end)

os.exit(test:check() and 0 or 1)
