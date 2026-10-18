-- Streaming JSON encoder for the Factorio prototype dump.
-- Lua 5.2 compatible (Factorio's interpreter version).

local json = {}

local floor, abs, format = math.floor, math.abs, string.format

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_string(s, out)
  out[#out + 1] = '"'
  -- escape control chars and quotes in one pass using gsub
  s = s:gsub('[%z\1-\31\\"]', function(c)
    local e = ESCAPES[c]
    if e then return e end
    return format('\\u%04x', c:byte())
  end)
  out[#out + 1] = s
  out[#out + 1] = '"'
end

local function encode_number(v, out)
  if v ~= v or v == math.huge or v == -math.huge then
    out[#out + 1] = 'null'
    return
  end
  if v == floor(v) and abs(v) < 9007199254740992 then
    out[#out + 1] = format('%d', v)
  else
    out[#out + 1] = format('%.15g', v)
  end
end

-- Classify a table: dense array part -> array, otherwise object.
local function classify(t)
  local count, max = 0, 0
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    if k ~= floor(k) or k < 1 then return false end
    count = count + 1
    if k > max then max = k end
  end
  if count == 0 then return false end
  return count == max, max
end

local function key_to_string(k)
  local tk = type(k)
  if tk == 'string' then return k end
  if tk == 'number' then
    if k == floor(k) then return format('%d', k) end
    return format('%.15g', k)
  end
  if tk == 'boolean' then return tostring(k) end
  return '<' .. tk .. '>'
end

local encode_value

-- stats collects diagnostics: skipped functions, cycles, truncations.
local function encode_table(t, out, stats, seen, depth)
  if depth > 64 then
    stats.depth_limited = stats.depth_limited + 1
    out[#out + 1] = 'null'
    return
  end
  if seen[t] then
    stats.cycles = stats.cycles + 1
    out[#out + 1] = 'null'
    return
  end
  seen[t] = true

  local is_arr, n = classify(t)
  if is_arr then
    out[#out + 1] = '['
    for i = 1, n do
      if i > 1 then out[#out + 1] = ',' end
      encode_value(t[i], out, stats, seen, depth + 1)
    end
    out[#out + 1] = ']'
  else
    out[#out + 1] = '{'
    local first = true
    for k, v in pairs(t) do
      local tk = type(k)
      if tk == 'string' or tk == 'number' or tk == 'boolean' then
        if not first then out[#out + 1] = ',' end
        first = false
        escape_string(key_to_string(k), out)
        out[#out + 1] = ':'
        encode_value(v, out, stats, seen, depth + 1)
      else
        stats.bad_keys = stats.bad_keys + 1
      end
    end
    out[#out + 1] = '}'
  end

  seen[t] = nil
end

encode_value = function(v, out, stats, seen, depth)
  local tv = type(v)
  if v == nil then
    out[#out + 1] = 'null'
  elseif tv == 'boolean' then
    out[#out + 1] = v and 'true' or 'false'
  elseif tv == 'number' then
    encode_number(v, out)
  elseif tv == 'string' then
    escape_string(v, out)
  elseif tv == 'table' then
    encode_table(v, out, stats, seen, depth)
  else
    -- function, userdata, thread: not serialisable
    stats['skipped_' .. tv] = (stats['skipped_' .. tv] or 0) + 1
    out[#out + 1] = 'null'
  end
end

-- Encode `value` and return the JSON text plus diagnostics.
function json.encode(value)
  local out = {}
  local stats = { cycles = 0, depth_limited = 0, bad_keys = 0 }
  encode_value(value, out, stats, {}, 0)
  return table.concat(out), stats
end

-- Encode to an open file handle in chunks (for very large tables).
function json.write_file(path, value)
  local text, stats = json.encode(value)
  local f, err = io.open(path, 'wb')
  if not f then return nil, err end
  f:write(text)
  f:close()
  return #text, stats
end

return json
