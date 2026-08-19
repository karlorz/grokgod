# grokgod

ClawGod-style persist wrapper around official Grok Build. This glossary is the
shared language for what grokgod keeps across `grok update`, not a spec.

## Language

**Source patch**:
A `git apply` diff under `patches/` against a pinned grok-build SHA. Re-applied
on `grok update` / `grokgod update`. v1 has one: `0001-normalize-plugin-skill-join`.
_Avoid_: Mach-O hex edit, plugin.json rewrite as the engine fix

**Overlay pin**:
`grokgod run` exporting `GROK_CONFIG_PATH` to an automation-root overlay TOML
so a headless `grok -p` uses a different `[models]` default than interactive grok.
Never `-m`.
_Avoid_: global Orca agentDefaultEnv, overlays.toml as production

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
Mach-O or run `git apply --check` against a grok-build checkout.
_Avoid_: binary prove, strings scan, apply --check in status

**Overlay-pin status**:
`grok status` reports overlay-pin=wrapper when the installed `grokgod-run.sh`
exists. It does not look at any host automation-root overlay file.
_Avoid_: requiring Weekly grok-overlay.toml for status to pass
