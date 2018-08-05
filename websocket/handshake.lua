-- Copyright (c) 2012 by Gerhard Lipp <gelipp@gmail.com>

-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:

-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.

-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.

local digest = require('digest')

local guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function sec_websocket_accept(sec_websocket_key)
    local a = sec_websocket_key..guid
    local sha1 = digest.sha1(a)
    assert((#sha1 % 2) == 0)
    return digest.base64_encode(sha1)
end

local function upgrade_request(req)
    local lines = {
        ('GET %s HTTP/1.1'):format(req.uri or ''),
        ('Host: %s'):format(req.host),
        'Upgrade: websocket',
        'Connection: Upgrade',
        ('Sec-WebSocket-Key: %s'):format(req.key),
        ('Sec-WebSocket-Protocol: %s'):format(table.concat(req.protocols,', ')),
        'Sec-WebSocket-Version: 13',
    }
    if req.origin then
        table.insert(lines, ('Origin: %s'):format(req.origin))
    end
    if req.port and req.port ~= 80 then
        lines[2] = ('Host: %s:%d'):format(req.host, req.port)
    end
    table.insert(lines,'\r\n')
    return table.concat(lines,'\r\n')
end

local function validate_request(request)
    local headers = request.headers
    if headers == nil
        or not headers['upgrade']
        or headers['upgrade']:lower() ~= 'websocket'
        or not headers['connection']
        or not headers['connection']:lower():match('upgrade')
        or not headers['sec-websocket-key']
        or headers['sec-websocket-version'] ~= '13'
    then
        return false, 'HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'
    end
    return true
end

local function accept_upgrade(request)
    local headers = request.headers
    local response = {
        version='HTTP/1.1',
        code='101',
        status='Switching Protocols',

        headers = {
            ['Upgrade']='websocket',
            ['Connection']=headers['connection'],
            ['Sec-WebSocket-Accept']=sec_websocket_accept(headers['sec-websocket-key'])
        }
    }

    return response
end

local function reduce_response(response)
    local lines = {
        string.format('%s %s %s', response.version, response.code, response.status),
    }
    for key, val in pairs(response.headers) do
        table.insert(lines, string.format('%s: %s', key, val))
    end
    table.insert(lines,'\r\n')
    return table.concat(lines, '\r\n')
end

return {
    sec_websocket_accept = sec_websocket_accept,
    accept_upgrade = accept_upgrade,
    upgrade_request = upgrade_request,
    validate_request = validate_request,
    reduce_response = reduce_response,
}
