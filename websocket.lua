#!/usr/bin/env tarantool

local errno = require('errno')
local socket = require('socket')
local fiber = require('fiber')
local log = require('log')

local clock = require('clock')

local handshake = require('websocket.handshake')
local frame = require('websocket.frame')

--[[
    WebSocket Peer
]]
local wspeer = {
    __newindex = function(table, key, value)
        error("Attempt to modify read-only wspeer properties")
    end,
}

wspeer.__index = wspeer

function wspeer.new(peer, handshake_packets, ping_freq)
    ping_freq = ping_freq or 15

    local self = setmetatable({}, wspeer)

    rawset(self, 'peer', peer)
    local peeraddr = peer:peer()
    if peeraddr ~= nil then
        rawset(self, 'host', peeraddr['host'])
        rawset(self, 'port', peeraddr['port'])
    end
    rawset(self, 'handshake', handshake_packets)
    rawset(self, 'ping_freq', ping_freq)
    rawset(self, 'close_sended', false)
    rawset(self, 'inside', fiber.channel())
    rawset(self, 'rawread_fiber', fiber.create(wspeer.rawread, self))
    rawset(self, 'last_opcode', nil)

    return self
end

function wspeer.rawread(self)
    local status, err = pcall(function ()
            local ping_sended = false
            local last_ping_sended = fiber.time()

            while true do
                if not ping_sended then
                    if clock.time() - last_ping_sended > self.ping_freq then
                        log.info('Websocket peer %s:%d sending ping request',
                                 self['host'],
                                 self['port'])
                        last_ping_sended = fiber.time()
                        local packet = frame.encode('', frame.PING, false, true)
                        self.peer:write(packet)
                        ping_sended = true
                    end
                end

                local tuple = frame.decode_from(self.peer, self.ping_freq
                                                    - (clock.time() - last_ping_sended))
                if tuple == nil and self.peer:errno() == errno.ETIMEDOUT then
                    if ping_sended then
                        log.info('Websocket peer %s:%d ping timed out',
                                 self['host'],
                                 self['port'])

                        local packet = frame.encode('', frame.CLOSE, false, true)
                        self.peer:write(packet)
                        rawset(self, 'close_sended', true)
                        log.debug('Websocket peer close sended')
                        break
                    end
                elseif tuple == nil then
                    log.info('Websocket peer %s:%d hard error',
                             self['host'],
                             self['port'])

                    local packet = frame.encode('', frame.CLOSE, false, true)
                    self.peer:write(packet)
                    rawset(self, 'close_sended', true)
                    log.debug('Websocket peer close sended')
                    break
                end

                if tuple.opcode == nil then
                    -- eof
                    log.info('Websocket peer %s:%d read eof',
                             self['host'],
                             self['port'])
                    break
                end

                -- Validation
                -- invalid frame
                if tuple.opcode ~= frame.CONTINUATION
                    and tuple.opcode ~= frame.TEXT and tuple.opcode ~= frame.BINARY
                    and tuple.opcode ~= frame.CLOSE
                    and tuple.opcode ~= frame.PING and tuple.opcode ~= frame.PONG
                then
                    log.info('Websocket peer frame opcode is invalid: %d', tuple.opcode)
                    local packet = frame.encode('', frame.CLOSE, false, true)
                    self.peer:write(packet)
                    rawset(self, 'close_sended', true)
                    log.debug('Websocket peer close sended')
                    break
                end

                -- invalid control frame length
                if tuple.opcode ~= frame.CONTINUATION
                    and tuple.opcode ~= frame.TEXT and tuple.opcode ~= frame.BINARY
                    and #tuple.data > 125
                then
                    log.info('Websocket peer control frame length greater than 125')
                    local packet = frame.encode('', frame.CLOSE, false, true)
                    self.peer:write(packet)
                    rawset(self, 'close_sended', true)
                    log.debug('Websocket peer close sended')
                    break
                end

                -- invalid rsv
                if tuple.rsv ~= 0 then
                    log.info('Websocket peer frame rsv invalid')
                    local packet = frame.encode('', frame.CLOSE, false, true)
                    self.peer:write(packet)
                    rawset(self, 'close_sended', true)
                    log.debug('Websocket peer close sended')
                    break
                end

                -- control message can not be fragmented
                if tuple.opcode ~= frame.CONTINUATION
                    and tuple.opcode ~= frame.TEXT and tuple.opcode ~= frame.BINARY
                    and not tuple.fin
                then
                      log.info('Websocket peer fragmented control frame not allowed')
                      local packet = frame.encode('', frame.CLOSE, false, true)
                      self.peer:write(packet)
                      rawset(self, 'close_sended', true)
                      log.debug('Websocket peer close sended')
                      break
                end

                -- fragmented messages opcode == 0
                if tuple.opcode == frame.TEXT or tuple.opcode == frame.BINARY then
                    if self.last_opcode ~= nil then
                        log.info('Websocket peer fragmented frame should be continuation')
                        local packet = frame.encode('', frame.CLOSE, false, true)
                        self.peer:write(packet)
                        rawset(self, 'close_sended', true)
                        log.debug('Websocket peer close sended')
                        break
                    end
                end

                -- continuation frame without head frame
                if tuple.opcode == frame.CONTINUATION then
                    if self.last_opcode == nil then
                        log.info('Websocket peer continuation frame without head frame')
                        local packet = frame.encode('', frame.CLOSE, false, true)
                        self.peer:write(packet)
                        rawset(self, 'close_sended', true)
                        log.debug('Websocket peer close sended')
                        break
                    end
                end

                -- utf8 invalid simple case
                if tuple.opcode == frame.TEXT then
                    if utf8.len(tuple.data) == nil then
                        log.info('Websocket peer utf8 data invalid')
                        local packet = frame.encode('', frame.CLOSE, false, true)
                        self.peer:write(packet)
                        rawset(self, 'close_sended', true)
                        log.debug('Websocket peer close sended')
                        break
                    end
                end

                -- save/reset fragmented stream
                if tuple.opcode == frame.TEXT or tuple.opcode == frame.BINARY then
                    if self.last_opcode == nil then
                        if not tuple.fin then
                            rawset(self, 'last_opcode', tuple.opcode)
                        end
                    end
                elseif tuple.opcode == frame.CONTINUATION then
                    if tuple.fin then
                        rawset(self, 'last_opcode', nil)
                    end
                end

                -- Buiseness
                if tuple.opcode == frame.PING then
                    log.debug('Websocket peer %s:%d ping request',
                              self['host'],
                              self['port'])
                    local packet = frame.encode(tuple.data, frame.PONG, false, true)
                    self.peer:write(packet)
                elseif tuple.opcode == frame.PONG then
                    log.debug('Websocket peer %s:%d pong response',
                              self['host'],
                              self['port'])
                    ping_sended = false
                elseif tuple.opcode == frame.CLOSE then
                    log.debug('Websocket peer close received')
                    if not self.close_sended then
                        local packet = frame.encode('', frame.CLOSE, false, true)
                        self.peer:write(packet)
                        rawset(self, 'close_sended', true)
                        log.debug('Websocket peer close sended')
                    end
                    break
                else
                    self.inside:put(tuple)
                end
            end

            log.info('Websocket peer %s:%d exit read loop',
                     self['host'],
                     self['port'])

            self.peer:shutdown(socket.SHUT_RDWR) -- ignore result, anyway exit
    end)

    if not status then
        log.info(err)
    end

    if self.peer ~= nil then
        self.peer:close()  -- ignore result, anyway exit
        rawset(self, 'peer', nil)
    end

    if self.inside ~= nil then
        self.inside:close()
    end
