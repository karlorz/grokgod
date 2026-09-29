# PTY / TUI smoke tests

A bounded end-to-end smoke seam for the grokgod build: it boots the real `grok`
TUI on a pseudo-terminal, points every API endpoint at a local mock, and asserts
on what the TUI renders.

## Why a mock rather than the live backend

The upstream `xai-grok-pager-pty-harness` crate in the grok-build checkout already
exercises the pager thoroughly, but it needs a full cargo build of the pager and
the whole test-support stack. That is minutes and several GB, so it cannot gate
this repo's CI, and it tests upstream's tree rather than the binary grokgod ships.

The TUI needs remarkably little from the backend to boot and answer a turn, so
this suite serves that little bit from `http.server`. That buys a run that is
seconds long, needs no credentials, makes no network calls, and can deterministically
provoke a limit path that would otherwise require burning a real quota.

## Layout

| File | Role |
| --- | --- |
| `mock_api.py` | Stdlib HTTP server for `/v1/models`, `/v1/settings`, `/v1/api-key`, `/v1/user`, and the SSE inference endpoints. Records every request. |
| `vt_screen.py` | Bounded VT100/xterm grid. Cursor addressing is applied, so assertions read *visible* text rather than raw bytes. |
| `harness.py` | `PtySession`: spawn on a PTY with an isolated `$HOME`, pump output into a `Screen`, inject keys, bound every wait. |
| `test_tui_smoke.py` | The scenarios. |
| `test_tui_smoke.sh` | `sh` entry point matching the repo's `tests/<dir>/test_*.sh` convention. |

Everything is stdlib-only. There is no `requirements.txt` and nothing to install.

## Running

```sh
sh tests/pty/test_tui_smoke.sh             # all scenarios
sh tests/pty/test_tui_smoke.sh startup     # one scenario
sh tests/pty/test_tui_smoke.sh --list      # scenario names
```

Exit codes: `0` pass, `1` failure, `77` skipped.

A skip is reported, not failed, when there is no PTY support (non-POSIX) or no
grok binary is installed — a PTY smoke run is only meaningful next to a real
binary. Binary resolution order:

1. `$GROKGOD_TUI_BINARY` (explicit override; CI uses this)
2. `$GROKGOD_HOME/bin/grok`
3. `~/.grok/bin/grok`

## Scenarios

**`startup`** — the process boots, paints the welcome screen (`Grok Build`,
`Quit`), shows the launch model in the status bar, and performs its catalog fetch
against the mock.

**`reply`** — a submitted prompt produces a `POST /v1/chat/completions` carrying
the selected model, and the streamed answer renders in the transcript.

**`limit`** — the mock answers the first foreground turn with
`429 {"code": "subscription:free-usage-exhausted"}`. The free-usage paywall opens;
selecting `Switch model & retry` opens the model picker, and choosing the second
mock model re-sends the *original prompt text* on that model, which then replies.
The mock fails exactly one turn, so a green run proves the retry both happened and
switched models.

## Mock API contract

These routes and shapes were derived from the built binary, not from upstream
source. Treat them as the contract this suite depends on:

| Route | Response | Notes |
| --- | --- | --- |
| `GET /v1/models` | `{"object":"list","data":[{"id":…,"object":"model","created":…,"owned_by":…,"context_length":…}]}` | Ids become the `/model` picker rows. |
| `GET /v1/settings` | `{"allow_access": true}` | Anything else strands the pager on the upsell screen. |
| `GET /v1/api-key` | `{}` | Probed before `initialize` advertises the env key. A 404 counts as "unknown" and fails open, so the route is optional; serving it keeps the request log readable. |
| `GET /v1/user` | `{"userId":…,"email":…}` | Identity; absence is tolerated but noisy. |
| `POST /v1/chat/completions` | SSE, OpenAI chunk shape, terminated by `data: [DONE]` | Foreground turns on an OpenAI-compatible model entry. |
| `POST /v1/responses` | SSE, `response.created` / `response.output_text.delta` / `response.completed` | Auxiliary traffic (session title). Answered so it never blocks a turn. |

The limit path needs a **flat** error envelope. The nested form is parsed into a
different shape and does not reach the paywall:

```json
{"code": "subscription:free-usage-exhausted", "error": "You have used all your free usage."}
```

Served with HTTP 429 and `x-should-retry: false`.

The env overlay that redirects the TUI (`MockApi.env()`) sets
`GROK_CLI_CHAT_PROXY_BASE_URL`, `GROK_XAI_API_BASE_URL`, `GROK_MODELS_BASE_URL`,
`GROK_FEEDBACK_BASE_URL`, `GROK_TRACE_UPLOAD_URL`, `GROK_MANAGED_CONFIG_URL`,
`GROK_CODE_WEB_URL`, `GROK_CONVERSATIONS_BASE_URL`, `XAI_API_KEY`, and loopback
`NO_PROXY`.

## Coupling and maintenance

The suite deliberately couples to a small set of user-visible strings (`Quit`,
`Grok Build`, `You hit your free usage limit.`, `Switch model & retry`,
`Pick model`) and to the routes above. That is the point — a smoke test that
asserts nothing observable asserts nothing — but it does mean an upstream reword
or endpoint change surfaces here as a failure. Update the constants at the top of
`test_tui_smoke.py` when that happens, deliberately.

Assertions never touch layout, color, cursor position, or the logo, so restyling
the TUI does not break this suite.

## Deliberately out of scope

- Rendering conformance (scroll regions, resize, selection, minimal vs fullscreen).
- Anything requiring real credentials or the public network.
- Windows: `pty.fork` is POSIX-only, so the suite reports SKIP there. The `.sh`
  entry point also means it is not wired into the `windows-latest` CI leg.
