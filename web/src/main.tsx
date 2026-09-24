import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import "@xyflow/react/dist/style.css";
import "./styles.css";
import { connect, requestDump, useStore } from "./store";
import { Inspector, RoutingView, type Selection } from "./RoutingView";
import { JackView } from "./JackView";
import { MixerView } from "./MixerView";

type Tab = "flow" | "jack" | "mixer";
const TABS: [Tab, string][] = [
  ["flow", "signal flow"],
  ["jack", "jack ports"],
  ["mixer", "mixer"],
];

function readTab(): Tab {
  const h = location.hash.slice(1);
  return TABS.some(([t]) => t === h) ? (h as Tab) : "flow";
}

function App() {
  const [tab, setTab] = useState<Tab>(readTab);
  const [sel, setSel] = useState<Selection>(null);
  const connected = useStore((s) => s.connected);
  const matron = useStore((s) => s.matron);
  const t = useStore((s) => s.topology);
  const toast = useStore((s) => s.toast);

  useEffect(() => {
    const on = () => setTab(readTab());
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);

  return (
    <div className="app">
      <header className="topbar">
        <h1>mixctl</h1>
        <nav>
          {TABS.map(([id, name]) => (
            <a key={id} href={`#${id}`} className={tab === id ? "active" : ""}>
              {name}
            </a>
          ))}
        </nav>
        <div className="status">
          {t && (
            <span className="muted">
              {t.script || "no script"} · {t.engine}
            </span>
          )}
          <span className={`dot ${connected ? "ok" : "bad"}`} title="sidecar connection" />
          <span className="muted">server</span>
          <span className={`dot ${matron ? "ok" : "bad"}`} title="matron heartbeat" />
          <span className="muted">matron</span>
          <button onClick={() => requestDump()} title="ask matron to rebuild the graph">
            refresh
          </button>
        </div>
      </header>
      <main className={`view view-${tab}`}>
        {tab === "flow" && (
          <>
            <div className="canvas">
              <RoutingView onSelect={setSel} />
            </div>
            <Inspector sel={sel} onClose={() => setSel(null)} />
          </>
        )}
        {tab === "jack" && <JackView />}
        {tab === "mixer" && <MixerView />}
      </main>
      {toast && <div className="toast">{toast}</div>}
    </div>
  );
}

connect();
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
