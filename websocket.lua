#!/usr/bin/env tarantool

local errno = require('errno')
local socket = require('socket')
local fiber = require('fiber')
local log = require('log')

local handshake = require('websocket.handshake')
local frame = require('websocket.frame')

local wspeer = {
    __newindex = function(table, key, value)
        error("Attempt to modify read-only wspeer properties")
    end,
}

wspeer.__index = wspeer

function wspeer.new(peer, handshake_packets)
    local self = setmetatable({}, wspeer)

    rawset(self, 'peer', peer)
    rawset(self, 'handshake', handshake_packets)
    rawset(self, 'close_sended', false)
    rawset(self, 'inside', fiber.channel())
    rawset(self, 'rawread_fiber', fiber.create(wspeer.rawread, self))

    return self
end

function wspeer.rawread(self)
    local PING_FREQ = 15
    local ping_sended = false
    local last_ping_sended = fiber.time()

    while true do
        if not ping_sended then
            if fiber.time() - last_ping_sended > PING_FREQ then
                -- log.info('Websocket peer sending ping request')
                last_ping_sended = fiber.time()
                local packet = frame.encode('', frame.PING, false, true)
                self.peer:write(packet, nil)
                ping_sended = true
            end
        end

        local ready = self.peer:readable(PING_FREQ)
        if not ready and ping_sended then
            -- log.info('Websocket peer ping timeout')
            break
        end

        local tuple = frame.decode_from(self.peer)
        if tuple == nil then
            -- eof
            break
        end

        if tuple.opcode == frame.PING then
            --log.info('Websocket peer ping request')
            local packet = frame.encode(tuple.data, frame.PONG, false, true)
            self.peer:write(packet)
        elseif tuple.opcode == frame.PONG then
            --log.info('Websocket peer pong response')
            ping_sended = false
        elseif tuple.opcode == frame.CLOSE then
            if not self.close_sended then
                local packet = frame.encode(tuple.data, frame.CLOSE, false, true)
                self.peer:write(packet)
            end
            break
        else
            if self.inside:has_readers() then
                self.inside:put(tuple)
            else
                log.info('Websocket peer discards packet because no active readers')
            end
        end
    end

    self.peer:shutdown(socket.SHUT_RDWR)
    self.peer:close()
    rawset(self, 'peer', nil)

    --log.info('Websocket peer exit read loop')
end

function wspeer.write(self, tuple, timeout)
    -- channel is closed
    if not self.peer then
        return nil
    end

    local message = tuple.data
    local packet = frame.encode(message, tuple.op, false, tuple.fin)

    return self.peer:write(packet, timeout)
end

function wspeer.read(self, timeout)
    return self.inside:get(timeout)
end

function wspeer.shutdown(self, code, reason, timeout)
    code = code or 1000
    local message = frame.encode(frame.encode_close(code, reason), frame.CLOSE,
                                 false, true)
    if self.peer:write(message, timeout) ~= nil then
        rawset(self, 'close_sended', true)
    end
end

function wspeer.close(self)
    self.rawread_fiber:cancel()
    self.peer:close()
    rawset(self, 'peer', nil)
end

function wspeer.is_closed(self)
    return self.peer == nil
end

local wsserver = {

    __newindex = function(table, key, value)
        error("Attempt to modify read-only wsserver properties")
    end,
}

wsserver.__index = wsserver

function wsserver.new(host, port, options)
    local self = setmetatable({}, wsserver)
    host = host or '127.0.0.1'
    port = port or 8080
    options = options or {}

    if not options.backlog then
        options.backlog = 1024
    end

    rawset(self, 'host', host)
    rawset(self, 'port', port)

    rawset(self, 'options', options)

    rawset(self, 'listening', false)
    rawset(self, 'ms', nil)

    return self
end

function wsserver.listen(self)
    if self.listening then
        error('Websocket server %s:%d already listen',
              self.host, self.port)
    end

    rawset(self, 'listening', true)
    rawset(self, 'accept_channel', fiber.channel())
    rawset(self, 'listen_fiber', fiber.create(wsserver.rawlisten, self))
