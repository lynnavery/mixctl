-- mixctl: network mix control for norns
-- serves a routing graph + mixer at http://<norns>:8740 via a python sidecar

local mod = require 'core/mods'
local topology = require 'mixctl/lib/topology'
local json = require 'mixctl/lib/json'

local PORT = 8740
local SIDECAR = { "127.0.0.1", PORT }
local SCLANG = { "localhost", 57120 }
local TOPO_FILE = "/tmp/mixctl_topology.json"
local MOD_DIR = _path.code .. "mixctl/"
local SETTINGS = _path.data .. "mixctl/settings.lua"

local state = {
  enabled = true,
  watch = {},
  last = {},
  sig = nil,
  vu = { 0, 0, 0, 0 },
  vu_chained = {},
  osc_wrapped = nil,
  metro = nil,
  ticks = 0,
}

-- sidecar process ------------------------------------------------------------

-- the [m] keeps pgrep/pkill from matching the `sh -c` running them
local PGREP_PATTERN = "'[m]ixctl/server/mixctl.py'"

local function server_running()
  return util.os_capture("pgrep -f " .. PGREP_PATTERN) ~= ""
end

local function start_server()
  if server_running() then return end
  -- absolute path so the pattern above matches the process
  os.execute("nohup python3 " .. MOD_DIR .. "server/mixctl.py --port " .. PORT ..
    " > /tmp/mixctl.log 2>&1 &")
end

local function stop_server()
  os.execute("pkill -f " .. PGREP_PATTERN)
end

local function load_settings()
  local ok, t = pcall(dofile, SETTINGS)
  if ok and type(t) == "table" and t.enabled ~= nil then state.enabled = t.enabled end
end

local function save_settings()
  util.make_dir(_path.data .. "mixctl")
  local f = io.open(SETTINGS, "w")
  if f then
    f:write("return { enabled = " .. tostring(state.enabled) .. " }\n")
    f:close()
  end
end

-- topology -------------------------------------------------------------------

local function dump()
  if not state.enabled then return end
  local ok, g, watch = pcall(topology.build)
  if not ok then
    print("mixctl: topology build failed: " .. tostring(g))
    return
  end
  state.watch = watch
  state.last = {}
  for _, c in ipairs(watch) do state.last[c.pset .. ":" .. c.id] = c.display end
  state.sig = topology.signature()
  local f = io.open(TOPO_FILE, "w")
  if f then
    f:write(json.encode(g))
    f:close()
    osc.send(SIDECAR, "/mixctl/topology_changed", {})
  end
end

-- send only the watched params whose display string changed since last tick
local function diff_params()
  local psets = topology.psets()
  for _, c in ipairs(state.watch) do
    if topology.read(c, psets[c.pset]) then
      local key = c.pset .. ":" .. c.id
      if state.last[key] ~= c.display then
        state.last[key] = c.display
        local v = c.value
        if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then v = -999 end
        osc.send(SIDECAR, "/mixctl/param", { c.pset, c.id, v + 0.0, (c.raw or -1) + 0.0, c.display })
      end
    end
  end
end

-- incoming osc -----------------------------------------------------------------

local function handle(path, args)
  if path == "/mixctl/set" then
    -- pset, id, mode ("raw"|"value"), value
    local pname, id, mode, value = args[1], args[2], args[3], tonumber(args[4])
    local ps = topology.psets()[pname]
    if ps and ps.lookup[id] and value then
      if mode == "raw" then ps:set_raw(id, value) else ps:set(id, value) end
    end
  elseif path == "/mixctl/dump" then
    dump()
  end
end

local function wrap_osc()
  if osc.event ~= nil and osc.event == state.osc_wrapped then return end
  -- capture per wrapper: if something wraps us and we re-wrap, reading a
  -- shared variable at call time would loop forever
  local orig = osc.event
  state.osc_wrapped = function(path, args, from)
    if type(path) == "string" and path:sub(1, 8) == "/mixctl/" then
      if state.enabled then handle(path, args) end
      return
    end
    if orig then return orig(path, args, from) end
  end
  osc.event = state.osc_wrapped
end

