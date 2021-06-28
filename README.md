- [Library to use websocket channels](#library-to-use-websocket-channels)
  - [Use cases](#use-cases)
  - [Installation](#installation)
    - [master](#master)
  - [Example](#example)
    - [Client to echo](#client-to-echo)
    - [Client to exchange ticker](#client-to-exchange-ticker)
    - [Echo server](#echo-server)
    - [Send a message to all connected clients](#send-a-message-to-all-connected-clients)
    - [Server with ssl](#server-with-ssl)
  - [Tests](#tests)
    - [Server](#server)
    - [Client](#client)
  - [SSL API](#ssl-api)
    - [`ssl.methods`](#sslmethods)
    - [`ssl.ctx(method)`](#sslctxmethod)
    - [`ssl.ctx_use_private_key_file(ctx, filepath)`](#sslctxuseprivatekeyfilectx-filepath)
    - [`ssl.ctx_use_certificate_file(ctx, filepath)`](#sslctxusecertificatefilectx-filepath)
  - [API](#api)
    - [`websocket.server(url, handler, options)`](#websocketserverurl-handler-options)
    - [`websocket.connect(url, request, options)`](#websocketconnecturl-request-options)
    - [`websocket.bind(url, options)`](#websocketbindurl-options)
    - [`websocket.new(peer, ping_freq, is_client, is_handshaked, client_request)`](#websocketnewpeer-pingfreq-isclient-ishandshaked-clientrequest)
    - [`wspeer:read([timeout])`](#wspeerreadtimeout)
    - [`wspeer:write(frame[, timeout])`](#wspeerwriteframe-timeout)
    - [`wspeer:shutdown(code, reason[, timeout])`](#wspeershutdowncode-reason-timeout)
    - [`wspeer:close()`](#wspeerclose)

# Library to use websocket channels

## Use cases

The advantages of this library are:

* persistent connection (no need to reconnect)
* full-duplex data transmission

For example, it can help when you want to:

* make a chat
* send financial quotes
* write a backend for a rich internet application
* send push-notifications to your users

## Installation

### master

``` shell
tarantoolctl rocks install https://github.com/tarantool/websocket/raw/master/websocket-scm-1.rockspec
```

## Example

### Client to echo

`./example/client.lua`

``` lua
#!/usr/bin/env tarantool

local log = require('log')
local websocket = require('websocket')
local json = require('json')

local ws, err = websocket.connect('wss://echo.websocket.org',
                                  nil, {timeout=3})

if not ws then
    log.info(err)
    return
end

ws:write('HELLO')
local response = ws:read()
log.info(response)
assert(response.data == 'HELLO')
```

### Client to exchange ticker

`./example/gdax.lua`

``` lua
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

local packet = ws:read()
while packet ~= nil do
    log.info(packet)
    packet = ws:read()
end
```

### Echo server

``` lua
#!/usr/bin/env tarantool

local ws = require('websocket')

ws.server('ws://0.0.0.0:8080', function (ws_peer)
    while true do
        local message, err = ws_peer:read()
        if not message or message.opcode == nil then
            break
        end
	ws_peer:write(message.data)
    end
end)
```

### Send a message to all connected clients

``` lua
#!/usr/bin/env tarantool

local ws = require('websocket')
local json = require('json')
local ws_peers = {}

ws.server('ws://0.0.0.0:8080', function (ws_peer)
    local id = ws_peer.peer:fd()
    table.insert(ws_peers, id, ws_peer) -- save after connection

    while true do
        local message, err = ws_peer:read()
        if not message or message.opcode == nil then
            break
        end
    end

    ws_peers[id] = nil -- remove after disconnection
end)

return {
    push = function (data)
        for _, ws_peer in pairs(ws_peers) do
            ws_peer:write(json.encode(data)) -- send message to all subscribers
        end
    end
}
```

### Server with ssl

``` lua
#!/usr/bin/env tarantool

local log = require('log')
local ssl = require('websocket.ssl')
local websocket = require('websocket')
local json = require('json')

local ctx = ssl.ctx()
if not ssl.ctx_use_private_key_file(ctx, './certificate.pem') then
    log.info('Error private key')
    return
end

if not ssl.ctx_use_certificate_file(ctx, './certificate.pem') then
    log.info('Error certificate')
    return
end

websocket.server(
    'wss://0.0.0.0:8443/',
    function(wspeer)
        while true do
            local message, err = wspeer:read()
            if message then
                if message.opcode == nil then
                    log.info('Normal close')
                    break
                end
                log.info('echo ' .. json.encode(message))
                wspeer:write(message)
            else
                log.info('Exception close ' .. tostring(err))
                if wspeer:error() then
                    log.info('Socket error '..wspeer:error())
                end
                break
            end
        end
    end,
    {
        ping_timeout = 120,
        ctx = ctx
    }
)
```

## Tests

### Server

Load echo server

``` shell
./example/echo_server.lua
```

``` shell
# python2
virtualenv ptest # -p python2
cp test/fuzzyclient.json ptest/
cd ptest
source bin/activate
pip install autobahntestsuite
wstest -m fuzzingclient -s fuzzyclient.json
```

Open reports `open reports/servers/index.html`

### Client

Load test server

``` shell
# python2
virtualenv ptest # -p python2
cp test/fuzzyserver.json ptest/
cd ptest
source bin/activate
pip install autobahntestsuite
wstest -m fuzzingserver -s fuzzyserver.json
```

Start client

``` shell
./example/echo_client.lua
```

Open reports `open reports/clients/index.html`

## SSL API

``` lua
local ssl = require('websocket.ssl')
```

### `ssl.methods`

### `ssl.ctx(method)`

### `ssl.ctx_use_private_key_file(ctx, filepath)`

### `ssl.ctx_use_certificate_file(ctx, filepath)`

## API

### `websocket.server(url, handler, options)`

   - `url` url for serving (e.g. `wss://127.0.0.1:8443/endpoint`)
   - `handler` callback with one param `wspeer` (e.g. `function (wspeer) wspeer:read() end`)
   - `options`
     - `timeout` - accept timeout
     - `ping_frequency` - ping frequency in seconds
     - `ctx` - ssl context
     - `max_receive_payload` — payload size limit

**Returns:**

   - server socket

### `websocket.connect(url, request, options)`

   - `url` url for connect (e.g. `ws://echo.websocket.org`)
   - `request`
     - `method`
     - `path`
     - `version`
     - `headers` dict of headers
   - `options`
     - `timeout` connect timeout
     - `ctx` ssl context
     - `max_receive_payload` — payload size limit

**Returns:**

   - wspeer (socket like object)

### `websocket.bind(url, options)`

   - `url` url for serving (e.g. `wss://127.0.0.1:8443/endpoint`)
   - `options`
     - `timeout` - accept timeout
     - `ping_frequency` - ping frequency in seconds
     - `ctx` - ssl context
     - `max_receive_payload` — payload size limit

**Returns:**

   - server socket


### `websocket.new(peer, ping_freq, is_client, is_handshaked, client_request, max_receive_payload)`

   - `peer` tarantool socket object
   - `ping_freq` ping frequency in seconds
   - `is_client` is client side
   - `is_handshaked` whether socket already http handshaked or not
   - `client_request` http client handshake request
   - `max_receive_payload` payload size limit

**Returns:**

   - wspeer (socket like object)

### `wspeer:read([timeout])`

**Returns:**

  - data frame in following format
``` lua
{
    "opcode":frame.TEXT|frame.BINARY,
    "fin":true|false,
    "data":string
}
```
  - nil, error if error or timeout

### `wspeer:write(frame[, timeout])`

Send data frame. Frame structure the same as returned from `wspeer:read`:

``` lua
{
    "opcode":frame.TEXT|frame.BINARY,
    "fin":true|false,
    "data":string
}
```

**Returns:**

   - frame size written
   - nil if error

### `wspeer:shutdown(code, reason[, timeout])`

Graceful shutdown

**Returns:**

  - `true` graceful shutdown.
  - `false`, err - if error

### `wspeer:close()`

Immediately close `wspeer` connection. Any pending data discarded.