end

function wsserver.close(self)
    if not self.listening then
        error('Websocket server %s:%d already closed',
              self.host, self.port)
    end

    -- there is no fiber if error during binding socket
    if self.listen_fiber then
        self.listen_fiber:cancel()
        rawset(self, 'listen_fiber', nil)
    end

    self.ms:close()
    rawset(self, 'ms', nil)

    self.accept_channel:close()
    rawset(self, 'accept_channel', nil)

    rawset(self, 'listening', false)
end

function wsserver.is_listen(self)
    return self.listening
end

function wsserver.accept(self, timeout)
    if not self.listening then
        error('Websocket server %s:%d is not listen',
              self.host, self.port)
    end

    return self.accept_channel:get(timeout)
end

function wsserver.set_proxy_handshake(self, proxy)
    rawset(self, 'proxy_handshake', proxy)
end

function wsserver.rawlisten(self)
    rawset(self, 'ms', socket('PF_INET', 'SOCK_STREAM', 'tcp'))
    if self.ms == nil then
        error('Websocket server could not create socket %s:%d error %s',
              self.host, self.port, errno.strerror())
    end
    self.ms:setsockopt('SOL_SOCKET', 'SO_REUSEADDR', true)
    self.ms:nonblock(true)
    if not self.ms:bind(self.host, self.port) then
        log.info('Websocket server bind %s:%d error "%s"', self.host, self.port,
                 self.ms:error())
        self:close()
        return
    end
    if not self.ms:listen(self.options.backlog) then
        log.info('Websocket server listen %s:%d with backlog error "%s"',
                 self.host, self.port,
                 self.ms:error())

        self:close()
        return
    end

    while self.ms:readable() do
        local peer = self.ms:accept()
        if peer ~= nil then
            peer:nonblock(true)

            fiber.create(wsserver.handshake_loop, self, peer)
        end
    end

    self:close()
    -- not reached
end

function wsserver.handshake_loop(self, peer)
    local HTTPSTATE = {
        REQUEST = 1,
        HEADERS = 2,
    }

    local httpstate = HTTPSTATE.REQUEST

    local success = false
    local request = {
        method='',
        uri='',
        version='',
        headers={}
    }
    local response = {
        version='',
        code='',
        status='',
        headers=''
    }
    while true do
        local line = peer:read({delimiter='\r\n'})
        if line == nil then
            --log.info('Websocket server connection closed while handshake')
            break
        elseif #line == 0 then
            --log.info('Websocket server eof from peer while handshake')
            break
        end
        if httpstate == HTTPSTATE.REQUEST then
            -- Method SP Request-URI SP HTTP-Version CRLF
            _, _, request.method, request.uri, request.version =
                line:find('^([^%s]+)%s([^%s]+)%s([^%s]+)')
            httpstate = HTTPSTATE.HEADERS
        elseif httpstate == HTTPSTATE.HEADERS then
            if line == '\r\n' then
                local valid, err = handshake.validate_request(request)
                if not valid then
                    peer:write(err)
                    break
                end
                response = handshake.accept_upgrade(request)
                if self.proxy_handshake then
                    response = self:proxy_handshake(request, response)
                end
                local packet = handshake.reduce_response(response)

                if peer:write(packet) == nil then
                    --log.info('Websocket server could not write while handshake')
                    break
                end

                success = (tonumber(response.code) == 101)
                break
            else
                local _, _, name, value = line:find('^([^:]+)%s*:%s*(.+)')
                if name == nil or value == nil then
                    --log.info('Websocket server malformed handshake packet')
                    break
                end
                request.headers[name:strip():lower()] = value:strip()
            end
        end
    end

    if success then
        if self.accept_channel:has_readers() then
            local newpeer = wspeer.new(peer, {request=request,
                                              response=response})
            self.accept_channel:put(newpeer)
        end
    else
        --log.info('Websocket peer closed while handshake')
        peer:shutdown(socket.SHUT_RDWR)
        peer:close()
    end
end

return wsserver