-- metering + polling ---------------------------------------------------------

-- each poll has a single callback; chain onto whatever the script set in
-- init() rather than replacing it, and leave its rate alone if it has one
local function start_polls()
  local names = { "amp_in_l", "amp_in_r", "amp_out_l", "amp_out_r" }
  for i, name in ipairs(names) do
    local p = poll.polls and poll.polls[name]
    if p and (p.callback == nil or p.callback ~= state.vu_chained[name]) then
      local prev = p.callback
      local cb = function(v)
        state.vu[i] = v
        if prev then prev(v) end
      end
      state.vu_chained[name] = cb
      p.callback = cb
      if not prev then p.time = 0.05 end
      p:start()
    end
  end
end

local function tick()
  if not state.enabled then return end
  state.ticks = state.ticks + 1
  wrap_osc() -- scripts can reassign osc.event at any time
  osc.send(SIDECAR, "/mixctl/vu", { state.vu[1] + 0.0, state.vu[2] + 0.0, state.vu[3] + 0.0, state.vu[4] + 0.0 })
  if state.ticks % 2 == 0 then diff_params() end
  if state.ticks % 5 == 0 and topology.signature() ~= state.sig then dump() end
end

-- script clear frees metros and polls, so these are rebuilt on every script init
local function start_runtime()
  if not state.enabled then return end
  wrap_osc()
  start_polls()
  state.metro = metro.init(tick, 0.1, -1)
  if state.metro then state.metro:start() end
  osc.send(SCLANG, "/mixctl/init", {})
  dump()
end

-- hooks ----------------------------------------------------------------------

mod.hook.register("system_post_startup", "mixctl start", function()
  load_settings()
  if state.enabled then start_server() end
end)

mod.hook.register("system_pre_shutdown", "mixctl stop", function()
  stop_server()
end)

mod.hook.register("script_pre_init", "mixctl sc meters", function()
  if state.enabled then osc.send(SCLANG, "/mixctl/init", {}) end
end)

mod.hook.register("script_post_init", "mixctl runtime", function()
  start_runtime()
end)

mod.hook.register("script_post_cleanup", "mixctl cleanup", function()
  state.metro = nil
  state.watch = {}
  if state.enabled then clock.run(function()
    -- give the clear a moment, then publish the empty-script graph
    clock.sleep(0.5)
    dump()
  end) end
end)

-- mod menu -------------------------------------------------------------------

local function ip()
  local w = rawget(_G, "wifi")
  if w and type(w.ip) == "string" and w.ip ~= "" then return w.ip end
  local s = util.os_capture("hostname -I | awk '{print $1}'")
  return s ~= "" and s or "norns.local"
end

local menu = { running = false, addr = "" }

menu.init = function()
  menu.running = server_running()
  menu.addr = ip() .. ":" .. PORT
end

menu.deinit = function() end

menu.key = function(n, z)
  if z ~= 1 then return end
  if n == 2 then
    mod.menu.exit()
  elseif n == 3 then
    state.enabled = not state.enabled
    save_settings()
    if state.enabled then
      start_server()
      start_runtime()
    else
      stop_server()
      if state.metro then
        state.metro:stop()
        metro.free(state.metro.id)
        state.metro = nil
      end
      osc.send(SCLANG, "/mixctl/cleanup", {})
    end
    menu.running = server_running()
    mod.menu.redraw()
  end
end

menu.enc = function(n, d) end

menu.redraw = function()
  screen.clear()
  screen.level(15)
  screen.move(0, 10)
  screen.text("MIXCTL")
  screen.level(4)
  screen.move(0, 26)
  screen.text("open in a browser:")
  screen.level(15)
  screen.move(0, 36)
  screen.text("http://" .. menu.addr)
  screen.level(4)
  screen.move(0, 52)
  screen.text("server: " .. (menu.running and "running" or "stopped"))
  screen.move(0, 62)
  screen.text("K3: " .. (state.enabled and "disable" or "enable"))
  screen.update()
end

mod.menu.register(mod.this_name, menu)

-- exposed for the repl: `require('mixctl/lib/mod').dump()`
return { dump = dump, state = state }
