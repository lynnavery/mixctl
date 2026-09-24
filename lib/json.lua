-- minimal json encoder (topology export only; no decoding needed)

local json = {}

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_str(s)
  s = s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local encode

local function encode_table(t, out)
  if is_array(t) then
    out[#out + 1] = "["
    for i, v in ipairs(t) do
      if i > 1 then out[#out + 1] = "," end
      encode(v, out)
    end
    out[#out + 1] = "]"
  else
    out[#out + 1] = "{"
    local first = true
    for k, v in pairs(t) do
      if type(v) ~= "function" then
        if not first then out[#out + 1] = "," end
        first = false
        out[#out + 1] = escape_str(tostring(k))
        out[#out + 1] = ":"
        encode(v, out)
      end
    end
    out[#out + 1] = "}"
  end
end

encode = function(v, out)
  local t = type(v)
  if t == "nil" then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    -- -inf is common for dB levels; nan/inf aren't valid json
    if v ~= v or v == math.huge or v == -math.huge then
      out[#out + 1] = "null"
    elseif math.type and math.type(v) == "integer" then
      out[#out + 1] = tostring(v)
    else
      out[#out + 1] = string.format("%.6g", v)
    end
  elseif t == "string" then
    out[#out + 1] = escape_str(v)
  elseif t == "table" then
    encode_table(v, out)
  else
    out[#out + 1] = "null"
  end
end

function json.encode(v)
  local out = {}
  encode(v, out)
  return table.concat(out)
end

return json
