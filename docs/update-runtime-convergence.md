# Update runtime convergence and suggested config profile

Grilled 2026-10-06. Installer + README implemented on both OS (status-line
two-item seed, AQU 120s/recommended, Windows skip-download runtime refresh).
v1.0.50 tag is still the Windows first hop.

ClawGod analog: Lean Settings persist across `claude update`, and the README
is grouped feat tables. grokgod persist is a compiled patch stack (no
`patches.json`). The config half is a **suggested profile** merged
fill-if-missing into `~/.grok/config.toml`.

## Contract

Every `grok update` / install, including skip-download of an already-current
grok binary, still converges:

1. Updater scripts (install.sh / install.ps1, shims, launcher helpers)
2. PATH launchers (`grok` / `grokgod`)
3. Suggested config profile (keys below)

Engine patches `0001`–`0023` stay in the binary. Absent key in config is not
a patch toggle.

## Suggested profile

Fill-if-missing. Docs-only name. No `grokgod profile` command. A user-set key
stays. `GROK_CONFIG_PATH` overlays cannot carry these tables (not on the
overlay allowlist); merge target is always `~/.grok/config.toml`.

**Default** = grok-build compiled value when the key is absent.
**On** = grokgod suggested profile (what install writes if missing).
**Off** = stock / opt-out (set the key yourself).

| Key | Default (compiled) | On (suggested) | Off (opt-out) |
|-----|--------------------|----------------|---------------|
| `[plan_mode] implement_via_subagents` | `true` (0002) | `true` | `false` — parent “start coding” |
| `[workflows.builtins] deep-research` | `true` (builtin owns `/deep-research`) | `false` — plugin owns slash | `true` — stock builtin |
| `[ui.status_line] type` | `disabled` | `builtin` | `disabled` / `command` / off / none / hidden |
| `[ui.status_line] items` (only if type builtin and section missing) | grok `DEFAULT_ITEMS`: cwd, model, context | `compacts`, `session-name` | Keep your own list; install never re-expands |
| `[toolset.ask_user_question] timeout_enabled` | `true` | `true` | `false` — wait forever |
| `[toolset.ask_user_question] timeout_secs` | `1800` (30 min) | `120` | Any positive integer, or omit for 1800 |
| `[toolset.ask_user_question] timeout_action` | `decline` (Shift+X) | `recommended` | `decline` |
| `[toolset.ask_user_question] timeout_reset_on_activity` | `true` | `true` | `false` — timer keeps running while you read |

### Status-line items

- **Missing `[ui.status_line]`:** seed

  ```toml
  [ui.status_line]
  type = "builtin"
  items = [
      "compacts",
      "session-name",
  ]
  ```

  (Live operator preference. Replaces today’s four-item seed of
  `model`, `turn-timer`, `session-name`, `compacts`.)

- **Existing builtin list:** append `"compacts"` if missing; never add
  `model` / `turn-timer`; never remove items the user dropped.
- **`type = "command"` / `"disabled"` / off / none / hidden:** leave alone.

### Out of profile

| Candidate | Why omitted |
|-----------|-------------|
| `[plan_mode] extra_writable_globs` | 0002 compiled catalog when absent; writing it freezes the list. |
| `[models] default` | Interactive default stays `~/.grok/config.toml` (`grok-4.6`). `flash-max` is overlay / real-session tests only. |
| eval-home lockdown | Isolated `GROK_HOME` for `grokgod eval`, not a personal default. |
| `[cli] auto_update` | Shim already sets `GROK_DISABLE_AUTOUPDATER=1`. |
| `[features] telemetry` | Operator privacy choice, not persist. |

Windows `install.ps1` currently writes none of these. The implementation ports
the same merges, including AQU 120s / recommended and the two-item status-line seed.

## Skip-download

| | POSIX | Windows |
|---|---------|---------|
| Binary skip | Live file matches `manifest.json` `artifactSha256` (post-codesign). Stamp SHA is the pre-codesign asset digest (ADR 0006). | Live `.exe` hash matches stamp SHA (no codesign). |
| Runtime source | git-ff `~/.grokgod/src` from `origin/main`, then rewrite launchers + merge profile. | Fetch runtime scripts from **GitHub latest** (install.ps1, grok-shim.ps1, LauncherHelpers.ps1, cmd templates, daily-minimal). Skip `grokgod-windows-x64.exe` when verified. Then rewrite launchers + merge profile. |
| Runtime fetch failure | Existing git-ff failure already fail-closed (live binary untouched). | **Warn, keep on-disk runtime, still skip the binary.** Next `grok update` retries. A bad network must not force a grok.exe re-download. |

Asymmetry is intentional: macOS/Linux track grokgod `main`; Windows tracks
the latest **release** (no git required). Installer-only Windows fixes still
need a GitHub release after the first hop.

## First hop

Tag **v1.0.50** with the existing `release.yml` (rebuild all `grokgod-*`
plus new installers/shims). Persist stack stays grok 1.0.45 / `2bdd1d6a`.

Windows: `irm …/install.ps1 | iex` or `grok update -Force` **once**. After
that, skip-download refreshes runtime from latest.

POSIX: `grok update` already git-ffs src; a tag is not required for macOS to
pick up installer-only commits, but v1.0.50 still ships the two-item seed and
docs.

## README draft (replace the short v1 bullet list)

### Persist (what you get)

Grouped; patch ids in the last column. Full numbered inventory stays in
[`patch-inventory.md`](patch-inventory.md).

| Group | What you get | Patches |
|-------|----------------|---------|
| Plugin skills | `"./skills/"` joins resolve | 0001 |
| Plan mode | Extra writable PRD globs; PlanReady spawns implementers | 0002, 0019 |
| Workflows | Builtin `/deep-research` can yield to the plugin | 0004 |
| BYOK / Chat Completions | Tool deny/allow, hosted search splice, DeepSeek null/index/image, Gemini enum | 0005–0007, 0009, 0010, 0014, 0018 |
| Sessions | Single-turn persist toggle; compaction warning + `compacts` status item | 0003, 0013 |
| Usage limits | Switch-model retry; prompt lifetime across compact | 0016, 0020, 0023 |
| Platform | Windows protoc; process-group cleanup; idle-resume context window | 0012, 0021, 0022 |
| UX | Ask-question timeout action; `-m` does not stick; welcome accent | 0011, 0015, 0017 |
| Compat | Claude permissions import gate | 0008 |

Engine patches have no `patches.json`. To drop one you rebuild without that
file.

### Suggested profile

Install/update writes these only when missing:

```toml
[plan_mode]
implement_via_subagents = true

[workflows.builtins]
deep-research = false

[ui.status_line]
type = "builtin"
items = [
    "compacts",
    "session-name",
]

[toolset.ask_user_question]
timeout_enabled = true
timeout_secs = 120
timeout_action = "recommended"
timeout_reset_on_activity = true
```

Set a key yourself to opt out. Existing status-line item lists are not
expanded back to `model` / `turn-timer`. AQU keys are merged per-key when
missing (a user who already set `timeout_secs = 120` is left alone).

## Implementation order (later)

1. POSIX: change missing-section status-line seed to the two items; update
   `examples/status-line.toml` and `tests/install/test_status_line_merge.sh`.
2. Windows: suggested-profile merge + skip-download runtime fetch from latest
   (warn-and-keep on failure) + launcher rewrite on that path.
3. README feat tables as above.
4. Tag v1.0.50 via `release.yml`.
