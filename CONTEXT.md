# grokgod

ClawGod-style persist wrapper around official Grok Build. This glossary is the
shared language for what grokgod keeps across `grok update`, not a spec.

## Language

**Source patch**:
A `git apply` diff under `patches/` against a pinned grok-build SHA. Re-applied
on `grok update` / `grokgod update`. Current set: `0001-normalize-plugin-skill-join`,
`0002-plan-mode-extra-writable`, `0003-session-persist-single`, `0004-disable-builtin-deep-research`.
_Avoid_: Mach-O hex edit, plugin.json rewrite as the engine fix

**Built-in deep-research workflow**:
Compiled-in grok-build workflow and `/deep-research` slash command. grokgod
`0004` adds `[workflows.builtins] deep-research` (default on). `false` hides
the builtin so plugin skill `deep-research:deep-research` can own the bare
slash name. Not `[workflows] enabled = false` (that kills every workflow).
_Avoid_: renaming the plugin; disabling all workflows to unstick the name

**Session plan file**:
Grok plan-mode exclusive live file at `~/.grok/sessions/<cwd>/<id>/plan.md`.
The TUI preview and `exit_plan_mode` read this path.
_Avoid_: vault plan, work-item plan.md, grok plan (bare)

**Extra writable glob**:
`[plan_mode] extra_writable_globs` matched against an absolute edit path while
plan mode is Active. Default catalog is generic PRD markdown locations, not a
SkillWiki API. `[]` restores stock Grok. Skills choose the path; the gate only
stops rejecting matches.
_Avoid_: hardcoded /using-skillwiki, vault path in grok-build

**Implement-phase subagents**:
`[plan_mode] implement_via_subagents`. Default **true** in 0002: after `a`,
`exit_plan_mode` PlanReady/EmptyPlan and the toggle-exit reminder prefer
second-tier implementer subagents and parent verification. Set `false` to
restore stock “start coding” / “you can proceed”.
_Avoid_: runtime ban on parent writes, same-tier spawn as parent

**Overlay pin**:
`grokgod run` exporting `GROK_CONFIG_PATH` to an automation-root overlay TOML
so a headless `grok -p` uses a different `[models]` default than interactive grok.
Never `-m` on that overlay path.
_Avoid_: global Orca agentDefaultEnv, overlays.toml as production

**Local real-session test**:
Headed Orca grok TUI / interactive grok against the live patched binary.
Always `grok -m flash-max` (or `/model flash-max`). Not grok-4.6.
_Avoid_: mixing this with overlay pin; Saturday automation `-m`

**Resume tag**:
The grokgod `--orca-resume-tag` workaround (create-first waiter + `grok --resume`).
Hit the request on DEV-TEST run 2. Operator 2026-08-19: **remove now**, not a
persist feature. Durable conversation resume is an Orca product gap.
_Avoid_: calling this a source patch

**View run**:
Orca automations button that focuses a still-live run PTY. Stored IDs with a
dead PTY toast "Run terminal is unavailable." Does not spawn any CLI resume.
_Avoid_: resume session, reopen grok

**Resume workspace**:
Orca automations button when terminal IDs are null. Focuses the workspace card
only ("Workspace is available.").
_Avoid_: resume session

**Persist inventory**:
The keep-list in `docs/patch-inventory.md` plus `grok status` lines. Not a
ClawGod `patch.mjs` regex engine. Source patches still apply via `git apply
--check` in `install.sh`.
_Avoid_: patcher, universal patcher, regex catalog

**Stamp-only status**:
`grok status` treats source patch 0001 as applied when `.source-version`
carries PATCHSET and the target binary exists. It does not disassemble the
Mach-O or run `git apply --check` against a grok-build checkout; drift is
git-ref compare only.
_Avoid_: binary prove, strings scan, apply --check in status

**Overlay-pin status**:
`grok status` reports overlay-pin=wrapper when the installed `grokgod-run.sh`
exists. It does not look at any host automation-root overlay file.
_Avoid_: requiring Weekly grok-overlay.toml for status to pass

**Pin file**:
`~/.grokgod/pin/grok-overlay.toml` — optional host overlay template. Bare `grok` does not auto-read it.
_Avoid_: shipping Weekly config.toml, always-on ClawGod-style inject.
