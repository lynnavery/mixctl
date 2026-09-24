#!/usr/bin/env python3
"""mixctl sidecar: bridges matron/sclang OSC and JACK to a browser.

stdlib only. HTTP (static files + SSE + JSON POST) and UDP OSC share one port
number: TCP for the browser, UDP (localhost) for matron and sclang.
"""

import argparse
import json
import math
import os
import queue
import random
import socket
import struct
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
WWW = os.path.join(HERE, "..", "www")
TOPO_FILE = "/tmp/mixctl_topology.json"
MATRON = ("127.0.0.1", 10111)
METER_HZ = 20
JACK_POLL_S = 2.0

# osc -------------------------------------------------------------------------


def _pad(b):
    return b + b"\0" * (4 - len(b) % 4)


def osc_encode(path, *args):
    tags = ","
    data = b""
    for a in args:
        if isinstance(a, bool):
            tags += "T" if a else "F"
        elif isinstance(a, int):
            tags += "i"
            data += struct.pack(">i", a)
        elif isinstance(a, float):
            tags += "f"
            data += struct.pack(">f", a)
        else:
            tags += "s"
            data += _pad(str(a).encode())
    return _pad(path.encode()) + _pad(tags.encode()) + data


def _read_str(buf, i):
    end = buf.index(b"\0", i)
    s = buf[i:end].decode(errors="replace")
    return s, (end + 4) & ~3


def osc_decode(buf):
    """returns (path, args) or None; ignores bundles"""
    if not buf or buf[:1] != b"/":
        return None
    path, i = _read_str(buf, 0)
    if i >= len(buf):
        return path, []
    tags, i = _read_str(buf, i)
    args = []
    for t in tags[1:]:
        if t == "i":
            args.append(struct.unpack(">i", buf[i:i + 4])[0]); i += 4
        elif t == "f":
            args.append(struct.unpack(">f", buf[i:i + 4])[0]); i += 4
        elif t == "d":
            args.append(struct.unpack(">d", buf[i:i + 8])[0]); i += 8
        elif t == "h":
            args.append(struct.unpack(">q", buf[i:i + 8])[0]); i += 8
        elif t in "sS":
            s, i = _read_str(buf, i); args.append(s)
        elif t == "T":
            args.append(True)
        elif t == "F":
            args.append(False)
        elif t in "NI":
            args.append(None)
        else:
            break
    return path, args


# state + fan-out ---------------------------------------------------------------


class Hub:
    def __init__(self):
        self.lock = threading.Lock()
        self.clients = set()
        self.topology = None
        self.jack = {"ports": [], "connections": [], "ok": False, "error": None}
        self.meters = {}
        self.dirty_meters = False
        self.last_matron = 0.0

    def subscribe(self):
        q = queue.Queue(maxsize=256)
        with self.lock:
            self.clients.add(q)
        return q

    def unsubscribe(self, q):
        with self.lock:
            self.clients.discard(q)

    def publish(self, event, data):
        msg = "event: %s\ndata: %s\n\n" % (event, json.dumps(data, separators=(",", ":")))
        with self.lock:
            clients = list(self.clients)
        for q in clients:
            try:
                q.put_nowait(msg)
            except queue.Full:
                pass  # slow client; it'll resync on the next topology event

    def snapshot(self):
        return {
            "topology": self.topology,
            "jack": self.jack,
            "status": self.status(),
        }

    def status(self):
        return {"matron": time.time() - self.last_matron < 3.0}

    def set_meter(self, key, values):
        self.meters[key] = values
        self.dirty_meters = True

    def set_param(self, pset, pid, value, raw, display):
        """mirror a param change into the cached topology, then publish it"""
        topo = self.topology
        if topo:
            ctls = [c for n in topo.get("nodes", []) for c in n.get("controls", [])]
            ctls += [e["gain"] for e in topo.get("edges", []) if e.get("gain")]
            for c in ctls:
                if c["pset"] == pset and c["id"] == pid:
                    c["value"], c["raw"], c["display"] = value, raw, display
        self.publish("param", {"pset": pset, "id": pid, "value": value, "raw": raw, "display": display})


# jack ----------------------------------------------------------------------------


def jack_graph():
    try:
        out = subprocess.run(["jack_lsp", "-c", "-p"], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"ports": [], "connections": [], "ok": False, "error": str(e)}
    if out.returncode != 0:
        return {"ports": [], "connections": [], "ok": False, "error": out.stderr.strip()}
    ports, conns, cur = [], [], None
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            cur = {"name": line.strip(), "dir": "?"}
            ports.append(cur)
        elif line.strip().startswith("properties:"):
            props = line.split(":", 1)[1]
            cur["dir"] = "out" if "output" in props else "in"
        elif cur is not None:
            conns.append((cur, line.strip()))
    # each connection is listed on both ends; keep the output side only
    connections = sorted({(p["name"], dst) for p, dst in conns if p["dir"] == "out"})
    return {
        "ports": ports,
        "connections": [{"src": s, "dst": d} for s, d in connections],
        "ok": True,
        "error": None,
    }


