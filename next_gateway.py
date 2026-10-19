"""OpenAI/Anthropic-compatible gateway in front of the Strata NVFP4 server.

Strata (strata-nvfp4) does the inference and listens on 127.0.0.1 only.  This
gateway is the LAN-facing entry point: it binds 0.0.0.0:8000 by default,
checks the optional client key, and forwards every request unchanged.
Sampling defaults belong to Strata (the run config's "sampling" block fills
fields a request omits), so next_config.json leaves everything null.  Values
set there, or via --temperature/--top-p/--top-k/--temperature-cap, are an
opt-in override for when format_probe.py shows they help.  Structured-output,
stop, seed and logit_bias fields are always passed through untouched.

Only the standard library is used, so any Python 3.9+ can run it.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

ROOT = Path(os.environ.get("NEXT_ROOT", Path(__file__).resolve().parent)).resolve()
CONFIG_PATH = ROOT / "next_config.json"

BUILTIN_CONFIG: dict[str, Any] = {
    "model_id": "Qwen3.8-Flash-Next",
    "sampling": {"temperature": None, "top_p": None, "top_k": None},
    "temperature_cap": None,
}

# Fields each generation endpoint understands.  /v1/responses has no top_k.
SAMPLING_FIELDS = {
    "/v1/chat/completions": ("temperature", "top_p", "top_k"),
    "/v1/completions": ("temperature", "top_p", "top_k"),
    "/v1/messages": ("temperature", "top_p", "top_k"),
    "/v1/responses": ("temperature", "top_p"),
}
HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization"}
FORWARD_HEADERS = ("authorization", "x-api-key", "anthropic-version", "anthropic-beta", "content-type", "accept")


def load_config(path: Path = CONFIG_PATH) -> dict[str, Any]:
    config = {**BUILTIN_CONFIG, "sampling": dict(BUILTIN_CONFIG["sampling"])}
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return config
    for key in ("model_id", "temperature_cap"):
        if key in loaded:
            config[key] = loaded[key]
    if isinstance(loaded.get("sampling"), dict):
        config["sampling"].update(loaded["sampling"])
    return config


def apply_sampling(path: str, body: dict[str, Any], config: dict[str, Any]) -> list[str]:
    """Fill missing sampling fields and cap temperature.  Returns log notes."""
    notes: list[str] = []
    fields = SAMPLING_FIELDS.get(path)
    if not fields:
        return notes
    for key in fields:
        default = config["sampling"].get(key)
        if default is not None and body.get(key) is None:
            body[key] = default
            notes.append(f"{key}={default} (default)")
    cap = config.get("temperature_cap")
    requested = body.get("temperature")
    if cap is not None and isinstance(requested, (int, float)) and not isinstance(requested, bool) and requested > cap:
        body["temperature"] = cap
        notes.append(f"temperature {requested} -> {cap} (cap)")
    return notes


class GatewayHandler(BaseHTTPRequestHandler):
    server_version = "NextGateway/1.0"

    @property
    def cfg(self) -> dict[str, Any]:
        return self.server.cfg  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {fmt % args}", flush=True)

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def _connect(self, timeout: float | None) -> http.client.HTTPConnection:
        args = self.server.args  # type: ignore[attr-defined]
        return http.client.HTTPConnection(args.upstream_host, args.upstream_port, timeout=timeout)

    def _upstream_headers(self) -> dict[str, str]:
        headers = {k: v for k, v in self.headers.items() if k.lower() in FORWARD_HEADERS}
        key = self.server.args.upstream_key  # type: ignore[attr-defined]
        if key:
            headers["Authorization"] = f"Bearer {key}"
            headers["x-api-key"] = key
        return headers

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self._cors()
        self.end_headers()

    def _authorized(self) -> bool:
        """With --client-key set, every request except /health needs it."""
        key = self.server.args.client_key  # type: ignore[attr-defined]
        if not key:
            return True
        supplied = self.headers.get("Authorization", "").removeprefix("Bearer ").strip() or self.headers.get("x-api-key", "")
        if supplied == key:
            return True
        self._json(401, {"error": {"message": "invalid or missing API key", "type": "authentication_error"}})
        return False

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/health":
            self._health()
        elif self._authorized():
            self._proxy(b"")

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b""
        if not self._authorized():
            return
        path = urlsplit(self.path).path
        if path in SAMPLING_FIELDS and raw:
            try:
                body = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                body = None
            if isinstance(body, dict):
                notes = apply_sampling(path, body, self.cfg)
                if notes:
                    self.log_message("%s sampling: %s", path, "; ".join(notes))
                raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self._proxy(raw)

    def _health(self) -> None:
        try:
            conn = self._connect(3)
            conn.request("GET", "/v1/models", headers=self._upstream_headers())
            status = conn.getresponse().status
            conn.close()
            ok = status < 500
        except OSError:
            ok = False
        self._json(200 if ok else 503, {
            "status": "ok" if ok else "loading_or_down",
            "model": self.cfg["model_id"],
            "engine": "strata-nvfp4",
            "sampling_defaults": self.cfg["sampling"],
            "temperature_cap": self.cfg.get("temperature_cap"),
        })

    def _proxy(self, raw: bytes) -> None:
        headers = self._upstream_headers()
        if raw:
            headers["Content-Length"] = str(len(raw))
        conn = self._connect(None)
        try:
            try:
                conn.request(self.command, self.path, body=raw or None, headers=headers)
                resp = conn.getresponse()
            except OSError as exc:
                self._json(502, {"error": {
                    "message": f"Strata upstream is not reachable ({exc}). The model may still be loading; check /health.",
                    "type": "upstream_unavailable",
                }})
                return
            self.send_response(resp.status)
            for name, value in resp.getheaders():
                if name.lower() not in HOP_BY_HOP:
                    self.send_header(name, value)
            self.send_header("Connection", "close")
            self._cors()
            self.end_headers()
            # read1 returns as soon as any bytes arrive, which keeps SSE live.
            while True:
                chunk = resp.read1(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except ConnectionError as exc:
            self.log_message("client disconnected: %s", exc)
        finally:
            conn.close()
            self.close_connection = True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Gateway for the Strata NVFP4 Qwen3.8-Flash-Next server")
    parser.add_argument("--host", default="0.0.0.0", help="address to bind; 0.0.0.0 allows LAN clients")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--upstream-port", type=int, default=8080)
    parser.add_argument("--upstream-key", default=os.environ.get("NEXT_UPSTREAM_KEY", ""), help="api_key configured in Strata, if any")
    parser.add_argument("--client-key", default=os.environ.get("NEXT_CLIENT_KEY", ""), help="require this API key from clients (recommended when binding 0.0.0.0)")
    parser.add_argument("--temperature", type=float, help="override sampling default from next_config.json")
    parser.add_argument("--top-p", type=float, help="override sampling default from next_config.json")
    parser.add_argument("--top-k", type=int, help="override sampling default from next_config.json")
    parser.add_argument("--temperature-cap", type=float, help="override temperature_cap; use a negative value to disable")
    return parser.parse_args()


def build_config(args: argparse.Namespace) -> dict[str, Any]:
    config = load_config()
    for key, value in (("temperature", args.temperature), ("top_p", args.top_p), ("top_k", args.top_k)):
        if value is not None:
            config["sampling"][key] = value
    if args.temperature_cap is not None:
        config["temperature_cap"] = None if args.temperature_cap < 0 else args.temperature_cap
    return config


def main() -> None:
    args = parse_args()
    config = build_config(args)
    server = ThreadingHTTPServer((args.host, args.port), GatewayHandler)
    server.daemon_threads = True
    server.args = args  # type: ignore[attr-defined]
    server.cfg = config  # type: ignore[attr-defined]
    print(f"-- Gateway on http://{args.host}:{args.port} -> Strata http://{args.upstream_host}:{args.upstream_port}", flush=True)
    print(f"-- Sampling defaults: {config['sampling']}  temperature cap: {config['temperature_cap']}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n-- Shutting down", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())
