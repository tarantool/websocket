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

local write_int8 = string.char

local write_int16 = function(v)
    return string.char(bit.rshift(v, 8), bit.band(v, 0xFF))
end

local write_int32 = function(v)
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
local bit_0_6 = bits(0,1,2,3,4,5,6)

-- TODO: improve performance
local xor_mask = function(encoded,mask,payload)
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

local encode_header_small = function(header, payload)
    return string.char(header, payload)
end

local encode_header_medium = function(header, payload, len)
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


local function decode_from(client, timeout)
    local header, payload

    header = client:read({chunk=1}, timeout):byte()
    payload = client:read({chunk=1}, timeout):byte()
    if header == nil or payload == nil then
        -- eof
        return nil
    end

    local high, low
    local fin = bit.band(header, bit_7) > 0
    local opcode = bit.band(header, bit_0_3)
    local ismasked = bit.band(payload, bit_7) > 0

    payload = bit.band(payload,bit_0_6)
    if payload > 125 then
        if payload == 126 then
            payload = client:read({chunk=2}, timeout):int16()
            if payload == nil then
                -- eof
                return nil
            end
        elseif payload == 127 then
            high = client:read({chunk=4}, timeout):int32()
            low = client:read({chunk=4}, timeout):int32()
            if high == nil or low == nil then
                return nil
            end
            payload = high*2^32 + low
            if payload < 0xffff or payload > 2^53 then
                return nil
            end
        else
            return nil
        end
    end

    local m1,m2,m3,m4
    local mask
    if ismasked then
        m1 = client:read({chunk=1}, timeout):byte()
        m2 = client:read({chunk=1}, timeout):byte()
        m3 = client:read({chunk=1}, timeout):byte()
        m4 = client:read({chunk=1}, timeout):byte()
        if m1 == nil or m2 == nil or m3 == nil or m4 == nil then
            return nil
        end
        mask = { m1, m2, m3, m4 }
    end


    -- TODO optimize frame body read loop
    local data = {}
    local maski = 1
    for i=1, payload do
        local piece
        if mask then
            piece = client:read({chunk=1}, timeout):byte()
            if piece == nil then
                return nil
            end
            piece = bit.bxor(piece, mask[maski])
            if maski == 4 then
                maski = 1
            else
                maski = maski + 1
            end
        else
            piece = client:read({chunk=1}, timeout):byte()
            if piece == nil then
                return nil
            end
        end

        if opcode == TEXT then
            piece = string.char(piece)
        end
        data[i] = piece
    end
    return {
        opcode = opcode,
        fin = fin,
        data = table.concat(data)
    }
end

local encode_close = function(code,reason)
    if code then
        local data = write_int16(code)
        if reason then
            data = data..tostring(reason)
        end
        return data
    end
    return ''
end

local read_n_bytes = function(str, pos, n)
    pos = pos or 1
    return pos+n, string.byte(str, pos, pos + n - 1)
end

local read_int16 = function(str, pos)
    local new_pos, a, b = read_n_bytes(str, pos, 2)
    return new_pos, bit.lshift(a, 8) + b
end

local decode_close = function(data)
    local _, code, reason
    if data then
        if #data > 1 then
            _,code = read_int16(data,1)
        end
        if #data > 2 then
            reason = data:sub(3)
        end
    end
    return code, reason
end


return {
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
