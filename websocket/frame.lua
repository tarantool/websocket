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

-- Following Websocket RFC: http://tools.ietf.org/html/rfc6455
local bit = require('bit')
local clock = require('clock')

local function slice_wait(timeout, starttime)
    if timeout == nil then
        return nil
    end

    return timeout - (clock.time() - starttime)
end


local write_int8 = string.char

local function write_int16(v)
    return string.char(bit.rshift(v, 8), bit.band(v, 0xFF))
end

local function write_int32(v)
    return string.char(
        bit.band(bit.rshift(v, 24), 0xFF),
        bit.band(bit.rshift(v, 16), 0xFF),
        bit.band(bit.rshift(v,  8), 0xFF),
        bit.band(v, 0xFF)
    )
end

local TEXT = 1
local BINARY = 2
local CLOSE = 8
local PING = 9
local PONG = 10

local bits = function(...)
    local n = 0
    for _,bitn in pairs{...} do
        n = n + 2^bitn
    end
    return n
end

local bit_7 = bits(7)
local bit_0_3 = bits(0,1,2,3)
local bit_4_6 = bits(4,5,6)
local bit_0_6 = bits(0,1,2,3,4,5,6)

-- TODO: improve performance
local function xor_mask(encoded,mask,payload)
    local transformed,transformed_arr = {},{}
    -- xor chunk-wise to prevent stack overflow.
    -- byte and char multiple in/out values
    -- which require stack
    for p=1,payload,2000 do
        local last = math.min(p+1999,payload)
        local original = {encoded:byte(p,last)}
        for i=1,#original do
            local j = (i-1) % 4 + 1
            transformed[i] = bit.bxor(original[i],mask[j])
        end
        local xored = string.char(unpack(transformed,1,#original))
        table.insert(transformed_arr,xored)
    end
    return table.concat(transformed_arr)
end

local function encode_header_small(header, payload)
    return string.char(header, payload)
end

local function encode_header_medium(header, payload, len)
    return string.char(header, payload, bit.band(bit.rshift(len, 8), 0xFF), bit.band(len, 0xFF))
end

local function encode_header_big(header, payload, high, low)
    return string.char(header, payload)..write_int32(high)..write_int32(low)
end

local function encode(data, opcode, masked, fin)
    local header = opcode or TEXT-- TEXT is default opcode
    if fin == nil or fin == true then
        header = bit.bor(header, bit_7)
    end
    local payload = 0
    if masked then
        payload = bit.bor(payload, bit_7)
    end
    local len = 0
    if data ~= nil then
        len = #data
    end
    local chunks = {}
    if len < 126 then
        payload = bit.bor(payload, len)
        table.insert(chunks, encode_header_small(header, payload))
    elseif len <= 0xffff then
        payload = bit.bor(payload,126)
        table.insert(chunks, encode_header_medium(header, payload, len))
    elseif len < 2^53 then
        local high = math.floor(len/2^32)
        local low = len - high*2^32
        payload = bit.bor(payload,127)
        table.insert(chunks, encode_header_big(header, payload, high, low))
    end
    if not masked and data ~= nil then
        table.insert(chunks, data)
    elseif data ~= nil then
        local m1 = math.random(0, 0xff)
        local m2 = math.random(0, 0xff)
        local m3 = math.random(0, 0xff)
        local m4 = math.random(0, 0xff)
        local mask = {m1, m2, m3, m4}
        table.insert(chunks, write_int8(m1, m2, m3, m4))
        table.insert(chunks, xor_mask(data, mask, #data))
    end
    return table.concat(chunks)
end

function string.int16(self)
    local a, b = self:byte(1, 2)
    return bit.lshift(a, 8) + b
end

function string.int32(self)
    local a, b, c, d = self:byte(1, 4)
    return bit.lshift(a, 24) +
        bit.lshift(b, 16) +
        bit.lshift(c, 8) +
        d
end

--[[
    returns:
      {opcode=number,fin=boolean,data=string,rsv=number} on success
      {} on eof
      nil on timeout or hard error, check it with client:errno()
]]
local function decode_from(client, timeout)
    local starttime = clock.time()

    local header, payload
    header = client:read({chunk=1}, timeout)
    if header == nil then
        return nil, client:error()
    elseif header == '' then
        return {}
    end
    header = header:byte()

    local fin = bit.band(header, bit_7) > 0
    local rsv = bit.band(header, bit_4_6)
    local opcode = bit.band(header, bit_0_3)

    payload = client:read({chunk=1}, slice_wait(timeout, starttime))
    if payload == nil then
        return nil, client:error()
    elseif payload == '' then
        return {}
    end
    payload = payload:byte()

    local high, low
    local ismasked = bit.band(payload, bit_7) > 0

    payload = bit.band(payload,bit_0_6)
    if payload > 125 then
        if payload == 126 then
            payload = client:read({chunk=2}, slice_wait(timeout, starttime))
            if payload == nil then
                return nil, client:error()
            elseif payload == '' then
                return {}
            end
            payload = payload:int16()
        elseif payload == 127 then
            high = client:read({chunk=4}, slice_wait(timeout, starttime))
            low = client:read({chunk=4}, slice_wait(timeout, starttime))
            if high == nil or low == nil then
                return nil, client:error()
            elseif high == '' or low == '' then
                return {}
            end
            high = high:int32()
            low = low:int32()

            payload = tonumber64(high)*2^32 + low
            if payload < 0xffff or payload > 2^53 then
                return nil, 'Invalid payload frame size'
            end
        else
            error('NOTREACHED')
        end
    end

    local m1,m2,m3,m4
    local mask
    if ismasked then
        local stringmask = client:read({chunk=4}, slice_wait(timeout, starttime))
        if stringmask == nil then
            return nil, client:error()
        elseif stringmask == '' then
            return {}
        end
        m1 = stringmask:byte(1)
        m2 = stringmask:byte(2)
        m3 = stringmask:byte(3)
        m4 = stringmask:byte(4)
        mask = { m1, m2, m3, m4 }
    end

    -- TODO optimize frame body read loop
    local data = {}
    local maski = 1
    if mask then
        for i=1, payload do
            local piece
            piece = client:read({chunk=1}, slice_wait(timeout, starttime))
            if piece == nil then
                return nil, client:error()
            elseif piece == '' then
                return {}
            end
            piece = piece:byte()
            piece = bit.bxor(piece, mask[maski])
            if maski == 4 then
                maski = 1
            else
                maski = maski + 1
            end

            piece = string.char(piece)
            data[i] = piece
        end
        data = table.concat(data)
    else
        data = client:read({chunk=payload}, slice_wait(timeout, starttime))
        if data == nil then
            return nil, client:error()
        elseif data == '' then
            return {}
        end
    end

    return {
        opcode = opcode,
        fin = fin,
        data = data,
        rsv = rsv,
    }
end

local function encode_close(code, reason)
    if code then
        local data = write_int16(code)
        if reason then
            data = data..tostring(reason)
        end
        return data
    end
    return ''
end

local function read_n_bytes(str, pos, n)
    pos = pos or 1
    return pos+n, string.byte(str, pos, pos + n - 1)
end

local function read_int16(str, pos)
    local new_pos, a, b = read_n_bytes(str, pos, 2)
    return new_pos, bit.lshift(a, 8) + b
end

local function decode_close(data)
    local _, code, reason
    if data then
        if #data > 1 then
            _, code = read_int16(data,1)
        end
        if #data > 2 then
            reason = data:sub(3)
        end
    end
    return code, reason
end


return {
    slice_wait = slice_wait,

    xor_mask = xor_mask,

    encode = encode,
    decode_from = decode_from,
    encode_close = encode_close,
    decode_close = decode_close,

    CONTINUATION = 0,
    TEXT = TEXT,
    BINARY = BINARY,
    CLOSE = CLOSE,
    PING = PING,
    PONG = PONG
}
