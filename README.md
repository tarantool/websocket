- [Library to build simple websocket server.](#library-to-build-simple-websocket-server)
  * [Restrictions](#restrictions)
  * [Tests](#tests)
  * [Example](#example)
  * [API](#api)
    + [`websocket.new(socket, ping_frequency, handshaked)`](#websocketnewsocket-ping_frequency-handshaked)
    + [`wspeer:read([timeout])`](#wspeerreadtimeout)
    + [`wspeer:write(frame[, timeout])`](#wspeerwriteframe-timeout)
    + [`wspeer:shutdown(code, reason[, timeout])`](#wspeershutdowncode-reason-timeout)
    + [`wspeer:close()`](#wspeerclose)

# Library to build simple websocket server.

## Restrictions

  - no http features (just simple websocket handshake logic)
  - no websocket extensions
  - no client

## Tests


``` shell
# python2
virtualenv test # -p python2
cd test
source bin/activate
pip install autobahntestsuite
wstest -m fuzzingclient -s fuzzingclient.json
```

## Example

``` lua
#!/usr/bin/env tarantool

local log = require('log')
local socket = require('socket')
local websocket = require('websocket')
local json = require('json')

socket.tcp_server(
    '0.0.0.0',
    8080,
    function(sock)
        local wspeer = websocket.new(sock)

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
end)
```

## API

### `websocket.new(socket, ping_frequency, handshaked)`

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
