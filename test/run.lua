-- off-device check for lib/topology.lua: stubs just enough of the norns
-- param API to build a graph, then writes server/mock_topology.json.
--   lua test/run.lua     (run from the repo root)

package.path = "../?.lua;" .. package.path -- so require 'mixctl/lib/x' resolves

local ParamSet = {
  tSEPARATOR = 0, tNUMBER = 1, tOPTION = 2, tCONTROL = 3, tFILE = 4,
  tTAPER = 5, tTRIGGER = 6, tGROUP = 7, tTEXT = 8, tBINARY = 9,
}
ParamSet.__index = ParamSet

function ParamSet.new()
  return setmetatable({ params = {}, lookup = {} }, ParamSet)
end

function ParamSet:add(p)
  self.params[#self.params + 1] = p
  self.lookup[p.id] = #self.params
end

function ParamSet:control(id, name, min, max, v)
  self:add({ id = id, name = name, t = self.tCONTROL, controlspec = { minval = min, maxval = max }, v = v })
end

function ParamSet:option(id, name, options, v)
  self:add({ id = id, name = name, t = self.tOPTION, options = options, count = #options, v = v })
end

function ParamSet:number(id, name, min, max, v)
  self:add({ id = id, name = name, t = self.tNUMBER, min = min, max = max, v = v })
end

function ParamSet:lookup_param(id)
  local i = self.lookup[id]
  if not i then error("invalid paramset index: " .. tostring(id)) end
  return self.params[i]
end

function ParamSet:get(id) return self:lookup_param(id).v end

function ParamSet:get_raw(id)
  local p = self:lookup_param(id)
  if p.t ~= self.tCONTROL then error("no raw") end
  return (p.v - p.controlspec.minval) / (p.controlspec.maxval - p.controlspec.minval)
end

function ParamSet:string(id)
  local p = self:lookup_param(id)
  if p.t == self.tOPTION then return p.options[p.v] end
  if p.v == -math.huge then return "-inf dB" end
  return string.format("%.2f", p.v)
end

-- norns globals -----------------------------------------------------------------

params = ParamSet.new()
mix = ParamSet.new()
engine = { name = "PolyPerc" }
norns = { state = { name = "awake" } }
tab = {}

for _, id in ipairs({ "output", "input", "monitor", "engine", "cut", "tape" }) do
  mix:number(id, id, -math.huge, 6, 0)
end
mix:option("monitor_mode", "monitor mode", { "stereo", "mono" }, 1)
mix:option("headphone", "headphone", { "0", "1", "2" }, 1)
for _, id in ipairs({ "rev_eng_input", "rev_cut_input", "rev_monitor_input", "rev_tape_input", "rev_return_level" }) do
  mix:number(id, id, -math.huge, 18, -9)
end
mix:option("reverb", "reverb", { "off", "on" }, 2)
mix:option("compressor", "compressor", { "off", "on" }, 2)
mix:control("comp_mix", "mix", 0, 1, 1)
for _, id in ipairs({ "cut_input_adc", "cut_input_eng", "cut_input_tape" }) do
  mix:number(id, id, -math.huge, 18, 0)
end

-- nb_mxsynths + emplaitress voice 1 active, fx_dverb on send A, ffbc insert
params:control("nb_mxsynths_amp", "amp", 0, 1, 0.8)
params:control("nb_mxsynths_pan", "pan", -1, 1, 0)
params:control("nb_mxsynths_send_a", "send a", 0, 1, 0.3)
params:control("nb_mxsynths_send_b", "send b", 0, 1, 0)
params:control("plaits_amp_1", "amp", 0, 1, 0.2)
params:control("plaits_gain_1", "gain", 0, 3, 1)
params:control("plaits_pan_1", "pan", -1, 1, -0.3)
params:control("plaits_send_a_1", "send a", 0, 1, 0)
params:control("plaits_send_b_1", "send b", 0, 1, 0.5)
local slots = { "none", "send a", "send b", "insert" }
params:option("fx_dverb_slot", "slot", slots, 2)
params:control("fx_dverb_slot_drywet", "dry/wet", 0, 1, 1)
params:control("fx_dverb_level", "level", 0, 1, 1)
params:option("fx_grains_slot", "slot", slots, 3)
params:control("fx_grains_slot_drywet", "dry/wet", 0, 1, 1)
params:option("fx_ffbc_slot", "slot", slots, 4)
params:control("fx_ffbc_slot_drywet", "dry/wet", 0, 1, 0.5)
-- fx_llll: subpath "/fx_llll" but params are "fx_ll_*"
params:option("fx_ll_slot", "slot", slots, 4)
params:control("fx_ll_slot_drywet", "dry/wet", 0, 1, 0.5)

note_players = { mxsynths = {}, ["emplait 1"] = {}, ["emplait 2"] = {}, smpKit = {}, ["midi: uno 1"] = {} }
nb_player_refcounts = { mxsynths = 1, ["emplait 1"] = 2 }

-- run ------------------------------------------------------------------------------

local topology = require 'mixctl/lib/topology'
local json = require 'mixctl/lib/json'

local g, watch = topology.build()

local ids = {}
for _, n in ipairs(g.nodes) do ids[n.id] = true end
for _, e in ipairs(g.edges) do
  assert(ids[e.source] and ids[e.target], "dangling edge " .. e.id)
end
assert(ids["nb:mxsynths"] and ids["nb:emplait 1"], "active voices missing")
assert(not ids["nb:emplait 2"] and not ids["nb:midi: uno 1"], "inactive voice shown")
assert(ids["fx:fx_dverb"] and ids["fx:fx_ffbc"], "fx missing")

local has = {}
for _, e in ipairs(g.edges) do has[e.id] = e end
assert(has["bus:sendA->fx:fx_dverb"], "dverb should be on send A")
assert(has["bus:sendB->fx:fx_grains"], "grains should be on send B")
-- no order from sclang yet: alphabetical, flagged as unknown
assert(has["bus:sc_main->fx:fx_ffbc"] and has["fx:fx_ffbc->fx:fx_ll"] and has["fx:fx_ll->crone:eng"],
  "alphabetical insert chain")
assert(g.insert_order_known == false and has["bus:sc_main->fx:fx_ffbc"].label == "insert 1?")
assert(has["nb:mxsynths->bus:sendA"].gain.id == "nb_mxsynths_send_a")
assert(has["crone:eng->crone:rev"].gain.pset == "mix")

-- sclang reports llll activated first: chain follows the node tree
local g2 = topology.build({ "fx_llll", "fx_ffbc" })
local has2 = {}
for _, e in ipairs(g2.edges) do has2[e.id] = e end
assert(has2["bus:sc_main->fx:fx_ll"] and has2["fx:fx_ll->fx:fx_ffbc"] and has2["fx:fx_ffbc->crone:eng"],
  "insert chain should follow sclang order")
assert(g2.insert_order_known and has2["bus:sc_main->fx:fx_ll"].label == "insert 1")
assert(g2.inserts[1] == "fx:fx_ll" and g2.inserts[2] == "fx:fx_ffbc")

-- a partial report (one insert unknown to sclang) keeps known ones first, flags it
local g3 = topology.build({ "fx_ffbc" })
assert(g3.inserts[1] == "fx:fx_ffbc" and not g3.insert_order_known)

print(string.format("ok: %d nodes, %d edges, %d watched controls, sig=%s",
  #g.nodes, #g.edges, #watch, topology.signature()))

local f = assert(io.open("server/mock_topology.json", "w"))
f:write(json.encode(g))
f:close()
print("wrote server/mock_topology.json")
