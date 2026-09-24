-- builds the signal-flow graph: crone mixer, softcut, engine, nb voices,
-- fx mod sends/inserts. every controllable gain is a "ctl" descriptor:
--   { pset, id, role, name, type, min, max, value, raw, display, options }

local adapters = require 'mixctl/lib/adapters'

local topology = {}

-- the crone mix levels may live in a separate system paramset (`mix`)
-- rather than the script's `params`; check both
function topology.psets()
  local r = { script = params }
  local m = rawget(_G, "mix")
  if type(m) == "table" and type(m.lookup) == "table" then r.mix = m end
  return r
end

function topology.read(d, ps)
  ps = ps or topology.psets()[d.pset]
  if not ps or not ps.lookup[d.id] then return false end
  d.value = ps:get(d.id)
  local ok, raw = pcall(ps.get_raw, ps, d.id)
  d.raw = ok and type(raw) == "number" and raw or nil
  local ok2, s = pcall(ps.string, ps, d.id)
  d.display = ok2 and s or tostring(d.value)
  return true
end

function topology.describe(pname, id, role, label)
  local ps = topology.psets()[pname]
  if not ps or not id or not ps.lookup[id] then return nil end
  local p = ps:lookup_param(id)
  local d = { pset = pname, id = id, role = role, name = label or p.name or id }
  local t = p.t
  if t == ps.tCONTROL then
    d.type = "control"; d.min = p.controlspec.minval; d.max = p.controlspec.maxval
  elseif t == ps.tTAPER then
    d.type = "taper"; d.min = p.min; d.max = p.max
  elseif t == ps.tNUMBER then
    d.type = "number"; d.min = p.min; d.max = p.max
  elseif t == ps.tOPTION then
    d.type = "option"; d.options = p.options; d.min = 1; d.max = p.count
  elseif t == ps.tBINARY then
    d.type = "binary"; d.min = 0; d.max = 1
  else
    return nil
  end
  topology.read(d, ps)
  return d
end

-- first id from `ids` that exists in mix, then script params
local function find_ctl(ids, role, label)
  for _, pname in ipairs({ "mix", "script" }) do
    local ps = topology.psets()[pname]
    if ps then
      for _, id in ipairs(ids) do
        if ps.lookup[id] then return topology.describe(pname, id, role, label) end
      end
    end
  end
  return nil
end

