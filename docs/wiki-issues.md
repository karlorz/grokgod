# Grok Build wiki issue catalog (2026-08-18)

Collected from the vault for grokgod. Status is wiki status, not “grokgod will patch this.”

## Open product issues (grok-build itself)

| ID | Issue | Wiki | grokgod fit |
|----|-------|------|-------------|
| GB-PATH | Plugin `"skills": "./skills/"` registers `/./skills/`; auto skill-read FileNotFound | [[projects/grok-build/work/2026-08-18-plugin-skill-path-dot-slash-normalization/spec]] | **v1 persist:** rewrite installed plugin.json after update |
| GB-BUNDLE | Server empty bundle `empty-v1` + local `prune_removed_files` deleted bundled skills | [[concepts/grok-build-bundled-skill-sync-empty-manifest-incident]] · [[raw/transcripts/2026-08-04-grok-build-bundled-skill-empty-manifest]] | Later: guard/restore cache; not a JS patch |
| GB-SEARCH | BYOK gateway 400 if tool named `web_search` | [[concepts/grok-build-gateway-web-search-tool-400]] | Config overlay, already workaround `web_search = "no-such-model"` |
| GB-LEAK | `frontend-design` still loaded despite ignore / `compat.claude.skills=false` | [[concepts/grok-build-frontend-design-skill-leak-and-cc-switch-storage]] | Config / skill-root hygiene on launch |
| GB-PLAN | Write deny from `grok-build-plan` / catalog / NotebookEdit deny | [[concepts/grok-build-plan-lock-write-remediation]] | Policy check, not binary patch |
| GB-HOOKS | Inspect shows Hooks(N); Claude SessionStart `additionalContext` does not inject | [[concepts/grok-build-claude-plugin-hooks-compatibility]] | Document only unless we ship grok hooks |
| GB-UPDATE | Official `grok update` replaces Mach-O; local binary/source edits die | this project | **Why grokgod exists** |

## Adjacent (not grok-build binary)

| ID | Issue | Wiki | grokgod fit |
|----|-------|------|-------------|
| ORCA-PIN | Orca 1.4.184 cannot inject `GROK_CONFIG` / `-m` per automation | [[raw/transcripts/2026-08-18-bug-orca-cannot-pin-grok-config-per-automation]] · [[projects/playground/work/2026-08-18-orca-grok-weekly-model-pin/spec]] | Optional later: grokgod can *set* overlay when launching `grok -p` |
| LUNA-MCP | `gpt-5.6-luna` via opencode zen emits empty `tool_input` | [[raw/transcripts/2026-08-08-task-gpt-5-6-luna-mcp-tool-args-broken]] | Upstream gateway; not a grok patch |
| GEM-ENUM | Gemini `enum[N]: cannot be empty` through cliaproxy | [[projects/grok-build/work/2026-08-15-gemini-enum-override-raw/spec]] | **Completed** (cliaproxy override). Not grokgod |

## Work items under [[projects/grok-build]]

| Folder | Status | Title |
|--------|--------|-------|
| `work/2026-08-18-plugin-skill-path-dot-slash-normalization/` | planned | Normalize `./skills/` join |
| `work/2026-08-15-gemini-enum-override-raw/` | completed | Gemini enum via cliaproxy |

## Architecture / research (not bugs)

See [[projects/grok-build/knowledge]] and [[projects/grok-build/architecture/09-tech-debt]] (compat matrix, dual tool planes, public SHA ≠ product channel).
