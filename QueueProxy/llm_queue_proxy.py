#!/usr/bin/env python3
"""Priority-queue HTTP proxy in front of Ollama.

Listens on 127.0.0.1:11434, forwards to 127.0.0.1:11436.
Inference requests wait in an inspectable, reorderable queue when all
OLLAMA_NUM_PARALLEL slots are busy.
"""

from __future__ import annotations

import http.client
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = os.environ.get("LLM_QUEUE_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LLM_QUEUE_LISTEN_PORT", "11434"))
UPSTREAM_HOST = os.environ.get("LLM_QUEUE_UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.environ.get("LLM_QUEUE_UPSTREAM_PORT", "11436"))
MAX_CONCURRENT = int(os.environ.get("OLLAMA_NUM_PARALLEL", "4"))

CHUNK = 8192
UPSTREAM_TIMEOUT_S = 3600
HOP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
}

INFERENCE_PATHS = (
    "/api/chat",
    "/api/generate",
    "/v1/chat/completions",
    "/v1/completions",
    "/v1/responses",
    "/api/embed",
    "/api/embeddings",
)

LOCAL_COMPUTER_NAME = socket.gethostname().removesuffix(".local") or "Studio"

queue_cond = threading.Condition()
active_count = 0
active_tasks: list[dict] = []
waiting_queue: list[dict] = []
next_seq = 0


def classify_client(cmd: str, args: str) -> str:
    hay = f"{cmd} {args}".lower()
    if "ollama-auth-proxy" in hay:
        return "Remote (Auth Proxy)"
    if "hermes" in hay:
        return "Hermes"
    if "deepseek" in hay or "dsh-desktop" in hay:
        return "DeepSeek Harness"
    if "orca.app" in hay or "application support/orca" in hay:
        return "Orca"
    if "jarvis" in hay:
        return "Jarvis"
    if "lmstudio" in hay:
        return "LM Studio"
    if "cursor" in hay:
        return "Cursor"
    if "claude" in hay:
        return "Claude"
    return cmd or "Local Client"


HOSTS_FILE = os.path.expanduser("~/.local/share/llm-queue-proxy/hosts.json")
PRIORITIES_FILE = os.path.expanduser("~/.local/share/llm-queue-proxy/priorities.json")
PRIORITY_WEIGHT = {"high": 2, "medium": 1, "low": 0}


