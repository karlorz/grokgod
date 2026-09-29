"""Bounded VT100/xterm screen model for PTY assertions.

`grok` paints with absolute cursor addressing (`ESC[<row>;<col>H`), so a raw byte
strip is not a reliable way to ask "is this text on screen?" — the same glyphs
appear in the raw stream long before the frame that makes them visible, and
overwritten cells stay in the byte history forever. This module keeps an
in-memory character grid and applies the subset of escape sequences the TUI
actually emits, which is what the assertions in `scenarios.py` read.

Deliberately dependency-free (stdlib only) and deliberately partial: unusual
sequences are ignored rather than modelled. Unknown CSI final bytes are dropped,
which is safe because every sequence the TUI uses to place text is handled.
"""

from __future__ import annotations

import re

# CSI: ESC [ params intermediates final
_CSI_RE = re.compile(rb"\x1b\[([0-?]*)([ -/]*)([@-~])")
# OSC: ESC ] ... (BEL | ESC \)
_OSC_RE = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
# Charset selection / single-char escapes: ESC ( X, ESC ) X, ESC =, ESC >, ESC 7/8 ...
_SHORT_ESC_RE = re.compile(rb"\x1b[()][0-9A-Za-z]|\x1b[=>NODHc78MZ]")


class Screen:
    """A fixed-size character grid with an optional line scrollback."""

    def __init__(self, rows: int = 50, cols: int = 120, scrollback: int = 4000):
        self.rows = rows
        self.cols = cols
        self.scrollback_limit = scrollback
        self.grid = [[" "] * cols for _ in range(rows)]
        self.scrollback: list[str] = []
        self.row = 0
        self.col = 0
        self.saw_alt_screen = False
        self._pending = b""

    # ── public API ────────────────────────────────────────────────────────

    def feed(self, data: bytes) -> None:
        """Apply a chunk of terminal output."""
        if isinstance(data, str):
            data = data.encode("utf-8", "replace")
        buf = self._pending + data
        self._pending = b""
        i = 0
        n = len(buf)
        while i < n:
            b = buf[i]
            if b == 0x1B:
                consumed = self._escape(buf, i)
                if consumed is None:
                    # Incomplete sequence: keep it for the next chunk.
                    self._pending = buf[i:]
                    return
                i = consumed
                continue
            if b == 0x0D:  # CR
                self.col = 0
            elif b == 0x0A:  # LF
                self._linefeed()
            elif b == 0x08:  # BS
                self.col = max(0, self.col - 1)
            elif b == 0x09:  # HT
                self.col = min(self.cols - 1, (self.col // 8 + 1) * 8)
            elif b == 0x07:  # BEL
                pass
            elif b < 0x20:
                pass
            else:
                # Decode one UTF-8 scalar.
                length = 1
                if b >= 0xF0:
                    length = 4
                elif b >= 0xE0:
                    length = 3
                elif b >= 0xC0:
                    length = 2
                chunk = buf[i : i + length]
                if len(chunk) < length:
                    self._pending = buf[i:]
                    return
                try:
                    ch = chunk.decode("utf-8")
                except UnicodeDecodeError:
                    ch = "�"
                self._put(ch)
                i += length
                continue
            i += 1

    def text(self) -> str:
        """Visible screen text, right-trimmed per line, blank lines preserved."""
        return "\n".join("".join(row).rstrip() for row in self.grid)

    def full_text(self) -> str:
        """Scrollback plus visible screen."""
        return "\n".join(self.scrollback + [self.text()])

    def contains(self, needle: str) -> bool:
        return needle in self.full_text() or needle in self.text()

    def raw_line(self, row: int) -> str:
        return "".join(self.grid[row]).rstrip()

    def nonblank_lines(self) -> list[str]:
        return [line for line in self.text().split("\n") if line.strip()]

    # ── internals ─────────────────────────────────────────────────────────

    def _put(self, ch: str) -> None:
        if self.col >= self.cols:
            # Autowrap: xterm wraps on the next printable after the margin.
            self.col = 0
            self._linefeed()
        self.grid[self.row][self.col] = ch
        self.col += 1

    def _linefeed(self) -> None:
        if self.row + 1 >= self.rows:
            self._scroll_up()
        else:
            self.row += 1

    def _scroll_up(self) -> None:
        self.scrollback.append("".join(self.grid[0]).rstrip())
        if len(self.scrollback) > self.scrollback_limit:
            del self.scrollback[: len(self.scrollback) - self.scrollback_limit]
        self.grid.pop(0)
        self.grid.append([" "] * self.cols)

    def _clear_all(self) -> None:
        self.grid = [[" "] * self.cols for _ in range(self.rows)]
        self.row = 0
        self.col = 0

    def _erase_in_line(self, mode: int) -> None:
        row = self.grid[self.row]
        if mode == 0:
            for c in range(self.col, self.cols):
                row[c] = " "
        elif mode == 1:
            for c in range(0, min(self.col + 1, self.cols)):
                row[c] = " "
        else:
            self.grid[self.row] = [" "] * self.cols

    def _erase_in_display(self, mode: int) -> None:
        if mode == 0:
            self._erase_in_line(0)
            for r in range(self.row + 1, self.rows):
                self.grid[r] = [" "] * self.cols
        elif mode == 1:
            self._erase_in_line(1)
            for r in range(0, self.row):
                self.grid[r] = [" "] * self.cols
        else:
            self._clear_all()

    def _escape(self, buf: bytes, i: int):
        """Handle the escape at `buf[i]`. Returns the next index, or None if incomplete."""
        rest = buf[i:]
        m = _OSC_RE.match(rest)
        if m:
            return i + m.end()
        if rest.startswith(b"\x1b]") and len(rest) < 4096:
            return None  # possibly a truncated OSC
        m = _CSI_RE.match(rest)
        if m:
            params = m.group(1).decode("ascii", "replace")
            final = m.group(3).decode("ascii")
            self._csi(params, final)
            return i + m.end()
        if rest.startswith(b"\x1b["):
            return None  # truncated CSI
        m = _SHORT_ESC_RE.match(rest)
        if m:
            seq = m.group(0)
            if seq.endswith(b"c"):  # RIS full reset
                self._clear_all()
            return i + m.end()
        if len(rest) < 2:
            return None
        # Unknown two-byte escape: consume it.
        return i + 2

    def _csi(self, params: str, final: str) -> None:
        private = params.startswith("?")
        body = params[1:] if private else params
        nums = [int(p) for p in body.split(";") if p.isdigit()]
        first = nums[0] if nums else 0

        if private:
            # Alt-screen enter/exit and bracketed paste carry no text; alt-screen
            # enter clears the grid because the previous frame is gone.
            if final == "h" and 1049 in nums:
                self.saw_alt_screen = True
                self._clear_all()
            return

        if final in ("H", "f"):
            self.row = min(self.rows - 1, max(0, (nums[0] if nums else 1) - 1))
            self.col = min(self.cols - 1, max(0, (nums[1] if len(nums) > 1 else 1) - 1))
        elif final == "A":
            self.row = max(0, self.row - max(1, first))
        elif final == "B":
            self.row = min(self.rows - 1, self.row + max(1, first))
        elif final == "C":
            self.col = min(self.cols - 1, self.col + max(1, first))
        elif final == "D":
            self.col = max(0, self.col - max(1, first))
        elif final == "G":
            self.col = min(self.cols - 1, max(0, first - 1))
        elif final == "d":
            self.row = min(self.rows - 1, max(0, first - 1))
        elif final == "J":
            self._erase_in_display(first)
        elif final == "K":
            self._erase_in_line(first)
        # SGR (m), modes (h/l), scroll regions (r) and the rest do not move text.
