- [Library to use websocket channels.](#library-to-use-websocket-channels)
  * [Installation](#installation)
    + [master](#master)
  * [Example](#example)
    + [Client to echo](#client-to-echo)
    + [Client to exchange ticker](#client-to-exchange-ticker)
    + [Server with ssl](#server-with-ssl)
  * [Tests](#tests)
    + [Server](#server)
    + [Client](#client)
  * [SSL API](#ssl-api)
    + [`ssl.methods`](#sslmethods)
    + [`ssl.ctx(method)`](#sslctxmethod)
    + [`ssl.ctx_use_private_key_file(ctx, filepath)`](#sslctx_use_private_key_filectx-filepath)
    + [`ssl.ctx_use_certificate_file(ctx, filepath)`](#sslctx_use_certificate_filectx-filepath)
  * [API](#api)
    + [`websocket.server(url, handler, options)`](#websocketserverurl-handler-options)
    + [`websocket.connect(url, request, options)`](#websocketconnecturl-request-options)
    + [`websocket.bind(url, options)`](#websocketbindurl-options)
    + [`websocket.new(peer, ping_freq, is_client, is_handshaked, client_request)`](#websocketnewpeer-ping_freq-is_client-is_handshaked-client_request)
    + [`wspeer:read([timeout])`](#wspeerreadtimeout)
    + [`wspeer:write(frame[, timeout])`](#wspeerwriteframe-timeout)
    + [`wspeer:shutdown(code, reason[, timeout])`](#wspeershutdowncode-reason-timeout)
    + [`wspeer:close()`](#wspeerclose)

# Library to use websocket channels.

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
virtualenv test # -p python2
cd test
source bin/activate
pip install autobahntestsuite
wstest -m fuzzingclient -s fuzzyclient.json
```

Open reports `open reports/servers/index.html`

### Client

Load test server

``` shell
# python2
virtualenv test # -p python2
cd test
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

**Returns:**

   - wspeer (socket like object)

### `websocket.bind(url, options)`

   - `url` url for serving (e.g. `wss://127.0.0.1:8443/endpoint`)
   - `options`
     - `timeout` - accept timeout
     - `ping_frequency` - ping frequency in seconds
     - `ctx` - ssl context

**Returns:**

   - server socket


### `websocket.new(peer, ping_freq, is_client, is_handshaked, client_request)`

   - `peer` tarantool socket object
   - `ping_freq` ping frequency in seconds
   - `is_client` is client side
   - `is_handshaked` whether socket already http handshaked or not
   - `client_request` http client handshake request

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
