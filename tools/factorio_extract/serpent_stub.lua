-- Minimal stand-in for Factorio's embedded `serpent` library.
-- Only used by prototype code on error paths and by a handful of
-- diagnostic helpers, so a compact pretty-printer is enough.

local serpent = {}

local function serialize(v, indent, seen, maxlevel)
  local tv = type(v)
  if tv == 'string' then return string.format('%q', v) end
  if tv == 'number' or tv == 'boolean' then return tostring(v) end
  if tv == 'nil' then return 'nil' end
  if tv ~= 'table' then return tostring(v) end

  indent = indent or 0
  if maxlevel and indent > maxlevel then return '{...}' end
  seen = seen or {}
  if seen[v] then return '<cycle>' end
  seen[v] = true

  local pad = string.rep('  ', indent + 1)
  local closer = string.rep('  ', indent)
  local parts = {}
  for k, val in pairs(v) do
    parts[#parts + 1] = pad .. '[' .. serialize(k, indent + 1, seen, maxlevel) .. '] = '
      .. serialize(val, indent + 1, seen, maxlevel)
  end
  seen[v] = nil
  if #parts == 0 then return '{}' end
  return '{\n' .. table.concat(parts, ',\n') .. '\n' .. closer .. '}'
end

function serpent.block(v, opts)
  return serialize(v, 0, nil, opts and opts.maxlevel)
end

function serpent.line(v, opts)
  return (serialize(v, 0, nil, opts and opts.maxlevel):gsub('%s+', ' '))
end

function serpent.dump(v)
  return serialize(v, 0, nil, nil), ''
end

serpent._VERSION = 'stub-1.0'
return serpent
