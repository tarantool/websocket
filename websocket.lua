#!/usr/bin/env tarantool

local socket = require('socket')
local log = require('log')

local clock = require('clock')

local handshake = require('websocket.handshake')
local frame = require('websocket.frame')
local utf8_validator = require('websocket.utf8_validator')

local HTTPSTATE = {
    REQUEST = 1,
    HEADERS = 2,
}

--[[
    WebSocket Peer
]]
local wspeer = {
    __newindex = function(table, key, value)
        error("Attempt to modify read-only wspeer properties")
    end,
}

wspeer.__index = wspeer

function wspeer.new(peer, ping_freq, handshaked)
    local self = setmetatable({}, wspeer)

    peer:nonblock(true)
    rawset(self, 'peer', peer)

    local peeraddr = peer:peer()
    if peeraddr ~= nil then
        rawset(self, 'host', peeraddr['host'])
        rawset(self, 'port', peeraddr['port'])
    end
    rawset(self, 'handshake_packets', nil)
    rawset(self, 'handshaked', handshaked)

    rawset(self, 'proxy_handshake', nil)

    rawset(self, 'ping_freq', ping_freq)

    rawset(self, 'close_sended', false)
    rawset(self, 'close_received', false)

    rawset(self, 'ping_sended', false)

    rawset(self, 'closed_by_me', false)

    -- validation state
    rawset(self, 'last_opcode', nil)

    return self
end

function wspeer.check_handshake(self, timeout)
    local starttime = clock.time()

    if self.handshaked then
        return true
    end

    rawset(self, 'httpstate', HTTPSTATE.REQUEST)

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
        local line = self.peer:read({delimiter='\r\n'},
            frame.slice_wait(timeout, starttime))
        if line == nil then
            log.debug('Read failed while handshake')
            return nil, self.peer:error()
        elseif line == '' then
            log.debug('Read eof while handshake')
            return nil, 'Connection closed'
        end
        if self.httpstate == HTTPSTATE.REQUEST then
            local i, j
            -- Method SP Request-URI SP HTTP-Version CRLF
            i, j, request.method, request.uri, request.version =
                line:find('^([^%s]+)%s([^%s]+)%s([^%s]+)')
            rawset(self, 'httpstate', HTTPSTATE.HEADERS)
        elseif self.httpstate == HTTPSTATE.HEADERS then
            if line == '\r\n' then
                local valid, erresp = handshake.validate_request(request)
                if not valid then
                    local rc = self.peer:write(erresp,
                                               frame.slice_wait(timeout, starttime))
                    if not rc then
                        log.debug('Write failed while error handshake')
                        return nil, self.peer:errno()
                    end
                    local rc = self.peer:shutdown(socket.SHUT_RDWR,
                                                  frame.slice_wait(timeout, starttime))
                    if not rc then
                        log.debug('Shutdown failed while error handshake')
                    end
                    return nil, 'Handshake failed'
                end

                if valid then
                    response = handshake.accept_upgrade(request)
                    if self.proxy_handshake then
                        response = self:proxy_handshake(request, response)
                    end
                    local packet = handshake.reduce_response(response)
                    local rc = self.peer:write(packet,
                                               frame.slice_wait(timeout, starttime))
                    if rc  == nil then
                        log.debug('Websocket server could not write while handshake')
                        return nil, self.peer:error()
                    end

                    rawset(self, 'httpstate', HTTPSTATE.REQUEST)
                    success = (tonumber(response.code) == 101)
                    if success then
                        rawset(self, 'handshake_packets', {request, response})
                        rawset(self, 'handshaked', true)
                        return true
                    end
                end
            else
                local _, _, name, value = line:find('^([^:]+)%s*:%s*(.+)')
                if name == nil or value == nil then
                    log.debug('Websocket server malformed handshake packet')
                    self.peer:shutdown(socket.SHUT_RDWR,
                                       frame.slice_wait(timeout, starttime))
                    return false, 'Malformed packet'
                end
                request.headers[name:strip():lower()] = value:strip()
            end
        end
    end
    -- NOTREACHED
