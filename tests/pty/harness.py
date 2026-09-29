"""PTY harness for driving the installed grok TUI against a local mock API.

The suite has three layers, each usable on its own:

  * [`MockApi`](mock_api.py) – a stdlib HTTP server for the routes the TUI boots on.
  * [`Screen`](vt_screen.py) – a bounded VT grid so assertions read *visible* text,
    not raw bytes.
  * `PtySession` (this module) – spawn the real binary on a pseudo-terminal with an
    isolated `$HOME`, feed its output into a `Screen`, and inject keys.

Everything is stdlib-only. The binary under test is resolved by
`resolve_binary()`; when no build is installed the suite reports SKIP rather
than failing, because a PTY smoke run is only meaningful next to a real binary.
"""

from __future__ import annotations

import fcntl
import os
import pty
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import threading
import time

from vt_screen import Screen

DEFAULT_ROWS = 50
DEFAULT_COLS = 120

# Keys the TUI reads as raw bytes on stdin.
KEYS = {
    "enter": b"\r",
    "esc": b"\x1b",
    "tab": b"\t",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "left": b"\x1b[D",
    "right": b"\x1b[C",
    "ctrl-c": b"\x03",
    "ctrl-n": b"\x0e",
    "ctrl-u": b"\x15",
    "space": b" ",
    "backspace": b"\x7f",
}


def resolve_binary() -> str | None:
    """Locate the grokgod-built binary, newest install first.

    `GROKGOD_TUI_BINARY` always wins so CI can point at a specific artifact.
    """
    override = os.environ.get("GROKGOD_TUI_BINARY")
    if override:
        return override if os.access(override, os.X_OK) else None

    grokgod_home = os.environ.get("GROKGOD_HOME", os.path.expanduser("~/.grokgod"))
    candidates = [
        os.path.join(grokgod_home, "bin", "grok"),
        os.path.expanduser("~/.grok/bin/grok"),
    ]
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def resolve_shim() -> str | None:
    """Locate the installed `grokgod` PATH shim, if any."""
    override = os.environ.get("GROKGOD_TUI_SHIM")
    if override:
        return override if os.access(override, os.X_OK) else None
    for candidate in (
        os.path.expanduser("~/.local/bin/grokgod"),
        os.path.expanduser("~/.local/bin/grok"),
    ):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


class PtySession:
    """One TUI process on a pseudo-terminal, with an isolated home."""

    def __init__(self, binary, args=(), env=None, cwd=None, rows=DEFAULT_ROWS, cols=DEFAULT_COLS):
        self.binary = binary
        self.args = list(args)
        self.env_overlay = dict(env or {})
        self.cwd = cwd or os.getcwd()
        self.rows = rows
        self.cols = cols
        self.screen = Screen(rows, cols)
        self.home = tempfile.mkdtemp(prefix="grokgod-pty-")
        self._lock = threading.Lock()
        self._pid = None
        self._fd = None
        self._reader = None
        self._stopping = False
        self._exit_status = None
        self.raw = bytearray()

    # ── lifecycle ─────────────────────────────────────────────────────────

    def start(self) -> "PtySession":
        env = self._child_env()
        pid, fd = pty.fork()
        if pid == 0:  # child
            try:
                os.chdir(self.cwd)
                os.environ.clear()
                os.environ.update(env)
                os.execv(self.binary, [os.path.basename(self.binary)] + self.args)
            except BaseException:
                os._exit(127)
        self._pid = pid
        self._fd = fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0))
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        return self

    def _child_env(self) -> dict:
        grok_home = os.path.join(self.home, ".grok")
        os.makedirs(grok_home, exist_ok=True)
        env = {
            "HOME": self.home,
            "GROK_HOME": grok_home,
            "TMPDIR": self.home,
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "SHELL": "/bin/sh",
            "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
            # The TUI is not the thing under test here; keep its optional work
            # (telemetry, updater, prompt suggestions) from adding nondeterminism.
            "GROK_PROMPT_SUGGESTIONS": "false",
            "GROK_TELEMETRY_ENABLED": "false",
            "GROK_FEEDBACK_ENABLED": "false",
            "GROK_TRACE_UPLOAD": "false",
            "GROK_DISABLE_AUTOUPDATER": "1",
        }
        env.update(self.env_overlay)
        return env

    def _read_loop(self) -> None:
        fd = self._fd
        while not self._stopping:
            try:
                ready, _, _ = select.select([fd], [], [], 0.2)
            except (OSError, ValueError):
                return
            if not ready:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            with self._lock:
                self.raw.extend(chunk)
                self.screen.feed(chunk)

    def close(self, timeout: float = 3.0) -> int | None:
        """Kill the process group and reap, then delete the isolated home."""
        self._stopping = True
        pid = self._pid
        if pid is not None:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(os.getpgid(pid), sig)
                except OSError:
                    try:
                        os.kill(pid, sig)
                    except OSError:
                        break
                deadline = time.time() + timeout
                while time.time() < deadline:
                    try:
                        reaped, status = os.waitpid(pid, os.WNOHANG)
                    except ChildProcessError:
                        self._exit_status = 0
                        return self._exit_status
                    if reaped:
                        self._exit_status = status
                        return status
                    time.sleep(0.02)
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
        shutil.rmtree(self.home, ignore_errors=True)
        return self._exit_status

    # ── input ─────────────────────────────────────────────────────────────

    def write(self, data: bytes) -> None:
        os.write(self._fd, data)

    def send_key(self, name: str) -> None:
        self.write(KEYS[name])

    def type_text(self, text: str) -> None:
        self.write(text.encode("utf-8"))

    def submit(self, text: str) -> None:
        self.type_text(text)
        time.sleep(0.2)
        self.send_key("enter")

    # ── observation ───────────────────────────────────────────────────────

    def text(self) -> str:
        with self._lock:
            return self.screen.text()

    def full_text(self) -> str:
        with self._lock:
            return self.screen.full_text()

    def raw_bytes(self) -> bytes:
        with self._lock:
            return bytes(self.raw)

    def wait_for_text(self, needle: str, timeout: float = 20.0, interval: float = 0.2) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in self.text():
                return True
            time.sleep(interval)
        return False

    def wait_until(self, predicate, timeout: float = 20.0, interval: float = 0.2) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                if predicate(self):
                    return True
            except Exception:  # a mid-paint read is not a failure, just not ready
                pass
            time.sleep(interval)
        return False

    def snapshot(self, max_lines: int = 24) -> str:
        """A failure message: the visible screen's non-blank lines, plus the tail."""
        lines = [line for line in self.text().split("\n") if line.strip()]
        tail = lines[-max_lines:]
        body = "\n".join("    | " + line[:200] for line in tail)
        return f"    visible screen (last {len(tail)} non-blank lines):\n{body}"


def pump(seconds: float) -> None:
    time.sleep(seconds)


def have_pty_support() -> bool:
    return sys.platform != "win32" and hasattr(os, "openpty")
