import { type Ctl, setCtl, useCtl } from "./store";

// faders use the param's normalized raw value when norns provides one (so
// taper/warp matches the norns menu), otherwise the plain value range
function spec(c: Ctl, raw: number | null, value: number | null) {
  if (raw != null) return { mode: "raw" as const, min: 0, max: 1, step: 0.001, pos: raw };
  const lo = c.min ?? -60; // null min is -inf dB
  const hi = c.max ?? 1;
  const step = c.type === "number" ? 1 : (hi - lo) / 500;
  return { mode: "value" as const, min: lo, max: hi, step, pos: value ?? lo };
}

export function CtlSlider({ c, vertical = false, label = true }: { c: Ctl; vertical?: boolean; label?: boolean }) {
  const v = useCtl(c);
  if (c.type === "option") return <CtlSelect c={c} />;
  if (c.type === "binary") return <CtlToggle c={c} />;
  const s = spec(c, v.raw, v.value);
  return (
    <label className={`ctl ${vertical ? "ctl-v" : "ctl-h"}`} title={`${c.name} (${c.id})`}>
      {label && <span className="ctl-name">{c.name}</span>}
      <input
        type="range"
        className="nodrag"
        min={s.min}
        max={s.max}
        step={s.step}
        value={s.pos}
        onChange={(e) => setCtl(c, s.mode, Number(e.target.value))}
        onDoubleClick={() => c.role === "pan" && setCtl(c, "value", 0, "center")}
      />
      <span className="ctl-val">{v.display}</span>
    </label>
  );
}

export function CtlSelect({ c }: { c: Ctl }) {
  const v = useCtl(c);
  return (
    <label className="ctl ctl-h" title={c.id}>
      <span className="ctl-name">{c.name}</span>
      <select
        className="nodrag"
        value={v.value ?? 1}
        onChange={(e) => {
          const i = Number(e.target.value);
          setCtl(c, "value", i, c.options?.[i - 1]);
        }}
      >
        {(c.options ?? []).map((o, i) => (
          <option key={o + i} value={i + 1}>
            {o}
          </option>
        ))}
      </select>
    </label>
  );
}

export function CtlToggle({ c }: { c: Ctl }) {
  const v = useCtl(c);
  const on = (v.value ?? 0) > 0;
  return (
    <label className="ctl ctl-h" title={c.id}>
      <span className="ctl-name">{c.name}</span>
      <button className={`toggle nodrag ${on ? "on" : ""}`} onClick={() => setCtl(c, "value", on ? 0 : 1)}>
        {on ? "on" : "off"}
      </button>
    </label>
  );
}