end

function wspeer.shutdown(self, code, reason, timeout)
    local starttime = clock.time()
    log.info('Websocket peer %s:%d close frame with code %d reason %s',
             self['host'],
             self['port'],
             code,
             reason)
    local packet = frame.encode(frame.encode_close(code, reason),
                                frame.CLOSE, false, true)
    local rc = self.peer:write(packet, frame.slice_wait(timeout))
    if not rc then
        return nil, self.peer:error()
    end

    rawset(self, 'close_sended', true)
    rawset(self, 'closed_by_me', not self.close_received)

    if not self.close_received then
        while true  do
            local tuple = frame.decode_from(self.peer, frame.slice_wait(timeout, starttime))
            if tuple == nil then
                log.debug('Read failed while close handshake')
                break
            elseif tuple.opcode == nil then
                log.debug('Read eof while close handshake')
                break
            end

            local rc, err = self:validate(tuple)
            if not rc then
                log.debug('Validation failed while close handshake %s', tostring(err))
                -- TODO think about
                -- break
            end

            if tuple.opcode == frame.CLOSE then
                log.debug('Close handshake success')
                rawset(self, 'close_received', true)
                break
            end
        end
    end

    -- TODO think about result
    local rc = self.peer:shutdown(socket.SHUT_RDWR,
                                  frame.slice_wait(timeout, starttime))
    if not rc then
        log.debug('Shutdown socket failed while close handshake #3')
    end
    return true
end

function wspeer.check_ping_pong(self, timeout)
    local starttime = clock.time()

    if self.ping_freq == nil then
        return true
    end

    if self.last_ping_sended == nil then
        rawset(self, 'last_ping_sended', clock.time())
    end

    if clock.time() - self.last_ping_sended < self.ping_freq then
        return true
    end

    if not self.ping_sended then
        log.info('Websocket peer %s:%d sending ping request',
                 self['host'],
                 self['port'])
        rawset(self, 'last_ping_sended', clock.time())
        local packet = frame.encode('', frame.PING, false, true)
        local rc = self.peer:write(packet, frame.slice_wait(timeout, starttime))
        if not rc then
            return nil, 'Connection write error'
        end
        rawset(self, 'ping_sended', true)
        return true
    else
        self:shutdown(1000, 'pong timeout', frame.slice_wait(timeout, starttime))
        return nil, 'Pong timeout'
    end
end

