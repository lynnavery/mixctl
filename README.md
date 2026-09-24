# mixctl

A norns mod that serves a network mix control panel at `http://<norns>:8740`:

- **signal flow**: a React Flow graph of audio routing through the crone mixer
  (input / monitor / engine / softcut / tape, reverb sends, output), the
  script's SuperCollider engine, active [nb](https://github.com/sixolet/nb)
  voices and their send A / B levels, and any mods built on the
  [fx mod](https://github.com/sixolet/fx) (each slot shows as none, send A,
  send B or insert). Click a node or cable to edit its levels.
- **jack ports**: the live `jack_lsp -c` graph shown as a patchbay. Turn on
  *edit connections* to connect ports by dragging, or select a cable and press
  Backspace to disconnect it. Disconnecting `crone:output_* → system:playback_*`
  is refused, so you can't silence the device by accident.
- **mixer**: channel strips with peak/RMS meters, a level fader, pan and sends.

Every change goes through the normal norns params, so the norns menus, PSETs
and the web UI stay in sync.

## install

```
;install https://github.com/lynnavery/mixctl
```

Then enable it in **SYSTEM > MODS > MIXCTL** and restart. The mod menu page
shows the URL. K3 turns it on or off.

## how it works

```
browser ──HTTP/SSE──▶ server/mixctl.py (python3, stdlib only, :8740)
                        │  OSC ⇄ matron (lib/mod.lua)  params, topology, crone VU polls
                        │  OSC ◀ sclang (lib/MixCtl.sc) SendPeakRMS on SC buses
                        │  jack_lsp / jack_connect / jack_disconnect
```

- `lib/mod.lua` starts the sidecar at boot. On every script init it rebuilds
  the graph (`lib/topology.lua`) and writes it to `/tmp/mixctl_topology.json`.
  A 10 Hz metro forwards crone in/out levels and any changed param values.
- `lib/MixCtl.sc` meters SC out [0,1] (read after any fx inserts), send A and
  send B from a group at the root tail, which runs after `FxSetup.fxGroup`.
- `lib/adapters.lua` maps nb voices to their level, pan and send params
  (mxsynths, smpKit, emplaitress, plus a name-based guess for other voices).

### limitations

- nb voices and the engine all sum onto SC's main out, so meters are per bus
  and per crone channel, not per voice.
- Several fx in the insert slot run in series in the order they were
  switched on. mixctl reads that order from the server's node tree
  (`/g_queryTree` on `FxSetup.insertGroup`) and numbers the insert cables.
  Until sclang answers, or if an insert's synth isn't found, the numbers get
  a `?` and the order falls back to alphabetical.
- The main out node has no meter. The only crone output level is the VU stream
  the MIX menu turns on. The `amp_out` polls meter `Crone.context.out_b`, which
  is the engine's output bus, so that meter is on the engine node.
- Softcut voice levels aren't shown (softcut has no getters). Softcut appears
  as a single channel.

## development

```
cd web && npm install
npm run mock      # sidecar with fake topology, jack graph and meters
npm run dev       # vite dev server, proxies /events and /api to the mock
npm run build     # writes ../www (committed, so the norns needs no node)
lua test/run.lua       # off-device check of lib/topology.lua; regenerates the mock graph
lua test/mod_test.lua  # osc.event wrapping, poll chaining, param set
```

Deploy to the norns without the web sources:

```
rsync -av --exclude web --exclude test --exclude .git ./ we@norns.local:~/dust/code/mixctl/
```

Logs: `/tmp/mixctl.log` on the norns.
