import { useMemo } from "react";
import {
  Background,
  BaseEdge,
  Controls,
  EdgeLabelRenderer,
  getBezierPath,
  Handle,
  Position,
  ReactFlow,
  type Edge,
  type EdgeProps,
  type Node,
  type NodeProps,
} from "@xyflow/react";
import { Graph, layout } from "@dagrejs/dagre";
import { type GEdge, type GNode, type Topology, useCtl, useStore } from "./store";
import { Meter } from "./Meter";
import { CtlSlider } from "./controls";

export type Selection = { type: "node"; id: string } | { type: "edge"; id: string } | null;

const NODE_W = 188;
const nodeHeight = (n: GNode) => 34 + (n.meter ? 14 : 0) + (n.controls.some((c) => c.role === "level") ? 34 : 0);

type FlowNodeData = { g: GNode };
type FlowEdgeData = { g: GEdge };

function FlowNode({ data, selected }: NodeProps<Node<FlowNodeData>>) {
  const n = data.g;
  const level = n.controls.find((c) => c.role === "level");
  return (
    <div className={`fnode kind-${n.kind} ${selected ? "selected" : ""}`} style={{ width: NODE_W }}>
      <Handle type="target" position={Position.Left} />
      <div className="fnode-head">
        <span className="kind-dot" />
        <span className="fnode-label">{n.label}</span>
        <span className="fnode-kind">{n.kind}</span>
      </div>
      {n.meter && <Meter id={n.meter} />}
      {level && <CtlSlider c={level} label={false} />}
      <Handle type="source" position={Position.Right} />
    </div>
  );
}

function GainEdge(props: EdgeProps<Edge<FlowEdgeData>>) {
  const { sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition, data, selected, markerEnd } = props;
  const [path, lx, ly] = getBezierPath({ sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition });
  const g = data!.g;
  return (
    <>
      <BaseEdge path={path} markerEnd={markerEnd} className={`fedge fedge-${g.kind} ${selected ? "selected" : ""}`} />
      {(g.gain || g.label) && (
        <EdgeLabelRenderer>
          <div
            className={`edge-label nodrag nopan ${selected ? "selected" : ""}`}
            style={{ transform: `translate(-50%, -50%) translate(${lx}px, ${ly}px)` }}
          >
            {g.gain ? <GainText g={g} /> : g.label}
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  );
}

function GainText({ g }: { g: GEdge }) {
  const v = useCtl(g.gain!);
  return <>{v.display}</>;
}

const nodeTypes = { flow: FlowNode };
const edgeTypes = { gain: GainEdge };

function build(t: Topology) {
  const dg = new Graph();
  dg.setGraph({ rankdir: "LR", nodesep: 18, ranksep: 70, marginx: 20, marginy: 20 });
  dg.setDefaultEdgeLabel(() => ({}));
  t.nodes.forEach((n) => dg.setNode(n.id, { width: NODE_W, height: nodeHeight(n) }));
  // return edges would create cycles; leave them out of the ranking
  t.edges.filter((e) => e.kind !== "return").forEach((e) => dg.setEdge(e.source, e.target));
  layout(dg);

  const nodes: Node<FlowNodeData>[] = t.nodes.map((n) => {
    const p = dg.node(n.id);
    return {
      id: n.id,
      type: "flow",
      position: { x: p.x - NODE_W / 2, y: p.y - nodeHeight(n) / 2 },
      data: { g: n },
    };
  });
  const edges: Edge<FlowEdgeData>[] = t.edges.map((e) => ({
    id: e.id,
    source: e.source,
    target: e.target,
    type: "gain",
    data: { g: e },
    animated: e.kind === "send",
  }));
  return { nodes, edges };
}

export function RoutingView({ onSelect }: { onSelect: (s: Selection) => void }) {
  const t = useStore((s) => s.topology);
  const graph = useMemo(() => (t ? build(t) : null), [t]);
  if (!graph) return <div className="empty">waiting for topology from matron…</div>;
  return (
    <ReactFlow
      nodes={graph.nodes}
      edges={graph.edges}
      nodeTypes={nodeTypes}
      edgeTypes={edgeTypes}
      nodesConnectable={false}
      fitView
      minZoom={0.2}
      proOptions={{ hideAttribution: true }}
      onNodeClick={(_, n) => onSelect({ type: "node", id: n.id })}
      onEdgeClick={(_, e) => onSelect({ type: "edge", id: e.id })}
      onPaneClick={() => onSelect(null)}
    >
      <Background gap={24} size={1} />
      <Controls showInteractive={false} />
    </ReactFlow>
  );
}

export function Inspector({ sel, onClose }: { sel: Selection; onClose: () => void }) {
  const t = useStore((s) => s.topology);
  if (!sel || !t) return null;
  if (sel.type === "node") {
    const n = t.nodes.find((x) => x.id === sel.id);
    if (!n) return null;
    const outs = t.edges.filter((e) => e.source === n.id && e.gain);
    const ins = t.edges.filter((e) => e.target === n.id && e.gain);
    return (
      <aside className="inspector">
        <header>
          <span className={`kind-dot kind-${n.kind}`} />
          <h2>{n.label}</h2>
          <button onClick={onClose} aria-label="close">×</button>
        </header>
        {n.meter && <Meter id={n.meter} className="meter-lg" />}
        {n.controls.length === 0 && outs.length === 0 && ins.length === 0 && (
          <p className="muted">no controls exposed</p>
        )}
        {n.controls.map((c) => (
          <CtlSlider key={c.id} c={c} />
        ))}
        {outs.length > 0 && <h3>sends</h3>}
        {outs.map((e) => (
          <CtlSlider key={e.id} c={{ ...e.gain!, name: `→ ${label(t, e.target)}` }} />
        ))}
        {ins.length > 0 && <h3>inputs</h3>}
        {ins.map((e) => (
          <CtlSlider key={e.id} c={{ ...e.gain!, name: `${label(t, e.source)} →` }} />
        ))}
      </aside>
    );
  }
  const e = t.edges.find((x) => x.id === sel.id);
  if (!e) return null;
  return (
    <aside className="inspector">
      <header>
        <h2>
          {label(t, e.source)} → {label(t, e.target)}
        </h2>
        <button onClick={onClose} aria-label="close">×</button>
      </header>
      <p className="muted">{e.kind}{e.label ? ` · ${e.label}` : ""}</p>
      {e.gain ? <CtlSlider c={e.gain} /> : <p className="muted">fixed connection (no gain param)</p>}
    </aside>
  );
}

const label = (t: Topology, id: string) => t.nodes.find((n) => n.id === id)?.label ?? id;
