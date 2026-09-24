import { useSyncExternalStore } from "react";

// ---- types mirror lib/topology.lua and server/mixctl.py -------------------

export type Ctl = {
  pset: string;
  id: string;
  role: string;
  name: string;
  type: "control" | "taper" | "number" | "option" | "binary";
  min: number | null;
  max: number | null;
  value: number | null;
  raw: number | null;
  display: string;
  options?: string[];
};

export type GNode = {
  id: string;
  kind: string;
  label: string;
  layer: number;
  meter?: string;
  controls: Ctl[];
};

export type GEdge = {
  id: string;
  source: string;
  target: string;
  kind: "audio" | "send" | "return" | "insert";
  gain?: Ctl | null;
  label?: string;
};

export type Topology = {
  script: string;
  engine: string;
  voices_inactive: string[];
  nodes: GNode[];
  edges: GEdge[];
};

export type JackPort = { name: string; dir: "in" | "out" | "?" };
export type Jack = {
  ports: JackPort[];
  connections: { src: string; dst: string }[];
  ok: boolean;
  error: string | null;
};

export type CtlValue = { value: number | null; raw: number | null; display: string };

type State = {
  connected: boolean;
  matron: boolean;
  topology: Topology | null;
  jack: Jack | null;
  values: Record<string, CtlValue>;
  toast: string | null;
};

// ---- store ----------------------------------------------------------------

let state: State = {
  connected: false,
  matron: false,
  topology: null,
  jack: null,
  values: {},
  toast: null,
};
const listeners = new Set<() => void>();

function set(patch: Partial<State>) {
  state = { ...state, ...patch };
  listeners.forEach((l) => l());
}

export function useStore<T>(sel: (s: State) => T): T {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => sel(state),
  );
}

export const ctlKey = (c: { pset: string; id: string }) => `${c.pset}:${c.id}`;

export function useCtl(c: Ctl): CtlValue {
  return useStore((s) => s.values[ctlKey(c)]) ?? c;
}

let toastTimer: number | undefined;
export function toast(msg: string) {
  set({ toast: msg });
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => set({ toast: null }), 4000);
}

// meters change at 20 Hz; kept outside react state and read by a rAF loop
export const meters: Record<string, number[]> = {};

// ---- server connection ----------------------------------------------------

function valuesFrom(t: Topology): Record<string, CtlValue> {
  const v: Record<string, CtlValue> = {};
  const add = (c?: Ctl | null) => {
    if (c) v[ctlKey(c)] = { value: c.value, raw: c.raw, display: c.display };
  };
  t.nodes.forEach((n) => n.controls.forEach(add));
  t.edges.forEach((e) => add(e.gain));
  return v;
}

export function connect() {
  const es = new EventSource("events");
  es.onopen = () => set({ connected: true });
  es.onerror = () => set({ connected: false });
  es.addEventListener("topology", (e) => {
    const t = JSON.parse((e as MessageEvent).data) as Topology;
    set({ topology: t, values: valuesFrom(t) });
  });
  es.addEventListener("jack", (e) => set({ jack: JSON.parse((e as MessageEvent).data) }));
  es.addEventListener("status", (e) => set({ matron: JSON.parse((e as MessageEvent).data).matron }));
  es.addEventListener("param", (e) => {
    const p = JSON.parse((e as MessageEvent).data);
    const key = `${p.pset}:${p.id}`;
    // don't fight a fader that's being dragged (matron echoes lag by ~200 ms);
    // hold the newest echo and apply it once the fader has been still a while
    const since = Date.now() - (touched.get(key) ?? 0);
    const apply = () => {
      deferred.delete(key);
      set({ values: { ...state.values, [key]: { value: p.value, raw: p.raw, display: p.display } } });
    };
    if (since >= ECHO_HOLD_MS) return apply();
    clearTimeout(deferred.get(key));
    deferred.set(key, window.setTimeout(apply, ECHO_HOLD_MS - since));
  });
  es.addEventListener("meters", (e) => Object.assign(meters, JSON.parse((e as MessageEvent).data)));
}

// ---- control writes (throttled per param, trailing edge kept) -------------

const pending = new Map<string, { timer: number; body: object }>();
const touched = new Map<string, number>();
const deferred = new Map<string, number>();
const THROTTLE_MS = 33;
const ECHO_HOLD_MS = 500;

async function post(path: string, body: object) {
  try {
    const r = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    if (!j.ok) toast(j.error || "request failed");
    return j;
  } catch {
    toast("server unreachable");
    return { ok: false };
  }
}

export function setCtl(c: Ctl, mode: "raw" | "value", value: number, display?: string) {
  const key = ctlKey(c);
  touched.set(key, Date.now());
  const held = deferred.get(key);
  if (held) {
    // stale now; matron will echo this newer move
    clearTimeout(held);
    deferred.delete(key);
  }
  const cur = state.values[key] ?? c;
  set({
    values: {
      ...state.values,
      [key]: {
        value: mode === "value" ? value : cur.value,
        raw: mode === "raw" ? value : cur.raw,
        display: display ?? cur.display,
      },
    },
  });
  const body = { pset: c.pset, id: c.id, mode, value };
  const p = pending.get(key);
  if (p) {
    p.body = body;
    return;
  }
  post("api/set", body);
  const entry = { body, timer: 0 };
  entry.timer = window.setTimeout(function flush() {
    const last = pending.get(key);
    pending.delete(key);
    if (last && last.body !== body) post("api/set", last.body);
  }, THROTTLE_MS);
  pending.set(key, entry);
}

export function jackEdit(op: "connect" | "disconnect", src: string, dst: string) {
  return post("api/jack", { op, src, dst });
}

export function requestDump() {
  return post("api/dump", {});
}
