#!/usr/bin/env tarantool

local errno = require('errno')
local socket = require('socket')
local log = require('log')

local clock = require('clock')
local digest = require('digest')

local handshake = require('websocket.handshake')
local frame = require('websocket.frame')
local utf8_validator = require('websocket.utf8_validator')

local HTTPSTATE = {
    REQUEST = 1,
    HEADERS = 2,
}

local wspeer = {
    __newindex = function(table, key, value)
        error("Attempt to modify read-only wspeer properties")
    end,
}

wspeer.__index = wspeer

function wspeer.new(peer, ping_freq, is_client, handshaked, client_request)
    local self = setmetatable({}, wspeer)

    peer:nonblock(true)
    rawset(self, 'peer', peer)

    local peeraddr = peer:peer()
    if peeraddr ~= nil then
        rawset(self, 'peerhost', peeraddr['host'])
        rawset(self, 'peerport', peeraddr['port'])
    end
    rawset(self, 'is_client', is_client)
    rawset(self, 'client_request', client_request)

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

function wspeer.check_client_handshake(self, timeout)
    local starttime = clock.time()

    if self.handshaked then
        return true
    end

    rawset(self, 'httpstate', HTTPSTATE.RESPONSE)

    local request = table.copy(self.client_request)
    request.key = request.key or digest.base64_encode(digest.urandom(16))

    local response = {
        version='',
        code='',
        status='',
        headers={}
    }

    local rc = self.peer:write(handshake.upgrade_request(request),
                               frame.slice_wait(timeout, starttime))
    if rc == nil then
        return false, 'Connection closed: error'
    end
    if rc == 0 then
        return false, 'Connection closed: eof'
    end

    while true do
        local line = self.peer:read({delimiter='\r\n'},
            frame.slice_wait(timeout, starttime))
        if line == nil then
            log.debug('Read failed while handshake')
            return nil, self.peer:error()
        elseif line == '' then
            log.debug('Read eof while handshake')
            return nil, 'Connection closed: eof'
        end
        if self.httpstate == HTTPSTATE.RESPONSE then
            local i, j
            -- Method SP Request-URI SP HTTP-Version CRLF
            i, j, response.version, response.code, response.reason =
                line:find('^([^%s]+)%s([^%s]+)%s([^\r\n]*)')
            rawset(self, 'httpstate', HTTPSTATE.HEADERS)
        elseif self.httpstate == HTTPSTATE.HEADERS then
            if line == '\r\n' then
                if response.code == '101' then
                    local respkey = handshake.sec_websocket_accept(request.key)
                    if respkey == response.headers['sec-websocket-accept'] then
                        rawset(self, 'handshaked', true)
                        return true
                    end
                end
                log.debug('Websocket handshake response error')
                self.peer:shutdown(socket.SHUT_RDWR,
                                   frame.slice_wait(timeout, starttime))
                return false, 'Handshake error'
            else
                local _, _, name, value = line:find('^([^:]+)%s*:%s*(.+)')
                if name == nil or value == nil then
                    log.debug('Websocket malformed handshake packet')
                    self.peer:shutdown(socket.SHUT_RDWR,
                                       frame.slice_wait(timeout, starttime))
                    return false, 'Malformed packet'
                end
                response.headers[name:strip():lower()] = value:strip()
            end
        end
    end
    -- NOTREACHED
end

function wspeer.shutdown(self, code, reason, timeout)
    local starttime = clock.time()
    log.debug('Websocket peer %s:%d close frame with code %d reason %s',
              self['peerhost'],
              self['peerport'],
              code,
              reason)
    local packet = frame.encode(frame.encode_close(code, reason),
                                frame.CLOSE, self.is_client, true)
    local rc = self.peer:write(packet, frame.slice_wait(timeout))
    if not rc then
        return nil, self.peer:error()
    end

    rawset(self, 'close_sended', true)
    rawset(self, 'closed_by_me', not self.close_received)

    if not self.close_received then
        while true do
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

    if self.last_ping_sended ~= nil
        and clock.time() - self.last_ping_sended < self.ping_freq
    then
        return true
    end

    if not self.ping_sended then
        log.debug('Websocket peer %s:%d sending ping request',
                 self['peerhost'],
                 self['peerport'])
        rawset(self, 'last_ping_sended', clock.time())
        local packet = frame.encode('', frame.PING, self.is_client, true)
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

    if self.is_client then
        local rc, err = self:check_client_handshake(frame.slice_wait(timeout, starttime))
        if not rc then
            return nil, err
        end
    else
        local rc, err = self:check_handshake(frame.slice_wait(timeout, starttime))
        if not rc then
            return nil, err
        end
    end

    local err
    local tuple
    while true do
        repeat
            local rc, err = self:check_ping_pong(frame.slice_wait(timeout, starttime))
            if rc == nil then
                return rc, err
            end

            local corrected = frame.slice_wait(timeout, starttime)
            if corrected == nil and self.ping_freq ~= nil then
                corrected = self.ping_freq
            elseif corrected > self.ping_freq then
                corrected = self.ping_freq
            end

            tuple, err = frame.decode_from(self.peer, corrected)

            if tuple == nil then
                if self.peer:errno() == errno.ETIMEDOUT then
                    if frame.slice_wait(timeout, starttime) == nil then
                        --continue
                    elseif frame.slice_wait(timeout, starttime) > 0 then
                        --continue
                    else
                        return nil, self.peer:error()
                    end
                else
                    return nil, self.peer:error()
                end
            elseif tuple.opcode == nil then
                return tuple
            end
        until tuple ~= nil

        local rc, err = self:validate(tuple)
        if not rc then
            self:shutdown(err.code, err.message, frame.slice_wait(timeout, starttime))
            return nil, 'Validation error'
        end

        -- Buiseness
        if tuple.opcode == frame.PING then
            log.debug('Websocket peer %s:%d ping request',
                      self['peerhost'],
                      self['peerport'])
            local packet = frame.encode(tuple.data, frame.PONG, self.is_client, true)
            local rc = self.peer:write(packet, frame.slice_wait(timeout, starttime))
            if not rc then
                return nil, 'Write pong failed'
            end
        elseif tuple.opcode == frame.PONG then
            log.debug('Websocket peer %s:%d pong response',
                      self['peerhost'],
                      self['peerport'])
            rawset(self, 'ping_sended', false)
        elseif tuple.opcode == frame.CLOSE then
            log.debug('Websocket peer close received')

            rawset(self, 'close_received', true)

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

    if self.is_client then
        local rc, err = self:check_client_handshake(frame.slice_wait(timeout, starttime))
        if not rc then
            return nil, err
        end
    else
        local rc, err = self:check_handshake(frame.slice_wait(timeout, starttime))
        if not rc then
            return nil, err
        end
    end

    local rc, err = self:check_ping_pong(frame.slice_wait(timeout, starttime))
    if rc == nil then
        return rc, err
    end

    local message = tuple.data
    local packet = frame.encode(message, tuple.opcode, self.is_client, tuple.fin)

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
