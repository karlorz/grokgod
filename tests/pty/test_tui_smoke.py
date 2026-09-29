#!/usr/bin/env python3
"""Bounded PTY/TUI smoke tests for the grokgod build.

What this covers
----------------
The repo's other suites test the wrapper (shim dispatch, installer, patches).
Nothing tested the thing users actually sit in front of: the TUI. These scenarios
spawn the real installed binary on a pseudo-terminal against a local mock API and
assert on what is *rendered*:

  1. `startup`  – the process boots, paints the welcome screen, and issues its
     catalog fetch against our mock.
  2. `reply`    – a submitted prompt reaches the mock and the streamed answer
     renders in the transcript.
  3. `limit`    – a 429 carrying the free-usage code raises the paywall, and
     `Switch model & retry` genuinely re-sends the prompt on the newly picked
     model (bounded: the mock serves the failure once, then replies).

Scope is deliberately narrow. It is a smoke seam, not a rendering-conformance
suite: every assertion is on a stable string the TUI prints, never on layout,
colors, or cursor positions.

Usage
-----
    python3 tests/pty/test_tui_smoke.py            # all scenarios
    python3 tests/pty/test_tui_smoke.py startup    # one scenario

Exit codes: 0 pass, 1 failure, 77 skip (no binary / no PTY support), which is
the convention `run.sh` maps onto CI.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import PtySession, have_pty_support, resolve_binary  # noqa: E402
from mock_api import MockApi  # noqa: E402

# Timings. The pager spawns a child agent process, so a cold start on a loaded
# machine is seconds, not milliseconds; every wait is a bound, not an expectation.
STARTUP_TIMEOUT = 30.0
SCREEN_SETTLE = 1.0
REPLY_TIMEOUT = 30.0
PAYWALL_TIMEOUT = 30.0
PICKER_TIMEOUT = 20.0

# Stable strings the TUI prints. These are the assertion surface; if upstream
# rewords them the smoke test should be updated deliberately, not by grepping.
WELCOME_SENTINEL = "Quit"
WELCOME_TITLE = "Grok Build"
PAYWALL_HEADING = "You hit your free usage limit."
SWITCH_AND_RETRY = "Switch model & retry"
PICKER_TITLE = "Pick model"
REPLY_SENTINEL = "MOCKREPLYOK"

SKIP_EXIT = 77


class Failure(AssertionError):
    """An assertion failure that carries the rendered screen."""

    def __init__(self, message: str, session: PtySession | None = None):
        detail = message if session is None else f"{message}\n{session.snapshot()}"
        super().__init__(detail)


def _spawn(api: MockApi, model: str = "mock-model-a") -> PtySession:
    binary = resolve_binary()
    if binary is None:
        raise RuntimeError("no grok binary resolved")
    session = PtySession(binary, args=["-m", model], env=api.env())
    return session.start()


def _drive_to_welcome(session: PtySession) -> None:
    if not session.wait_for_text(WELCOME_SENTINEL, STARTUP_TIMEOUT):
        raise Failure("welcome screen never painted", session)
    # The screen is still animating in when the sentinel lands; let it settle so
    # later assertions read a complete frame.
    time.sleep(SCREEN_SETTLE)


def _drive_to_paywall(session: PtySession, prompt: str = "hey mock go") -> None:
    _drive_to_welcome(session)
    session.submit(prompt)
    if not session.wait_for_text(PAYWALL_HEADING, PAYWALL_TIMEOUT):
        raise Failure("free-usage paywall did not open", session)


def _select_switch_option(session: PtySession) -> None:
    """Move the paywall cursor onto `Switch model & retry` and submit it."""
    # The paywall lists three upgrade options before the switch option; the
    # cursor starts on option 1, so three downs land on option 4.
    for _ in range(3):
        session.send_key("down")
        time.sleep(0.2)
    session.send_key("enter")


# ── scenarios ─────────────────────────────────────────────────────────────


def scenario_startup() -> None:
    """Boot paints the welcome screen and the catalog fetch hits the mock."""
    with MockApi() as api:
        session = _spawn(api)
        try:
            _drive_to_welcome(session)
            text = session.text()
            if WELCOME_TITLE not in text:
                raise Failure(f"welcome banner missing {WELCOME_TITLE!r}", session)
            if "mock-model-a" not in text:
                raise Failure("launch model id is not shown in the status bar", session)
            if not api.seen("/v1/models"):
                raise Failure("the TUI never fetched the model catalog", session)
        finally:
            session.close()


def scenario_reply() -> None:
    """A submitted prompt reaches the mock and its streamed answer renders."""
    with MockApi() as api:
        api.set_reply(REPLY_SENTINEL)
        session = _spawn(api)
        try:
            _drive_to_welcome(session)
            session.submit("hey mock go")
            if not session.wait_for_text(REPLY_SENTINEL, REPLY_TIMEOUT):
                raise Failure("mocked reply never rendered", session)

            inference = api.inference_requests()
            if not inference:
                raise Failure("the prompt never produced an inference request", session)
            if not any(
                "/chat/completions" in r.path and r.model() == "mock-model-a"
                for r in inference
            ):
                raise Failure(
                    f"no chat/completions request for mock-model-a; saw "
                    f"{[(r.path, r.model()) for r in inference]}",
                    session,
                )
        finally:
            session.close()


def scenario_limit_and_model_switch() -> None:
    """The free-usage paywall opens, and its switch path retries on the new model."""
    with MockApi() as api:
        api.set_reply(REPLY_SENTINEL)
        # The first foreground turn fails with the free-usage code; the retry
        # after the model switch must succeed, which is what proves the flow
        # both re-sent and switched.
        api.fail_next_turns(1)
        session = _spawn(api)
        try:
            _drive_to_paywall(session)

            text = session.text()
            if SWITCH_AND_RETRY not in text:
                raise Failure("paywall is missing the switch-and-retry option", session)

            _select_switch_option(session)
            if not session.wait_for_text(PICKER_TITLE, PICKER_TIMEOUT):
                raise Failure("switch-and-retry did not open the model picker", session)
            if "mock-model-b" not in session.text():
                raise Failure("picker did not list the second mock model", session)

            session.send_key("down")  # mock-model-a (current) -> mock-model-b
            time.sleep(0.3)
            session.send_key("enter")

            if not session.wait_for_text(REPLY_SENTINEL, REPLY_TIMEOUT):
                raise Failure("retry after the model switch never produced a reply", session)

            models = api.models_requested()
            if "mock-model-b" not in models:
                raise Failure(
                    f"no inference request carried the switched model; saw {models}",
                    session,
                )
            # The original prompt text is what gets retried; a switch that
            # silently sent nothing (or a fresh empty prompt) would still render
            # a reply, so assert the retried body carries the user's words.
            retried = api.inference_requests()[-1]
            body = retried.body.decode("utf-8", "replace")
            if "hey mock go" not in body:
                raise Failure("the retry did not resend the failed prompt text", session)
        finally:
            session.close()


SCENARIOS = {
    "startup": scenario_startup,
    "reply": scenario_reply,
    "limit": scenario_limit_and_model_switch,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "scenarios",
        nargs="*",
        choices=sorted(SCENARIOS),
        help="scenarios to run (default: all)",
    )
    parser.add_argument("--list", action="store_true", help="list scenarios and exit")
    args = parser.parse_args()

    if args.list:
        for name in SCENARIOS:
            print(name)
        return 0

    if not have_pty_support():
        print("SKIP: this platform has no pty/os.openpty support")
        return SKIP_EXIT

    binary = resolve_binary()
    if binary is None:
        print(
            "SKIP: no grok binary found. Set GROKGOD_TUI_BINARY, or install a "
            "build with `grokgod update`."
        )
        return SKIP_EXIT

    selected = args.scenarios or list(SCENARIOS)
    print(f"=== grokgod PTY/TUI smoke (binary: {binary}) ===")

    failures = 0
    for name in selected:
        print(f"--- {name}")
        started = time.time()
        try:
            SCENARIOS[name]()
        except Failure as exc:
            failures += 1
            print(f"FAIL: {name}: {exc}", file=sys.stderr)
        except Exception as exc:  # harness-level breakage is a failure, not a skip
            failures += 1
            print(f"FAIL: {name}: {type(exc).__name__}: {exc}", file=sys.stderr)
            traceback.print_exc()
        else:
            print(f"PASS: {name} ({time.time() - started:.1f}s)")

    if failures:
        print(f"=== {failures} of {len(selected)} scenario(s) failed ===")
        return 1
    print(f"=== all {len(selected)} scenario(s) passed ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
