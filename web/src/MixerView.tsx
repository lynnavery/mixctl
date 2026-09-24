import { type GNode, type Topology, useStore } from "./store";
import { Meter } from "./Meter";
import { CtlSlider } from "./controls";

// strip order follows the signal: inputs, voices, buses/fx, crone, master
const ORDER = ["source", "voice", "engine", "bus", "fx", "crone", "softcut", "reverb", "master"];

function Strip({ n, t }: { n: GNode; t: Topology }) {
  const level = n.controls.find((c) => c.role === "level");
  const pan = n.controls.find((c) => c.role === "pan");
  const others = n.controls.filter((c) => c !== level && c !== pan && c.role !== "param");
  const sends = t.edges.filter((e) => e.source === n.id && e.gain && e.kind !== "return");
  const returns = t.edges.filter((e) => e.target === n.id && e.gain && e.kind === "return");
  const name = (id: string) => t.nodes.find((x) => x.id === id)?.label ?? id;
  return (
    <section className={`strip kind-${n.kind}`}>
      <header>
        <span className="kind-dot" />
        <span className="strip-name" title={n.id}>{n.label}</span>
      </header>
      <div className="strip-sends">
        {others.map((c) => (
          <CtlSlider key={c.id} c={c} />
        ))}
        {sends.map((e) => (
          <CtlSlider key={e.id} c={{ ...e.gain!, name: `→ ${name(e.target)}` }} />
        ))}
        {returns.map((e) => (
          <CtlSlider key={e.id} c={{ ...e.gain!, name: "return" }} />
        ))}
      </div>
      {pan && <CtlSlider c={pan} />}
      <div className="strip-main">
        {n.meter ? <Meter id={n.meter} vertical /> : <div className="meter meter-v meter-none" title="no meter on this channel" />}
        {level ? <CtlSlider c={level} vertical label={false} /> : <div className="fader-none" />}
      </div>
    </section>
  );
}

export function MixerView() {
  const t = useStore((s) => s.topology);
  if (!t) return <div className="empty">waiting for topology from matron…</div>;
  const strips = t.nodes
    .filter((n) => n.meter || n.controls.some((c) => c.role === "level") || n.kind === "fx")
    .filter((n) => n.kind !== "sink")
    .sort((a, b) => ORDER.indexOf(a.kind) - ORDER.indexOf(b.kind));
  return (
    <div className="mixer">
      {strips.map((n) => (
        <Strip key={n.id} n={n} t={t} />
      ))}
      {t.voices_inactive.length > 0 && (
        <p className="muted mixer-note">inactive nb voices: {t.voices_inactive.join(", ")}</p>
      )}
    </div>
  );
}
