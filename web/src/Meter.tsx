import { useEffect, useRef } from "react";
import { meters } from "./store";

// one rAF loop draws every mounted meter straight from the mutable `meters`
// map, so 20 Hz meter traffic never re-renders react

type Entry = { canvas: HTMLCanvasElement; key: string; vertical: boolean; hold: number[]; holdAt: number[] };
const entries = new Set<Entry>();
let running = false;

const FLOOR_DB = -60;
const CEIL_DB = 6;

export function ampToPos(a: number) {
  if (!(a > 0)) return 0;
  const db = 20 * Math.log10(a);
  return Math.max(0, Math.min(1, (db - FLOOR_DB) / (CEIL_DB - FLOOR_DB)));
}

function color(name: string) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function draw() {
  const now = performance.now();
  const c = {
    bg: color("--meter-bg"),
    rms: color("--meter-rms"),
    peak: color("--meter-peak"),
    hot: color("--meter-hot"),
    hold: color("--meter-hold"),
  };
  const zeroPos = (0 - FLOOR_DB) / (CEIL_DB - FLOOR_DB);
  for (const e of entries) {
    const cv = e.canvas;
    const dpr = window.devicePixelRatio || 1;
    const w = cv.clientWidth, h = cv.clientHeight;
    if (cv.width !== w * dpr || cv.height !== h * dpr) {
      cv.width = w * dpr;
      cv.height = h * dpr;
    }
    const g = cv.getContext("2d")!;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.fillStyle = c.bg;
    g.fillRect(0, 0, w, h);
    // [peakL, rmsL, peakR, rmsR]
    const m = meters[e.key] ?? [0, 0, 0, 0];
    for (let ch = 0; ch < 2; ch++) {
      const peak = ampToPos(m[ch * 2]);
      const rms = ampToPos(m[ch * 2 + 1]);
      if (peak >= e.hold[ch] || now - e.holdAt[ch] > 1200) {
        e.hold[ch] = peak;
        e.holdAt[ch] = now;
      }
      const bar = (pos: number, fill: string) => {
        g.fillStyle = fill;
        if (e.vertical) {
          const bw = (w - 1) / 2;
          g.fillRect(ch * (bw + 1), h * (1 - pos), bw, h * pos);
        } else {
          const bh = (h - 1) / 2;
          g.fillRect(0, ch * (bh + 1), w * pos, bh);
        }
      };
      bar(peak, peak > zeroPos ? c.hot : c.peak);
      bar(rms, c.rms);
      g.fillStyle = e.hold[ch] > zeroPos ? c.hot : c.hold;
      if (e.vertical) {
        const bw = (w - 1) / 2;
        g.fillRect(ch * (bw + 1), h * (1 - e.hold[ch]), bw, 1.5);
      } else {
        const bh = (h - 1) / 2;
        g.fillRect(w * e.hold[ch] - 1.5, ch * (bh + 1), 1.5, bh);
      }
    }
  }
  if (entries.size) requestAnimationFrame(draw);
  else running = false;
}

export function Meter({ id, vertical = false, className }: { id: string; vertical?: boolean; className?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const e: Entry = { canvas: ref.current!, key: id, vertical, hold: [0, 0], holdAt: [0, 0] };
    entries.add(e);
    if (!running) {
      running = true;
      requestAnimationFrame(draw);
    }
    return () => {
      entries.delete(e);
    };
  }, [id, vertical]);
  return <canvas ref={ref} className={`meter ${vertical ? "meter-v" : "meter-h"} ${className ?? ""}`} />;
}
