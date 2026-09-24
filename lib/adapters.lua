-- param-id maps for known nb voices, plus a heuristic for unknown ones.
-- each adapter returns { level=, pan=, send_a=, send_b=, prefix= } (ids may be nil)

local adapters = {}

local nb = {}

nb["mxsynths"] = function()
  return {
    prefix = "nb_mxsynths_",
    level = "nb_mxsynths_amp",
    pan = "nb_mxsynths_pan",
    send_a = "nb_mxsynths_send_a",
    send_b = "nb_mxsynths_send_b",
  }
end

nb["smpKit"] = function()
  return {
    prefix = "nb_smpkit_",
    level = "nb_smpkit_main_amp",
    pan = "nb_smpkit_pan_glb",
    send_a = "nb_smpkit_send_a_glb",
    send_b = "nb_smpkit_send_b_glb",
    extra = { "nb_smpkit_amp_glb" },
  }
end

-- emplaitress registers "emplait 1".."emplait 4", params are plaits_<key>_<i>
local function emplait(i)
  return {
    prefix = "plaits_",
    level = "plaits_amp_" .. i,
    pan = "plaits_pan_" .. i,
    send_a = "plaits_send_a_" .. i,
    send_b = "plaits_send_b_" .. i,
    extra = { "plaits_gain_" .. i },
  }
end

local function normalize(s)
  return s:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

local suffixes = {
  level = { "amp", "level", "gain", "vol", "volume" },
  pan = { "pan" },
  send_a = { "send_a", "sendA", "send_1" },
  send_b = { "send_b", "sendB", "send_2" },
}

-- guess ids by looking for <prefix><suffix> in params, trying a few prefixes
-- derived from the player name
local function guess(name)
  local norm = normalize(name)
  local prefixes = { "nb_" .. norm .. "_", norm .. "_" }
  for _, prefix in ipairs(prefixes) do
    local found = { prefix = prefix }
    local any = false
    for role, list in pairs(suffixes) do
      for _, suf in ipairs(list) do
        if params.lookup[prefix .. suf] then
          found[role] = prefix .. suf
          any = true
          break
        end
      end
    end
    if any then return found end
  end
  return nil
end

function adapters.nb_voice(name)
  if nb[name] then return nb[name]() end
  local i = name:match("^emplait (%d+)$")
  if i then return emplait(i) end
  return guess(name)
end

-- fx mods built on fx/lib/fx.lua all add "<prefix>_slot" + "<prefix>_slot_drywet"
function adapters.fx_mods()
  local found = {}
  for _, p in ipairs(params.params) do
    local id = p.id
    if type(id) == "string" then
      local prefix = id:match("^(.+)_slot$")
      if prefix and params.lookup[id .. "_drywet"] then
        found[#found + 1] = prefix
      end
    end
  end
  table.sort(found)
  return found
end

local fx_level_suffixes = { "_level", "_amp", "_mix", "_gain" }

function adapters.fx_level(prefix)
  for _, suf in ipairs(fx_level_suffixes) do
    if params.lookup[prefix .. suf] then return prefix .. suf end
  end
  return nil
end

return adapters
