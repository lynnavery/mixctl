import { useMemo, useState } from "react";
import { Background, Controls, Handle, Position, ReactFlow, type Edge, type Node, type NodeProps } from "@xyflow/react";
import { type Jack, jackEdit, useStore } from "./store";

// patchbay layout: every jack client is split into an outputs block (left
// column) and an inputs block (right column), so the graph never loops back

const PORT_H = 22;
const HEAD_H = 30;
const COL_GAP = 360;
const BLOCK_W = 200;

type BlockData = { client: string; dir: "in" | "out"; ports: string[] };

function Block({ data }: NodeProps<Node<BlockData>>) {
  const isOut = data.dir === "out";
  return (
    <div className={`jblock jblock-${data.dir} client-${data.client}`} style={{ width: BLOCK_W }}>
      <div className="jblock-head">
        {data.client} <span className="muted">{isOut ? "outputs" : "inputs"}</span>
      </div>
      {data.ports.map((p) => (
        <div key={p} className="jport" style={{ height: PORT_H }}>
          {!isOut && <Handle type="target" position={Position.Left} id={p} />}
          <span>{p.split(":")[1]}</span>
          {isOut && <Handle type="source" position={Position.Right} id={p} />}
        </div>
      ))}
    </div>
  );
}

const nodeTypes = { block: Block };

function build(j: Jack) {
  const groups = new Map<string, BlockData>();
  for (const p of j.ports) {
    const client = p.name.split(":")[0];
    const dir = p.dir === "out" ? "out" : "in";
    const key = `${client}#${dir}`;
    if (!groups.has(key)) groups.set(key, { client, dir, ports: [] });
    groups.get(key)!.ports.push(p.name);
  }
  const y = { in: 0, out: 0 };
  const nodes: Node<BlockData>[] = [...groups.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, d]) => {
      const pos = { x: d.dir === "out" ? 0 : COL_GAP, y: y[d.dir] };
      y[d.dir] += HEAD_H + d.ports.length * PORT_H + 24;
      return { id: key, type: "block", position: pos, data: d };
    });
  const edges: Edge[] = j.connections.map((c) => {
    const client = (p: string) => p.split(":")[0];
    return {
      id: `${c.src}>${c.dst}`,
      source: `${client(c.src)}#out`,
      sourceHandle: c.src,
      target: `${client(c.dst)}#in`,
      targetHandle: c.dst,
      className: `jedge client-${client(c.src)}`,
    };
  });
  return { nodes, edges };
}

export function JackView() {
  const jack = useStore((s) => s.jack);
  const [edit, setEdit] = useState(false);
  const graph = useMemo(() => (jack ? build(jack) : null), [jack]);
  if (!jack) return <div className="empty">waiting for jack graph…</div>;
  if (!jack.ok) return <div className="empty">jack unavailable: {jack.error}</div>;
  return (
    <div className="jack-wrap">
      <div className="jack-bar">
        <label className="switch">
          <input type="checkbox" checked={edit} onChange={(e) => setEdit(e.target.checked)} />
          edit connections
        </label>
        <span className="muted">
          {edit
            ? "drag from an output to an input to connect · select a cable and press Backspace to remove it"
            : "read-only view of jack_lsp -c"}
        </span>
      </div>
      <ReactFlow
        nodes={graph!.nodes}
        edges={graph!.edges}
        nodeTypes={nodeTypes}
        nodesConnectable={edit}
        edgesFocusable={edit}
        elementsSelectable={edit}
        deleteKeyCode={edit ? ["Backspace", "Delete"] : null}
        onConnect={(c) => c.sourceHandle && c.targetHandle && jackEdit("connect", c.sourceHandle, c.targetHandle)}
        onEdgesDelete={(es) =>
          es.forEach((e) => e.sourceHandle && e.targetHandle && jackEdit("disconnect", e.sourceHandle, e.targetHandle))
        }
        fitView
        proOptions={{ hideAttribution: true }}
      >
        <Background gap={24} size={1} />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  );
}
