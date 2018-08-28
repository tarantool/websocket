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
    req = req or {}

    req.method = req.method or 'GET'
    req.path = req.path or '/'
    req.version = req.version or 'HTTP/1.1'


    req.headers = req.headers or {}
    req.headers['Connection'] = req.headers['Connection'] or 'Upgrade'
    req.headers['Upgrade'] = req.headers['Upgrade'] or 'websocket'
    req.headers['Sec-WebSocket-Version'] = req.headers['Sec-WebSocket-Version']
        or '13'
    req.headers['Sec-WebSocket-Key'] = req.headers['Sec-WebSocket-Key']
        or digest.base64_encode(digest.urandom(16))

    return req
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
        string.format('%s %s %s', response.version or 'HTTP/1.1',
                      response.code or '200', response.status or 'OK'),
    }
    for key, val in pairs(response.headers) do
        table.insert(lines, string.format('%s: %s', key, val))
    end
    table.insert(lines,'\r\n')
    return table.concat(lines, '\r\n')
end

local function reduce_request(request)
    local lines = {
        string.format('%s %s %s', request.method or 'GET', request.path or '/',
                      request.version or 'HTTP/1.1')
    }
    for key, val in pairs(request.headers) do
        table.insert(lines, string.format('%s: %s', key, val))
    end
    table.insert(lines, '\r\n')
    return table.concat(lines, '\r\n')
end

return {
    sec_websocket_accept = sec_websocket_accept,
    accept_upgrade = accept_upgrade,
    upgrade_request = upgrade_request,
    validate_request = validate_request,
    reduce_response = reduce_response,
    reduce_request = reduce_request
}