end

function wspeer.write(self, tuple, timeout)
    -- channel is closed
    if not self.peer then
        return nil, "Peer is closed"
    end

    if type(tuple) == 'string' then
        local message = tuple
        tuple = {
            opcode = frame.TEXT,
            fin = true,
            data = message
        }
    end

    if tuple.opcode ~= frame.CONTINUATION and
        tuple.opcode ~= frame.TEXT and tuple.opcode ~= frame.BINARY
    then
        return nil, 'You can send only text or binary frame'
    end

    local message = tuple.data
    local packet = frame.encode(message, tuple.opcode, false, tuple.fin)

    local rc = self.peer:write(packet, timeout)
    if rc == nil then
        return rc, self.peer:error()
    end
    return rc
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
        return true
    end
    return false
end

function wspeer.close(self)
    if self.rawread_fiber ~= nil then
        self.rawread_fiber:cancel()
        rawset(self, 'rawread_fiber', nil)
    end

    if self.peer ~= nil then
        self.peer:close()
        rawset(self, 'peer', nil)
    end
end

function wspeer.is_closed(self)
    return self.peer == nil
end

function wspeer.error(self)
    if self.peer == nil then
        return 'No connection'
    end

    return self.peer:error()
end

--[[
    WebSocket server
]]
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

    rawset(self, 'host', host)
    rawset(self, 'port', port)
    rawset(self, 'backlog', options.backlog or 1024)
    rawset(self, 'http_read_timeout', options.http_read_timeout or 120)
    rawset(self, 'http_write_timeout', options.http_write_timeout or 120)
    rawset(self, 'ping_freq', options.ping_freq or 30)

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

    if self.ms ~= nil then
        self.ms:close()
        rawset(self, 'ms', nil)
    end

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

