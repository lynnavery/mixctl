-- off-device check for lib/mod.lua: osc.event wrapping, poll chaining and
-- /mixctl/set, against stubbed norns globals.
--   lua test/mod_test.lua     (run from the repo root)

package.path = "../?.lua;" .. package.path

local sent, hooks, executed = {}, {}, {}

package.loaded['core/mods'] = {
  this_name = "mixctl",
  hook = { register = function(h, name, f) hooks[h] = f end },
  menu = { register = function() end, redraw = function() end, exit = function() end },
}

_path = { code = "/home/we/dust/code/", data = "/tmp/mixctl_test_data/" }
util = { os_capture = function() return "" end, make_dir = function() end }
os.execute = function(cmd) executed[#executed + 1] = cmd end
osc = { send = function(to, path, args) sent[#sent + 1] = { to = to, path = path, args = args } end }
clock = { run = function() end, sleep = function() end }
engine = { name = "PolyPerc" }
norns = { state = { name = "test" } }

local function mkpoll()
  return { callback = nil, time = 1, started = false, start = function(self) self.started = true end }
end
poll = { polls = { amp_in_l = mkpoll(), amp_in_r = mkpoll(), amp_out_l = mkpoll(), amp_out_r = mkpoll() } }

local metros = {}
metro = {
  init = function(f, t) local m = { id = #metros + 1, f = f, start = function() end, stop = function() end }; metros[#metros + 1] = m; return m end,
  free = function() end,
}

-- minimal paramset with one control
local set_calls = {}
params = {
  tCONTROL = 3, tOPTION = 2, tNUMBER = 1, tTAPER = 5, tBINARY = 9,
  params = { { id = "x_amp", name = "amp", t = 3, controlspec = { minval = 0, maxval = 1 } } },
  lookup = { x_amp = 1 }, v = 0.5,
  lookup_param = function(self, id) return self.params[self.lookup[id]] end,
  get = function(self) return self.v end,
  get_raw = function(self) return self.v end,
  string = function(self) return tostring(self.v) end,
  set = function(self, id, v) set_calls[#set_calls + 1] = { "set", id, v }; self.v = v end,
  set_raw = function(self, id, v) set_calls[#set_calls + 1] = { "raw", id, v }; self.v = v end,
}

require 'mixctl/lib/mod'

-- server start uses an absolute path that the [m] pgrep pattern matches
hooks.system_post_startup()
assert(executed[1]:find("python3 /home/we/dust/code/mixctl/server/mixctl.py", 1, true), executed[1])

-- a script sets its own osc handler and poll callback in init()
local script_osc = {}
osc.event = function(path) script_osc[#script_osc + 1] = path end
local script_vu = {}
poll.polls.amp_in_l.callback = function(v) script_vu[#script_vu + 1] = v end
poll.polls.amp_in_l.time = 0.5

hooks.script_post_init()

-- polls: chained, script callback still fires, script rate untouched
poll.polls.amp_in_l.callback(0.7)
assert(script_vu[1] == 0.7, "script poll callback lost")
assert(poll.polls.amp_in_l.time == 0.5, "script poll rate changed")
assert(poll.polls.amp_out_l.time == 0.05 and poll.polls.amp_out_l.started, "idle poll not started")

-- another mod wraps osc.event after us, then our tick re-wraps
local ours = osc.event
local other_seen = 0
osc.event = function(path, args, from) other_seen = other_seen + 1; return ours(path, args, from) end
metros[#metros].f() -- tick → wrap_osc
osc.event("/some/script/path", {}, {})
assert(script_osc[#script_osc] == "/some/script/path", "script osc not reached")
assert(other_seen == 1, "other wrapper not reached exactly once")

-- /mixctl/set is handled and not passed to the script
local before = #script_osc
osc.event("/mixctl/set", { "script", "x_amp", "raw", 0.25 }, {})
assert(#script_osc == before, "/mixctl/ leaked to script handler")
assert(set_calls[#set_calls][1] == "raw" and set_calls[#set_calls][3] == 0.25, "set_raw not called")

-- repeated post_init (script reload) doesn't double-chain polls
hooks.script_post_init()
script_vu = {}
poll.polls.amp_in_l.callback(0.1)
assert(#script_vu == 1, "poll callback chained twice")

print("ok: mod.lua osc wrap, poll chaining, set, server launch")