function wspeer.validate(self, tuple)
    -- invalid frame
    if tuple.opcode ~= frame.CONTINUATION
        and tuple.opcode ~= frame.TEXT and tuple.opcode ~= frame.BINARY
        and tuple.opcode ~= frame.CLOSE
        and tuple.opcode ~= frame.PING and tuple.opcode ~= frame.PONG
    then
        return false, {code=1002,
                       message=('opcode invalid: %d'):format(tuple.opcode)}
    end

    -- invalid control frame length
    if tuple.opcode ~= frame.CONTINUATION
        and tuple.opcode ~= frame.TEXT and tuple.opcode ~= frame.BINARY
        and #tuple.data > 125
    then
        return false, {code=1002,
                       message=('control frame length greater than 125: %d'):format(#tuple.data)}
    end

    -- invalid rsv
    if tuple.rsv ~= 0 then
        return false, {code=1002,
                       message=('frame rsv invalid: %d'):format(tuple.rsv)}
    end

    -- control message can not be fragmented
    if tuple.opcode ~= frame.CONTINUATION
        and tuple.opcode ~= frame.TEXT and tuple.opcode ~= frame.BINARY
        and not tuple.fin
    then
        return false, {code=1002,
                       message='fragmented control frame not allloed'}
    end

    -- fragmented messages opcode == 0
    if tuple.opcode == frame.TEXT or tuple.opcode == frame.BINARY then
        if self.last_opcode ~= nil then
            return false, {code=1002,
                           message='fragmented frame should be continuation'}
        end
    end

    -- continuation frame without head frame
    if tuple.opcode == frame.CONTINUATION then
        if self.last_opcode == nil then
            return false, {code=1002,
                           message='continuation frame without head frame'}
        end
    end

    -- utf8 invalid simple case
    if tuple.opcode == frame.TEXT then
        if utf8_validator(tuple.data) == false then
            return false, {code=1007,
                           message='utf8 data invalid'}
        end
    end

    -- close invalid
    if tuple.opcode == frame.CLOSE then
        -- not enough data
        if tuple.data and #tuple.data == 1 then
            return false, {code=1002,
                           message='invalid close frame'}
        end
        -- invalid utf8
        if tuple.data and #tuple.data > 1 then
            local code, reason = frame.decode_close(tuple.data)
            if code < 1000 or code == 1004
                or code == 1005
                or code == 1006
                or (code > 1013 and code < 3000)
                or code > 4999
            then
                return false, {code=1002,
                              message='close code invalid'}
            end
            if reason ~= nil and utf8_validator(reason) == false then
                return false, {code=1007,
                              message='utf8 data in close frame invalid'}
            end
        end
    end

    -- save/reset fragmented stream
    if tuple.opcode == frame.TEXT or tuple.opcode == frame.BINARY then
        if not tuple.fin then
            rawset(self, 'last_opcode', tuple.opcode)
        end
    elseif tuple.opcode == frame.CONTINUATION then
        if tuple.fin then
            rawset(self, 'last_opcode', nil)
        end
    end

    return true
end

--[[
]]
function wspeer.read(self, timeout)
    local starttime = clock.time()

    local tuple

    local rc, err = self:check_handshake(frame.slice_wait(timeout, starttime))
    if not rc then
        return nil, err
    end

    while true do
        local rc, err = self:check_ping_pong(frame.slice_wait(timeout, starttime))
        if rc == nil then
            return rc, err
        end

        tuple = frame.decode_from(self.peer, frame.slice_wait(timeout, starttime))
        if tuple == nil then
            return nil, 'Connection error'
        elseif tuple.opcode == nil then
            return tuple
        end

        local rc, err = self:validate(tuple)
        if not rc then
            self:shutdown(err.code, err.message, frame.slice_wait(timeout, starttime))
            return nil, 'Validation error'
        end

        -- Buiseness
        if tuple.opcode == frame.PING then
            log.debug('Websocket peer %s:%d ping request',
                      self['host'],
                      self['port'])
            local packet = frame.encode(tuple.data, frame.PONG, false, true)
            local rc = self.peer:write(packet, frame.slice_wait(timeout, starttime))
            if not rc then
                return nil, 'Write pong failed'
            end
        elseif tuple.opcode == frame.PONG then
            log.debug('Websocket peer %s:%d pong response',
                      self['host'],
                      self['port'])
            rawset(self, 'ping_sended', false)
        elseif tuple.opcode == frame.CLOSE then
            log.debug('Websocket peer close received')

            rawset(self,'close_received', true)

            self:shutdown(1000, '', frame.slice_wait(timeout, starttime))
            return nil, 'Close handshaked'
        else
            return tuple
        end
    end
end

function wspeer.write(self, tuple, timeout)
    local starttime = clock.time()

    if type(tuple) == 'string' then
        local message = tuple
        tuple = {
            opcode = frame.TEXT,
            fin = true,
            data = message
        }
    end

    if tuple.opcode ~= frame.CONTINUATION
        and tuple.opcode ~= frame.TEXT
        and tuple.opcode ~= frame.BINARY
    then
        return nil, 'You can send only text or binary frame'
    end

    local rc, err = self:check_handshake(frame.slice_wait(timeout, starttime))
    if not rc then
        return nil, err
    end

    local message = tuple.data
    local packet = frame.encode(message, tuple.opcode, false, tuple.fin)

    local rc = self.peer:write(packet, frame.slice_wait(timeout, starttime))
    if rc == nil then
        return rc, self.peer:error()
    end
    return rc
end

function wspeer.close(self)
    self.peer:close()
end

function wspeer.error(self)
    return self.peer:error()
end

return wspeer