PROTECTED = ("crone:output_", "system:playback_")


def jack_edit(op, src, dst, force=False):
    if op not in ("connect", "disconnect"):
        return False, "bad op"
    if op == "disconnect" and not force and src.startswith(PROTECTED[0]) and dst.startswith(PROTECTED[1]):
        return False, "refusing to disconnect main output (pass force)"
    cmd = "jack_connect" if op == "connect" else "jack_disconnect"
    try:
        out = subprocess.run([cmd, src, dst], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)
    return out.returncode == 0, (out.stderr or out.stdout).strip()


# workers -----------------------------------------------------------------------


def load_topology(hub):
    try:
        with open(TOPO_FILE) as f:
            hub.topology = json.load(f)
    except (OSError, ValueError) as e:
        print("topology read failed:", e, flush=True)
        return
    hub.publish("topology", hub.topology)


def udp_loop(hub, sock):
    while True:
        try:
            buf, _ = sock.recvfrom(65536)
            msg = osc_decode(buf)
        except Exception as e:  # keep the listener alive on bad packets
            print("udp:", e, flush=True)
            continue
        if not msg:
            continue
        path, args = msg
        if path == "/mixctl/meter" and len(args) >= 5:
            hub.set_meter(args[0], args[1:5])
        elif path == "/mixctl/vu" and len(args) >= 4:
            hub.last_matron = time.time()
            # polls give amplitude only; use it for both peak and rms
            hub.set_meter("crone_in", [args[0], args[0], args[1], args[1]])
            hub.set_meter("eng_outb", [args[2], args[2], args[3], args[3]])
        elif path == "/mixctl/param" and len(args) >= 5:
            hub.last_matron = time.time()
            value = None if args[2] == -999 else args[2]
            raw = None if args[3] < 0 else args[3]
            hub.set_param(args[0], args[1], value, raw, args[4])
        elif path == "/mixctl/topology_changed":
            hub.last_matron = time.time()
            load_topology(hub)


def meter_loop(hub):
    last_status = None
    while True:
        time.sleep(1.0 / METER_HZ)
        if hub.dirty_meters:
            hub.dirty_meters = False
            hub.publish("meters", dict(hub.meters))
        status = hub.status()
        if status != last_status:
            last_status = status
            hub.publish("status", status)


def jack_loop(hub, mock):
    last = None
    while True:
        g = mock_jack() if mock else jack_graph()
        key = json.dumps(g, sort_keys=True)
        if key != last:
            last = key
            hub.jack = g
            hub.publish("jack", g)
        time.sleep(JACK_POLL_S)


# mock mode (for UI development off-device) --------------------------------------


def mock_jack():
    names = {
        "system": ["capture_1", "capture_2", "playback_1", "playback_2"],
        "crone": ["input_%d" % i for i in range(1, 7)] + ["output_%d" % i for i in range(1, 7)],
        "SuperCollider": ["in_1", "in_2", "out_1", "out_2"],
    }
    ports = []
    for client, ps in names.items():
        for p in ps:
            is_out = p.startswith(("capture", "output", "out_"))
            ports.append({"name": "%s:%s" % (client, p), "dir": "out" if is_out else "in"})
    pairs = [
        ("system:capture_1", "crone:input_1"), ("system:capture_2", "crone:input_2"),
        ("SuperCollider:out_1", "crone:input_5"), ("SuperCollider:out_2", "crone:input_6"),
        ("crone:output_1", "system:playback_1"), ("crone:output_2", "system:playback_2"),
        ("crone:output_5", "SuperCollider:in_1"), ("crone:output_6", "SuperCollider:in_2"),
    ]
    extra = getattr(mock_jack, "extra", set())
    removed = getattr(mock_jack, "removed", set())
    conns = sorted((set(pairs) | extra) - removed)
    return {"ports": ports, "connections": [{"src": s, "dst": d} for s, d in conns], "ok": True, "error": None}


def mock_topology(hub):
    path = os.path.join(HERE, "mock_topology.json")
    with open(path) as f:
        hub.topology = json.load(f)


def mock_meters(hub):
    t0 = time.time()
    while True:
        t = time.time() - t0
        for i, key in enumerate(["crone_in", "eng_outb", "sc_main", "sc_sendA", "sc_sendB"]):
            env = 0.5 + 0.5 * math.sin(t * (0.7 + i * 0.3))
            peak = min(1.0, env * (0.6 + 0.4 * random.random()))
            hub.set_meter(key, [peak, peak * 0.5, peak * 0.9, peak * 0.45])
        hub.last_matron = time.time()
        time.sleep(1.0 / METER_HZ)


