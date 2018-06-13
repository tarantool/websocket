# Library to build simple websocket server.

## Restrictions

  - no http features (just simple websocket handshake logic)
  - no websocket extensions
  - no client

## Example

``` lua
#!/usr/bin/env tarantool

local log = require('log')
local fiber = require('fiber')
local wsserver = require('websocket')
local frame = require('websocket.frame')

-- create server socket
local wsd = wsserver.new('127.0.0.1', 8080)

-- logging handshake or you can return modified or custom handshake response
wsd:set_proxy_handshake(function(self, request, response)
    log.info(request)
    log.info(response)
    return response
end)

-- listen
wsd:listen() -- makes underground fiber

-- wait fo new peers
if wsd:is_listen() then
    local channel = wsd:accept() -- returns ready to use websocket channel
    -- makes underground fiber to read and decode websocket frames

    if channel ~= nil then
        local message = channel:read() -- returns websocket frame
        log.info(message)
        if message == nil then         -- eof
            log.info('Channel closed')
        elseif not channel:write(message) then -- write websocket frame back
            log.info('Channel closed#2')
        end

        if not channel:is_closed() then  -- check is channel alive
            channel:write({op=frame.TEXT,
                           data='{"key":value}'}) -- send custom data, ignore status

            channel:shutdown(1000, 'Goodbye') -- graceful close channel
            -- channel:close() -- or immediately close
            local switch = 0
            while not channel:is_closed() do -- with for graceful shutdown
                fiber.yield()
                switch = switch + 1
                if switch > 20 then
                    channel:close() -- ok, no more time
                end
            end
        end
    else
        log.info('Server is closed')
    end
end

if wsd:is_listen() then -- check if server listen
    wsd:close() -- close server, no more clients
end
```

## API

## wsserver

- [`new(host, port [,options])`](#)
- [`listen()`](#)
- [`is_listen()`](#)
- [`set_proxy_handshake(function(request, response))`](#)
- [`accept([timeout])`](#)
- [`close()`](#)

## wspeer

- [`read(timeout)`](#)
- [`write(frame, timeout)`](#)
- [`shutdown(timeout)`](#)
- [`close()`](#)
- [`is_closed()`](#)

## Startup

### `websocket.new([host[, port[, options]]])`

Create new `wsserver` object with params

  - `host` default '127.0.0.1'
  - `port` default 8080
  - `options` default { `backlog` = 1024}

**Returns** `wsserver` object

## wsserver

### `wsserver:listen()`

Starts to listen incoming connections.

**Side effects:**

  - Make underground fiber to listen and accept incoming peers.
  - Make http websocket handshake fiber, when new peer accepted.

**Warning!!!**

Peer discarded after handshake if no pending `wsserver:accept()`.

Throw error if `wsserver` already listen.

If error occurs during startup, check it using `wsserver:is_listen()` and
logs for error message.

### `wsserver:is_listen()`

**Returns** whether server is running

### `wsserver:set_proxy_handshake(function(request, response))`

Set callback function to control handshake process. It is possible to return modified
or custom response. Returned object field `code` is used to determine success connection upgrading.

If code == '101' than new `wspeer` will be returned.

Request format is:

``` lua
{
    method='GET', -- or any other
    uri='ws://example.local/path/with/params?key=value',
    version='HTTP/1.1',
    headers={
        '<lowcased header name>' = 'value'
    }
}
```

Response format is:

``` lua
{
    version='HTTP/1.1',
    code='101', -- or any other
    status='Switching Protocols',
    headers={
        '<header name with case sensitivity>' = 'value'
    }
}
```

### `wsserver:set_http_read_timeout(timeout)`

Set http read timeout. Used only for handshake process.

### `wsserver:set_http_write_timeout(timeout)`

Set http write timeout. Used only for handshake process.

### `wsserver:accept([timeout])`

Accept new ready to use connection.

**Returns:**

  - `wspeer` object if success.
  - `nil` if timeout occurs.

### `wsserver:close()`

Close server.

**Side effects:**

  - Stop listening fiber.

**Warning**

Already established `wspeer` connections are kept alive.

## wspeer

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
  - nil if error or timeout

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

   - raw bytes size written
   - nil if error

### `wspeer:shutdown(code, reason, timeout)`

Graceful shutdown

**Returns:**

    - `true` graceful shutdown starts. Wait for `wspeer` closed state. No need to call `wspeer:close`.
    - `false` if graceful shutdown impossible. Call `wspeer:close` immediately.

### `wspeer:close()`

Immediately close `wspeer` connection. Any pending data discarded.

### `wspeer:is_closed()`

**Returns** whether `wspeer` connection is closed