def load_priorities() -> dict[str, str]:
    try:
        with open(PRIORITIES_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            if isinstance(data, dict):
                return {
                    str(k): str(v).lower()
                    for k, v in data.items()
                    if str(v).lower() in ("high", "medium")
                }
    except Exception:
        pass
    return {}


def save_priorities(data: dict[str, str]):
    try:
        os.makedirs(os.path.dirname(PRIORITIES_FILE), exist_ok=True)
        with open(PRIORITIES_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


client_priorities: dict[str, str] = load_priorities()


def load_host_aliases() -> dict[str, str]:
    try:
        with open(HOSTS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            if isinstance(data, dict):
                return {str(k): str(v) for k, v in data.items()}
    except Exception:
        pass
    return {}


def resolve_computer(ip: str) -> str:
    if ip in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
        return LOCAL_COMPUTER_NAME
    aliases = load_host_aliases()
    if ip in aliases:
        return aliases[ip]
    try:
        host, _, _ = socket.gethostbyaddr(ip)
        return host.removesuffix(".local") or ip
    except Exception:
        return ip


def identify_peer(client_ip: str, client_port: int, headers: dict) -> tuple[str, str]:
    xff = (headers.get("X-Forwarded-For") or headers.get("x-forwarded-for") or "").split(",")[0].strip()
    ua = (headers.get("User-Agent") or headers.get("user-agent") or "").lower()
    x_title = (headers.get("X-Title") or headers.get("x-title") or "").lower()
    hint = f"{ua} {x_title}"

    computer = resolve_computer(xff if xff else client_ip)
    if computer != LOCAL_COMPUTER_NAME:
        if "deepseek" in hint or "dsh" in hint:
            return computer, "DeepSeek Harness"
        if "orca" in hint:
            return computer, "Orca"
        if "hermes" in hint:
            return computer, "Hermes"
        return computer, "Remote API"

    try:
        out = subprocess.run(
            ["/usr/sbin/lsof", f"-iTCP:{client_port}", "-sTCP:ESTABLISHED", "-n", "-P", "-F", "pc"],
            capture_output=True, text=True, timeout=0.6,
        ).stdout
        pid = None
        cmd = ""
        cur_pid = None
        cur_cmd = ""
        for line in out.splitlines():
            if not line:
                continue
            tag, val = line[0], line[1:]
            if tag == "p":
                cur_pid = val
                cur_cmd = ""
            elif tag == "c":
                cur_cmd = val
                if cur_pid and cur_pid != str(os.getpid()):
                    pid = cur_pid
                    cmd = cur_cmd
        if pid:
            ps_out = subprocess.run(
                ["/bin/ps", "-p", pid, "-o", "args="],
                capture_output=True, text=True, timeout=0.5,
            ).stdout.strip()
            return computer, classify_client(cmd, ps_out)
    except Exception:
        pass
    return computer, "Local Client"


def queue_snapshot_locked(now: float | None = None) -> dict:
    t = now or time.time()
    return {
        "maxConcurrent": MAX_CONCURRENT,
        "activeCount": active_count,
        "priorities": dict(client_priorities),
        "active": [
            {
                "id": item["id"],
                "computer": item["computer"],
                "program": item["program"],
                "model": item["model"],
                "path": item["path"],
                "elapsedSeconds": round(max(0.0, t - item.get("startedAt", t)), 1),
            }
            for item in active_tasks
        ],
        "queued": [
            {
                "id": item["id"],
                "position": idx + 1,
                "computer": item["computer"],
                "program": item["program"],
                "priority": item.get("priority", "low"),
                "model": item["model"],
                "path": item["path"],
                "waitSeconds": round(max(0.0, t - item["enqueuedAt"]), 1),
            }
            for idx, item in enumerate(waiting_queue)
            if not item.get("cancelled")
        ],
    }


class QueueProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError, TimeoutError):
            pass

    def log_message(self, fmt, *args):
        pass

    def _send_json(self, code: int, payload: dict):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self) -> bytes | None:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length > 0 else None

    def _handle_queue_get(self):
        with queue_cond:
            snap = queue_snapshot_locked()
        self._send_json(200, snap)

    def _handle_queue_move(self):
        body = self._read_body() or b"{}"
        try:
            req = json.loads(body.decode("utf-8"))
        except Exception:
            return self._send_json(400, {"error": "invalid json"})
        task_id = req.get("id", "")
        direction = req.get("direction", "")
        to_index = req.get("toIndex")

        with queue_cond:
            idx = next((i for i, item in enumerate(waiting_queue) if item["id"] == task_id), None)
            if idx is not None:
                if isinstance(to_index, int):
                    target = max(0, min(len(waiting_queue) - 1, to_index))
                    if target != idx:
                        item = waiting_queue.pop(idx)
                        waiting_queue.insert(target, item)
                elif direction == "up" and idx > 0:
                    waiting_queue[idx - 1], waiting_queue[idx] = waiting_queue[idx], waiting_queue[idx - 1]
                elif direction == "down" and idx < len(waiting_queue) - 1:
                    waiting_queue[idx + 1], waiting_queue[idx] = waiting_queue[idx], waiting_queue[idx + 1]
                elif direction == "top" and idx > 0:
                    item = waiting_queue.pop(idx)
                    waiting_queue.insert(0, item)
                queue_cond.notify_all()
            snap = queue_snapshot_locked()
        self._send_json(200, snap)

    def _handle_queue_priority(self):
        body = self._read_body() or b"{}"
        try:
            req = json.loads(body.decode("utf-8"))
        except Exception:
            return self._send_json(400, {"error": "invalid json"})
        client = str(req.get("client") or "").strip()
        prio = str(req.get("priority") or "low").lower()
        if not client or prio not in ("high", "medium", "low"):
            return self._send_json(400, {"error": "invalid client or priority"})

        with queue_cond:
            if prio == "low":
                client_priorities.pop(client, None)
            else:
                client_priorities[client] = prio
            save_priorities(client_priorities)
            for item in waiting_queue:
                if item["program"] == client:
                    item["priority"] = prio
            waiting_queue.sort(
                key=lambda x: (-PRIORITY_WEIGHT.get(x.get("priority", "low"), 0), x.get("seq", 0))
            )
            queue_cond.notify_all()
            snap = queue_snapshot_locked()
        self._send_json(200, snap)

    def _handle_queue_cancel(self):
        body = self._read_body() or b"{}"
        try:
            req = json.loads(body.decode("utf-8"))
        except Exception:
            return self._send_json(400, {"error": "invalid json"})
        task_id = req.get("id", "")
        with queue_cond:
            for item in waiting_queue:
                if item["id"] == task_id:
                    item["cancelled"] = True
            queue_cond.notify_all()
            snap = queue_snapshot_locked()
        self._send_json(200, snap)

    def _is_inference_request(self) -> bool:
        if self.command != "POST":
            return False
        path_only = urllib.parse.urlsplit(self.path).path
        return path_only in INFERENCE_PATHS

    def _proxy(self):
        global active_count, next_seq
        path_only = urllib.parse.urlsplit(self.path).path

        if self.command == "GET" and path_only == "/_queue":
            return self._handle_queue_get()
        if self.command == "POST" and path_only == "/_queue/move":
            return self._handle_queue_move()
        if self.command == "POST" and path_only == "/_queue/priority":
            return self._handle_queue_priority()
        if self.command == "POST" and path_only == "/_queue/cancel":
            return self._handle_queue_cancel()

        body = self._read_body()
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_HEADERS}

        if not self._is_inference_request():
            return self._forward_to_upstream(body, headers)

        model = ""
        if body:
            try:
                parsed = json.loads(body.decode("utf-8"))
                model = str(parsed.get("model") or "")
            except Exception:
                pass

        computer, program = identify_peer(self.client_address[0], self.client_address[1], headers)
        acquired = False
        task = None

        with queue_cond:
            next_seq += 1
            prio = client_priorities.get(program, "low")
            task = {
                "id": f"q-{next_seq}",
                "seq": next_seq,
                "computer": computer,
                "program": program,
                "priority": prio,
                "model": model,
                "path": path_only,
                "enqueuedAt": time.time(),
                "startedAt": time.time(),
                "cancelled": False,
            }
            if active_count < MAX_CONCURRENT and not waiting_queue:
                active_count += 1
                task["startedAt"] = time.time()
                active_tasks.append(task)
                acquired = True
            else:
                w = PRIORITY_WEIGHT.get(prio, 0)
                insert_idx = len(waiting_queue)
                for i, existing in enumerate(waiting_queue):
                    if PRIORITY_WEIGHT.get(existing.get("priority", "low"), 0) < w:
                        insert_idx = i
                        break
                waiting_queue.insert(insert_idx, task)
                queue_cond.notify_all()

                while True:
                    if task["cancelled"]:
                        if task in waiting_queue:
                            waiting_queue.remove(task)
                        return self._send_json(499, {"error": "cancelled from queue"})

                    if active_count < MAX_CONCURRENT and waiting_queue and waiting_queue[0]["id"] == task["id"]:
                        waiting_queue.pop(0)
                        active_count += 1
                        task["startedAt"] = time.time()
                        active_tasks.append(task)
                        acquired = True
                        queue_cond.notify_all()
                        break

                    queue_cond.wait(timeout=1.0)

        try:
            self._forward_to_upstream(body, headers)
        finally:
            if acquired:
                with queue_cond:
                    if task in active_tasks:
                        active_tasks.remove(task)
                    active_count = max(0, active_count - 1)
                    queue_cond.notify_all()

    def _forward_to_upstream(self, body: bytes | None, headers: dict):
        conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=UPSTREAM_TIMEOUT_S)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
        except OSError as exc:
            return self._send_json(502, {"error": f"ollama upstream unreachable: {exc}"})

        try:
            self.send_response(resp.status)
            has_cl = False
            for k, v in resp.getheaders():
                kl = k.lower()
                if kl == "content-length":
                    has_cl = True
                    self.send_header(k, v)
                elif kl not in HOP_HEADERS:
                    self.send_header(k, v)

            if has_cl:
                self.end_headers()
                while True:
                    chunk = resp.read(CHUNK)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            else:
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                while True:
                    chunk = resp.read1(CHUNK) if hasattr(resp, "read1") else resp.read(CHUNK)
                    if not chunk:
                        break
                    self.wfile.write(f"{len(chunk):x}\r\n".encode("ascii"))
                    self.wfile.write(chunk)
                    self.wfile.write(b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, http.client.IncompleteRead):
            pass
        finally:
            conn.close()

    def do_GET(self):
        self._proxy()

    def do_POST(self):
        self._proxy()

    def do_HEAD(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_OPTIONS(self):
        self._proxy()


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    server = ReusableThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), QueueProxyHandler)
    sys.stderr.write(
        f"llm_queue_proxy listening on {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM_HOST}:{UPSTREAM_PORT} (max={MAX_CONCURRENT})\n"
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