function wsserver.set_backlog(self, backlog)
    rawset(self, 'backlog', backlog)
end

function wsserver.set_http_read_timeout(self, timeout)
    rawset(self, 'http_read_timeout', timeout)
end

function wsserver.set_http_write_timeout(self, timeout)
    rawset(self, 'http_write_timeout', timeout)
end

function wsserver.set_ping_freq(self, frequency)
    rawset(self, 'ping_freq', frequency)
end

function wsserver.rawlisten(self)
    rawset(self, 'ms', socket('PF_INET', 'SOCK_STREAM', 'tcp'))
    if self.ms == nil then
        log.info('Websocket server could not create socket %s:%d error %s',
                 self.host, self.port, errno.strerror())
        self:close()
        return
    end
    self.ms:setsockopt('SOL_SOCKET', 'SO_REUSEADDR', true)
    self.ms:nonblock(true)
    if not self.ms:bind(self.host, self.port) then
        log.info('Websocket server bind %s:%d error "%s"', self.host, self.port,
                 self.ms:error())
        self:close()
        return
    end
    if not self.ms:listen(self.backlog) then
        log.info('Websocket server listen %s:%d with backlog %d error "%s"',
                 self.host, self.port,
                 self.backlog,
                 self.ms:error())

        self:close()
        return
    end

    while self.ms:readable() do
        local peer = self.ms:accept()
        if peer ~= nil then
            peer:nonblock(true)

            fiber.create(wsserver.handshake_loop, self, peer)
        else
            log.debug('Websocket server %s:%d accept failed', self.host,
                      self.port)
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
        local line = peer:read({delimiter='\r\n'}, self.http_read_timeout)
        if line == nil then
            log.debug('Websocket server connection closed while handshake')
            break
        elseif #line == 0 then
            log.debug('Websocket server eof from peer while handshake')
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
                    peer:write(err, self.http_write_timeout)
                    break
                end
                response = handshake.accept_upgrade(request)
                if self.proxy_handshake then
                    response = self:proxy_handshake(request, response)
                end
                local packet = handshake.reduce_response(response)

                if peer:write(packet, self.http_write_timeout) == nil then
                    log.debug('Websocket server could not write while handshake')
                    break
                end

                success = (tonumber(response.code) == 101)
                break
            else
                local _, _, name, value = line:find('^([^:]+)%s*:%s*(.+)')
                if name == nil or value == nil then
                    log.debug('Websocket server malformed handshake packet')
                    break
                end
                request.headers[name:strip():lower()] = value:strip()
            end
        end
    end

    if success then
        if self.accept_channel:has_readers() then
            local newpeer = wspeer.new(peer, {request=request,
                                              response=response},
                                       self.ping_freq)
            self.accept_channel:put(newpeer)
        else
            log.info('Websocket server discards new peer because no accept listeners')
            peer:shutdown(socket.SHUT_RDWR)
            peer:close()
        end
    else
        log.debug('Websocket peer closed while handshake')
        peer:shutdown(socket.SHUT_RDWR)
        peer:close()
    end
end

return wsserver