local function compact(list)
  local out = {}
  for _, v in pairs(list) do if v then out[#out + 1] = v end end
  return out
end

function topology.build()
  local nodes, edges, watch = {}, {}, {}
  local by_id = {}

  local function track(c)
    if c then watch[#watch + 1] = c end
    return c
  end

  local function node(id, kind, label, layer, opts)
    local n = { id = id, kind = kind, label = label, layer = layer, controls = {} }
    for k, v in pairs(opts or {}) do n[k] = v end
    for _, c in ipairs(n.controls) do track(c) end
    nodes[#nodes + 1] = n
    by_id[id] = n
    return n
  end

  local function edge(src, dst, kind, gain, label)
    if not by_id[src] or not by_id[dst] then return end
    edges[#edges + 1] = {
      id = src .. "->" .. dst, source = src, target = dst,
      kind = kind or "audio", gain = track(gain), label = label,
    }
  end

  local function ctl(ids, role, label) return find_ctl(ids, role, label) end

  -- sources / sinks ---------------------------------------------------------

  node("src:adc", "source", "audio in", 0, { meter = "crone_in" })
  node("src:tape", "source", "tape play", 0)
  node("sink:dac", "sink", "audio out", 7, { meter = "crone_out" })

  -- supercollider -----------------------------------------------------------

  local ename = (engine and engine.name) or "none"
  node("sc:engine", "engine", "engine: " .. tostring(ename), 1)

  local voices, inactive = {}, {}
  local refs = rawget(_G, "nb_player_refcounts") or {}
  local players = rawget(_G, "note_players") or {}
  local names = {}
  for name in pairs(players) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if not name:match("^midi") then
      if (refs[name] or 0) > 0 then
        voices[#voices + 1] = name
      else
        inactive[#inactive + 1] = name
      end
    end
  end

  local any_sends = false
  for _, name in ipairs(voices) do
    local a = adapters.nb_voice(name) or {}
    local controls = compact({
      ctl({ a.level }, "level", "level"),
      ctl({ a.pan }, "pan", "pan"),
    })
    for _, id in ipairs(a.extra or {}) do
      local c = ctl({ id }, "param")
      if c then controls[#controls + 1] = c end
    end
    local vid = "nb:" .. name
    node(vid, "voice", name, 1, { controls = controls })
    if a.send_a or a.send_b then any_sends = true end
    by_id[vid].sends = { a = a.send_a, b = a.send_b }
  end

  node("bus:sc_main", "bus", "SC out", 3, { meter = "sc_main" })
  edge("sc:engine", "bus:sc_main")

  local fx = adapters.fx_mods()
  if #fx > 0 or any_sends then
    node("bus:sendA", "bus", "send A", 2, { meter = "sc_sendA" })
    node("bus:sendB", "bus", "send B", 2, { meter = "sc_sendB" })
  end

  for _, name in ipairs(voices) do
    local vid = "nb:" .. name
    local s = by_id[vid].sends
    by_id[vid].sends = nil
    edge(vid, "bus:sc_main")
    if s.a then edge(vid, "bus:sendA", "send", ctl({ s.a }, "send_a", "send A")) end
    if s.b then edge(vid, "bus:sendB", "send", ctl({ s.b }, "send_b", "send B")) end
  end

  -- fx mods: slot decides the edge (none / send a / send b / insert)
  local inserts = {}
  for _, prefix in ipairs(fx) do
    local slot = ctl({ prefix .. "_slot" }, "slot", "slot")
    local controls = compact({
      slot,
      ctl({ adapters.fx_level(prefix) }, "level", "level"),
      ctl({ prefix .. "_slot_drywet" }, "drywet", "dry/wet"),
    })
    local fid = "fx:" .. prefix
    node(fid, "fx", prefix:gsub("^fx_", ""), 3, { controls = controls })
    local v = slot and slot.value or 1
    if v == 2 then
      edge("bus:sendA", fid, "send")
      edge(fid, "bus:sc_main", "return")
    elseif v == 3 then
      edge("bus:sendB", fid, "send")
      edge(fid, "bus:sc_main", "return")
    elseif v == 4 then
      inserts[#inserts + 1] = fid
    end
  end

  -- crone mixer -------------------------------------------------------------

  node("crone:input", "crone", "input", 5, {
    controls = compact({ ctl({ "input", "input_level" }, "level", "input") }),
  })
  node("crone:monitor", "crone", "monitor", 6, {
    controls = compact({ ctl({ "monitor", "monitor_level" }, "level", "monitor"),
      ctl({ "monitor_mode" }, "param", "mode") }),
  })
  node("crone:eng", "crone", "engine", 5, {
    controls = compact({ ctl({ "engine", "engine_level" }, "level", "engine") }),
  })
  node("softcut", "softcut", "softcut", 5)
  node("crone:cut", "crone", "softcut", 6, {
    controls = compact({ ctl({ "cut", "softcut_level" }, "level", "softcut") }),
  })
  node("crone:tape", "crone", "tape", 5, {
    controls = compact({ ctl({ "tape", "tape_level" }, "level", "tape") }),
  })
  node("crone:rev", "reverb", "reverb", 6, {
    controls = compact({
      ctl({ "reverb" }, "enable", "reverb"),
      ctl({ "rev_pre_delay" }, "param", "pre delay"),
      ctl({ "rev_lf_fc" }, "param", "lf fc"),
      ctl({ "rev_low_time" }, "param", "low time"),
      ctl({ "rev_mid_time" }, "param", "mid time"),
      ctl({ "rev_hf_damping" }, "param", "hf damp"),
    }),
  })
  node("crone:out", "master", "main out", 7, {
    meter = "crone_out",
    controls = compact({
      ctl({ "output", "output_level" }, "level", "output"),
      ctl({ "compressor" }, "enable", "compressor"),
      ctl({ "comp_mix" }, "param", "comp mix"),
      ctl({ "comp_ratio" }, "param", "comp ratio"),
      ctl({ "comp_threshold" }, "param", "comp thresh"),
      ctl({ "headphone" }, "param", "headphone"),
    }),
  })

  -- sc output: main bus (through any inserts) -> crone engine channel
  local prev = "bus:sc_main"
  for _, fid in ipairs(inserts) do
    edge(prev, fid, "insert", nil, "insert")
    prev = fid
  end
  edge(prev, "crone:eng")

  edge("src:adc", "crone:input")
  edge("crone:input", "crone:monitor")
  edge("crone:monitor", "crone:out")
  edge("src:tape", "crone:tape")
  edge("crone:eng", "crone:out")
  edge("crone:tape", "crone:out")
  edge("softcut", "crone:cut")
  edge("crone:cut", "crone:out")

  edge("crone:input", "softcut", "send", ctl({ "cut_input_adc" }, "send", "adc → cut"))
  edge("crone:eng", "softcut", "send", ctl({ "cut_input_eng" }, "send", "eng → cut"))
  edge("crone:tape", "softcut", "send", ctl({ "cut_input_tape" }, "send", "tape → cut"))

  edge("crone:monitor", "crone:rev", "send", ctl({ "rev_monitor_input" }, "send", "rev send"))
  edge("crone:eng", "crone:rev", "send", ctl({ "rev_eng_input" }, "send", "rev send"))
  edge("crone:cut", "crone:rev", "send", ctl({ "rev_cut_input" }, "send", "rev send"))
  edge("crone:tape", "crone:rev", "send", ctl({ "rev_tape_input" }, "send", "rev send"))
  edge("crone:rev", "crone:out", "return", ctl({ "rev_return_level" }, "level", "rev return"))

  edge("crone:out", "sink:dac")

  local g = {
    version = 1,
    script = (norns and norns.state and norns.state.name) or "",
    engine = ename,
    voices_inactive = inactive,
    psets = {},
    nodes = nodes,
    edges = edges,
  }
  for k in pairs(topology.psets()) do g.psets[#g.psets + 1] = k end
  return g, watch
end

-- changes to any of these mean the graph shape (not just values) changed
function topology.signature()
  local parts = { tostring(engine and engine.name), tostring(#params.params) }
  local refs = rawget(_G, "nb_player_refcounts") or {}
  local names = {}
  for k, v in pairs(refs) do if v > 0 then names[#names + 1] = k end end
  table.sort(names)
  parts[#parts + 1] = table.concat(names, ",")
  for _, prefix in ipairs(adapters.fx_mods()) do
    parts[#parts + 1] = prefix .. "=" .. tostring(params:get(prefix .. "_slot"))
  end
  return table.concat(parts, "|")
end

return topology
