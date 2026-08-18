# grokgod

ClawGod-style **wrapper** for official [Grok Build](https://github.com/xai-org/grok-build).

Official `grok update` replaces the Mach-O binary. One-off local patches die. `grokgod` re-applies persist steps on launch.

## Not ClawGod’s engine

ClawGod extracts `cli.js` from a Bun standalone and regex-patches JavaScript. Grok is a native Rust binary (`~/.grok/bin/grok`). There is nothing to extract. This repo copies only the **lifecycle**: wrapper name, version stamp, re-apply, keep official `grok` unpatched.

## v1 (not implemented yet)

`grokgod apply` — rewrite installed plugin manifests:

- `"skills": "./skills/"` → `"skills"`
- `"skills": "./"` → omit or `"skills"` when a `skills/` dir exists

Then `grokgod` execs official `grok` with the same argv.

## Wiki

Vault project: `~/wiki/projects/grokgod/`

Known issue: `~/wiki/raw/transcripts/2026-08-18-bug-grok-official-update-wipes-local-patches.md`

Issue catalog: `~/wiki/projects/grokgod/requirements/2026-08-18-grok-build-wiki-issue-catalog.md`

## Status

Bootstrap only (2026-08-18). No launcher on PATH yet.
