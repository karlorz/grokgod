# Runbook: grokgod session-start checks (run once at session start)

Any agent starting development in this repo MUST run this runbook ONCE before
other work. It replaces scheduled watchers: there is no persistent session, so
the checks run when an agent session starts in a grokgod-related project.

## 1. Disk watch (every session)

The host data volume runs tight (historically 86-92% used). Cargo builds are the
main disk eater (`~/.grokgod/target` ~8 GB warm, cold rebuild needs headroom).

```sh
df -h /System/Volumes/Data | tail -1
du -sh ~/.grokgod/target 2>/dev/null || echo "no target cache yet"
du -sh ~/.grok/sessions 2>/dev/null || echo "no grok sessions dir"
```

- Free >= 15 GiB: OK, proceed.
- Free < 15 GiB: WARN the user in your first reply. Suggest `grokgod cache report`.
- Free < 10 GiB: strongly recommend `grokgod cache --auto-clean` (removes only
  `~/.grokgod/target`; rebuild ~8 min) and/or the macos-dev-cache-cleaner skill.
  Never run a clean or `--apply` yourself without explicit user approval.
- If `~/.grok/sessions` is larger than 2 GiB: WARN and suggest
  `grokgod sessions prune --dry-run` only. Never prune from this runbook.

## 2. Upstream patch watch (every session)

`patches/0001-normalize-plugin-skill-join.patch` is private. Upstream
(xai-org/grok-build) is a one-way mirror with issues/PRs disabled, so watch for
the fix landing on `origin/main` (or forks) instead of expecting a PR.

```sh
git -C ~/Desktop/code/grok-build fetch origin --quiet
git -C ~/Desktop/code/grok-build log --oneline -20 origin/main -- crates/codegen/xai-grok-agent/src/plugins/manifest.rs
git -C ~/Desktop/code/grok-build show origin/main:crates/codegen/xai-grok-agent/src/plugins/manifest.rs | grep -n "CurDir\|normalize" || true
```

- If CurDir/normalize filtering EXISTS upstream: report FIXED-UPSTREAM to the
  user; suggest pinning that SHA, dropping `patches/0001`, rebuilding stock.
- Otherwise: NOT-YET; do nothing. Do not modify patches/, do not rebuild.

NOTE: `git status` in the grok-build checkout showing `manifest.rs` modified is
EXPECTED - that is our applied patch. Never revert it casually; `install.sh`
handles reverse/re-apply on update.

## 3. Live state sanity (every session, 10 seconds)

```sh
grok --version                          # expect: grok 1.0.6 (<origin/main short SHA>)
                                        # full SHA in ~/.grokgod/.source-version matches
                                        # git -C ~/Desktop/code/grok-build rev-parse origin/main
                                        # (authorship pin in patches/README.md is not the update target)
grokgod status | head -6                # shim ownership + source-version
ls -la ~/.local/bin/grok ~/.local/bin/grok.orig
```

`grok status` / `grokgod status` prints `source-drift` vs local `origin/main` (no fetch). `grok --version` stderr warns when behind.

- `~/.local/bin/grok` should be OUR shim (1632+ bytes, contains "GROKGOD").
- If it is a symlink to `~/.grok/bin/grok` again, the official installer
  reclaimed PATH: tell the user, offer `sh ~/Desktop/code/grokgod/install.sh`
  (fast path; only rebuilds if SHA/patchset changed).

## 4. Post-v1 automation model facts (context, no action)

- Interactive default stays `~/.grok/config.toml` `[models] default`
  (currently `grok-4.6`). The old Saturday `~/.grokgod/pin/orca-pin.toml`
  overlay is deprecated as of 2026-09-23; a missing pin file is expected and
  is not an anomaly.
- Orca desktop v1.4.206-1 publishes each automation's model field (`-m`),
  reasoning effort, and optional `minimal` profile (`--agent minimal`). Daily
  `04136086` and Weekly `f91e2fc7` use the model from the Orca automation
  record. Do not treat `grokgod pin check --expect-orca-pin` as a live
  session-start failure.
- **Historical helper:** `grokgod run --automation-root …` /
  `grokgod run --pin` still exports `GROK_CONFIG_PATH` for the disabled
  DEV-TEST fixture. Do not create the retired Weekly automation directory on
  servers without Orca.
- Local grokgod real-session tests (headed Orca TUI / interactive grok against
  the patched binary): always `grok -m flash-max` (or `/model flash-max`).
  Never grok-4.6 for those tests. The deprecated overlay pin and local
  `-m flash-max` are different paths; do not mix them.
- Historical Weekly id `0bbdc998` is retired. launchd stays retired. Codex
  Scheduled copies stay PAUSED. NEVER re-enable launchd while Orca
  automations are enabled (double-fire).
- `~/.grokgod/overlays.toml` is test-fixtures only; production never reads it.

## 5. Release CI facts (context, no action)

- `macos-13` runners are retired by GitHub (~Dec 2025); jobs requesting them
  queue forever and block the whole release. Intel macOS builds use
  `macos-15-intel`. (Wiki: queries/2026-07-24-clawgod-v175-upstream-sync-p1-p2.md)
- grok-build vendors `bin/protoc` as a dotslash file; every CI build leg must
  install dotslash first (`taiki-e/install-action@v2`, `tool: dotslash`) or
  `xai-grok-tools-api` build.rs panics "protoc not found".
- grok-build `.cargo/config.toml` pins `aarch64-unknown-linux-gnu` to
  `target-cpu=neoverse-v2` (ARMv9/SVE2, xAI fleet) - such binaries SIGILL on
  non-SVE ARM hosts (RPi5 Cortex-A76, Neoverse-N1). release.yml overrides
  `RUSTFLAGS` to `target-cpu=generic` for the linux-arm64 leg only (env beats
  config; empty for other legs so their config flags survive). The same
  landmine exists for `--from-source` builds on aarch64 hosts (follow-up).
- release.yml gates on required legs (linux-x64, linux-arm64, darwin-arm64,
  windows-x64); darwin-x64 stays best-effort (`continue-on-error`). Do not
  re-add `if: always()` to the release job - it would publish releases that
  are missing required binaries.

## Escalation

Anything unexpected (patch reject on update, PATH reclaimed, disk < 10 GiB,
upstream fix landed): report to the user in that session's first substantive
reply. Do not auto-fix beyond what is listed above.