def mock_set(hub, pset, pid, mode, value):
    for n in (hub.topology or {}).get("nodes", []):
        for c in n.get("controls", []):
            _mock_apply(hub, c, pset, pid, mode, value)
    for e in (hub.topology or {}).get("edges", []):
        if e.get("gain"):
            _mock_apply(hub, e["gain"], pset, pid, mode, value)


def _mock_apply(hub, c, pset, pid, mode, value):
    if c["pset"] != pset or c["id"] != pid:
        return
    lo = c.get("min") if c.get("min") is not None else -60.0  # null is -inf dB
    hi = c.get("max") if c.get("max") is not None else 1.0
    if mode == "raw":
        raw = value
        v = lo + (hi - lo) * value
    else:
        v = value
        raw = (value - lo) / (hi - lo) if hi != lo else 0
    if c["type"] in ("option", "number", "binary"):
        v = round(v)
    disp = c["options"][int(v) - 1] if c["type"] == "option" else ("%.2f" % v)
    hub.set_param(pset, pid, v, raw, disp)
    if c["role"] == "slot":
        # the real mod would rebuild the graph; the mock just re-publishes
        hub.publish("topology", hub.topology)


# http ----------------------------------------------------------------------------


def make_handler(hub, sock, mock):
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=WWW, **kw)

        def log_message(self, fmt, *args):
            pass

        def end_json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/events":
                return self.sse()
            if self.path == "/api/state":
                return self.end_json(200, hub.snapshot())
            return super().do_GET()

        def sse(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            q = hub.subscribe()
            try:
                snap = hub.snapshot()
                for key in ("topology", "jack", "status"):
                    if snap[key] is not None:
                        self.wfile.write(("event: %s\ndata: %s\n\n" % (key, json.dumps(snap[key]))).encode())
                self.wfile.flush()
                while True:
                    try:
                        msg = q.get(timeout=15)
                    except queue.Empty:
                        msg = ": keepalive\n\n"
                    self.wfile.write(msg.encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                hub.unsubscribe(q)

        def do_POST(self):
            try:
                n = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return self.end_json(400, {"ok": False, "error": "bad json"})

            if self.path == "/api/set":
                pset, pid = str(body.get("pset", "script")), str(body.get("id", ""))
                mode = "raw" if body.get("mode") == "raw" else "value"
                try:
                    value = float(body["value"])
                except (KeyError, TypeError, ValueError):
                    return self.end_json(400, {"ok": False, "error": "bad value"})
                if mock:
                    mock_set(hub, pset, pid, mode, value)
                else:
                    sock.sendto(osc_encode("/mixctl/set", pset, pid, mode, value), MATRON)
                return self.end_json(200, {"ok": True})

            if self.path == "/api/dump":
                if not mock:
                    sock.sendto(osc_encode("/mixctl/dump"), MATRON)
                return self.end_json(200, {"ok": True})

            if self.path == "/api/jack":
                op, src, dst = body.get("op"), str(body.get("src", "")), str(body.get("dst", ""))
                force = bool(body.get("force"))
                if mock:
                    if op == "connect":
                        mock_jack.extra = getattr(mock_jack, "extra", set()) | {(src, dst)}
                        mock_jack.removed = getattr(mock_jack, "removed", set()) - {(src, dst)}
                    elif op == "disconnect":
                        if src.startswith(PROTECTED[0]) and dst.startswith(PROTECTED[1]) and not force:
                            return self.end_json(409, {"ok": False, "error": "refusing to disconnect main output (pass force)"})
                        mock_jack.removed = getattr(mock_jack, "removed", set()) | {(src, dst)}
                        mock_jack.extra = getattr(mock_jack, "extra", set()) - {(src, dst)}
                    ok, err = True, ""
                else:
                    ok, err = jack_edit(op, src, dst, force)
                g = mock_jack() if mock else jack_graph()
                hub.jack = g
                hub.publish("jack", g)
                return self.end_json(200 if ok else 409, {"ok": ok, "error": err})

            return self.end_json(404, {"ok": False, "error": "not found"})

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8740)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--mock", action="store_true", help="fake topology, jack and meters")
    args = ap.parse_args()

    hub = Hub()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", args.port))

    threads = [
        threading.Thread(target=udp_loop, args=(hub, sock), daemon=True),
        threading.Thread(target=meter_loop, args=(hub,), daemon=True),
        threading.Thread(target=jack_loop, args=(hub, args.mock), daemon=True),
    ]
    if args.mock:
        mock_topology(hub)
        threads.append(threading.Thread(target=mock_meters, args=(hub,), daemon=True))
    else:
        load_topology(hub)  # pick up whatever matron last wrote
        sock.sendto(osc_encode("/mixctl/dump"), MATRON)
    for t in threads:
        t.start()

    httpd = ThreadingHTTPServer((args.host, args.port), make_handler(hub, sock, args.mock))
    httpd.daemon_threads = True
    print("mixctl on http://%s:%d%s" % (args.host, args.port, " (mock)" if args.mock else ""), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
