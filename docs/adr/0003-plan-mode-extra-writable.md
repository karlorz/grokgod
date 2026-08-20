# Plan-mode extra writable globs, not a SkillWiki hardcode

Grok plan mode’s canonical file stays `~/.grok/sessions/.../plan.md` (TUI
preview / `exit_plan_mode`). 0002 widens the Active edit gate with generic
`[plan_mode] extra_writable_globs` so any PRD skill whose markdown path
matches (SkillWiki work items, Superpowers `docs/superpowers/`, more via
config) can write during planning. grok-build does not detect slash skills
or call `skillwiki path`.

Rejected: SessionStart/PostToolUse copy hooks; switching the canonical path
to a vault file (unknown at session start); forbidding `enter_plan_mode`.

Implement-via-subagents is **on by default** in 0002 (`true` when the key is
absent). Set `implement_via_subagents = false` for stock messages. It does
not ban parent writes. Same-tier-as-parent spawn is a prompt rule, not a
runtime model-id compare. When true, `exit_plan_mode` PlanReady/EmptyPlan
tool results use the second-tier implementer clause (the toggle-exit
reminder is not enough — after `a` the model sees the tool result).

`GROK_CONFIG_PATH` overlays cannot carry `[plan_mode]` (allowlist is models/
features/toolset). grokgod install merges the stanza into `~/.grok/config.toml`
when missing. See `examples/plan-mode.toml`.
