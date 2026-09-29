"""Standards-only mock of the endpoints the grok TUI talks to at startup and on a turn.

Why this exists
---------------
`tests/` in this repo is otherwise sh-only and asserts on wrapper behaviour. The
TUI itself has no smoke coverage here, and the upstream harness crate that does
cover it (`xai-grok-pager-pty-harness` in the grok-build checkout) needs a full
cargo build of the pager, which this repo cannot do in CI. The TUI only needs a
handful of HTTP routes to boot and answer a turn, so this module serves them from
`http.server` and lets the suite drive the real installed binary under a PTY
without touching the network.

Contract notes (verified against the built binary, see docs/PTY-TUI-SMOKE.md):
  * `GET /v1/models`   – the model catalog; ids here become the `/model` picker rows.
  * `GET /v1/settings` – `{"allow_access": true}`; anything else strands the pager on
    the upsell screen.
  * `GET /v1/api-key`  – probed before `initialize` advertises the env key. A 404 is
    treated as "unknown" and fails open, so the route is optional; it is served to
    keep the request log readable.
  * `POST /v1/chat/completions` and `POST /v1/responses` – SSE. The pager uses
    `/v1/responses` for auxiliary traffic (session title) and `/v1/chat/completions`
    for the foreground turn on an OpenAI-compatible model entry.
  * A 429 whose flat body carries `{"code": "subscription:free-usage-exhausted"}`
    drives the free-usage paywall, which is the only supported way to exercise a
    limit path without a real quota.
"""

from __future__ import annotations

import http.server
import json
import socketserver
import threading
import time

FREE_USAGE_CODE = "subscription:free-usage-exhausted"


class Request:
    __slots__ = ("method", "path", "body", "headers")

    def __init__(self, method: str, path: str, body: bytes, headers):
        self.method = method
        self.path = path
        self.body = body
        self.headers = headers

    def json(self):
        try:
            return json.loads(self.body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    def model(self):
        """The `model` field of an inference body, or None."""
        payload = self.json()
        if isinstance(payload, dict):
            return payload.get("model")
        return None


class MockApi:
    """A loopback HTTP server serving the grok API surface.

    The server stays en dash-free JSON on the wire; everything the TUI needs to
    boot, stream a turn, and raise the free-usage paywall is a mode switch on
    this object, not a separate fixture.
    """

    def __init__(self, models=("mock-model-a", "mock-model-b"), host="127.0.0.1"):
        self.models = list(models)
        self.host = host
        self.requests: list[Request] = []
        self._lock = threading.Lock()
        self._turn_mode = "reply"
        self._reply_text = "MOCKREPLYOK"
        self._title_text = "TITLE"
        # Consecutive 429s to serve before switching to the reply mode. The
        # paywall flow uses this to fail the first turn and let the retry pass.
        self._limit_turns = 0
        self._limited_models: set[str] | None = None
        self._server = None
        self._thread = None
        self.port = 0

    # ── lifecycle ─────────────────────────────────────────────────────────

    def start(self) -> "MockApi":
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def _record(self, body: bytes) -> Request:
                req = Request(self.command, self.path, body, dict(self.headers))
                with outer._lock:
                    outer.requests.append(req)
                return req

            def _json(self, payload, status=200, extra_headers=None):
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                for key, value in (extra_headers or {}).items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(data)

            def _sse(self, frames):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                for frame in frames:
                    self.wfile.write(f"data: {json.dumps(frame)}\n\n".encode())
                self.wfile.flush()

            def do_GET(self):
                self._record(b"")
                if self.path.startswith("/v1/models"):
                    return self._json({"object": "list", "data": outer._catalog()})
                if self.path.startswith("/v1/settings"):
                    return self._json({"allow_access": True})
                if self.path.startswith("/v1/user"):
                    return self._json(
                        {"userId": "mock-user", "email": "mock-user@test.invalid"}
                    )
                if self.path.startswith("/v1/api-key"):
                    return self._json({})
                return self._json({})

            def do_PUT(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                self._record(body)
                return self._json({})

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                req = self._record(body)
                if "/responses" in self.path:
                    return self._sse(outer._responses_frames())
                if "/chat/completions" in self.path or "/messages" in self.path:
                    if outer._should_limit(req):
                        payload = {
                            "code": FREE_USAGE_CODE,
                            "error": "You have used all your free usage.",
                        }
                        return self._json(payload, status=429, extra_headers={"x-should-retry": "false"})
                    return self._sse(outer._completion_frames(req.model() or "mock-model"))
                return self._json({})

        self._server = socketserver.ThreadingTCPServer((self.host, 0), Handler)
        self._server.daemon_threads = True
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        self._wait_ready()
        return self

    def _wait_ready(self, timeout: float = 5.0) -> None:
        import socket

        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                with socket.create_connection((self.host, self.port), timeout=0.2):
                    return
            except OSError:
                time.sleep(0.02)
        raise RuntimeError("mock API did not start listening")

    def stop(self):
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()

    # ── addressing ────────────────────────────────────────────────────────

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}/v1"

    def env(self) -> dict:
        """The env overlay that points every grok endpoint at this server."""
        return {
            "GROK_CLI_CHAT_PROXY_BASE_URL": self.base_url,
            "GROK_XAI_API_BASE_URL": self.base_url,
            "GROK_MODELS_BASE_URL": self.base_url,
            "GROK_FEEDBACK_BASE_URL": self.base_url,
            "GROK_TRACE_UPLOAD_URL": self.base_url,
            "GROK_MANAGED_CONFIG_URL": self.base_url,
            "GROK_CODE_WEB_URL": self.base_url,
            "GROK_CONVERSATIONS_BASE_URL": self.base_url,
            "XAI_API_KEY": "test-key-for-ci",
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
        }

    # ── modes ─────────────────────────────────────────────────────────────

    def set_reply(self, text: str) -> None:
        self._reply_text = text

    def fail_next_turns(self, count: int, models=None) -> None:
        """Serve `count` more 429 free-usage-exhausted turns, optionally only for `models`."""
        self._limit_turns = count
        self._limited_models = set(models) if models else None

    # ── request log helpers ───────────────────────────────────────────────

    def inference_requests(self):
        return [
            r
            for r in self.requests
            if r.method == "POST" and ("/chat/completions" in r.path or "/messages" in r.path)
        ]

    def models_requested(self):
        return [r.model() for r in self.inference_requests()]

    def seen(self, fragment: str) -> bool:
        return any(fragment in r.path for r in self.requests)

    # ── payload builders ──────────────────────────────────────────────────

    def _catalog(self):
        return [
            {
                "id": model,
                "object": "model",
                "created": 1234567890,
                "owned_by": "test",
                "context_length": 131072,
            }
            for model in self.models
        ]

    def _should_limit(self, req: Request) -> bool:
        with self._lock:
            if self._limit_turns <= 0:
                return False
            if self._limited_models is not None and req.model() not in self._limited_models:
                return False
            self._limit_turns -= 1
            return True

    def _responses_frames(self):
        return [
            {"type": "response.created", "response": {"id": "resp-1", "model": "mock"}},
            {"type": "response.output_text.delta", "delta": self._title_text},
            {"type": "response.completed", "response": {"id": "resp-1"}},
        ]

    def _completion_frames(self, model: str):
        frames = []
        for piece in _chunk_text(self._reply_text, 3):
            frames.append(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": model,
                    "choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}],
                }
            )
        frames.append(
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": 1,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
        )
        return frames


def _chunk_text(text: str, size: int):
    return [text[i : i + size] for i in range(0, len(text), size)] or [""]
